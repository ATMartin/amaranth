import SwiftUI
import Domain

struct SettingsView: View {
    static let notices: String = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "Notices file missing from this build."
    @Bindable var models: ModelSetupModel
    @AppStorage("microphoneMode") private var microphoneMode = MicrophoneMode.personal.rawValue
    @AppStorage("concurrentAnalysis") private var concurrentAnalysis = true

    var body: some View {
        TabView {
            ModelSetupView(model: models)
                .tabItem { Label("Models", systemImage: "cpu") }
            Form {
                Picker("My microphone is", selection: $microphoneMode) {
                    Text("A personal headset or laptop mic (one local speaker)").tag(MicrophoneMode.personal.rawValue)
                    Text("A shared room mic (several people may speak)").tag(MicrophoneMode.room.rawValue)
                }
                .pickerStyle(.radioGroup)
                Text("Speaker separation uses this to decide whether to split the microphone track into several speakers. You can always correct speakers afterwards. Takes effect for meetings processed after the next launch.")
                    .font(.caption).foregroundStyle(.secondary)
                Section("Processing") {
                    Toggle("Find speakers while transcribing", isOn: $concurrentAnalysis)
                    Text("Transcripts with speakers are ready sooner. Turn this off to process one step at a time if your Mac runs hot or short of memory. Takes effect after the next launch.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Privacy") {
                    Text("Audio, transcripts and notes are kept in ~/Library/Application Support/Amaranth until you delete them. Deleting a meeting removes its audio, text, notes and search entries; exported files you saved elsewhere are not affected.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Recording", systemImage: "mic") }
            ScrollView {
                Text(Self.notices).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding()
            }
            .tabItem { Label("Notices", systemImage: "doc.text") }
        }
        .frame(width: 560, height: 460)
    }
}
