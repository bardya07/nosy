#import "AudioExceptions.h"
#include <math.h>

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
        // Keep the older engine bridge safe for any callers: never install a stale
        // client format after a headset changes its current input format.
        AVAudioFormat *hardware = [engine.inputNode inputFormatForBus:0];
        AVAudioFormat *tap = format ?: [engine.inputNode outputFormatForBus:0];
        if (!hardware.channelCount || hardware.sampleRate <= 0 || hardware.sampleRate != tap.sampleRate || hardware.channelCount != tap.channelCount) {
            if (error) *error = [NSError errorWithDomain:@"com.bardya.nosy.audio" code:1 userInfo:@{NSLocalizedDescriptionKey: @"The microphone changed during setup. Try recording again."}];
            return NO;
        }
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

static BOOL MicrophoneError(NSString *message, NSError **error) {
    if (error) *error = [NSError errorWithDomain:@"com.bardya.nosy.audio" code:2
                                      userInfo:@{NSLocalizedDescriptionKey: message}];
    return NO;
}

NSArray<AVAudioFormat *> *NosyMicrophoneFormats(AudioObjectID device, NSError **error) {
    @try {
        AudioObjectPropertyAddress address = {kAudioDevicePropertyStreams, kAudioDevicePropertyScopeInput, kAudioObjectPropertyElementMain};
        UInt32 size = 0;
        if (AudioObjectGetPropertyDataSize(device, &address, 0, NULL, &size) != noErr || !size || size % sizeof(AudioStreamID)) {
            MicrophoneError(@"The microphone has no available input streams.", error); return nil;
        }
        NSMutableData *storage = [NSMutableData dataWithLength:size];
        UInt32 capacity = size;
        if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, storage.mutableBytes) != noErr || size > capacity || size % sizeof(AudioStreamID)) {
            MicrophoneError(@"Could not read the microphone input streams.", error); return nil;
        }
        AudioStreamID *streams = storage.mutableBytes;
        NSMutableArray<AVAudioFormat *> *formats = [NSMutableArray array];
        for (UInt32 index = 0; index < size / sizeof(AudioStreamID); ++index) {
            AudioStreamBasicDescription asbd = {0};
            UInt32 formatSize = sizeof(asbd);
            AudioObjectPropertyAddress formatAddress = {kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
            if (AudioObjectGetPropertyData(streams[index], &formatAddress, 0, NULL, &formatSize, &asbd) != noErr || formatSize != sizeof(asbd)) {
                MicrophoneError(@"Could not read the current microphone format.", error); return nil;
            }
            AVAudioFormat *format = [[AVAudioFormat alloc] initWithStreamDescription:&asbd];
            if (!format || format.sampleRate <= 0 || !format.channelCount || format.commonFormat == AVAudioOtherFormat
                || (formats.count && format.sampleRate != formats.firstObject.sampleRate)) {
                MicrophoneError(@"The microphone has no usable audio input format.", error); return nil;
            }
            [formats addObject:format];
        }
        return formats.count ? formats : nil;
    } @catch (NSException *exception) { AudioError(exception, error); return nil; }
}

AVAudioPCMBuffer *NosyMicrophoneCopyInput(NSArray<AVAudioFormat *> *formats, const AudioBufferList *input, NSError **error) {
    @try {
        // Validate every buffer before reading any samples. A changed device layout is
        // discarded, never installed as a stale AVAudioEngine tap or read out of bounds.
        UInt32 bufferIndex = 0, channelCount = 0, frames = 0;
        for (AVAudioFormat *format in formats) {
            UInt32 count = format.interleaved ? 1 : format.channelCount;
            UInt32 bytes = format.streamDescription->mBytesPerFrame;
            if (!bytes || bufferIndex + count > input->mNumberBuffers) goto changed;
            for (UInt32 index = 0; index < count; ++index) {
                AudioBuffer buffer = input->mBuffers[bufferIndex++];
                UInt32 channels = format.interleaved ? format.channelCount : 1;
                if (!buffer.mData || !buffer.mDataByteSize || buffer.mNumberChannels != channels
                    || buffer.mDataByteSize % bytes) goto changed;
                UInt32 length = buffer.mDataByteSize / bytes;
                if (frames && frames != length) goto changed;
                frames = length;
            }
            channelCount += format.channelCount;
        }
        if (!frames || !channelCount || bufferIndex != input->mNumberBuffers) goto changed;
        {
            AVAudioFormat *output = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:formats.firstObject.sampleRate channels:channelCount];
            AVAudioPCMBuffer *result = [[AVAudioPCMBuffer alloc] initWithPCMFormat:output frameCapacity:frames];
            if (!result) { MicrophoneError(@"Could not allocate microphone audio memory.", error); return nil; }
            result.frameLength = frames;
            bufferIndex = 0;
            UInt32 destinationChannel = 0;
            for (AVAudioFormat *format in formats) {
                for (UInt32 channel = 0; channel < format.channelCount; ++channel) {
                    const void *source = input->mBuffers[bufferIndex + (format.interleaved ? 0 : channel)].mData;
                    UInt32 stride = format.interleaved ? format.channelCount : 1;
                    float *destination = result.floatChannelData[destinationChannel++];
                    for (UInt32 frame = 0; frame < frames; ++frame) {
                        UInt32 offset = frame * stride + (format.interleaved ? channel : 0);
                        double sample;
                        switch (format.commonFormat) {
                            case AVAudioPCMFormatFloat32: sample = ((const float *)source)[offset]; break;
                            case AVAudioPCMFormatFloat64: sample = ((const double *)source)[offset]; break;
                            case AVAudioPCMFormatInt16: sample = ((const int16_t *)source)[offset] / 32768.0; break;
                            case AVAudioPCMFormatInt32: sample = ((const int32_t *)source)[offset] / 2147483648.0; break;
                            default: goto changed;
                        }
                        destination[frame] = isfinite(sample) ? (float)sample : 0;
                    }
                }
                bufferIndex += format.interleaved ? 1 : format.channelCount;
            }
            return result;
        }
    changed:
        MicrophoneError(@"The microphone format changed. Reconnecting the input.", error);
        return nil;
    } @catch (NSException *exception) { AudioError(exception, error); return nil; }
}

BOOL NosyMicrophoneDisableOutput(AudioObjectID device, AudioDeviceIOProcID ioProc, NSError **error) {
    // This is per reader stream usage, not device configuration. No output stream
    // participates in this input reader. Never write rates, formats, buffers or defaults.
    AudioObjectPropertyAddress streams = {kAudioDevicePropertyStreams, kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(device, &streams, 0, NULL, &size);
    if (status != noErr || size % sizeof(AudioStreamID)) return MicrophoneError(@"Could not inspect microphone output streams.", error);
    UInt32 count = size / sizeof(AudioStreamID);
    if (!count) return YES;
    size = (UInt32)(offsetof(AudioHardwareIOProcStreamUsage, mStreamIsOn) + count * sizeof(UInt32));
    NSMutableData *storage = [NSMutableData dataWithLength:size];
    AudioHardwareIOProcStreamUsage *usage = storage.mutableBytes;
    usage->mIOProc = (void *)ioProc;
    usage->mNumberStreams = count;
    AudioObjectPropertyAddress address = {kAudioDevicePropertyIOProcStreamUsage, kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMain};
    status = AudioObjectSetPropertyData(device, &address, 0, NULL, size, usage);
    return status == noErr || MicrophoneError(@"Could not open the microphone as an input reader.", error);
}
