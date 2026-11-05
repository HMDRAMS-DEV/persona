"""Seeds the starter gallery through the same create pipeline the app uses.

Needs the server running (the app, or .venv/bin/python server/persona.py).
Two at a time: Muse Wonder and Muse Image overlap while Glimmer reads one trait at a time.
Run: .venv/bin/python scripts/starters.py
"""
import json
from concurrent.futures import ThreadPoolExecutor

import httpx

STARTERS = [
    "A dry-witted writing editor who makes your drafts shorter and sharper, with a raised eyebrow.",
    "An over-the-top workout hype coach who thinks every rep you do is legendary.",
    "A cozy grandmother chef who helps you cook with what's in the fridge and calls you dear.",
]


def make(description):
    with httpx.stream("POST", "http://127.0.0.1:4410/personas", json={"description": description}, timeout=900) as r:
        for line in r.iter_lines():
            if not line.startswith("data: "):
                continue
            e = json.loads(line[6:])
            if "error" in e:
                return f"FAILED {description[:40]}: {e['error']}"
            if "label" in e:
                print(f"  {e['label']}", flush=True)
            if "done" in e:
                d = e["done"]
                return f"{d['name']} ({d['bytes'] // 1024} KB): {d['intro']}"


with ThreadPoolExecutor(2) as pool:
    for result in pool.map(make, STARTERS):
        print(result, flush=True)
