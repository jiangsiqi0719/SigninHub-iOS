//
//  KeepAlive.h
//  SigninHub iOS
//
//  静音音频后台保活。iOS 没有办法像 Android 那样起常驻 Service，
//  唯一稳定可行的等价手段是声明 UIBackgroundModes=audio 并持续播放静音音频。
//  巨魔（TrollStore）签名不受 App Store 审核约束，这条路可用。
//

#import <Foundation/Foundation.h>

@interface KeepAlive : NSObject

+ (void)start;
+ (void)resume;
+ (void)stop;

@end
