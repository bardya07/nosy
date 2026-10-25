#import "AudioExceptions.h"

static void AudioError(NSException *exception, NSError **error) {
    if (error) *error = [NSError errorWithDomain:@"com.bardya.nosy.audio" code:1 userInfo:@{
        NSLocalizedDescriptionKey: [NSString stringWithFormat:@"The microphone changed during setup (%@). Check your input device, then try again.", exception.reason ?: exception.name]
    }];
}
NSArray<AVAudioFormat *> *NosyAudioFormats(AVAudioEngine *engine, NSError **error) {
    @try { return @[[engine.inputNode outputFormatForBus:0], [engine.inputNode inputFormatForBus:0]]; }
    @catch (NSException *exception) { AudioError(exception, error); return nil; }
}
AVAudioInputNode *NosyAudioInput(AVAudioEngine *engine, NSError **error) {
    @try { return engine.inputNode; }
    @catch (NSException *exception) { AudioError(exception, error); return nil; }
}
BOOL NosyAudioStart(AVAudioEngine *engine, AVAudioFormat *format, AVAudioNodeTapBlock block, NSError **error) {
    @try {
        [engine.inputNode removeTapOnBus:0];
        [engine.inputNode installTapOnBus:0 bufferSize:4096 format:format block:block];
        [engine prepare];
        return [engine startAndReturnError:error];
    } @catch (NSException *exception) { AudioError(exception, error); return NO; }
}
BOOL NosyAudioStop(AVAudioEngine *engine, NSError **error) {
    @try { [engine stop]; [engine.inputNode removeTapOnBus:0]; return YES; }
    @catch (NSException *exception) { AudioError(exception, error); return NO; }
}
