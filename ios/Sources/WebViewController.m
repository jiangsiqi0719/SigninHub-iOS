//
//  WebViewController.m
//  SigninHub iOS
//
//  与安卓版完全一致的思路：界面就是后端自带的网页版（backend/web），
//  所以这里只做三件事 —— 全屏 WKWebView、连本机 8787、失败自动重试。
//

#import "WebViewController.h"
#import <WebKit/WebKit.h>
#import "PyRunner.h"

static NSString *const kHomeURLString = @"http://127.0.0.1:8787/";
static const NSInteger kMaxRetry = 300;   // 300 * 0.2s = 60s

@interface WebViewController () <WKNavigationDelegate, WKUIDelegate>

@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) UILabel *hintLabel;
@property (nonatomic, assign) NSInteger retryCount;
@property (nonatomic, assign) BOOL pageLoaded;
@property (nonatomic, copy) NSString *apiToken;

@end

@implementation WebViewController

- (instancetype)initWithApiToken:(NSString *)apiToken {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _apiToken = [apiToken copy];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.retryCount = 0;

    WKWebViewConfiguration *cfg = [[WKWebViewConfiguration alloc] init];
    cfg.defaultWebpagePreferences.allowsContentJavaScript = YES;
    cfg.allowsInlineMediaPlayback = YES;
    cfg.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeNone;
    if (@available(iOS 14.0, *)) {
        cfg.defaultWebpagePreferences.preferredContentMode = WKContentModeMobile;
    }

    // 页面脚本执行之前把口令塞进 sessionStorage：
    // app.js 读取顺序是 sessionStorage["signhub_token"] → localStorage → 空。
    // 不注入的话，后端 serve() 会自动生成随机口令并只打印到控制台，
    // 界面所有 /api/* 都会 401。
    if (self.apiToken.length > 0) {
        NSString *js = [NSString stringWithFormat:
            @"(function(){try{sessionStorage.setItem('signhub_token','%@');}catch(e){}})();",
            self.apiToken];
        WKUserScript *script = [[WKUserScript alloc] initWithSource:js
                                                     injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                                  forMainFrameOnly:NO];
        [cfg.userContentController addUserScript:script];
    }

    self.webView = [[WKWebView alloc] initWithFrame:self.view.bounds configuration:cfg];
    self.webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.webView.navigationDelegate = self;
    self.webView.UIDelegate = self;
    self.webView.allowsBackForwardNavigationGestures = NO;
    self.webView.scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentAutomatic;
    self.webView.backgroundColor = [UIColor systemBackgroundColor];
    self.webView.hidden = YES;
    [self.view addSubview:self.webView];

    self.hintLabel = [[UILabel alloc] initWithFrame:self.view.bounds];
    self.hintLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.hintLabel.textAlignment = NSTextAlignmentCenter;
    self.hintLabel.numberOfLines = 0;
    self.hintLabel.font = [UIFont systemFontOfSize:15];
    self.hintLabel.textColor = [UIColor secondaryLabelColor];
    self.hintLabel.text = @"正在启动签到引擎…";
    [self.view addSubview:self.hintLabel];

    [self loadHome];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.webView.frame = self.view.bounds;
    self.hintLabel.frame = UIEdgeInsetsInsetRect(self.view.bounds, UIEdgeInsetsMake(60, 24, 60, 24));
}

#pragma mark - loading

- (void)loadHome {
    NSURL *url = [NSURL URLWithString:kHomeURLString];
    NSURLRequest *req = [NSURLRequest requestWithURL:url
                                        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                    timeoutInterval:25.0];
    [self.webView loadRequest:req];
}

- (void)setEngineReady:(BOOL)ok message:(NSString *)message {
    if (ok) {
        [self loadHome];
        return;
    }
    self.hintLabel.hidden = NO;
    self.webView.hidden = YES;
    NSString *tail = [PyRunner bootLogTail];
    self.hintLabel.text = [NSString stringWithFormat:
        @"Python 引擎启动失败\n%@\n\nboot.log 末尾：\n%@",
        message ?: @"", tail.length > 0 ? tail : @"(空)"];
}

#pragma mark - WKNavigationDelegate

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    self.pageLoaded = YES;
    self.retryCount = 0;
    self.hintLabel.hidden = YES;
    self.webView.hidden = NO;
}

- (void)webView:(WKWebView *)webView
didFailProvisionalNavigation:(WKNavigation *)navigation
      withError:(NSError *)error {
    // 引擎还在初始化（Python 首次导入 + sqlite 建表约 1~3 秒），重试即可。
    if (self.retryCount < kMaxRetry) {
        self.retryCount += 1;
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [weakSelf loadHome];
        });
        return;
    }
    self.hintLabel.hidden = NO;
    self.webView.hidden = YES;
    self.hintLabel.text = [NSString stringWithFormat:
        @"连不上本机签到引擎 (127.0.0.1:8787)\n%@",
        error.localizedDescription ?: @""];
}

- (void)webView:(WKWebView *)webView
didFailNavigation:(WKNavigation *)navigation
      withError:(NSError *)error {
    // 已加载过页面后的偶发失败，交给用户下拉/重启，不覆盖界面。
    NSLog(@"[WebView] didFailNavigation: %@", error);
}

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView {
    [self loadHome];
}

#pragma mark - WKUIDelegate（app.js 用到了 confirm()/alert()）

- (void)webView:(WKWebView *)webView
runJavaScriptAlertPanelWithMessage:(NSString *)message
 initiatedByFrame:(WKFrameInfo *)frame
completionHandler:(void (^)(void))completionHandler {
    UIAlertController *ac =
        [UIAlertController alertControllerWithTitle:nil
                                           message:message
                                    preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好"
                                          style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *a) { completionHandler(); }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)webView:(WKWebView *)webView
runJavaScriptConfirmPanelWithMessage:(NSString *)message
 initiatedByFrame:(WKFrameInfo *)frame
completionHandler:(void (^)(BOOL))completionHandler {
    UIAlertController *ac =
        [UIAlertController alertControllerWithTitle:nil
                                           message:message
                                    preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消"
                                          style:UIAlertActionStyleCancel
                                        handler:^(UIAlertAction *a) { completionHandler(NO); }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"确定"
                                          style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *a) { completionHandler(YES); }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)webView:(WKWebView *)webView
runJavaScriptTextInputPanelWithPrompt:(NSString *)prompt
                          defaultText:(NSString *)defaultText
 initiatedByFrame:(WKFrameInfo *)frame
completionHandler:(void (^)(NSString *))completionHandler {
    UIAlertController *ac =
        [UIAlertController alertControllerWithTitle:nil
                                           message:prompt
                                    preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) { tf.text = defaultText; }];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消"
                                          style:UIAlertActionStyleCancel
                                        handler:^(UIAlertAction *a) { completionHandler(nil); }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"确定"
                                          style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *a) {
        completionHandler(ac.textFields.firstObject.text);
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

@end
