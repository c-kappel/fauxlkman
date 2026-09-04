"""Browser-agent URL acquisition: drive a real Safari session to a YouTube watch page
and capture the HLS master playlist URL it requests, so downloader.py can take it from there.

One-time manual setup (not automated here, since it touches system/developer settings):
    - `pip install selenium`
    - Safari > Settings > Advanced > enable "Show Develop menu in menu bar"
    - Develop menu > "Allow Remote Automation"
    - Run `safaridriver --enable` once in Terminal (prompts for your password)

Known risk: this relies on the page's Resource Timing API (`performance.getEntriesByType
('resource')`) surfacing the native HLS manifest request. WebKit's native <video> HLS
pipeline is handled by AVFoundation below the page's JS/network stack, and it is NOT
confirmed that this always shows up in Resource Timing. If a live run times out without
ever seeing a `.m3u8` entry, the fallback is a local MITM proxy (e.g. mitmproxy) routed
through Safari's network settings instead of polling the page.
"""

from __future__ import annotations

import argparse
import sys
import time
import urllib.request

from selenium import webdriver
from selenium.webdriver.common.by import By

import downloader


def _log(msg: str) -> None:
    print(f'[fetch] {msg}', file=sys.stderr, flush=True)


def _all_resource_urls(driver) -> list[str]:
    return driver.execute_script("return performance.getEntriesByType('resource').map(e => e.name);")


def _resource_urls(driver, substring: str) -> list[str]:
    return [u for u in _all_resource_urls(driver) if substring in u]


_MEDIA_URL_HINTS = ('.m3u8', '.mpd', '.ts', '.m4s', '.mp4', '.webm', 'videoplayback', 'googlevideo')


def _log_media_like_resources(driver) -> None:
    urls = _all_resource_urls(driver)
    media_like = [u for u in urls if any(hint in u for hint in _MEDIA_URL_HINTS)]
    _log(f'diagnostic: {len(urls)} total resources observed, {len(media_like)} look media-related:')
    for u in media_like[:20]:
        _log(f'  {u}')
    if not media_like:
        _log('  (none — Safari is likely not fetching audio/video through the page-level '
             'network stack that Resource Timing observes; a proxy-based capture is the next step)')


def _looks_like_master_playlist(text: str) -> bool:
    tracks, _ = downloader.parse_master_playlist(text)
    return bool(tracks)


def _classify_candidates(candidate_urls: list[str]) -> str | None:
    for url in candidate_urls:
        try:
            with urllib.request.urlopen(url, timeout=5) as resp:  # noqa: S310
                text = resp.read().decode('utf-8', errors='ignore')
        except OSError:
            continue
        if _looks_like_master_playlist(text):
            return url
    return None


_AD_SKIP_SELECTORS = (
    '.ytp-ad-skip-button-modern',
    '.ytp-skip-ad-button',
    '.ytp-ad-skip-button',
)


def _movie_player_is_showing_ad(driver) -> bool:
    return bool(driver.execute_script(
        "const p = document.querySelector('#movie_player'); "
        "return p ? p.classList.contains('ad-showing') : false;"))


def _try_click_skip_button(driver) -> None:
    for selector in _AD_SKIP_SELECTORS:
        try:
            button = driver.find_element(By.CSS_SELECTOR, selector)
            if button.is_displayed() and button.is_enabled():
                button.click()
        except Exception:
            pass


def _wait_out_ad(driver, timeout: float = 90.0, poll_interval: float = 1.0) -> None:
    # Give the player a moment to initialize before checking, otherwise an ad that
    # hasn't started rendering yet reads as "no ad" and we start capturing too early.
    time.sleep(2)
    if not _movie_player_is_showing_ad(driver):
        _log('no ad detected')
        return
    _log(f'ad detected, waiting for it to clear (up to {timeout:.0f}s)...')
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if not _movie_player_is_showing_ad(driver):
            _log('ad cleared')
            return
        _try_click_skip_button(driver)
        time.sleep(poll_interval)
    raise TimeoutError(f'Ad did not clear within {timeout}s')


def find_master_playlist_url(
    youtube_url: str,
    timeout: float = 30.0,
    poll_interval: float = 1.0,
    ad_timeout: float = 90.0,
) -> str:
    driver = webdriver.Safari()
    try:
        driver.get(youtube_url)
        _wait_out_ad(driver, timeout=ad_timeout)
        # Resource Timing accumulates since page load, so anything recorded during the
        # ad is still in the buffer; clear it so only post-ad (content) requests count.
        driver.execute_script('performance.clearResourceTimings();')

        try:
            video = driver.find_element(By.TAG_NAME, 'video')
            driver.execute_script('arguments[0].play();', video)
        except Exception:
            pass  # playback may already be underway, or blocked pending a user gesture

        deadline = time.monotonic() + timeout
        seen: set[str] = set()
        while time.monotonic() < deadline:
            candidates = [u for u in _resource_urls(driver, '.m3u8') if u not in seen]
            seen.update(candidates)

            master_url = _classify_candidates(candidates)
            if master_url:
                return master_url

            time.sleep(poll_interval)

        _log_media_like_resources(driver)
        raise TimeoutError(f'No HLS master playlist observed within {timeout}s for {youtube_url}')
    finally:
        driver.quit()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Capture a YouTube video's HLS master playlist URL via a real Safari session.")
    parser.add_argument('youtube_url')
    parser.add_argument('--timeout', type=float, default=30.0,
                         help='Seconds to wait for the master playlist request (default: 30)')
    parser.add_argument('--ad-timeout', type=float, default=90.0,
                         help='Seconds to wait for a pre-roll ad to clear before capturing (default: 90)')
    args = parser.parse_args(argv)

    try:
        url = find_master_playlist_url(args.youtube_url, timeout=args.timeout, ad_timeout=args.ad_timeout)
    except TimeoutError as exc:
        print(str(exc), file=sys.stderr)
        return 1

    print(url)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
