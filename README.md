# latest-debs.github.io

Landing page for [latest-debs](https://github.com/latest-debs), the Debian
apt repository that tracks latest developer tool releases.

The apt repository itself lives in the
[apt-repo](https://github.com/latest-debs/apt-repo) project and is served at
`https://latest-debs.github.io/apt-repo/`.

## Maintenance scripts

- `generate-noscript.py` — regenerates the static `<noscript>` package list in
  `index.html` from apt-repo's `tools.yaml`. Run it whenever a tool is added so
  the JS-less/crawler-visible fallback can't drift from the live table.
- `generate-feed.py` — builds `feed.xml` from the org's published releases
  (needs `GH_TOKEN`). Run hourly in CI by `.github/workflows/feed.yml`; you
  only need it locally when testing the feed.
