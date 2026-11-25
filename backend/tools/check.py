"""Config doctor: tell you whether each provider can really sign in.

Run (inside backend/):
    python tools/check.py

Output is ASCII-only so it renders correctly in any Windows console.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

from signbot.config import load_config, DATA_DIR  # noqa: E402

PH = re.compile(r"^[A-Z0-9_]{4,}$")


def is_placeholder(v):
    if not isinstance(v, str):
        return False
    s = v.strip()
    if s.upper().startswith(("WORKBUDDY_", "TRAESOLO_", "APP_", "TARGET", "TOKEN")):
        return True
    return bool(PH.match(s) and "_" in s and "://" not in s and "@" not in s)


def main():
    cfg = load_config()
    line = "=" * 64
    print(line)
    print("  SigninHub config doctor")
    print(line)
    try:
        import playwright  # noqa: F401
        has_pw = True
    except Exception:
        has_pw = False
    print("Playwright installed :", "yes" if has_pw else "no (required for browser mode)")
    print("Data dir             :", DATA_DIR)
    print("-" * 64)

    all_ok = True
    for key, p in cfg.get("providers", {}).items():
        mode = (p.get("mode") or "http").lower()
        print("\n[%s]  mode=%s  enabled=%s" % (key, mode, p.get("enabled", True)))
        if mode == "wb":
            wb_cfg = p.get("wb", {}) or {}
            if (wb_cfg.get("accessToken") or "").strip():
                print("   [v] accessToken filled -> will call the official check-in protocol")
            else:
                try:
                    from signbot import workbuddy as wbmod
                    creds, problems = wbmod.discover_credentials()
                    want = (wb_cfg.get("region") or "").strip().lower()
                    if want in ("cn", "global"):
                        creds = [c for c in creds if wbmod.region_of(c.domain) == want]
                    if creds:
                        print("   [v] found %d credential(s) on this machine" % len(creds))
                        for c in creds[:3]:
                            print("       - %s (%s, %s)" % (c.account_id(), c.source, wbmod.region_of(c.domain)))
                    else:
                        all_ok = False
                        print("   [x] no usable credential -> paste accessToken in settings, or log in to WorkBuddy")
                        for pr in problems[:3]:
                            print("       ! " + pr[:120])
                except Exception as e:
                    all_ok = False
                    print("   [x] workbuddy module unavailable: %s" % e)
        elif mode == "http":
            h = p.get("http", {})
            url = h.get("url", "")
            hdrs = h.get("headers", {}) or {}
            bad = []
            if is_placeholder(url):
                bad.append("http.url is still a placeholder -> need the real sign-in endpoint")
            for k, v in hdrs.items():
                if is_placeholder(v):
                    bad.append("header %s is still a placeholder -> need real value (Cookie/Authorization)" % k)
            if bad:
                all_ok = False
                for b in bad:
                    print("   [x] " + b)
                print("   ==> this provider currently runs in DEMO mode (no real request)")
            else:
                print("   [v] http config complete -> will send a REAL request")
        elif mode == "browser":
            b = p.get("browser", {})
            sig = b.get("sign_url") or ""
            if is_placeholder(sig) or not sig:
                all_ok = False
                print("   [x] browser.sign_url is empty / placeholder -> need the real sign-in page URL")
            state = os.path.join(DATA_DIR, b.get("storage_state") or ("%s_state.json" % key))
            if os.path.exists(state):
                print("   [v] login state found: " + os.path.basename(state))
            else:
                all_ok = False
                print("   [x] login state missing -> run: python tools/login.py " + key)
            if not has_pw:
                all_ok = False
                print("   [x] Playwright not installed -> pip install playwright && playwright install chromium")
            if sig and not is_placeholder(sig) and os.path.exists(state) and has_pw:
                print("   [v] browser mode ready -> will open the page and click sign-in")
        else:
            all_ok = False
            print("   [x] unknown mode '%s' (use http or browser)" % mode)

    print("\n" + line)
    if all_ok:
        print("RESULT: all providers ready for REAL check-in")
    else:
        print("RESULT: some providers still in DEMO mode until configured")
    print(line)


if __name__ == "__main__":
    main()