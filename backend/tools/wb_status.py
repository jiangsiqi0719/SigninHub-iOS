"""只读探测 WorkBuddy 签到状态：验证基址/请求头/协议是否正确。不会领取签到。

用法（在 backend/ 目录下）：
    python tools/wb_status.py
"""
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

from signbot import workbuddy as wb  # noqa: E402


def main():
    print("=" * 64)
    print(" WorkBuddy 只读状态探测（不会签到/不会领取）")
    print("=" * 64)
    creds, problems = wb.discover_credentials()
    print("发现的凭据数:", len(creds))
    for p in problems:
        print("  [!]", p)
    if not creds:
        print("没有可用凭据。")
        return
    for c in creds:
        print("-" * 64)
        print("账号:", c.account_id(), "| 来源:", c.source, "| 区域:", wb.region_of(c.domain))
        print("token:", c.masked(), "| uid:", (c.uid[:8] + "…") if c.uid else "-")
        try:
            st = wb.fetch_status(c)
            print("  今日已签到 :", st["today_checked_in"])
            print("  连续天数   :", st["streak_days"])
            print("  每日积分   :", st["daily_credit"])
            print("  今日积分   :", st["today_credit"])
            print("  活动有效   :", st["active"])
            if st["claim_button_text"]:
                print("  按钮文案   :", st["claim_button_text"])
            print("  [OK] 协议验证通过")
        except Exception as e:
            print("  [FAIL]", type(e).__name__, str(e)[:300])


if __name__ == "__main__":
    main()