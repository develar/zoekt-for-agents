# zoekt-for-agents

Sub-second text, regex and symbol search over a huge monorepo for coding agents (Claude Code, Codex, any
shell-capable agent), built on a local [Zoekt](https://github.com/sourcegraph/zoekt) index that is shared
by every clone of the repository.

## Why

On a 1.4M-file monorepo a repo-wide `rg` or `git grep` takes about 50 s on a cold cache, almost all of it
kernel time opening files. Agents do that dozens of times per task. IDE-backed search (JetBrains MCP) only
works for the checkout the IDE has open, and agent subagents often cannot reach MCP tools at all.

Zoekt is a trigram index: a query never touches the working tree, so the file count stops mattering.
Zoekt indexes git objects of a commit, not a directory, which gives the second property: one index serves
every clone of the repo, because `master@<sha>` is the same everywhere. Each clone's local commits and
uncommitted edits are overlaid on top by a thin wrapper.

Measured on an Apple Silicon laptop, 1.38M files, 10 GB of tracked content: first build 13 min, index 14 GB,
queries well under a second.

## What is in the box

| Path | Purpose |
|---|---|
| `bin/zk` | search: Zoekt query syntax, output `path:line:text`, local changes overlaid |
| `cmd/zk-search` | small Go client over the Zoekt library with result caps (`-max_files`, `-max_lines`, `-max_wall`); the stock `zoekt` CLI has none and takes 13 s on a term like `fun main` |
| `bin/zkf` | find files by path regex: `git ls-files` plus untracked files, through ripgrep |
| `bin/zk-wt` | helper: working-tree changes with a cache and a time budget, so a slow `git status` never stalls a search |
| `reindex.sh` | build or refresh the index from the reference clone's `origin/<branch>`; incremental/delta |
| `hooks/git/reference-transaction` | local git hook for the reference clone: `origin/<branch>` moved, refresh in background |
| `hooks/claude/no-repo-wide-grep.py` | Claude Code `PreToolUse` hook: refuses repo-wide `rg` / `git grep` / `fd` inside a clone of the indexed repo and tells the agent to use `zk` |
| `claude/` | `settings.json` and `CLAUDE.md` snippets |
| `launchd/` | hourly reindex LaunchAgent template (macOS) |
| `install.sh` | symlinks, config, hook, launchd, Claude settings |

## Install

Requirements: git, Go 1.25+ (`go install` of the Zoekt indexer and of `cmd/zk-search`), ripgrep, universal-ctags
(symbols are a ranking signal and power `sym:`). `install.sh --deps` installs all of them on macOS with Homebrew.

```bash
git clone https://github.com/develar/zoekt-for-agents ~/projects/zoekt-for-agents
cd ~/projects/zoekt-for-agents
./install.sh --deps --claude --launchd \
  --ref-clone ~/projects/my-monorepo \
  --index-dir ~/.zoekt/my-monorepo \
  --marker .my-monorepo.root.marker \
  --exclude '^generated/'
~/.zoekt/reindex.sh --full          # first build, watch ~/.zoekt/my-monorepo/index.log
```

`--ref-clone` is the one clone whose `refs/remotes/origin/master` gets indexed; it is the only clone that
ever indexes anything. `--marker` is a file that exists at the root of every clone of this repo (the Claude
hook uses it to decide whether it is inside a clone; without it the hook compares `remote.origin.url` with
the reference clone). `--exclude` drops a path prefix from results unless the query mentions it or `--all`
is passed. Everything lands in `~/.zoekt/config`, which all scripts source.

## Use

```bash
zk ToolWindowSetInitializer                         # substring
zk 'sym:ToolWindowSetInitializer'                   # symbol definitions (ctags)
zk 'f:^platform/ lang:kotlin "fun doWhenFirstShown"'
zk -l 'HIDE_OTHER_EDITORS -f:test'                  # file names only, exclude test paths
zk 'case:yes Foo or Bar'                            # case sensitive, OR
zkf 'ToolWindowSetInitializer\.kt$'                 # files by path regex
```

Query syntax is Zoekt's ([reference](https://github.com/sourcegraph/zoekt/blob/main/doc/query_syntax.md)):
plain text is a substring, regex metacharacters make it a regex, terms are ANDed, `or` is the only operator,
`-term` negates, filters are `f:` `sym:` `lang:` `case:` `content:` `branch:`.

## How a clone is matched to the shared index

1. `reindex.sh` records the indexed commit in `<index dir>/.commit`.
2. In any clone, `zk` computes the set of paths whose content differs from that commit:
   `git diff --name-only <sha> HEAD` (a tree diff, ancestry does not matter) plus `git status --porcelain`.
3. Index hits in those paths are dropped and replaced by a `ripgrep` run over the clone's current files, with
   the content terms of the query. That set is small for a feature branch, so this stays fast.
4. If the clone has never fetched the indexed commit, `zk` falls back to the clone's `origin/<branch>` and
   says so: the index may then show upstream content the clone does not have yet, but nothing local is lost.
5. `git status` is the one expensive step: fast with fsmonitor most of the time, with multi-second outliers
   on a million-file tree. `zk-wt` caches its result in `<git dir>/zk-wt.cache`, serves a result younger
   than `ZK_WT_FRESH` (5 s) without running git, and otherwise gives `git status` `ZK_WT_BUDGET` (2 s): on
   overrun it keeps running in the background to refresh the cache while the previous result is used and
   `zk` says how old it is. Committed differences are always current; a brand-new untracked file can lag
   by one slow `git status`.

## Keeping the index fresh

- `hooks/git/reference-transaction`, linked into the reference clone, starts `reindex.sh` in the background
  whenever `origin/<branch>` moves. `reindex.sh` exits at once if the index already matches.
- The LaunchAgent runs `reindex.sh` hourly as a safety net.
- Refreshes are delta builds (`zoekt-git-index -delta`); after 20 deltas a full rebuild happens automatically.
  Force one with `~/.zoekt/reindex.sh --full`.

## Claude Code integration

`install.sh --claude` adds `Bash(zk:*)` and friends to `permissions.allow` in `~/.claude/settings.json`,
registers the `PreToolUse` hook, and appends `claude/CLAUDE.md.snippet` to `~/.claude/CLAUDE.md`.

The hook matters more than the instructions: built-in Explore subagents start without `CLAUDE.md`, but
hooks from `settings.json` fire inside every subagent. A repo-wide `rg.cmd -n foo` or `git grep foo` from the
repo root is denied with a message that names `zk`; `rg.cmd -n foo platform/core`, `... | rg.cmd foo` and
searches outside a clone pass through.

## Limitations

- The index covers one branch of one repository. More branches: pass `-branches a,b` to `zoekt-git-index`
  in `reindex.sh`; identical files are stored once with a branch mask, filter with `branch:`.
- Files above 2 MB are indexed by name only (Zoekt default `-file_limit`).
- The overlay approximates Zoekt semantics with ripgrep: `sym:` becomes a text match, negated content terms
  are ignored.
- macOS and Linux; the LaunchAgent is macOS only.

## License

MIT
