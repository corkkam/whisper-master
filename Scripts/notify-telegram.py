#!/usr/bin/env python3
"""Announce a release to a Telegram group via the Bot API.

Posts the new version plus formatted release notes (the commit subjects in this
push) so the message can be copied/edited for Twitter or elsewhere. Designed to
run at the end of the CI release job, but works locally too.

Configuration (all via env):
  TELEGRAM_BOT_TOKEN   bot token from @BotFather                 (required)
  TELEGRAM_CHAT_ID     target group/chat id (negative for groups) (required)
  R2_PUBLIC_BASE_URL   base url of the R2 feed (for the download link)
  RANGE_BEFORE         git sha the push started from (github.event.before)
  RANGE_AFTER          git sha the push ended at    (github.sha); default HEAD

If either of the two required vars is missing the script logs and exits 0, so a
repo without Telegram configured still releases fine.
"""
import os
import plistlib
import subprocess
import sys
import urllib.parse
import urllib.request

INFO_PLIST = "Resources/Info.plist"
ZEROS = "0" * 40


def version() -> str:
    with open(INFO_PLIST, "rb") as fh:
        return plistlib.load(fh)["CFBundleShortVersionString"]


def git(*args: str) -> str:
    return subprocess.run(
        ["git", *args], capture_output=True, text=True, check=True
    ).stdout.strip()


def release_notes() -> list[str]:
    """Commit subjects introduced by this push, newest first, de-noised."""
    before = os.environ.get("RANGE_BEFORE", "").strip()
    after = os.environ.get("RANGE_AFTER", "").strip() or "HEAD"

    rng = f"{before}..{after}" if before and before != ZEROS else f"{after}~20..{after}"
    try:
        raw = git("log", "--no-merges", "--pretty=format:%s", rng)
    except subprocess.CalledProcessError:
        raw = git("log", "--no-merges", "-1", "--pretty=format:%s")

    subjects = [s.strip() for s in raw.splitlines() if s.strip()]
    # Drop housekeeping commits that aren't worth announcing.
    skip = ("[skip release]", "Merge ", "bump to ", "bump version", "build: bump")
    notes = [s for s in subjects if not any(tok in s for tok in skip)]
    return notes or subjects  # fall back to raw if filtering emptied it


def esc(text: str) -> str:
    """Escape for Telegram HTML parse mode."""
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def build_message(ver: str, notes: list[str]) -> str:
    lines = [f"<b>🚀 Whisper Master {esc(ver)}</b>", ""]
    if notes:
        lines.append("<b>What's new</b>")
        lines += [f"• {esc(n)}" for n in notes]
        lines.append("")
    base = os.environ.get("R2_PUBLIC_BASE_URL", "").rstrip("/")
    if base:
        url = f"{base}/WhisperMaster-{ver}.zip"
        lines.append(f'⬇️ <a href="{esc(url)}">Download {esc(ver)}</a>')
    return "\n".join(lines).strip()


def send(token: str, chat_id: str, text: str) -> None:
    data = urllib.parse.urlencode(
        {
            "chat_id": chat_id,
            "text": text,
            "parse_mode": "HTML",
            "disable_web_page_preview": "true",
        }
    ).encode()
    req = urllib.request.Request(
        f"https://api.telegram.org/bot{token}/sendMessage", data=data
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        body = resp.read().decode()
    if '"ok":true' not in body:
        raise RuntimeError(f"Telegram API rejected the message: {body}")


def main() -> int:
    token = os.environ.get("TELEGRAM_BOT_TOKEN", "").strip()
    chat_id = os.environ.get("TELEGRAM_CHAT_ID", "").strip()
    if not token or not chat_id:
        print(">> Telegram not configured (TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID); skipping.")
        return 0

    ver = version()
    notes = release_notes()
    message = build_message(ver, notes)
    print(">> Posting release announcement to Telegram:")
    print(message)
    send(token, chat_id, message)
    print(">> Sent.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
