import SwiftUI
import UniformTypeIdentifiers

/// The only outbound surfaces are user-invoked system file/share sheets.
private struct ExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data
    init(_ data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct ReviewView: View {
    let store: ChoreStore
    let onRestore: () -> Void

    @State private var window: FairnessWindow = .week
    @State private var rows: [FairnessRow] = []
    @State private var state = BoardState()
    @State private var redactNames = true
    @State private var showingImporter = false
    @State private var showingExporter = false
    @State private var showingBackupConfirmation = false
    @State private var pendingArchive: BoardArchive?
    @State private var exportDocument: ExportDocument?
    @State private var errorMessage: String?

    private var shareText: String { BoardShare.text(state: state, redactNames: redactNames) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Time window", selection: $window) {
                        ForEach(FairnessWindow.allCases) { option in Text(option.rawValue).tag(option) }
                    }
                    .accessibilityIdentifier("fairness.window")
                    Text("Only explicitly completed chores count. Effort is estimated at assignment time; undone work does not count.")
                        .font(.footnote).foregroundStyle(.secondary)
                    ForEach(rows) { row in
                        VStack(alignment: .leading) {
                            Text(row.name)
                            Text("\(row.completedCount) completed · \(row.completedEffortMinutes) estimated minutes")
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                } header: { Text("Completed work") }

                Section("Board text") {
                    Toggle("Hide profile names", isOn: $redactNames)
                        .accessibilityIdentifier("share.redact")
                    Text(shareText)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                    ShareLink(item: shareText) { Label("Share or print board text", systemImage: "square.and.arrow.up") }
                        .accessibilityIdentifier("share.board")
                    Text("Preview above before sharing. Chore titles and unredacted names may identify your household; never includes history or swap requests.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section("Portable backup") {
                    Button("Export full JSON backup") { showingBackupConfirmation = true }
                        .accessibilityIdentifier("backup.export")
                    Button("Restore JSON backup") { showingImporter = true }
                        .accessibilityIdentifier("backup.import")
                    Text("Backup is unencrypted and includes profile names, chore details and every event. Keep it private. Restore replaces this device's entire board after confirmation.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Review")
            .onAppear(perform: refresh)
            .onChange(of: window) { _, _ in refresh() }
            .confirmationDialog("Export unencrypted household backup?", isPresented: $showingBackupConfirmation) {
                Button("Export JSON") { prepareExport() }
            } message: { Text("Anyone with this file can read your full household history.") }
            .fileExporter(isPresented: $showingExporter, document: exportDocument,
                          contentType: .json, defaultFilename: "ChoreWheel-backup") { result in
                if case .failure(let error) = result { errorMessage = error.localizedDescription }
                exportDocument = nil
            }
            .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.json]) { result in
                do {
                    let url = try result.get()
                    guard url.startAccessingSecurityScopedResource() else {
                        throw CocoaError(.fileReadNoPermission)
                    }
                    defer { url.stopAccessingSecurityScopedResource() }
                    let data = try Data(contentsOf: url)
                    let archive = try JSONDecoder().decode(BoardArchive.self, from: data)
                    _ = try archive.validatedEvents()
                    pendingArchive = archive
                } catch { errorMessage = error.localizedDescription }
            }
            .confirmationDialog("Replace entire local board?", isPresented: Binding(
                get: { pendingArchive != nil },
                set: { if !$0 { pendingArchive = nil } }
            )) {
                Button("Replace board", role: .destructive) {
                    guard let archive = pendingArchive else { return }
                    do { try store.replace(with: archive); refresh(); onRestore() }
                    catch { errorMessage = error.localizedDescription }
                    pendingArchive = nil
                }
                Button("Cancel", role: .cancel) { pendingArchive = nil }
            } message: {
                Text("This overwrites current members, chores and history with \(pendingArchive?.events.count ?? 0) backup events. Export current board first if needed.")
            }
            .alert("Operation failed", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "Unknown error") }
        }
    }

    private func refresh() {
        do {
            state = store.boardState()
            rows = try FairnessReport.rows(events: store.allEvents(), asOf: Date(), window: window)
        } catch { errorMessage = error.localizedDescription }
    }

    private func prepareExport() {
        do {
            exportDocument = ExportDocument(try store.exportArchive())
            showingExporter = true
        } catch { errorMessage = error.localizedDescription }
    }
}
