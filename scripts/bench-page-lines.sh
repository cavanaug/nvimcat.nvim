#!/usr/bin/env bash
# Empirical sweep of NVIMCAT_STITCH_HEIGHT on tall markdown fixtures.
# (NVIMCAT_PAGE_LINES no longer affects paint height — output must be PAGE_LINES-invariant.)
# Usage:
#   scripts/bench-page-lines.sh
#   scripts/bench-page-lines.sh --pages 100,250,500,1000
#   scripts/bench-page-lines.sh --max-lines 4000   # truncate huge inputs
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PAGES="${NVIMCAT_BENCH_PAGES:-100,150,200,250,300,400,500,750,1000}"
MAX_LINES="${NVIMCAT_BENCH_MAX_LINES:-4000}"
WIDTH="${NVIMCAT_BENCH_WIDTH:-100}"
TIMEOUT_S="${NVIMCAT_BENCH_TIMEOUT:-120}"
OUT_DIR="${NVIMCAT_BENCH_OUT:-$ROOT/.bench-page-lines}"
# Fresh run dir avoids stale TSV rows from interrupted prior sweeps.
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
CORPUS="$OUT_DIR/corpus"
mkdir -p "$CORPUS"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pages) PAGES="$2"; shift 2 ;;
    --max-lines) MAX_LINES="$2"; shift 2 ;;
    --width) WIDTH="$2"; shift 2 ;;
    --timeout) TIMEOUT_S="$2"; shift 2 ;;
    --out) OUT_DIR="$2"; CORPUS="$OUT_DIR/corpus"; mkdir -p "$OUT_DIR" "$CORPUS"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Curated from user's largest .md list (+ pathological tables fixture).
# Skip: nvim undo blobs, near-duplicates (nightly rust, staging litho, build/podman, nvim-lazy snacks).
SOURCES=(
  "/home/cavanaug/wip_other/src_cavanaug/zoom-cli/.opencode/skills/zoom-skills/oauth/references/granular-scopes.md|tables"
  "/home/cavanaug/.local/share/nvim/lazy/snacks.nvim/tests/image/big.md|mixed"
  "/home/cavanaug/wip_hp/src/ghes_internal/PersonalSystemsDataScience/hp-agentdeck/graphify-out/GRAPH_REPORT.md|report"
  "/home/cavanaug/.vscode-server/extensions/eamodio.gitlens-18.2.0/changelog.md|changelog"
  "/home/cavanaug/wip_hp/src/ghes_internal/john-cavanaugh/podman-trixie/podman-5.6.1+ds1/RELEASE_NOTES.md|prose"
  "/home/cavanaug/.local/zed.app/licenses.md|licenses"
)

prepare_corpus() {
  local src tag dest head_file
  for entry in "${SOURCES[@]}"; do
    src="${entry%%|*}"
    tag="${entry##*|}"
    dest="$CORPUS/${tag}.md"
    if [[ ! -f "$src" ]]; then
      echo "SKIP missing $src" >&2
      continue
    fi
    # Cap line count so a full page sweep stays practical.
    head -n "$MAX_LINES" "$src" >"$dest"
    head_file="$CORPUS/${tag}.head"
    # Stable needles: rendered markdown often conceals # / turns - into ●.
    python3 - "$dest" "$head_file" <<'PY'
import re, sys
from pathlib import Path

def needle(s: str) -> str:
    s = re.sub(r"^[#*\-\s\d.]+", "", s.strip())
    # Drop markdown link targets; rendered output often conceals URLs.
    s = re.sub(r"\([^)]*\)", "", s)
    s = re.sub(r"\[[^\]]*\]", lambda m: m.group(0)[1:-1], s)
    s = re.sub(r"\s+", " ", s).strip(" #")
    return s[:40]

text = Path(sys.argv[1]).read_text(errors="replace")
lines = [ln for ln in text.splitlines() if ln.strip()]
head = needle(lines[0]) if lines else ""
tail = needle(lines[-1]) if lines else ""
# Prefer a mid/late unique line for tail if last line is too short.
if len(tail) < 12 and len(lines) > 10:
    for ln in reversed(lines):
        n = needle(ln)
        if len(n) >= 12:
            tail = n
            break
Path(sys.argv[2]).write_text(head)
Path(sys.argv[2] + ".tail").write_text(tail)
print(f"corpus {Path(sys.argv[1]).name}: lines={text.count(chr(10))+1} head={head!r} tail={tail!r}")
PY
  done
}

prepare_corpus

RESULTS="$OUT_DIR/results.tsv"
echo -e "tag\tpage_lines\tseconds\tout_lines\tok\tbytes" >"$RESULTS"

IFS=',' read -r -a PAGE_ARR <<<"$PAGES"
for md in "$CORPUS"/*.md; do
  [[ -f "$md" ]] || continue
  tag=$(basename "$md" .md)
  head_n=$(cat "$CORPUS/${tag}.head")
  for page in "${PAGE_ARR[@]}"; do
    out="$OUT_DIR/${tag}-p${page}.out"
    err="$OUT_DIR/${tag}-p${page}.err"
    start=$(date +%s%3N)
    set +e
    NVIMCAT_STITCH_HEIGHT="$page" NVIMCAT_TIMEOUT="$TIMEOUT_S" \
      timeout $((TIMEOUT_S + 15)) \
      "$ROOT/bin/nvimcat" --width "$WIDTH" "$md" >"$out" 2>"$err"
    rc=$?
    set -e
    end=$(date +%s%3N)
    elapsed_ms=$((end - start))
    elapsed=$(python3 -c "print(f'{${elapsed_ms}/1000:.3f}')")
    eval "$(python3 - "$out" "$md" "$head_n" <<'PY'
import re, sys
from pathlib import Path
raw = Path(sys.argv[1]).read_bytes() if Path(sys.argv[1]).exists() else b""
src = Path(sys.argv[2]).read_text(errors="replace")
head_n = sys.argv[3]
src_lines = src.count("\n") + (0 if src.endswith("\n") or not src else 1)
plain = re.sub(rb"\x1b\[[0-9;]*m", b"", raw).decode("utf-8", "replace")
out_lines = plain.count("\n") + (0 if plain.endswith("\n") or not plain else 1)
head_ok = bool(head_n) and head_n in plain
cover_ok = out_lines >= max(50, int(src_lines * 0.85))
ok = 1 if (head_ok and cover_ok) else 0
print(f"out_lines={out_lines}")
print(f"ok={ok}")
print(f"nbytes={len(raw)}")
PY
)"
    if [[ $rc -ne 0 ]]; then ok=0; fi
    echo -e "${tag}\t${page}\t${elapsed}\t${out_lines}\t${ok}\t${nbytes}" >>"$RESULTS"
    echo "bench tag=$tag page=$page sec=$elapsed lines=$out_lines ok=$ok rc=$rc"
  done
done

python3 - "$RESULTS" <<'PY'
"""Pick best PAGE_LINES: minimize geometric mean of successful times; require ok=1."""
import math
import sys
from collections import defaultdict
from pathlib import Path

rows = []
for line in Path(sys.argv[1]).read_text().splitlines()[1:]:
    tag, page, sec, out_lines, ok, nbytes = line.split("\t")
    rows.append(
        {
            "tag": tag,
            "page": int(page),
            "sec": float(sec),
            "out_lines": int(out_lines),
            "ok": ok == "1",
            "nbytes": int(nbytes),
        }
    )

by_page = defaultdict(list)
for r in rows:
    by_page[r["page"]].append(r)

print("\n=== summary by PAGE_LINES ===")
print(f"{'page':>6} {'geomean_s':>10} {'ok_rate':>8} {'n':>4} {'notes'}")
ranked = []
for page in sorted(by_page):
    rs = by_page[page]
    oks = [r for r in rs if r["ok"]]
    ok_rate = len(oks) / len(rs) if rs else 0
    if oks:
        g = math.exp(sum(math.log(max(r["sec"], 0.001)) for r in oks) / len(oks))
    else:
        g = float("inf")
    note = ""
    if ok_rate < 1:
        note = f"FAILS {[r['tag'] for r in rs if not r['ok']]}"
    print(f"{page:6d} {g:10.3f} {ok_rate:8.0%} {len(rs):4d} {note}")
    ranked.append((-ok_rate, g, page, ok_rate))

ranked.sort()
# Prefer full success, then lowest geomean.
full = [r for r in ranked if r[3] >= 1.0]
pick = full[0] if full else ranked[0]
print("\n=== per-file winners (min sec among ok) ===")
by_tag = defaultdict(list)
for r in rows:
    by_tag[r["tag"]].append(r)
for tag in sorted(by_tag):
    oks = [r for r in by_tag[tag] if r["ok"]]
    if not oks:
        print(f"{tag}: NO SUCCESS")
        continue
    best = min(oks, key=lambda r: r["sec"])
    print(f"{tag}: best_page={best['page']} sec={best['sec']:.3f} lines={best['out_lines']}")

if pick[3] > 0:
    best_page = pick[2]
    print(f"\nRECOMMEND NVIMCAT_STITCH_HEIGHT / default = {best_page}")
    print(
        f"(lowest geomean among fully-successful stitch heights)"
        if full
        else "(best available; some failures)"
    )
else:
    print("\nNO RECOMMENDATION (no successful page size)")
    raise SystemExit(1)
PY
