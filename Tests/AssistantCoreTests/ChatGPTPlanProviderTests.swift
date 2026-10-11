import Foundation
import XCTest
import Synchronization
@testable import AssistantCore

final class ChatGPTPlanProviderTests: XCTestCase {
    func testModelsKeepsOnlyListedCatalogEntriesInServerOrder() async throws {
        StubURLProtocol.handler = { request, loader in
            XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/models")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            loader.respond(body: #"{"models":[{"slug":"second","display_name":"Second","visibility":"list"},{"slug":"hidden","display_name":"Hidden","visibility":"private"},{"slug":"first","display_name":"First","visibility":"list"}]}"#)
        }
        defer { StubURLProtocol.handler = nil }

        let provider = makeProvider()
        let models = try await provider.models()

        XCTAssertEqual(models, [
            AssistantModel(id: "second", displayName: "Second"),
            AssistantModel(id: "first", displayName: "First"),
        ])
    }

    func testStreamSendsOnlyCompleteHistoryAndRequiresCompletionEvent() async throws {
        StubURLProtocol.handler = { request, loader in
            XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            let body = try XCTUnwrap(requestBody(request))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(object["model"] as? String, "catalog-model")
            XCTAssertEqual(object["store"] as? Bool, false)
            XCTAssertEqual(object["stream"] as? Bool, true)
            let input = try XCTUnwrap(object["input"] as? [[String: String]])
            XCTAssertEqual(input, [
                ["role": "user", "content": "Question"],
                ["role": "assistant", "content": "Prior answer"],
            ])
            loader.respond(body: """
                event: response.output_text.delta
                data: {"type":"response.output_text.delta","delta":"Hello"}

                data: {"type":"response.output_text.delta","delta":", world"}

                data: {"type":"response.completed","response":{"status":"completed"}}

                """)
        }
        defer { StubURLProtocol.handler = nil }

        let events = try await collect(provider: makeProvider(), messages: [
            message(.user, "Question"),
            message(.assistant, "Failed answer", status: .failed),
            message(.assistant, "Interrupted answer", status: .interrupted),
            message(.assistant, "Prior answer"),
        ])

        XCTAssertEqual(events, [
            .textDelta("Hello"), .textDelta(", world"), .completed,
        ])
    }

    func testUsageLimitFailureDoesNotEmitCompletedOrExposeRawBody() async throws {
        StubURLProtocol.handler = { _, loader in
            loader.respond(body: #"data: {"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded"}}}"# + "\n\n")
        }
        defer { StubURLProtocol.handler = nil }

        do {
            _ = try await collect(provider: makeProvider(), messages: [message(.user, "Hi")])
            XCTFail("Expected usage-limit failure")
        } catch let error as ChatGPTPlanProviderError {
            XCTAssertEqual(error, .usageLimitReached)
            XCTAssertEqual(error.errorDescription, "The ChatGPT usage limit was reached. Try again later.")
        }
    }

    func testRefusalStreamIsVisibleAndCompletesNormally() async throws {
        StubURLProtocol.handler = { _, loader in
            loader.respond(body: #"data: {"type":"response.refusal.delta","delta":"I can’t help with that."}"# + "\n\n"
                + #"data: {"type":"response.completed","response":{"status":"completed"}}"# + "\n\n")
        }
        defer { StubURLProtocol.handler = nil }

        let events = try await collect(
            provider: makeProvider(), messages: [message(.user, "Hi")]
        )

        XCTAssertEqual(events, [
            .textDelta("I can’t help with that."), .completed,
        ])
    }

    func testOutputItemDoneEventsPreserveNamespacedToolAndFinalMessage() async throws {
        let requests = Mutex(0)
        let executor = RecordingToolExecutor()
        StubURLProtocol.handler = { request, loader in
            let requestNumber = requests.withLock { value in value += 1; return value }
            if requestNumber == 1 {
                loader.respond(body: #"data: {"type":"response.output_item.done","output_index":1,"item":{"type":"function_call","id":"fc_done","call_id":"call_done","namespace":"notebook","name":"create_note","arguments":"{}","status":"completed"}}"# + "\n\n"
                    + #"data: {"type":"response.output_item.done","output_index":0,"item":{"type":"reasoning","id":"rs_done","summary":[],"encrypted_content":"opaque-done"}}"# + "\n\n"
                    + completedOutput("[]"))
            } else {
                let object = try XCTUnwrap(JSONSerialization.jsonObject(
                    with: XCTUnwrap(requestBody(request))) as? [String: Any])
                let input = try XCTUnwrap(object["input"] as? [[String: Any]])
                XCTAssertEqual(input.count, 5)
                XCTAssertEqual(input[2]["encrypted_content"] as? String, "opaque-done")
                XCTAssertEqual(input[3]["call_id"] as? String, "call_done")
                XCTAssertEqual(input[4]["type"] as? String, "function_call_output")
                loader.respond(body: #"data: {"type":"response.output_text.delta","item_id":"msg_done","delta":"Saved."}"# + "\n\n"
                    + #"data: {"type":"response.output_item.done","output_index":0,"item":{"type":"message","id":"msg_done","role":"assistant","status":"completed","content":[{"type":"output_text","text":"Saved.","annotations":[]}]}}"# + "\n\n"
                    + completedOutput("[]"))
            }
        }
        defer { StubURLProtocol.handler = nil }

        var events: [AssistantEvent] = []
        for try await event in makeProvider().stream(messages: [message(.user, "Make a note")],
            model: "m", tools: toolContext(executor: executor)) {
            events.append(event)
        }

        let calls = await executor.calls
        XCTAssertEqual(calls.map(\.name), ["create_note"])
        XCTAssertEqual(events.filter { $0 == .textDelta("Saved.") }.count, 1)
        let context = try XCTUnwrap(events.compactMap { event -> String? in
            if case let .providerContext(value) = event { return value }
            return nil
        }.last)
        let items = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(context.utf8)) as? [[String: Any]])
        XCTAssertEqual(items.count, 4)
        XCTAssertEqual(items[0]["encrypted_content"] as? String, "opaque-done")
        XCTAssertEqual(items[1]["call_id"] as? String, "call_done")
        XCTAssertEqual(items[2]["type"] as? String, "function_call_output")
        XCTAssertEqual(items[3]["id"] as? String, "msg_done")
        XCTAssertEqual(events.last, .completed)
        XCTAssertEqual(requests.withLock { $0 }, 2)
    }

    func testOutputItemDoneMessageSuppliesTextWhenNoDeltaArrives() async throws {
        StubURLProtocol.handler = { _, loader in
            loader.respond(body: #"data: {"type":"response.output_item.done","output_index":0,"item":{"type":"message","id":"msg_only_done","role":"assistant","status":"completed","content":[{"type":"output_text","text":"Only the final item has text.","annotations":[]}]}}"# + "\n\n"
                + completedOutput("[]"))
        }
        defer { StubURLProtocol.handler = nil }

        let events = try await collect(provider: makeProvider(), messages: [message(.user, "Hi")])

        XCTAssertEqual(events.filter { $0 == .textDelta("Only the final item has text.") }.count, 1)
        XCTAssertEqual(events.last, .completed)
    }

    func testEmptyCompletedResponseWithoutTextOrOutputFails() async throws {
        StubURLProtocol.handler = { _, loader in
            loader.respond(body: completedOutput("[]"))
        }
        defer { StubURLProtocol.handler = nil }

        do {
            _ = try await collect(provider: makeProvider(), messages: [message(.user, "Hi")])
            XCTFail("Expected empty completion rejection")
        } catch let error as ChatGPTPlanProviderError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    func testIncompleteAndUnterminatedStreamsAreNotSuccessful() async throws {
        StubURLProtocol.handler = { _, loader in
            loader.respond(body: #"data: {"type":"response.incomplete"}"# + "\n\n")
        }
        do {
            _ = try await collect(provider: makeProvider(), messages: [message(.user, "Hi")])
            XCTFail("Expected incomplete response")
        } catch let error as ChatGPTPlanProviderError {
            XCTAssertEqual(error, .responseIncomplete)
        }

        StubURLProtocol.handler = { _, loader in
            loader.respond(body: #"data: {"type":"response.output_text.delta","delta":"partial"}"# + "\n\n")
        }
        do {
            _ = try await collect(provider: makeProvider(), messages: [message(.user, "Hi")])
            XCTFail("Expected interrupted stream")
        } catch let error as ChatGPTPlanProviderError {
            XCTAssertEqual(error, .streamInterrupted)
        }
        StubURLProtocol.handler = nil
    }

    func testHTTPFailureDoesNotIncludeResponseBody() async throws {
        StubURLProtocol.handler = { _, loader in
            loader.respond(statusCode: 401, body: "secret response text")
        }
        defer { StubURLProtocol.handler = nil }

        do {
            _ = try await collect(provider: makeProvider(), messages: [message(.user, "Hi")])
            XCTFail("Expected HTTP failure")
        } catch let error as ChatGPTPlanProviderError {
            XCTAssertEqual(error, .requestRejected(statusCode: 401))
            XCTAssertFalse(error.localizedDescription.contains("secret response text"))
        }
    }

    func testCancellingConsumerCancelsUnderlyingRequest() async throws {
        let requestStarted = expectation(description: "request started")
        let requestCancelled = expectation(description: "request cancelled")
        StubURLProtocol.handler = { _, loader in
            loader.onStop = { requestCancelled.fulfill() }
            loader.respond(body: "", keepOpen: true)
            requestStarted.fulfill()
        }
        defer { StubURLProtocol.handler = nil }

        let stream = makeProvider().stream(messages: [message(.user, "Hi")], model: "m")
        let consumer = Task {
            for try await _ in stream {}
        }
        await fulfillment(of: [requestStarted], timeout: 2)
        consumer.cancel()
        await fulfillment(of: [requestCancelled], timeout: 2)
    }

    func testNamespacedToolRoundPreservesCanonicalReasoningAndResults() async throws {
        let requests = Mutex(0)
        let executor = RecordingToolExecutor()
        let activity = ToolActivityRecorder()
        StubURLProtocol.handler = { request, loader in
            let number = requests.withLock { value in value += 1; return value }
            let body = try XCTUnwrap(requestBody(request))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(object["store"] as? Bool, false)
            XCTAssertEqual(object["stream"] as? Bool, true)
            XCTAssertNil(object["previous_response_id"])
            let namespaces = try XCTUnwrap(object["tools"] as? [[String: Any]])
            XCTAssertEqual(namespaces[0]["name"] as? String, "notebook")
            XCTAssertEqual(namespaces[0]["type"] as? String, "namespace")
            XCTAssertEqual(object["parallel_tool_calls"] as? Bool, false)
            let input = try XCTUnwrap(object["input"] as? [[String: Any]])
            XCTAssertEqual(input.first?["role"] as? String, "developer")
            if number == 1 {
                loader.respond(body: completedOutput(#"[{"type":"reasoning","id":"rs_fixture","summary":[],"encrypted_content":"opaque-fictional"},{"type":"function_call","id":"fc_fixture","call_id":"call_fixture","namespace":"notebook","name":"create_note","arguments":"{}","status":"completed"}]"#))
            } else {
                XCTAssertEqual(input.count, 5)
                XCTAssertEqual(input[2]["encrypted_content"] as? String, "opaque-fictional")
                XCTAssertEqual(input[3]["call_id"] as? String, "call_fixture")
                XCTAssertEqual(input[4]["type"] as? String, "function_call_output")
                XCTAssertEqual(input[4]["output"] as? String, #"{"saved":true}"#)
                loader.respond(body: #"data: {"type":"response.output_text.delta","item_id":"msg_fixture","delta":"Saved."}"# + "\n\n" + completedOutput(#"[{"type":"message","id":"msg_fixture","role":"assistant","status":"completed","content":[{"type":"output_text","text":"Saved.","annotations":[]}]}]"#))
            }
        }
        defer { StubURLProtocol.handler = nil }
        let context = toolContext(executor: executor, onActivity: { await activity.append($0) })
        var events: [AssistantEvent] = []
        for try await event in makeProvider().stream(messages: [message(.user, "Make a note")],
                                                     model: "m", tools: context) { events.append(event) }
        let calls = await executor.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "create_note")
        let recorded = await activity.values
        XCTAssertEqual(recorded.map(\.phase), [.started, .completed])
        XCTAssertEqual(recorded.last?.output, #"{"saved":true}"#)
        let canonical = try XCTUnwrap(events.compactMap { event -> String? in
            if case let .providerContext(value) = event { return value }; return nil
        }.last)
        let items = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(canonical.utf8)) as? [[String: Any]])
        XCTAssertEqual(items.count, 4)
        XCTAssertEqual(items[0]["encrypted_content"] as? String, "opaque-fictional")
        XCTAssertEqual(items[2]["type"] as? String, "function_call_output")
        XCTAssertEqual(events.last, .completed)
        XCTAssertEqual(requests.withLock { $0 }, 2)
    }

    func testFollowUpReplaysCompleteProviderContextWithoutDuplicatingAssistantText() async throws {
        let canonical = #"[{"type":"reasoning","id":"rs","summary":[],"encrypted_content":"opaque","created_by":"output-only"},{"type":"message","id":"msg","role":"assistant","content":[{"type":"output_text","text":"Saved.","annotations":[]}]}]"#
        StubURLProtocol.handler = { request, loader in
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requestBody(request))) as? [String: Any])
            let input = try XCTUnwrap(object["input"] as? [[String: Any]])
            XCTAssertEqual(input.count, 4)
            XCTAssertEqual(input[1]["type"] as? String, "reasoning")
            XCTAssertNil(input[1]["created_by"])
            XCTAssertEqual(input[2]["id"] as? String, "msg")
            XCTAssertEqual(input[3]["content"] as? String, "What next?")
            XCTAssertFalse(input.contains { $0["content"] as? String == "Saved." })
            loader.respond(body: #"data: {"type":"response.output_text.delta","delta":"Next."}"# + "\n\n" + completedOutput("[]"))
        }
        defer { StubURLProtocol.handler = nil }
        _ = try await collect(provider: makeProvider(), messages: [message(.user, "Create"),
            AssistantMessage(role: .assistant, text: "Saved.", providerContext: canonical),
            message(.user, "What next?")])
    }

    func testInterruptedWritesAreContextButIncompleteModelItemsAreNeverReplayed() async throws {
        let saved = AssistantToolActivity(callID: "saved", name: "create_note", phase: .completed,
            summary: "Saved fictional note", output: #"{"saved":true}"#)
        StubURLProtocol.handler = { request, loader in
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requestBody(request))) as? [String: Any])
            let input = try XCTUnwrap(object["input"] as? [[String: Any]])
            XCTAssertEqual(input.count, 3)
            XCTAssertEqual(input[1]["role"] as? String, "developer")
            XCTAssertTrue((input[1]["content"] as? String)?.contains("saved") == true)
            XCTAssertFalse(input.contains { $0["type"] as? String == "function_call" })
            loader.respond(body: #"data: {"type":"response.output_text.delta","delta":"Continued."}"# + "\n\n" + completedOutput("[]"))
        }
        defer { StubURLProtocol.handler = nil }
        _ = try await collect(provider: makeProvider(), messages: [message(.user, "Create"),
            AssistantMessage(role: .assistant, text: "partial", status: .interrupted,
                toolActivities: [saved], providerContext: #"[{"type":"function_call"}]"#),
            message(.user, "Continue")])
    }

    func testUnknownToolsAndMalformedArgumentsNeverReachExecutor() async throws {
        let requests = Mutex(0)
        let executor = RecordingToolExecutor()
        StubURLProtocol.handler = { request, loader in
            let number = requests.withLock { value in value += 1; return value }
            if number == 1 {
                loader.respond(body: completedOutput(#"[{"type":"function_call","call_id":"unknown","namespace":"other","name":"create_note","arguments":"{}"},{"type":"function_call","call_id":"bad","namespace":"notebook","name":"create_note","arguments":"not-json"}]"#))
            } else {
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requestBody(request))) as? [String: Any])
                let input = try XCTUnwrap(object["input"] as? [[String: Any]])
                let outputs = input.filter { $0["type"] as? String == "function_call_output" }
                XCTAssertEqual(outputs.count, 2)
                XCTAssertTrue((outputs[0]["output"] as? String)?.contains("unknown_tool") == true)
                XCTAssertTrue((outputs[1]["output"] as? String)?.contains("invalid_arguments") == true)
                loader.respond(body: #"data: {"type":"response.output_text.delta","delta":"Done."}"# + "\n\n" + completedOutput("[]"))
            }
        }
        defer { StubURLProtocol.handler = nil }
        for try await _ in makeProvider().stream(messages: [message(.user, "Hi")], model: "m",
                                                  tools: toolContext(executor: executor)) {}
        let calls = await executor.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testRepeatedCallIDCannotRepeatWrite() async throws {
        let executor = RecordingToolExecutor()
        let count = Mutex(0)
        StubURLProtocol.handler = { _, loader in
            count.withLock { $0 += 1 }
            loader.respond(body: completedOutput(#"[{"type":"function_call","call_id":"duplicate","namespace":"notebook","name":"create_note","arguments":"{}"}]"#))
        }
        defer { StubURLProtocol.handler = nil }
        do {
            for try await _ in makeProvider().stream(messages: [message(.user, "Hi")], model: "m",
                                                      tools: toolContext(executor: executor)) {}
            XCTFail("Expected duplicate call rejection")
        } catch let error as ChatGPTPlanProviderError {
            XCTAssertEqual(error, .invalidToolCall)
        }
        let calls = await executor.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(count.withLock { $0 }, 2)
    }

    func testCancellationDuringCommittedToolRetainsFinalActivityWithoutNextRequest() async throws {
        let executor = RecordingToolExecutor(delay: true)
        let activity = ToolActivityRecorder()
        let count = Mutex(0)
        StubURLProtocol.handler = { _, loader in
            count.withLock { $0 += 1 }
            loader.respond(body: completedOutput(#"[{"type":"function_call","call_id":"saved","namespace":"notebook","name":"create_note","arguments":"{}"}]"#))
        }
        defer { StubURLProtocol.handler = nil }
        let stream = makeProvider().stream(messages: [message(.user, "Hi")], model: "m",
            tools: toolContext(executor: executor, onActivity: { await activity.append($0) }))
        let consumer = Task { for try await _ in stream {} }
        let deadline = Date().addingTimeInterval(2)
        while await executor.calls.isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        let started = await executor.calls
        XCTAssertEqual(started.count, 1)
        consumer.cancel()
        while await activity.values.last?.phase != .completed, Date() < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        let final = await activity.values.last
        XCTAssertEqual(final?.phase, .completed)
        XCTAssertEqual(final?.output, #"{"saved":true}"#)
        XCTAssertEqual(count.withLock { $0 }, 1)
    }

    func testCancellationInsideStartedCallbackFinishesActivityWithoutExecuting() async throws {
        let executor = RecordingToolExecutor()
        let activity = ToolActivityRecorder()
        let gate = ToolActivityGate()
        let count = Mutex(0)
        StubURLProtocol.handler = { _, loader in
            count.withLock { $0 += 1 }
            loader.respond(body: completedOutput(#"[{"type":"function_call","call_id":"cancelled","namespace":"notebook","name":"create_note","arguments":"{}"}]"#))
        }
        defer { StubURLProtocol.handler = nil }
        let stream = makeProvider().stream(messages: [message(.user, "Hi")], model: "m",
            tools: toolContext(executor: executor, onActivity: { value in
                await activity.append(value)
                if value.phase == .started { await gate.wait() }
            }))
        let consumer = Task { for try await _ in stream {} }
        let deadline = Date().addingTimeInterval(2)
        while await activity.values.isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        let started = await activity.values
        XCTAssertEqual(started.first?.phase, .started)
        consumer.cancel()
        await gate.release()
        while await activity.values.last?.phase != .failed, Date() < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        let recorded = await activity.values
        XCTAssertEqual(recorded.map(\.phase), [.started, .failed])
        XCTAssertTrue(recorded.last?.output?.contains("cancelled_before_execution") == true)
        let calls = await executor.calls
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(count.withLock { $0 }, 1)
    }

    func testToolLoopIsBoundedAndSeparatesRoundText() async throws {
        let count = Mutex(0)
        let executor = RecordingToolExecutor()
        StubURLProtocol.handler = { _, loader in
            let index = count.withLock { $0 += 1; return $0 }
            loader.respond(body: "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Round \(index).\"}\n\n" +
                completedOutput("[{\"type\":\"function_call\",\"call_id\":\"call_\(index)\",\"namespace\":\"notebook\",\"name\":\"create_note\",\"arguments\":\"{}\"}]"))
        }
        defer { StubURLProtocol.handler = nil }
        var text = ""
        do {
            for try await event in makeProvider().stream(messages: [message(.user, "Hi")], model: "m",
                tools: toolContext(executor: executor)) {
                if case let .textDelta(delta) = event { text += delta }
            }
            XCTFail("Expected bounded tool loop")
        } catch let error as ChatGPTPlanProviderError { XCTAssertEqual(error, .toolLimitReached) }
        XCTAssertTrue(text.hasPrefix("Round 1.\n\nRound 2."))
        XCTAssertEqual(count.withLock { $0 }, 8)
        let calls = await executor.calls
        XCTAssertEqual(calls.count, 7)
    }

    func testMalformedSchemaAndOversizedHistoryFailBeforeNetwork() async throws {
        let count = Mutex(0)
        StubURLProtocol.handler = { _, loader in count.withLock { $0 += 1 }; loader.respond(body: "") }
        defer { StubURLProtocol.handler = nil }
        do {
            for try await _ in makeProvider().stream(messages: [message(.user, "Hi")], model: "m",
                tools: AssistantToolContext(definitions: [.init(name: "bad", description: "bad", parameters: "not-json")],
                    instructions: "", executor: RecordingToolExecutor())) {}
            XCTFail("Expected invalid schema")
        } catch let error as ChatGPTPlanProviderError { XCTAssertEqual(error, .invalidToolDefinition) }
        do {
            _ = try await collect(provider: makeProvider(), messages: [message(.user, String(repeating: "a", count: 2_097_153))])
            XCTFail("Expected request bounds")
        } catch let error as ChatGPTPlanProviderError { XCTAssertEqual(error, .requestTooLarge) }
        XCTAssertEqual(count.withLock { $0 }, 0)
    }

    private func makeProvider() -> ChatGPTPlanProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return ChatGPTPlanProvider(accessToken: { "test-token" }, session: session)
    }

    private func collect(
        provider: ChatGPTPlanProvider,
        messages: [AssistantMessage]
    ) async throws -> [AssistantEvent] {
        var events: [AssistantEvent] = []
        for try await event in provider.stream(messages: messages, model: "catalog-model") {
            events.append(event)
        }
        return events
    }

    private func message(
        _ role: AssistantMessage.Role,
        _ text: String,
        status: AssistantMessage.Status = .complete
    ) -> AssistantMessage {
        AssistantMessage(role: role, text: text, status: status)
    }
}

private func requestBody(_ request: URLRequest) throws -> Data? {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
        if count == 0 { break }
        data.append(contentsOf: buffer.prefix(count))
    }
    return data
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler:
        ((URLRequest, StubURLProtocol) throws -> Void)?

    var onStop: (() -> Void)?
    private var keepOpen = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            try handler(request, self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
        onStop?()
    }

    func respond(statusCode: Int = 200, body: String, keepOpen: Bool = false) {
        self.keepOpen = keepOpen
        let response = HTTPURLResponse(
            url: request.url!, statusCode: statusCode,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client?.urlProtocol(self, didLoad: Data(body.utf8)) }
        if !keepOpen { client?.urlProtocolDidFinishLoading(self) }
    }
}


private func completedOutput(_ output: String) -> String {
    "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":\(output)}}\n\n"
}

private func toolContext(executor: any AssistantToolExecutor,
    onActivity: @escaping @Sendable (AssistantToolActivity) async -> Void = { _ in }) -> AssistantToolContext {
    AssistantToolContext(definitions: [.init(name: "create_note", description: "Create a note",
        parameters: #"{"type":"object","properties":{},"required":[],"additionalProperties":false}"#)],
        instructions: "Work in the selected fictional notebook.", executor: executor, onActivity: onActivity)
}

private actor RecordingToolExecutor: AssistantToolExecutor {
    var calls: [AssistantToolCall] = []
    let delay: Bool
    init(delay: Bool = false) { self.delay = delay }
    func execute(_ call: AssistantToolCall) async -> AssistantToolResult {
        calls.append(call)
        if delay { try? await Task.sleep(for: .milliseconds(100)) }
        return .init(callID: call.id, output: #"{"saved":true}"#, summary: "Saved fictional note")
    }
}

private actor ToolActivityRecorder {
    var values: [AssistantToolActivity] = []
    func append(_ value: AssistantToolActivity) { values.append(value) }
}

private actor ToolActivityGate {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
