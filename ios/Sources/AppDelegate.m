//
//  AppDelegate.m
//  SigninHub iOS
//

#import "AppDelegate.h"
#import "WebViewController.h"
#import "PyRunner.h"
#import "KeepAlive.h"

@interface AppDelegate ()
@property (nonatomic, strong) WebViewController *web;
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application
didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];

    self.web = [[WebViewController alloc] initWithApiToken:[PyRunner apiToken]];
    self.window.rootViewController = self.web;
    [self.window makeKeyAndVisible];

    // 静音音频保活：让进程不被系统挂起，Python 里的每日定时器才能到点执行。
    [KeepAlive start];

    // Python 引擎在后台线程启动，WKWebView 会自动重试连接本机 8787。
    [PyRunner bootstrapWithCompletion:^(BOOL ok, NSString *message) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.web setEngineReady:ok message:message];
        });
    }];

    return YES;
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    [KeepAlive resume];
}

- (void)applicationWillEnterForeground:(UIApplication *)application {
    [KeepAlive resume];
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    [KeepAlive resume];
}

- (void)applicationWillTerminate:(UIApplication *)application {
    [KeepAlive stop];
}

@end
