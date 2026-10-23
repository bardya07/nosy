import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @AppStorage("remindAfterHours") private var remindAfterHours = 3
    @AppStorage("compressAudio") private var compressAudio = true
    @AppStorage("smarterVocabulary") private var smarterVocabulary = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            section("Transcripts") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: "folder.fill").foregroundStyle(Theme.accent)
                        Text(abbreviated(model.paths.transcripts))
                            .font(Theme.text(13, .medium)).foregroundStyle(Theme.ink)
                            .lineLimit(1).truncationMode(.middle)
                            .help(model.paths.transcripts.path)
                        Spacer(minLength: 0)
                    }
                    .fieldChrome()
                    HStack(spacing: 8) {
                        Button("Change…") { model.chooseTranscriptsFolder() }
                            .buttonStyle(PillButtonStyle(kind: .quiet, height: 30, fullWidth: false))
                            .disabled(model.busy)
                        Button("Show in Finder") { model.revealTranscriptsFolder() }
                            .buttonStyle(PillButtonStyle(kind: .quiet, height: 30, fullWidth: false))
                    }
                    Toggle("Smarter vocabulary (beta)", isOn: $smarterVocabulary)
                    note("Checks uncertain spellings against your course vocabulary. Can make mistakes.")
                    note("Each lecture gets its own folder. Add a vocab.txt to a lecture's folder to teach Nosy its terms.")
                }
            }
            section("Audio") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Keep recordings", selection: Binding(get: { model.paths.retentionDays }, set: { model.setRetention(days: $0) })) {
                        Text("1 week").tag(7)
                        Text("2 weeks").tag(14)
                        Text("1 month").tag(30)
                        Text("Forever").tag(0)
                    }
                    Picker("Audio quality", selection: $compressAudio) {
                        Text("Compact — M4A, about 22 MB per hour").tag(true)
                        Text("Full quality — WAV, about 115 MB per hour").tag(false)
                    }
                    note("Audio is deleted only after its transcript is saved. Unfinished recordings are always kept.")
                }
            }
            section("While recording") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Remind me after", selection: $remindAfterHours) {
                        Text("2 hours").tag(2)
                        Text("3 hours").tag(3)
                        Text("4 hours").tag(4)
                        Text("Never").tag(0)
                    }
                    note("Nosy stops your Mac from dozing off while it works, but closing the lid still sleeps it — keep the lid open during lectures. You'll be warned if the mic goes quiet.")
                }
            }
        }
        .font(Theme.text(13))
        .foregroundStyle(Theme.ink)
        .padding(24)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.background)
        .tint(Theme.accent)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(Theme.label).kerning(0.8).foregroundStyle(Theme.muted)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
    private func note(_ text: String) -> some View {
        Text(text).font(Theme.text(11.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
    }
    private func abbreviated(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }
}
