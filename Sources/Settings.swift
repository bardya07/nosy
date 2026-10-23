import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @AppStorage("remindAfterHours") private var remindAfterHours = 3
    @AppStorage("compressAudio") private var compressAudio = true

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                NosyMark(size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Settings").font(Theme.display(20, .bold)).tracking(-0.4)
                }
            }

            section("Transcripts") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: "folder.fill").foregroundStyle(Theme.accentText)
                        Text(abbreviated(model.paths.transcripts))
                            .font(Theme.mono(12)).foregroundStyle(Theme.ink)
                            .lineLimit(1).truncationMode(.middle)
                            .tip("Transcript folder")
                        Spacer(minLength: 0)
                    }
                    .fieldChrome()
                    HStack(spacing: 8) {
                        Button("Change…") { model.chooseTranscriptsFolder() }
                            .buttonStyle(PillButtonStyle(kind: .quiet, height: 30, fullWidth: false))
                            .disabled(model.working)
                            .tip(model.working ? "Finish current work" : "Change folder")
                        Button("Show in Finder") { model.revealTranscriptsFolder() }
                            .buttonStyle(PillButtonStyle(kind: .quiet, height: 30, fullWidth: false))
                            .tip("Show in Finder")
                    }
                    note("Folders group transcripts; vocab.txt adds course terms.", tip: "Add course vocabulary")
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
                    note(compressAudio ? "About 22 MB per hour." : "About 115 MB per hour.", tip: "Storage estimate")
                    note("Audio deleted after transcript saves; unfinished stays.", tip: "Audio cleanup rules")
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
                    note("Keep lid open; closed Macs sleep. Mic silence warns.", tip: "Mac sleep behavior")
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
        .menuStyle(.button).font(Theme.mono(11)).buttonStyle(InsetButtonStyle()).menuIndicator(.hidden)
        .tip("Change setting")
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
    private func note(_ text: String, tip: String) -> some View {
        Text(text).font(Theme.text(10)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.tail)
            .tip(tip)
    }
    private func abbreviated(_ url: URL) -> String {
        if let preview = Snapshot.displayPath(url.path) { return preview }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }
}
