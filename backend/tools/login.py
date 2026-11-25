"""Capture login state for browser mode.

Run (inside backend/):
    python tools/login.py workbuddy
    python tools/login.py traesolo

It opens a visible Chromium window, you log in manually, press Enter, and the
login state is saved to data/<provider>_state.json for later sign-in runs.

Requires: pip install playwright && playwright install chromium
ASCII-only output for Windows console compatibility.
"""
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

from signbot.config import load_config, DATA_DIR  # noqa: E402


def main():
    if len(sys.argv) < 2:
        print("usage: python tools/login.py <workbuddy|traesolo>")
        sys.exit(1)
    key = sys.argv[1].strip().lower()
    cfg = load_config()
    providers = cfg.get("providers", {})
    if key not in providers:
        print("unknown provider: %s (choose from: %s)" % (key, ", ".join(providers)))
        sys.exit(1)

    b = providers[key].get("browser", {})
    login_url = b.get("login_url") or b.get("sign_url") or ""
    if not login_url or login_url.upper().startswith(("WORKBUDDY_", "TRAESOLO_")):
        print("[!] browser.login_url is empty or placeholder. Edit backend/data/config.json first.")
        sys.exit(1)
    state_name = b.get("storage_state") or ("%s_state.json" % key)
    state_path = os.path.join(DATA_DIR, state_name)

    try:
        from playwright.sync_api import sync_playwright
    except Exception:
        print("[!] Playwright not installed. Run:")
        print("    pip install playwright")
        print("    playwright install chromium")
        sys.exit(2)

    print("[*] opening: " + login_url)
    print("[*] log in in the window, then come back here and press Enter.")
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=False)
        ctx = browser.new_context()
        page = ctx.new_page()
        page.goto(login_url, timeout=60000)
        try:
            input(">>> press Enter after you have logged in... ")
        except EOFError:
            pass
        ctx.storage_state(path=state_path)
        browser.close()
    print("[OK] login state saved: " + state_path)
    print("[*] now set mode to \"browser\" for this provider in config.json")


if __name__ == "__main__":
    main()