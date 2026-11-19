#!/usr/bin/env bash
# Text scan of the tree for the project's safety rules. Usage: check-safety.sh [root]
# Prints "FAIL <rule>: <file>:<line>" (never the matching text) and exits 1 on any hit.
set -u

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT" || exit 1

fail=0

# Text patterns are joined from halves so this file never holds a whole forbidden string.
CL="Clau""de"
AN="Anthro""pic"

report() {
  rule=$1
  hits=$2
  [ -n "$hits" ] || return 0
  printf '%s\n' "$hits" | cut -d: -f1,2 | sort -u | while IFS= read -r where; do
    printf 'FAIL %s: %s\n' "$rule" "$where"
  done
  fail=1
}

# Every source type that can run code or touch files, not only Swift.
INCLUDES=""
for ext in swift c h m mm cpp cc cxx hpp hh hxx; do
  INCLUDES="$INCLUDES --include=*.$ext"
done

# scan <rule> <regex> <exempt path regex or empty> <dir>...
scan() {
  rule=$1
  re=$2
  exempt=$3
  shift 3
  for d in "$@"; do
    [ -e "$d" ] || continue
    hits=$(grep -rEnH $INCLUDES -e "$re" "$d" 2>/dev/null || true)
    if [ -n "$exempt" ] && [ -n "$hits" ]; then
      hits=$(printf '%s\n' "$hits" | grep -Ev "^($exempt)" || true)
    fi
    report "$rule" "$hits"
  done
}

SRC="Sources"
# Scanned trees: sources, build tool plugins and the manifest (it runs code at build time).
SCAN="Sources Plugins Package.swift"

scan keychain 'import Security|SecItem[A-Z]|SecKeychain|Keychain|kSec[A-Z]|LocalAuthentication' '' $SCAN
scan network 'URLSession|URLRequest|NSURLConnection|import Network|NWConnection|NWListener|CFSocket|CFNetwork|getaddrinfo|\bsocket\(|\bconnect\(' '' $SCAN
scan credfile 'credentials\.json|\.claude\.json' '' $SCAN
scan process '\bProcess\b|NSTask|posix_spawn|\bsystem\(|\bpopen\(|\bexecv[a-z]*\(|\bdlopen\(' 'Sources/Core/Runner/' $SCAN
scan fileread '[cC]ontentsOf|FileHandle|\bfopen\(|\bopen\(|contents\(atPath|InputStream|\b(openat|freopen|fdopen|opendir|fdopendir|readlink|readlinkat|mmap)\(|NSData\(|Data\(referencing|UserDefaults|NSUbiquitousKeyValueStore|CFPreferences|AppStorage|enumerator\(at|subpathsOfDirectory' 'Sources/Core/Paths/' $SCAN
scan envread 'ProcessInfo|\bgetenv\(|\bsetenv\(|\benviron\b' 'Sources/Core/Env/' $SCAN
# Only the readers named in the architecture open the default folder's settings file: `HookRecord`,
# the pick service and the `init`, `doctor` and `link` commands. `run` uses the saved verdict.
scan settingsread 'readSettings|settingsState\(|settings\.json' 'Sources/(Core/Links/HookRecord|Core/Picker/PickService|agent-balancer/Commands/(Init|Doctor|Link))\.swift:' $SCAN
scan settingsread 'defaultClaudeFolder' 'Sources/(Core/Env/Env|Core/Links/HookRecord|Core/Runner/ChildEnvironment|Core/Readers/SessionsReader)\.swift:' $SCAN
scan secstr '"[^"]*(security |curl)[^"]*"' '' $SCAN
scan tokenstring 'CLAUDE_CODE_OAUTH_TOKEN|"tokens"|tokens/' 'Sources/Core/Tokens/' $SCAN Tests
scan tokenstring '"launch"|launch/' 'Sources/Core/Launch/' $SCAN Tests
# Only the named no-follow writer file may write or delete.
WRITER='Sources/Core/Paths/NoFollowWriter\.swift:'
scan delete 'removeItem|trashItem|unlinkat|\bunlink\(|\brmdir\(|remove\(atPath|replaceItem|(^|[^A-Za-z0-9_.])remove\(|removeObject|removePersistentDomain|removeObjectForKey|UserDefaults|NSUbiquitousKeyValueStore|CFPreferences|AppStorage|recycle\(' "$WRITER" $SCAN
scan write 'write\(to|write\(contentsOf|\.write\(|\bfwrite\(|createFile|createDirectory|moveItem|copyItem|linkItem|createSymbolicLink|setAttributes|forWritingTo|forUpdating|\bfopen\(|\bcreat\(|O_WRONLY|O_RDWR|O_CREAT|O_APPEND|\brename[a-z]*\(|\bsymlink[a-z]*\(|\blink[a-z]*\(|\bmkdir[a-z]*\(|\bmkstemp\(|\b[fl]?chmod(at)?\(|\b[fl]?chown(at)?\(|\bf?truncate\(|setxattr|removexattr|OutputStream|atomically' "$WRITER" $SCAN
# POSIX and stdio write primitives, bare write(fd, ...), copy/clone calls and timestamp changes.
scan write '(^|[^A-Za-z0-9_.])write\(|\bp?writev?\(|\b(fputs|fputc|fputws|putc|putc_unlocked|fprintf|vfprintf|dprintf|vdprintf)\(|\b(f?copyfile|fcopyfile|clonefile(at)?|fclonefileat|copy_file_range|sendfile)\(|\bexchangedata\(|\b(utimes|futimes|lutimes|utime|utimensat|futimens)\(|\b(mknod(at)?|mkfifo(at)?|fsetxattr|fremovexattr)\(' "$WRITER" $SCAN
# Preference stores, descriptor re-opens and resource-value writes also write outside the no-follow writer.
scan write 'UserDefaults|NSUbiquitousKeyValueStore|CFPreferences|AppStorage|\b(freopen|openat)\(|setResourceValues?|writeTo(File|URL)|NSKeyedArchiver|NSFileCoordinator' "$WRITER" $SCAN
scan xctest 'import XCTest|XCTestCase|XCTAssert' '' $SCAN Tests

# One usage-page URL constant, in one named file of the app, and no other http text in Sources.
USAGE_FILE="Sources/AgentBalancerBar/UsagePage.swift"
if [ -d "$SRC" ]; then
  hits=$(grep -rEn --include='*.swift' -e 'https?:' "$SRC" 2>/dev/null | grep -v "^$USAGE_FILE:" || true)
  report http "$hits"
  if [ -f "$USAGE_FILE" ]; then
    count=$(grep -cE 'https?:' "$USAGE_FILE" || true)
    bad=$(grep -nE 'https?:' "$USAGE_FILE" | grep -vE 'https://claude\.ai/[A-Za-z0-9/_.-]*"' || true)
    if [ "${count:-0}" -gt 1 ]; then report http "$USAGE_FILE:1"; fi
    if [ -n "$bad" ]; then report http "$(printf '%s\n' "$bad" | sed "s|^|$USAGE_FILE:|")"; fi
  fi
fi

# Layout: only the known Swift targets, no other source types, plugins, symlinks or stray Swift.
PRUNE='( -name .git -o -name .build -o -name build -o -name .claude -o -name .claude-working -o -name .swiftpm -o -name node_modules ) -prune'
layout_hits=""
# shellcheck disable=SC2086
layout_hits="$layout_hits$(find . $PRUNE -o -type f \( -name '*.c' -o -name '*.h' -o -name '*.m' -o -name '*.mm' -o -name '*.cpp' -o -name '*.cc' -o -name '*.cxx' -o -name '*.hpp' -o -name '*.hh' -o -name '*.hxx' -o -name '*.modulemap' -o -name '*.xcframework' -o -name '*.a' -o -name '*.dylib' \) -print 2>/dev/null | sed 's|^\./||;s|$|:1|')
"
layout_hits="$layout_hits$(find . $PRUNE -o -type d \( -name Plugins -o -name '*.xcframework' -o -name '*.artifactbundle' \) -print 2>/dev/null | sed 's|^\./||;s|$|:1|')
"
layout_hits="$layout_hits$(find . $PRUNE -o -type l -print 2>/dev/null | sed 's|^\./||;s|$|:1|')
"
layout_hits="$layout_hits$(find . $PRUNE -o -type f -name '*.swift' -print 2>/dev/null | sed 's|^\./||' | grep -Ev '^(Sources/|Tests/|Package\.swift$)' | sed 's|$|:1|' || true)
"
# Fixtures hold recorded data and the fake program, never Swift.
layout_hits="$layout_hits$(find Tests/Fixtures -type f -name '*.swift' -print 2>/dev/null | sed 's|$|:1|')
"
for pair in "Sources:Core agent-balancer AgentBalancerBar" "Tests:CoreTests CLITests Fixtures"; do
  top=${pair%%:*}
  allowed=" ${pair#*:} "
  [ -d "$top" ] || continue
  for entry in "$top"/* "$top"/.[!.]*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    name=${entry##*/}
    case "$allowed" in *" $name "*) ;; *) layout_hits="$layout_hits$entry:1
" ;; esac
  done
done
layout_hits=$(printf '%s' "$layout_hits" | grep -v '^$' || true)
report layout "$layout_hits"

# Manifest: no plugins, binary or system targets, custom paths, extra dependencies or extra imports.
if [ -f Package.swift ]; then
  hits=$(grep -nE '\.plugin\(|plugins:|pluginCapability|\.binaryTarget|\.systemLibrary|\.macro\(|\bpath:|\bsources:|publicHeadersPath|cSettings|cxxSettings|linkerSettings|unsafeFlags|\.package\(path|Foundation|FileManager|Process|#if|#warning|#error' Package.swift || true)
  hits="$hits
$(grep -nE '^[[:space:]]*(@testable )?import ' Package.swift | grep -Ev 'import PackageDescription[[:space:]]*$' || true)
$(grep -nE 'url:' Package.swift | grep -v 'https://github.com/apple/swift-argument-parser' || true)"
  hits=$(printf '%s\n' "$hits" | grep -v '^$' | sed 's|^|Package.swift:|' || true)
  report manifest "$hits"
fi

TEXT_DIRS="Sources Tests docs skill"
ROOT_DOCS="README.md CONTRIBUTING.md CHANGELOG.md SECURITY.md CODE_OF_CONDUCT.md"

# Emails: only example.com addresses may appear. -H keeps the file name on a hit in a single file,
# so the report prints a place and never the matching text.
for d in $TEXT_DIRS $ROOT_DOCS; do
  [ -e "$d" ] || continue
  hits=$(grep -rHEnIo '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+' "$d" 2>/dev/null \
    | grep -Eiv '@([A-Za-z0-9-]+\.)*example\.com$' || true)
  report email "$hits"
  hits=$(grep -rHEnIio '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' "$d" 2>/dev/null || true)
  report orgid "$hits"
done

# Attribution phrase: a past-tense verb, by/with/using/via/through, then the product or company.
ATTR_RE="([a-z]+ed|written|made|built|done|given|wrote) (by|with|using|via|through) ($CL|$AN)"
for t in $TEXT_DIRS scripts .github $ROOT_DOCS Package.swift; do
  [ -e "$t" ] || continue
  hits=$(grep -rHEnIi -e "$ATTR_RE" "$t" 2>/dev/null || true)
  report attribution "$hits"
done

# A script under scripts/ that sets pipefail never pipes into a reader that can stop before it
# reads all its input: grep -q, -m or -l, head, sed with q, awk with exit outside END, cmp, read or
# a loop that breaks. When the reader stops, the writer dies of SIGPIPE and pipefail fails the
# pipe, so a check takes a match for none. The scan reads quotes, comments, $( ), here-documents
# and line continuations as the shell does, so a pipe split across lines is still found.
PIPE_SCAN='
  BEGIN {
    d = 1; st[1] = "C"; last = ";"
    fix = "use a here-string or a reader that reads all its input (grep ... >/dev/null, sed -n 1p)"
  }
  # Frames: C code (also inside $( )), M $(( )), B backquotes, S single quotes, A $-single quotes,
  # D double quotes, H a here-document body that expands, Q one that does not.
  function push(t) { d++; st[d] = t; par[d] = 0 }
  # In quotes, an operator character becomes "_" in code, so code holds only real pipes and command
  # ends; raw keeps the text at the same offsets.
  function lit(c) { return index("|;&(){}<>`", c) ? "_" : c }
  function put(c, r) { oc = oc c; orw = orw r }
  function here(t,    dash, quoted, w) {
    dash = 0; quoted = 1
    if (substr(t, 1, 1) == "-") { dash = 1; t = substr(t, 2) }
    sub(/^[ \t]+/, "", t)
    if (match(t, "^" q "[^" q "]*" q) || match(t, /^"[^"]*"/)) w = substr(t, 2, RLENGTH - 2)
    else if (match(t, /^\\[A-Za-z_][A-Za-z0-9_]*/)) w = substr(t, 2, RLENGTH - 1)
    else if (match(t, /^[A-Za-z_][A-Za-z0-9_]*/)) { w = substr(t, 1, RLENGTH); quoted = 0 }
    else return
    hn++; hw[hn] = w; hq[hn] = quoted; hd[hn] = dash
  }
  function nexthere(    k) {
    if (hn == 0) return
    push(hq[1] ? "Q" : "H"); hdel[d] = hw[1]; hdash[d] = hd[1]
    for (k = 1; k < hn; k++) { hw[k] = hw[k + 1]; hq[k] = hq[k + 1]; hd[k] = hd[k + 1] }
    hn--
  }
  {
    s = $0; n = length(s); oc = ""; orw = ""; cont = 0
    if (st[d] == "H" || st[d] == "Q") {
      t = s
      if (hdash[d]) sub(/^\t+/, "", t)
      if (t == hdel[d]) { d--; cl[NR] = "\n"; rl[NR] = "\n"; nexthere(); next }
      if (st[d] == "Q") { cl[NR] = "\n"; rl[NR] = "\n"; next }
    }
    for (i = 1; i <= n; i++) {
      c = substr(s, i, 1); c2 = substr(s, i + 1, 1); top = st[d]
      if (top == "S") { if (c == q) d--; put(lit(c), c); continue }
      if (c == "\\") {
        if (i == n) { cont = 1; continue }
        put(lit(c) lit(c2), c c2); i++; continue
      }
      if (top == "A") { if (c == q) d--; put(lit(c), c); continue }
      if (top == "D" || top == "H") {
        if (c == "\"" && top == "D") { d--; put(c, c); continue }
        if (c == "$" && c2 == "(") { push(substr(s, i + 2, 1) == "(" ? "M" : "C"); put(c c2, c c2); i++; continue }
        if (c == "`") { push("B"); put(c, c); continue }
        put(lit(c), c); continue
      }
      if (c == q) { push("S"); put(c, c); continue }
      if (c == "$" && c2 == q) { push("A"); put(c c2, c c2); i++; continue }
      if (c == "\"") { push("D"); put(c, c); continue }
      if (c == "`") { if (top == "B") d--; else push("B"); put(c, c); continue }
      if (c == "$" && c2 == "(") { push(substr(s, i + 2, 1) == "(" ? "M" : "C"); put(c c2, c c2); i++; continue }
      if (d > 1 && (top == "C" || top == "M")) {
        if (c == "(") par[d]++
        else if (c == ")" && par[d]-- == 0) { d--; put(c, c); continue }
      }
      if (c == "#" && (i == 1 || index(" \t;&|()", substr(s, i - 1, 1)))) break
      if (c == "<" && c2 == "<" && top != "M" && substr(s, i + 2, 1) != "<" && substr(s, i - 1, 1) != "<") here(substr(s, i + 2))
      put(c, c)
    }
    top = st[d]
    if (top == "C" || top == "M" || top == "B") {
      t = oc; sub(/[ \t]+$/, "", t)
      if (t != "") last = substr(t, length(t))
      # After a backslash, a pipe, an and-or operator or an open paren the command goes on.
      if (cont || index("|&(", last)) put("\n", "\n")
      else { put(";\n", ";\n"); last = ";" }
    } else put("\n", "\n")
    cl[NR] = oc; rl[NR] = orw
    if (top == "C" || top == "M" || top == "B") nexthere()
  }
  function grepkind(args,    w, nw, k, j, ch) {
    nw = split(args, w, /[ \t\n]+/)
    for (k = 1; k <= nw; k++) {
      if (w[k] == "--") break
      if (w[k] ~ /^--(quiet|silent)$/) return "grep -q"
      if (w[k] ~ /^--max-count/) return "grep -m"
      if (w[k] ~ /^--files-with/) return "grep -l"
      if (w[k] !~ /^-[A-Za-z0-9]/) continue
      for (j = 2; j <= length(w[k]); j++) {
        ch = substr(w[k], j, 1)
        if (ch == "q") return "grep -q"
        if (ch == "m") return "grep -m"
        if (ch == "l" || ch == "L") return "grep -l"
        # These take a value, the rest of the word or the next one.
        if (index("efABCdD", ch)) { if (j == length(w[k])) k++; break }
      }
    }
    return ""
  }
  function sedq(r) {
    gsub(/"/, "", r); gsub(q, "", r)
    return r ~ /(^|[;{} \t\n0-9$\/])[qQ][0-9]*[ \t]*([;}\n]|$)/
  }
  # An exit in END runs after all the input is read.
  function awkexit(r) {
    if (match(r, /(^|[^A-Za-z0-9_])END[ \t\n]*[{]/)) r = substr(r, 1, RSTART)
    return r ~ /(^|[^A-Za-z0-9_])(exit|nextfile)([^A-Za-z0-9_]|$)/
  }
  # Whether the loop that starts at offset s of code leaves before done.
  function breaks(s,    t, depth, cmd, w, nw, k) {
    t = substr(code, s); depth = 0
    while (t != "") {
      if (match(t, /[;&|(){}\n]/)) { cmd = substr(t, 1, RSTART - 1); t = substr(t, RSTART + 1) }
      else { cmd = t; t = "" }
      nw = split(cmd, w, /[ \t]+/)
      for (k = 1; k <= nw; k++) {
        if (w[k] == "" || w[k] ~ /^(then|else|elif|if|while|until|!)$/) continue
        if (w[k] == "do") { depth++; continue }
        if (w[k] == "done" && --depth <= 0) return 0
        if (depth > 0 && w[k] ~ /^(break|exit|return)$/) return 1
        break
      }
    }
    return 0
  }
  # The command after the pipe at offset s of code, past assignments and command or env.
  function reader(s,    t, w, name, a, e, args, rargs, kind, ln) {
    t = substr(code, s)
    while (1) {
      if (match(t, /^[ \t\n]+/)) { s += RLENGTH; t = substr(t, RLENGTH + 1) }
      if (!match(t, /^[^ \t\n;&|()<>]+/)) return
      w = substr(t, 1, RLENGTH)
      if (w !~ /^[A-Za-z_][A-Za-z0-9_]*=/ && w != "command" && w != "env" && w != "exec") break
      s += RLENGTH; t = substr(t, RLENGTH + 1)
    }
    name = w; sub(/.*\//, "", name)
    a = s + length(w)
    e = match(substr(code, a), /[;&|)]/) ? a + RSTART - 1 : length(code) + 1
    args = substr(code, a, e - a); rargs = substr(raw, a, e - a)
    kind = ""
    if (name ~ /^[ef]?grep$/) kind = grepkind(args)
    else if (name == "head" || name == "cmp" || name == "read") kind = name
    else if (name == "sed" && sedq(rargs)) kind = "sed with q"
    else if (name ~ /^[gmn]?awk$/ && awkexit(rargs)) kind = "awk with exit"
    else if ((name == "while" || name == "until") && breaks(a)) kind = "a loop that breaks"
    if (kind == "") return
    t = substr(code, 1, s - 1); ln = gsub(/\n/, "", t) + 1
    printf "FAIL pipe: %s:%d pipes into %s under pipefail; %s\n", FILENAME, ln, kind, fix
  }
  END {
    for (k = 1; k <= NR; k++) { code = code cl[k]; raw = raw rl[k] }
    if (code !~ /-[A-Za-z]*o[ \t\n]+pipefail/) exit
    for (i = 1; i <= length(code); i++) {
      if (substr(code, i, 1) != "|") continue
      if (substr(code, i + 1, 1) == "|") { i++; continue }
      if (substr(code, i - 1, 1) == ">") continue
      reader(substr(code, i + 1, 1) == "&" ? i + 2 : i + 1)
    }
  }'
if [ -d scripts ]; then
  hits=$(find scripts -type f -print 2>/dev/null | sort | while IFS= read -r f; do
    LC_ALL=C awk -v q="'" "$PIPE_SCAN" "$f" || printf 'FAIL pipe: %s:1 could not be scanned\n' "$f"
  done)
  if [ -n "$hits" ]; then
    printf '%s\n' "$hits"
    fail=1
  fi
fi

# Local banned-string list: whole words, case-insensitive, matched across the tree.
BANNED=".claude/sprint/banned-strings.txt"
if [ -f "$BANNED" ]; then
  pat=$(mktemp "${TMPDIR:-/tmp}/ab-banned.XXXXXX")
  grep -v '^[[:space:]]*$' "$BANNED" > "$pat" || true
  if [ -s "$pat" ]; then
    hits=$(grep -rIiwnF -f "$pat" \
      --exclude-dir=.git --exclude-dir=.build --exclude-dir=build \
      --exclude-dir=.claude --exclude-dir=.claude-working --exclude-dir=.swiftpm . 2>/dev/null \
      | sed 's|^\./||' || true)
    report banned "$hits"
  fi
  rm -f "$pat"
fi

if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "check-safety: ok"
