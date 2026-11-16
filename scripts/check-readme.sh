#!/usr/bin/env bash
# Checks README.md and docs/GUIDE.md, the guide that holds the detail the README links to, against
# the tool, and keeps the README pictures made up. The rules on characters, commands and links
# apply to both files.
# - Characters: each file holds only printable ASCII and tabs.
# - Commands: every inline code span is code, and so is every line of a fenced code block (three
#   or more backticks or tildes, closed only by a run of the same mark at least as long) except a
#   json block, with one leading "$ " or "% " prompt dropped. A fence must close before the list
#   item that holds it ends: a line that is not blank and is indented less than the opening fence
#   ends it, and a fence that ends there or at the end of the file without closing fails. A json
#   block must parse as JSON, and each key and each string of the parsed value, with any character
#   outside printable ASCII read as a space, is read as a later part, so a key that appears twice
#   is read with its last value only.
#   Each span or line is cut into parts at &&, ||, ;, & and | (a | before a flag is a choice in a
#   usage line), each $(...) or `...` substitution is a part of its own, and quotes, backslashes
#   and parentheses read as spaces. The first part must start with agent-balancer, claude, brew,
#   gh or mkdir, or be one word that is a path, file or key. A part that starts with claude, brew,
#   gh or mkdir is that program's line; in any other part, each word agent-balancer, and a path to
#   it that starts the part, begins a command whose subcommand and flags must be in its --help.
#   No flag may sit in plain text, and in plain text agent-balancer followed by spaces or tabs and
#   a word fails unless that word is on the list below.
# - Status transcripts: a fenced block whose info string is text shows what agent-balancer status
#   prints. Its first line is a "$ " prompt and agent-balancer status, alone or with --cached, read
#   as code, and every later line has the shape of a line the status table prints for one of the
#   five made-up labels: an account row, a limited line or a next line. Any other line fails, an
#   error or warning line, whose text is free, included.
# - Links: each local file named by an inline link or picture, or by a src or srcset attribute,
#   exists, read from the folder of the file that names it.
# - Pictures: the eight PNGs exist and carry no compressed chunk, and their metadata chunks hold no
#   absolute path of two or more parts (also right after a URL's scheme and host), home path (~/,
#   ~user/ or $HOME/), address outside example.com, org id or token.
# - Scene sources the pictures are drawn from: accounts named only by the five made-up labels,
#   every word with a letter in their strings and comments (lowercased, ISO times aside) a label
#   or on the word list below, and only those labels' example.com addresses (each with at most
#   one leading hyphen) and the fixture's paths.
# - When the local banned-string list is present, neither the metadata nor the scene sources hold
#   a banned string.
# Usage: check-readme.sh [path to the agent-balancer binary]
set -euo pipefail
export LC_ALL=C

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BIN="${1:-}"
if [ -z "$BIN" ]; then
  BIN="$(swift build --product agent-balancer --show-bin-path)/agent-balancer"
  # A fresh clone has no build yet: build the CLI rather than pass without it.
  if [ ! -x "$BIN" ]; then swift build --product agent-balancer >&2; fi
fi
[ -x "$BIN" ] || { echo "check-readme: no binary at $BIN" >&2; exit 1; }

fail=0
bad() { echo "FAIL readme: $1" >&2; fail=1; }
# Whether the newline-separated list $1 holds the line $2.
listed_in() {
  case $'\n'"$1"$'\n' in *$'\n'"$2"$'\n'*) return 0 ;; esac
  return 1
}
# The lines of $1 that do not match the extended regex $2. It reads all its input, so a check
# never misses a hit because a pipe closed early.
outside() { printf '%s\n' "$1" | grep -vE -- "$2" | grep -v '^$' || true; }
# Absolute paths of two or more parts, also right after a URL's scheme and host, and home paths
# (~/, ~user/ or $HOME/), in the file $1, one per line.
paths_in() {
  grep -aoE '(^|[^A-Za-z0-9._~/-]|[A-Za-z][A-Za-z0-9+.-]*://[^/[:space:]]*)(~[A-Za-z0-9._-]*/[A-Za-z0-9._-]|\$HOME/[A-Za-z0-9._-]|/[A-Za-z0-9._-]+/[A-Za-z0-9._-])[^[:space:]"'"'"'`),\\]*' "$1" \
    | sed -E 's#^([A-Za-z][A-Za-z0-9+.-]*://[^/[:space:]]*|[^~/$])##' || true
}

# The local banned-string list without blank lines, a picture's metadata and a json block, in
# temporary files the trap removes on every exit, a failed check included.
BANNED=".claude/sprint/banned-strings.txt"
PATTERNS="$(mktemp "${TMPDIR:-/tmp}/ab-readme-banned.XXXXXX")"
META="$(mktemp "${TMPDIR:-/tmp}/ab-readme-meta.XXXXXX")"
JSON="$(mktemp "${TMPDIR:-/tmp}/ab-readme-json.XXXXXX")"
trap 'rm -f "$PATTERNS" "$META" "$JSON"' EXIT
if [ -f "$BANNED" ]; then grep -v '^[[:space:]]*$' "$BANNED" > "$PATTERNS" || true; fi
banned_in() { [ -s "$PATTERNS" ] && grep -aiwqF -f "$PATTERNS" -- "$1"; }

# Each chunk of the PNG $1 after its signature, as "type data-offset length".
png_chunks() {
  local file="$1" size offset header len
  size=$(($(wc -c < "$file")))
  offset=8
  while [ "$offset" -lt "$size" ]; do
    header="$(od -An -tu1 -j "$offset" -N8 "$file" \
      | awk 'NF >= 8 { printf "%d %c%c%c%c", $1 * 16777216 + $2 * 65536 + $3 * 256 + $4, $5, $6, $7, $8 }')"
    [ -n "$header" ] || break
    len="${header%% *}"
    echo "${header#* } $((offset + 8)) $len"
    offset=$((offset + 12 + len))
  done
}

# Commands and flags.
subcommands() { sed -n '/^SUBCOMMANDS:/,$p' | awk 'NR>1 && /^  [a-z]/ {print $1}'; }
listed="$("$BIN" --help | subcommands)"
config_listed="$("$BIN" config --help | subcommands)"

# The files the rules on characters, commands and links read.
DOCS="README.md docs/GUIDE.md"
# The made-up labels: the only accounts a status transcript or a scene source may name.
LABELS='main|personal|lab|spare-a|spare-b'

# The words that may follow agent-balancer in plain text, where the README names the tool itself.
PROSE_WORDS="is
never
reads"

# Prints "ok" and then each key and each string of the value the JSON file named by its argument
# parses to, one a line, with every character outside printable ASCII as a space. It prints
# nothing when the file does not parse as JSON. JavaScript for Automation ships with macOS, so it
# needs no install.
JSON_READER='function run(argv) {
  ObjC.import("Foundation");
  var text = $.NSString.stringWithContentsOfFileEncodingError(
    argv[0], $.NSUTF8StringEncoding, null).js;
  var out = ["ok"];
  function walk(v) {
    if (typeof v === "string") out.push(v.replace(/[^ -~]/g, " "));
    else if (Array.isArray(v)) v.forEach(walk);
    else if (v !== null && typeof v === "object")
      Object.keys(v).forEach(function (k) { walk(k); walk(v[k]); });
  }
  walk(JSON.parse(text));
  return out.join("\n");
}'

# The code of the Markdown file $1, one item a line: "S <part>" for the first part of an inline
# code span or of a line of a fenced block that is not json, "L <part>" for each later part of a
# chain, each substitution and each part of a string in a json block, "P <flag>" for a flag in
# plain text, "C <word>" for the word after agent-balancer in a paragraph of plain text,
# "W <line number>" for a code span that runs across a line break, "U <line number>" for a fence
# that never closes and "J <line number>" for a json block that does not parse. A text block gives
# "X <line number> <command>" for its prompt line, whose command is also read as an S part,
# "Y <line number>" when it has no prompt line and "T <line number> <line>" for each later line,
# its block indent taken off. In code, quotes, backslashes and parentheses read as spaces.
read_code() {
  AB_JSON_FILE="$JSON" AB_JSON_READER="$JSON_READER" awk -v q="'" '
  function flush() {
    rest = para
    while (match(rest, /[^A-Za-z0-9-]agent-balancer[ \t]+[A-Za-z][A-Za-z0-9-]*/)) {
      word = substr(rest, RSTART, RLENGTH); sub(/.*agent-balancer[ \t]+/, "", word)
      print "C " word
      rest = substr(rest, RSTART + RLENGTH)
    }
    para = ""
  }
  function put(part, lead) {
    sub(/^[ \t]+/, "", part); sub(/[ \t]+$/, "", part)
    if (lead) print "S " part
    else if (part != "") print "L " part
  }
  # The parts of one span or line (lead 1) or of one substitution (lead 0).
  function parts(text, lead,    rest, part, i, j, n, c, d) {
    rest = ""; n = length(text); i = 1
    while (i <= n) {
      c = substr(text, i, 1)
      if (c == "$" && substr(text, i + 1, 1) == "(") {
        d = 1
        for (j = i + 2; j <= n && d > 0; j++) {
          c = substr(text, j, 1)
          if (c == "(") d++
          else if (c == ")") d--
        }
        parts(substr(text, i + 2, j - i - 2 - (d == 0)), 0)
        rest = rest " "; i = j; continue
      }
      if (c == "`") {
        j = index(substr(text, i + 1), "`")
        if (j == 0) j = n - i + 1
        parts(substr(text, i + 1, j - 1), 0)
        rest = rest " "; i += j + 1; continue
      }
      rest = rest c; i++
    }
    gsub("[\"\\\\()" q "]", " ", rest)
    part = ""; n = length(rest)
    for (i = 1; i <= n; i++) {
      c = substr(rest, i, 1)
      if (c == "|" && substr(rest, i + 1, 1) != "|") {
        for (j = i + 1; substr(rest, j, 1) ~ /[ \t]/; j++) {}
        if (substr(rest, j, 1) == "-") { part = part c; continue }
      }
      if (c == ";" || c == "&" || c == "|") {
        put(part, lead); lead = 0; part = ""
        if (c != ";" && substr(rest, i + 1, 1) == c) i++
        continue
      }
      part = part c
    }
    put(part, lead)
  }
  # The width of the spaces and tabs that start s, a tab reaching the next multiple of four.
  function indent(s,    n, i, c) {
    n = 0
    for (i = 1; i <= length(s); i++) {
      c = substr(s, i, 1)
      if (c == " ") n++
      else if (c == "\t") n += 4 - n % 4
      else break
    }
    return n
  }
  # Closes the open fence. A json block must parse as JSON, and each key and each string of the
  # parsed value is read as a later part, so a command in it is checked.
  function endfence(    file, cmd, s, ok) {
    if (data) {
      file = ENVIRON["AB_JSON_FILE"]
      printf "%s", json > file
      close(file)
      cmd = "/usr/bin/osascript -l JavaScript -e \"$AB_JSON_READER\" \"$AB_JSON_FILE\" 2>/dev/null"
      ok = ((cmd | getline s) > 0 && s == "ok")
      while (ok && (cmd | getline s) > 0) parts(s, 0)
      close(cmd)
      if (!ok) print "J " opened
    }
    if (shown && first) print "Y " opened
    fence = ""; data = 0; json = ""; shown = 0; first = 0
  }
  # A fence in a list item ends where the item ends, as Markdown renders it: a line that is not
  # blank and is indented less than the opening fence ends the fence unclosed and is read as usual.
  fence != "" && /[^ \t]/ && indent($0) < findent {
    print "U " opened
    endfence()
  }
  fence == "" && match($0, /^[ \t]*(```+|~~~+)/) {
    mark = substr($0, RSTART, RLENGTH); sub(/^[ \t]+/, "", mark)
    info = substr($0, RSTART + RLENGTH)
    # A line of backticks with a backtick after them is a code span, not a fence.
    if (mark ~ /^~/ || index(info, "`") == 0) {
      flush()
      fence = mark; opened = NR; findent = indent($0)
      sub(/^[ \t]+/, "", info); sub(/[ \t]+$/, "", info)
      data = (info == "json")
      shown = (info == "text"); first = 1
      next
    }
  }
  fence != "" {
    if ($0 ~ /^[ \t]*(```+|~~~+)[ \t]*$/) {
      mark = $0; gsub(/[ \t]/, "", mark)
      if (substr(mark, 1, 1) == substr(fence, 1, 1) && length(mark) >= length(fence)) {
        endfence()
        next
      }
    }
    if (data) { json = json $0 "\n"; next }
    # A status transcript: the prompt line is code, every later line is output.
    if (shown) {
      line = $0
      for (i = 0; i < findent && substr(line, 1, 1) == " "; i++) line = substr(line, 2)
      if (first) {
        first = 0
        if (line ~ /^[$] /) {
          sub(/^[$] +/, "", line)
          parts(line, 1)
          print "X " opened " " line
        } else print "Y " opened
      } else print "T " NR " " line
      next
    }
    line = $0; sub(/^[ \t]+/, "", line); sub(/^[$%] +/, "", line)
    if (line ~ /[^ \t]/) parts(line, 1)
    next
  }
  /^[[:space:]]*$/ { flush(); next }
  {
    line = $0; prose = " "
    while (match(line, /`[^`]*`/)) {
      start = RSTART; len = RLENGTH
      prose = prose substr(line, 1, start - 1) " "
      parts(substr(line, start + 1, len - 2), 1)
      line = substr(line, start + len)
    }
    if (index(line, "`") > 0) print "W " NR
    prose = prose line
    rest = prose
    while (match(rest, /[^A-Za-z0-9-]--[A-Za-z][A-Za-z0-9-]*/)) {
      print "P " substr(rest, RSTART + 1, RLENGTH - 1)
      rest = substr(rest, RSTART + RLENGTH)
    }
    para = para prose
  }
  END {
    flush()
    if (fence != "") { print "U " opened; endfence() }
  }' "$1"
}

# One command, its words from agent-balancer or a path to it on: its subcommand, a config
# subcommand and each flag up to a lone `--` must be in --help. Brackets and an `=value` around a
# flag are dropped.
check_command() {
  local sub word help short found
  local -a words
  shift
  [ "$#" -gt 0 ] || return 0
  sub="$1"
  shift
  if ! listed_in "$listed" "$sub"; then
    bad "command '$sub' is not in agent-balancer --help"
    return 0
  fi
  words=("$sub")
  if [ "$sub" = config ]; then
    if ! listed_in "$config_listed" "${1:-}"; then
      bad "command 'config ${1:-}' is not in agent-balancer config --help"
      return 0
    fi
    words+=("$1")
    shift
  fi
  help="$("$BIN" "${words[@]}" --help)"
  for word in "$@"; do
    if [ "$word" = "--" ]; then break; fi
    word="${word#\[}"
    word="${word%\]}"
    word="${word%%=*}"
    case "$word" in
      --[a-z]*) short="" ;;
      -[A-Za-z]) short=1 ;;
      *) continue ;;
    esac
    if [ -n "$short" ]; then
      found="$(printf '%s\n' "$help" | grep -E -- "^ +$word(,| |$)" || true)"
    else
      found="$(printf '%s\n' "$help" | grep -E -- "^ +(-[A-Za-z], )?$word( |$)" || true)"
    fi
    [ -n "$found" ] || bad "flag '$word' is not an option of agent-balancer ${words[*]}"
  done
}

# Whether the words $@ may begin a span or a line of code: an agent-balancer, claude, brew, gh or
# mkdir line, or one word naming a path, file or key.
leads_well() {
  case "${1:-}" in agent-balancer | claude | brew | gh | mkdir) return 0 ;; esac
  [ "$#" -eq 1 ] || return 1
  case "$1" in */* | *.* | "~"*) return 0 ;; esac
  return 1
}

# One part of a span or line of code: S for its first part, L for any other. A part that starts
# with claude, brew, gh or mkdir is that program's line. In any other part each word
# agent-balancer, and a path to it that starts the part, begins a command that runs to the next
# such word or to the end of the part.
check_part() {
  local kind="$1" text="$2" n i start
  local -a w
  # shellcheck disable=SC2086
  set -- $text
  if [ "$kind" = S ] && ! leads_well "$@"; then
    bad "code '$text' is not an agent-balancer command, a claude, brew, gh or mkdir line, or a path, file or key"
  fi
  case "${1:-}" in "" | claude | brew | gh | mkdir) return 0 ;; esac
  n=$#
  w=("$@")
  start=-1
  i=0
  while [ "$i" -lt "$n" ]; do
    if [ "${w[i]}" = agent-balancer ] || { [ "$i" -eq 0 ] && [ "${w[0]%/agent-balancer}" != "${w[0]}" ]; }; then
      if [ "$start" -ge 0 ]; then check_command "${w[@]:start:i-start}"; fi
      start=$i
    fi
    i=$((i + 1))
  done
  if [ "$start" -ge 0 ]; then check_command "${w[@]:start}"; fi
}

# Whether $1 has the shape of a line that the status table prints for a made-up account: an
# account row, a limited line or a next line (Sources/agent-balancer/Commands/Status.swift).
STATUS_TIME='(-|(Mon|Tue|Wed|Thu|Fri|Sat|Sun) (1[0-2]|[1-9]):[0-5][0-9] (AM|PM))'
STATUS_PERCENT='(n/a|(100|[1-9]?[0-9])\.[0-9]%)'
status_line() {
  printf '%s\n' "$1" | grep -qE \
    -e "^($LABELS) \[(login|token|folder), (main|pool)\] (ok|limited|error|ended) week $STATUS_PERCENT 5h $STATUS_PERCENT resets $STATUS_TIME in use ([0-9]+|unknown)\$" \
    -e "^  limited \((weekly|fiveHour)\) until $STATUS_TIME\$" \
    -e "^next( for fable)?: ($LABELS|none)\$"
}

for doc in $DOCS; do
  [ -f "$doc" ] || { bad "the doc $doc is missing"; continue; }
  if grep -qiE '<(code|pre|kbd|samp|tt)[[:space:]>]' "$doc"; then
    bad "$doc uses an HTML code tag: write code in Markdown"
  fi
  # Printable ASCII and tabs only, since a look-alike or invisible character could hide a command
  # from the rules below.
  nonascii="$(grep -n $'[^\t -~]' "$doc" | cut -d: -f1 | tr '\n' ' ' | sed 's/ $//' || true)"
  [ -z "$nonascii" ] || bad "$doc has a character outside printable ASCII and tabs on lines $nonascii"

  code="$(read_code "$doc")"
  set -f
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    text="${item#? }"
    case "$item" in
      S\ * | L\ *) check_part "${item%% *}" "$text" ;;
      P\ *) bad "flag '$text' is in plain text: write it in code after its agent-balancer command" ;;
      C\ *)
        if listed_in "$listed" "$text"; then
          bad "command 'agent-balancer $text' sits in plain text: write it in code"
        elif ! listed_in "$PROSE_WORDS" "$text"; then
          bad "'agent-balancer $text' in plain text is neither a command in code nor a listed word"
        fi
        ;;
      W\ *) bad "the code span on line $text of $doc runs across a line break: keep it on one line" ;;
      U\ *) bad "the code fence that opens on line $text of $doc never closes" ;;
      J\ *) bad "the json block that opens on line $text of $doc does not parse as JSON" ;;
      X\ *)
        case "${text#* }" in
          "agent-balancer status" | "agent-balancer status --cached") ;;
          *) bad "the text block that opens on line ${text%% *} of $doc shows a command other than agent-balancer status or agent-balancer status --cached" ;;
        esac
        ;;
      Y\ *) bad "the text block that opens on line $text of $doc does not start with a prompt line" ;;
      T\ *)
        status_line "${text#* }" \
          || bad "line ${text%% *} of $doc is in a text block but is not agent-balancer status output for a made-up account"
        ;;
    esac
  done <<EOF
$code
EOF
  set +f

  # Local links and pictures, read from the folder of the doc. An anchor is not part of the file
  # name.
  dir="$(dirname "$doc")"
  refs="$(grep -oE '(\]\(|srcset="|src=")[^)" ]+' "$doc" \
    | sed -E 's/^(\]\(|srcset="|src=")//; s/#.*$//' | grep -vE '^(https?:|$)' || true)"
  for ref in $refs; do
    [ -e "$dir/$ref" ] || bad "in $doc, linked file '$ref' does not exist"
  done
done

# Pictures: eight PNGs.
for scene in hero menu manage-tokens manage-folders; do
  for mode in light dark; do
    f="docs/media/$scene-$mode.png"
    [ -f "$f" ] || { bad "missing picture $f"; continue; }
    if [ "$(od -An -tx1 -N8 "$f" | tr -d ' \n')" != 89504e470d0a1a0a ]; then
      bad "$f is not a PNG"
      continue
    fi
    # Byte checks read only the metadata chunks: drawn text is compressed pixel data no grep sees.
    # A compressed chunk would hide its text from them, so it is refused. A newline ends each
    # chunk, so a word at the end of one never runs into the next.
    : > "$META"
    while read -r type start len; do
      [ -n "$type" ] || continue
      case "$type" in
        IDAT | IEND) ;;
        zTXt | iTXt | iCCP) bad "$f carries a compressed chunk ($type)" ;;
        *)
          if [ "$len" -gt 0 ]; then dd if="$f" bs=1 skip="$start" count="$len" 2>/dev/null >> "$META"; fi
          printf '\n' >> "$META"
          ;;
      esac
    done <<EOF
$(png_chunks "$f")
EOF
    [ -z "$(paths_in "$META")" ] || bad "$f metadata holds a path"
    addresses="$(grep -aoE '[A-Za-z0-9._-]+@[A-Za-z0-9.-]+\.[A-Za-z]+' "$META" || true)"
    [ -z "$(outside "$addresses" '@example\.com$')" ] || bad "$f metadata holds an address outside example.com"
    if grep -aiqE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' "$META"; then
      bad "$f metadata holds an org id"
    fi
    if grep -aqF 'sk-ant-' "$META"; then bad "$f metadata holds a token"; fi
    if banned_in "$META"; then bad "$f metadata holds a banned string"; fi
  done
done

# Scene sources: the pictures are drawn from the README fixture and the scene strings it reuses,
# so every label, word, address and path in these files must be the fixture's. Hits are not
# printed, so a real label or address never reaches a log; a word hit prints only line numbers.
FIXTURE_PATHS="^(~/\.agent-balancer/accounts/($LABELS)/\.claude|/Users/example|/opt/homebrew/bin/agent-balancer|/usr/local/bin/agent-balancer)$"
README_SCENES="Sources/AgentBalancerBar/ReadmeScenes.swift"
SCENES="$README_SCENES Sources/AgentBalancerBar/Manage/ManageScenes.swift Sources/AgentBalancerBar/RenderScenes.swift"
# Every word of the scenes' strings and comments, lowercased, that has the shape of a label
# (letters, digits and hyphens, with a letter) is a fixture label or one of these listed words,
# so an account name written in free text fails, capitalized or not. ISO times are not words. A
# new word fails until someone checks that it names no account and adds it here.
SCENE_WORDS="20x a accept-source-change account accounts add addresses after again agent-balancer
all alone am an and another as at auth badge banner bar because bin border browser by can cap
change changed chats check claude code com config configdir confirmed could count data dates day
daysleft dec deleted design document documents drawn duplicate each email empty-cli-missing
empty-first-run empty-reading empty-update ended ending-soon endingsoon ends endsat error
estimate every example expires expiring fable failed false file first fixed folder folders for
found frame frames from full fulllogin generatedat getting guaranteedleftpercentofcap half has
hides home homebrew hook html hyphen icon if in inuse is it its kind label labels last
launchallowed least left lights limited linepercent link linked local logged login loginexpiresat
loginexpiressource made-up manage manage-add-folder manage-add-token manage-email-note
manage-folder manage-remove
manage-states manage-token manage-token-run marginpercent max menu menu-refreshing menu-states
menu-steps meter minute missing mock moment new next no none not nov null of ok on one only opt or
other out over own path pictures place plan plantier pm poll pool possible
possibleleftpercentofcap probe produce ran read readingsage readme readme-hero
readme-manage-folders readme-manage-tokens readme-menu reads real reason refresh rejected remove render reserve reset
resets resetsat reuse right role room rounded row rows run s same scene schemaversion selected
sessions set settings shared sheet show shows sign sign-in signed signed-in signincheck since so
soon soonest source starts state statesince statesjson status stay stops terminal text the their
them
this three tier tile time timed times title to token tool traffic true tue two ultra under until
updated used usedpercent users usr warnings was wed weekly when which whose will window with
workers writer writes written wrong"
# The text of each string literal and comment of the Swift file $1, as "line<TAB>text".
free_text() {
  awk '
    {
      line = $0
      if (block) {
        if (line ~ /^[[:space:]]*"""/) { block = 0; line = substr(line, index(line, "\"\"\"") + 3) }
        else { print NR "\t" line; next }
      }
      out = ""; instr = 0; i = 1; n = length(line)
      while (i <= n) {
        c = substr(line, i, 1)
        if (instr) {
          if (c == "\\") { out = out substr(line, i, 2); i += 2; continue }
          if (c == "\"") { instr = 0; print NR "\t" out; i++; continue }
          out = out c; i++; continue
        }
        if (substr(line, i, 3) == "\"\"\"") { block = 1; break }
        if (substr(line, i, 2) == "//") { print NR "\t" substr(line, i + 2); break }
        if (c == "\"") { instr = 1; out = ""; i++; continue }
        i++
      }
    }' "$1"
}
if [ -f "$README_SCENES" ]; then
  reused="$(grep -oE '[A-Z][A-Za-z]*Scenes\.' "$README_SCENES" | sort -u || true)"
  [ -z "$(outside "$reused" '^(ManageScenes|RenderScenes)\.$')" ] \
    || bad "$README_SCENES reuses a scene file this check does not read"
fi
for src in $SCENES; do
  [ -f "$src" ] || { bad "missing scene source $src"; continue; }
  # Where the scenes name an account: JSON and Swift label fields, selections, typed labels,
  # opened steps, account folder paths and the command lines in texts.
  labels="$(
    grep -oE '\\?"label\\?":[[:space:]]*\\?"[^"\\]*' "$src" | sed -E 's/.*"//' || true
    grep -oE '(label|selection|typed)[[:space:]]*(==|=|:)[[:space:]]*"[^"]*"' "$src" \
      | sed -E 's/.*"([^"]*)"$/\1/' || true
    grep -oE 'steps:[[:space:]]*\[[^]]*\]' "$src" | grep -oE '"[^"]*"' | tr -d '"' || true
    grep -oE 'accounts/[^/"\\[:space:]]+/' "$src" | sed -E 's|^accounts/||; s|/$||' || true
    grep -oE 'agent-balancer (config (set|set-main|clear-main)|add|login|link|unlink|remove|verify|run) [a-z][a-z0-9-]*' "$src" \
      | awk '{print $NF}' || true
  )"
  [ -z "$(outside "$labels" "^($LABELS)$")" ] || bad "$src names an account outside the fixture"
  allowed="$(printf '%s main personal lab spare-a spare-b' "$SCENE_WORDS" | tr '\n' ' ')"
  unknown="$(free_text "$src" | awk -v allowed="$allowed" '
    BEGIN { n = split(allowed, w, / +/); for (i = 1; i <= n; i++) ok[w[i]] = 1 }
    {
      tab = index($0, "\t"); text = substr($0, tab + 1); gsub(/\\\([^)]*\)/, " ", text)
      gsub(/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9](:[0-9][0-9])?(\.[0-9]+)?Z?/, " ", text)
      n = split(text, t, /[^A-Za-z0-9-]+/)
      for (i = 1; i <= n; i++) {
        word = tolower(t[i]); sub(/^-+/, "", word)
        if (word ~ /^[a-z0-9][a-z0-9-]*$/ && word ~ /[a-z]/ && !(word in ok)) print substr($0, 1, tab - 1)
      }
    }' | sort -nu | tr '\n' ' ' | sed 's/ $//')"
  [ -z "$unknown" ] || bad "$src has a word that is neither a fixture label nor in SCENE_WORDS, on lines $unknown"
  # One leading hyphen is allowed, for the scene of an email that login will not pass on.
  addresses="$(grep -oE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]+' "$src" || true)"
  [ -z "$(outside "$addresses" "^-?($LABELS)@example\.com$")" ] \
    || bad "$src holds an address other than a fixture label at example.com"
  [ -z "$(outside "$(paths_in "$src")" "$FIXTURE_PATHS")" ] || bad "$src source holds a path outside the fixture"
  if banned_in "$src"; then bad "$src source holds a banned string"; fi
done

[ "$fail" -eq 0 ] || exit 1
echo "check-readme: ok"
