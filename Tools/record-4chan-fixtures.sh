#!/usr/bin/env bash
# Records 4chan API fixtures used by the test suites.
#
# A sibling of record-fixtures.sh rather than a branch inside it: that script is
# two hundred lines of 2ch-shaped trimming, and interleaving a second site's
# shapes would double every one of them for the sake of sharing `get`.
#
# Fixtures are trimmed (thread/post counts capped) so the repo stays small while
# keeping the exact JSON shape the server returns.
#
# Usage: Tools/record-4chan-fixtures.sh [board]
set -euo pipefail

BOARD="${1:-po}"
UA='Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1'
OUT="$(cd "$(dirname "$0")/.." && pwd)/Packages/NeechanTestSupport/Sources/NeechanTestSupport/Fixtures"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 4chan asks for no more than one request a second, and a recorder that ignores
# that is how this repository's CI address gets itself blocked.
get() { sleep 1; curl -sS --fail --compressed -A "$UA" -H 'Accept: application/json' "https://a.4cdn.org$1"; }

echo "Recording from https://a.4cdn.org, board /$BOARD/ into $OUT"
mkdir -p "$OUT"

# --- boards ---------------------------------------------------------------
get /boards.json > "$TMP/boards_full.json"
python3 - "$TMP/boards_full.json" "$OUT/fourchan_boards.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
# /3/ is here on purpose: it is the only all-digit board code either site has,
# and the one that board-code validation used to reject outright.
keep = {"3", "g", "po", "pol", "sci", "a", "vg", "wsg"}
d["boards"] = [b for b in d["boards"] if b.get("board") in keep]
missing = keep - {b["board"] for b in d["boards"]}
if missing:
    print(f"  ! boards not found, skipped: {sorted(missing)}", file=sys.stderr)
json.dump(d, open(sys.argv[2], "w"), ensure_ascii=False, indent=1)
print(f"  fourchan_boards.json: {len(d['boards'])} boards")
PY

# --- catalog --------------------------------------------------------------
get "/$BOARD/catalog.json" > "$TMP/catalog_full.json"
python3 - "$TMP/catalog_full.json" "$OUT/fourchan_catalog.json" <<'PY'
import json, sys
pages = json.load(open(sys.argv[1]))[:2]
for page in pages:
    page["threads"] = page["threads"][:5]
    for thread in page["threads"]:
        thread["last_replies"] = thread.get("last_replies", [])[:2]
json.dump(pages, open(sys.argv[2], "w"), ensure_ascii=False, indent=1)
print(f"  fourchan_catalog.json: {sum(len(p['threads']) for p in pages)} threads on {len(pages)} pages")
PY

# --- index page -----------------------------------------------------------
# Page 1, not 0: 4chan has no index.json and /po/0.json is a 404.
get "/$BOARD/1.json" > "$TMP/index_full.json"
python3 - "$TMP/index_full.json" "$OUT/fourchan_index_page1.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["threads"] = d["threads"][:5]
for thread in d["threads"]:
    thread["posts"] = thread["posts"][:3]
json.dump(d, open(sys.argv[2], "w"), ensure_ascii=False, indent=1)
print(f"  fourchan_index_page1.json: {len(d['threads'])} threads")
PY

# --- thread list ----------------------------------------------------------
# What the watcher polls: every thread on the board with its reply count.
get "/$BOARD/threads.json" > "$TMP/threads_full.json"
python3 - "$TMP/threads_full.json" "$OUT/fourchan_threads_index.json" <<'PY'
import json, sys
pages = json.load(open(sys.argv[1]))[:3]
json.dump(pages, open(sys.argv[2], "w"), ensure_ascii=False, indent=1)
print(f"  fourchan_threads_index.json: {sum(len(p['threads']) for p in pages)} threads")
PY

# --- one thread -----------------------------------------------------------
THREAD="$(python3 -c "import json,sys; print(json.load(open('$TMP/threads_full.json'))[0]['threads'][1]['no'])")"
get "/$BOARD/thread/$THREAD.json" > "$TMP/thread_full.json"
python3 - "$TMP/thread_full.json" "$OUT/fourchan_thread.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["posts"] = d["posts"][:12]
json.dump(d, open(sys.argv[2], "w"), ensure_ascii=False, indent=1)
print(f"  fourchan_thread.json: {len(d['posts'])} posts")
PY

# --- archive --------------------------------------------------------------
# A bare array of thread numbers: no titles, no dates.
get "/$BOARD/archive.json" > "$OUT/fourchan_archive.json"
python3 -c "
import json
print(f'  fourchan_archive.json: {len(json.load(open(\"$OUT/fourchan_archive.json\")))} threads')
"

# --- captcha --------------------------------------------------------------
# Saved whatever the status: the interesting case *is* the browser check, and
# the test that recognises it needs the real page rather than a hand-written one.
echo "Recording the captcha gate from https://sys.4chan.org"
sleep 1
STATUS="$(curl -sS -o "$OUT/fourchan_cloudflare_gate.html" -w '%{http_code}' \
    -A "$UA" -H "Referer: https://boards.4chan.org/$BOARD/" \
    "https://sys.4chan.org/captcha?board=$BOARD" || true)"
echo "  fourchan_cloudflare_gate.html: HTTP $STATUS"

python3 - "$OUT/fourchan_cloudflare_gate.html" <<'PY'
import sys
# Mirrors ChallengeDetector.bodyMarkers. A saved page containing none of them
# would make the detection test pass without testing anything.
markers = ["cf-challenge", "challenge-platform", "cf_chl_opt", "__cf_chl", "Just a moment"]
body = open(sys.argv[1], encoding="utf-8", errors="replace").read()
if not any(marker in body for marker in markers):
    print("  ! the saved page carries no challenge marker: the gate may be open,", file=sys.stderr)
    print("    in which case re-record when it is closed, or the detection test", file=sys.stderr)
    print("    is asserting nothing.", file=sys.stderr)
    sys.exit(1)
print("  carries a challenge marker, as the detection test expects")
PY

# The served captcha cannot be recorded while the gate is up, so the fixture is
# synthesized — the same thing record-fixtures.sh does for the proof-of-work
# case it cannot reach. Shape taken from the site's own captcha.js.
python3 - "$OUT/fourchan_captcha_challenge.json" "$OUT/fourchan_captcha_cooldown.json" <<'PY'
import base64, json, sys
# A 1x1 PNG stands in for the puzzle images: the tests decode them, they do not
# look at them, and nothing in this app ever tries to solve one.
pixel = base64.b64encode(base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
)).decode()
json.dump({
    "challenge": "synthetic-challenge-token",
    "img": pixel,
    "bg": pixel,
    "img_width": 300,
    "bg_width": 400,
    "ttl": 120,
}, open(sys.argv[1], "w"), indent=1)
json.dump({"error": "You have to wait a while before doing this again.", "cd": 27},
          open(sys.argv[2], "w"), indent=1)
print("  ! fourchan_captcha_challenge.json synthesized: the live endpoint is", file=sys.stderr)
print("    behind a browser check, so a served captcha cannot be recorded here.", file=sys.stderr)
print("  fourchan_captcha_challenge.json, fourchan_captcha_cooldown.json")
PY

echo "Done."
