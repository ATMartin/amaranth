import SwiftUI
import Domain
import Presentation

/// Settings tabs, persisted so a control elsewhere can open Settings on a given tab (T77: the sidebar footer opens Models).
enum SettingsTab: String {
    case models, ask, recording, appearance, calendar, updates, notices
    static let key = "settingsTab"
}

extension OpenSettingsAction {
    /// Opens the Settings window on `tab`.
    @MainActor func callAsFunction(_ tab: SettingsTab) {
        UserDefaults.standard.set(tab.rawValue, forKey: SettingsTab.key)
        callAsFunction()
    }
}

struct SettingsView: View {
    static let notices: String = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "Notices file missing from this build."
    @Bindable var models: ModelSetupModel
    var recorder: RecorderModel
    var calendar: CalendarModel
    var reminders: ReminderController?
    var library: LibraryModel?
    var updates: UpdateModel?
    @AppStorage(SettingsTab.key) private var tab = SettingsTab.models.rawValue

    var body: some View {
        TabView(selection: $tab) {
            // Status, details and Install/verify (T77: the only place for them; the toolbar button and sheet are gone).
            ModelSetupView(model: models)
                .frame(maxHeight: .infinity, alignment: .top)
                .tabItem { Label("Models", systemImage: "cpu") }.tag(SettingsTab.models.rawValue)
            AskSettings()
                .tabItem { Label("Ask", systemImage: "bubble.left") }.tag(SettingsTab.ask.rawValue)
            RecordingSettings(recorder: recorder, folders: library?.folders ?? [], library: library)
                .tabItem { Label("Recording", systemImage: "mic") }.tag(SettingsTab.recording.rawValue)
            AppearanceSettings()
                .tabItem { Label("Appearance", systemImage: "textformat.size") }.tag(SettingsTab.appearance.rawValue)
            CalendarSettingsView(calendar: calendar, recorder: recorder, reminders: reminders, library: library)
                .tabItem { Label("Calendar", systemImage: "calendar") }.tag(SettingsTab.calendar.rawValue)
            if let updates {
                UpdateSettingsView(updates: updates)
                    .tabItem { Label("Updates", systemImage: "arrow.down.circle") }.tag(SettingsTab.updates.rawValue)
            }
            ScrollView {
                Text(Self.notices).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding()
            }
            .tabItem { Label("Notices", systemImage: "doc.text") }.tag(SettingsTab.notices.rawValue)
        }
        .frame(width: 560, height: 640)   // Settings → Calendar fits without scrolling to its last button
    }
}

/// Settings → Appearance (T36, T37, T43): light or dark, text size and transcript style.
struct AppearanceSettings: View {
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.system.rawValue
    @AppStorage(TextSize.key) private var textSize = TextSize.default.rawValue
    @AppStorage(TranscriptStyle.key) private var transcriptStyle = TranscriptStyle.columns.rawValue

    var body: some View {
        Form {
            LabeledContent("Appearance") {
                BrandSegmented(options: AppAppearance.allCases.map(\.rawValue), selection: $appearance) { AppAppearance(stored: $0).title }
                    .frame(maxWidth: 380).accessibilityLabel("Appearance")
            }
            Text("Match system follows the Mac's light or dark setting. The sun and moon button in the toolbar (⌘⇧L) switches between Light and Dark.")
                .font(.caption).foregroundStyle(Color.brandSecondary)
            LabeledContent("Text size") {
                BrandSegmented(options: TextSize.allCases.map(\.rawValue), selection: $textSize) { TextSize(stored: $0).title }
                    .frame(maxWidth: 380).accessibilityLabel("Text size")
            }
            Text("Sets the size of the meeting list, transcripts and notes. Default reads at 14 pt; choose Smaller to fit more on screen.")
                .font(.caption).foregroundStyle(Color.brandSecondary)
            LabeledContent("Transcript style") { EmptyView() }
            TranscriptStylePicker(selection: $transcriptStyle)
            Text("Columns: the time, then each speaker's name above their words, everyone on one reading edge. Bubbles: a conversation view with your microphone on the right and other speakers on the left; easiest to read in one-to-one meetings.")
                .font(.caption).foregroundStyle(Color.brandSecondary)
        }
        .formStyle(.grouped)
    }
}

/// Settings → Ask: how the Ask pane searches. One mode at a time; the pane watches the same key and resets on a change.
struct AskSettings: View {
    @AppStorage(AskMode.key) private var mode = AskMode.naturalLanguage.rawValue

    var body: some View {
        Form {
            LabeledContent("Search mode") {
                BrandSegmented(options: AskMode.allCases.map(\.rawValue), selection: $mode) { AskMode(stored: $0).title }
                    .frame(maxWidth: 380).accessibilityLabel("Search mode")
            }
            Text("Natural language answers your question with the model on this Mac, citing the lines it came from, and finds what was meant even in other words. Text match lists the lines that contain your words, grouped by meeting; it works without the models.")
                .font(.caption).foregroundStyle(Color.brandSecondary)
        }
        .formStyle(.grouped)
    }
}

/// Settings → Recording: defaults for new recordings (T30), speaker and processing options, privacy.
struct RecordingSettings: View {
    var recorder: RecorderModel
    /// The sidebar's folders, for "Save to folder" (T42).
    var folders: [Folder] = []
    @AppStorage(RecordingDefaults.folderKey) private var defaultFolder: String?
    @AppStorage(RecordingDefaults.sourcesKey) private var defaultSources = RecordingDefaults.sourcesDefault.rawValue
    @AppStorage(RecordingDefaults.microphoneKey) private var defaultMicrophone: String?
    @AppStorage("microphoneMode") private var microphoneMode = MicrophoneMode.personal.rawValue
    @AppStorage("concurrentAnalysis") private var concurrentAnalysis = true
    @AppStorage("processWhileRecording") private var processWhileRecording = true
    @AppStorage(QuietAlertSettings.enabledKey) private var quietAlert = true
    @AppStorage(QuietAlertSettings.thresholdKey) private var quietSeconds = QuietAlertSettings.defaultThreshold
    @AppStorage(QuietAlertSettings.callEndedKey) private var callEnded = QuietAlertSettings.callEndedDefault.rawValue
    /// T117: stored-audio controls.
    var library: LibraryModel?
    @AppStorage(ProcessingModel.keepAudioKey) private var keepAudio = true
    @State private var storedAudio: LibraryModel.StoredAudio?
    @State private var confirmingDeleteAll = false
    @State private var deletingAll = false
    @State private var deleteAllResult: String?

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
                // T42: a deleted folder reads None and new recordings are unfiled.
                Picker("Save to folder", selection: Binding(get: { RecordingDefaults.resolveFolder(defaultFolder.map(FolderID.init), folders: folders)?.rawValue },
                                                           set: { defaultFolder = $0 })) {
                    Text("None").tag(String?.none)
                    ForEach(folders) { Text($0.name).tag(String?.some($0.id.rawValue)) }
                }
                .disabled(folders.isEmpty)
                Text("Record uses these every time. You can change them for a single meeting with the ▾ button next to Record.")
                    .font(.caption).foregroundStyle(Color.brandSecondary)
            }
            // 2026-11-02.
            Section("When the call ends") {
                Picker("Action", selection: $callEnded) {
                    Text("Stop and make notes").tag(QuietAlertSettings.CallEndedAction.stop.rawValue)
                    Text("Ask “Still recording?”").tag(QuietAlertSettings.CallEndedAction.ask.rawValue)
                    Text("Do nothing").tag(QuietAlertSettings.CallEndedAction.off.rawValue)
                }
                .onChange(of: callEnded) { _, v in
                    if v != QuietAlertSettings.CallEndedAction.off.rawValue, !recorder.inSession { Task { await QuietNotifications.ask() } }
                }
                Text("Works with any call app that uses the microphone: Meet or another browser call, Zoom, Teams, Slack, FaceTime. When an app that held the microphone for 15 seconds lets go of it, the call is over: within 5 seconds Amaranth stops, ends the meeting there and makes the notes. If the call app keeps the microphone (a browser tab left open), Amaranth also stops after 3 minutes without call audio, once other people have spoken; the time starts over while you talk at length, so presenting isn’t cut off. Recording only your microphone never stops this way. Changes apply from the next recording.")
                    .font(.caption).foregroundStyle(Color.brandSecondary)
            }
            // T68.
            Section("When a recording goes quiet") {
                Toggle("Alert when a recording goes quiet", isOn: $quietAlert)
                    .onChange(of: quietAlert) { _, on in
                        // Never asks during a recording (the 0006 rule); the next Stop asks instead.
                        if on, !recorder.inSession { Task { await QuietNotifications.ask() } }
                    }
                Picker("After", selection: $quietSeconds) {
                    ForEach(QuietAlertSettings.choices, id: \.self) { Text(QuietAlertSettings.label($0)).tag($0) }
                }
                .disabled(!quietAlert)
                Text("Asks “Still recording?” when no one has spoken for this long. Stopping while it asks ends the meeting 5 seconds after the last words and deletes the quiet audio after that. Changes apply from the next recording.")
                    .font(.caption).foregroundStyle(Color.brandSecondary)
            }
            Picker("My microphone is", selection: $microphoneMode) {
                Text("A personal headset or laptop mic (one local speaker)").tag(MicrophoneMode.personal.rawValue)
                Text("A shared room mic (several people may speak)").tag(MicrophoneMode.room.rawValue)
            }
            .pickerStyle(.radioGroup)
            Text("Speaker separation uses this to decide whether to split the microphone track into several speakers. You can always correct speakers afterwards. Takes effect for meetings processed after the next launch.")
                .font(.caption).foregroundStyle(Color.brandSecondary)
            Section("Processing") {
                Toggle("Find speakers while transcribing", isOn: $concurrentAnalysis)
                Text("Transcripts with speakers are ready sooner. Turn this off to process one step at a time if your Mac runs hot or short of memory. Takes effect after the next launch.")
                    .font(.caption).foregroundStyle(Color.brandSecondary)
                Toggle("Process while recording", isOn: $processWhileRecording)
                Text("Transcribes during the meeting, so the transcript is ready sooner after you stop, and finishes earlier meetings while you record the next one. It pauses on its own if the Mac gets hot, runs short of memory or the recording has a problem. Turn it off to wait until recording ends, as before. Takes effect after the next launch.")
                    .font(.caption).foregroundStyle(Color.brandSecondary)
            }
            // T117.
            Section("Storage") {
                Toggle("Keep audio after processing", isOn: $keepAudio)
                Text(StoredAudioText.keepCaption)
                    .font(.caption).foregroundStyle(Color.brandSecondary)
                HStack {
                    Text(storedAudio.map { StoredAudioText.summary(bytes: $0.bytes, meetings: $0.meetings) } ?? "Stored audio: measuring…")
                        .monospacedDigit()
                    Spacer()
                    if deletingAll { ProgressView().controlSize(.small) }
                    Button("Delete all stored audio…") { confirmingDeleteAll = true }
                        .disabled(library == nil || deletingAll || (storedAudio?.bytes ?? 0) == 0)
                }
                if let deleteAllResult {
                    Text(deleteAllResult).font(.caption).foregroundStyle(Color.brandSecondary)
                }
            }
            Section("Privacy") {
                Text("Audio, transcripts and notes are kept in ~/Library/Application Support/Amaranth until you delete them, unless you turn off Keep audio after processing above: then each new meeting’s audio is deleted once it has been processed. Deleting a meeting removes its audio, text, notes and search entries; exported files you saved elsewhere are not affected.")
                    .font(.caption).foregroundStyle(Color.brandSecondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(storedAudio.map { StoredAudioText.confirmationTitle(bytes: $0.bytes, meetings: $0.meetings) } ?? "",
                            isPresented: $confirmingDeleteAll, titleVisibility: .visible) {
            Button("Delete All Stored Audio", role: .destructive) { deleteAllStoredAudio() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(StoredAudioText.confirmationMessage(skipped: storedAudio?.skipped ?? 0, untranscribed: storedAudio?.untranscribed ?? 0))
        }
        // On appear and whenever the library list changes (a meeting recorded, processed or its audio deleted).
        .task(id: library?.items) { await refreshStoredAudio() }
        .onAppear { recorder.refreshDevices() }
        .onChange(of: defaultSources) { if !recorder.customized { recorder.loadDefaults() } }
        .onChange(of: defaultMicrophone) { if !recorder.customized { recorder.loadDefaults() } }
    }

    private var recordingMeeting: MeetingID? { recorder.inSession ? recorder.meetingID : nil }

    private func refreshStoredAudio() async {
        storedAudio = await library?.loadStoredAudio(recording: recordingMeeting)
    }

    private func deleteAllStoredAudio() {
        guard let library else { return }
        deletingAll = true
        deleteAllResult = nil
        Task {
            deleteAllResult = await library.deleteAllStoredAudio(recording: recordingMeeting)
            await refreshStoredAudio()
            deletingAll = false
        }
    }
}
