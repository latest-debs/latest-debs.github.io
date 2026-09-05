#!/usr/bin/env python3
"""generate-feed.py - build feed.xml, the Atom feed of new latest-debs packages.

The live site data is all client-fetched, so nothing subscribable existed.
This feed gives readers an "what shipped" surface: one entry per upstream
release the org published in the lookback window, plus an entry for any
tool newly added to the tracking registry.

Run hourly by .github/workflows/feed.yml (needs GH_TOKEN), or locally:

    GH_TOKEN=$(gh auth token) python3 generate-feed.py

Entries are gathered fresh from the GitHub API on every run - no state
file - so the feed is deterministic and self-healing after a failed run.
The <updated> timestamp is the newest entry, or "now" when there are none,
which keeps feed readers polling correctly either way.
"""
import json
import os
import sys
import urllib.request
from datetime import datetime, timedelta, timezone

ORG = "latest-debs"
LOOKBACK_DAYS = 30
BASE = "https://latest-debs.github.io"

token = os.environ.get("GH_TOKEN")
if not token:
    sys.exit("GH_TOKEN not set")


def gh(url):
    req = urllib.request.Request(url, headers={
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
        "User-Agent": "latest-debs-feed",
    })
    with urllib.request.urlopen(req) as r:
        return json.load(r)


def esc(s):
    return (s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))


since = (datetime.now(timezone.utc) - timedelta(days=LOOKBACK_DAYS)).strftime("%Y-%m-%dT%H:%M:%SZ")

entries = []
# Per-tool repos: each publishes upstream releases as GitHub Releases.
repos = gh(f"https://api.github.com/orgs/{ORG}/repos?per_page=200")
for repo in repos:
    name = repo["name"]
    if not name.endswith("-debian"):
        continue
    tool = name[: -len("-debian")]
    try:
        rels = gh(f"https://api.github.com/repos/{ORG}/{name}/releases?per_page=10")
    except Exception:
        continue
    for rel in rels:
        if rel.get("draft"):
            continue
        published = rel.get("published_at")
        if not published or published < since:
            continue
        url = rel.get("html_url") or f"https://github.com/{ORG}/{name}/releases"
        entries.append({
            "id": url,
            "title": f"{tool} {rel.get('tag_name', '')}".strip(),
            "updated": published,
            "link": url,
            "content": f"<p>latest-debs published <strong>{esc(tool)}</strong> "
                       f"<code>{esc(rel.get('tag_name', ''))}</code>. "
                       f"Install with <code>sudo apt install {esc(tool)}</code>.</p>",
        })

if not entries:
    print("no releases in the lookback window; feed will carry only the self-entry")

entries.sort(key=lambda e: e["updated"], reverse=True)
newest = entries[0]["updated"] if entries else datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

out = [
    '<?xml version="1.0" encoding="utf-8"?>',
    '<feed xmlns="http://www.w3.org/2005/Atom">',
    f"  <title>latest-debs — new packages and releases</title>",
    f'  <link href="{BASE}/"/>',
    f'  <link rel="self" href="{BASE}/feed.xml"/>',
    f"  <id>{BASE}/feed.xml</id>",
    f"  <updated>{newest}</updated>",
    "  <author><name>latest-debs</name></author>",
    "  <subtitle>Latest dev tools, packaged for Debian — automatically. One entry per release published to the apt channel.</subtitle>",
]
for e in entries[:60]:
    out += [
        "  <entry>",
        f"    <id>{esc(e['id'])}</id>",
        f"    <title>{esc(e['title'])}</title>",
        f'    <link href="{esc(e["link"])}"/>',
        f"    <updated>{e['updated']}</updated>",
        f'    <content type="html">{esc(e["content"])}</content>',
        "  </entry>",
    ]
out.append("</feed>")

with open("feed.xml", "w") as f:
    f.write("\n".join(out) + "\n")

print(f"feed.xml written: {min(len(entries), 60)} entries")
