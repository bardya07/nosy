import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @AppStorage("remindAfterHours") private var remindAfterHours = 3
    @AppStorage("compressAudio") private var compressAudio = true
    @AppStorage("smarterVocabulary") private var smarterVocabulary = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                NosyMark(size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Settings").font(Theme.display(20, .bold)).tracking(-0.4)
                    Text("Nosy · on-device").font(Theme.mono(11)).foregroundStyle(Theme.muted)
                }
            }

            section("Transcripts") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: "folder.fill").foregroundStyle(Theme.accentText)
                        Text(abbreviated(model.paths.transcripts))
                            .font(Theme.mono(12)).foregroundStyle(Theme.ink)
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
                    settingMenu("Keep recordings", value: retentionLabel) {
                        Picker("Keep recordings", selection: Binding(get: { model.paths.retentionDays }, set: { model.setRetention(days: $0) })) {
                            Text("1 week").tag(7)
                            Text("2 weeks").tag(14)
                            Text("1 month").tag(30)
                            Text("Forever").tag(0)
                        }
                    }
                    settingMenu("Audio quality", value: compressAudio ? "Compact · M4A" : "Full quality · WAV") {
                        Picker("Audio quality", selection: $compressAudio) {
                            Text("Compact — M4A, about 22 MB per hour").tag(true)
                            Text("Full quality — WAV, about 115 MB per hour").tag(false)
                        }
                    }
                    note(compressAudio ? "About 22 MB per hour of audio." : "About 115 MB per hour of audio.")
                    note("Audio is deleted only after its transcript is saved. Unfinished recordings are always kept.")
                }
            }
            section("While recording") {
                VStack(alignment: .leading, spacing: 8) {
                    settingMenu("Remind me after", value: remindAfterHours == 0 ? "Never" : "\(remindAfterHours) hours") {
                        Picker("Remind me after", selection: $remindAfterHours) {
                            Text("2 hours").tag(2)
                            Text("3 hours").tag(3)
                            Text("4 hours").tag(4)
                            Text("Never").tag(0)
                        }
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
        .background(WindowBackdrop())
        .tint(Theme.accentText)
    }

    private var retentionLabel: String {
        switch model.paths.retentionDays {
        case 7: "1 week"
        case 14: "2 weeks"
        case 30: "1 month"
        case 0: "Forever"
        default: "\(model.paths.retentionDays) days"
        }
    }
    private func settingMenu<Options: View>(_ label: String, value: String, @ViewBuilder options: () -> Options) -> some View {
        Menu(content: options) {
            HStack(spacing: 12) {
                Text(label).font(Theme.text(13)).foregroundStyle(Theme.muted)
                Spacer(minLength: 0)
                Text(value).font(Theme.mono(12)).foregroundStyle(Theme.ink)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 12).frame(height: 38)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(InsetButtonStyle()).menuIndicator(.hidden)
        .accessibilityLabel(label).accessibilityValue(value)
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
        if let preview = Snapshot.displayPath(url.path) { return preview }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }
}
