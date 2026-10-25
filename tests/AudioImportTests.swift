import Foundation
import AVFoundation
import CoreVideo

@main
enum AudioImportTests {
    static func main() async throws {
        func check(_ value: Bool, _ message: String) {
            guard value else { fatalError("FAIL: \(message)") }
        }

        let movie = URL(fileURLWithPath: "/tmp/Lecture Week 4.mp4")
        check(AudioImport.sessionName(for: movie) == "Lecture Week 4", "session name comes from filename without extension")
        check(AudioImport.sessionName(for: URL(fileURLWithPath: "/tmp/lecture.final.wav")) == "lecture.final",
              "session name keeps earlier filename dots")
        check(AudioImport.supports(URL(fileURLWithPath: "/tmp/lecture.wav")), "WAV is audio")
        check(AudioImport.supports(URL(fileURLWithPath: "/tmp/lecture.m4a")), "M4A is audio")
        check(AudioImport.supports(movie), "MP4 is video")
        check(AudioImport.supports(URL(fileURLWithPath: "/tmp/lecture.mov")), "MOV is video")
        check(!AudioImport.supports(URL(fileURLWithPath: "/tmp/notes.txt")), "text files are rejected")
        check(!AudioImport.supports(URL(string: "https://example.com/lecture.mp3")!), "non file URLs are rejected")
        check(AudioImport.destinationLecture(selectedTreeLecture: "CHEM281", currentLecture: "MBB322",
                                             availableLectures: ["MBB322", "CHEM281"]) == "CHEM281",
              "selected tree folder is the import target")
        check(AudioImport.destinationLecture(selectedTreeLecture: nil, currentLecture: "MBB322",
                                             availableLectures: ["CHEM281"]) == "MBB322",
              "main window folder is the fallback target")
        check(AudioImport.destinationLecture(selectedTreeLecture: nil, currentLecture: "__new__",
                                             availableLectures: ["MBB322"]) == "MBB322",
              "existing folder is used when the main window has no current folder")
        check(AudioImport.destinationLecture(selectedTreeLecture: nil, currentLecture: "mbb322",
                                             availableLectures: ["MBB322"]) == "MBB322",
              "current folder matching ignores case")
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("nosy-media-tests-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: root) }
        let paths = AppPaths(environment: ["NOSY_SUPPORT_DIR": root.appendingPathComponent("support").path,
                                           "NOSY_TRANSCRIPTS_DIR": root.appendingPathComponent("transcripts").path])
        try paths.prepareSupport()
        // One hour, written in small blocks: exercise the importer's bounded streaming path.
        let long = root.appendingPathComponent("Long silence.wav")
        try Core.wavHeader(pcmBytes: 3600 * Core.bytesPerSecond).write(to: long)
        let handle = try FileHandle(forWritingTo: long)
        try handle.seekToEnd()
        let zeros = Data(repeating: 0, count: Int(Core.bytesPerSecond))
        for _ in 0..<3600 { try handle.write(contentsOf: zeros) }
        try handle.close()
        let longRecord = try AudioFiles.importRecording(from: long, lecture: "Long", session: "Silence", paths: paths)
        check(abs(Core.audioDuration(id: longRecord.id, paths: paths) - 3600) < 0.01, "one hour of silent audio imports without a duration limit")
        check(Core.fileSize(long) == 3600 * Core.bytesPerSecond + 44, "import preserves the long source")
        let before = Set(try manager.contentsOfDirectory(atPath: paths.audio.path))
        let corrupt = root.appendingPathComponent("Corrupt.mp4")
        try Data("not media".utf8).write(to: corrupt)
        let empty = root.appendingPathComponent("Empty.wav")
        try Core.wavHeader(pcmBytes: 0).write(to: empty)
        for source in [corrupt, empty] {
            var refused = false
            do { _ = try AudioFiles.importRecording(from: source, lecture: "Odd", session: "Bad", paths: paths) }
            catch { refused = true }
            check(refused, "corrupt and empty media fail cleanly")
            check(Set(try manager.contentsOfDirectory(atPath: paths.audio.path)) == before, "failed imports leave no partial audio or sidecar")
        }
        let video = root.appendingPathComponent("No audio.mov")
        let writer = try AVAssetWriter(outputURL: video, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
                                                                          AVVideoWidthKey: 16, AVVideoHeightKey: 16])
        writer.add(input)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                                         kCVPixelBufferWidthKey as String: 16, kCVPixelBufferHeightKey as String: 16])
        check(writer.startWriting(), "video fixture starts")
        writer.startSession(atSourceTime: .zero)
        var pixel: CVPixelBuffer?
        check(CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32ARGB, nil, &pixel) == kCVReturnSuccess, "video fixture allocates")
        CVPixelBufferLockBaseAddress(pixel!, [])
        memset(CVPixelBufferGetBaseAddress(pixel!), 0, CVPixelBufferGetDataSize(pixel!))
        CVPixelBufferUnlockBaseAddress(pixel!, [])
        for frame in 0..<2 {
            for _ in 0..<100 where !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(20)) }
            check(adaptor.append(pixel!, withPresentationTime: CMTime(value: Int64(frame), timescale: 1)), "video fixture writes a frame")
        }
        input.markAsFinished()
        await writer.finishWriting()
        check(writer.status == .completed, "video fixture completes")
        var refusedVideo = false
        do { _ = try AudioFiles.importRecording(from: video, lecture: "Video", session: "No audio", paths: paths) }
        catch { refusedVideo = error.localizedDescription.contains("no readable audio track") }
        check(refusedVideo, "video without an audio track explains the failure")
        print("AUDIO IMPORT TESTS PASS: names, media filtering, destination, one hour of silence, corrupt/empty media and video without audio")
    }
}
