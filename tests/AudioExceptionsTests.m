#import "../Native/AudioExceptions.h"

// Fake Objective C receivers raise at each AVFAudio boundary without opening hardware.
@interface ThrowingAudio : NSObject
@property NSString *stage;
@end
@implementation ThrowingAudio
- (id)inputNode { if ([_stage isEqual:@"formats"]) [NSException raise:NSInvalidArgumentException format:@"format changed"]; return self; }
- (AVAudioFormat *)outputFormatForBus:(NSUInteger)bus { return [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:1]; }
- (AVAudioFormat *)inputFormatForBus:(NSUInteger)bus { return [self outputFormatForBus:bus]; }
- (void)removeTapOnBus:(NSUInteger)bus { if ([_stage isEqual:@"remove"]) [NSException raise:NSInvalidArgumentException format:@"device gone"]; }
- (void)installTapOnBus:(NSUInteger)bus bufferSize:(AVAudioFrameCount)size format:(AVAudioFormat *)format block:(AVAudioNodeTapBlock)block {
    if ([_stage isEqual:@"install"]) [NSException raise:NSInvalidArgumentException format:@"format changed again"];
}
- (void)prepare { if ([_stage isEqual:@"prepare"]) [NSException raise:NSInvalidArgumentException format:@"graph changed"]; }
- (BOOL)startAndReturnError:(NSError **)error { [NSException raise:NSInvalidArgumentException format:@"start failed"]; return NO; }
- (void)stop { if ([_stage isEqual:@"stop"]) [NSException raise:NSInvalidArgumentException format:@"stop failed"]; }
@end
int main(void) {
    @autoreleasepool {
        ThrowingAudio *fake = [ThrowingAudio new];
        for (NSString *stage in @[@"formats", @"install", @"prepare", @"start", @"stop", @"remove"]) {
            fake.stage = stage;
            NSError *error = nil;
            BOOL failed;
            if ([stage isEqual:@"formats"]) failed = NosyAudioFormats((id)fake, &error) == nil;
            else if ([stage isEqual:@"stop"] || [stage isEqual:@"remove"]) failed = !NosyAudioStop((id)fake, &error);
            else failed = !NosyAudioStart((id)fake, nil, ^(AVAudioPCMBuffer *b, AVAudioTime *t) {}, &error);
            if (!failed || ![error.domain isEqual:@"com.bardya.nosy.audio"]) return 1;
        }
        puts("AUDIO EXCEPTION PASS: format, install, prepare, start, stop and removal exceptions become errors without hardware");
    }
}
