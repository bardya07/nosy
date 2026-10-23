import AVFoundation
import CoreAudio
import Foundation

@main
enum AudioCaptureTests {
    static func main() async throws {
        func check(_ condition: Bool, _ message: String) { precondition(condition, message) }
        for recording in [false, true] {
            for paused in [false, true] {
                for transitioning in [false, true] {
                    check(RecordingSource.canChange(recording: recording, paused: paused, transitioning: transitioning)
                          == (!transitioning && (!recording || paused)), "Source change state rules")
                }
            }
        }
        check(RecordingSource.restored("unknown") == .mic, "Unknown preference falls back safely")
        for source in RecordingSource.available { check(RecordingSource.restored(source.rawValue) == source, "Preference roundtrip") }
        check(RecordingSource.mic.usesMic && !RecordingSource.mic.usesMacAudio, "Mic permissions")
        check(!RecordingSource.macAudio.usesMic && RecordingSource.macAudio.usesMacAudio, "Mac capture needs no mic")
        check(RecordingSource.both.inputName(mic: "Pinned mic") == "Pinned mic + Mac audio", "Both source name")
        check(RecordingSource.macAudio.inputName(mic: "Ignored") == "Mac audio", "Mac source name")
        check(!CaptureWatchdog.tapStalled(alive: true, formatMatches: true, readerAttached: true), "Zero/no callbacks during silence never imply a stall")
        check(CaptureWatchdog.tapStalled(alive: false, formatMatches: true, readerAttached: true), "Dead HAL object is detected even in silence")
        check(CaptureWatchdog.tapStalled(alive: true, formatMatches: false, readerAttached: true), "Format changes trigger tap recovery")
        check(CaptureWatchdog.tapStalled(alive: true, formatMatches: true, readerAttached: false), "Lost IO reader is detected")
        check(CaptureWatchdog.shouldRearm(lastBuffer: 0, now: 10), "An unresponsive tap is rearmed without a false stall warning")
        check(!CaptureWatchdog.shouldRearm(lastBuffer: 9, now: 10), "Zero buffers count as heartbeats")
        check(MacAudioError(operation: "start", status: kAudioHardwareIllegalOperationError).permissionDenied, "Permission error mapping")
        let idle = Recorder { _ in }
        do { try await idle.switchSource(.macAudio, inputUID: nil); preconditionFailure("Idle recorder cannot switch live hardware") }
        catch { check(error.localizedDescription.contains("Pause"), "Recorder enforces source rules") }

        for interleaved in [false, true] {
            let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 4)!
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, interleaved: interleaved, channelLayout: layout)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
            buffer.frameLength = 480
            for frame in 0..<480 {
                for channel in 0..<4 {
                    let value: Float = channel == 1 ? 0.8 : 0
                    if interleaved { buffer.floatChannelData![0][frame * 4 + channel] = value }
                    else { buffer.floatChannelData![channel][frame] = value }
                }
            }
            let monoFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
            let mono = CaptureConverter.mono(buffer, format: monoFormat)!
            check(abs(mono.floatChannelData![0][100] - 0.2) < 0.00001, "Downmix preserves speech on discrete channel 2")
        }
        for rate in [44_100.0, 48_000.0, 96_000.0] {
            let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
            let converter = try CaptureConverter(format: format)
            let frames = Int(rate / 100)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
            buffer.frameLength = AVAudioFrameCount(frames)
            var result: [Float] = []
            for block in 0..<100 {
                for frame in 0..<frames {
                    let value = Float(sin(2 * Double.pi * 440 * Double(block * frames + frame) / rate)) * 0.25
                    buffer.floatChannelData![0][frame] = value; buffer.floatChannelData![1][frame] = value
                }
                result += try converter.convert(buffer)
            }
            check(abs(result.count - 16_000) <= 64, "Streaming rate conversion preserves duration at \(rate)")
            let rms = sqrt(result.dropFirst(160).reduce(0.0) { $0 + Double($1 * $1) } / Double(result.count - 160))
            check(abs(rms - 0.25 / sqrt(2)) < 0.005, "Resampling preserves speech-band level")
            converter.reset()
            for channel in 0..<2 { buffer.floatChannelData![channel].initialize(repeating: 0, count: frames) }
            check(try converter.convert(buffer).allSatisfy { abs($0) < 0.00001 }, "Reset discards pre-pause history")
        }
        let aliasFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let aliasConverter = try CaptureConverter(format: aliasFormat)
        let aliasBuffer = AVAudioPCMBuffer(pcmFormat: aliasFormat, frameCapacity: 480)!
        aliasBuffer.frameLength = 480
        var aliasSamples: [Float] = []
        for block in 0..<100 {
            for frame in 0..<480 {
                aliasBuffer.floatChannelData![0][frame] = Float(sin(2 * Double.pi * 12_000 * Double(block * 480 + frame) / 48_000)) * 0.5
            }
            aliasSamples += try aliasConverter.convert(aliasBuffer)
        }
        let aliasPower = aliasSamples.dropFirst(160).reduce(0.0) { $0 + Double($1 * $1) } / Double(aliasSamples.count - 160)
        check(sqrt(aliasPower) < 0.005, "Resampling filters frequencies above the 16 kHz Nyquist limit")
        var aligned = CaptureMixer(origin: 0)
        aligned.push([Float](repeating: 0.2, count: 1600), mic: false, time: 0)
        aligned.push([Float](repeating: -0.2, count: 1600), mic: true, time: 0)
        check(aligned.render(until: 0.1, both: true).allSatisfy { $0 == 0 }, "Opposite sources align on the same host timeline")
        // No source buffers at all: valid PCM zeros and exact wall-clock duration.
        var silent = CaptureMixer(origin: 100)
        var silence: [Int16] = []
        for index in 1...20 { silence += silent.render(until: 100 + Double(index) / 4, both: false) }
        check(silence.count == 80_000 && silence.allSatisfy { $0 == 0 }, "Five seconds of idle tap is valid silent PCM")
        var balance = CaptureBalance()
        var loud: [Int16] = [], quiet: [Int16] = []
        for i in 0..<64_000 {
            let wave = Float(sin(2 * Double.pi * 440 * Double(i) / 16_000))
            let value = balance.mix(mic: wave * 0.05, mac: wave * 0.8, both: true)
            check(abs(Int(value)) < 32767, "Mixed peaks never clip")
            if i >= 48_000 { loud.append(value) }
        }
        for i in 0..<16_000 {
            let wave = Float(sin(2 * Double.pi * 440 * Double(i) / 16_000))
            quiet.append(balance.mix(mic: wave * 0.05, mac: 0, both: true))
        }
        let rms: ([Int16]) -> Double = { values in sqrt(values.reduce(0) { $0 + pow(Double($1), 2) } / Double(values.count)) }
        check(rms(loud) / rms(quiet) < 3, "Quiet microphone remains audible beside loud Mac audio")
        for value: Float in [0, 1, -1, 10, -10, .nan, .infinity] {
            check(abs(Int(balance.mix(mic: value, mac: value, both: true))) < 32767, "Limiter handles peaks/nonfinite input")
        }
        // One minute of independent clock drift at an exaggerated 0.5%.
        // Buffers are reanchored to host time, never queued into a growing backlog.
        var drift = CaptureMixer(origin: 0)
        var outputCount = 0, nonzero = 0
        for block in 0..<6000 {
            let time = Double(block) * 0.01005
            drift.push([Float](repeating: 0.1, count: 160), mic: false, time: time)
            let result = drift.render(until: max(0, time - 0.2), both: false)
            outputCount += result.count; nonzero += result.filter { $0 != 0 }.count
        }
        check(abs(Double(outputCount) / 16_000 - (Double(5999) * 0.01005 - 0.2)) < 0.001, "Output follows host clock despite drift")
        check(Double(nonzero) / Double(outputCount) > 0.999, "Drift correction does not leave periodic holes")
        var tail = CaptureMixer(origin: 0)
        tail.push([Float](repeating: 0.25, count: 1600), mic: false, time: 0)
        let tailOutput = tail.render(until: 0.05, both: false)
        check(tailOutput.count == 800 && tailOutput.allSatisfy { $0 > 0 }, "Stop flush retains a partially captured final buffer")
        var track = CaptureTrack()
        track.push([0.5, 0.5], at: 0, cursor: 40_000)
        track.push([0.5, 0.5], at: 2, cursor: 40_000)
        check(track.sample(at: 40_000) == 0, "Late buffers cannot replay after a gap")
        print("AUDIO CAPTURE UNIT PASS: source rules, channels, streaming resampling, silence, balance, limiter, drift and late buffers")
    }
}
