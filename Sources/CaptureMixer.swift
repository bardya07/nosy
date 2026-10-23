import AVFoundation
import Foundation

// Used only under Recorder's lock. AVAudioConverter supplies its anti-aliasing filter;
// timestamp correction below only adjusts the small difference between hardware clocks.
final class CaptureConverter {
    private let mono: AVAudioFormat
    private let output: AVAudioFormat
    private let converter: AVAudioConverter

    init(format: AVAudioFormat) throws {
        guard format.sampleRate > 0, format.channelCount > 0, format.commonFormat == .pcmFormatFloat32,
              let mono = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1),
              let output = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
              let converter = AVAudioConverter(from: mono, to: output) else {
            throw LectureError.message("This recording source has no usable audio format.")
        }
        self.mono = mono; self.output = output; self.converter = converter
        converter.primeMethod = .none
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
    }
    func reset() { converter.reset() }
    func convert(_ input: AVAudioPCMBuffer) throws -> [Float] {
        guard let mixed = Self.mono(input, format: mono),
              let result = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: AVAudioFrameCount(ceil(Double(input.frameLength) * 16_000 / input.format.sampleRate)) + 64) else {
            throw LectureError.message("Could not allocate audio conversion buffer.")
        }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: result, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return mixed
        }
        guard status != .error, error == nil, let data = result.floatChannelData?[0] else {
            throw error ?? LectureError.message("Audio conversion failed.")
        }
        return Array(UnsafeBufferPointer(start: data, count: Int(result.frameLength)))
    }
    static func mono(_ input: AVAudioPCMBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = Int(input.frameLength), channels = Int(input.format.channelCount)
        guard channels > 0, let source = input.floatChannelData,
              let mono = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: input.frameLength),
              let target = mono.floatChannelData?[0] else { return nil }
        mono.frameLength = input.frameLength
        for frame in 0..<frames {
            var sum: Float = 0
            for channel in 0..<channels {
                let value = input.format.isInterleaved ? source[0][frame * input.stride + channel] : source[channel][frame]
                sum += value.isFinite ? value : 0
            }
            target[frame] = sum / Float(channels)
        }
        return mono
    }
}

// A bounded, host-clock-addressed ring, never an unbounded FIFO. Gaps are silence;
// stale/late samples cannot play later. Small drift is resampled between consecutive
// host timestamps, keeping independently clocked mic and tap aligned over long calls.
struct CaptureTrack {
    private static let capacity = 32_000
    private var samples = [Float](repeating: 0, count: capacity)
    private var tags = [Int64](repeating: -1, count: capacity)
    private var pending: (start: Int64, samples: [Float])?

    mutating func push(_ values: [Float], at start: Int64, cursor: Int64) {
        guard !values.isEmpty else { return }
        if let previous = pending {
            let span = start - previous.start
            let expected = previous.samples.count
            let count = abs(Double(span) - Double(expected)) <= max(4, Double(expected) * 0.01) ? Int(span) : expected
            place(previous.samples, at: previous.start, count: max(1, count), cursor: cursor)
        }
        pending = (start, values)
    }
    mutating func flush(before end: Int64, cursor: Int64) {
        if let pending, pending.start < end {
            place(pending.samples, at: pending.start, count: pending.samples.count, cursor: cursor)
            self.pending = nil
        }
    }
    private mutating func place(_ values: [Float], at start: Int64, count: Int, cursor: Int64) {
        let lower = max(0, cursor - start), upper = min(Int64(count), cursor + Int64(Self.capacity) - start)
        guard lower < upper else { return }
        for offset in Int(lower)..<Int(upper) {
            let position = Double(offset) * Double(values.count) / Double(count)
            let index = min(values.count - 1, Int(position))
            let next = min(values.count - 1, index + 1)
            let fraction = Float(position - Double(index))
            let frame = start + Int64(offset), slot = Int(frame % Int64(Self.capacity))
            guard frame >= 0 else { continue }
            samples[slot] = values[index] + (values[next] - values[index]) * fraction
            tags[slot] = frame
        }
    }
    func sample(at frame: Int64) -> Float {
        let slot = Int(frame % Int64(Self.capacity))
        return tags[slot] == frame ? samples[slot] : 0
    }
}

struct CaptureBalance {
    private var micPower: Float = 0
    private var macPower: Float = 0
    private var micGain: Float = 1
    private var macGain: Float = 1
    private var limiter: Float = 1

    mutating func mix(mic: Float, mac: Float, both: Bool) -> Int16 {
        let mic = mic.isFinite ? mic : 0, mac = mac.isFinite ? mac : 0
        var value = mac
        if both {
            // 100 ms RMS follower, bounded gain, and a noise gate for gain increases.
            // Quiet room noise is never normalized up to the level of meeting speech.
            micPower += 0.000625 * (mic * mic - micPower)
            macPower += 0.000625 * (mac * mac - macPower)
            func gain(_ power: Float) -> Float { power > 0.0001 ? min(4, max(0.25, 0.12 / sqrt(power))) : 1 }
            micGain += 0.000125 * (gain(micPower) - micGain)
            macGain += 0.000125 * (gain(macPower) - macGain)
            value = (mic * micGain + mac * macGain) * 0.5
        }
        // Instant attack, 100 ms release peak limiter. Keep headroom before Int16.
        let safeGain: Float = abs(value) > 0.98 ? 0.98 / abs(value) : 1
        limiter = min(safeGain, limiter + 0.000625 * (1 - limiter))
        return Int16((max(-0.98, min(0.98, value * limiter)) * 32767).rounded())
    }
}

struct CaptureMixer {
    static let latency = 0.2 // Covers the existing 4096-frame mic tap plus scheduling jitter.
    let origin: TimeInterval
    private(set) var cursor: Int64 = 0
    private var mic = CaptureTrack()
    private var mac = CaptureTrack()
    private var balance = CaptureBalance()
    init(origin: TimeInterval) { self.origin = origin }
    mutating func push(_ samples: [Float], mic isMic: Bool, time: TimeInterval) {
        guard time.isFinite, abs(time - origin) < Double(Int64.max / 32_000) else { return }
        let start = Int64(((time - origin) * 16_000).rounded())
        if isMic { mic.push(samples, at: start, cursor: cursor) }
        else { mac.push(samples, at: start, cursor: cursor) }
    }
    mutating func render(until time: TimeInterval, both: Bool) -> [Int16] {
        // The caller resets the origin after sleep/pause, so no missing sleep time is written.
        let end = max(cursor, Int64(max(0, time - origin) * 16_000))
        let count = Int(min(4_000, end - cursor))
        guard count > 0 else { return [] }
        mic.flush(before: cursor + Int64(count), cursor: cursor)
        mac.flush(before: cursor + Int64(count), cursor: cursor)
        let result = (0..<count).map { offset in
            let frame = cursor + Int64(offset)
            return balance.mix(mic: mic.sample(at: frame), mac: mac.sample(at: frame), both: both)
        }
        cursor += Int64(count)
        return result
    }
}
