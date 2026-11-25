//
//  PyRunner.h
//  SigninHub iOS
//
//  在后台线程嵌入并启动 CPython 3.11，然后执行后端 serve()。
//

#import <Foundation/Foundation.h>

@interface PyRunner : NSObject

/// 本机访问口令。首次调用时随机生成并写入 NSUserDefaults，之后固定不变。
/// 后端 config.json 的 server.api_token 与此值保持一致，WebView 启动时注入。
+ (NSString *)apiToken;

/// 启动 Python 解释器并拉起 signbot HTTP 服务（127.0.0.1:8787）。
/// completion 在后台队列回调，调用方需自行切回主线程。
+ (void)bootstrapWithCompletion:(void (^)(BOOL ok, NSString *message))completion;

/// boot.log 末尾内容，用于启动失败时显示。
+ (NSString *)bootLogTail;

@end
