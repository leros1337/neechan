#!/usr/bin/env bash
# Records 2ch API fixtures used by the test suites.
# Fixtures are trimmed (thread/post counts capped) so the repo stays small while
# keeping the exact JSON shape the server returns.
#
# Usage: Tools/record-fixtures.sh [board] [domain]
set -euo pipefail

BOARD="${1:-po}"
DOMAIN="${2:-2ch.org}"
UA='Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1'
OUT="$(cd "$(dirname "$0")/.." && pwd)/Packages/NeechanTestSupport/Sources/NeechanTestSupport/Fixtures"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

get() { curl -sS --fail --compressed -A "$UA" -H 'Accept: application/json' "https://$DOMAIN$1"; }

echo "Recording from https://$DOMAIN, board /$BOARD/ into $OUT"
mkdir -p "$OUT"

# --- boards ---------------------------------------------------------------
get /api/mobile/v2/boards > "$TMP/boards_full.json"
python3 - "$TMP/boards_full.json" "$OUT/boards.json" <<'PY'
import json, sys
boards = json.load(open(sys.argv[1]))
keep = {"b", "po", "a", "vg", "test", "news", "hc", "bi"}
subset = [b for b in boards if b.get("id") in keep]
missing = keep - {b.get("id") for b in subset}
if missing:
    print(f"  ! boards not found, skipped: {sorted(missing)}", file=sys.stderr)
json.dump(subset, open(sys.argv[2], "w"), ensure_ascii=False, indent=1)
print(f"  boards.json: {len(subset)} boards")
PY

# --- catalog --------------------------------------------------------------
get "/$BOARD/catalog.json" > "$TMP/catalog_full.json"
python3 - "$TMP/catalog_full.json" "$OUT/catalog.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["threads"] = d["threads"][:25]
json.dump(d, open(sys.argv[2], "w"), ensure_ascii=False, indent=1)
print(f"  catalog.json: {len(d['threads'])} threads")
PY

# --- paged index ----------------------------------------------------------
get "/$BOARD/index.json" > "$TMP/index_full.json"
python3 - "$TMP/index_full.json" "$OUT/index_page0.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["threads"] = d["threads"][:8]
json.dump(d, open(sys.argv[2], "w"), ensure_ascii=False, indent=1)
print(f"  index_page0.json: {len(d['threads'])} threads, pages={d.get('pages')}")
PY
get "/$BOARD/1.json" > "$TMP/page1_full.json"
python3 - "$TMP/page1_full.json" "$OUT/index_page1.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["threads"] = d["threads"][:4]
json.dump(d, open(sys.argv[2], "w"), ensure_ascii=False, indent=1)
print(f"  index_page1.json: current_page={d.get('current_page')}")
PY

# --- pick a thread with enough posts and at least one video ---------------
THREAD=$(python3 - "$TMP/catalog_full.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
best = None
for t in d["threads"]:
    if t.get("sticky"):
        continue
    if 20 <= t.get("posts_count", 0) <= 400:
        best = t
        break
print((best or d["threads"][0])["num"])
PY
)
echo "  using thread $THREAD"
get "/$BOARD/res/$THREAD.json" > "$TMP/thread_full.json"
python3 - "$TMP/thread_full.json" "$OUT/thread.json" "$OUT/thread_after.json" "$OUT/thread_after_empty.json" <<'PY'
import copy, json, sys
d = json.load(open(sys.argv[1]))
posts = d["threads"][0]["posts"]
head, tail = posts[:12], posts[12:16]
trimmed = copy.deepcopy(d)
trimmed["threads"][0]["posts"] = head
trimmed["posts_count"] = len(head)
trimmed["max_num"] = head[-1]["num"]
json.dump(trimmed, open(sys.argv[2], "w"), ensure_ascii=False, indent=1)
# /after returns the anchor post first, then the newer ones.
after = {"result": 1, "unique_posters": d.get("unique_posters", 1),
         "posts": [head[-1]] + tail}
json.dump(after, open(sys.argv[3], "w"), ensure_ascii=False, indent=1)
json.dump({"result": 1, "unique_posters": d.get("unique_posters", 1),
           "posts": [head[-1]]}, open(sys.argv[4], "w"), ensure_ascii=False, indent=1)
print(f"  thread.json: {len(head)} posts, max_num={trimmed['max_num']}")
print(f"  thread_after.json: {len(tail)} new posts")
PY

get "/api/mobile/v2/info/$BOARD/$THREAD" | python3 -m json.tool --no-ensure-ascii > "$OUT/thread_info.json"
FIRST_POST=$(python3 -c "import json;print(json.load(open('$OUT/thread.json'))['threads'][0]['posts'][0]['num'])")
get "/api/mobile/v2/post/$BOARD/$FIRST_POST" | python3 -m json.tool --no-ensure-ascii > "$OUT/post_single.json"
get "/api/mobile/v2/after/$BOARD/$THREAD/0" | python3 -m json.tool --no-ensure-ascii > "$OUT/error_no_post.json"

# --- search ---------------------------------------------------------------
curl -sS --fail --compressed -A "$UA" -X POST "https://$DOMAIN/user/search?json=1" \
     -F "board=$BOARD" -F 'text=аниме' > "$TMP/search_full.json"
python3 - "$TMP/search_full.json" "$OUT/search_result.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
if "posts" in d:
    d["posts"] = d["posts"][:6]
json.dump(d, open(sys.argv[2], "w"), ensure_ascii=False, indent=1)
print(f"  search_result.json: {len(d.get('posts', []))} posts")
PY
curl -sS --compressed -A "$UA" -X POST "https://$DOMAIN/user/search?json=1" \
     -F "board=$BOARD" -F 'text=a' | python3 -m json.tool --no-ensure-ascii > "$OUT/search_too_short.json"

# --- captcha --------------------------------------------------------------
get "/api/captcha/settings/$BOARD" | python3 -m json.tool --no-ensure-ascii > "$OUT/captcha_settings.json"
get "/api/captcha/emoji/id?board=$BOARD" > "$TMP/emoji_id.json"
python3 -m json.tool --no-ensure-ascii < "$TMP/emoji_id.json" > "$OUT/captcha_emoji_id.json"
EMOJI_ID=$(python3 -c "import json;print(json.load(open('$TMP/emoji_id.json')).get('id',''))")
if [ -n "$EMOJI_ID" ]; then
  get "/api/captcha/emoji/show?id=$EMOJI_ID" > "$TMP/emoji_show.json"
  python3 - "$TMP/emoji_show.json" "$OUT/captcha_emoji_show.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
# Base64 PNGs are large; truncate to keep the fixture small but keep the shape.
if "image" in d:
    d["image"] = d["image"][:512]
if "keyboard" in d:
    d["keyboard"] = [k[:256] for k in d["keyboard"]]
json.dump(d, open(sys.argv[2], "w"), ensure_ascii=False, indent=1)
print(f"  captcha_emoji_show.json: keyboard={len(d.get('keyboard', []))} keys")
PY
fi

# --- proof of work --------------------------------------------------------
python3 - "$TMP/emoji_id.json" "$OUT/pow_case.json" <<'PY'
import hashlib, json, sys
d = json.load(open(sys.argv[1]))
ch = d.get("challenge")
if not ch:
    print("  ! no challenge in emoji/id response, writing synthetic case", file=sys.stderr)
    ch = {"template": "neechan-%d-fixture", "limit": 20000}
    ch["hash"] = hashlib.sha512(ch["template"].replace("%d", "1337").encode()).hexdigest()
    answer = 1337
else:
    answer = None
    for i in range(ch["limit"]):
        if hashlib.sha512(ch["template"].replace("%d", str(i)).encode()).hexdigest() == ch["hash"]:
            answer = i
            break
json.dump({"challenge": ch, "expectedAnswer": answer},
          open(sys.argv[2], "w"), ensure_ascii=False, indent=1)
print(f"  pow_case.json: answer={answer} (limit {ch['limit']})")
PY

# --- comment corpus -------------------------------------------------------
# /b is pulled in as well: it is the board where cross-thread reply links,
# spoilers and administrative markup actually show up.
get "/b/catalog.json" > "$TMP/b_catalog.json" || true
B_THREAD=$(python3 -c "
import json
d = json.load(open('$TMP/b_catalog.json'))
cands = [t for t in d['threads'] if not t.get('sticky') and t.get('posts_count', 0) > 50]
print((cands or d['threads'])[0]['num'])
" 2>/dev/null || echo "")
if [ -n "$B_THREAD" ]; then
  get "/b/res/$B_THREAD.json" > "$TMP/b_thread.json" || true
fi
python3 - "$TMP/catalog_full.json" "$TMP/thread_full.json" "$TMP/b_thread.json" "$OUT/comment_samples.json" <<'PY'
import json, os, sys
seen, out = set(), []
for path in sys.argv[1:-1]:
    if not os.path.exists(path):
        continue
    d = json.load(open(path))
    posts = []
    if "threads" in d:
        for t in d["threads"]:
            posts.extend(t.get("posts", []) if isinstance(t, dict) and "posts" in t else [t])
    for p in posts:
        c = (p.get("comment") or "").strip()
        if c and c not in seen and len(c) < 4000:
            seen.add(c)
            out.append({"num": p["num"], "comment": c})
# Keep everything that carries markup first, then pad with plain comments, so
# the corpus stays small but exercises the parser.
def score(entry):
    html = entry["comment"]
    return (
        ("post-reply-link" in html) * 4
        + ("spoiler" in html) * 3
        + ("unkfunc" in html) * 2
        + ("<" in html)
    )
out.sort(key=score, reverse=True)
json.dump(out[:120], open(sys.argv[-1], "w"), ensure_ascii=False, indent=1)
print(f"  comment_samples.json: {len(out[:120])} comments, "
      f"{sum('post-reply-link' in e['comment'] for e in out[:120])} with reply links")
PY

echo "Done. Fixture sizes:"
du -ch "$OUT"/*.json | tail -1
