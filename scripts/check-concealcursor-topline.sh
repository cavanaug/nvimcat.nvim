#!/usr/bin/env bash
# Cursor/topline must keep markdown links concealed (concealcursor=nvic).
# Soft-break hard-cut can park lnum on a mid-table row; concealcursor=""
# used to reveal raw [text](url) on that row only.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=check-lib.sh
source "$ROOT/scripts/check-lib.sh"

TMP="$(mktemp --suffix=.md)"
OUT="$(mktemp)"
trap 'rm -f "$TMP" "$OUT" "$OUT.err"' EXIT

{
  echo "# concealcursor topline"
  echo
  echo "| API Endpoint | Granular Scopes |"
  echo "|--------------|-----------------|"
  # header + sep + 998 pads = 1000 lines → hard-cut; next segment starts on probe link.
  for i in $(seq 1 998); do
    echo "| pad-row-$i | \`scope-$i\` |"
  done
  echo "| [List channel videos](/docs/api/rest/reference/https:/developers.zoom.us/docs/api/methods/#operation/ListChannelVideos) | \`video_mgmt:read:list_channel_videos\` |"
  echo "| [Delete channel videos](/docs/api/rest/reference/https:/developers.zoom.us/docs/api/methods/#operation/DeleteChannelVideos) | \`video_mgmt:delete:channel_videos\` |"
} >"$TMP"

nvimcat_capture 90 "$OUT" -- --width 120 "$TMP"
assert_capture "$OUT" 50 "List channel videos" "Delete channel videos"

python3 - "$OUT" <<'PY'
import re, sys
from pathlib import Path
plain = re.sub(r"\x1b\[[0-9;]*m", "", Path(sys.argv[1]).read_text())
# Raw markdown link must not appear (cursor-line reveal regression).
if "](/docs/api" in plain or "](http" in plain:
    for i, ln in enumerate(plain.splitlines()):
        if "](/docs/api" in ln or "](http" in ln:
            print(f"FAIL raw link on capture line {i}: {ln[:160]!r}", file=sys.stderr)
            raise SystemExit(1)
    raise SystemExit("FAIL raw markdown link in capture")
if "ListChannelVideos" in plain:
    print("FAIL operation id leaked (unconcealed URL)", file=sys.stderr)
    raise SystemExit(1)
# Both neighboring titles should render as titles, not raw links.
if plain.count("List channel videos") < 1 or plain.count("Delete channel videos") < 1:
    raise SystemExit("FAIL missing rendered titles")
print("OK concealcursor-topline")
PY
