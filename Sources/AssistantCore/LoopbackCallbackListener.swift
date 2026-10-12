import Foundation
import Network

/// A short-lived, IPv4 loopback-only listener for one OAuth callback.
public actor LoopbackCallbackListener {
    private var listener: NWListener?
    private var redirectURI: URL?
    private var expectedState: String?
    private var ready: CheckedContinuation<URL, any Error>?
    private var callback: CheckedContinuation<URL, any Error>?
    private var connections: [UUID: NWConnection] = [:]
    private let queue = DispatchQueue(label: "meh.md.chatgpt.callback")

    public init() {}

    public func start() async throws -> URL {
        guard listener == nil else { throw CallbackError.alreadyStarted }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: .ipv4(.loopback), port: .any
        )
        // The exact IPv4 loopback bind excludes connections from the LAN.
        // acceptLocalOnly restricts local-link peers, which differs from loopback.
        let server = try NWListener(using: parameters)
        listener = server
        server.stateUpdateHandler = { [weak self] state in
            Task { await self?.stateChanged(state) }
        }
        server.newConnectionHandler = { [weak self] connection in
            Task { await self?.receive(connection) }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                ready = continuation
                server.start(queue: queue)
            }
        } onCancel: {
            Task { await self.stop() }
        }
    }

    public func callback(expectedState: String) async throws -> URL {
        guard redirectURI != nil, callback == nil else {
            throw CallbackError.notReady
        }
        self.expectedState = expectedState
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                callback = continuation
            }
        } onCancel: {
            Task { await self.stop() }
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        redirectURI = nil
        expectedState = nil
        ready?.resume(throwing: CancellationError())
        ready = nil
        callback?.resume(throwing: CancellationError())
        callback = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
    }

    private func stateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let port = listener?.port, let continuation = ready else { return }
            let url = URL(string: "http://127.0.0.1:\(port.rawValue)/auth/callback")!
            redirectURI = url
            ready = nil
            continuation.resume(returning: url)
        case .failed:
            ready?.resume(throwing: CallbackError.unavailable)
            ready = nil
            callback?.resume(throwing: CallbackError.unavailable)
            callback = nil
            stop()
        default: break
        }
    }

    private func receive(_ connection: NWConnection) {
        guard listener != nil, connections.count < 8 else {
            connection.cancel()
            return
        }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: queue)
        read(connection, id: id, accumulated: Data())
        Task {
            try? await Task.sleep(for: .seconds(10))
            expire(id)
        }
    }

    private func read(_ connection: NWConnection, id: UUID, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) {
            [weak self] data, _, complete, error in
            Task {
                await self?.received(
                    data, complete: complete, failed: error != nil,
                    connection: connection, id: id, accumulated: accumulated
                )
            }
        }
    }

    private func received(
        _ data: Data?, complete: Bool, failed: Bool,
        connection: NWConnection, id: UUID, accumulated: Data
    ) {
        guard connections[id] != nil else { return }
        var request = accumulated
        if let data { request.append(data) }
        guard request.count <= 8192, !failed else { expire(id); return }
        if request.range(of: Data("\r\n\r\n".utf8)) == nil {
            if complete { expire(id) }
            else { read(connection, id: id, accumulated: request) }
            return
        }
        guard let redirectURI, let expectedState,
              let url = Self.callbackURL(
                  request: request, redirectURI: redirectURI,
                  expectedState: expectedState
              ), let continuation = callback else {
            reply(connection, id: id, success: false)
            return
        }
        callback = nil
        // Send a response without reflecting the authorization code or state.
        reply(connection, id: id, success: true)
        connections.removeValue(forKey: id)
        listener?.cancel()
        listener = nil
        self.redirectURI = nil
        self.expectedState = nil
        for other in connections.values { other.cancel() }
        connections.removeAll()
        continuation.resume(returning: url)
    }

    private func expire(_ id: UUID) {
        connections.removeValue(forKey: id)?.cancel()
    }

    private func reply(_ connection: NWConnection, id: UUID, success: Bool) {
        let body = success
            ? "Sign-in received. You can return to meh.md."
            : "This sign-in callback was not accepted. Return to meh.md to retry."
        let status = success ? "200 OK" : "400 Bad Request"
        let response = "HTTP/1.1 \(status)\r\n"
            + "Content-Type: text/plain; charset=utf-8\r\n"
            + "Content-Length: \(body.utf8.count)\r\n"
            + "Cache-Control: no-store\r\nReferrer-Policy: no-referrer\r\n"
            + "Content-Security-Policy: default-src 'none'\r\n"
            + "Connection: close\r\n\r\n" + body
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
            Task { await self.expire(id) }
        })
    }

    static func callbackURL(
        request: Data, redirectURI: URL, expectedState: String
    ) -> URL? {
        guard let text = String(data: request, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        let first = lines.first?.split(separator: " ") ?? []
        guard first.count == 3, first[0] == "GET", first[2] == "HTTP/1.1",
              first[1].hasPrefix("/"), !first[1].hasPrefix("//") else { return nil }
        let hosts = lines.dropFirst().compactMap { line -> String? in
            guard let colon = line.firstIndex(of: ":"),
                  line[..<colon].lowercased() == "host" else { return nil }
            return line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
        }
        guard hosts == ["127.0.0.1:\(redirectURI.port ?? 0)"],
              let url = URL(string: String(first[1]), relativeTo: redirectURI)?.absoluteURL,
              url.host == "127.0.0.1", url.port == redirectURI.port,
              url.path == redirectURI.path, url.fragment == nil,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return nil }
        let states = items.filter { $0.name == "state" }
        guard states.count == 1, states[0].value == expectedState else { return nil }
        let codes = items.filter { $0.name == "code" }
        let errors = items.filter { $0.name == "error" }
        guard (codes.count == 1 && !(codes[0].value ?? "").isEmpty && errors.isEmpty)
                || (errors.count == 1 && !(errors[0].value ?? "").isEmpty && codes.isEmpty)
        else { return nil }
        return url
    }

    public enum CallbackError: LocalizedError {
        case alreadyStarted, notReady, unavailable
        public var errorDescription: String? {
            "The sign-in callback could not start. Please try again."
        }
    }
}
