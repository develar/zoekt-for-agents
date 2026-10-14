#!/bin/bash
# Install zoekt-for-agents for the current user.
#
# Usage: ./install.sh --ref-clone <path> [--index-dir <dir>] [--branch master] [--marker <file>] [--exclude '^dotnet/']
#                     [--deps] [--claude] [--launchd] [--build]
#   --ref-clone  clone whose refs/remotes/origin/<branch> is indexed (required on first install)
#   --index-dir  where shards live (default ~/.zoekt/index)
#   --marker     file at the root of every clone of this repo (lets the Claude hook recognise clones cheaply)
#   --exclude    f: regex excluded from zk results unless --all or mentioned in the query
#   --deps       go install the zoekt binaries, brew install universal-ctags and ripgrep
#   --claude     merge claude/settings.snippet.json into ~/.claude/settings.json and append the CLAUDE.md snippet
#   --launchd    install an hourly reindex LaunchAgent (macOS)
#   --build      run the first full index build in the foreground
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
ref=""; idx=""; branch=""; marker=""; exclude=""; deps=0; claude=0; launchd=0; build=0
while [ $# -gt 0 ]; do
  case "$1" in
    --ref-clone) ref="$2"; shift;; --index-dir) idx="$2"; shift;; --branch) branch="$2"; shift;;
    --marker) marker="$2"; shift;; --exclude) exclude="$2"; shift;;
    --deps) deps=1;; --claude) claude=1;; --launchd) launchd=1;; --build) build=1;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown option $1" >&2; exit 2;;
  esac; shift
done
mkdir -p "$HOME/.local/bin" "$HOME/.zoekt"
cfg="$HOME/.zoekt/config"
if [ ! -f "$cfg" ]; then
  [ -n "$ref" ] || { echo "--ref-clone is required on first install" >&2; exit 2; }
  {
    echo "ZOEKT_REF_CLONE=$ref"
    echo "ZOEKT_INDEX_DIR=${idx:-$HOME/.zoekt/index}"
    echo "ZOEKT_BRANCH=${branch:-master}"
    [ -n "$marker" ] && echo "ZK_ROOT_MARKER=$marker"
    [ -n "$exclude" ] && echo "ZK_EXCLUDE=$exclude"
  } >"$cfg"
  echo "wrote $cfg"
else
  echo "keeping existing $cfg"
fi
. "$cfg"
for b in zk zkf zk-wt; do ln -sfn "$here/bin/$b" "$HOME/.local/bin/$b"; done
ln -sfn "$here/reindex.sh" "$HOME/.zoekt/reindex.sh"
echo "linked zk, zkf, zk-wt into ~/.local/bin and reindex.sh into ~/.zoekt"
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) echo "note: add $HOME/.local/bin to PATH";; esac

if [ "$deps" = 1 ]; then
  command -v go >/dev/null || { echo "go is required (brew install go)" >&2; exit 1; }
  go install github.com/sourcegraph/zoekt/cmd/zoekt-git-index@latest github.com/sourcegraph/zoekt/cmd/zoekt@latest
  (cd "$here" && go install ./cmd/zk-search)
  if command -v brew >/dev/null; then brew list universal-ctags >/dev/null 2>&1 || brew install universal-ctags; brew list ripgrep >/dev/null 2>&1 || brew install ripgrep; fi
  command -v universal-ctags >/dev/null || ln -sfn "$(command -v ctags)" "$HOME/.local/bin/universal-ctags"
fi

hook="$ZOEKT_REF_CLONE/.git/hooks/reference-transaction"
if [ -e "$hook" ] && [ ! -L "$hook" ]; then echo "note: $hook exists, not replaced; chain $here/hooks/git/reference-transaction from it"
else ln -sfn "$here/hooks/git/reference-transaction" "$hook"; echo "linked git hook into $ZOEKT_REF_CLONE"; fi

if [ "$launchd" = 1 ]; then
  plist="$HOME/Library/LaunchAgents/com.zoekt-for-agents.reindex.plist"
  sed "s|@HOME@|$HOME|g" "$here/launchd/com.zoekt-for-agents.reindex.plist.template" >"$plist"
  launchctl bootout "gui/$(id -u)/com.zoekt-for-agents.reindex" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$plist" && echo "launchd: hourly reindex installed"
fi

if [ "$claude" = 1 ]; then
  s="$HOME/.claude/settings.json"; [ -f "$s" ] || echo '{}' >"$s"
  cp "$s" "$s.bak-zoekt-for-agents"
  sed "s|@PROJECT@|$here|g" "$here/claude/settings.snippet.json" >"$HOME/.zoekt/.settings.snippet.json"
  jq -s '
    .[0] as $cur | .[1] as $add
    | $cur
    | .permissions.allow = ((($cur.permissions.allow) // []) + $add.permissions.allow | unique)
    | .hooks.PreToolUse = (
        ((($cur.hooks.PreToolUse) // []) | map(select((.hooks // []) | any(.command | test("no-repo-wide-grep")) | not)))
        + $add.hooks.PreToolUse)' "$s.bak-zoekt-for-agents" "$HOME/.zoekt/.settings.snippet.json" >"$s.new"
  jq empty "$s.new" && mv "$s.new" "$s" && echo "claude: settings.json updated (backup at $s.bak-zoekt-for-agents)"
  md="$HOME/.claude/CLAUDE.md"
  if ! grep -q 'zk .<query>.' "$md" 2>/dev/null; then { echo; cat "$here/claude/CLAUDE.md.snippet"; } >>"$md"; echo "claude: CLAUDE.md snippet appended"; fi
fi

if [ "$build" = 1 ]; then "$HOME/.zoekt/reindex.sh" --full; tail -2 "$ZOEKT_INDEX_DIR/index.log"; fi
echo "done. First build: ~/.zoekt/reindex.sh --full   (log: $ZOEKT_INDEX_DIR/index.log)"
