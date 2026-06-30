#!/usr/bin/env python3
"""Announce a release to a Telegram group via the Bot API.

The announcement text is the release commit message you write — no LLM. Write
the release commit's body as the finished, post-ready copy (see CLAUDE.md →
"Release announcements"); this script posts that verbatim and attaches the built
app (the Sparkle .zip) so people can download it straight from the group. If the
commit has no body, it falls back to a bullet list of the commit subjects since
the last release.

Configuration (all via env):
  TELEGRAM_BOT_TOKEN   bot token from @BotFather                  (required)
  TELEGRAM_CHAT_ID     target group/chat id (negative for groups) (required)
  APP_ZIP              path to the app zip to attach (optional; defaults to
                       build/sparkle/WhisperMaster-<version>.zip if present)
  R2_PUBLIC_BASE_URL   base url of the R2 feed (used only for the link fallback
                       when no app zip is attached)
  RANGE_BEFORE         git sha the push started from (github.event.before)
  RANGE_AFTER          git sha the push ended at    (github.sha); default HEAD

If either of the two required vars is missing the script logs and exits 0, so a
repo without Telegram configured still releases fine.
"""
from __future__ import annotations

import os
import plistlib
import subprocess
import sys
import urllib.parse
import urllib.request

INFO_PLIST = "Resources/Info.plist"
ZEROS = "0" * 40
CAPTION_LIMIT = 1024  # Telegram caption max length


def version() -> str:
    with open(INFO_PLIST, "rb") as fh:
        return plistlib.load(fh)["CFBundleShortVersionString"]


def git(*args: str) -> str:
    return subprocess.run(
        ["git", *args], capture_output=True, text=True, check=True
    ).stdout.strip()


def previous_release_tag() -> str | None:
    """The most recent `v*` tag reachable from HEAD — i.e. the previous release.

    Runs *before* the current release is tagged, so `git describe` returns the
    prior release tag, giving an accurate "everything since last release" range
    even when the changes were spread across several pushes.
    """
    try:
        return git("describe", "--tags", "--abbrev=0", "--match", "v*", "HEAD")
    except subprocess.CalledProcessError:
        return None


def commit_range() -> str:
    """Range to read commits from: prefer last-release-tag..HEAD; otherwise fall
    back to this push's range, then to the last 20 commits."""
    after = os.environ.get("RANGE_AFTER", "").strip() or "HEAD"
    tag = previous_release_tag()
    if tag:
        return f"{tag}..{after}"
    before = os.environ.get("RANGE_BEFORE", "").strip()
    if before and before != ZEROS:
        return f"{before}..{after}"
    return f"{after}~20..{after}"


def is_noise(subject: str) -> bool:
    """Housekeeping commits not worth announcing."""
    if "[skip release]" in subject:
        return True
    if subject.startswith(("Merge ", "release:", "bump ")):
        return True
    if subject.startswith("build:") and "bump" in subject:
        return True
    return False


def release_notes_bullets() -> list[str]:
    """Commit subjects since the last release, newest first, de-noised."""
    after = os.environ.get("RANGE_AFTER", "").strip() or "HEAD"
    try:
        raw = git("log", "--no-merges", "--pretty=format:%s", commit_range())
    except subprocess.CalledProcessError:
        raw = git("log", "--no-merges", "-1", "--pretty=format:%s", after)
    subjects = [s.strip() for s in raw.splitlines() if s.strip()]
    notes = [s for s in subjects if not is_noise(s)]
    return notes or subjects  # fall back to raw if filtering emptied it


def head_commit_body() -> str:
    """The body (everything after the subject line) of the commit that triggered
    this release. This is the hand-written announcement."""
    after = os.environ.get("RANGE_AFTER", "").strip() or "HEAD"
    body = git("log", "-1", "--pretty=format:%b", after).strip()
    # Drop trailers like "[skip release]" that aren't part of the announcement.
    lines = [ln for ln in body.splitlines() if "[skip release]" not in ln]
    return "\n".join(lines).strip()


def esc(text: str) -> str:
    """Escape for Telegram HTML parse mode."""
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def post_text(ver: str) -> str:
    """The announcement to post: the release commit body verbatim, or a bullet
    changelog if the commit has no body. HTML-escaped for Telegram."""
    body = head_commit_body()
    if body:
        return esc(body)
    bullets = release_notes_bullets()
    lines = [f"<b>🚀 Whisper Master {esc(ver)}</b>", ""]
    if bullets:
        lines += [f"• {esc(b)}" for b in bullets]
    return "\n".join(lines).strip()


def app_zip(ver: str) -> str | None:
    """Path to the app zip to attach, if it exists."""
    candidate = os.environ.get("APP_ZIP", "").strip() or f"build/sparkle/WhisperMaster-{ver}.zip"
    return candidate if os.path.isfile(candidate) else None


def download_link(ver: str) -> str | None:
    base = os.environ.get("R2_PUBLIC_BASE_URL", "").rstrip("/")
    if not base:
        return None
    url = f"{base}/WhisperMaster-{ver}.zip"
    return f'⬇️ <a href="{esc(url)}">Download {esc(ver)}</a>'


def send_message(token: str, chat_id: str, text: str) -> None:
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
        raise RuntimeError(f"Telegram sendMessage rejected: {body}")


def send_document(token: str, chat_id: str, file_path: str, caption: str | None) -> None:
    """Upload a file to the chat via multipart/form-data (stdlib only)."""
    boundary = "----WhisperMasterBoundaryQ1W2E3R4T5"
    sep = f"--{boundary}\r\n".encode()

    def field(name: str, value: str) -> bytes:
        return (
            sep
            + f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode()
            + value.encode()
            + b"\r\n"
        )

    with open(file_path, "rb") as fh:
        file_bytes = fh.read()
    filename = os.path.basename(file_path)

    body = field("chat_id", chat_id)
    if caption:
        body += field("caption", caption)
        body += field("parse_mode", "HTML")
    body += (
        sep
        + f'Content-Disposition: form-data; name="document"; filename="{filename}"\r\n'.encode()
        + b"Content-Type: application/zip\r\n\r\n"
        + file_bytes
        + b"\r\n"
        + f"--{boundary}--\r\n".encode()
    )

    req = urllib.request.Request(
        f"https://api.telegram.org/bot{token}/sendDocument",
        data=body,
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
    )
    with urllib.request.urlopen(req, timeout=180) as resp:
        resp_body = resp.read().decode()
    if '"ok":true' not in resp_body:
        raise RuntimeError(f"Telegram sendDocument rejected: {resp_body}")


def main() -> int:
    token = os.environ.get("TELEGRAM_BOT_TOKEN", "").strip()
    chat_id = os.environ.get("TELEGRAM_CHAT_ID", "").strip()
    if not token or not chat_id:
        print(">> Telegram not configured (TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID); skipping.")
        return 0

    ver = version()
    text = post_text(ver)
    zip_path = app_zip(ver)

    print(">> Posting release announcement to Telegram:")
    print(text)

    if zip_path:
        print(f">> Attaching {zip_path}")
        if len(text) <= CAPTION_LIMIT:
            send_document(token, chat_id, zip_path, caption=text)
        else:
            # Caption too long for one message — post the text, then the file.
            send_message(token, chat_id, text)
            send_document(token, chat_id, zip_path, caption=None)
    else:
        link = download_link(ver)
        if link:
            text = f"{text}\n\n{link}"
        send_message(token, chat_id, text)

    print(">> Sent.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
