#!/bin/bash
# Build or refresh the shared Zoekt index from the reference clone's refs/remotes/origin/<branch>.
# Usage: reindex.sh [--full]   (default: skip when up to date, otherwise delta build)
set -euo pipefail
self="$0"; [ -L "$self" ] && self="$(readlink "$self")"
. "$(dirname "$self")/bin/zk-config"
[ -n "$ZOEKT_REF_CLONE" ] || { echo "reindex: set ZOEKT_REF_CLONE in ~/.zoekt/config" >&2; exit 2; }
INDEX_DIR="$ZOEKT_INDEX_DIR"; LOG="$INDEX_DIR/index.log"; LOCK="$INDEX_DIR/.lock.d"
mkdir -p "$INDEX_DIR"
if ! mkdir "$LOCK" 2>/dev/null; then echo "reindex already running" >&2; exit 0; fi
trap 'rmdir "$LOCK"' EXIT
sha="$(git -C "$ZOEKT_REF_CLONE" rev-parse "refs/remotes/origin/$ZOEKT_BRANCH")"
if [ "${1:-}" != "--full" ] && [ -f "$INDEX_DIR/.commit" ] && [ "$(cat "$INDEX_DIR/.commit")" = "$sha" ]; then
  echo "$(date '+%F %T') up to date at $sha" >>"$LOG"; exit 0
fi
extra=()
[ "${1:-}" = "--full" ] || extra=(-delta -delta_threshold 20)
{
  echo "$(date '+%F %T') start $sha (${1:-incremental})"
  start=$(date +%s)
  zoekt-git-index -index "$INDEX_DIR" -branches "$ZOEKT_BRANCH" -prefix refs/remotes/origin/ \
    -parallelism "$ZOEKT_PARALLELISM" -submodules=false -incremental=true ${extra[@]+"${extra[@]}"} "$ZOEKT_REF_CLONE"
  echo "$sha" >"$INDEX_DIR/.commit"
  echo "$(date '+%F %T') done in $(( $(date +%s) - start )) s, size $(du -sh "$INDEX_DIR" | cut -f1)"
} >>"$LOG" 2>&1
