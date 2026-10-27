#import <AVFoundation/AVFoundation.h>
#import <CoreAudio/CoreAudio.h>

NS_ASSUME_NONNULL_BEGIN
// Keep exception-raising AVFAudio operations entirely in Objective C. Swift never
// unwinds through an NSException, including a format change during tap setup.
NSArray<AVAudioFormat *> * _Nullable NosyAudioFormats(AVAudioEngine *engine, NSError **error) NS_SWIFT_NOTHROW;
AVAudioInputNode * _Nullable NosyAudioInput(AVAudioEngine *engine, NSError **error) NS_SWIFT_NOTHROW;
BOOL NosyAudioStart(AVAudioEngine *engine, AVAudioFormat * _Nullable format, AVAudioNodeTapBlock block, NSError **error) NS_SWIFT_NOTHROW;
BOOL NosyAudioStop(AVAudioEngine *engine, NSError **error) NS_SWIFT_NOTHROW;
// Read the live input streams without creating an engine or negotiating a format.
NSArray<AVAudioFormat *> * _Nullable NosyMicrophoneFormats(AudioObjectID device, NSError **error) NS_SWIFT_NOTHROW;
AVAudioPCMBuffer * _Nullable NosyMicrophoneCopyInput(NSArray<AVAudioFormat *> *formats, const AudioBufferList *input, NSError **error) NS_SWIFT_NOTHROW;
BOOL NosyMicrophoneDisableOutput(AudioObjectID device, AudioDeviceIOProcID ioProc, NSError **error) NS_SWIFT_NOTHROW;
NS_ASSUME_NONNULL_END
