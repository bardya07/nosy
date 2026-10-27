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
        // Synthetic memory only. The reader preserves a call's current 24 kHz
        // rate, normalizes PCM in memory, and rejects a changed buffer layout.
        for (NSNumber *common in @[@(AVAudioPCMFormatFloat32), @(AVAudioPCMFormatFloat64), @(AVAudioPCMFormatInt16), @(AVAudioPCMFormatInt32)]) {
            for (NSNumber *interleaved in @[@NO, @YES]) {
                AVAudioFormat *format = [[AVAudioFormat alloc] initWithCommonFormat:common.unsignedIntegerValue sampleRate:24000 channels:2 interleaved:interleaved.boolValue];
                AVAudioPCMBuffer *input = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:240];
                input.frameLength = 240;
                for (UInt32 channel = 0; channel < 2; ++channel) {
                    for (UInt32 frame = 0; frame < 240; ++frame) {
                        UInt32 offset = interleaved.boolValue ? frame * 2 + channel : frame;
                        UInt32 buffer = interleaved.boolValue ? 0 : channel;
                        void *data = input.mutableAudioBufferList->mBuffers[buffer].mData;
                        switch (format.commonFormat) {
                            case AVAudioPCMFormatFloat32: ((float *)data)[offset] = 0.25; break;
                            case AVAudioPCMFormatFloat64: ((double *)data)[offset] = 0.25; break;
                            case AVAudioPCMFormatInt16: ((int16_t *)data)[offset] = 8192; break;
                            case AVAudioPCMFormatInt32: ((int32_t *)data)[offset] = 536870912; break;
                            default: return 2;
                        }
                    }
                }
                NSError *error = nil;
                AVAudioPCMBuffer *copy = NosyMicrophoneCopyInput(@[format], input.audioBufferList, &error);
                if (!copy || error || copy.format.sampleRate != 24000 || copy.frameLength != 240
                    || copy.format.channelCount != 2 || copy.floatChannelData[1][239] != 0.25f) return 3;
                AudioBufferList *changed = input.mutableAudioBufferList;
                changed->mBuffers[0].mDataByteSize -= 1;
                if (NosyMicrophoneCopyInput(@[format], changed, &error) || !error) return 4;
            }
        }
        puts("AUDIO EXCEPTION PASS: format, install, prepare, start, stop and removal exceptions become errors without hardware");
        puts("FAKE INPUT PASS: current 24 kHz PCM formats, channels and stale buffer rejection without hardware");
    }
}
