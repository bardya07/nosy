import SwiftUI
import AppKit

// Deterministic design previews. No launch(), microphone, playback, downloads, or real user data.
@MainActor
enum Snapshot {
    static var isRunning = false
    private static var transcriptRoot: String?

    static func displayPath(_ path: String) -> String? {
        guard isRunning, let root = transcriptRoot, path.hasPrefix(root) else { return nil }
        return "~/Nosy" + path.dropFirst(root.count)
    }

    static func run(_ args: [String]) -> Int32 {
        guard let out = args.first else { print("Usage: --headless-snapshot <out.png>"); return 1 }
        _ = NSApplication.shared
        isRunning = true
        let manager = FileManager.default
        let fixture = manager.temporaryDirectory.appendingPathComponent("Nosy-preview-\(UUID().uuidString)")
        let transcripts = fixture.appendingPathComponent("transcripts")
        let emptyTranscripts = fixture.appendingPathComponent("empty-transcripts")
        let support = fixture.appendingPathComponent("support")
        let argumentDomain = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        var previewArguments = argumentDomain
        previewArguments[AppPaths.retentionKey] = 14
        UserDefaults.standard.setVolatileDomain(previewArguments, forName: UserDefaults.argumentDomain)
        let oldTranscripts = ProcessInfo.processInfo.environment["NOSY_TRANSCRIPTS_DIR"]
        let oldSupport = ProcessInfo.processInfo.environment["NOSY_SUPPORT_DIR"]
        setenv("NOSY_TRANSCRIPTS_DIR", transcripts.path, 1)
        setenv("NOSY_SUPPORT_DIR", support.path, 1)
        transcriptRoot = transcripts.path
        defer {
            if let oldTranscripts { setenv("NOSY_TRANSCRIPTS_DIR", oldTranscripts, 1) } else { unsetenv("NOSY_TRANSCRIPTS_DIR") }
            if let oldSupport { setenv("NOSY_SUPPORT_DIR", oldSupport, 1) } else { unsetenv("NOSY_SUPPORT_DIR") }
            UserDefaults.standard.setVolatileDomain(argumentDomain, forName: UserDefaults.argumentDomain)
            try? manager.removeItem(at: fixture)
            transcriptRoot = nil
            isRunning = false
        }
        let date = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 16, minute: 13))!
        let course = transcripts.appendingPathComponent("MBB322")
        let transcript = course.appendingPathComponent("2026-10-23.md")
        let vocabulary = """
        ATP, ADP, NADH, FADH2, acetyl-CoA, glycolysis, citric acid cycle, oxidative phosphorylation,
        mitochondria, cytosol, pyruvate, glucose, phosphofructokinase, hexokinase, citrate synthase,
        allosteric regulation, feedback inhibition, electron transport chain, chemiosmosis, ATP synthase,
        proton gradient, redox, substrate, enzyme, cofactor, coenzyme, active site, activation energy,
        phosphorylation, dephosphorylation, isomerase, kinase, phosphatase, dehydrogenase, Km, Vmax,
        Michaelis-Menten, competitive inhibition, noncompetitive inhibition, gluconeogenesis, glycogen, lactate
        """
        let text = """
        # MBB322 — 2026-10-23

        - Date: 2026-10-23
        - Started: 16:13
        - Length: 1 min

        ## Transcript

        Today we're following the journey from glucose to ATP. We'll connect glycolysis in the cytosol with the citric acid cycle in the mitochondria, then ask how oxidative phosphorylation brings those pathways together.

        > [0:12] Exam hint

        Think of an enzyme as a way to make a reaction happen faster without changing where it ends up. The active site holds a substrate in just the right position, lowering the activation energy. A cofactor can help with that chemistry; a coenzyme is an organic molecule that plays a similar supporting role.

        In glycolysis, hexokinase adds the first phosphate to glucose. Phosphofructokinase provides an important point of allosteric regulation. When ATP is abundant, feedback inhibition slows the pathway. When ADP rises, the cell has a reason to make more ATP. These signals let a pathway respond to demand instead of running at the same speed all day.

        > [0:31] Confused — review

        Pyruvate then supplies acetyl-CoA for the citric acid cycle. Citrate synthase starts that cycle, and a series of redox reactions captures energy in NADH and FADH2. Remember that these molecules carry electrons, rather than storing the final usable energy in the form of ATP.

        The electron transport chain uses that energy to build a proton gradient across the inner mitochondrial membrane. ATP synthase couples the return flow to phosphorylation. We call this chemiosmosis. The membrane matters: without a separation between the two sides, the gradient cannot do useful work.

        For next time, trace each carbon through the pathway and keep a separate account of ATP, NADH and FADH2. Explain why a cell might make lactate, and how gluconeogenesis differs from simply running glycolysis backwards.
        """
        do {
            try manager.createDirectory(at: course, withIntermediateDirectories: true)
            try manager.createDirectory(at: emptyTranscripts, withIntermediateDirectories: true)
            try manager.createDirectory(at: support, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: transcript)
            try Data(vocabulary.utf8).write(to: course.appendingPathComponent("vocab.txt"))
            let paths = AppPaths()
            try paths.prepareSupport()
            let previewRecord = SessionRecord(id: "preview-audio", lecture: "MBB322", session: "2026-10-23",
                startedAt: date, endedAt: date.addingTimeInterval(60), status: .done,
                transcriptPath: transcript.path, markers: [SessionMarker(t: 12, label: "Exam hint"), SessionMarker(t: 31, label: "Confused — review")],
                vocabularyTerms: Vocabulary.entries(vocabulary))
            try previewRecord.save(in: paths)
            let audio = paths.audioFile(previewRecord.id, "wav")
            try Core.wavHeader(pcmBytes: 1_920_000).write(to: audio)
            let audioFile = try FileHandle(forWritingTo: audio)
            try audioFile.seekToEnd()
            try audioFile.write(contentsOf: Data(repeating: 0, count: 1_920_000))
            try audioFile.close()
            let other = transcripts.appendingPathComponent("CHEM281")
            try manager.createDirectory(at: other, withIntermediateDirectories: true)
            let earlier = other.appendingPathComponent("2026-10-21.md")
            try Data(text.replacingOccurrences(of: "MBB322", with: "CHEM281").replacingOccurrences(of: "2026-10-23", with: "2026-10-21").utf8).write(to: earlier)
            try manager.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: transcript.path)
            try manager.setAttributes([.creationDate: date.addingTimeInterval(-172_800), .modificationDate: date.addingTimeInterval(-172_800)], ofItemAtPath: earlier.path)
            try manager.createDirectory(at: transcripts.appendingPathComponent("BISC202"), withIntermediateDirectories: true)
        } catch { print(error); return 1 }
        let longCourse = transcripts.appendingPathComponent("Molecular Biology and Biochemistry — advanced seminar")
        let longURL = longCourse.appendingPathComponent("Review of enzyme regulation and cellular respiration.md")
        do {
            try manager.createDirectory(at: longCourse, withIntermediateDirectories: true)
            try Data("Molecular Biology and Biochemistry".utf8).write(to: longCourse.appendingPathComponent("vocab.txt"))
            try Data(text.utf8).write(to: longURL)
        } catch { print(error); return 1 }

        func model(_ phase: AppPhase, paused: Bool = false, source: RecordingSource = .mic) -> AppModel {
            let model = AppModel()
            model.lectures = ["MBB322", "CHEM281", "BISC202", longCourse.lastPathComponent]
            model.selectedLecture = "MBB322"
            model.session = "2026-10-23"
            model.libraryFocus = transcript
            model.phase = phase
            model.paused = paused
            model.level = phase == .idle ? -160 : -24
            model.duration = phase == .done ? 4_724 : 2_832
            model.levels = (0..<AppModel.waveformLength).map { i in
                i < 7 ? -160 : -42 + 22 * abs(sin(Double(i) * 1.3) * cos(Double(i) * 0.21))
            }
            if phase != .idle {
                model.current = SessionRecord(id: "preview", lecture: "MBB322", session: "2026-10-23", startedAt: date,
                    status: phase == .done ? .done : (phase == .failed ? .failed : .recording),
                    transcriptPath: phase == .done ? transcript.path : nil,
                    markers: [SessionMarker(t: 12, label: "Exam hint"), SessionMarker(t: 31, label: "Confused — review")],
                    vocabularyTerms: Vocabulary.entries(vocabulary))
            }
            model.configurePreview(active: phase == .transcribing ? model.current : nil, source: source)
            if phase == .transcribing { model.transcriptionProgress = 0.62; model.transcriptionElapsed = 151 }
            if phase == .failed { model.errorMessage = "Transcription hit a snag. Your audio is safe — try Retry." }
            return model
        }
        let base = URL(fileURLWithPath: out).deletingPathExtension()
        do { try manager.createDirectory(at: base.deletingLastPathComponent(), withIntermediateDirectories: true) }
        catch { print(error); return 1 }
        let mainStates: [(String, AppPhase)] = [("Ready", .idle), ("Recording", .recording), ("Saved", .done)]
        let previewDefaults = UserDefaults(suiteName: "com.bardya.nosy.preview")!
        // A suite separate from the user's settings; the previews do not change preferences.
        for scheme in [ColorScheme.light, .dark] {
            let mode = scheme == .dark ? "dark" : "light"
            func save<V: View>(_ view: V, _ suffix: String) -> Bool {
                render(view.environment(\.colorScheme, scheme).defaultAppStorage(previewDefaults), scheme: scheme,
                       to: base.appendingPathExtension("\(suffix).png"))
            }
            let states = mainStates.map { (title: $0.0, model: model($0.1)) }
            let sheet = HStack(alignment: .top, spacing: 28) {
                ForEach(states.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 12) {
                        Text("0\(index + 1) / \(states[index].title.uppercased())")
                            .font(Theme.mono(11)).tracking(0.8).foregroundStyle(Theme.navy)
                        PreviewWindow { MainView(model: states[index].model) }
                    }
                }
            }.padding(36).background(PreviewBackdrop())
            guard save(sheet, mode) else { return 1 }
            for state in states {
                guard save(PreviewWindow { MainView(model: state.model) }.padding(36).background(PreviewBackdrop()), "\(state.title.lowercased()).\(mode)") else { return 1 }
            }
            guard save(PreviewWindow { MainView(model: model(.transcribing)) }.padding(36).background(PreviewBackdrop()),
                       "transcribing.\(mode)") else { return 1 }
            let readyInPerson = model(.idle, source: .mic)
            let readyVirtual = model(.idle, source: .both)
            guard save(PreviewWindow { MainView(model: readyInPerson) }.padding(36).background(PreviewBackdrop()), "ready-in-person.\(mode)"),
                  save(PreviewWindow { MainView(model: readyVirtual) }.padding(36).background(PreviewBackdrop()), "ready-virtual.\(mode)") else { return 1 }
            for (name, dropdown) in [("save-to", MainView.Dropdown.saveTo),
                                     ("session", MainView.Dropdown.session),
                                     ("vocabulary", MainView.Dropdown.vocabulary)] {
                let fixture = model(.idle)
                guard save(PreviewWindow { MainView(model: fixture, previewDropdown: dropdown) }
                    .padding(36).background(PreviewBackdrop()), "dropdown-\(name).\(mode)") else { return 1 }
            }
            let longFolder = model(.idle)
            longFolder.selectedLecture = longCourse.lastPathComponent
            guard save(PreviewWindow { MainView(model: longFolder, previewDropdown: .saveTo) }
                .padding(36).background(PreviewBackdrop()), "dropdown-long-folder.\(mode)") else { return 1 }
            let emptyURL = course.appendingPathComponent("Silent.md")
            try? Data("# MBB322\n\n## Transcript\n\n_No speech detected._\n".utf8).write(to: emptyURL)
            let empty = model(.done)
            empty.duration = 4
            empty.current?.markers = []
            empty.current?.vocabularyTerms = []
            empty.current?.transcriptPath = emptyURL.path
            let queued = model(.transcribing)
            let earlier = SessionRecord(id: "earlier", lecture: "CHEM281", session: "2026-10-21", startedAt: date, status: .transcribing)
            queued.configurePreview(active: earlier, queued: [queued.current!])
            let power = model(.transcribing)
            power.configurePreview(active: power.current, pauseReason: "battery low")
            let warnings = model(.recording)
            warnings.errorMessage = "The chosen microphone disconnected. Nosy is using the system microphone."
            warnings.sleepNotice = "Nosy missed 12 min while your Mac was asleep. Keep the lid open while recording."
            warnings.stalled = true
            warnings.setupMessage = "Speech engine missing"
            warnings.recovery = [earlier]
            let long = model(.recording)
            long.current?.lecture = "Molecular Biology and Biochemistry — advanced seminar"
            long.current?.session = "A very long session name for October 23"
            long.current?.markers = (1...8).map { SessionMarker(t: Double($0 * 60), label: "A long marker label to review before the final exam") }
            let minimal = model(.done)
            minimal.current?.markers = []
            minimal.current?.vocabularyTerms = []
            let removed = model(.done)
            removed.current?.transcriptPath = nil
            let longSaved = model(.done)
            longSaved.current?.transcriptPath = longURL.path
            let transcribingHome = model(.transcribing)
            let homeView = PreviewWindow { MainView(model: transcribingHome, previewTranscribingHome: true) }
            guard save(homeView.padding(36).background(PreviewBackdrop()), "transcribing-home.\(mode)") else { return 1 }
            let recovery = model(.idle)
            recovery.transitioning = true
            recovery.recovery = [earlier]
            let newFolder = model(.idle)
            newFolder.selectedLecture = "__new__"
            let noSubject = model(.idle)
            noSubject.selectedLecture = "Seminar"
            for (name, fixture) in [("no-speech", empty), ("queued", queued), ("power-paused", power),
                                    ("warnings", warnings), ("long-recording", long), ("saved-minimal", minimal),
                                    ("removed", removed), ("new-folder", newFolder), ("no-subject", noSubject),
                                    ("long-saved", longSaved), ("recovery", recovery)] {
                guard save(PreviewWindow { MainView(model: fixture) }.padding(36).background(PreviewBackdrop()), "\(name).\(mode)") else { return 1 }
            }
            guard save(PreviewWindow { MainView(model: warnings, bodyHeightLimit: 320) }
                .padding(36).background(PreviewBackdrop()), "small-screen.\(mode)") else { return 1 }
            for step in OnboardingModel.Step.allCases {
                let setup = OnboardingModel()
                setup.step = step
                setup.micStatus = .denied
                guard save(PreviewWindow { OnboardingView(model: model(.idle), setup: setup) }
                    .padding(36).background(PreviewBackdrop()), "setup-\(step).\(mode)") else { return 1 }
            }
            for expanded in [false, true] {
                let draft = VocabularyDraft(lecture: "MBB322", text: "", write: { _, _ in })
                guard save(VocabularyEditor(draft: draft, close: {}, expanded: expanded)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.panelBorder))
                    .padding(36).background(PreviewBackdrop()),
                    "vocabulary-\(expanded ? "expanded" : "collapsed").\(mode)") else { return 1 }
            }
            guard save(LibraryView(model: model(.idle)).frame(width: 720, height: 460)
                .padding(36).background(PreviewBackdrop()), "library-minimum.\(mode)") else { return 1 }
            guard save(PreviewWindow { LibraryView(model: model(.idle), previewQuery: "ATP") }
                    .frame(width: 1040, height: 720).padding(36).background(PreviewBackdrop()), "library-search.\(mode)"),
                  save(PreviewWindow { LibraryView(model: model(.idle)) }
                    .frame(width: 1040, height: 720).padding(36).background(PreviewBackdrop()), "library-reader.\(mode)") else { return 1 }
            setenv("NOSY_TRANSCRIPTS_DIR", emptyTranscripts.path, 1)
            let emptyLibraryModel = AppModel()
            setenv("NOSY_TRANSCRIPTS_DIR", transcripts.path, 1)
            guard save(PreviewWindow { LibraryView(model: emptyLibraryModel) }
                    .frame(width: 1040, height: 720).padding(36).background(PreviewBackdrop()), "library-empty.\(mode)") else { return 1 }
            for phase in [AppPhase.idle, .recording, .done] {
                guard render(MainView(model: model(phase)).environment(\.colorScheme, scheme), scheme: scheme,
                    to: base.appendingPathExtension("native-\(phase).\(mode).png"), native: true) else { return 1 }
            }
            let activity = HStack(alignment: .top, spacing: 28) {
                PreviewWindow { MainView(model: model(.recording, paused: true)) }
                PreviewWindow { MainView(model: model(.transcribing)) }
                PreviewWindow { MainView(model: model(.failed)) }
            }.padding(36).background(PreviewBackdrop())
            guard save(activity, "activity.\(mode)"),
                  save(LibraryView(model: model(.idle)).frame(width: 860, height: 560)
                    .clipShape(RoundedRectangle(cornerRadius: 18)).padding(36).background(PreviewBackdrop()), "library.\(mode)"),
                  save(SettingsView(model: model(.idle)).clipShape(RoundedRectangle(cornerRadius: 18))
                    .padding(36).background(PreviewBackdrop()), "settings.\(mode)"),
                  save(PreviewWindow { OnboardingView(model: model(.idle)) }
                    .padding(36).background(PreviewBackdrop()), "onboarding.\(mode)") else { return 1 }
        }
        return 0
    }
}

private struct PreviewWindow<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        content()
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.panelBorder))
            .overlay(alignment: .topLeading) { TrafficLights().padding(.leading, 16).padding(.top, 16) }
            .shadow(color: Color(hex: 0x0A466E).opacity(0.16), radius: 24, y: 12)
    }
}

// Native vibrancy has no desktop behind it during cacheDisplay. Use the handoff's fallback.
private struct PreviewBackdrop: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        LinearGradient(stops: scheme == .dark ? [
            .init(color: Color(hex: 0x102C48), location: 0), .init(color: Color(hex: 0x184B62), location: 0.48),
            .init(color: Color(hex: 0x183D3C), location: 0.72), .init(color: Color(hex: 0x214D36), location: 1)
        ] : [
            .init(color: Color(hex: 0x5EC4F2), location: 0), .init(color: Color(hex: 0xA8E2F8), location: 0.48),
            .init(color: Color(hex: 0xD8F4E0), location: 0.72), .init(color: Color(hex: 0x7FCB5A), location: 1)
        ], startPoint: .top, endPoint: .bottom)
    }
}

@MainActor
private func render<V: View>(_ view: V, scheme: ColorScheme, to url: URL, native: Bool = false) -> Bool {
    let host = NSHostingView(rootView: view)
    host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
    host.frame = NSRect(origin: .zero, size: host.fittingSize)
    let window = NSWindow(contentRect: host.frame,
        styleMask: native ? [.titled, .closable, .miniaturizable, .fullSizeContentView] : [.borderless], backing: .buffered, defer: false)
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.appearance = host.appearance
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    window.setContentSize(host.fittingSize)
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    if native {
        func surface(in view: NSView) -> NSView? {
            if view is MainWindowChrome.Anchor { return view }
            return view.subviews.lazy.compactMap { surface(in: $0) }.first
        }
        let chrome = surface(in: host)
        print("NATIVE \(url.lastPathComponent): window=\(window.frame.size) content=\(host.bounds.size) fitted=\(host.fittingSize) surface=\(String(describing: chrome?.bounds.size)) regions=\(host.safeAreaRegions)")
        guard abs(host.bounds.height - host.fittingSize.height) < 1,
              let chrome, abs(chrome.bounds.height - host.bounds.height) < 1 else { print("Native surface mismatch"); return false }
    }
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
    host.cacheDisplay(in: host.bounds, to: rep)
    guard let data = rep.representation(using: .png, properties: [:]) else { return false }
    do { try data.write(to: url) } catch { print(error); return false }
    print("SNAPSHOT \(url.path)")
    return true
}

private struct TrafficLights: View {
    var body: some View {
        HStack(spacing: 8) {
            ForEach([Color(hex: 0xFF5F57), Color(hex: 0xFEBC2E), Color(hex: 0x28C840)], id: \.self) {
                Circle().fill($0).frame(width: 12, height: 12)
            }
        }.accessibilityHidden(true)
    }
}
