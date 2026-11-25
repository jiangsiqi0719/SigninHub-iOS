//
//  KeepAlive.m
//  SigninHub iOS
//

#import "KeepAlive.h"
#import <AVFoundation/AVFoundation.h>

static AVAudioPlayer *gPlayer = nil;

@implementation KeepAlive

/// 生成一段 2 秒 8bit 单声道静音 WAV（采样值 0x80 = 8bit PCM 的零点）。
+ (NSData *)silentWavData {
    const uint32_t sampleRate = 8000;
    const uint32_t seconds = 2;
    const uint32_t dataLen = sampleRate * seconds;

    NSMutableData *d = [NSMutableData dataWithCapacity:44 + dataLen];
    uint32_t u32;
    uint16_t u16;

#define APPEND4(lit) [d appendBytes:(lit) length:4]
#define APPEND_U32(v) do { u32 = (uint32_t)(v); [d appendBytes:&u32 length:4]; } while (0)
#define APPEND_U16(v) do { u16 = (uint16_t)(v); [d appendBytes:&u16 length:2]; } while (0)

    APPEND4("RIFF");
    APPEND_U32(36 + dataLen);   // ChunkSize
    APPEND4("WAVE");
    APPEND4("fmt ");
    APPEND_U32(16);             // Subchunk1Size
    APPEND_U16(1);              // PCM
    APPEND_U16(1);              // mono
    APPEND_U32(sampleRate);     // SampleRate
    APPEND_U32(sampleRate * 1 * 1);  // ByteRate = rate * ch * bits/8
    APPEND_U16(1);              // BlockAlign
    APPEND_U16(8);              // BitsPerSample
    APPEND4("data");
    APPEND_U32(dataLen);

#undef APPEND4
#undef APPEND_U32
#undef APPEND_U16

    uint8_t *silence = (uint8_t *)malloc(dataLen);
    if (silence != NULL) {
        memset(silence, 0x80, dataLen);
        [d appendBytes:silence length:dataLen];
        free(silence);
    }
    return d;
}

+ (void)start {
    if (gPlayer != nil) {
        [self resume];
        return;
    }
    NSError *err = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryPlayback
             withOptions:AVAudioSessionCategoryOptionMixWithOthers
                   error:&err];
    [session setActive:YES error:&err];

    NSData *wav = [self silentWavData];
    gPlayer = [[AVAudioPlayer alloc] initWithData:wav error:&err];
    if (gPlayer == nil) {
        NSLog(@"[KeepAlive] AVAudioPlayer init failed: %@", err);
        return;
    }
    gPlayer.numberOfLoops = -1;
    // 不能设 0.0：系统可能判定为「无输出」而挂起。0.02 乘静音采样，实际无声。
    gPlayer.volume = 0.02f;
    [gPlayer prepareToPlay];
    BOOL ok = [gPlayer play];
    NSLog(@"[KeepAlive] started=%@", ok ? @"YES" : @"NO");
}

+ (void)resume {
    NSError *err = nil;
    [[AVAudioSession sharedInstance] setActive:YES error:&err];
    if (gPlayer != nil && !gPlayer.isPlaying) {
        [gPlayer play];
    }
}

+ (void)stop {
    if (gPlayer != nil) {
        [gPlayer stop];
        gPlayer = nil;
    }
    [[AVAudioSession sharedInstance] setActive:NO
                                   withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                         error:NULL];
}

@end
