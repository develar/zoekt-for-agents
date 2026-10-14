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
# Delta builds: -delta_threshold counts all shards (base + delta), so it must exceed the base shard
# count or zoekt falls back to a full build. Allow ZOEKT_DELTA_MAX (default 20) delta shards on top.
extra=()
if [ "${1:-}" != "--full" ]; then
  base="$(cat "$INDEX_DIR/.base_shards" 2>/dev/null || /bin/ls "$INDEX_DIR"/*.zoekt 2>/dev/null | wc -l | tr -d ' ')"
  extra=(-delta -delta_threshold $(( ${base:-0} + ${ZOEKT_DELTA_MAX:-20} )))
fi
{
  echo "$(date '+%F %T') start $sha (${1:-incremental})"
  start=$(date +%s)
  zoekt-git-index -index "$INDEX_DIR" -branches "$ZOEKT_BRANCH" -prefix refs/remotes/origin/ \
    -parallelism "$ZOEKT_PARALLELISM" -submodules=false -incremental=true ${extra[@]+"${extra[@]}"} "$ZOEKT_REF_CLONE"
  echo "$sha" >"$INDEX_DIR/.commit"
  [ "${1:-}" = "--full" ] && /bin/ls "$INDEX_DIR"/*.zoekt | wc -l | tr -d ' ' >"$INDEX_DIR/.base_shards"
  echo "$(date '+%F %T') done in $(( $(date +%s) - start )) s, size $(du -sh "$INDEX_DIR" | cut -f1)"
} >>"$LOG" 2>&1
