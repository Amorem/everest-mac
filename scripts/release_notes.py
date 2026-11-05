#!/usr/bin/env python3
"""Release notes and manifests from ReleaseNotes/<version>.json.

  release_notes.py html   <notes.json> <out.html>
  release_notes.py latest <notes.json> --build N --dmg PATH --url URL --min-os 13.0 > latest.json
  release_notes.py link   <appcast.xml> <version> <url>   # adds sparkle:releaseNotesLink
"""
import argparse
import datetime
import hashlib
import html
import json
import os
import re
import sys

PAGE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>Everest for Mac {version}</title>
<style>
  :root {{ --bg: #fff; --card: #f6f8fb; --border: #e5e9f0; --text: #0b1220; --muted: #5b6475; }}
  @media (prefers-color-scheme: dark) {{
    :root {{ --bg: #0f1626; --card: #182136; --border: #2b3a5c; --text: #eef2f7; --muted: #9aa4b5; }}
  }}
  * {{ box-sizing: border-box; }}
  body {{ margin: 0; background: var(--bg); color: var(--text); font: 15px/1.55 -apple-system, BlinkMacSystemFont, sans-serif; }}
  main {{ max-width: 620px; margin: 0 auto; padding: 32px 24px 40px; }}
  h1 {{ margin: 0; font-size: 24px; }}
  .meta, .headline, p {{ color: var(--muted); }}
  .meta {{ font-size: 13px; margin-bottom: 12px; }}
  .headline {{ font-size: 16px; margin: 0 0 20px; }}
  ul {{ list-style: none; margin: 0; padding: 0; display: grid; gap: 10px; }}
  li {{ padding: 14px 16px; background: var(--card); border: 1px solid var(--border); border-radius: 12px; }}
  h2 {{ margin: 0 0 2px; font-size: 15px; }}
  p {{ margin: 0; font-size: 14px; }}
</style>
</head>
<body>
<main>
  <h1>Everest for Mac {version}</h1>
  <div class="meta">{date}</div>
  <p class="headline">{headline}</p>
  <ul>
{items}
  </ul>
</main>
</body>
</html>
"""


def load(path):
    with open(path, encoding="utf-8") as f:
        notes = json.load(f)
    for key in ("version", "date", "headline", "items"):
        if not notes.get(key):
            sys.exit(f"{path}: missing {key}")
    return notes


def cmd_html(args):
    notes = load(args.notes)
    items = "\n".join(
        f"    <li><h2>{html.escape(i['title'])}</h2><p>{html.escape(i['detail'])}</p></li>" for i in notes["items"]
    )
    date = datetime.date.fromisoformat(notes["date"]).strftime("%B %-d, %Y")
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as f:
        f.write(PAGE.format(version=html.escape(notes["version"]), date=date, headline=html.escape(notes["headline"]), items=items))


def cmd_latest(args):
    notes = load(args.notes)
    digest = hashlib.sha256()
    with open(args.dmg, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            digest.update(chunk)
    released = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    json.dump(
        {
            "version": notes["version"],
            "build": args.build,
            "releasedAt": released,
            "minimumSystemVersion": args.min_os,
            "url": args.url,
            "size": os.path.getsize(args.dmg),
            "sha256": digest.hexdigest(),
            "notes": [f"{i['title']}: {i['detail']}" for i in notes["items"]],
        },
        sys.stdout,
        indent=2,
    )
    print()


def cmd_link(args):
    with open(args.appcast, encoding="utf-8") as f:
        xml = f.read()
    marker = f"<sparkle:shortVersionString>{args.version}</sparkle:shortVersionString>"
    if marker not in xml:
        sys.exit(f"{args.version} is not in {args.appcast}")
    if args.url not in xml:
        xml = xml.replace(marker, f"{marker}\n            <sparkle:releaseNotesLink>{args.url}</sparkle:releaseNotesLink>", 1)
    with open(args.appcast, "w", encoding="utf-8") as f:
        f.write(xml)


parser = argparse.ArgumentParser()
sub = parser.add_subparsers(required=True)
p = sub.add_parser("html"); p.add_argument("notes"); p.add_argument("out"); p.set_defaults(run=cmd_html)
p = sub.add_parser("latest"); p.add_argument("notes"); p.add_argument("--build", required=True); p.add_argument("--dmg", required=True)
p.add_argument("--url", required=True); p.add_argument("--min-os", required=True); p.set_defaults(run=cmd_latest)
p = sub.add_parser("link"); p.add_argument("appcast"); p.add_argument("version"); p.add_argument("url"); p.set_defaults(run=cmd_link)
args = parser.parse_args()
args.run(args)
