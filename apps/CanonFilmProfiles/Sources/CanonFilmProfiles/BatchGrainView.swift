import AppKit
import ProfileCore
import SwiftUI
import UniformTypeIdentifiers

struct BatchGrainView: View {
    @ObservedObject var draft: BatchGrainDraft
    @ObservedObject var session: HostBatchSession

    var body: some View {
        Section("Idle batch grain") {
            Text("Pin completed JPEGs to a manifest and apply luminance grain to separate copies. Picture Style and white balance are set at capture.")
                .font(.caption).fpSecondaryText()
            Text("Processes JPEGs on this Mac. Camera batch support is pending.")
                .font(.caption).fpSecondaryText()

            Group {
                Picker("Grain amount", selection: $draft.amount) {
                    ForEach(BatchGrainAmount.allCases, id: \.self) { choice in
                        Text(choice == .off ? "Off — skip source" : String(choice.rawValue)).tag(choice)
                    }
                }
                Picker("Grain cell", selection: $draft.cell) {
                    ForEach(UInt32(1)...3, id: \.self) { choice in
                        Text(String(choice)).tag(choice)
                    }
                }
                TextField("Seed (0–4,294,967,295)", text: $draft.seed)
                if draft.validatedSeed == nil {
                    Text("Enter a whole number from 0 through 4,294,967,295.").font(.caption)
                }

                Button("Choose host source folder…", action: draft.chooseRoot)
                if let sourceRoot = draft.sourceRoot {
                    LabeledContent("Source folder", value: sourceRoot.path)
                        .font(.caption)
                        .textSelection(.enabled)
                    Button("Choose completed JPEGs…", action: draft.chooseSources)
                    if !draft.sources.isEmpty {
                        DisclosureGroup("Selected JPEGs (\(draft.sources.count))") {
                            ForEach(draft.sources, id: \.self) { source in
                                Text(source.path).font(.caption).textSelection(.enabled)
                            }
                        }
                    }
                }

                Button("Export host batch manifest…") { draft.export(for: session) }
                    .disabled(draft.sources.isEmpty || draft.sources.count > BatchGrainManifest.maxJobs ||
                              draft.validatedSeed == nil)
            }.disabled(session.isActive)
            if draft.exporting {
                ProgressView("Pinning selected JPEGs…").controlSize(.small)
            }
            if let result = draft.result {
                Text(result).font(.caption).textSelection(.enabled)
            }
            HostBatchControls(session: session, exporting: draft.exporting)
        }.disabled(draft.exporting)
    }
}

struct HostBatchFooter: View {
    @ObservedObject var session: HostBatchSession
    @ObservedObject var draft: BatchGrainDraft
    @StateObject private var popover = Popover()

    @MainActor
    private final class Popover: ObservableObject {
        @Published var isPresented = false
    }

    var body: some View {
        if session.hasRun {
            Button {
                popover.isPresented.toggle()
            } label: {
                Label(session.isActive ? "Host batch running" : "Host batch status",
                      systemImage: "photo.on.rectangle.angled")
            }
            .font(.caption)
            .popover(isPresented: $popover.isPresented) {
                VStack(alignment: .leading, spacing: 8) {
                    HostBatchControls(session: session, exporting: draft.exporting)
                }
                .padding()
                .frame(width: 360, alignment: .leading)
            }
        }
    }
}

@MainActor
final class BatchGrainDraft: ObservableObject {
    @Published var sourceRoot: URL?
    @Published var sources: [URL] = []
    @Published var amount: BatchGrainAmount = .off
    @Published var cell: UInt32 = 1
    @Published var seed = "0"
    @Published var exporting = false
    @Published var result: String?

    var validatedSeed: UInt32? {
        guard !seed.isEmpty, seed.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return UInt32(seed)
    }

    func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.prompt = "Choose source folder"
        panel.message = "Choose a folder containing completed JPEGs on this Mac."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        sourceRoot = url
        sources = []
        result = nil
    }

    func chooseSources() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg]
        panel.allowsMultipleSelection = true
        panel.directoryURL = sourceRoot
        panel.prompt = "Choose JPEGs"
        panel.message = "Select up to 64 completed JPEGs inside the chosen source folder."
        guard panel.runModal() == .OK else { return }
        sources = panel.urls
        result = sources.count > BatchGrainManifest.maxJobs ? "Choose at most 64 JPEGs." : nil
    }

    func export(for session: HostBatchSession) {
        guard !exporting, !session.isActive, let sourceRoot, let validatedSeed else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "cbatch") ?? .data]
        panel.nameFieldStringValue = "Idle Batch.cbatch"
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.prompt = "Export host manifest"
        panel.message = "Use a new .cbatch filename on the Mac’s internal drive."
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let selected = sources
        let amount = amount
        let cell = cell
        exporting = true
        result = nil
        Task {
            defer { exporting = false }
            do {
                let output = try await Task.detached(priority: .userInitiated) {
                    let settings = try BatchGrainSettings(amount: amount, cell: cell, seed: validatedSeed)
                    return try BatchGrainExporter.exportPinned(sourceRoot: sourceRoot, sources: selected,
                                                              settings: settings, to: destination)
                }.value
                session.prepare(HostBatchRequest(manifest: output.manifest, sourceRoot: output.sourceRoot,
                                                 digest: output.digest, jobCount: output.jobCount))
                result = "Host batch manifest saved to \(output.manifest.path)."
            } catch {
                result = error.localizedDescription
            }
        }
    }
}
