"""Probe: plain HTTP GET of a YouTube watch page (no browser, no cookies) and report what comes back."""

from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.error
import urllib.request

USER_AGENT = (
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 '
    '(KHTML, like Gecko) Version/17.0 Safari/605.1.15'
)


def fetch(url: str, user_agent: str | None) -> tuple[int, str, dict[str, str], str]:
    """Returns (status, final_url, headers, body) without raising on HTTP error statuses."""
    headers = {'Accept-Language': 'en-US,en;q=0.9'}
    if user_agent:
        headers['User-Agent'] = user_agent
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            return resp.status, resp.geturl(), dict(resp.headers), resp.read().decode('utf-8', errors='replace')
    except urllib.error.HTTPError as e:
        return e.code, url, dict(e.headers), e.read().decode('utf-8', errors='replace')


def extract_player_response(html: str) -> dict | None:
    """Pulls the ytInitialPlayerResponse JSON object embedded in the watch page, if present."""
    m = re.search(r'ytInitialPlayerResponse\s*=\s*', html)
    if not m:
        return None
    try:
        obj, _ = json.JSONDecoder().raw_decode(html, m.end())
        return obj
    except json.JSONDecodeError:
        return None


def report(status: int, final_url: str, headers: dict[str, str], body: str) -> None:
    print(f'status:       {status}')
    print(f'final url:    {final_url}')
    print(f'content-type: {headers.get("Content-Type")}')
    print(f'body size:    {len(body):,} chars')
    print(f'set-cookie:   {"yes" if "Set-Cookie" in headers else "no"}')

    if 'consent.youtube.com' in final_url or 'consent.google.com' in final_url:
        print('!! redirected to a consent wall (common for EU IPs)')
    if '/sorry/' in final_url:
        print('!! looks like a captcha / "sorry" bot page')

    title = re.search(r'<title>(.*?)</title>', body, re.S)
    print(f'<title>:      {title.group(1).strip() if title else None}')

    player = extract_player_response(body)
    if player is None:
        print('ytInitialPlayerResponse: not found')
        return

    playability = player.get('playabilityStatus', {})
    print(f'playability:  {playability.get("status")} {playability.get("reason") or ""}'.rstrip())

    details = player.get('videoDetails', {})
    print(f'video title:  {details.get("title")}')
    print(f'author:       {details.get("author")}')
    print(f'length (s):   {details.get("lengthSeconds")}')

    streaming = player.get('streamingData', {})
    if not streaming:
        print('streamingData: absent')
        return
    print(f'hlsManifestUrl:  {"present" if streaming.get("hlsManifestUrl") else "absent"}')
    print(f'dashManifestUrl: {"present" if streaming.get("dashManifestUrl") else "absent"}')
    adaptive = streaming.get('adaptiveFormats', [])
    with_url = sum(1 for f in adaptive if 'url' in f)
    with_cipher = sum(1 for f in adaptive if 'signatureCipher' in f)
    print(f'adaptiveFormats: {len(adaptive)} total, {with_url} direct url, {with_cipher} signatureCipher')


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('url', help='YouTube watch URL')
    parser.add_argument('--no-ua', action='store_true', help="send Python's default User-Agent instead of Safari's")
    parser.add_argument('--save', metavar='PATH', help='write the raw response body to PATH')
    args = parser.parse_args()

    status, final_url, headers, body = fetch(args.url, None if args.no_ua else USER_AGENT)
    report(status, final_url, headers, body)

    if args.save:
        with open(args.save, 'w', encoding='utf-8') as f:
            f.write(body)
        print(f'saved body -> {args.save}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
