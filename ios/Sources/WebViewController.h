//
//  WebViewController.h
//  SigninHub iOS
//

#import <UIKit/UIKit.h>

@interface WebViewController : UIViewController

/// apiToken：后端 config.json 里的 server.api_token，页面加载前注入
/// sessionStorage["signhub_token"]，让网页版无需用户手工填口令。
- (instancetype)initWithApiToken:(NSString *)apiToken;

/// Python 引擎启动结果回调（主线程）。
- (void)setEngineReady:(BOOL)ok message:(NSString *)message;

@end
