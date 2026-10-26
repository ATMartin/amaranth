import SwiftUI
import Domain
import Models

/// First-run model installation (T04). Shows download size, free-space requirement, progress, cancellation and
/// verification; offers offline import of the same pack from a folder.
struct ModelSetupView: View {
    @Bindable var model: ModelSetupModel
    @State private var importing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Local models").font(.title2.bold())
            Text("Transcription, speaker separation and notes run entirely on this Mac. The model pack is downloaded once, only when you choose to install it; afterwards everything works offline.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let pack = model.pack {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    GridRow { Text("Pack").foregroundStyle(.secondary); Text("\(pack.id) \(pack.version)") }
                    GridRow { Text("Download").foregroundStyle(.secondary); Text(ModelSetupModel.gb(model.downloadBytes)) }
                    GridRow { Text("Free space needed").foregroundStyle(.secondary); Text(ModelSetupModel.gb(model.requiredFreeBytes)) }
                    GridRow { Text("Free space available").foregroundStyle(.secondary); Text(model.availableBytes.map(ModelSetupModel.gb) ?? "unknown") }
                }
                DisclosureGroup("Models and licenses") {
                    ForEach(pack.manifests) { m in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(m.family) · \(m.license.identifier)").font(.callout.bold())
                            Text(m.license.attribution).font(.caption).foregroundStyle(.secondary)
                            Text("\(m.sourceRepository) @ \(m.sourceRevision.prefix(12))").font(.caption.monospaced()).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            } else {
                Text("This build does not include a model pack definition.").foregroundStyle(Color.statusAttention)
            }

            statusView

            HStack {
                switch model.status {
                case .installing:
                    Button("Cancel", role: .cancel) { model.cancel() }
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
