import SwiftUI
import AppKit
import Capture
import Domain

/// The recorder: title, sources, microphone, independent per-source meters and health, durable "saved up to" time,
/// disk warning, pause/resume/stop, and the private scratchpad while recording. Meters are polled at 10 Hz.
struct RecorderPanel: View {
    @Bindable var model: RecorderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                status
                Spacer()
            }
            let idle = !model.state.isActive
            if idle {
                TextField("Meeting title (optional)", text: $model.title).textFieldStyle(.roundedBorder)
                Picker("Record", selection: $model.selection) {
                    Text("Microphone + system audio").tag(SourceSelection.both)
                    Text("Microphone only").tag(SourceSelection.microphoneOnly)
                    Text("System audio only").tag(SourceSelection.systemOnly)
                }
                Picker("Microphone", selection: $model.microphoneUID) {
                    Text("System default").tag(String?.none)
                    ForEach(model.inputs) { d in Text("\(d.name) (\(d.transportName))").tag(Optional(d.uid)) }
                }
                .disabled(model.selection == .systemOnly)
            }
            ForEach(model.health, id: \.source) { h in
                SourceHealthRow(health: h, savedUpTo: model.savedUpTo[h.source], now: model.elapsed)
            }
            if model.health.contains(where: { $0.status == .permissionDenied }) {
                Button("Open Privacy Settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!)
                }
                .font(.caption)
            }
            if model.diskWarned, let left = model.diskSecondsLeft {
                Label("Low disk space: about \(Int(left / 60)) min of recording left. Amaranth will stop and save before the disk is full.",
                      systemImage: "externaldrive.badge.exclamationmark").font(.caption).foregroundStyle(.orange)
            }
            HStack {
                if idle {
                    Button { model.start() } label: { Label("Record", systemImage: "record.circle") }
                        .keyboardShortcut("r", modifiers: [.command, .shift]).controlSize(.large)
                } else {
                    if model.state == .paused || model.state == .interrupted {
                        Button("Resume") { model.resume() }.keyboardShortcut("p", modifiers: [.command, .shift])
                    } else {
                        Button("Pause") { model.pause() }.disabled(model.state != .recording).keyboardShortcut("p", modifiers: [.command, .shift])
                    }
                    Button("Stop and Save") { model.stop() }.disabled(model.state == .stopping).keyboardShortcut("s", modifiers: [.command, .shift])
                }
            }
            if model.state.isActive {
                TextField("Private scratchpad (only on this Mac)", text: $model.scratchpad, axis: .vertical).lineLimit(2...6)
                    .textFieldStyle(.roundedBorder).font(.callout)
            }
            Text("Amaranth records only when you press Record. Let participants know you are recording.")
                .font(.caption2).foregroundStyle(.secondary)
            if let r = model.lastResult { Text(r).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
            if let m = model.recoveryMessage { Label(m, systemImage: "arrow.uturn.backward.circle").font(.caption).foregroundStyle(.secondary) }
            if let e = model.error { Label(e, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red) }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
    }

    @ViewBuilder var status: some View {
        switch model.state {
        case .recording: Label("Recording · \(Self.format(model.elapsed))", systemImage: "record.circle.fill").foregroundStyle(.red).monospacedDigit().font(.headline)
        case .paused: Label("Paused · \(Self.format(model.elapsed)) — nothing is being recorded", systemImage: "pause.circle.fill").monospacedDigit().font(.headline)
        case .interrupted: Label("Interrupted by sleep · audio so far is saved", systemImage: "moon.zzz").foregroundStyle(.orange).font(.headline)
        case .preparing: Label("Starting… waiting for audio", systemImage: "hourglass").foregroundStyle(.secondary).font(.headline)
        case .stopping: Label("Saving…", systemImage: "arrow.down.circle").font(.headline)
        default: Text("Recorder").font(.headline)
        }
    }

    static func format(_ s: Double) -> String {
        let t = Int(s)
        return String(format: "%02d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60)
    }
}

struct SourceHealthRow: View {
    let health: SourceHealth
    var savedUpTo: Double? = nil
    var now: Double = 0

    var body: some View {
        HStack {
            Text(health.source == .microphone ? "MIC" : "SYS").font(.caption2.bold()).frame(width: 28)
            MeterBar(db: health.peakLevelDBFS ?? -120)
            Text(statusText).font(.caption2).foregroundStyle(statusColor).frame(width: 150, alignment: .leading)
        }
        .help([health.deviceName, savedUpTo.map { "Saved up to \(RecorderPanel.format($0))" }].compactMap { $0 }.joined(separator: " · "))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(health.source == .microphone ? "Microphone" : "System audio"): \(statusText)")
    }

    var statusText: String {
        let lag = savedUpTo.map { now - $0 } ?? 0
        let saved = savedUpTo != nil && lag > 8 ? " · saving delayed" : ""
        return switch health.status {
        case .healthy: "OK" + saved
        case .silent: "Silent (still recording)" + saved
        case .clipping: "Too loud (clipping)"
        case .degraded: "Interrupted — gap marked"
        case .failed: "Not recording — source failed"
        case .permissionDenied: "Permission denied — see System Settings"
        case .starting: "Starting"
        case .inactive: "Off"
        }
    }

    var statusColor: Color {
        switch health.status {
        case .healthy, .silent: .secondary
        case .clipping, .degraded: .orange
        case .failed, .permissionDenied: .red
        default: .secondary
        }
    }
}

struct MeterBar: View {
    let db: Float
    var body: some View {
        GeometryReader { g in
            let frac = CGFloat(max(0, min(1, (db + 60) / 60)))
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(db > -3 ? Color.orange : Color.green).frame(width: g.size.width * frac)
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}
