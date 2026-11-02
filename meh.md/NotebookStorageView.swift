import NoteCore
import SwiftUI

struct NotebookStorageView: View {
    let replica: NotebookReplica
    let workspace: NotebookWorkspace
    let onOpenNote: ((UUID) -> Void)?
    @State private var report: NotebookStorageReport?
    @State private var errorMessage: String?
    @State private var loading = true

    var body: some View {
        Form {
            if workspace.snapshotMaintenanceStatus != nil {
                NotebookCloudCopiesSection(workspace: workspace)
            }
            if let report {
                NotebookStorageSummary(report: report)
                NotebookStorageCategories(
                    categories: report.categories, totalBytes: report.totalBytes
                )
                NotebookLargestNotesSection(
                    documents: report.documents, onOpenNote: onOpenNote
                )
                Section {
                    Text("Sizes measure notebook files on this device, including copies and backups. They do not measure the app, memory use, or iCloud storage.")
                    Text("File sizes are measured before filesystem compression and may differ from device storage settings.")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            } else if loading {
                Section {
                    ProgressView("Measuring Storage…")
                        .frame(maxWidth: .infinity, alignment: .center)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("notebook-storage-loading")
                }
            }
            if let errorMessage {
                Section {
                    Text("Couldn’t Measure Storage")
                        .font(.headline)
                    Text(errorMessage).foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("notebook-storage-error")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Storage")
        .task {
            loading = true
            errorMessage = nil
            defer { loading = false }
            do {
                let measured = try await workspace.storageReport(for: replica)
                try Task.checkCancellation()
                report = measured
            } catch is CancellationError {
                // Navigation cancels measurements without publishing an error.
            } catch {
                report = nil
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct NotebookStorageSummary: View {
    let report: NotebookStorageReport

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(storageBytes(report.totalBytes))
                    .font(.largeTitle.bold())
                    .accessibilityIdentifier("notebook-storage-total")
                HStack(alignment: .firstTextBaseline) {
                    Text("\(report.activeNoteCount) notes")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("notebook-storage-note-count")
                    if report.trashNoteCount > 0 {
                        Spacer(minLength: 12)
                        Text("\(report.trashNoteCount) in Trash")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }
                NotebookStorageBar(
                    categories: report.categories, totalBytes: report.totalBytes
                )
                .padding(.top, 6)
            }
            .padding(.vertical, 6)
        } header: {
            Text("On This Device")
        } footer: {
            Text("Measured \(report.measuredAt.formatted(date: .omitted, time: .shortened))")
        }
    }
}

private struct NotebookStorageCategories: View {
    let categories: [NotebookStorageCategoryTotal]
    let totalBytes: Int64

    var body: some View {
        Section("Storage Breakdown") {
            ForEach(categories, id: \.category) { entry in
                NotebookStorageValueRow(
                    title: entry.category.storageTitle,
                    value: storageBytes(entry.byteCount),
                    subtitle: storagePercent(entry.byteCount, of: totalBytes),
                    color: entry.category.storageColor
                )
                .accessibilityIdentifier(
                    "notebook-storage-category-\(entry.category.storageIdentifier)"
                )
            }
        }
    }
}

private struct NotebookStorageBar: View {
    let categories: [NotebookStorageCategoryTotal]
    let totalBytes: Int64

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(categories, id: \.category) { entry in
                    Rectangle()
                        .fill(entry.category.storageColor)
                        .frame(width: totalBytes > 0
                            ? geometry.size.width * CGFloat(entry.byteCount)
                                / CGFloat(totalBytes)
                            : 0)
                }
            }
            .background(.quaternary)
            .clipShape(Capsule())
        }
        .frame(height: 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Storage breakdown")
        .accessibilityValue(categories.map {
            "\(String(localized: $0.category.storageTitle)): "
                + storagePercent($0.byteCount, of: totalBytes)
        }.joined(separator: ", "))
    }
}

private struct NotebookLargestNotesSection: View {
    let documents: [NotebookStorageDocumentUsage]
    let onOpenNote: ((UUID) -> Void)?

    var body: some View {
        Section {
            if documents.isEmpty {
                Text("No Notes Yet").foregroundStyle(.secondary)
                    .accessibilityIdentifier("notebook-storage-empty")
            } else {
                ForEach(documents.prefix(5), id: \.id) { document in
                    NotebookStorageNoteLink(
                        document: document, onOpenNote: onOpenNote
                    )
                }
                NavigationLink {
                    NotebookStorageNotesList(
                        documents: documents, onOpenNote: onOpenNote
                    )
                } label: {
                    Text("Show All")
                }
                .accessibilityIdentifier("notebook-storage-show-all")
            }
        } header: {
            Text("Largest Notes")
        } footer: {
            Text("Includes current notes, history, and recovery copies. Markdown copies and backups are counted separately.")
        }
    }
}

private struct NotebookStorageNotesList: View {
    let documents: [NotebookStorageDocumentUsage]
    let onOpenNote: ((UUID) -> Void)?

    var body: some View {
        List(documents, id: \.id) { document in
            NotebookStorageNoteLink(
                document: document, onOpenNote: onOpenNote
            )
        }
        .navigationTitle("All Notes")
        .accessibilityIdentifier("notebook-storage-all-notes")
    }
}

private struct NotebookStorageNoteLink: View {
    let document: NotebookStorageDocumentUsage
    let onOpenNote: ((UUID) -> Void)?

    var body: some View {
        NavigationLink {
            NotebookStorageNoteDetail(
                document: document, onOpenNote: onOpenNote
            )
        } label: {
            NotebookStorageValueRow(
                title: nil, name: document.name,
                value: storageBytes(document.totalBytes),
                subtitle: document.isInTrash ? "Trash" : document.path,
                color: nil
            )
        }
        .accessibilityIdentifier("notebook-storage-note-\(document.id)")
    }
}

private struct NotebookStorageNoteDetail: View {
    let document: NotebookStorageDocumentUsage
    let onOpenNote: ((UUID) -> Void)?

    var body: some View {
        Form {
            Section {
                Text(document.name).font(.headline)
                Text(document.path).foregroundStyle(.secondary)
                if document.isInTrash {
                    Label("In Trash", systemImage: "trash")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                NotebookStorageValueRow(
                    title: "Total", value: storageBytes(document.totalBytes)
                )
                NotebookStorageValueRow(
                    title: "Current Note & History",
                    value: storageBytes(document.currentAndHistoryBytes)
                )
                .accessibilityIdentifier("notebook-storage-note-history")
                NotebookStorageValueRow(
                    title: "Recovery Copies",
                    value: storageBytes(document.recoveryBytes)
                )
            } footer: {
                Text("The current note and its edit history are stored together in one compressed document. Their sizes cannot be measured separately. Markdown copies and backups are not included here.")
            }
            if !document.isInTrash, let onOpenNote {
                Section {
                    Button("Open Note") { onOpenNote(document.id) }
                        .accessibilityIdentifier("notebook-storage-open-note")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Note Storage")
    }
}

private struct NotebookStorageValueRow: View {
    let title: LocalizedStringResource?
    var name: String? = nil
    let value: String
    var subtitle: String? = nil
    var color: Color? = nil

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                NotebookStorageRowLabel(
                    title: title, name: name, subtitle: subtitle, color: color
                )
                Spacer(minLength: 12)
                Text(value).foregroundStyle(.secondary).fixedSize()
            }
            VStack(alignment: .leading, spacing: 6) {
                NotebookStorageRowLabel(
                    title: title, name: name, subtitle: subtitle, color: color
                )
                Text(value).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct NotebookStorageRowLabel: View {
    let title: LocalizedStringResource?
    let name: String?
    let subtitle: String?
    let color: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if let color {
                    Circle().fill(color).frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                }
                if let title { Text(title) }
                else if let name { Text(name) }
            }
            if let subtitle {
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private extension NotebookStorageCategory {
    var storageTitle: LocalizedStringResource {
        switch self {
        case .notesAndHistory: "Notes & History"
        case .recoveryCopies: "Recovery Copies"
        case .markdownCopies: "Markdown Copies"
        case .backups: "Backups"
        case .other: "Other Notebook Files"
        }
    }

    var storageColor: Color {
        switch self {
        case .notesAndHistory: .blue
        case .recoveryCopies: .teal
        case .markdownCopies: .orange
        case .backups: .purple
        case .other: .gray
        }
    }

    var storageIdentifier: String {
        switch self {
        case .notesAndHistory: "notes-history"
        case .recoveryCopies: "recovery"
        case .markdownCopies: "markdown"
        case .backups: "backups"
        case .other: "other"
        }
    }
}

private func storageBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

private func storagePercent(_ bytes: Int64, of total: Int64) -> String {
    (total > 0 ? Double(bytes) / Double(total) : 0)
        .formatted(.percent.precision(.fractionLength(0...1)))
}

private struct NotebookCloudCopiesSection: View {
    let workspace: NotebookWorkspace

    var body: some View {
        Section {
            Button {
                Task { await workspace.requestCloudCopyCleanup() }
            } label: {
                HStack {
                    Text("Clean Up \(workspace.syncStorageName) Copies")
                    Spacer()
                    if workspace.isCleaningCloudCopies { ProgressView() }
                }
            }
            .disabled(!workspace.canCleanCloudCopies)
            .accessibilityIdentifier("notebook-storage-cleanup")
            LabeledContent("Last Cleanup") {
                if let date = workspace.snapshotMaintenanceStatus?.lastSuccessfulCleanup {
                    Text(date, format: .dateTime.year().month().day().hour().minute())
                } else {
                    Text("Never")
                }
            }
            .accessibilityIdentifier("notebook-storage-last-cleanup")
            if let error = workspace.cloudCleanupError {
                Text("Couldn’t Clean Up \(workspace.syncStorageName) Copies")
                    .font(.headline)
                Text(error).foregroundStyle(.secondary)
            }
        } header: {
            Text(workspace.syncStorageName)
        } footer: {
            Text("Removes older sync copies. All notes and their edit history are preserved. Cleanup also runs automatically.")
        }
    }
}
