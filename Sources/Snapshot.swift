import SwiftUI
import AppKit

// Deterministic design previews. No launch(), microphone, playback, downloads, or real user data.
@MainActor
enum Snapshot {
    static var isRunning = false
    private static var transcriptRoot: String?

    // Focused built in model previews; no other preview, real file, or preference is touched.
    private static func runLocalModels(_ out: String) -> Int32 {
        _ = NSApplication.shared
        isRunning = true
        defer { isRunning = false }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nosy-local-previews-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let base = URL(fileURLWithPath: out).deletingPathExtension()
        try? FileManager.default.createDirectory(at: base.deletingLastPathComponent(), withIntermediateDirectories: true)
        let suite = "com.bardya.nosy.preview.local-models.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for scheme in [ColorScheme.light, .dark] {
            let mode = scheme == .dark ? "dark" : "light"
            for (name, state) in [("missing", LocalModelStore.State.notDownloaded), ("downloading", .downloading(1_248_000_000)),
                                  ("verifying", .verifying), ("downloaded", .downloaded), ("loaded", .loaded),
                                  ("error", .error("SHA256 verification failed. Download the model again."))] {
                let model = AppModel()
                model.summaries.configurePreview(detection: SummaryDetection(checked: true), localModels: LocalModelStore(root: root))
                model.summaries.localModels.configurePreview(.qwen, state: state, diskBytes: state == .notDownloaded || name == "error" ? 0 : name == "downloading" ? 1_248_000_000 : 2_497_281_120)
                defaults.set(SummaryProvider.qwen.rawValue, forKey: SummarySettings.providerKey)
                let view = SettingsView(model: model, pane: .summaries).defaultAppStorage(defaults)
                    .environment(\.colorScheme, scheme).clipShape(RoundedRectangle(cornerRadius: 18))
                    .padding(24).background(PreviewBackdrop())
                guard render(view, scheme: scheme, to: base.appendingPathExtension("\(name).\(mode).png")) else { return 1 }
            }
            defaults.set(SummaryProvider.smol.rawValue, forKey: SummarySettings.providerKey)
            let smol = LocalModelCard(model: .smol, store: LocalModelStore(root: root)).frame(width: SettingsView.columnWidth)
                .environment(\.colorScheme, scheme).padding(24).background(PreviewBackdrop())
            guard render(smol, scheme: scheme, to: base.appendingPathExtension("smol.\(mode).png")) else { return 1 }
            defaults.set(SummaryProvider.off.rawValue, forKey: SummarySettings.providerKey)
            let reader = SummaryBar(transcript: root.appendingPathComponent("lecture.md"), summaries: SummaryCenter(),
                hasSummary: false, showSummary: .constant(false)).defaultAppStorage(defaults)
                .frame(width: 500).environment(\.colorScheme, scheme).padding(24).background(PreviewBackdrop())
            guard render(reader, scheme: scheme, to: base.appendingPathExtension("reader-off.\(mode).png")) else { return 1 }
        }
        print("LOCAL MODEL PREVIEWS PASS: \(base.path)")
        return 0
    }

    static func displayPath(_ path: String) -> String? {
        guard isRunning, let root = transcriptRoot, path.hasPrefix(root) else { return nil }
        return "~/Nosy" + path.dropFirst(root.count)
    }

    static func run(_ args: [String]) -> Int32 {
        guard let out = args.first else { print("Usage: --headless-snapshot <out.png>"); return 1 }
        if args.contains("--local-models") { return runLocalModels(out) }
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

        > [0:31] Confused, review

        Pyruvate then supplies acetyl-CoA for the citric acid cycle. Citrate synthase starts that cycle, and a series of redox reactions captures energy in NADH and FADH2. Remember that these molecules carry electrons, rather than storing the final usable energy in the form of ATP.

        The electron transport chain uses that energy to build a proton gradient across the inner mitochondrial membrane. ATP synthase couples the return flow to phosphorylation. We call this chemiosmosis. The membrane matters: without a separation between the two sides, the gradient cannot do useful work.

        For next time, trace each carbon through the pathway and keep a separate account of ATP, NADH and FADH2. Explain why a cell might make lactate, and how gluconeogenesis differs from simply running glycolysis backwards.
        """
        let summaryFixture = """
        ## Short notes
        - Glucose to ATP: glycolysis in the cytosol feeds the citric acid cycle in the mitochondria.
        - Enzymes speed reactions by lowering activation energy; the active site positions the substrate.
        - Phosphofructokinase is the key control point; ATP inhibits it and ADP signals demand.
        - NADH and FADH2 carry electrons to the electron transport chain, which builds a proton gradient.

        ## Key terms
        - **Activation energy**: the energy barrier an enzyme lowers so a reaction runs faster.
        - **Allosteric regulation**: control of an enzyme by a molecule binding away from the active site.
        - **Chemiosmosis**: ATP synthase using the flow of protons back across the membrane to make ATP.

        ## Likely exam questions
        1. Why is phosphofructokinase a good place to regulate glycolysis?
        2. Trace one glucose carbon from glycolysis to carbon dioxide.
        3. Why does the proton gradient need an intact inner membrane?
        """
        do {
            try manager.createDirectory(at: course, withIntermediateDirectories: true)
            try manager.createDirectory(at: emptyTranscripts, withIntermediateDirectories: true)
            try manager.createDirectory(at: support, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: transcript)
            try Data(vocabulary.utf8).write(to: course.appendingPathComponent("vocab.txt"))
            try Data(SummaryFiles.document(body: summaryFixture, transcript: transcript, provider: .claudeCode, date: date).utf8)
                .write(to: SummaryFiles.url(for: transcript))
            let paths = AppPaths()
            try paths.prepareSupport()
            let previewRecord = SessionRecord(id: "preview-audio", lecture: "MBB322", session: "2026-10-23",
                startedAt: date, endedAt: date.addingTimeInterval(60), status: .done,
                transcriptPath: transcript.path, markers: [SessionMarker(t: 12, label: "Exam hint"), SessionMarker(t: 31, label: "Confused, review")],
                aiMarkers: [AIMarker(t: 4, label: "Enzymes lower activation energy", anchor: KeyMoments.anchor("Think of an enzyme as a way"), approximate: true),
                            AIMarker(t: 40, label: "Glycolysis control points", anchor: KeyMoments.anchor("In glycolysis, hexokinase adds"), approximate: true),
                            AIMarker(t: 300, label: "Electron transport chain", anchor: KeyMoments.anchor("The electron transport chain uses"), approximate: true)],
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
        let longCourse = transcripts.appendingPathComponent("Molecular Biology and Biochemistry, advanced seminar")
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
            model.session = phase == .idle ? "" : "2026-10-23"
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
                    markers: [SessionMarker(t: 12, label: "Exam hint"), SessionMarker(t: 31, label: "Confused, review")],
                    vocabularyTerms: Vocabulary.entries(vocabulary))
            }
            model.configurePreview(active: phase == .transcribing ? model.current : nil, source: source)
            if phase == .transcribing { model.transcriptionProgress = 0.62; model.transcriptionElapsed = 151 }
            if phase == .failed { model.errorMessage = "Transcription hit a snag. Your audio is safe. Try again." }
            return model
        }
        let base = URL(fileURLWithPath: out).deletingPathExtension()
        do { try manager.createDirectory(at: base.deletingLastPathComponent(), withIntermediateDirectories: true) }
        catch { print(error); return 1 }
        let mainStates: [(String, AppPhase)] = [("Ready", .idle), ("Recording", .recording), ("Saved", .done)]
        let previewDefaults = UserDefaults(suiteName: "com.bardya.nosy.preview")!
        // Summary settings fixtures write to their own throwaway suites.
        let apiDefaults = UserDefaults(suiteName: "com.bardya.nosy.preview.summaries-api")!
        let localDefaults = UserDefaults(suiteName: "com.bardya.nosy.preview.summaries-local")!
        // Live level and reminder choices get their own throwaway suites as well.
        let technicalLevel = UserDefaults(suiteName: "com.bardya.nosy.preview.level-technical")!
        let customReminder = UserDefaults(suiteName: "com.bardya.nosy.preview.custom-reminder")!
        defer {
            apiDefaults.removePersistentDomain(forName: "com.bardya.nosy.preview.summaries-api")
            localDefaults.removePersistentDomain(forName: "com.bardya.nosy.preview.summaries-local")
            technicalLevel.removePersistentDomain(forName: "com.bardya.nosy.preview.level-technical")
            customReminder.removePersistentDomain(forName: "com.bardya.nosy.preview.custom-reminder")
        }
        technicalLevel.set(LevelDisplay.technical.rawValue, forKey: LevelDisplay.storageKey)
        customReminder.set(45, forKey: ReminderInterval.storageKey)
        // Claude Desktop states come from fixtures, so the previews never depend on what this Mac has installed.
        let helperURL = fixture.appendingPathComponent("nosy-mcp")
        let absentConfig = fixture.appendingPathComponent("claude_desktop_config.json")
        let connectedConfig = fixture.appendingPathComponent("connected/claude_desktop_config.json")
        try? manager.createDirectory(at: connectedConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let connectedData = try? ClaudeDesktopConfig.adding(to: nil, command: helperURL.path) {
            try? connectedData.write(to: connectedConfig)
        }
        func desktopConnector(config: URL, installed: Bool, running: Bool) -> ClaudeConnector {
            ClaudeConnector(configURL: config, helperURL: helperURL,
                            desktop: { ClaudeDesktopApp.Status(installed: installed, running: running) })
        }
        apiDefaults.set(SummaryProvider.anthropic.rawValue, forKey: SummarySettings.providerKey)
        apiDefaults.set(true, forKey: SummarySettings.automaticKey)
        apiDefaults.set(true, forKey: SummarySection.questions.storageKey)
        apiDefaults.set("Use British spelling.", forKey: SummarySettings.customKey)
        localDefaults.set(SummaryProvider.ollama.rawValue, forKey: SummarySettings.providerKey)
        localDefaults.set("qwen3:8b", forKey: SummaryProvider.ollama.modelKey)
        let summaryDetection = SummaryDetection(executables: [.claudeCode: URL(fileURLWithPath: "/opt/homebrew/bin/claude")],
                                                localModels: [.ollama: ["llama3.2:3b", "qwen3:8b"]], checked: true)
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
                            .font(Theme.text(11)).tracking(0.8).foregroundStyle(Theme.navy)
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
            guard save(PreviewWindow { MainView(model: model(.idle), previewDropping: true) }
                    .padding(36).background(PreviewBackdrop()), "drop-main.\(mode)") else { return 1 }
            // The live level in both readings: the everyday estimate first, then the technical dBFS value.
            guard save(PreviewWindow { MainView(model: model(.recording)) }
                    .padding(36).background(PreviewBackdrop()), "recording-estimate.\(mode)"),
                  save(PreviewWindow { MainView(model: model(.recording)) }.defaultAppStorage(technicalLevel)
                    .padding(36).background(PreviewBackdrop()), "recording-technical.\(mode)") else { return 1 }
            let readyRoom = model(.idle, source: .mic)
            let readyMac = model(.idle, source: .both)
            guard save(PreviewWindow { MainView(model: readyRoom) }.padding(36).background(PreviewBackdrop()), "ready-room-audio.\(mode)"),
                  save(PreviewWindow { MainView(model: readyMac) }.padding(36).background(PreviewBackdrop()), "ready-mac-audio.\(mode)") else { return 1 }
            for tip in ["Microphone", "Start recording", "Home", "Open GitHub", "All your transcripts"] {
                let slug = tip.lowercased().replacingOccurrences(of: " ", with: "-")
                guard save(PreviewWindow {
                    MainView(model: model(.idle)).environment(\.previewTipText, tip)
                }.padding(36).background(PreviewBackdrop()), "tip-\(slug).\(mode)") else { return 1 }
            }
            guard save(PreviewWindow {
                MainView(model: model(.idle)).environment(\.previewTipText, "Settings (⌘,)")
            }.padding(36).background(PreviewBackdrop()), "tip-settings.\(mode)") else { return 1 }
            let sessionTip = "Use today's date"
            guard save(PreviewWindow {
                MainView(model: model(.idle), previewDropdown: .session)
                    .environment(\.previewTipText, sessionTip)
            }.padding(36).background(PreviewBackdrop()), "tip-use-todays-date.\(mode)") else { return 1 }
            let settingTip = "Pick a subject or setting to fine tune the vocabulary."
            guard save(PreviewWindow {
                MainView(model: model(.idle), previewDropdown: .vocabulary)
                    .environment(\.previewTipText, settingTip)
            }.padding(36).background(PreviewBackdrop()), "tip-vocabulary-setting.\(mode)") else { return 1 }
            for expanded in [false, true] {
                let fixture = model(.idle)
                guard save(PreviewWindow {
                    MainView(model: fixture, previewSaveToExpanded: expanded)
                }.padding(36).background(PreviewBackdrop()),
                    expanded ? "dropdown-save-to.\(mode)" : "save-to-wheel-closed.\(mode)") else { return 1 }
            }
            let folderList = model(.idle)
            guard save(PreviewWindow {
                MainView(model: folderList, previewSaveToExpanded: true, previewFolderListOpen: true)
            }.padding(36).background(PreviewBackdrop()), "dropdown-folder-list.\(mode)") else { return 1 }
            // Tips inside the scrolling details must still draw whole, not cut off at the scroll edge.
            let destinationTip = "Change where transcripts are saved"
            guard save(PreviewWindow {
                MainView(model: model(.idle), previewSaveToExpanded: true).environment(\.previewTipText, destinationTip)
            }.padding(36).background(PreviewBackdrop()), "tip-choose-destination.\(mode)") else { return 1 }
            let setupTip = model(.idle)
            setupTip.setupMessage = "Speech engine missing"
            guard save(PreviewWindow {
                MainView(model: setupTip).environment(\.previewTipText, "Open setup")
            }.padding(36).background(PreviewBackdrop()), "tip-open-setup.\(mode)") else { return 1 }
            for (name, dropdown) in [("session", MainView.Dropdown.session),
                                     ("vocabulary", MainView.Dropdown.vocabulary)] {
                let fixture = model(.idle)
                guard save(PreviewWindow { MainView(model: fixture, previewDropdown: dropdown) }
                    .padding(36).background(PreviewBackdrop()), "dropdown-\(name).\(mode)") else { return 1 }
            }
            guard save(PreviewWindow {
                MainView(model: model(.idle), previewSessionRequired: true)
            }.padding(36).background(PreviewBackdrop()), "session-required.\(mode)") else { return 1 }
            // Microphone panel: the device list with the current choice checked, and the meter while recording.
            let microphones = [AudioInputs.Device(id: "preview-yeti", name: "Yeti Stereo Microphone"),
                               AudioInputs.Device(id: "preview-airpods", name: "AirPods Pro")]
            let micIdle = model(.idle)
            micIdle.configurePreview(source: .mic, microphones: microphones, selectedMicrophone: "preview-yeti")
            let micRecording = model(.recording)
            micRecording.configurePreview(source: .mic, microphones: microphones, selectedMicrophone: "preview-yeti")
            guard save(PreviewWindow { MainView(model: micIdle, previewDropdown: .microphone) }
                .padding(36).background(PreviewBackdrop()), "dropdown-microphone.\(mode)"),
                  save(PreviewWindow { MainView(model: micRecording, previewDropdown: .microphone) }
                .padding(36).background(PreviewBackdrop()), "dropdown-microphone-recording.\(mode)") else { return 1 }
            // A folder row with its trash button showing (the hover state).
            guard save(PreviewWindow {
                MainView(model: model(.idle), previewSaveToExpanded: true, previewFolderListOpen: true,
                         previewHoveredFolder: "CHEM281")
            }.padding(36).background(PreviewBackdrop()), "dropdown-folder-delete.\(mode)") else { return 1 }
            // Vocabulary opens even before a folder has a name, and says what to do.
            let unnamedFolder = model(.idle)
            unnamedFolder.selectedLecture = "__new__"
            unnamedFolder.newLecture = ""
            guard save(PreviewWindow { MainView(model: unnamedFolder, previewDropdown: .vocabulary) }
                .padding(36).background(PreviewBackdrop()), "dropdown-vocabulary-no-folder.\(mode)") else { return 1 }
            guard save(PreviewWindow { MainView(model: model(.idle), previewDropdown: .vocabulary, previewVocabularyExpanded: true) }
                .padding(36).background(PreviewBackdrop()), "dropdown-vocabulary-expanded.\(mode)") else { return 1 }
            let newFolderPanel = model(.idle)
            newFolderPanel.selectedLecture = "__new__"
            newFolderPanel.newLecture = "New seminar"
            guard save(PreviewWindow {
                MainView(model: newFolderPanel, previewEnteringNewFolderName: true)
            }
                .padding(36).background(PreviewBackdrop()), "dropdown-new-folder.\(mode)") else { return 1 }
            let longFolder = model(.idle)
            longFolder.selectedLecture = longCourse.lastPathComponent
            guard save(PreviewWindow { MainView(model: longFolder) }
                .padding(36).background(PreviewBackdrop()), "dropdown-long-folder.\(mode)") else { return 1 }
            let emptyURL = course.appendingPathComponent("Silent.md")
            try? Data("# MBB322\n\n- Date: 2026-10-23\n- Length: 1 min\n\n## Transcript\n\n_No speech detected._\n".utf8).write(to: emptyURL)
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
            long.current?.lecture = "Molecular Biology and Biochemistry, advanced seminar"
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
            let previousLibrary = fixture.appendingPathComponent("Previous library")
            let locations = model(.idle)
            locations.configurePreview(libraryLocations: [transcripts, previousLibrary])
            guard save(LibraryView(model: locations).frame(width: 720, height: 460)
                .padding(36).background(PreviewBackdrop()), "library-locations.\(mode)") else { return 1 }
            guard save(PreviewWindow { LibraryView(model: model(.idle), previewQuery: "ATP") }
                    .frame(width: 1040, height: 720).padding(36).background(PreviewBackdrop()), "library-search.\(mode)"),
                  save(PreviewWindow { LibraryView(model: model(.idle)) }
                    .frame(width: 1040, height: 720).padding(36).background(PreviewBackdrop()), "library-reader.\(mode)"),
                  save(PreviewWindow { LibraryView(model: model(.idle), previewHoveredFolder: "MBB322") }
                    .frame(width: 1040, height: 720).padding(36).background(PreviewBackdrop()), "library-folder-delete-hover.\(mode)"),
                  save(PreviewWindow { LibraryView(model: model(.idle), previewDropping: true) }
                    .frame(width: 1040, height: 720).padding(36).background(PreviewBackdrop()), "drop-library.\(mode)") else { return 1 }
            // A folder row with keyboard focus: Delete moves it to the Trash after the confirmation.
            guard save(PreviewWindow { LibraryView(model: model(.idle), previewFocusedFolder: "MBB322") }
                    .frame(width: 1040, height: 720).padding(36).background(PreviewBackdrop()), "library-folder-focused.\(mode)") else { return 1 }
            // The folder Trash confirmation, drawn from the same alert the owner sees.
            let trashConfirmation = LectureFolderTrash.makeConfirmation("MBB322")
            guard renderAlert(trashConfirmation.alert, scheme: scheme, to: base.appendingPathExtension("trash-confirmation.\(mode).png")) else { return 1 }
            setenv("NOSY_TRANSCRIPTS_DIR", emptyTranscripts.path, 1)
            let emptyLibraryModel = AppModel()
            setenv("NOSY_TRANSCRIPTS_DIR", transcripts.path, 1)
            guard save(PreviewWindow { LibraryView(model: emptyLibraryModel) }
                    .frame(width: 1040, height: 720).padding(36).background(PreviewBackdrop()), "library-empty.\(mode)") else { return 1 }
            let silentLibrary = model(.idle)
            silentLibrary.libraryFocus = emptyURL
            guard save(PreviewWindow { LibraryView(model: model(.idle), previewCollapsed: true) }
                    .frame(width: 1040, height: 720).padding(36).background(PreviewBackdrop()), "library-collapsed.\(mode)"),
                  save(PreviewWindow { LibraryView(model: silentLibrary) }
                    .frame(width: 1040, height: 720).padding(36).background(PreviewBackdrop()), "library-no-speech.\(mode)"),
                  save(PreviewWindow { LibraryView(model: model(.idle)) }
                    .environment(\.previewTipText, "Show in Finder")
                    .frame(width: 1040, height: 720).padding(36).background(PreviewBackdrop()), "library-tip.\(mode)") else { return 1 }
            for phase in [AppPhase.idle, .recording, .done] {
                guard render(MainView(model: model(phase)).environment(\.colorScheme, scheme), scheme: scheme,
                    to: base.appendingPathExtension("native-\(phase).\(mode).png"), native: true) else { return 1 }
            }
            let summarizing = model(.idle)
            let chemistry = transcripts.appendingPathComponent("CHEM281").appendingPathComponent("2026-10-21.md")
            summarizing.libraryFocus = chemistry
            summarizing.summaries.configurePreview(detection: summaryDetection,
                status: [chemistry.standardizedFileURL.path: .running(step: 2, total: 4)])
            let summaryModel = model(.idle)
            summaryModel.summaries.configurePreview(detection: summaryDetection, keyTail: SummaryKeychain.masked("sk-ant-preview-key-7Qx2"))
            let activity = HStack(alignment: .top, spacing: 28) {
                PreviewWindow { MainView(model: model(.recording, paused: true)) }
                PreviewWindow { MainView(model: model(.transcribing)) }
                PreviewWindow { MainView(model: model(.failed)) }
            }.padding(36).background(PreviewBackdrop())
            guard save(activity, "activity.\(mode)"),
                  save(PreviewWindow { LibraryView(model: model(.idle), previewSummary: true) }
                    .frame(width: 1040, height: 720).padding(36).background(PreviewBackdrop()), "library-summary.\(mode)"),
                  save(PreviewWindow { LibraryView(model: summarizing) }
                    .frame(width: 1040, height: 720).padding(36).background(PreviewBackdrop()), "library-summarizing.\(mode)"),
                  save(LibraryView(model: model(.idle), previewSummary: true).frame(width: 720, height: 460)
                    .padding(36).background(PreviewBackdrop()), "library-summary-minimum.\(mode)"),
                  save(SettingsView(model: summaryModel, pane: .summaries).defaultAppStorage(apiDefaults).clipShape(RoundedRectangle(cornerRadius: 18))
                    .padding(36).background(PreviewBackdrop()), "settings-summaries.\(mode)"),
                  save(SettingsView(model: summaryModel, pane: .summaries).defaultAppStorage(localDefaults).clipShape(RoundedRectangle(cornerRadius: 18))
                    .padding(36).background(PreviewBackdrop()), "settings-summaries-local.\(mode)"),
                  save(SettingsView(model: model(.idle), connector: desktopConnector(config: absentConfig, installed: true, running: false))
                    .defaultAppStorage(customReminder).clipShape(RoundedRectangle(cornerRadius: 18))
                    .padding(36).background(PreviewBackdrop()), "settings-reminder-custom.\(mode)"),
                  save(LibraryView(model: model(.idle)).frame(width: 860, height: 560)
                    .clipShape(RoundedRectangle(cornerRadius: 18)).padding(36).background(PreviewBackdrop()), "library.\(mode)"),
                  save(SettingsView(model: model(.idle), connector: desktopConnector(config: absentConfig, installed: true, running: false))
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .padding(36).background(PreviewBackdrop()), "settings.\(mode)"),
                  save(SettingsView(model: model(.idle), connector: desktopConnector(config: absentConfig, installed: true, running: false),
                    pane: .connect).clipShape(RoundedRectangle(cornerRadius: 18))
                    .padding(36).background(PreviewBackdrop()), "settings-connect.\(mode)"),
                  save(SettingsView(model: model(.idle), connector: desktopConnector(config: connectedConfig, installed: true, running: true),
                    pane: .connect).clipShape(RoundedRectangle(cornerRadius: 18))
                    .padding(36).background(PreviewBackdrop()), "settings-connect-added.\(mode)"),
                  save(SettingsView(model: model(.idle), connector: desktopConnector(config: absentConfig, installed: false, running: false),
                    pane: .connect).clipShape(RoundedRectangle(cornerRadius: 18))
                    .padding(36).background(PreviewBackdrop()), "settings-connect-missing.\(mode)"),
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
            .overlay(alignment: .topLeading) { TrafficLights().padding(.leading, 16).frame(height: 44).allowsHitTesting(false) }
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

// Draws an alert's own window, which SwiftUI cannot host. The alert is never shown on screen.
@MainActor
private func renderAlert(_ alert: NSAlert, scheme: ColorScheme, to url: URL) -> Bool {
    alert.window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
    alert.layout()
    guard let view = alert.window.contentView else { return false }
    view.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
    view.cacheDisplay(in: view.bounds, to: rep)
    guard let data = rep.representation(using: .png, properties: [:]) else { return false }
    do { try data.write(to: url) } catch { print(error); return false }
    print("SNAPSHOT \(url.path)")
    return true
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
