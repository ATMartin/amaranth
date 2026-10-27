import SwiftUI
import Domain
import Presentation

struct SettingsView: View {
    static let notices: String = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "Notices file missing from this build."
    @Bindable var models: ModelSetupModel
    var recorder: RecorderModel
    var calendar: CalendarModel
    var reminders: ReminderController?
    var library: LibraryModel?

    var body: some View {
        TabView {
            ModelSetupView(model: models)
                .tabItem { Label("Models", systemImage: "cpu") }
            RecordingSettings(recorder: recorder)
                .tabItem { Label("Recording", systemImage: "mic") }
            AppearanceSettings()
                .tabItem { Label("Appearance", systemImage: "textformat.size") }
            CalendarSettingsView(calendar: calendar, recorder: recorder, reminders: reminders, library: library)
                .tabItem { Label("Calendar", systemImage: "calendar") }
            ScrollView {
                Text(Self.notices).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding()
            }
            .tabItem { Label("Notices", systemImage: "doc.text") }
        }
        .frame(width: 560, height: 460)
    }
}

/// Settings → Appearance (T36, T37, T43): light or dark, text size and transcript style.
struct AppearanceSettings: View {
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.system.rawValue
    @AppStorage(TextSize.key) private var textSize = TextSize.default.rawValue
    @AppStorage(TranscriptStyle.key) private var transcriptStyle = TranscriptStyle.columns.rawValue

    var body: some View {
        Form {
            Picker("Appearance", selection: $appearance) {
                ForEach(AppAppearance.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            Text("Match system follows the Mac's light or dark setting. The sun and moon button in the toolbar (⌘⇧L) switches between Light and Dark.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Text size", selection: $textSize) {
                ForEach(TextSize.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            Text("Sets the size of the meeting list, transcripts and notes. Default is compact; choose Larger for easier reading.")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("Transcript style") { EmptyView() }
            TranscriptStylePicker(selection: $transcriptStyle)
            Text("Columns: time, speaker and text side by side. Bubbles: a conversation view with your microphone on the right and other speakers on the left; easiest to read in one-to-one meetings.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

/// Settings → Recording: defaults for new recordings (T30), speaker and processing options, privacy.
struct RecordingSettings: View {
    var recorder: RecorderModel
    @AppStorage(RecordingDefaults.sourcesKey) private var defaultSources = RecordingDefaults.sourcesDefault.rawValue
    @AppStorage(RecordingDefaults.microphoneKey) private var defaultMicrophone: String?
    @AppStorage("microphoneMode") private var microphoneMode = MicrophoneMode.personal.rawValue
    @AppStorage("concurrentAnalysis") private var concurrentAnalysis = true
    @AppStorage("processWhileRecording") private var processWhileRecording = true

    var body: some View {
        Form {
            Section("New recordings") {
                Picker("Record", selection: $defaultSources) {
                    Text("Microphone + system audio").tag(SourceSelection.both.rawValue)
                    Text("Microphone only").tag(SourceSelection.microphoneOnly.rawValue)
                    Text("System audio only").tag(SourceSelection.systemOnly.rawValue)
                }
                Picker("Microphone", selection: $defaultMicrophone) {
                    Text("System default").tag(String?.none)
                    ForEach(recorder.inputs) { d in Text("\(d.name) (\(d.transportName))").tag(Optional(d.uid)) }
                    if let uid = defaultMicrophone, !recorder.inputs.contains(where: { $0.uid == uid }) {
                        Text("Not connected (uses System default)").tag(Optional(uid))
                    }
                }
                .disabled(defaultSources == SourceSelection.systemOnly.rawValue)
                Text("Record uses these every time. You can change them for a single meeting with the ▾ button next to Record.")
                    .font(.caption).foregroundStyle(.secondary)
            }
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
                Toggle("Process while recording", isOn: $processWhileRecording)
                Text("Transcribes during the meeting, so the transcript is ready sooner after you stop, and finishes earlier meetings while you record the next one. It pauses on its own if the Mac gets hot, runs short of memory or the recording has a problem. Turn it off to wait until recording ends, as before. Takes effect after the next launch.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Privacy") {
                Text("Audio, transcripts and notes are kept in ~/Library/Application Support/Amaranth until you delete them. Deleting a meeting removes its audio, text, notes and search entries; exported files you saved elsewhere are not affected.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { recorder.refreshDevices() }
        .onChange(of: defaultSources) { if !recorder.customized { recorder.loadDefaults() } }
        .onChange(of: defaultMicrophone) { if !recorder.customized { recorder.loadDefaults() } }
    }
}
