#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN
// Keep exception-raising AVFAudio operations entirely in Objective C. Swift never
// unwinds through an NSException, including a format change during tap setup.
NSArray<AVAudioFormat *> * _Nullable NosyAudioFormats(AVAudioEngine *engine, NSError **error) NS_SWIFT_NOTHROW;
BOOL NosyAudioStart(AVAudioEngine *engine, AVAudioFormat * _Nullable format, AVAudioNodeTapBlock block, NSError **error) NS_SWIFT_NOTHROW;
BOOL NosyAudioStop(AVAudioEngine *engine, NSError **error) NS_SWIFT_NOTHROW;
NS_ASSUME_NONNULL_END
