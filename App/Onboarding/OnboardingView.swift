import SwiftUI

/// First run: what Amaranth does, what stays local, when permissions are asked, and that models are optional for
/// recording. Permissions are requested by macOS at the first Record, never silently.
struct OnboardingView: View {
    @Environment(ModelSetupModel.self) private var models
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Welcome to Amaranth").font(.largeTitle.bold())
            point("lock.shield", "Everything stays on this Mac",
                  "Recordings, transcripts and notes are made and stored locally. Nothing is uploaded.")
            point("mic", "Permissions when you first record",
                  "macOS will ask to allow the microphone and system audio (so other participants are recorded).")
            point("person.2", "Tell people you are recording",
                  "Amaranth records only when you press Record. Recording laws differ; let participants know before you start.")
            point("arrow.down.circle", "Models are optional for recording",
                  modelText)
            HStack {
                Spacer()
                Button("Get Started") { done() }.keyboardShortcut(.defaultAction).controlSize(.large)
            }
        }
        .padding(28)
        .frame(width: 560)
    }

    var modelText: String {
        if case .ready = models.status { return "The speech and notes models are installed, so transcripts and notes are made automatically after each meeting." }
        let gb = Double(models.downloadBytes) / 1e9
        return String(format: "Transcripts and notes need a one-time %.1f GB model download (Settings → Models, or the toolbar). Until then, Amaranth records audio and processes it later.", gb)
    }

    func point(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.title2).frame(width: 30).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
