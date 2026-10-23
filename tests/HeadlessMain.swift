import Foundation
import AudioToolbox

// Compile the real backend independently while UI work is in progress.
@main
enum HeadlessTestMain {
    static func main() async {
        if CommandLine.arguments.dropFirst().first == "--test-aac-capability" {
            var format = kAudioFormatMPEG4AAC
            var size: UInt32 = 0
            let status = AudioFormatGetPropertyInfo(kAudioFormatProperty_Encoders, 4, &format, &size)
            exit(status == noErr && size > 0 ? 0 : 77)
        }
        UserDefaults.standard.setVolatileDomain(["compressAudio": true], forName: UserDefaults.argumentDomain)
        exit(await Headless.run(Array(CommandLine.arguments.dropFirst())))
    }
}
