import SwiftUI
import AppKit

// `--headless-snapshot <out.png>` renders the main window in each state, light and dark,
// on one sheet: used for design previews and README screenshots. Touches no real data.
@MainActor
enum Snapshot {
    static func run(_ args: [String]) -> Int32 {
        guard let out = args.first else { print("Usage: --headless-snapshot <out.png>"); return 1 }
        _ = NSApplication.shared
        let states: [(String, (AppModel) -> Void)] = [
            ("idle", { _ in }),
            ("recording", { model in
                model.phase = .recording; model.duration = 1_947
                model.levels = (0..<AppModel.waveformLength).map { i in -38 + 22 * sin(Double(i) * 0.7) * sin(Double(i) * 0.13) }
                model.level = -20
            }),
            ("transcribing", { model in
                model.phase = .transcribing; model.transcriptionProgress = 0.62; model.transcriptionElapsed = 151
            }),
            ("done", { model in
                model.phase = .done
                model.current = SessionRecord(id: "x", lecture: "Biochemistry", session: model.session, startedAt: Date(), status: .done, transcriptPath: "/tmp/\(model.session).md")
            }),
            ("failed", { model in
                model.phase = .failed
                model.errorMessage = "Transcription hit a snag. Your audio is safe — try Retry."
                model.current = SessionRecord(id: "x", lecture: "Biochemistry", session: model.session, startedAt: Date(), status: .failed)
            }),
        ]
        func row(_ scheme: ColorScheme) -> some View {
            HStack(alignment: .top, spacing: 28) {
                ForEach(states.indices, id: \.self) { index in
                    let model = AppModel()
                    let _ = {
                        model.lectures = ["Biochemistry", "Organic Chemistry", "Physiology"]
                        model.selectedLecture = "Biochemistry"
                        states[index].1(model)
                    }()
                    MainView(model: model)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.black.opacity(0.12)))
                        .overlay(alignment: .topLeading) { TrafficLights().padding(12) }
                        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
                }
            }
            .padding(36)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(scheme == .dark ? Color(white: 0.1) : Color(white: 0.9))
            .environment(\.colorScheme, scheme)
        }
        func extras(_ scheme: ColorScheme) -> some View {
            let model = AppModel()
            return HStack(alignment: .top, spacing: 28) {
                SettingsView(model: model)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
            }
            .padding(36)
            .background(scheme == .dark ? Color(white: 0.1) : Color(white: 0.9))
            .environment(\.colorScheme, scheme)
        }
        for scheme in [ColorScheme.light, .dark] {
            let library = LibraryView(model: AppModel()).frame(width: 860, height: 560)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(36).background(scheme == .dark ? Color(white: 0.1) : Color(white: 0.9))
                .environment(\.colorScheme, scheme)
            if !render(library, scheme: scheme, to: URL(fileURLWithPath: out).deletingPathExtension().appendingPathExtension(scheme == .dark ? "library.dark.png" : "library.light.png")) { return 1 }
        }
        for scheme in [ColorScheme.light, .dark] {
            if !render(extras(scheme), scheme: scheme, to: URL(fileURLWithPath: out).deletingPathExtension().appendingPathExtension(scheme == .dark ? "settings.dark.png" : "settings.light.png")) { return 1 }
        }
        for scheme in [ColorScheme.light, .dark] {
            let host = NSHostingView(rootView: row(scheme))
            host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            let size = host.fittingSize
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = host.appearance
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return 1 }
            host.cacheDisplay(in: host.bounds, to: rep)
            let url = URL(fileURLWithPath: out).deletingPathExtension().appendingPathExtension(scheme == .dark ? "dark.png" : "light.png")
            do { try rep.representation(using: .png, properties: [:])?.write(to: url) } catch { print(error); return 1 }
            print("SNAPSHOT \(url.path)")
        }
        return 0
    }
}

@MainActor
private func render<V: View>(_ view: V, scheme: ColorScheme, to url: URL) -> Bool {
    let host = NSHostingView(rootView: view)
    host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
    host.frame = NSRect(origin: .zero, size: host.fittingSize)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = host.appearance
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
    host.cacheDisplay(in: host.bounds, to: rep)
    do { try rep.representation(using: .png, properties: [:])?.write(to: url) } catch { return false }
    print("SNAPSHOT \(url.path)")
    return true
}

private struct TrafficLights: View {
    var body: some View {
        HStack(spacing: 8) {
            ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18), Color(red: 0.16, green: 0.79, blue: 0.25)], id: \.self) {
                Circle().fill($0).frame(width: 12, height: 12)
            }
        }
    }
}
