//
//  PyRunner.m
//  SigninHub iOS
//
//  关键点（踩坑记录）：
//  1. home 必须指向 <App>.app/python —— install_stdlib 把 stdlib 铺到
//     <App>.app/python/lib/python3.11，CPython 才能找到 os.py / encodings。
//  2. executable 必须设成 app 主二进制路径 —— Python-Apple-support 的
//     AppleFrameworkLoader 用 os.path.split(sys.executable)[0] 定位
//     Frameworks/*.framework 里的扩展模块（_ssl / _sqlite3 / _hashlib …）。
//  3. SIGNBOT_DATA 必须指到可写沙盒目录 —— app 包是只读的，
//     config.py 里 DATA_DIR.mkdir() 会在只读路径上抛异常。
//  4. PyEval_SaveThread()：主线程初始化完就把 GIL 放掉，否则 Python 线程
//     永远拿不到 GIL，HTTP 服务不会起来。
//

#import "PyRunner.h"
#import <Foundation/Foundation.h>

#import <Python/Python.h>

#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#pragma mark - helpers

static NSString *SHSigninhubDataDir(void) {
    NSArray<NSString *> *paths =
        NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
    NSString *base = paths.firstObject ?: NSTemporaryDirectory();
    NSString *dir = [base stringByAppendingPathComponent:@"signinhub"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];
    return dir;
}

static wchar_t *SHWideCopy(const char *utf8) {
    if (utf8 == NULL) { return NULL; }
    size_t n = strlen(utf8);
    wchar_t *w = (wchar_t *)calloc(n + 1, sizeof(wchar_t));
    if (w == NULL) { return NULL; }
    size_t got = mbstowcs(w, utf8, n + 1);
    if (got == (size_t)-1) {
        // 极端情况下 mbstowcs 失败：退化为逐字节拷贝（路径都是 ASCII）。
        for (size_t i = 0; i < n; i++) { w[i] = (wchar_t)(unsigned char)utf8[i]; }
        w[n] = L'\0';
    }
    return w;
}

// 全部写成 ASCII，避免 C 字符串里的中文转义问题。
//
// 启动顺序很关键：
//   1. 先把 SIGNHUB_TOKEN 写进 config.json 的 server.api_token
//      —— 必须早于 `from signbot.server import serve`，因为 serve() 里的
//      _ensure_api_token() 发现口令为空会自动生成一个随机口令并只打印到控制台，
//      那样 WebView 就拿不到口令，界面会全线 401。
//   2. 再导入 serve，起线程。
static const char *kBootstrapCode =
    "import os, sys, threading, traceback\n"
    "def _signhub_boot():\n"
    "    d = os.environ.get('SIGNBOT_DATA') or '/tmp'\n"
    "    f = open(os.path.join(d, 'boot.log'), 'a', buffering=1, encoding='utf-8', errors='replace')\n"
    "    sys.stdout = f\n"
    "    sys.stderr = f\n"
    "    try:\n"
    "        f.write('=== boot platform=%s exe=%s prefix=%s\\n' % (sys.platform, sys.executable, sys.prefix))\n"
    "        b = os.environ.get('SIGNHUB_BACKEND')\n"
    "        if b and b not in sys.path:\n"
    "            sys.path.insert(0, b)\n"
    "        import signbot\n"
    "        f.write('signbot=%s\\n' % (getattr(signbot, '__file__', '?')))\n"
    "        tok = os.environ.get('SIGNHUB_TOKEN') or ''\n"
    "        if tok:\n"
    "            from signbot.config import update_config\n"
    "            def _set(cur):\n"
    "                cur.setdefault('server', {})['api_token'] = tok\n"
    "            update_config(_set)\n"
    "            f.write('api_token injected\\n')\n"
    "        from signbot.server import serve\n"
    "        def _run():\n"
    "            try:\n"
    "                serve(host='127.0.0.1', port=8787)\n"
    "            except BaseException:\n"
    "                traceback.print_exc()\n"
    "        threading.Thread(target=_run, daemon=True, name='signhub-http').start()\n"
    "        f.write('BOOTSTRAP_OK\\n')\n"
    "    except BaseException:\n"
    "        traceback.print_exc()\n"
    "_signhub_boot()\n";

@implementation PyRunner

static NSString *const kTokenDefaultsKey = @"signhub_api_token";

+ (NSString *)apiToken {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSString *tok = [ud stringForKey:kTokenDefaultsKey];
    if (tok.length >= 16) { return tok; }

    // 32 hex 字符 = 128 bit，本机单用户场景足够。
    uint8_t buf[16];
    arc4random_buf(buf, sizeof(buf));
    NSMutableString *s = [NSMutableString stringWithCapacity:32];
    for (int i = 0; i < 16; i++) { [s appendFormat:@"%02x", buf[i]]; }
    tok = [s copy];
    [ud setObject:tok forKey:kTokenDefaultsKey];
    [ud synchronize];
    return tok;
}


+ (NSString *)bootLogPath {
    return [SHSigninhubDataDir() stringByAppendingPathComponent:@"boot.log"];
}

+ (NSString *)bootLogTail {
    NSString *path = [self bootLogPath];
    NSString *text = [NSString stringWithContentsOfFile:path
                                               encoding:NSUTF8StringEncoding
                                                  error:NULL];
    if (text.length == 0) { return @""; }
    if (text.length > 1500) {
        text = [text substringFromIndex:text.length - 1500];
    }
    return text;
}

+ (void)bootstrapWithCompletion:(void (^)(BOOL, NSString *))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
        NSString *pyHome     = [bundlePath stringByAppendingPathComponent:@"python"];
        NSString *backend    = [bundlePath stringByAppendingPathComponent:@"backend"];
        NSString *exe        = [[NSBundle mainBundle] executablePath];
        NSString *dataDir    = SHSigninhubDataDir();

        setenv("PYTHONHOME", pyHome.UTF8String, 1);
        setenv("PYTHONDONTWRITEBYTECODE", "1", 1);
        setenv("PYTHONUTF8", "1", 1);
        setenv("PYTHONUNBUFFERED", "1", 1);
        setenv("SIGNBOT_DATA", dataDir.UTF8String, 1);
        setenv("SIGNHUB_BACKEND", backend.UTF8String, 1);
        setenv("SIGNHUB_TOKEN", [self apiToken].UTF8String, 1);
        setenv("TZ", "CST-8", 1);

        NSString *errMsg = nil;

        PyConfig config;
        PyConfig_InitIsolatedConfig(&config);
        config.install_signal_handlers = 0;
        config.write_bytecode = 0;
        config.parse_argv = 0;
        config.user_site_directory = 0;
        config.buffered_stdio = 0;

        PyStatus st = PyConfig_SetBytesString(&config, &config.home, pyHome.UTF8String);
        if (!PyStatus_Exception(st)) {
            st = PyConfig_SetBytesString(&config, &config.program_name, exe.UTF8String);
        }
        if (!PyStatus_Exception(st)) {
            st = PyConfig_SetBytesString(&config, &config.executable, exe.UTF8String);
        }
        if (PyStatus_Exception(st)) {
            errMsg = [NSString stringWithFormat:@"PyConfig 设置失败: %s",
                      (st.err_msg != NULL ? st.err_msg : "unknown")];
        }

        if (errMsg == nil) {
            NSArray<NSString *> *searchPaths = @[
                [pyHome stringByAppendingPathComponent:@"lib/python3.11"],
                [pyHome stringByAppendingPathComponent:@"lib/python3.11/lib-dynload"],
                backend,
            ];
            config.module_search_paths_set = 1;
            for (NSString *p in searchPaths) {
                wchar_t *w = SHWideCopy(p.UTF8String);
                if (w != NULL) {
                    PyWideStringList_Append(&config.module_search_paths, w);
                    free(w);
                }
            }
            st = Py_InitializeFromConfig(&config);
            if (PyStatus_Exception(st)) {
                errMsg = [NSString stringWithFormat:@"Py_InitializeFromConfig 失败: %s",
                          (st.err_msg != NULL ? st.err_msg : "unknown")];
            }
        }

        PyConfig_Clear(&config);

        if (errMsg == nil) {
            int rc = PyRun_SimpleStringFlags(kBootstrapCode, NULL);
            if (rc != 0) {
                errMsg = @"bootstrap 脚本执行失败（详见 boot.log）";
            }
        }

        if (errMsg == nil) {
            // 放掉 GIL，让 signhub-http 线程跑起来。之后不再从 ObjC 侧调用 Python。
            PyEval_SaveThread();
        }

        if (completion) {
            completion(errMsg == nil, errMsg ?: @"");
        }
    });
}

@end
