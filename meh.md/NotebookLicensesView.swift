import SwiftUI

/// The open source code inside meh.md and the licenses it comes with.
struct NotebookLicensesView: View {
    private let licenses = OpenSourceLicenses.bundled

    var body: some View {
        Form {
            Section {
                Text("meh.md is built with these open source projects. Thank you to everyone who works on them.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
            }
            if let licenses {
                Section {
                    ForEach(licenses.packages) { package in
                        NavigationLink {
                            NotebookLicenseView(
                                package: package, texts: licenses.texts(for: package)
                            )
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: package.name)
                                Text(verbatim: package.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Open Source Licenses")
    }
}

private struct NotebookLicenseView: View {
    let package: OpenSourceLicenses.Package
    let texts: [String]

    var body: some View {
        Form {
            Section {
                if !package.version.isEmpty {
                    LabeledContent("Version") { Text(verbatim: package.version) }
                }
                LabeledContent("License") { Text(verbatim: package.license) }
                Link("Source Code", destination: package.url)
            } footer: {
                if let note = package.note {
                    Text(verbatim: note)
                }
            }
            ForEach(texts.indices, id: \.self) { index in
                Section {
                    Text(verbatim: OpenSourceLicenses.reflowed(texts[index]))
                        .font(.footnote)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text(verbatim: package.name))
    }
}

private extension OpenSourceLicenses.Package {
    var summary: String {
        [version, license].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
