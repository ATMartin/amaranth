import SwiftUI
import Domain
import Models

/// Settings → Models (T04, T77): every model in the pack with what it does, its size and whether it is installed —
/// the search model included (Ask needs it) — the download size, free space, progress, cancellation and verification;
/// offline import of the same pack from a folder.
struct ModelSetupView: View {
    @Bindable var model: ModelSetupModel
    @State private var importing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Local models").font(.title2.bold())
            Text("Transcription, speaker separation, notes and search run entirely on this Mac. Models are downloaded only when you choose to install them; afterwards everything works offline.")
                .foregroundStyle(Color.brandSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let pack = model.pack {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(rows(pack)) { r in modelRow(r) }
                }
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    GridRow { Text("Pack").foregroundStyle(Color.brandSecondary); Text(packText(pack)) }
                    GridRow {
                        Text("Download").foregroundStyle(Color.brandSecondary)
                        Text(downloadText)
                    }
                    GridRow {
                        Text("Free space needed").foregroundStyle(Color.brandSecondary)
                        Text(model.pendingDownloadBytes < model.downloadBytes ? "\(ModelSetupModel.gb(model.requiredFreeBytes)) (checked against the whole pack)" : ModelSetupModel.gb(model.requiredFreeBytes))
                    }
                    GridRow { Text("Free space available").foregroundStyle(Color.brandSecondary); Text(model.availableBytes.map(ModelSetupModel.gb) ?? "unknown") }
                }
                DisclosureGroup("Licenses and sources") {
                    ForEach(pack.manifests) { m in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(m.family) · \(m.license.identifier)").font(.callout.bold())
                            Text(m.license.attribution).font(.caption).foregroundStyle(Color.brandSecondary)
                            Text("\(m.sourceRepository) @ \(m.sourceRevision.prefix(12))").font(.caption.monospaced()).foregroundStyle(Color.brandSecondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            } else {
                Text("This build does not include a model pack definition.").foregroundStyle(Color.statusAttention)
            }

            statusView
            if let note = model.installNote {
                Label(note, systemImage: "info.circle").font(.callout).foregroundStyle(Color.brandSecondary).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                switch model.status {
                case .installing:
                    Button("Cancel", role: .cancel) { model.cancel() }
                case .ready where model.searchModelMissing && model.pack != nil:
                    Button("Download Search Model (\(ModelSetupModel.gb(model.pendingDownloadBytes)))") { model.install() }
                        .keyboardShortcut(.defaultAction)
                    Button("Import from folder…") { importing = true }
                case .ready:
                    Button("Verify again") { model.refresh() }
                default:
                    Button("Download and install") { model.install() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.pack == nil)
                    Button("Import from folder…") { importing = true }
                        .disabled(model.pack == nil)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 520)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.install(fromDirectory: url) }
        }
    }

    /// One row per job: speaker separation's two manifests share a row.
    struct Row: Identifiable {
        var id: String { title }
        var title: String
        var detail: String
        var families: [String]
        var bytes: Int64
        var installed: Bool
    }

    func rows(_ pack: ModelPack) -> [Row] {
        var out: [Row] = []
        for m in pack.manifests {
            let title = ModelSetupModel.roleTitle(m.role)
            let installed = !model.missingManifests.contains(m.id)
            if let i = out.firstIndex(where: { $0.title == title }) {
                out[i].families.append(m.family); out[i].bytes += m.totalBytes; out[i].installed = out[i].installed && installed
            } else {
                out.append(Row(title: title, detail: ModelSetupModel.roleDetail(m.role), families: [m.family], bytes: m.totalBytes, installed: installed))
            }
        }
        return out
    }

    func modelRow(_ r: Row) -> some View {
        let ready = r.installed && model.status != .checking
        let installing: Bool = { if case .installing = model.status { true } else { false } }()
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: ready ? "checkmark.circle.fill" : installing ? "arrow.down.circle" : "exclamationmark.triangle.fill")
                .foregroundStyle(ready ? Color.statusOK : installing ? Color.brandSecondary : Color.statusAttention)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline) {
                    Text(r.title).font(.callout.bold())
                    Spacer()
                    Text(ready ? "Installed" : installing ? "Installing…" : "Not installed").font(.caption)
                        .foregroundStyle(ready ? Color.brandSecondary : installing ? Color.brandSecondary : Color.statusAttention)
                }
                Text(r.detail).font(.caption).foregroundStyle(Color.brandSecondary).fixedSize(horizontal: false, vertical: true)
                Text("\(r.families.joined(separator: ", ")) · \(ByteCountFormatter.string(fromByteCount: r.bytes, countStyle: .file))").font(.caption.monospaced()).foregroundStyle(Color.brandSecondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(r.title): \(ready ? "installed" : installing ? "installing" : "not installed"). \(r.detail) \(r.families.joined(separator: ", ")), \(ByteCountFormatter.string(fromByteCount: r.bytes, countStyle: .file)).")
    }

    func packText(_ pack: ModelPack) -> String {
        if case .ready(let id, let v) = model.status, id != pack.id || v != pack.version { return "\(pack.id) \(pack.version) (installed: \(v))" }
        return "\(pack.id) \(pack.version)"
    }

    var downloadText: String {
        if case .ready = model.status {
            return model.searchModelMissing ? "\(ModelSetupModel.gb(model.pendingDownloadBytes)) (the search model; installed models are reused)" : "Nothing to download"
        }
        let pending = model.pendingDownloadBytes
        return pending > 0 && pending < model.downloadBytes ? "\(ModelSetupModel.gb(pending)) (installed models are reused)" : ModelSetupModel.gb(model.downloadBytes)
    }

    @ViewBuilder private var statusView: some View {
        switch model.status {
        case .checking:
            ProgressView().controlSize(.small)
        case .recordOnly(let reason):
            Label { Text("Record-only. ").bold() + Text(reason) } icon: { Image(systemName: "record.circle") }
                .foregroundStyle(Color.statusAttention)
        case .installing(let p):
            VStack(alignment: .leading) {
                ProgressView(value: p.bytesTotal > 0 ? Double(p.bytesDone) / Double(p.bytesTotal) : 0) {
                    Text(label(for: p.phase))
                } currentValueLabel: {
                    Text("\(ModelSetupModel.gb(p.bytesDone)) of \(ModelSetupModel.gb(p.bytesTotal))\(p.currentFile.map { " · \($0)" } ?? "")")
                        .lineLimit(1).truncationMode(.middle)
                }
            }
        case .ready where model.searchModelMissing:
            Label { Text("Search model not installed. ").bold() + Text("Recording, transcripts and notes work; Ask needs the search model. Only it is downloaded: the models you have are reused.") }
                icon: { Image(systemName: "exclamationmark.triangle.fill") }
                .foregroundStyle(Color.statusAttention)
                .fixedSize(horizontal: false, vertical: true)
        case .ready(let id, let v):
            Label("Installed and verified: \(id) \(v). Works offline.", systemImage: "checkmark.seal").foregroundStyle(Color.statusOK)
        case .failed(let msg):
            Label(msg, systemImage: "xmark.octagon").foregroundStyle(Color.statusFailed)
        }
    }

    private func label(for phase: InstallProgress.Phase) -> String {
        switch phase {
        case .checkingSpace: "Checking free space…"
        case .downloading: "Downloading…"
        case .verifying: "Verifying checksums…"
        case .warmingUp: "Preparing models…"
        case .activating: "Activating…"
        case .done: "Done"
        }
    }
}
