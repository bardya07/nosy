import Foundation
import AVFoundation

private actor RecordingFailure {
    var message: String?
    func set(_ message: String) { self.message = message }
}

enum Headless {
    static func run(_ args: [String]) async -> Int32 {
        if args.first == "--headless-inputs" {
            for device in AudioInputs.list() { print("INPUT \(device.id)\t\(device.name)") }
            if let device = AudioInputs.systemDefault() { print("DEFAULT \(device.id)") }
            return 0
        }
        let paths = AppPaths()
        do {
            try Core.migrateLegacy(paths: paths)
            try paths.prepareSupport()
            switch args.first {
            case "--headless-recover":
                let records = try Core.recover(paths: paths)
                try Core.applyRetention(paths: paths)
                for record in records { print("RECOVERED \(record.id) \(record.status.rawValue) \(Core.timer(Core.audioDuration(id: record.id, paths: paths)))") }
                print("RECOVERY PASS: \(records.count) recoverable recording(s)")
            case "--headless-transcribe":
                guard args.count == 2 else { throw LectureError.message("Usage: --headless-transcribe <id>") }
                let record = try SessionRecord.read(paths.audioFile(args[1], "json"))
                let result = try await Transcriber.transcribe(record: record, paths: paths)
                print("TRANSCRIPTION PASS: \(result.transcriptPath ?? "")")
            case "--headless-import":
                guard args.count == 4 else { throw LectureError.message("Usage: --headless-import <file> <lecture> <session>") }
                let record = try AudioFiles.importRecording(from: URL(fileURLWithPath: args[1]), lecture: args[2], session: args[3], paths: paths)
                let result = try await Transcriber.transcribe(record: record, paths: paths)
                print("IMPORT PASS: \(result.transcriptPath ?? "")")
            case "--headless-record":
                guard args.count == 4, let seconds = Double(args[1]), seconds > 0, seconds <= 86_400 else {
                    throw LectureError.message("Usage: --headless-record <seconds> <lecture> <session>")
                }
                let permission: Bool
                switch AVCaptureDevice.authorizationStatus(for: .audio) {
                case .authorized: permission = true
                case .notDetermined: permission = await AVCaptureDevice.requestAccess(for: .audio)
                default: permission = false
                }
                guard permission else { print("SKIPPED: microphone permission denied or restricted"); return 77 }
                let lecture = try Core.sanitize(args[2])
                let session = try Core.sanitize(args[3])
                try FileManager.default.createDirectory(at: paths.lectureFolder(lecture), withIntermediateDirectories: true)
                var record = SessionRecord(id: Core.newID(in: paths), lecture: lecture, session: session, startedAt: Date(), status: .recording)
                try record.save(in: paths)
                let failure = RecordingFailure()
                let recorder = Recorder { event in
                    if case .failed(let message, _) = event { Task { await failure.set(message) } }
                }
                try await recorder.start(at: paths.audioFile(record.id, "pcm"))
                print("RECORDING \(record.id)")
                let iterations = Int(ceil(seconds * 5))
                for _ in 0..<iterations {
                    try await Task.sleep(for: .milliseconds(200))
                    if let message = await failure.message { throw LectureError.message(message) }
                }
                _ = try await recorder.stop()
                record.endedAt = Date()
                _ = try await Transcriber.transcribe(record: record, paths: paths)
                print("RECORDING PASS")
            default: throw LectureError.message("Unknown headless mode")
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("ERROR: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }
}
