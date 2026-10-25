import AVFoundation
import Foundation
import UniformTypeIdentifiers

enum AudioImport {
    static func supports(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: url.pathExtension)
        return type?.conforms(to: .audio) == true
            || type?.conforms(to: .movie) == true
            || type?.conforms(to: .video) == true
    }

    static func sessionName(for url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        return name.isEmpty ? "Imported audio" : name
    }

    static func destinationLecture(selectedTreeLecture: String?, currentLecture: String,
                                   availableLectures: [String]) -> String {
        if let selectedTreeLecture, !selectedTreeLecture.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return selectedTreeLecture
        }
        let current = currentLecture.trimmingCharacters(in: .whitespacesAndNewlines)
        if !current.isEmpty && current != "__new__" {
            return availableLectures.first { $0.caseInsensitiveCompare(current) == .orderedSame } ?? current
        }
        if let first = availableLectures.first { return first }
        return "Imported Audio"
    }
}

enum AudioFiles {
    static func importRecording(from source: URL, lecture: String, session: String, paths: AppPaths) throws -> SessionRecord {
        try Task.checkCancellation()
        let lecture = try Core.sanitize(lecture)
        let session = try Core.sanitize(session)
        try paths.validateLectureFolder(lecture)
        try paths.prepareSupport()
        try FileManager.default.createDirectory(at: paths.lectureFolder(lecture), withIntermediateDirectories: true)
        let id = Core.newID(in: paths)
        do {
            let wav = try decode(source: source, id: id, paths: paths)
            try Task.checkCancellation()
            let startedAt = (try? source.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            let duration = Core.duration(pcmBytes: max(0, Core.fileSize(wav) - 44))
            let record = SessionRecord(id: id, lecture: lecture, session: session, startedAt: startedAt,
                                       endedAt: startedAt.addingTimeInterval(duration), status: .failed, error: nil)
            try record.save(in: paths)
            return record
        } catch {
            try? deleteAudio(id: id, paths: paths)
            throw error
        }
    }

    static func compress(id: String, paths: AppPaths) throws {
        let wav = paths.audioFile(id, "wav")
        let m4a = paths.audioFile(id, "m4a")
        let temporary = paths.audio.appendingPathComponent(".\(id)-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: temporary) }
        var expectedDuration = 0.0
        // Scope both files so the encoder is closed (including its final AAC packet and
        // container metadata) before verifying or publishing the result.
        try autoreleasepool {
            let input = try AVAudioFile(forReading: wav)
            expectedDuration = Double(input.length) / input.processingFormat.sampleRate
            guard input.length > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 8192) else {
                throw LectureError.message("Recorded audio is empty or unreadable.")
            }
            let output = try AVAudioFile(forWriting: temporary, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: input.processingFormat.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 32_000
            ])
            defer { if #available(macOS 15, *) { output.close() } }
            while input.framePosition < input.length {
                try input.read(into: buffer)
                guard buffer.frameLength > 0 else { throw LectureError.message("Recorded audio ended unexpectedly.") }
                try output.write(from: buffer)
            }
        }
        let verified = try AVAudioFile(forReading: temporary)
        guard verified.length > 0, verified.processingFormat.sampleRate > 0,
              abs(Double(verified.length) / verified.processingFormat.sampleRate - expectedDuration) <= 0.1,
              let probe = AVAudioPCMBuffer(pcmFormat: verified.processingFormat, frameCapacity: 1024) else {
            throw LectureError.message("Compressed audio could not be verified; the WAV is kept.")
        }
        try verified.read(into: probe)
        guard probe.frameLength > 0 else {
            throw LectureError.message("Compressed audio could not be read; the WAV is kept.")
        }
        verified.framePosition = max(0, verified.length - 1024)
        try verified.read(into: probe)
        guard probe.frameLength > 0 else {
            throw LectureError.message("The end of the compressed audio could not be read; the WAV is kept.")
        }
        if #available(macOS 15, *) { verified.close() }
        let durable = try FileHandle(forReadingFrom: temporary)
        defer { try? durable.close() }
        try durable.synchronize()
        try durable.close()
        try publish(temporary, to: m4a)
        try FileManager.default.removeItem(at: wav)
    }

    static func playable(id: String, paths: AppPaths) -> URL? {
        ["m4a", "wav"].map { paths.audioFile(id, $0) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func decodeToWAV(id: String, paths: AppPaths) throws -> URL {
        let wav = paths.audioFile(id, "wav")
        if FileManager.default.fileExists(atPath: wav.path) { return wav }
        if FileManager.default.fileExists(atPath: paths.audioFile(id, "pcm").path) {
            return try Core.finalizeWAV(id: id, paths: paths)
        }
        let m4a = paths.audioFile(id, "m4a")
        if FileManager.default.fileExists(atPath: m4a.path) { return try decode(source: m4a, id: id, paths: paths) }
        throw LectureError.message("Recorded audio is missing.")
    }

    /// A louder copy of a quiet recording, or nil when it's already loud enough.
    /// Far-away lecture mics can sit near -50 dBFS, where whisper loops on one phrase.
    static func boosted(_ wav: URL, to target: URL) throws -> URL? {
        let source = try AVAudioFile(forReading: wav, commonFormat: .pcmFormatInt16, interleaved: true)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 65_536) else { return nil }
        // Gain from the 99.95th-percentile level, so a single bump or clap can't block the boost.
        var histogram = [Int](repeating: 0, count: 32_769)
        var total = 0
        while source.framePosition < source.length {
            try source.read(into: buffer)
            guard buffer.frameLength > 0, let samples = buffer.int16ChannelData?[0] else {
                throw LectureError.message("Recorded audio ended unexpectedly.")
            }
            let count = Int(buffer.frameLength) * Int(source.processingFormat.channelCount)
            for i in 0..<count { histogram[Int(samples[i].magnitude)] += 1 }
            total += count
        }
        guard total > 0 else { return nil }
        var level = 0, seen = 0
        for (value, count) in histogram.enumerated().reversed() {
            seen += count
            if Double(seen) >= Double(total) * 0.0005 { level = max(value, 1); break }
        }
        let gain = min(29_000 / Double(level), 40)
        guard gain > 1.5 else { return nil }

        let input = try AVAudioFile(forReading: wav, commonFormat: .pcmFormatInt16, interleaved: true)
        let output = try AVAudioFile(forWriting: target, settings: input.processingFormat.settings,
                                     commonFormat: .pcmFormatInt16, interleaved: true)
        defer { if #available(macOS 15, *) { output.close() } }
        while input.framePosition < input.length {
            try input.read(into: buffer)
            guard buffer.frameLength > 0, let samples = buffer.int16ChannelData?[0] else {
                throw LectureError.message("Recorded audio ended unexpectedly.")
            }
            for i in 0..<(Int(buffer.frameLength) * Int(input.processingFormat.channelCount)) {
                samples[i] = Int16(max(-32_767, min(32_767, (Double(samples[i]) * gain).rounded())))
            }
            try output.write(from: buffer)
        }
        return target
    }

    static func deleteAudio(id: String, paths: AppPaths) throws {
        guard FileManager.default.fileExists(atPath: paths.audio.path) else { return }
        for url in try FileManager.default.contentsOfDirectory(at: paths.audio, includingPropertiesForKeys: nil)
            where url.lastPathComponent.hasPrefix(id + ".") {
            try FileManager.default.removeItem(at: url)
        }
    }

    private static func decode(source: URL, id: String, paths: AppPaths) throws -> URL {
        let temporary = paths.audio.appendingPathComponent(".\(id)-\(UUID().uuidString).pcm")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
            throw LectureError.message("Could not create imported audio file.")
        }
        let file = try FileHandle(forWritingTo: temporary)
        defer { try? file.close() }
        if let audio = try? AVAudioFile(forReading: source) {
            try decode(audio, to: file)
        } else {
            try decodeAsset(source, to: file)
        }
        guard Core.fileSize(temporary) > 0 else { throw LectureError.message("The audio track is empty.") }
        try file.synchronize()
        try file.close()
        try publish(temporary, to: paths.audioFile(id, "pcm"))
        return try Core.finalizeWAV(id: id, paths: paths)
    }

    private static func decode(_ audio: AVAudioFile, to file: FileHandle) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: audio.processingFormat, to: format),
              let input = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 8192),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else {
            throw LectureError.message("This audio format could not be decoded.")
        }
        var readError: Error?
        while true {
            try Task.checkCancellation()
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { requested, inputStatus in
                guard audio.framePosition < audio.length else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    let remaining = AVAudioFrameCount(min(Int64(input.frameCapacity), audio.length - audio.framePosition))
                    try audio.read(into: input, frameCount: min(requested, remaining))
                    inputStatus.pointee = input.frameLength > 0 ? .haveData : .endOfStream
                    return input.frameLength > 0 ? input : nil
                } catch {
                    readError = error
                    inputStatus.pointee = .endOfStream
                    return nil
                }
            }
            if let readError { throw readError }
            if let conversionError { throw conversionError }
            guard status != .error else { throw LectureError.message("Audio conversion failed.") }
            if output.frameLength > 0, let samples = output.int16ChannelData?[0] {
                try file.write(contentsOf: Data(bytes: samples, count: Int(output.frameLength) * 2))
            }
            if status == .endOfStream { return }
        }
    }

    private static func decodeAsset(_ source: URL, to file: FileHandle) throws {
        let asset = AVURLAsset(url: source)
        // This API is deliberately synchronous to preserve the throwing import API.
        // AVAssetReader decompresses/resamples in bounded sample buffers, including video containers.
        guard let track = asset.tracks(withMediaType: .audio).first else {
            throw LectureError.message("This file has no readable audio track.")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw LectureError.message("This audio format could not be decoded.") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? LectureError.message("Could not read the audio track.") }
        defer { reader.cancelReading() }
        while try autoreleasepool(invoking: { () throws -> Bool in
            try Task.checkCancellation()
            guard let sample = output.copyNextSampleBuffer() else { return false }
            guard let block = CMSampleBufferGetDataBuffer(sample) else {
                throw LectureError.message("Could not decode audio samples.")
            }
            var offset = 0
            let length = CMBlockBufferGetDataLength(block)
            while offset < length {
                var data = Data(count: min(65_536, length - offset))
                let count = data.count
                let status = data.withUnsafeMutableBytes {
                    CMBlockBufferCopyDataBytes(block, atOffset: offset, dataLength: count, destination: $0.baseAddress!)
                }
                guard status == kCMBlockBufferNoErr else { throw LectureError.message("Could not read decoded audio samples.") }
                try file.write(contentsOf: data)
                offset += count
            }
            return true
        }) { }
        guard reader.status == .completed else {
            throw reader.error ?? LectureError.message("Audio decoding did not finish.")
        }
    }

    private static func publish(_ temporary: URL, to target: URL) throws {
        let status = temporary.path.withCString { from in target.path.withCString { to in rename(from, to) } }
        guard status == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
}
