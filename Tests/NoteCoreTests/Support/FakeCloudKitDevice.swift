import Foundation

@testable import NoteCore

/// One app install syncing through a fake CloudKit server.
@MainActor
struct FakeCloudKitDevice {
    let directory: URL
    let replica: NotebookReplica
    let transport: CloudKitSyncTransport
    let coordinator: NotebookSyncCoordinator
    let log: NotebookSyncEventLog

    static func open(
        _ directory: URL, server: FakeCloudKitServer
    ) async throws -> FakeCloudKitDevice {
        let replica = NotebookReplica(
            directory: directory.appending(path: "notebook")
        )
        try await replica.load()
        let transport = try await CloudKitSyncTransport.makeNotebook(
            services: server.services,
            containerIdentifier: server.containerIdentifier,
            stateDirectory: directory.appending(path: "cloudkit")
        )
        let log = NotebookSyncEventLog(directory: directory)
        return FakeCloudKitDevice(
            directory: directory,
            replica: replica,
            transport: transport,
            coordinator: NotebookSyncCoordinator(
                replica: replica, transport: transport, diagnosticLog: log
            ),
            log: log
        )
    }

    func restarted(
        server: FakeCloudKitServer
    ) async throws -> FakeCloudKitDevice {
        await transport.retire()
        return try await FakeCloudKitDevice.open(directory, server: server)
    }
}
