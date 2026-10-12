"""Pinned, resumable, cancellable model downloads for the voice tiers.

Replaces `huggingface_hub.snapshot_download`, which (through its hf_xet transfer backend) hung mid-file on a
slow connection with the bytes counter frozen, no error, and no way to stop it from another thread.

Here every file is a plain HTTPS GET of the pinned revision, written to disk as the bytes arrive:

- **Stalls end.** A read that sees no byte for `READ_TIMEOUT` seconds raises, and the file is retried from
  where it stopped. After `MAX_STALLS` attempts in a row without progress the download fails with a message
  that says so, instead of sitting at "running" forever.
- **Resume.** Bytes land in `<file>.part`; a retry (or a fresh Download after a cancel, a failure or a
  restart) continues it with a Range request. A file is renamed into place only when it's complete, so a
  half-written model file is never mistaken for a real one.
- **Cancel.** The cancel event is checked on every read and during the back-off waits, so Cancel takes effect
  at once. Partial files are kept, so downloading again resumes.
"""
from __future__ import annotations

import fnmatch
import os
import threading
from pathlib import Path
from typing import Callable, Iterable

import httpx

HF = "https://huggingface.co"
READ_TIMEOUT = 30.0       # seconds without a byte before a read counts as stalled
CONNECT_TIMEOUT = 15.0
MAX_STALLS = 6            # consecutive attempts without progress before giving up
PART_SUFFIX = ".part"


class Cancelled(Exception):
    pass


class DownloadError(Exception):
    pass


def list_files(repo: str, revision: str, allow_patterns: Iterable[str] | None) -> list[tuple[str, int]]:
    """(path, size) for every file in the pinned revision that the patterns allow (None = all)."""
    patterns = list(allow_patterns) if allow_patterns else None
    url: str | None = f"{HF}/api/models/{repo}/tree/{revision}?recursive=true"
    files: list[tuple[str, int]] = []
    with httpx.Client(timeout=httpx.Timeout(READ_TIMEOUT, connect=CONNECT_TIMEOUT),
                      follow_redirects=True) as client:
        while url:
            r = client.get(url)
            r.raise_for_status()
            for entry in r.json():
                if entry.get("type") != "file":
                    continue
                path = entry["path"]
                if patterns is None or any(fnmatch.fnmatch(path, p) for p in patterns):
                    files.append((path, int(entry.get("size", 0))))
            url = r.links.get("next", {}).get("url")    # the tree API pages large repos
    if not files:
        raise DownloadError(f"{repo}@{revision[:7]} has no files to download")
    return files


def bytes_on_disk(dest: Path, files: list[tuple[str, int]]) -> int:
    """What's already here: complete files plus partial ones."""
    total = 0
    for path, size in files:
        final = dest / path
        part = final.with_name(final.name + PART_SUFFIX)
        if final.exists() and final.stat().st_size == size:
            total += size
        elif part.exists():
            total += min(part.stat().st_size, size)
    return total


def fetch(repo: str, revision: str, files: list[tuple[str, int]], dest: Path,
          cancel: threading.Event, on_bytes: Callable[[int], None]) -> None:
    """Download every file into `dest`, reporting each chunk through `on_bytes`."""
    timeout = httpx.Timeout(READ_TIMEOUT, connect=CONNECT_TIMEOUT)
    with httpx.Client(timeout=timeout, follow_redirects=True) as client:
        for path, size in files:
            final = dest / path
            if final.exists() and final.stat().st_size == size:
                continue
            final.parent.mkdir(parents=True, exist_ok=True)
            part = final.with_name(final.name + PART_SUFFIX)
            _fetch_one(client, f"{HF}/{repo}/resolve/{revision}/{path}", part, size, cancel, on_bytes)
            os.replace(part, final)


def _fetch_one(client: httpx.Client, url: str, part: Path, size: int,
               cancel: threading.Event, on_bytes: Callable[[int], None]) -> None:
    stalls = 0
    while True:
        if cancel.is_set():
            raise Cancelled()
        have = part.stat().st_size if part.exists() else 0
        if have >= size:
            if have > size:                                  # can't happen with a sane server; start over
                part.unlink()
                continue
            return
        headers = {"Range": f"bytes={have}-"} if have else {}
        progressed = False
        try:
            with client.stream("GET", url, headers=headers) as r:
                if r.status_code == 416:                     # nothing left to send: already complete
                    return
                if r.status_code in (429,) or r.status_code >= 500:
                    raise httpx.HTTPStatusError(f"HTTP {r.status_code}", request=r.request, response=r)
                if r.status_code >= 400:
                    raise DownloadError(f"HTTP {r.status_code} for {url.rsplit('/', 1)[-1]}")
                if have and r.status_code == 200:            # server ignored the Range: rewrite from 0
                    on_bytes(-have)
                    have = 0
                with open(part, "ab" if have else "wb") as f:
                    # No chunk size: a fixed-size buffer would throw away its partial fill on a stall.
                    for chunk in r.iter_bytes():
                        if cancel.is_set():
                            raise Cancelled()
                        f.write(chunk)
                        on_bytes(len(chunk))
                        progressed = True
            if progressed:
                stalls = 0
                continue                                     # loop re-checks: done, or resume the rest
            reason = "the server closed the connection without sending data"
        except (Cancelled, DownloadError):
            raise
        except (httpx.TimeoutException, httpx.TransportError, httpx.HTTPStatusError) as e:
            if progressed:
                stalls = 0
                continue
            reason = type(e).__name__
        # No progress on this attempt: back off, and give up after MAX_STALLS in a row.
        stalls += 1
        if stalls >= MAX_STALLS:
            raise DownloadError(f"Download stalled — no data for {MAX_STALLS} tries in a row ({reason}). "
                                f"Check your connection, then Resume.")
        if cancel.wait(min(30, 2 ** stalls)):                # Cancel cuts the wait short
            raise Cancelled()
