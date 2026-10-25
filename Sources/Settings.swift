import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var model: AppModel
    var connector = ClaudeConnector.standard
    @AppStorage("remindAfterHours") private var remindAfterHours = 3
    @AppStorage("compressAudio") private var compressAudio = true
    @State private var connection: ClaudeConnector.Status = .notAdded
    @State private var connectionMessage: String?
    @State private var connectionFailed = false
    @State private var pane: Pane

    init(model: AppModel, connector: ClaudeConnector = .standard, pane: Pane = .general) {
        self.model = model
        self.connector = connector
        _pane = State(initialValue: pane)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                NosyMark(size: 40)
                Text("Settings").font(Theme.display(20, .bold)).tracking(-0.4)
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Pane.allCases) { pane in paneButton(pane) }
                }
                .frame(width: Self.sidebarWidth, alignment: .leading)
                VStack(alignment: .leading, spacing: 18) {
                    switch pane {
                    case .general: generalPane
                    case .summaries: summariesPane
                    case .connect: connectPane
                    }
                }
                .frame(width: Self.columnWidth, alignment: .topLeading)
            }
        }
        .font(Theme.text(13))
        .foregroundStyle(Theme.ink)
        .padding(24)
        .frame(width: Self.sidebarWidth + 16 + Self.columnWidth + 48, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background(WindowBackdrop())
        .tint(Theme.accentText)
        .tipContainerBounds()
    }

    enum Pane: String, CaseIterable, Identifiable {
        case general, summaries, connect
        var id: String { rawValue }
        var title: String {
            switch self {
            case .general: "General"
            case .summaries: "Summaries"
            case .connect: "Connect your AI"
            }
        }
        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .summaries: "text.badge.star"
            case .connect: "link"
            }
        }
    }

    private func paneButton(_ option: Pane) -> some View {
        let selected = option == pane
        return Button { pane = option } label: {
            HStack(spacing: 8) {
                Image(systemName: option.symbol).font(.system(size: 12, weight: .semibold))
                    .frame(width: 16)
                    .foregroundStyle(selected ? Theme.accentText : Theme.muted)
                Text(option.title).font(Theme.text(13, selected ? .semibold : .regular))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).frame(height: 32)
            .background(selected ? Theme.raised : .clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Theme.line : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(InsetButtonStyle())
        .accessibilityLabel(option.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var generalPane: some View {
        section("Transcripts") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "folder.fill").foregroundStyle(Theme.accentText).accessibilityHidden(true)
                    Text(abbreviated(model.paths.transcripts))
                        .font(Theme.text(12)).foregroundStyle(Theme.ink)
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
                        Text("Compact M4A, about 22 MB per hour").tag(true)
                        Text("Full quality WAV, about 115 MB per hour").tag(false)
                    }
                }
                note(compressAudio ? "About 22 MB per hour." : "About 115 MB per hour.", tip: "Storage estimate")
                note("Unfinished audio stays. Saved audio follows this limit.", tip: "Audio cleanup rules")
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

    private var summariesPane: some View {
        section("Summaries") {
            SummarySettingsSection(summaries: model.summaries)
        }
    }

    private var connectPane: some View {
        section("Connect your AI") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: connection == .added ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(connection == .added ? Theme.green : Theme.muted)
                    Text(connectionTitle).font(Theme.text(12)).foregroundStyle(Theme.ink)
                    Spacer(minLength: 0)
                }
                .fieldChrome()
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Claude Desktop connection")
                .accessibilityValue(connectionTitle)
                switch connection {
                case .added:
                    Button("Remove") { changeConnection(adding: false) }
                        .buttonStyle(PillButtonStyle(kind: .quiet, height: 30, fullWidth: false))
                        .tip("Remove Nosy from Claude Desktop")
                case .notAdded:
                    Button("Add to Claude Desktop") { changeConnection(adding: true) }
                        .buttonStyle(PillButtonStyle(kind: .primary, height: 30, fullWidth: false))
                        .tip("Let Claude Desktop read your transcripts")
                case .unreadable:
                    EmptyView()
                }
                Button("Copy setup for other apps") { copyConnectionSetup() }
                    .buttonStyle(PillButtonStyle(kind: .quiet, height: 30, fullWidth: false))
                    .tip("Copy the setup for Cursor and Claude Code")
                Text(connectionNote)
                    .font(Theme.text(10)).foregroundStyle(connectionIsProblem ? Theme.stop : Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .onAppear { connection = connector.status() }
        }
    }

    static let sidebarWidth: CGFloat = 168
    static let columnWidth: CGFloat = 392

    private var connectionTitle: String {
        switch connection {
        case .added: "Added"
        case .notAdded: "Not installed"
        case .unreadable: "Claude Desktop settings need fixing"
        }
    }
    private var connectionNote: String {
        if let connectionMessage { return connectionMessage }
        switch connection {
        case .added: return "Restart Claude Desktop to load Nosy."
        case .notAdded: return "Restart Claude Desktop after adding."
        case .unreadable(let message): return message
        }
    }
    private var connectionIsProblem: Bool {
        if connectionMessage != nil { return connectionFailed }
        if case .unreadable = connection { return true }
        return false
    }
    private func changeConnection(adding: Bool) {
        do {
            if adding { try connector.add() } else { try connector.remove() }
            connectionMessage = adding ? "Added. Restart Claude Desktop to use Nosy." : "Removed. Restart Claude Desktop to apply."
            connectionFailed = false
        } catch {
            connectionMessage = error.localizedDescription
            connectionFailed = true
        }
        connection = connector.status()
    }
    private func copyConnectionSetup() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(ClaudeDesktopConfig.setupText(command: connector.helperPath), forType: .string)
        connectionMessage = "Copied the setup."
        connectionFailed = false
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
                Text(value).font(Theme.text(12)).foregroundStyle(Theme.ink)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.muted)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12).frame(height: 38)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label).accessibilityValue(value)
        }
        .menuStyle(.button).font(Theme.text(11)).buttonStyle(InsetButtonStyle()).menuIndicator(.hidden)
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
