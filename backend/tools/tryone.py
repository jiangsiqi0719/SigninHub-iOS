"""Try ONE provider right now and print the raw result (debug helper).

Run (inside backend/):
    python tools/tryone.py workbuddy

ASCII-only output for Windows console compatibility.
"""
import os
import sys
import json

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

from signbot import db, runner  # noqa: E402
from signbot.config import load_config  # noqa: E402
from signbot.provider import build_providers  # noqa: E402


def safe(s):
    """Avoid UnicodeEncodeError / mojibake on GBK consoles."""
    try:
        enc = sys.stdout.encoding or "utf-8"
        return str(s).encode(enc, "replace").decode(enc)
    except Exception:
        return str(s)


def main():
    if len(sys.argv) < 2:
        print("usage: python tools/tryone.py <workbuddy|traesolo>")
        sys.exit(1)
    key = sys.argv[1].strip().lower()
    cfg = load_config()
    providers = build_providers(cfg)
    if key not in providers:
        print("unknown provider: %s (choose: %s)" % (key, ", ".join(providers)))
        sys.exit(1)
    prov = providers[key]
    print("provider :", key)
    print("mode     :", (cfg["providers"][key].get("mode") or "http"))
    print("dry-run  :", prov.is_dry_run())
    print("running...")
    res = runner.run_one(key)
    print("-" * 60)
    print("status   :", res.get("status"))
    print("http     :", res.get("http_status"))
    print("points   :", res.get("points"))
    print("message  :", safe(res.get("message")))
    detail = res.get("detail") or ""
    if detail:
        print("detail   :", safe(detail[:800]))
    print("-" * 60)
    print("tip: if status=fail, read 'message'/'detail'. "
          "For browser mode run: python tools/login.py " + key)


if __name__ == "__main__":
    main()