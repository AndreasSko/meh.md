#if CHATGPT_POC && os(iOS)
import AssistantCore
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class AssistantController {
    static let shared = AssistantController()

    private(set) var account: ChatGPTAccount?
    private(set) var models: [AssistantModel] = []
    private(set) var defaultModelID: String?
    var selectedModelID: String? {
        didSet {
            guard let selectedThreadID, let selectedModelID else { return }
            selectedModelByThreadID[selectedThreadID] = selectedModelID
        }
    }
    private(set) var threads: [AssistantThread] = []
    private(set) var selectedThreadID: UUID?
    private(set) var notebookID: UUID?
    var draft = ""
    private(set) var isSending = false
    private(set) var pendingToolTurnIDs = Set<UUID>()
    private(set) var isConnecting = false
    private(set) var isFixtureOperationWaiting = false
    var errorMessage: String?
    private(set) var authorizationURL: URL?

    var messages: [AssistantMessage] {
        threads.first(where: { $0.id == selectedThreadID })?.messages ?? []
    }

    var visibleThreads: [AssistantThread] {
        guard let notebookID else { return [] }
        return threads.filter { $0.notebookID == notebookID || $0.notebookID == nil }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var isNotebookBound: Bool {
        !isConnecting && notebookID != nil && notebookTools != nil
    }
    var hasPendingToolOperation: Bool { !pendingToolTurnIDs.isEmpty }

    @ObservationIgnored private let provider: any AssistantProvider
    @ObservationIgnored private let authentication: ChatGPTAuthentication?
    @ObservationIgnored private let threadStore: AssistantThreadStore
    @ObservationIgnored private let modelPreferences: AssistantModelPreferences
    @ObservationIgnored private let isFixture: Bool
    @ObservationIgnored private let fixtureStartsSignedOut: Bool
    @ObservationIgnored private var restoreTask: Task<Void, Never>?
    @ObservationIgnored private var didRestore = false
    @ObservationIgnored private var stateEpoch = UUID()
    @ObservationIgnored private var isDisconnecting = false
    @ObservationIgnored private var listener: LoopbackCallbackListener?
    @ObservationIgnored private var connectionTask: Task<Void, Never>?
    @ObservationIgnored private var connectionGeneration = UUID()
    @ObservationIgnored private var connectionAttempt: ChatGPTSignInAttempt?
    @ObservationIgnored private var sendTask: Task<Void, Never>?
    @ObservationIgnored private var activeTurnID: UUID?
    @ObservationIgnored private var persistenceTask: Task<Void, Never>?
    @ObservationIgnored private var partitionPersistenceTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var partitionRevisions: [String: UInt64] = [:]
    @ObservationIgnored private var notebookTools: AssistantToolContext?
    @ObservationIgnored private var selectedModelByThreadID: [UUID: String] = [:]
    @ObservationIgnored private var retainedThreadsByPartition: [String: [AssistantThread]] = [:]
    @ObservationIgnored private var retainedPersistenceTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var retainedPersistenceTokens: [String: UUID] = [:]
    @ObservationIgnored private var retainedPendingTurnIDs: [String: Set<UUID>] = [:]
    @ObservationIgnored private var retainedPendingCallIDs: [String: Set<String>] = [:]
    @ObservationIgnored private var retainedClearAfterSave: [String: UUID] = [:]
    @ObservationIgnored private var retainedExpiryTokens: [String: UUID] = [:]
    @ObservationIgnored private var fixtureCompletionArmed = false
    @ObservationIgnored private var fixtureCompletionContinuation: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var fixtureCompletionGateID: UUID?

    var canFinishFixtureOperation: Bool {
        isFixture && isFixtureOperationWaiting
    }

    private init() {
        let environment = ProcessInfo.processInfo.environment
        #if DEBUG
        let previewRun: String?
        if environment["MEH_ASSISTANT_FIXTURE"] == "1",
           case let .valid(run) = NotebookWorkspace.previewRequest(
               environment: environment
           ), NotebookWorkspace.shared.isPreview {
            previewRun = run
        } else {
            previewRun = nil
        }
        #else
        let previewRun: String? = nil
        #endif

        isFixture = previewRun != nil
        fixtureStartsSignedOut = previewRun != nil
            && environment["MEH_ASSISTANT_FIXTURE_ACCOUNT"] == "0"
        let support = URL.applicationSupportDirectory
        let directory: URL
        if let previewRun {
            directory = support.appending(
                path: "NotebookPreviewTests/\(previewRun)/AssistantChats"
            )
        } else {
            directory = support.appending(path: "AssistantChats")
        }
        threadStore = AssistantThreadStore(directory: directory)
        let modelPreferenceDefaults: UserDefaults?
        if let previewRun {
            modelPreferenceDefaults = UserDefaults(
                suiteName: "meh.md.AssistantPreview.\(previewRun)"
            )
        } else {
            modelPreferenceDefaults = .standard
        }
        modelPreferences = AssistantModelPreferences(defaults: modelPreferenceDefaults)

        #if DEBUG
        if previewRun != nil {
            authentication = nil
            provider = AssistantFixtureProvider()
        } else {
            let auth = ChatGPTAuthentication(
                store: KeychainChatGPTCredentialStore()
            )
            authentication = auth
            provider = ChatGPTPlanProvider(
                accessToken: { try await auth.accessToken() }
            )
        }
        #else
        let auth = ChatGPTAuthentication(
            store: KeychainChatGPTCredentialStore()
        )
        authentication = auth
        provider = ChatGPTPlanProvider(
            accessToken: { try await auth.accessToken() }
        )
        #endif

        Task { await restore() }
    }

    func restore() async {
        if didRestore { return }
        if let restoreTask {
            await restoreTask.value
            return
        }
        isConnecting = true
        let epoch = stateEpoch
        let task = Task { await performRestore(epoch: epoch) }
        restoreTask = task
        await task.value
    }

    private func performRestore(epoch: UUID) async {
        defer {
            if stateEpoch == epoch {
                didRestore = true
                restoreTask = nil
                isConnecting = false
            }
        }

        let restoredAccount: ChatGPTAccount?
        do {
            if isFixture {
                restoredAccount = fixtureStartsSignedOut
                    ? nil : AssistantFixtureProvider.account
            } else {
                restoredAccount = try await authentication?.account()
            }
        } catch {
            guard stateEpoch == epoch else { return }
            errorMessage = userMessage(for: error)
            return
        }
        guard stateEpoch == epoch else { return }
        account = restoredAccount
        guard let restoredAccount else { return }

        await refreshModels(epoch: epoch, accountID: restoredAccount.id)
        guard stateEpoch == epoch else { return }

        do {
            try await loadAndPublishThreads(accountID: restoredAccount.id) { [weak self] loaded in
                guard let self,
                      self.stateEpoch == epoch,
                      self.account?.id == restoredAccount.id else { return false }
                self.threads = loaded
                self.selectedThreadID = nil
                return true
            }
        } catch {
            guard stateEpoch == epoch else { return }
            errorMessage = "Saved chats could not be opened on this device."
        }
    }

    func connect() {
        guard !isConnecting, !isDisconnecting else { return }
        if isFixture {
            connectFixture()
            return
        }
        guard let authentication else { return }
        isConnecting = true
        errorMessage = nil
        let generation = UUID()
        connectionGeneration = generation
        let epoch = UUID()
        stateEpoch = epoch
        restoreTask?.cancel()
        restoreTask = nil
        didRestore = true
        let callbackListener = LoopbackCallbackListener()
        listener = callbackListener

        connectionTask = Task { [weak self] in
            guard let self else { return }
            var startedAttempt: ChatGPTSignInAttempt?
            do {
                let redirectURI = try await callbackListener.start()
                try Task.checkCancellation()
                let attempt = try await authentication.beginSignIn(
                    redirectURI: redirectURI
                )
                startedAttempt = attempt
                guard connectionGeneration == generation, stateEpoch == epoch else {
                    await authentication.cancelSignIn(attempt: attempt)
                    await callbackListener.stop()
                    return
                }
                connectionAttempt = attempt
                authorizationURL = attempt.authorizationURL
                let callbackURL = try await withThrowingTaskGroup(of: URL.self) {
                    group in
                    group.addTask {
                        try await callbackListener.callback(
                            expectedState: attempt.state
                        )
                    }
                    group.addTask {
                        try await Task.sleep(for: .seconds(300))
                        throw AssistantControllerError.signInTimedOut
                    }
                    guard let result = try await group.next() else {
                        throw AssistantControllerError.signInTimedOut
                    }
                    group.cancelAll()
                    return result
                }
                guard connectionGeneration == generation, stateEpoch == epoch else {
                    await authentication.cancelSignIn(attempt: attempt)
                    await callbackListener.stop()
                    return
                }
                authorizationURL = nil
                let signedInAccount = try await authentication.completeSignIn(
                    callbackURL: callbackURL, attempt: attempt
                )
                guard connectionGeneration == generation, stateEpoch == epoch else { return }
                account = signedInAccount
                resetModelSelectionForAccountChange()
                try await loadAndPublishThreads(accountID: signedInAccount.id) { [weak self] loaded in
                    guard let self,
                          self.connectionGeneration == generation,
                          self.stateEpoch == epoch else { return false }
                    self.threads = loaded
                    self.selectedThreadID = nil
                    return true
                }
                await refreshModels(epoch: epoch, accountID: signedInAccount.id)
                guard connectionGeneration == generation, stateEpoch == epoch else { return }
                didRestore = true
                isConnecting = false
                connectionAttempt = nil
                listener = nil
            } catch {
                await callbackListener.stop()
                if connectionGeneration == generation, stateEpoch == epoch {
                    if let startedAttempt {
                        await authentication.cancelSignIn(attempt: startedAttempt)
                    }
                    guard connectionGeneration == generation, stateEpoch == epoch else { return }
                    connectionAttempt = nil
                    authorizationURL = nil
                    isConnecting = false
                    listener = nil
                    if !(error is CancellationError) {
                        errorMessage = userMessage(for: error)
                    }
                }
            }
        }
    }

    func cancelSignIn() {
        connectionGeneration = UUID()
        connectionTask?.cancel()
        connectionTask = nil
        isConnecting = false
        authorizationURL = nil
        let oldListener = listener
        listener = nil
        let oldAttempt = connectionAttempt
        connectionAttempt = nil
        guard let authentication else { return }
        Task {
            if let oldAttempt {
                await authentication.cancelSignIn(attempt: oldAttempt)
            }
            await oldListener?.stop()
        }
    }

    func disconnect() {
        guard !isDisconnecting else { return }
        let departingAccountID = account?.id
        let mayHaveLateToolResult = activeTurnID != nil
            || !pendingToolTurnIDs.isEmpty
        stateEpoch = UUID()
        let epoch = stateEpoch
        cancelSignIn()
        stop()
        restoreTask?.cancel()
        restoreTask = nil
        didRestore = true
        if let departingAccountID, mayHaveLateToolResult {
            let key = partitionKey(accountID: departingAccountID)
            retainedThreadsByPartition[key] = threads
            partitionRevisions[key, default: 0] &+= 1
            retainedPersistenceTasks[key] = partitionPersistenceTasks[key]
            retainedPendingTurnIDs[key] = pendingToolTurnIDs
            if let activeTurnID {
                retainedPendingTurnIDs[key, default: []].insert(activeTurnID)
            }
            retainedPendingCallIDs[key] = Set(threads.flatMap(\.messages)
                .flatMap(\.toolActivities)
                .filter { $0.phase == .started }
                .map(\.callID))
            let expiryToken = UUID()
            retainedExpiryTokens[key] = expiryToken
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(300))
                self?.expireRetainedPartition(key: key, token: expiryToken)
            }
        }
        account = nil
        models = []
        defaultModelID = nil
        selectedModelID = nil
        selectedModelByThreadID.removeAll()
        threads = []
        selectedThreadID = nil
        pendingToolTurnIDs.removeAll()
        draft = ""
        errorMessage = nil
        guard !isFixture, let authentication else {
            isDisconnecting = false
            return
        }
        isDisconnecting = true
        Task {
            do {
                try await authentication.signOut()
            } catch {
                if stateEpoch == epoch { errorMessage = userMessage(for: error) }
            }
            if stateEpoch == epoch { isDisconnecting = false }
        }
    }

    func retryModels() {
        guard let account else { return }
        errorMessage = nil
        let epoch = stateEpoch
        Task { await refreshModels(epoch: epoch, accountID: account.id) }
    }

    var defaultModelName: String? {
        guard let defaultModelID else { return nil }
        return models.first(where: { $0.id == defaultModelID })?.displayName
    }

    func setDefaultModel(_ modelID: String) {
        guard let account, models.contains(where: { $0.id == modelID }) else { return }
        modelPreferences.setModelID(modelID, providerID: provider.id, accountID: account.id)
        defaultModelID = modelID
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending, !hasPendingToolOperation,
              !isConnecting,
              account != nil, isNotebookBound else { return }
        if selectedThreadID == nil { newThread() }
        guard let threadID = selectedThreadID, let model = selectedModelID else { return }

        errorMessage = nil
        draft = ""
        isSending = true
        let turnID = UUID()
        activeTurnID = turnID
        mutateThread(threadID) { thread in
            if thread.notebookID == nil { thread.notebookID = notebookID }
            if thread.title == "New Chat" {
                thread.title = String(text.prefix(48))
            }
            thread.messages.append(
                AssistantMessage(role: .user, text: text)
            )
            thread.messages.append(
                AssistantMessage(
                    id: turnID, role: .assistant, text: "",
                    status: .interrupted
                )
            )
        }
        persistCurrentThreads()
        let snapshot = messages
        let turnEpoch = stateEpoch
        let turnAccountID = account?.id ?? ""
        fixtureCompletionArmed = isFixture
            && text == "fixture create note then stop"
        let tools = notebookTools.map { base in
            AssistantToolContext(
                definitions: base.definitions,
                instructions: base.instructions,
                executor: base.executor,
                onActivity: { [weak self] activity in
                    await self?.recordToolActivity(
                        activity, threadID: threadID, turnID: turnID,
                        epoch: turnEpoch, accountID: turnAccountID
                    )
                }
            )
        }
        sendTask = Task { [weak self] in
            guard let self else { return }
            var receivedCompletion = false
            do {
                for try await event in provider.stream(
                    messages: snapshot, model: model, tools: tools
                ) {
                    try Task.checkCancellation()
                    switch event {
                    case let .textDelta(delta):
                        guard activeTurnID == turnID,
                              selectedThreadID == threadID else { continue }
                        mutateMessage(threadID, turnID: turnID) {
                            $0.text.append(delta)
                        }
                    case .toolActivity:
                        // The awaited callback is the single authoritative source.
                        // Stream delivery can arrive after a later callback save.
                        continue
                    case let .providerContext(context):
                        guard activeTurnID == turnID,
                              selectedThreadID == threadID else { continue }
                        mutateMessage(threadID, turnID: turnID) {
                            $0.providerContext = context
                        }
                        persistCurrentThreads()
                    case .completed:
                        guard activeTurnID == turnID,
                              selectedThreadID == threadID else { continue }
                        mutateMessage(threadID, turnID: turnID) {
                            $0.status = .complete
                        }
                        receivedCompletion = true
                        pendingToolTurnIDs.remove(turnID)
                        activeTurnID = nil
                        isSending = false
                        sendTask = nil
                        persistCurrentThreads()
                    }
                }
                guard receivedCompletion else {
                    throw AssistantControllerError.streamEnded
                }
            } catch {
                guard activeTurnID == turnID else { return }
                mutateMessage(threadID, turnID: turnID) {
                    $0.status = error is CancellationError ? .interrupted : .failed
                }
                activeTurnID = nil
                isSending = false
                sendTask = nil
                if !(error is CancellationError) {
                    errorMessage = userMessage(for: error)
                }
                persistCurrentThreads()
            }
        }
    }

    func stop() {
        guard let turnID = activeTurnID else { return }
        activeTurnID = nil
        sendTask?.cancel()
        sendTask = nil
        if let threadID = selectedThreadID {
            mutateMessage(threadID, turnID: turnID) { $0.status = .interrupted }
        }
        isSending = false
        persistCurrentThreads()
    }

    func newThread() {
        guard account != nil, !isConnecting, notebookID != nil else { return }
        stop()
        draft = ""
        errorMessage = nil
        let thread = AssistantThread(notebookID: notebookID)
        threads.insert(thread, at: 0)
        selectedThreadID = thread.id
        if let defaultModelID {
            selectedModelByThreadID[thread.id] = defaultModelID
        }
        selectedModelID = defaultModelID
        persistCurrentThreads()
    }

    func selectThread(_ id: UUID) {
        guard !isConnecting else { return }
        guard let index = threads.firstIndex(where: { $0.id == id }),
              let notebookID,
              threads[index].notebookID == notebookID
                || threads[index].notebookID == nil else { return }
        guard selectedThreadID != id else { return }
        stop()
        if threads[index].notebookID == nil {
            threads[index].notebookID = notebookID
        }
        selectedThreadID = id
        restoreModelSelection(for: id)
        draft = ""
        errorMessage = nil
        persistCurrentThreads()
    }

    func bindNotebook(_ id: UUID, tools: AssistantToolContext) async {
        await restore()
        guard account != nil, !isConnecting else { return }
        if notebookID != id {
            stop()
            notebookID = id
            notebookTools = tools
            draft = ""
            errorMessage = nil
        } else {
            notebookTools = tools
        }
        guard selectedThreadID.flatMap({ selected in
            threads.first(where: { $0.id == selected })?.notebookID
        }) == id else {
            if let existing = visibleThreads.first(where: { $0.notebookID == id }) {
                selectedThreadID = existing.id
                restoreModelSelection(for: existing.id)
            } else {
                newThread()
            }
            return
        }
    }

    func unbindNotebook(_ id: UUID) {
        guard notebookID == id else { return }
        stop()
        notebookID = nil
        notebookTools = nil
        selectedThreadID = nil
        draft = ""
    }

    func clearError() {
        errorMessage = nil
    }

    func finishFixtureOperation() {
        guard isFixture, let fixtureCompletionGateID else { return }
        releaseFixtureOperation(gateID: fixtureCompletionGateID)
    }

    private func recordToolActivity(
        _ activity: AssistantToolActivity,
        threadID: UUID,
        turnID: UUID,
        epoch: UUID,
        accountID: String
    ) async {
        if isFixture, fixtureCompletionArmed, activity.phase == .completed {
            await waitForFixtureOperationCompletion()
        }
        if stateEpoch == epoch, account?.id == accountID {
            let accepted = mergeToolActivity(
                activity, threadID: threadID, turnID: turnID
            )
            updatePendingToolTurn(turnID, activity: accepted)
            if let task = persistCurrentThreads() { await task.value }
            return
        }

        let key = partitionKey(accountID: accountID)
        if account?.id == accountID,
           threads.contains(where: { $0.id == threadID }) {
            let accepted = mergeToolActivity(
                activity, threadID: threadID, turnID: turnID
            )
            updatePendingToolTurn(turnID, activity: accepted)
            if let task = persistCurrentThreads() { await task.value }
            retainedThreadsByPartition[key] = nil
            return
        }
        guard var retained = retainedThreadsByPartition[key],
              let threadIndex = retained.firstIndex(where: { $0.id == threadID }),
              let messageIndex = retained[threadIndex].messages.firstIndex(
                  where: { $0.id == turnID }
              ) else { return }
        var activities = retained[threadIndex].messages[messageIndex].toolActivities
        let accepted = Self.mergeActivity(activity, into: &activities)
        retained[threadIndex].messages[messageIndex].toolActivities = activities
        retained[threadIndex].updatedAt = Date()
        retainedThreadsByPartition[key] = retained
        if accepted.phase == .started {
            retainedPendingCallIDs[key, default: []].insert(accepted.callID)
            retainedPendingTurnIDs[key, default: []].insert(turnID)
        } else {
            retainedPendingCallIDs[key]?.remove(accepted.callID)
            retainedPendingTurnIDs[key]?.remove(turnID)
        }
        let clearAfterSave = accepted.phase != .started
            && retainedPendingCallIDs[key, default: []].isEmpty
            && retainedPendingTurnIDs[key, default: []].isEmpty
        if let task = persistRetainedThreads(
            retained, key: key, accountID: accountID,
            clearAfterSave: clearAfterSave
        ) { await task.value }
    }

    private func persistRetainedThreads(
        _ snapshot: [AssistantThread], key: String, accountID: String,
        clearAfterSave: Bool
    ) -> Task<Void, Never>? {
        let token = UUID()
        retainedPersistenceTokens[key] = token
        if clearAfterSave { retainedClearAfterSave[key] = token }
        else { retainedClearAfterSave[key] = nil }
        let task = schedulePersistence(snapshot, accountID: accountID)
        retainedPersistenceTasks[key] = task
        Task { [weak self] in
            await task.value
            await self?.finishRetainedPersistence(key: key, token: token)
        }
        return task
    }

    private func finishRetainedPersistence(key: String, token: UUID) {
        guard retainedPersistenceTokens[key] == token else { return }
        retainedPersistenceTokens[key] = nil
        retainedPersistenceTasks[key] = nil
        guard retainedClearAfterSave[key] == token,
              retainedPendingCallIDs[key, default: []].isEmpty,
              retainedPendingTurnIDs[key, default: []].isEmpty else { return }
        clearRetainedPartition(key)
    }

    private func expireRetainedPartition(key: String, token: UUID) {
        guard retainedExpiryTokens[key] == token else { return }
        clearRetainedPartition(key)
    }

    private func clearRetainedPartition(_ key: String) {
        partitionRevisions[key, default: 0] &+= 1
        retainedExpiryTokens[key] = nil
        retainedPersistenceTokens[key] = nil
        retainedClearAfterSave[key] = nil
        retainedPendingCallIDs[key] = nil
        retainedPendingTurnIDs[key] = nil
        retainedThreadsByPartition[key] = nil
    }

    private func updatePendingToolTurn(
        _ turnID: UUID, activity: AssistantToolActivity
    ) {
        if activity.phase == .started {
            pendingToolTurnIDs.insert(turnID)
        } else {
            pendingToolTurnIDs.remove(turnID)
        }
    }

    private func waitForFixtureOperationCompletion() async {
        guard isFixture else { return }
        fixtureCompletionArmed = false
        isFixtureOperationWaiting = true
        let gateID = UUID()
        fixtureCompletionGateID = gateID
        await withCheckedContinuation { continuation in
            fixtureCompletionContinuation = continuation
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(60))
                self?.releaseFixtureOperation(gateID: gateID)
            }
        }
    }

    private func releaseFixtureOperation(gateID: UUID) {
        guard fixtureCompletionGateID == gateID else { return }
        fixtureCompletionGateID = nil
        isFixtureOperationWaiting = false
        let continuation = fixtureCompletionContinuation
        fixtureCompletionContinuation = nil
        continuation?.resume()
    }

    private func partitionKey(accountID: String) -> String {
        "\(provider.id)\u{0}\(accountID)"
    }

    private func waitForPartitionPersistence(accountID: String) async {
        let key = partitionKey(accountID: accountID)
        while true {
            let revision = partitionRevisions[key, default: 0]
            let task = partitionPersistenceTasks[key]
            await task?.value
            if partitionRevisions[key, default: 0] == revision { return }
        }
    }

    private func loadAndPublishThreads(
        accountID: String,
        publish: @MainActor ([AssistantThread]) -> Bool
    ) async throws {
        let key = partitionKey(accountID: accountID)
        while true {
            await waitForPartitionPersistence(accountID: accountID)
            let revision = partitionRevisions[key, default: 0]
            let loaded = try await threadStore.load(
                providerID: provider.id, accountID: accountID
            )
            guard partitionRevisions[key, default: 0] == revision else { continue }
            let merged = Self.mergingThreads(
                loaded, retainedThreadsByPartition[key] ?? []
            )
            guard publish(merged) else { return }
            if retainedClearAfterSave[key] != nil,
               retainedPersistenceTokens[key] == nil,
               retainedPendingCallIDs[key, default: []].isEmpty,
               retainedPendingTurnIDs[key, default: []].isEmpty {
                clearRetainedPartition(key)
            }
            return
        }
    }

    private static func mergingThreads(
        _ stored: [AssistantThread], _ retained: [AssistantThread]
    ) -> [AssistantThread] {
        var merged = Dictionary(uniqueKeysWithValues: stored.map { ($0.id, $0) })
        for retainedThread in retained {
            guard var storedThread = merged[retainedThread.id] else {
                merged[retainedThread.id] = retainedThread
                continue
            }
            var messages = Dictionary(
                uniqueKeysWithValues: storedThread.messages.map { ($0.id, $0) }
            )
            for retainedMessage in retainedThread.messages {
                guard var storedMessage = messages[retainedMessage.id] else {
                    messages[retainedMessage.id] = retainedMessage
                    continue
                }
                for activity in retainedMessage.toolActivities {
                    if let index = storedMessage.toolActivities.firstIndex(
                        where: { $0.callID == activity.callID }
                    ) {
                        if storedMessage.toolActivities[index].phase == .started,
                           activity.phase != .started {
                            storedMessage.toolActivities[index] = activity
                        }
                    } else {
                        storedMessage.toolActivities.append(activity)
                    }
                }
                if storedMessage.text.isEmpty { storedMessage.text = retainedMessage.text }
                if storedMessage.providerContext == nil {
                    storedMessage.providerContext = retainedMessage.providerContext
                }
                messages[retainedMessage.id] = storedMessage
            }
            storedThread.messages = messages.values.sorted {
                $0.createdAt < $1.createdAt
            }
            if storedThread.title == "New Chat" {
                storedThread.title = retainedThread.title
            }
            storedThread.updatedAt = max(storedThread.updatedAt, retainedThread.updatedAt)
            if storedThread.notebookID == nil {
                storedThread.notebookID = retainedThread.notebookID
            }
            merged[retainedThread.id] = storedThread
        }
        return merged.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    @discardableResult
    private func mergeToolActivity(
        _ activity: AssistantToolActivity,
        threadID: UUID,
        turnID: UUID
    ) -> AssistantToolActivity {
        var accepted = activity
        mutateMessage(threadID, turnID: turnID) { message in
            accepted = Self.mergeActivity(activity, into: &message.toolActivities)
        }
        return accepted
    }

    private static func mergeActivity(
        _ incoming: AssistantToolActivity,
        into activities: inout [AssistantToolActivity]
    ) -> AssistantToolActivity {
        guard let index = activities.firstIndex(where: { $0.callID == incoming.callID })
        else {
            activities.append(incoming)
            return incoming
        }
        let current = activities[index]
        guard current.phase == .started || incoming.phase != .started else {
            return current
        }
        activities[index] = incoming
        return incoming
    }

    private func mutateThread(
        _ id: UUID, _ change: (inout AssistantThread) -> Void
    ) {
        guard let index = threads.firstIndex(where: { $0.id == id }) else { return }
        change(&threads[index])
        threads[index].updatedAt = Date()
    }

    private func mutateMessage(
        _ threadID: UUID,
        turnID: UUID,
        _ change: (inout AssistantMessage) -> Void
    ) {
        mutateThread(threadID) { thread in
            guard let index = thread.messages.firstIndex(where: { $0.id == turnID })
            else { return }
            change(&thread.messages[index])
        }
    }

    @discardableResult
    private func persistCurrentThreads() -> Task<Void, Never>? {
        guard let account else { return nil }
        let snapshot = threads
        let task = schedulePersistence(snapshot, accountID: account.id)
        persistenceTask = task
        return task
    }

    private func schedulePersistence(
        _ snapshot: [AssistantThread], accountID: String
    ) -> Task<Void, Never> {
        let key = partitionKey(accountID: accountID)
        partitionRevisions[key, default: 0] &+= 1
        let previous = partitionPersistenceTasks[key]
        let store = threadStore
        let providerID = provider.id
        let task = Task.detached(priority: .utility) { [weak self] in
            await previous?.value
            do {
                try await store.save(
                    snapshot, providerID: providerID, accountID: accountID
                )
            } catch {
                await self?.reportPersistenceFailure(accountID: accountID)
            }
        }
        partitionPersistenceTasks[key] = task
        return task
    }

    private func reportPersistenceFailure(accountID: String) {
        guard account?.id == accountID else { return }
        errorMessage = "Chats could not be saved on this device."
    }

    private func refreshModels(epoch: UUID, accountID: String) async {
        do {
            let loadedModels = try await provider.models()
            guard stateEpoch == epoch, account?.id == accountID else { return }
            models = loadedModels
            let preferredModelID = modelPreferences.modelID(
                providerID: provider.id, accountID: accountID
            )
            guard stateEpoch == epoch, account?.id == accountID else { return }
            defaultModelID = loadedModels.first(where: { $0.id == preferredModelID })?.id
                ?? loadedModels.first?.id
            if loadedModels.isEmpty {
                selectedModelID = nil
                errorMessage = "No ChatGPT models are available yet. Retry in Settings."
            } else if !loadedModels.contains(where: { $0.id == selectedModelID }) {
                let rememberedModelID = selectedThreadID.flatMap { selectedModelByThreadID[$0] }
                selectedModelID = rememberedModelID.flatMap { modelID in
                    loadedModels.contains(where: { $0.id == modelID }) ? modelID : nil
                } ?? defaultModelID
            }
        } catch {
            guard stateEpoch == epoch, account?.id == accountID else { return }
            models = []
            defaultModelID = nil
            selectedModelID = nil
            errorMessage = userMessage(for: error)
        }
    }

    private func connectFixture() {
        guard isFixture, !isConnecting else { return }
        isConnecting = true
        errorMessage = nil
        let epoch = UUID()
        stateEpoch = epoch
        account = AssistantFixtureProvider.account
        resetModelSelectionForAccountChange()
        didRestore = true
        restoreTask?.cancel()
        restoreTask = nil
        Task {
            await refreshModels(
                epoch: epoch, accountID: AssistantFixtureProvider.account.id
            )
            guard stateEpoch == epoch else { return }
            do {
                try await loadAndPublishThreads(
                    accountID: AssistantFixtureProvider.account.id
                ) { [weak self] loaded in
                    guard let self, self.stateEpoch == epoch else { return false }
                    self.threads = loaded
                    self.selectedThreadID = nil
                    return true
                }
            } catch {
                guard stateEpoch == epoch else { return }
                errorMessage = "Saved chats could not be opened on this device."
            }
            guard stateEpoch == epoch else { return }
            isConnecting = false
        }
    }

    private func resetModelSelectionForAccountChange() {
        defaultModelID = nil
        selectedModelID = nil
        selectedModelByThreadID.removeAll()
    }

    private func restoreModelSelection(for threadID: UUID) {
        let rememberedModelID = selectedModelByThreadID[threadID]
        selectedModelID = rememberedModelID.flatMap { modelID in
            models.contains(where: { $0.id == modelID }) ? modelID : nil
        } ?? defaultModelID
    }

    private func userMessage(for error: Error) -> String {
        if let error = error as? ChatGPTAuthenticationError {
            return error.localizedDescription
        }
        if let error = error as? ChatGPTPlanProviderError {
            return error.localizedDescription
        }
        if let error = error as? AssistantThreadStoreError {
            return error.localizedDescription
        }
        if let error = error as? AssistantControllerError {
            if case .signInTimedOut = error {
                return "Sign-in expired. Connect again to continue."
            }
            return "The assistant response ended before it was complete."
        }
        return "The assistant could not complete this request. Try again."
    }
}

private enum AssistantControllerError: Error {
    case streamEnded
    case signInTimedOut
}

@MainActor
private final class AssistantModelPreferences {
    private let defaults: UserDefaults?
    private var isolatedValues: [String: String] = [:]

    init(defaults: UserDefaults?) {
        self.defaults = defaults
    }

    func modelID(providerID: String, accountID: String) -> String? {
        let key = Self.key(providerID: providerID, accountID: accountID)
        return defaults?.string(forKey: key) ?? isolatedValues[key]
    }

    func setModelID(_ modelID: String, providerID: String, accountID: String) {
        let key = Self.key(providerID: providerID, accountID: accountID)
        if let defaults {
            defaults.set(modelID, forKey: key)
        } else {
            isolatedValues[key] = modelID
        }
    }

    private static func key(providerID: String, accountID: String) -> String {
        "assistant.defaultModel.\(providerID).\(accountID)"
    }
}

#if DEBUG
private struct AssistantFixtureProvider: AssistantProvider {
    static let account = ChatGPTAccount(
        id: "preview-assistant-account",
        displayName: "Preview account",
        email: nil
    )

    let id = "assistant-preview"

    func models() async throws -> [AssistantModel] {
        [
            AssistantModel(id: "preview-model", displayName: "Preview model"),
            AssistantModel(id: "preview-model-plus", displayName: "Preview model Plus"),
        ]
    }

    func stream(
        messages: [AssistantMessage], model: String, tools: AssistantToolContext?
    ) -> AsyncThrowingStream<AssistantEvent, any Error> {
        AsyncThrowingStream { continuation in
            let prompt = messages.last(where: { $0.role == .user })?.text ?? ""
            let earlierCount = messages.dropLast(2).filter {
                $0.role == .user && $0.status == .complete
            }.count
            let task = Task {
                do {
                    if prompt == "fixture create note"
                        || prompt == "fixture create note then stop" {
                        guard let tools else { throw AssistantFixtureError.noTools }
                        let stopMode = prompt == "fixture create note then stop"
                        let title = stopMode
                            ? "Assistant Stop Fixture Note"
                            : "Assistant Fixture Note"
                        let result = try await Self.runTool(
                            "create_note",
                            arguments: [
                                "title": title,
                                "markdown": "Created by the notebook assistant fixture."
                            ], tools: tools, continuation: continuation
                        )
                        continuation.yield(.textDelta(result.summary))
                        continuation.yield(.completed)
                        continuation.finish()
                        return
                    }
                    if prompt == "fixture update note" {
                        guard let tools else { throw AssistantFixtureError.noTools }
                        let found = try await Self.runTool(
                            "search_notes",
                            arguments: ["query": "Assistant Fixture Note"],
                            tools: tools,
                            continuation: continuation
                        )
                        guard let noteID = Self.firstResult(found.output)?["note_id"] as? String,
                              let noteUUID = UUID(uuidString: noteID) else {
                            throw AssistantFixtureError.noteNotFound
                        }
                        let read = try await Self.runTool(
                            "read_note",
                            arguments: ["note_id": noteUUID.uuidString],
                            tools: tools,
                            continuation: continuation
                        )
                        guard let note = Self.object(read.output),
                              let revision = note["revision"] as? String else {
                            throw AssistantFixtureError.noteNotFound
                        }
                        let updated = try await Self.runTool(
                            "update_note",
                            arguments: [
                                "note_id": noteUUID.uuidString,
                                "revision": revision,
                                "markdown": "Updated by the notebook assistant fixture."
                            ],
                            tools: tools,
                            continuation: continuation
                        )
                        continuation.yield(.textDelta(updated.summary))
                        continuation.yield(.completed)
                        continuation.finish()
                        return
                    }
                    if prompt == "fixture search notes" || prompt == "fixture read note" {
                        guard let tools else { throw AssistantFixtureError.noTools }
                        let found = try await Self.runTool(
                            "search_notes",
                            arguments: ["query": "Assistant Fixture Note"],
                            tools: tools,
                            continuation: continuation
                        )
                        var summary = found.summary
                        if prompt == "fixture read note",
                           let noteID = Self.firstResult(found.output)?["note_id"] as? String {
                            let read = try await Self.runTool(
                                "read_note",
                                arguments: ["note_id": noteID],
                                tools: tools,
                                continuation: continuation
                            )
                            summary = read.summary
                        }
                        continuation.yield(.textDelta(summary))
                        continuation.yield(.completed)
                        continuation.finish()
                        return
                    }
                    if prompt == "fixture failure" {
                        continuation.yield(.textDelta("Partial preview reply"))
                        try await Task.sleep(for: .milliseconds(80))
                        throw AssistantFixtureError.failed
                    }

                    let reply = "Earlier messages: \(earlierCount). "
                        + "Preview reply: \(prompt)"
                    let chunks = Self.chunks(reply, size: 12)
                    for (index, chunk) in chunks.enumerated() {
                        try Task.checkCancellation()
                        continuation.yield(.textDelta(chunk))
                        if prompt == "fixture slow", index == 0 {
                            try await Task.sleep(for: .seconds(5))
                        } else {
                            try await Task.sleep(for: .milliseconds(20))
                        }
                    }
                    try Task.checkCancellation()
                    continuation.yield(.completed)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private static func chunks(_ text: String, size: Int) -> [String] {
        var result: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: size, limitedBy: text.endIndex)
                ?? text.endIndex
            result.append(String(text[start..<end]))
            start = end
        }
        return result
    }

    private static func runTool(
        _ name: String,
        arguments: [String: String],
        tools: AssistantToolContext,
        continuation: AsyncThrowingStream<AssistantEvent, any Error>.Continuation
    ) async throws -> AssistantToolResult {
        try Task.checkCancellation()
        guard tools.definitions.contains(where: { $0.name == name }) else {
            throw AssistantFixtureError.noTools
        }
        let data = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
        let callID = "fixture-\(UUID().uuidString)"
        let call = AssistantToolCall(
            id: callID, name: name,
            arguments: String(decoding: data, as: UTF8.self)
        )
        let started = AssistantToolActivity(
            callID: callID, name: name, phase: .started,
            summary: "Working with your notebook…"
        )
        await tools.onActivity(started)
        continuation.yield(.toolActivity(started))
        let result = await tools.executor.execute(call)
        let completed = AssistantToolActivity(
            callID: callID, name: name,
            phase: result.isError ? .failed : .completed,
            summary: result.summary, noteReferences: result.noteReferences,
            output: result.output
        )
        await tools.onActivity(completed)
        continuation.yield(.toolActivity(completed))
        try Task.checkCancellation()
        guard !result.isError else { throw AssistantFixtureError.toolFailed }
        return result
    }

    private static func object(_ output: String) -> [String: Any]? {
        guard let data = output.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func firstResult(_ output: String) -> [String: Any]? {
        let results = object(output)?["results"] as? [[String: Any]]
        return results?.first
    }
}

private enum AssistantFixtureError: Error {
    case failed
    case noTools
    case noteNotFound
    case toolFailed
}
#endif
#endif
