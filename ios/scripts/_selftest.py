# -*- coding: utf-8 -*-
"""本地自检：模拟 iOS 环境（屏蔽 ctypes.wintypes）+ 用 SIGNBOT_DATA 指向可写目录，
验证补丁后的后端能否导入、serve 能否起来、API 与网页是否可用。

不是 iOS 真机测试，只验证「Python 层」的兼容补丁是否成立。
"""
import os
import sys
import threading
import time
import json
import tempfile
import urllib.request
import urllib.error

HERE = os.path.dirname(os.path.abspath(__file__))
BACKEND = os.path.join(os.path.dirname(HERE), "backend")
PORT = 8788

# ---- 模拟 iOS：让 from ctypes import wintypes 失败 ----
class _BlockWintypes:
    def find_module(self, name, path=None):
        if name == "ctypes.wintypes":
            raise ImportError("simulated: no ctypes.wintypes on iOS")
        return None
    def find_spec(self, name, path=None, target=None):
        if name == "ctypes.wintypes":
            raise ImportError("simulated: no ctypes.wintypes on iOS")
        return None

sys.meta_path.insert(0, _BlockWintypes())
try:
    import ctypes
    sys.modules.pop("ctypes.wintypes", None)
    if hasattr(ctypes, "wintypes"):
        delattr(ctypes, "wintypes")
except Exception as e:
    print("prep warn:", e)

# ---- 模拟 iOS 沙盒：可写数据目录 ----
data_dir = tempfile.mkdtemp(prefix="signhub_data_")
os.environ["SIGNBOT_DATA"] = data_dir
os.environ["PYTHONDONTWRITEBYTECODE"] = "1"
# 模拟 PyRunner 注入的口令（与 kBootstrhCode 里那段完全一致）
FIXED_TOKEN = "aabbccddeeff00112233445566778899"
os.environ["SIGNHUB_TOKEN"] = FIXED_TOKEN
sys.path.insert(0, BACKEND)

print("python:", sys.version.split()[0])
print("data_dir:", data_dir)

try:
    import signbot
    print("import signbot: OK ->", signbot.__file__)
    from signbot import vault as _v
    print("import signbot.vault: OK (wintypes shim)")

    # ==== 与 PyRunner.m 的 kBootstrapCode 相同的口令注入段 ====
    tok = os.environ.get("SIGNHUB_TOKEN") or ""
    if tok:
        from signbot.config import update_config
        def _set(cur):
            cur.setdefault("server", {})["api_token"] = tok
        update_config(_set)
        print("api_token injected: OK")

    from signbot.server import serve
    print("import signbot.server: OK")
except Exception:
    import traceback
    traceback.print_exc()
    sys.exit(1)

errors = []
def _run():
    try:
        serve(host="127.0.0.1", port=PORT)
    except BaseException as e:
        errors.append(e)
        import traceback; traceback.print_exc()

threading.Thread(target=_run, daemon=True).start()

def token():
    try:
        import json as _j
        with open(os.path.join(data_dir, "config.json"), "r", encoding="utf-8-sig") as f:
            return (_j.load(f).get("server") or {}).get("api_token") or ""
    except Exception:
        return ""

def get(path, timeout=5):
    url = "http://127.0.0.1:%d%s" % (PORT, path)
    headers = {"Host": "127.0.0.1:%d" % PORT}
    tok = token()
    if tok:
        headers["X-API-Token"] = tok
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()

# 等服务起来（要求带口令后 /api/ping 返回 200）
ok = False
last = None
for i in range(60):
    if errors:
        break
    try:
        st, body = get("/api/ping")
        last = (st, body[:120])
        if st == 200:
            print("GET /api/ping ->", st, body[:200])
            ok = True
            break
    except Exception as e:
        last = ("EXC", str(e)[:120])
    time.sleep(0.5)

if not ok:
    print("FAIL: 服务没起来或口令不对，last =", last, "errors =", errors[:1])
    sys.exit(2)

results = {}
for path in ["/api/status", "/api/config", "/api/stats", "/api/logs", "/api/auto_status"]:
    try:
        st, body = get(path, timeout=15)
        results[path] = (st, len(body))
    except Exception as e:
        results[path] = ("ERR", str(e)[:120])

for path in ["/", "/static/app.js", "/manifest.webmanifest"]:
    try:
        st, body = get(path, timeout=10)
        results[path] = (st, len(body))
    except Exception as e:
        results[path] = ("ERR", str(e)[:120])

print("\n=== API / 静态资源 ===")
for k, v in results.items():
    print("%-24s %s" % (k, v))

print("\n=== 数据目录内容 ===")
for f in sorted(os.listdir(data_dir)):
    p = os.path.join(data_dir, f)
    print("  %s (%d bytes)" % (f, os.path.getsize(p) if os.path.isfile(p) else -1))

bad = [k for k, v in results.items() if v[0] == "ERR" or (isinstance(v[0], int) and v[0] >= 500)]
print("\n结果:", "PASS" if not bad else ("FAIL " + str(bad)))
sys.exit(0 if not bad else 3)
