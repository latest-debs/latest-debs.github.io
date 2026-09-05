#!/usr/bin/env python3
"""Regenerate the <noscript> package list inside index.html.

The package table is client-rendered from tools.yaml, which makes the
catalog invisible to crawlers and JS-less visitors. The <noscript> block
in the Packages section is the static fallback; run this whenever
apt-repo's tools.yaml changes so the fallback can't drift:

    python3 generate-noscript.py

Reads the tracking keys straight from tools.yaml (same source the live
table uses) and rewrites only the <noscript>...</noscript> region.
"""
import re
import sys
import urllib.request

TOOLS_YAML = "https://raw.githubusercontent.com/latest-debs/apt-repo/main/tools.yaml"
INDEX = "index.html"

with urllib.request.urlopen(TOOLS_YAML) as r:
    text = r.read().decode()

names = sorted(m.group(1) for m in re.finditer(r"^([a-z0-9][a-z0-9._+-]*):\s*$", text, re.M))
if not names:
    sys.exit("no tool entries parsed from tools.yaml - refusing to write an empty fallback")

items = "".join(f"<li>{n}</li>" for n in names)
replacement = (
    "<noscript>\n"
    "      <ul style=\"columns:2; -webkit-columns:2; gap:2rem; font-size:.92rem;\">\n"
    "        " + items + "\n"
    "      </ul>\n"
    "      <p class=\"tag\">Enable JavaScript to see per-package versions and the Debian comparison columns, or browse <a href=\"https://github.com/latest-debs/apt-repo/blob/main/tools.yaml\">tools.yaml</a> directly.</p>\n"
    "    </noscript>"
)

with open(INDEX) as f:
    html = f.read()

new_html, count = re.subn(r"<noscript>.*?</noscript>", replacement, html, count=1, flags=re.S)
if count != 1:
    sys.exit("expected exactly one <noscript> block in index.html, found %d" % count)

with open(INDEX, "w") as f:
    f.write(new_html)

print("wrote %d tools into the noscript fallback" % len(names))
