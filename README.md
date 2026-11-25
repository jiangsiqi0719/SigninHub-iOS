# SigninHub iOS（自助打包说明）

原项目 [Ayanguser/SigninHub](https://github.com/Ayanguser/SigninHub) **只发安卓 APK**，
全仓库没有任何 iOS 工程。这里把它移植成 iOS 版。

## 为什么不是「APK 转 IPA」

不存在这种东西。APK 是 Dalvik/ART 字节码 + Android Framework API，IPA 要 ARM64
原生 Mach-O + 苹果签名体系，两者没有字节码级对应关系。

原 App 的结构决定了移植成本很低：

```
界面 = backend/web/ 整套网页（PWA），安卓版就是 WebView 全屏加载它
引擎 = 安卓用 Kotlin 重写了 LocalApi / LocalCheckin（290KB）
```

所以 iOS 版换个思路：**不重写引擎，直接把整个 Python 后端塞进 IPA**。
后端是纯标准库 Python（`requirements.txt` 只有可选的 Playwright），
BeeWare 的 `Python-Apple-support` 已提供编译好的 iOS CPython 3.11
（`_ssl` / `_sqlite3` / `_hashlib` / `_ctypes` / `zlib` 全带），
于是 23 个 `/api/*` 接口、所有签到协议、网页界面**原样可跑，功能对等**。

```
iOS App
├─ WKWebView  ──加载──▶ http://127.0.0.1:8787/   ← backend 自己 serve 的网页
└─ 内嵌 CPython 3.11 ──▶ backend/signbot/server.py（原样）
```

## 结构

```
ios/
├─ project.yml                      XcodeGen 工程定义
├─ Sources/
│  ├─ main.m / AppDelegate.*        启动壳
│  ├─ PyRunner.*                    嵌 CPython：PyConfig + 启动 serve()
│  ├─ WebViewController.*           全屏 WKWebView + 口令注入 + 重试
│  └─ KeepAlive.*                   静音音频后台保活（iOS 没有常驻 Service）
├─ Resources/
│  ├─ Info.plist                    UIBackgroundModes=audio、ATS 放开本机
│  └─ Assets.xcassets/AppIcon       图标（CI 用后端自带 icon-512.png 生成）
├─ scripts/
│  ├─ bp_utils.sh                   install_python：stdlib 落包 + .so→.framework
│  ├─ prepare_backend.py            backend 复制 + iOS 兼容补丁
│  └─ _selftest.py                  Python 层兼容自检（本地就能跑）
└─ backend/                         ← 运行时由 prepare_backend.py 生成，不入库
```

## 构建

CI 已配好：`.github/workflows/build-ipa.yml`，push 到 `main` 自动出包，
也可在 Actions 页手动 `workflow_dispatch`。产物：

- Actions Artifacts：`SigninHub-ipa`（含 `SigninHub.ipa` + sha256）
- Release：`ios-v2.62.<run_number>` 标签下挂 IPA

本地有 Mac 的话：

```bash
cd ios
python3 scripts/prepare_backend.py
curl -fL -o /tmp/py.tar.gz \
  https://github.com/beeware/Python-Apple-support/releases/download/3.11-b13/Python-3.11-iOS-support.b13.tar.gz
tar -xzf /tmp/py.tar.gz Python.xcframework && mv Python.xcframework .
brew install xcodegen && xcodegen generate
xcodebuild -project SigninHub.xcodeproj -scheme SigninHub -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build
mkdir -p Payload && cp -R build/Build/Products/Release-iphoneos/SigninHub.app Payload/
zip -qry SigninHub.ipa Payload
```

## 装到手机

IPA 是**未签名**的（CI 上没有证书），直接用 **TrollStore / 巨魔** 打开安装即可，
TrollStore 会自己签名（含 `Frameworks/` 下的 Python.framework 和上百个扩展模块框架）。

## 已处理的关键坑

| 坑 | 处理 |
|---|---|
| `vault.py` 顶层 `from ctypes import wintypes`（Windows 专用），iOS 导入即崩 | `prepare_backend.py` 注入纯 Python 桩；DPAPI 分支本来就被 `sys.platform=="win32"` 挡住 |
| `config.py` 的 `DATA_DIR.mkdir()` 落在只读的 .app 里 | 启动时 `SIGNBOT_DATA` 指向沙盒 `Application Support/signinhub` |
| 后端首次启动自动生成随机访问口令、只打印控制台 → 界面全线 401 | App 侧生成固定 token，写进 `config.json` 的 `server.api_token`，并在页面脚本前注入 `sessionStorage["signhub_token"]` |
| `sys.executable` 决定 `AppleFrameworkLoader` 找框架的根路径 | `PyConfig.executable` 设为 app 主二进制路径 |
| 扩展模块是 `.so`，iOS 只认 framework | `bp_utils.sh` 把 `lib-dynload/*.so` 逐个转成 `Frameworks/X.framework` + 留 `.fwork` 指针 |
| iOS 没有常驻后台服务 | `UIBackgroundModes=audio` + 循环播放静音音频保活（巨魔签名不受审核限制） |
| 主线程持有 GIL，Python 线程起不来 | 初始化完 `PyEval_SaveThread()` |

## 已知限制（相对安卓版）

- 网页上的「本机凭据读取」(Qoder/MiniMax) 在 iOS 上无意义；`qoder.py` 依赖
  `cryptography`（C 扩展，未编 iOS 版），该接口会失败，不影响签到主流程。
- 「浏览器模式」（Playwright）不可用 —— Playwright 无 iOS 版。接口模式与官方协议直连不受影响。
- 安卓的「无障碍自动点击兜底」iOS 无对应 API，不可实现。
- 定时签到依赖保活是否被系统压制；长期不唤醒时，回到前台会由后端补跑当天窗口。
