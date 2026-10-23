import SwiftUI
import AppKit

@MainActor
final class VocabularyDraft: ObservableObject {
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
        catch { settings = SubjectSettings(subject: "off"); loadError = error.localizedDescription }
        self.init(lecture: lecture, text: text, subjects: settings, settingsError: loadError) { text, settings in
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // Keep the exact draft, including whitespace, until the user edits it.
            try Data(text.utf8).write(to: folder.appendingPathComponent("vocab.txt"), options: .atomic)
            if let settings { try settings.save(folder: folder) }
            didSave()
        }
    }

    func selectSubject(_ subject: String) {
        // Selecting None can also repair unreadable settings whose safe fallback
        // is already off, so an explicit selection always schedules a save.
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

struct VocabularyEditor: View {
    @ObservedObject var draft: VocabularyDraft
    var close: () -> Void
    @State var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(draft.lecture) vocabulary")
                .font(Theme.display(15, .bold)).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Text("Subject").foregroundStyle(Theme.muted)
                Spacer(minLength: 0)
                Picker("Subject", selection: Binding(get: { draft.subjects.subject }, set: {
                    draft.selectSubject($0)
                })) {
                    Text(autoMenuTitle).tag("auto")
                    ForEach(SubjectCatalog.subjects) { Text($0.name).tag($0.id) }
                    Text("None").tag("off")
                }
                .labelsHidden().pickerStyle(.menu)
                .frame(maxWidth: 220)
                .accessibilityLabel("Subject").accessibilityValue(subjectTitle)
            }
            DisclosureGroup(isExpanded: $expanded) {
                editor.padding(.top, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } label: {
                Text("Custom terms (\(Vocabulary.entries(draft.text).count))")
                    .font(Theme.text(13, .medium))
            }
            .animation(Motion.state(reduceMotion), value: expanded)
            if let error = draft.saveError ?? draft.settingsError {
                Text(error).font(Theme.text(11)).foregroundStyle(Theme.coral)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(Theme.text(13))
        .foregroundStyle(Theme.ink)
        .padding(16)
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
        .background(WindowBackdrop())
        .tint(Theme.accentText)
        .onExitCommand { draft.flush(); close() }
        .onDisappear { draft.flush(); expanded = false }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in draft.flush() }
    }

    private var guessedSubject: String {
        SubjectCatalog.subjects.filter { SubjectCatalog.guess(draft.lecture).contains($0.id) }
            .map(\.name).joined(separator: " + ")
    }
    private var autoMenuTitle: String {
        guessedSubject.isEmpty ? "Auto" : "\(guessedSubject) (auto)"
    }
    private var subjectTitle: String {
        draft.subjects.subject == "auto" ? autoMenuTitle
            : SubjectCatalog.subjects.first { $0.id == draft.subjects.subject }?.name ?? "None"
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
        }
        .font(Theme.text(13))
        .padding(8)
        .frame(height: 112)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line))
    }
    @ViewBuilder private var textEditor: some View {
        if #available(macOS 15.0, *) {
            TextEditor(text: $draft.text).writingToolsBehavior(.disabled)
        } else {
            TextEditor(text: $draft.text)
        }
    }
}
