import SwiftUI
import AppKit

enum SettingsFocusTarget: String, Equatable, Hashable, Identifiable {
    case aiFeatures = "settings-ai-features"
    case provider = "settings-summary-provider"
    case providerModel = "settings-provider-model"
    case localModel = "settings-local-model"
    case providerKey = "settings-provider-key"

    var id: String { rawValue }
}

struct SettingsFocusRequest: Equatable {
    let id: Int
    let target: SettingsFocusTarget
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var updater = SparkleUpdater.shared
    var connector = ClaudeConnector.standard
    var showsHeading = true
    var focusRequest: SettingsFocusRequest?
    var onFocusHandled: (Int) -> Void = { _ in }
    @AppStorage(ReminderInterval.storageKey) private var reminderMinutes = ReminderInterval.defaultMinutes
    @AppStorage(LectureFolderTrash.askKey) private var askBeforeDeleting = true
    @AppStorage("compressAudio") private var compressAudio = true
    @AppStorage(TranscriptionQuality.storageKey) private var transcriptionQualityRaw = TranscriptionQuality.detailed.rawValue
    @AppStorage(AIFeatures.storageKey) private var aiFeaturesEnabled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var customReminder = false
    @State private var connection: ClaudeConnector.Status = .notAdded
    @State private var desktop = ClaudeDesktopApp.Status(installed: false, running: false)
    @State private var restartingDesktop = false
    @State private var connectionMessage: String?
    @State private var connectionFailed = false
    @State private var pane: Pane
    @State private var highlightedTarget: SettingsFocusTarget?
    @State private var handledFocusID = 0
    @State private var highlightID = 0
    private static let customReminderTag = -1

    init(model: AppModel, connector: ClaudeConnector = .standard, pane: Pane = .general, showsHeading: Bool = true,
         focusRequest: SettingsFocusRequest? = nil, onFocusHandled: @escaping (Int) -> Void = { _ in }) {
        self.model = model
        self.connector = connector
        self.showsHeading = showsHeading
        self.focusRequest = focusRequest
        self.onFocusHandled = onFocusHandled
        _pane = State(initialValue: pane)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if showsHeading {
                HStack(spacing: 12) {
                    NosyMark(size: 40)
                    Text("Settings").font(Theme.display(20, .bold)).tracking(-0.4)
                }
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Pane.allCases) { pane in paneButton(pane) }
                }
                .frame(width: Self.sidebarWidth, alignment: .leading)
                Group {
                    if showsHeading {
                        paneContent
                    } else {
                        ScrollViewReader { scroll in
                            ScrollView { paneContent }
                                .scrollIndicators(.never)
                                .onAppear { handleFocus(focusRequest, using: scroll) }
                                .onChange(of: focusRequest) { _, request in handleFocus(request, using: scroll) }
                        }
                    }
                }
                .frame(width: Self.columnWidth, alignment: .topLeading)
            }
        }
        .font(Theme.text(13))
        .foregroundStyle(Theme.ink)
        .padding(24)
        .frame(width: Self.width, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: showsHeading)
        .background(WindowBackdrop())
        .tint(Theme.accentText)
        .tipContainerBounds()
    }

    private var paneContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            switch pane {
            case .general: generalPane
            case .summaries: summariesPane
            case .connect: connectPane
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
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
        .interactionTarget("settings-pane-\(option.rawValue)")
        .accessibilityLabel(option.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var generalPane: some View {
        section("Updates") {
            VStack(alignment: .leading, spacing: 10) {
                settingToggle("Check for updates automatically", isOn: Binding(
                    get: { updater.automaticallyChecks },
                    set: { updater.automaticallyChecks = $0 }
                ), tip: "Check for updates automatically")
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .buttonStyle(PillButtonStyle(kind: .quiet, height: 30, fullWidth: false))
            }
        }
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
                settingToggle("Ask before deleting folders", isOn: $askBeforeDeleting, tip: "Confirm before a folder moves to the Trash")
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
        section("Transcription") {
            settingMenu("Transcription quality", value: transcriptionQuality.title) {
                Button {
                    transcriptionQualityRaw = TranscriptionQuality.fast.rawValue
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Fast").font(Theme.text(12, .semibold))
                        Text("Lighter on battery and heat").font(Theme.text(10)).foregroundStyle(Theme.muted)
                    }
                }
                .accessibilityLabel("Fast")
                .accessibilityValue("Lighter on battery and heat")
                Button {
                    transcriptionQualityRaw = TranscriptionQuality.detailed.rawValue
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Detailed").font(Theme.text(12, .semibold))
                        Text("A bit more careful, works the Mac harder").font(Theme.text(10)).foregroundStyle(Theme.muted)
                    }
                }
                .accessibilityLabel("Detailed")
                .accessibilityValue("A bit more careful, works the Mac harder")
            }
        }
        section("While recording") {
            VStack(alignment: .leading, spacing: 8) {
                settingMenu("Remind me", value: customReminder ? "Custom" : ReminderInterval.label(reminderMinutes)) {
                    Picker("Remind me", selection: reminderChoice) {
                        ForEach(ReminderInterval.presets, id: \.self) { minutes in
                            Text(ReminderInterval.label(minutes)).tag(minutes)
                        }
                        Text(ReminderInterval.label(ReminderInterval.never)).tag(ReminderInterval.never)
                        Text("Custom").tag(Self.customReminderTag)
                    }
                }
                if customReminder {
                    HStack(spacing: 12) {
                        Text(ReminderInterval.label(reminderMinutes))
                            .font(Theme.text(13)).foregroundStyle(Theme.ink)
                        Spacer(minLength: 0)
                        Stepper("Custom reminder interval", value: $reminderMinutes,
                                in: ReminderInterval.customRange, step: ReminderInterval.customStep)
                            .labelsHidden()
                    }
                    .padding(.horizontal, 12).frame(height: 38)
                    .background(Theme.raised, in: RoundedRectangle(cornerRadius: 10))
                }
                Text("Keep your Mac open while recording. Nosy warns you if the mic goes silent.")
                    .font(Theme.text(10)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .tip("Mac sleep behavior")
            }
            .onAppear {
                customReminder = !ReminderInterval.presets.contains(reminderMinutes) && reminderMinutes != ReminderInterval.never
            }
        }
    }

    // Presets and Never are fixed choices; Custom opens the stepper. Choosing Custom from Never starts at the default hour.
    private var reminderChoice: Binding<Int> {
        Binding(get: { customReminder ? Self.customReminderTag : reminderMinutes },
                set: { choice in
                    if choice == Self.customReminderTag {
                        customReminder = true
                        if reminderMinutes == ReminderInterval.never { reminderMinutes = ReminderInterval.defaultMinutes }
                    } else {
                        customReminder = false
                        reminderMinutes = choice
                    }
                })
    }

    private var summariesPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: $aiFeaturesEnabled) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("AI features").font(Theme.text(13, .semibold)).foregroundStyle(Theme.ink)
                    Text("Summaries and key moments. Off keeps everything on this Mac.")
                        .font(Theme.text(10)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch).tint(Theme.accentText)
            .accessibilityLabel("AI features")
            .interactionTarget("settings-ai-features")
            .modifier(SettingsFocusHighlight(isHighlighted: highlightedTarget == .aiFeatures))
            .id(SettingsFocusTarget.aiFeatures)
            section("Summaries") {
                SummarySettingsSection(summaries: model.summaries, highlightedTarget: highlightedTarget)
            }
            .disabled(!aiFeaturesEnabled)
            .opacity(aiFeaturesEnabled ? 1 : 0.45)
        }
        .onChange(of: aiFeaturesEnabled) { _, enabled in
            model.summaries.aiFeaturesChanged(enabled)
        }
    }

    private var connectPane: some View {
        section("Connect your AI") {
            VStack(alignment: .leading, spacing: 12) {
                connectionStatus
                switch connection {
                case .added:
                    connectedSteps
                case .notAdded:
                    if desktop.installed {
                        Button("Add to Claude Desktop") { changeConnection(adding: true) }
                            .buttonStyle(PillButtonStyle(kind: .primary, height: 30, fullWidth: false))
                            .tip("Let Claude Desktop read your transcripts")
                    } else {
                        Link(destination: ClaudeDesktopApp.downloadURL) {
                            Label(ConnectionCopy.downloadLabel, systemImage: "arrow.up.right.square")
                                .font(Theme.text(12, .semibold))
                                .foregroundStyle(Theme.accentText)
                        }
                        .tip("Open the Claude Desktop download page")
                    }
                case .unreadable:
                    EmptyView()
                }
                Button("Copy setup for other apps") { copyConnectionSetup() }
                    .buttonStyle(PillButtonStyle(kind: .quiet, height: 30, fullWidth: false))
                    .tip("Copy the setup for Cursor and Claude Code")
                if !connectionNote.isEmpty {
                    Text(connectionNote)
                        .font(Theme.text(10)).foregroundStyle(connectionIsProblem ? Theme.stop : Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .onAppear(perform: refreshConnection)
        }
    }

    // The state line: a green check once Nosy is connected, otherwise what is missing.
    private var connectionStatus: some View {
        let connected = connection == .added
        return HStack(spacing: 10) {
            Image(systemName: connected ? "checkmark.circle.fill" : (connectionIsProblem ? "exclamationmark.triangle.fill" : "circle"))
                .foregroundStyle(connected ? Theme.green : (connectionIsProblem ? Theme.stop : Theme.muted))
                .accessibilityHidden(true)
            Text(ConnectionCopy.title(connection, installed: desktop.installed))
                .font(Theme.text(12, connected ? .semibold : .regular))
                .foregroundStyle(connected ? Theme.savedText : Theme.ink)
                .lineLimit(1)
            Spacer(minLength: 0)
            if connected {
                Button("Remove") { changeConnection(adding: false) }
                    .buttonStyle(PillButtonStyle(kind: .quiet, height: 26, fullWidth: false))
                    .tip("Remove Nosy from Claude Desktop")
            }
        }
        .fieldChrome()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Claude Desktop connection")
        .accessibilityValue(ConnectionCopy.title(connection, installed: desktop.installed))
    }

    // Shown once Nosy is connected: what to do in Claude Desktop, then the actions that make it happen.
    private var connectedSteps: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(ConnectionCopy.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).").font(Theme.text(12, .semibold)).foregroundStyle(Theme.muted).monospacedDigit()
                        Text(step).font(Theme.text(12)).foregroundStyle(Theme.ink)
                    }
                }
            }
            .padding(.leading, 2)
            HStack(spacing: 8) {
                if desktop.running {
                    Button(restartingDesktop ? "Restarting…" : "Restart Claude Desktop") { restartDesktop() }
                        .buttonStyle(PillButtonStyle(kind: .primary, height: 30, fullWidth: false))
                        .disabled(restartingDesktop)
                        .tip("Quit Claude Desktop and open it again")
                }
                Button("Copy example prompt") { copyExamplePrompt() }
                    .buttonStyle(PillButtonStyle(kind: .quiet, height: 30, fullWidth: false))
                    .tip("Copy a question to try in Claude Desktop")
            }
            if !desktop.running {
                Text(ConnectionCopy.closedNote)
                    .font(Theme.text(10)).foregroundStyle(Theme.muted)
            }
        }
    }

    static let width: CGFloat = sidebarWidth + 16 + columnWidth + 48
    static let sidebarWidth: CGFloat = 168
    static let columnWidth: CGFloat = 392

    private var connectionNote: String {
        if let connectionMessage { return connectionMessage }
        if case .unreadable(let message) = connection { return message }
        if connection == .notAdded, !desktop.installed { return ConnectionCopy.installNote }
        return ""
    }
    private var connectionIsProblem: Bool {
        if connectionMessage != nil { return connectionFailed }
        if case .unreadable = connection { return true }
        return false
    }
    private func refreshConnection() {
        connection = connector.status()
        desktop = connector.desktop()
    }
    private func changeConnection(adding: Bool) {
        do {
            if adding { try connector.add() } else { try connector.remove() }
            connectionMessage = adding ? nil : ConnectionCopy.removedNote
            connectionFailed = false
        } catch {
            connectionMessage = error.localizedDescription
            connectionFailed = true
        }
        refreshConnection()
    }
    private func restartDesktop() {
        restartingDesktop = true
        Task {
            let outcome = await ClaudeDesktopApp.restart()
            restartingDesktop = false
            refreshConnection()
            switch outcome {
            case .restarted:
                connectionMessage = "Claude Desktop restarted."
                connectionFailed = false
            case .notRunning:
                connectionMessage = ConnectionCopy.closedNote
                connectionFailed = false
            case .stillRunning:
                connectionMessage = "Claude Desktop is still open. Quit it there, then try again."
                connectionFailed = true
            case .failed:
                connectionMessage = "Couldn't reopen Claude Desktop. Open it from your Applications folder."
                connectionFailed = true
            }
        }
    }
    private func copyExamplePrompt() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(ConnectionCopy.examplePrompt, forType: .string)
        connectionMessage = ConnectionCopy.copiedPrompt
        connectionFailed = false
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
    private var transcriptionQuality: TranscriptionQuality {
        TranscriptionQuality(rawValue: transcriptionQualityRaw) ?? .detailed
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
    // A setting with a switch, in the same field style as the menus above it.
    private func settingToggle(_ label: String, isOn: Binding<Bool>, tip: String) -> some View {
        HStack(spacing: 12) {
            Text(label).font(Theme.text(13)).foregroundStyle(Theme.muted)
            Spacer(minLength: 0)
            Toggle(label, isOn: isOn).labelsHidden().toggleStyle(.switch).tint(Theme.accentText)
        }
        .padding(.horizontal, 12).frame(height: 38)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 10))
        .tip(tip)
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

    private func handleFocus(_ request: SettingsFocusRequest?, using scroll: ScrollViewProxy) {
        guard let request, request.id != handledFocusID else { return }
        handledFocusID = request.id
        DispatchQueue.main.async {
            guard focusRequest?.id == request.id else { return }
            if reduceMotion {
                scroll.scrollTo(request.target, anchor: .center)
            } else {
                withAnimation(.easeInOut(duration: 0.24)) {
                    scroll.scrollTo(request.target, anchor: .center)
                }
            }
            highlightedTarget = request.target
            highlightID = request.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                guard highlightID == request.id else { return }
                highlightedTarget = nil
            }
            onFocusHandled(request.id)
        }
    }
}

struct SettingsFocusHighlight: ViewModifier {
    let isHighlighted: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .inset(by: -6)
                    .fill(isHighlighted ? Theme.warmFill.opacity(0.58) : .clear)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .inset(by: -6)
                    .strokeBorder(isHighlighted ? Theme.warmText.opacity(0.58) : .clear, lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
            .animation(reduceMotion ? nil : Motion.state(reduceMotion), value: isHighlighted)
    }
}
