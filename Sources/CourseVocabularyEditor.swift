import SwiftUI
import AppKit

@MainActor
final class VocabularyDraft: ObservableObject, Identifiable {
    let id = UUID()
    let lecture: String
    @Published var text: String { didSet { if text != oldValue { scheduleSave() } } }
    @Published var subjects: SubjectSettings {
        didSet {
            if subjects != oldValue {
                settingsError = nil
                scheduleSave()
            }
        }
    }
    @Published private(set) var settingsError: String?
    @Published private(set) var saveError: String?
    private(set) var hasChanges = false
    private var pendingSave: Task<Void, Never>?
    private let write: (String, SubjectSettings?) throws -> Void

    init(lecture: String, text: String, subjects: SubjectSettings = SubjectSettings(),
         settingsError: String? = nil, write: @escaping (String, SubjectSettings?) throws -> Void) {
        self.lecture = lecture
        self.text = text
        self.subjects = subjects
        self.settingsError = settingsError
        self.write = write
    }

    convenience init(lecture: String, folder: URL, didSave: @escaping () -> Void) {
        let text = (try? String(contentsOf: folder.appendingPathComponent("vocab.txt"), encoding: .utf8)) ?? ""
        var settings = SubjectSettings()
        var loadError: String?
        do { settings = try SubjectSettings.load(folder: folder) }
        catch { settings = SubjectSettings(subject: "general"); loadError = error.localizedDescription }
        self.init(lecture: lecture, text: text, subjects: settings, settingsError: loadError) { text, settings in
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // Keep the exact draft, including whitespace, until the user edits it.
            try Data(text.utf8).write(to: folder.appendingPathComponent("vocab.txt"), options: .atomic)
            if let settings { try settings.save(folder: folder) }
            didSave()
        }
    }

    func selectSubject(_ subject: String) {
        // Selecting General can also repair unreadable settings whose safe fallback
        // is already General, so an explicit selection always schedules a save.
        settingsError = nil
        subjects = SubjectSettings(subject: subject)
        scheduleSave()
    }

    private func scheduleSave() {
        hasChanges = true
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) }
            catch { return }
            self?.flush()
        }
    }

    // Synchronous flush is also used on dismissal and termination; it cannot be
    // cancelled by SwiftUI removing the editor or by a pending debounce task.
    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        guard hasChanges else { return }
        do {
            try write(text, settingsError == nil ? subjects : nil)
            hasChanges = false
            saveError = nil
        } catch {
            saveError = "Couldn't save vocabulary: \(error.localizedDescription)"
        }
    }
}

private struct InfoButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(hovering ? 0.04 : 0)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : (hovering && !reduceMotion ? 1.06 : 1))
            .onHover { inside in withAnimation(Motion.hover) { hovering = inside } }
            .animation(Motion.press, value: configuration.isPressed)
    }
}

private struct SubjectPickerButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isFocused) private var focused
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(hovering && !configuration.isPressed ? 0.025 : 0)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(focused ? Theme.accentText :
                              (hovering ? Theme.accentText.opacity(0.42) : .clear), lineWidth: focused ? 1.6 : 1)
                .allowsHitTesting(false))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onHover { inside in withAnimation(Motion.hover) { hovering = inside } }
            .animation(Motion.press, value: configuration.isPressed)
    }
}

struct VocabularyEditor: View {
    @ObservedObject var draft: VocabularyDraft
    var close: () -> Void
    var inline = false
    @State var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !inline {
                Text("\(draft.lecture) vocabulary")
                    .font(Theme.display(15, .bold)).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("Setting").font(Theme.text(10.5, .medium)).foregroundStyle(Theme.muted)
                    .interactionTarget("vocabulary-setting-caption")
                Spacer(minLength: 0)
                Button {} label: {
                    Text("?").font(Theme.text(10, .semibold))
                        .foregroundStyle(Theme.muted)
                        .frame(width: 18, height: 18)
                        .background(Theme.raised, in: Circle())
                        .overlay(Circle().strokeBorder(Theme.line, lineWidth: 1))
                        .contentShape(Circle())
                }
                .buttonStyle(InfoButtonStyle())
                .tip("Pick a subject or setting to fine tune the vocabulary.")
                .accessibilityLabel("About vocabulary settings")
                .interactionTarget("vocabulary-help")
            }
            Menu {
                subjectOption("auto", "Auto")
                subjectOption("general", "General")
                ForEach(SubjectCatalog.subjects) { subject in
                    subjectOption(subject.id, subject.name)
                }
            } label: {
                HStack(spacing: 8) {
                    Text(subjectTitle).font(Theme.text(12, .medium)).lineLimit(1)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                        .accessibilityHidden(true)
                }
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 12).frame(maxWidth: .infinity).frame(height: 38)
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.line, lineWidth: 1).allowsHitTesting(false))
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .menuStyle(.button).menuIndicator(.hidden)
            .buttonStyle(SubjectPickerButtonStyle())
            .tip("Choose vocabulary subject")
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Subject").accessibilityValue(subjectTitle)
            .interactionTarget("subject-menu")
            VStack(alignment: .leading, spacing: 8) {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold)).frame(width: 12)
                        Text("Custom terms (\(Vocabulary.entries(draft.text).count))")
                            .font(Theme.text(13, .medium))
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 28).contentShape(Rectangle())
                }
                .buttonStyle(InsetButtonStyle())
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                .interactionTarget("custom-terms-disclosure")
                .tip("Edit custom terms")
                if expanded { editor.interactionTarget("custom-terms-editor") }
            }
            if let error = draft.saveError ?? draft.settingsError {
                Text(error).font(Theme.text(11)).foregroundStyle(Theme.coral)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(Theme.text(13))
        .foregroundStyle(Theme.ink)
        .padding(inline ? 12 : 16)
        .frame(width: inline ? nil : 340)
        .fixedSize(horizontal: false, vertical: true)
        .background { if !inline { WindowBackdrop() } }
        .tint(Theme.accentText)
        .onExitCommand { draft.flush(); close() }
        .onDisappear { draft.flush(); expanded = false }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in draft.flush() }
    }

    private var guessedSubject: String {
        SubjectCatalog.guess(draft.lecture).map(SubjectCatalog.name(for:)).joined(separator: " + ")
    }
    private var autoMenuTitle: String {
        guessedSubject.isEmpty ? "Auto" : "\(guessedSubject) (auto)"
    }
    private var subjectTitle: String {
        draft.subjects.subject == "auto" ? autoMenuTitle
            : SubjectCatalog.name(for: draft.subjects.canonicalSubject)
    }
    private func subjectOption(_ id: String, _ title: String) -> some View {
        Button { draft.selectSubject(id) } label: {
            if draft.subjects.subject == id { Label(title, systemImage: "checkmark") }
            else { Text(title) }
        }
        .tip("Choose vocabulary subject")
    }
    private var editor: some View {
        ZStack(alignment: .topLeading) {
            if draft.text.isEmpty {
                Text("Comma or line separated")
                    .foregroundStyle(Theme.faint).padding(.horizontal, 5).padding(.top, 8)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            textEditor
                .accessibilityLabel("Custom vocabulary for \(draft.lecture)")
                .scrollContentBackground(.hidden)
                .tip("Edit vocabulary")
        }
        .font(Theme.text(13))
        .padding(8)
        .frame(height: 112)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line).allowsHitTesting(false))
    }
    @ViewBuilder private var textEditor: some View {
        if #available(macOS 15.0, *) {
            TextEditor(text: $draft.text).writingToolsBehavior(.disabled)
        } else {
            TextEditor(text: $draft.text)
        }
    }
}
