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
for pair in "Sources:Core agent-balancer AgentBalancerBar" "Tests:CoreTests CLITests"; do
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

# Emails: only example.com addresses may appear.
for d in $TEXT_DIRS; do
  [ -d "$d" ] || continue
  hits=$(grep -rEnIo '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+' "$d" 2>/dev/null \
    | grep -Eiv '@([A-Za-z0-9-]+\.)*example\.com$' || true)
  report email "$hits"
  hits=$(grep -rEnIio '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' "$d" 2>/dev/null || true)
  report orgid "$hits"
done

# Attribution phrase: a past-tense verb, by/with/using/via/through, then the product or company.
ATTR_RE="([a-z]+ed|written|made|built|done|given|wrote) (by|with|using|via|through) ($CL|$AN)"
for t in $TEXT_DIRS scripts .github README.md CHANGELOG.md SECURITY.md Package.swift; do
  [ -e "$t" ] || continue
  hits=$(grep -rEnIi -e "$ATTR_RE" "$t" 2>/dev/null || true)
  report attribution "$hits"
done

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
