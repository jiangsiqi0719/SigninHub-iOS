#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
signinhub-ios / scripts/prepare_backend.py

把仓库根的 backend/ 复制到 ios/backend/，并打上 iOS 兼容补丁。
在 xcodegen 之前跑（workflow 里已串好）。

补丁清单
--------
1. signbot/vault.py
   顶层有 `from ctypes import wintypes`。iOS / Linux / macOS 上没有
   ctypes.wintypes（Windows 专用），导入即抛 ValueError，整个 server 起不来。
   替换成纯 Python 桩：DWORD 映射到 c_ulong，其它属性返回 c_void_p。
   真正的 DPAPI 调用都在 `_available()`（sys.platform == "win32"）之后，
   在 iOS 上永远不会执行；iOS 走的是 vault.py 自带的 `sealed:` HMAC 通道。

2. 清掉 requirements.txt / data / __pycache__
   - requirements.txt 只对电脑端浏览器模式（Playwright）有意义，iOS 用不上；
   - data/ 是电脑端历史数据，不能打进包（也不该带别人的配置）；
   - __pycache__ 里的 .pyc 是宿主机架构，混进包会干扰。

后端其余部分（server.py / provider.py / workbuddy.py / trae.py / huawei.py /
minimax.py / qoder.py / scheduler.py / notify.py / db.py …）在 iOS 上原样可跑：
纯标准库，_ssl / _sqlite3 / _hashlib / _ctypes / zlib 都由
Python-Apple-support 的 xcframework 提供。
qoder.py 里的 `cryptography` 是函数内延迟导入，缺失只影响「Qoder 本机凭据读取」
这一个接口，不影响签到主流程。
"""

import os
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
IOS_DIR = os.path.dirname(HERE)
REPO_ROOT = os.path.dirname(IOS_DIR)

SRC = os.path.join(REPO_ROOT, "backend")
DST = os.path.join(IOS_DIR, "backend")

IGNORE = shutil.ignore_patterns(
    "data", "__pycache__", "*.pyc", "*.pyo", "*.db", "*.db-journal",
    "requirements.txt", "*.log", "*.tmp",
)

VAULT_OLD = "from ctypes import wintypes"

VAULT_NEW = '''try:  # iOS / Linux / macOS：没有 Windows 专用的 ctypes.wintypes
    from ctypes import wintypes
except Exception:  # pragma: no cover - 非 Windows 平台走这里
    class _WinTypesShim:
        """给 vault.py 顶层的 Structure 定义提供最小桩。

        真正用到 DPAPI 的分支都被 _available()(sys.platform == "win32") 挡住，
        在 iOS 上永远不会执行到 windll 调用，所以这里只需要几个类型名。
        """
        DWORD = ctypes.c_ulong
        BOOL = ctypes.c_int
        LPWSTR = ctypes.c_wchar_p

        def __getattr__(self, _name):
            return ctypes.c_void_p

    wintypes = _WinTypesShim()
'''


def patch_vault(path: str) -> None:
    with open(path, "r", encoding="utf-8") as f:
        src = f.read()
    if "_WinTypesShim" in src:
        print("[prep] vault.py 已打过补丁，跳过")
        return
    if VAULT_OLD not in src:
        raise SystemExit(
            "[prep] FATAL: vault.py 结构已变化，找不到 `%s`，补丁失效。\n"
            "       请更新 ios/scripts/prepare_backend.py。" % VAULT_OLD
        )
    src = src.replace(VAULT_OLD, VAULT_NEW, 1)
    with open(path, "w", encoding="utf-8") as f:
        f.write(src)
    print("[prep] vault.py: ctypes.wintypes 已加非 Windows 兜底")


def patch_web_label(path: str) -> None:
    """把首页顶部的「电脑端」标签改成「iOS 本地」（纯文案，不动任何逻辑）。

    server.py 的 /api/ping 里 local 字段是写死 False 的（只有安卓的
    LocalApi.kt 会返回 true），前端只用它显示一行标签。这里只替换展示文案。
    """
    with open(path, "r", encoding="utf-8") as f:
        src = f.read()
    old = 'p.local ? "安卓本地" : "电脑端"'
    new = 'p.local ? "安卓本地" : "iOS 本地"'
    if new in src:
        print("[prep] app.js 文案已处理，跳过")
        return
    if old not in src:
        print("[prep] WARN: app.js 里没找到标签表达式，跳过文案修改")
        return
    src = src.replace(old, new, 1)
    with open(path, "w", encoding="utf-8") as f:
        f.write(src)
    print("[prep] app.js: 顶部标签改为「iOS 本地」")


def main() -> int:
    if not os.path.isdir(SRC):
        raise SystemExit("[prep] FATAL: 找不到 %s" % SRC)

    if os.path.isdir(DST):
        shutil.rmtree(DST)
    shutil.copytree(SRC, DST, ignore=IGNORE)
    print("[prep] backend 已复制 -> %s" % DST)

    patch_vault(os.path.join(DST, "signbot", "vault.py"))
    patch_web_label(os.path.join(DST, "web", "static", "app.js"))

    # 自检：关键文件必须在
    must = [
        "run.py",
        "signbot/server.py",
        "signbot/config.py",
        "signbot/db.py",
        "signbot/provider.py",
        "web/index.html",
        "web/static/app.js",
    ]
    missing = [m for m in must if not os.path.isfile(os.path.join(DST, m))]
    if missing:
        raise SystemExit("[prep] FATAL: 缺文件 %s" % missing)

    total = sum(len(files) for _, _, files in os.walk(DST))
    print("[prep] 自检通过，共 %d 个文件" % total)
    return 0


if __name__ == "__main__":
    sys.exit(main())
