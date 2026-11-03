#!/usr/bin/env python3
"""T100: read a bulk export with generic tools only (PyYAML + markdown-it-py, CommonMark), no Amaranth code.
Rendering uses linkify (as GFM and Obsidian autolink URLs, www. and e-mail addresses; bare domains without a scheme
are left alone, as in GFM), so meeting text that would become a clickable link is caught. Needs linkify-it-py.

usage: read-export.py <destination>   (the folder that contains amaranth/)
Checks every meeting folder: front matter parses as YAML with the expected keys; meeting_id matches the folder name and
meeting.json; the Markdown parses; its only links are amaranth:// citations; it has no raw HTML; manifest hashes
match the files. Prints a summary and exits non-zero on any failure.
"""
import hashlib, json, os, re, sys
import yaml
from markdown_it import MarkdownIt

root = os.path.join(sys.argv[1], "amaranth")
manifest = json.load(open(os.path.join(root, "manifest.json")))
md = MarkdownIt("commonmark", {"linkify": True}).enable("linkify")
md.linkify.set({"fuzzy_link": False})
UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
KEYS = {"schema", "version", "meeting_id", "library_id", "title", "start", "time_zone", "duration_seconds", "folder", "people",
        "transcript", "transcript_included", "notes", "notes_stale", "transcript_lines_removed", "audio", "transcript_revision",
        "notes_revision", "fingerprint", "read_at", "citation"}
failures, meetings, links, lines = [], 0, 0, 0

def walk(tokens):
    for t in tokens:
        yield t
        if t.children:
            yield from walk(t.children)

for name in sorted(os.listdir(root)):
    d = os.path.join(root, name)
    if not os.path.isdir(d) or name.startswith("."):
        continue
    meetings += 1
    if not UUID.match(name):
        failures.append(f"{name}: folder is not a UUID")
    text = open(os.path.join(d, "meeting.md"), encoding="utf-8").read()
    if not text.startswith("---\n"):
        failures.append(f"{name}: no front matter"); continue
    front, body = text[4:].split("\n---\n", 1)
    fm = yaml.safe_load(front)
    if set(fm) != KEYS:
        failures.append(f"{name}: keys {sorted(set(fm) ^ KEYS)}")
    js = json.load(open(os.path.join(d, "meeting.json"), encoding="utf-8"))
    if not (fm["meeting_id"] == name == js["meetingID"] and fm["fingerprint"] == js["fingerprint"] and fm["title"] == js["title"]):
        failures.append(f"{name}: ids/fingerprint/title differ between md, json and folder")
    if js["format"] != "amaranth-meeting" or js["version"] != 1:
        failures.append(f"{name}: json format {js['format']} v{js['version']}")
    tokens = md.parse(body)
    for t in walk(tokens):
        if t.type in ("html_block", "html_inline"):
            failures.append(f"{name}: raw HTML {t.content[:40]!r}")
        if t.type == "link_open":
            links += 1
            if not t.attrs.get("href", "").startswith("amaranth://meeting/" + name):
                failures.append(f"{name}: link {t.attrs.get('href')!r}")
        if t.type == "image":
            failures.append(f"{name}: image")
    h1 = [t for t in tokens if t.type == "heading_open" and t.tag == "h1"]
    if len(h1) != 1:
        failures.append(f"{name}: {len(h1)} top headings")
    lines += sum(1 for l in js["transcript"])

for e in manifest["meetings"]:
    for f in e["files"]:
        p = os.path.join(root, f["path"])
        if os.path.exists(p) and hashlib.sha256(open(p, "rb").read()).hexdigest() != f["sha256"] and e["status"] != "kept":
            failures.append(f"manifest hash mismatch {f['path']}")

print(f"meetings={meetings} transcript_lines={lines} links={links} manifest={manifest['status']} failures={len(failures)}")
for f in failures[:20]:
    print("FAIL", f)
sys.exit(1 if failures else 0)
