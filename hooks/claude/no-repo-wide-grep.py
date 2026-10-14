#!/usr/bin/env python3
"""Claude Code PreToolUse hook (matcher: Bash). Inside a clone of the indexed monorepo, refuse repo-wide
rg / git grep / ugrep / fd scans and point the agent at the Zoekt wrappers zk / zkf instead.
Scoped searches (a module path argument) and searches reading stdin (`... | rg.cmd x`) pass through.
Configuration comes from ~/.zoekt/config: ZOEKT_INDEX_DIR, ZK_ROOT_MARKER (a file at the root of every
clone of the indexed repo); without a marker the clone is recognised by its origin URL matching the
reference clone's."""
import json, os, re, shlex, subprocess, sys

def config():
    cfg = {"ZOEKT_INDEX_DIR": os.path.expanduser("~/.zoekt/index"), "ZK_ROOT_MARKER": "", "ZOEKT_REF_CLONE": ""}
    try:
        for line in open(os.path.expanduser("~/.zoekt/config")):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                cfg[k.strip()] = os.path.expandvars(v.strip().strip('"').strip("'")).replace("~", os.path.expanduser("~"))
    except OSError:
        pass
    return cfg

CFG = config()

SEARCH = {"rg", "rg.cmd", "ugrep", "ug"}
FIND = {"fd", "fd.cmd"}
# options that take a value (so the value is not mistaken for a path)
RG_VAL = {"-e", "--regexp", "-g", "--glob", "--iglob", "-t", "--type", "-T", "--type-not", "--type-add", "-A", "-B", "-C",
          "--after-context", "--before-context", "--context", "-m", "--max-count", "-j", "--threads", "-E", "--encoding",
          "-f", "--file", "-M", "--max-columns", "-d", "--max-depth", "--max-filesize", "-r", "--replace", "--color",
          "--colors", "--sort", "--sortr", "--ignore-file", "--pre", "--pre-glob", "--engine", "--context-separator",
          "--field-match-separator", "--path-separator", "--dfa-size-limit", "--regex-size-limit", "--include",
          "--exclude", "--exclude-dir", "-D", "--devices", "-K", "--range", "--format", "-Q", "--query", "--index"}
GITGREP_VAL = {"-e", "-f", "-A", "-B", "-C", "-m", "--max-count", "--threads", "-O", "--open-files-in-pager", "--color"}
FD_VAL = {"-e", "--extension", "-E", "--exclude", "-t", "--type", "-d", "--max-depth", "--min-depth", "--exact-depth",
          "-x", "--exec", "-X", "--exec-batch", "-S", "--size", "--changed-within", "--changed-before", "-o", "--owner",
          "--search-path", "--base-directory", "--path-separator", "-j", "--threads", "--max-buffer-time", "--max-results",
          "-c", "--color", "--ignore-file", "--strip-cwd-prefix", "--format"}

def main():
    data = json.load(sys.stdin)
    if data.get("tool_name") != "Bash":
        return
    cmd = (data.get("tool_input") or {}).get("command") or ""
    cwd = data.get("cwd") or os.getcwd()
    if not os.path.exists(os.path.join(CFG["ZOEKT_INDEX_DIR"], ".commit")):
        return
    root = indexed_repo_root(cwd)
    if not root:
        return
    for seg, piped in segments(cmd):
        verdict = check(seg, piped, cwd, root)
        if verdict:
            print(json.dumps({"hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": verdict}}))
            return

def indexed_repo_root(p):
    """Root of the clone containing p, if it is a clone of the indexed repository."""
    marker = CFG.get("ZK_ROOT_MARKER")
    p = os.path.abspath(p)
    if marker:
        while p and p != "/":
            if os.path.exists(os.path.join(p, marker)):
                return p
            p = os.path.dirname(p)
        return None
    ref = CFG.get("ZOEKT_REF_CLONE")
    if not ref:
        return None
    def git(d, *a):
        try:
            return subprocess.run(["git", "-C", d, *a], capture_output=True, text=True, timeout=3).stdout.strip()
        except Exception:
            return ""
    top = git(p, "rev-parse", "--show-toplevel")
    if top and git(top, "config", "--get", "remote.origin.url") == git(ref, "config", "--get", "remote.origin.url"):
        return top
    return None

def segments(cmd):
    """Split a shell command into simple commands; flag those fed by a pipe."""
    parts = re.split(r"(\|\||&&|;|\n|\||\$\(|\(|\))", cmd)
    sep = ""
    for part in parts:
        if part in ("||", "&&", ";", "\n", "|", "$(", "(", ")"):
            sep = part
            continue
        if part.strip():
            yield part, sep == "|"

def tokens(seg):
    try:
        toks = shlex.split(seg, posix=True)
    except ValueError:
        toks = seg.split()
    # drop env assignments and wrappers
    while toks and (re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", toks[0]) or toks[0] in ("time", "nohup", "command", "exec", "sudo")):
        toks = toks[1:]
    return toks

def positionals(args, val_opts, stop_at_dashdash=True):
    pos, i, after = [], 0, False
    while i < len(args):
        a = args[i]
        if after or not a.startswith("-") or a == "-":
            pos.append(a)
        elif a == "--" and stop_at_dashdash:
            after = True
        elif a in val_opts:
            i += 1
        elif a.startswith("--") and "=" in a:
            pass
        elif not a.startswith("--") and len(a) > 2 and a[:2] in val_opts:
            pass  # -e PATTERN glued: -ePATTERN
        i += 1
    return pos

def is_root_path(p, cwd, root):
    if p in (".", "./", "*", "./*"):
        return os.path.abspath(cwd) == root
    ap = os.path.abspath(os.path.join(cwd, os.path.expanduser(p)))
    return ap == root

def check(seg, piped, cwd, root):
    toks = tokens(seg)
    if not toks:
        return None
    name = os.path.basename(toks[0])
    if name == "git" and len(toks) > 1 and toks[1] == "grep":
        args = toks[2:]
        has_e = any(a == "-e" or (a.startswith("-e") and not a.startswith("--")) for a in args)
        pos = positionals(args, GITGREP_VAL)
        if "--" not in args and not has_e and pos:
            pos = pos[1:]  # first positional is the pattern
        paths = pos
        if all(is_root_path(p, cwd, root) for p in paths):
            return reason("git grep")
        return None
    if name in SEARCH:
        if piped:
            return None
        args = toks[1:]
        if any(a in ("-h", "--help", "-V", "--version", "--type-list") for a in args):
            return None
        has_e = any(a in ("-e", "--regexp", "-f", "--file") or a.startswith("--regexp=") or a.startswith("--file=") for a in args)
        files_mode = "--files" in args
        pos = positionals(args, RG_VAL)
        if not has_e and not files_mode and pos:
            pos = pos[1:]
        paths = [p for p in pos if p != "-"]
        if all(is_root_path(p, cwd, root) for p in paths):
            return reason(name)
        return None
    if name in FIND:
        args = toks[1:]
        if any(a in ("-h", "--help", "-V", "--version") for a in args):
            return None
        pos = positionals(args, FD_VAL)
        if pos and not any(a in ("--search-path",) for a in args):
            pos = pos[1:]  # first positional is the pattern
        paths = pos
        if all(is_root_path(p, cwd, root) for p in paths):
            return ("Repo-wide file listing with %s walks the whole monorepo. Use zkf '<path regex>' (git index + untracked, "
                    "about a second), or give %s a module path." % (name, name))
        return None
    return None

def reason(tool):
    return ("Repo-wide %s over this monorepo reads every file and takes tens of seconds. Use the Zoekt index instead: "
            "zk '<query>' - substring or regex, terms ANDed, filters f:<path regex> sym:<Name> lang:kotlin case:yes "
            "-f:testData, -l for file names only; zkf '<path regex>' for file names. If you really need %s, scope it to a "
            "module path, e.g. %s -n <pattern> <module dir>." % (tool, tool, tool))

if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # never block on a hook bug
        print("no-repo-wide-grep hook error: %s" % e, file=sys.stderr)
        sys.exit(0)
