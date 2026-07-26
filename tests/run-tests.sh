#!/usr/bin/env bash
#
# declaudify test suite - no network, no dependencies beyond git/awk.
#
# Builds throwaway repositories containing every flavour of Claude attribution
# (and several things that must NOT be touched), runs the real rewrite passes
# against them, and asserts the outcome.
#
#   ./tests/run-tests.sh [-v]

set -uo pipefail   # deliberately not -e: a failing assertion must not abort

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
VERBOSE=${1:-}

source "$ROOT/lib/common.sh"
source "$ROOT/lib/rewrite.sh"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/declaudify-tests.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

PASS=0 FAIL=0 CURRENT=''

# --- assertions --------------------------------------------------------------

suite() { CURRENT=$1; printf '\n%s%s%s\n' "$C_BOLD" "$1" "$C_RESET"; }

_pass() { PASS=$((PASS + 1)); printf '  %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$1"; }
_fail() {
    FAIL=$((FAIL + 1))
    printf '  %s✗%s %s\n' "$C_RED" "$C_RESET" "$1"
    printf '      expected: %s\n      actual:   %s\n' "$2" "$3"
}

is()      { [[ "$2" == "$3" ]] && _pass "$1" || _fail "$1" "$3" "$2"; }
isnt()    { [[ "$2" != "$3" ]] && _pass "$1" || _fail "$1" "not $3" "$2"; }
has()     { [[ "$2" == *"$3"* ]] && _pass "$1" || _fail "$1" "to contain '$3'" "$2"; }
hasnt()   { [[ "$2" != *"$3"* ]] && _pass "$1" || _fail "$1" "to NOT contain '$3'" "$2"; }

# --- fixtures ----------------------------------------------------------------

# A repo covering: plain trailer, mixed-case trailer + generated-with block,
# Claude-authored commit, all-boilerplate message, prose mentioning claude,
# a human named Claude, annotated + lightweight tags, and a second branch.
make_repo() {
    local dir=$1
    mkdir -p "$dir"
    git init -q -b main "$dir"
    git -C "$dir" config user.name "Parker"
    git -C "$dir" config user.email "parker@example.com"
    git -C "$dir" config commit.gpgsign false

    _commit "$dir" a "First commit"

    _commit "$dir" b "Add b

Some body text.

Co-authored-by: Claude <noreply@anthropic.com>"

    _commit "$dir" c "Add c

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"

    GIT_AUTHOR_NAME="Claude" GIT_AUTHOR_EMAIL="noreply@anthropic.com" \
    GIT_COMMITTER_NAME="Claude" GIT_COMMITTER_EMAIL="noreply@anthropic.com" \
        _commit "$dir" d "Add d"

    _commit "$dir" e "🤖 Generated with [Claude Code](https://claude.com/claude-code)"

    # Must survive untouched: prose, a human co-author, a human named Claude.
    _commit "$dir" f "Fix claude parser crash

The claude client mishandled anthropic-style payloads. See claude.md.

Co-authored-by: Dana <dana@example.com>
Signed-off-by: Parker <parker@example.com>"

    GIT_AUTHOR_NAME="Claude Dubois" GIT_AUTHOR_EMAIL="claude.dubois@example.fr" \
    GIT_COMMITTER_NAME="Claude Dubois" GIT_COMMITTER_EMAIL="claude.dubois@example.fr" \
        _commit "$dir" g "Human contribution"

    git -C "$dir" tag -a v1.0 -m "Release v1.0

Co-authored-by: Claude <noreply@anthropic.com>" HEAD~4
    git -C "$dir" tag lightweight HEAD~3

    GIT_COMMITTER_NAME="Claude" GIT_COMMITTER_EMAIL="noreply@anthropic.com" \
        git -C "$dir" tag -a v2.0 -m "Tagged by Claude" HEAD~1

    git -C "$dir" checkout -q -b feature
    _commit "$dir" h "Feature work

Co-authored-by: Claude <noreply@anthropic.com>"
    git -C "$dir" checkout -q main
}

_commit() {
    local dir=$1 file=$2 msg=$3
    printf '%s\n' "$file" > "$dir/$file.txt"
    git -C "$dir" add -A
    git -C "$dir" commit -q -F - <<<"$msg"
}

mirror_of() {
    local src=$1 dst=$2
    git clone -q --mirror "$src" "$dst"
}

# Run the full local pipeline (everything declaudify does before it touches
# GitHub) against a mirror.
rewrite_all() {
    local mirror=$1
    export DECLAUDIFY_NEW_NAME="Parker"
    export DECLAUDIFY_NEW_EMAIL="parker@example.com"
    dc_rewrite_commits "$mirror" "$ROOT/declaudify"
    dc_rewrite_tags "$mirror" >/dev/null
    dc_drop_original_refs "$mirror" >/dev/null
    dc_gc "$mirror"
}

msg_of() { git -C "$1" log -1 --format='%B' "$2"; }
find_sha() { git -C "$1" log --all --format='%H %s' | awk -v s="$2" '$0 ~ s {print $1; exit}'; }

# =============================================================================

suite "message filter (unit)"

out=$(printf 'Subject\n\nBody\n\nCo-authored-by: Claude <noreply@anthropic.com>\n' | dc_filter_message)
is "strips a Co-authored-by trailer" "$out" "$(printf 'Subject\n\nBody')"

out=$(printf 'Subject\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>\n' | dc_filter_message)
is "strips a mixed-case trailer" "$out" "Subject"

out=$(printf 'Subject\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)\n' | dc_filter_message)
is "strips the generated-with line" "$out" "Subject"

out=$(printf '🤖 Generated with [Claude Code](https://claude.com/claude-code)\n' | dc_filter_message)
is "falls back when nothing survives" "$out" "Update"

out=$(DECLAUDIFY_FALLBACK="Chore" dc_filter_message <<<'Generated with Claude Code')
is "honours a custom fallback" "$out" "Chore"

out=$(printf 'Fix claude parser\n\nThe claude client broke on anthropic payloads.\n' | dc_filter_message)
is "leaves prose mentioning claude alone" "$out" "$(printf 'Fix claude parser\n\nThe claude client broke on anthropic payloads.')"

out=$(printf 'Subject\n\nCo-authored-by: Dana <dana@example.com>\n' | dc_filter_message)
has "keeps a human co-author" "$out" "Dana <dana@example.com>"

out=$(printf 'Subject\n\nSigned-off-by: Parker <parker@example.com>\n' | dc_filter_message)
has "keeps a human sign-off" "$out" "Signed-off-by: Parker"

out=$(printf 'Subject\n\n\n\n' | dc_filter_message)
is "trims trailing blank lines" "$out" "Subject"

out=$(printf 'Subject\r\n\r\nCo-authored-by: Claude <noreply@anthropic.com>\r\n' | dc_filter_message)
hasnt "handles CRLF messages" "$out" "anthropic"

suite "identity matching (unit)"

dc_is_claude_identity "Claude" "noreply@anthropic.com" && r=yes || r=no
is "matches Claude/anthropic.com" "$r" "yes"

dc_is_claude_identity "Claude Opus 4.8" "noreply@anthropic.com" && r=yes || r=no
is "matches a model-versioned name" "$r" "yes"

dc_is_claude_identity "Claude Dubois" "claude.dubois@example.fr" && r=yes || r=no
is "does NOT match a human named Claude" "$r" "no"

dc_is_claude_identity "Parker" "parker@example.com" && r=yes || r=no
is "does NOT match an unrelated human" "$r" "no"

# =============================================================================

suite "end-to-end rewrite"

make_repo "$TMP/origin"
mirror_of "$TMP/origin" "$TMP/m1"

before=$(dc_snapshot "$TMP/m1")
before_commits=$(git -C "$TMP/m1" rev-list --all --count)

dc_scan "$TMP/m1"
isnt "scan finds attribution" "$DC_SCAN_TOTAL" "0"
is "scan counts 4 attributed messages" "$DC_SCAN_MSG_COUNT" "4"
is "scan counts 1 Claude-authored commit" "$DC_SCAN_IDENT_COUNT" "1"

rewrite_all "$TMP/m1"

after=$(dc_snapshot "$TMP/m1")
is "every ref keeps its tree and commit count" "$after" "$before"
is "commit count unchanged" "$(git -C "$TMP/m1" rev-list --all --count)" "$before_commits"

all=$(git -C "$TMP/m1" log --all --format='%an%n%ae%n%cn%n%ce%n%B')
hasnt "no anthropic.com anywhere" "$all" "anthropic.com"
hasnt "no Co-authored-by Claude" "$all" "Co-authored-by: Claude"
hasnt "no generated-with line" "$all" "Generated with"

has "prose mentioning claude survives" "$all" "The claude client mishandled"
has "human co-author survives" "$all" "Dana <dana@example.com>"
has "human named Claude survives" "$all" "Claude Dubois"

sha=$(find_sha "$TMP/m1" "Add d")
is "Claude-authored commit reattributed" \
   "$(git -C "$TMP/m1" log -1 --format='%an <%ae>' "$sha")" "Parker <parker@example.com>"
is "…and its committer too" \
   "$(git -C "$TMP/m1" log -1 --format='%cn <%ce>' "$sha")" "Parker <parker@example.com>"

sha=$(find_sha "$TMP/m1" "Update")
is "all-boilerplate message became the fallback" "$(msg_of "$TMP/m1" "$sha")" "Update"

suite "refs, branches and tags"

is "feature branch still present" \
   "$(git -C "$TMP/m1" for-each-ref --format='%(refname)' refs/heads | sort | tr '\n' ' ')" \
   "refs/heads/feature refs/heads/main "

is "all three tags still present" \
   "$(git -C "$TMP/m1" for-each-ref --format='%(refname:strip=2)' refs/tags | sort | tr '\n' ' ')" \
   "lightweight v1.0 v2.0 "

feature_msg=$(git -C "$TMP/m1" log -1 --format='%B' refs/heads/feature)
hasnt "feature branch commit was rewritten" "$feature_msg" "anthropic"

tagmsg=$(dc_tag_message "$TMP/m1" v1.0)
hasnt "annotated tag message was rewritten" "$tagmsg" "anthropic"
has "annotated tag keeps its real content" "$tagmsg" "Release v1.0"

is "annotated tag tagger reattributed" \
   "$(git -C "$TMP/m1" for-each-ref --format='%(taggername)' refs/tags/v2.0)" "Parker"

is "lightweight tag still points at a commit" \
   "$(git -C "$TMP/m1" cat-file -t refs/tags/lightweight)" "commit"

is "refs/original cleaned up" \
   "$(git -C "$TMP/m1" for-each-ref --format='%(refname)' refs/original | wc -l | tr -d ' ')" "0"

# The strict gates must be clean...
is "no attribution lines survive" "$(dc_residual_attribution_count "$TMP/m1")" "0"
is "no Claude identities survive" "$(dc_residual_identity_count "$TMP/m1")" "0"

# ...while the loose count is deliberately non-zero here: the fixture contains a
# prose commit about "the claude client" and a human contributor named Claude
# Dubois, both of which must be left alone. 2 prose lines + 4 identity fields.
is "loose count sees only the intentional false-positive bait" \
   "$(dc_residual_count "$TMP/m1")" "6"

suite "idempotency and no-op repos"

snap1=$(dc_snapshot "$TMP/m1")
heads1=$(git -C "$TMP/m1" for-each-ref --format='%(refname) %(objectname)' refs/heads)
dc_scan "$TMP/m1"
is "second scan finds nothing to do" "$DC_SCAN_TOTAL" "0"

rewrite_all "$TMP/m1"
is "re-running leaves trees identical" "$(dc_snapshot "$TMP/m1")" "$snap1"
is "re-running leaves commit SHAs identical" \
   "$(git -C "$TMP/m1" for-each-ref --format='%(refname) %(objectname)' refs/heads)" "$heads1"

mkdir -p "$TMP/clean"
git init -q -b main "$TMP/clean"
git -C "$TMP/clean" config user.name "Parker"
git -C "$TMP/clean" config user.email "parker@example.com"
_commit "$TMP/clean" x "Just a normal commit"
mirror_of "$TMP/clean" "$TMP/m2"
dc_scan "$TMP/m2"
is "clean repo reports nothing to do" "$DC_SCAN_TOTAL" "0"

suite "foreign ref pruning"

git -C "$TMP/m2" update-ref refs/pull/7/head "$(git -C "$TMP/m2" rev-parse main)"
pruned=$(dc_prune_foreign_refs "$TMP/m2")
is "refs/pull was pruned" "$pruned" "1"
is "refs/heads survived pruning" \
   "$(git -C "$TMP/m2" for-each-ref --format='%(refname)' refs/heads | wc -l | tr -d ' ')" "1"

suite "attribution reachable only from a PR ref"

# The case a force-push cannot fix: branches are clean, but an attributed commit
# lives on in refs/pull/N/head. The scan must see it BEFORE pruning.
mkdir -p "$TMP/pronly"
git init -q -b main "$TMP/pronly"
git -C "$TMP/pronly" config user.name "Parker"
git -C "$TMP/pronly" config user.email "parker@example.com"
_commit "$TMP/pronly" base "Clean commit on main"
git -C "$TMP/pronly" checkout -q -b prbranch
_commit "$TMP/pronly" pr "PR work

Co-authored-by: Claude <noreply@anthropic.com>"
git -C "$TMP/pronly" update-ref refs/pull/1/head "$(git -C "$TMP/pronly" rev-parse prbranch)"
git -C "$TMP/pronly" checkout -q main
git -C "$TMP/pronly" branch -q -D prbranch

mirror_of "$TMP/pronly" "$TMP/m3"

dc_scan "$TMP/m3"
before_prune=$(( DC_SCAN_MSG_COUNT + DC_SCAN_IDENT_COUNT ))
is "scan sees the PR-ref attribution before pruning" "$before_prune" "1"

dc_prune_foreign_refs "$TMP/m3" >/dev/null
dc_scan "$TMP/m3"
after_prune=$(( DC_SCAN_MSG_COUNT + DC_SCAN_IDENT_COUNT ))
is "…and none remains once PR refs are pruned" "$after_prune" "0"
is "branches are untouched by that" \
   "$(git -C "$TMP/m3" for-each-ref --format='%(refname)' refs/heads | tr '\n' ' ')" \
   "refs/heads/main "

suite "prompts without a terminal"

# curl ... | sh leaves stdin pointing at the script, so these paths matter.
DECLAUDIFY_ASSUME_YES=1
choose picked "Delete or keep?" "delete:remove it" "keep:leave it"
is "choose falls back to the first option when it cannot prompt" "$picked" "delete"

confirm "auto-confirmed?" >/dev/null 2>&1 && r=ok || r=failed
is "confirm honours --yes without a tty" "$r" "ok"
DECLAUDIFY_ASSUME_YES=0

( set +e; DECLAUDIFY_ASSUME_YES=0; confirm "needs a tty?" </dev/null >/dev/null 2>&1 )
is "confirm refuses rather than assuming yes when it cannot ask" "$?" "1"

suite "what-you-lose summary"

# Stub gh so the inventory can be tested without touching the network.
# jq field order is: issues, stars, forks, watchers, wiki, pages
source "$ROOT/lib/github.sh"
_stub_gh() {
    local fields=$1 releases=$2
    eval "gh() {
        case \"\$*\" in
            *releases*) printf '%s\n' '$releases' ;;
            *)          printf '%s\n' '$fields' ;;
        esac
    }"
}

_stub_gh "$(printf '2\t4\t1\t5\ttrue\tfalse')" 3
GH_LOSS_LIST='' GH_LOSS_STARS=0
gh_inventory "who/what"
is "counts stars separately so they can be shouted about" "$GH_LOSS_STARS" "4"
is "lists losses in plain English, stars excluded" "$GH_LOSS_LIST" \
   "1 fork, 5 watchers, 2 open issues and PRs, 3 releases, the wiki"

_stub_gh "$(printf '0\t1\t0\t1\tfalse\tfalse')" 0
GH_LOSS_LIST='' GH_LOSS_STARS=0
gh_inventory "who/what"
is "singular forms read correctly" "$GH_LOSS_LIST" "1 watcher"

_stub_gh "$(printf '0\t0\t0\t0\tfalse\tfalse')" 0
GH_LOSS_LIST='x' GH_LOSS_STARS=9
gh_inventory "who/what"
is "an empty repo loses nothing" "$GH_LOSS_LIST" ""
is "…and reports zero stars" "$GH_LOSS_STARS" "0"

unset -f gh

suite "contributor-list matching (regression)"

# A joined list must not be matched against the single-identity pattern: the
# anchored ^claude$ never fires mid-list, which once made declaudify report
# "sidebar clean (ParkerrDev claude)".
dc_list_has_claude "ParkerrDev claude" && r=yes || r=no
is "detects claude in the MIDDLE of a login list" "$r" "yes"

dc_list_has_claude "claude ParkerrDev" && r=yes || r=no
is "detects claude at the start of a list" "$r" "yes"

dc_list_has_claude "ParkerrDev" && r=yes || r=no
is "clean list reads as clean" "$r" "no"

dc_list_has_claude "" && r=yes || r=no
is "empty list reads as clean" "$r" "no"

dc_list_has_claude "ParkerrDev claudia Claudette" && r=yes || r=no
is "does not false-positive on similar human logins" "$r" "no"

# The old, broken form, kept as an explicit demonstration of why it was wrong.
printf '%s\n' "ParkerrDev claude" | grep -qiE "$(dc_ident_re)" && r=yes || r=no
is "the naive joined-string match is indeed blind to this" "$r" "no"

suite "in-place mode"

out=$("$ROOT/declaudify" --help)
has "--in-place is documented" "$out" "--in-place"
has "…and says it keeps stars" "$out" "Keeps stars"
has "…and is honest about what it leaves behind" "$out" "PR refs"

# The mode must never reach the rename/create/delete path.
src=$(cat "$ROOT/declaudify")
has "in-place forces keep-old so nothing is deleted" "$src" "KEEP_OLD=1"
has "in-place exits before the replacement plan" "$src" 'say "    Re-clone local copies: git clone $PUSH_URL"'
hasnt "in-place block never calls gh_delete" \
   "$(printf '%s' "$src" | sed -n '/^if (( IN_PLACE )); then/,/^fi$/p')" "gh_delete"
hasnt "in-place block never calls gh_rename" \
   "$(printf '%s' "$src" | sed -n '/^if (( IN_PLACE )); then/,/^fi$/p')" "gh_rename"
has "in-place warns against touching the repo while it settles" "$src" "Do not push or change settings"

# The homepage sidebar is a separate cache from Insights. Measured: a force-push
# alone left it stale for 919s, while a default-branch toggle cleared it in 61s
# and 81s across two controlled runs.
has "in-place flushes the sidebar cache" "$src" "gh_flush_sidebar_cache"
has "in-place waits on the sidebar too, not just Insights" "$src" "homepage sidebar clean after"
has "…and explains the manual fallback when not admin" "$src" "change the default branch"

ghsrc=$(cat "$ROOT/lib/github.sh")
has "flush works by toggling the default branch" "$ghsrc" "default_branch=\$DC_FLUSH_BRANCH"
has "flush restores the original default branch" "$ghsrc" "default_branch=\$default"
has "flush cleans up its temporary branch" "$ghsrc" "DELETE \"repos/\$repo/git/refs/heads/\$DC_FLUSH_BRANCH\""
has "sidebar reader documents why REST is not enough" "$ghsrc" "omits co-authors"

suite "installer"

sh -n "$ROOT/install.sh" && r=ok || r=failed
is "install.sh is valid POSIX sh" "$r" "ok"
is "install.sh is executable" "$([[ -x $ROOT/install.sh ]] && echo yes || echo no)" "yes"
has "installer explains missing scopes" "$(cat "$ROOT/install.sh")" "gh auth refresh"
has "installer supports running straight after install" "$(cat "$ROOT/install.sh")" 'exec "$SHARE/declaudify" "$@"'

suite "no em-dashes anywhere"

# Built from bytes rather than written literally, otherwise this file would
# contain the very character it is asserting the absence of.
EMDASH=$(printf '\xe2\x80\x94')

for f in declaudify install.sh lib/common.sh lib/rewrite.sh lib/github.sh tests/run-tests.sh README.md; do
    is "no em-dash in $f" "$(grep -c "$EMDASH" "$ROOT/$f" 2>/dev/null || true)" "0"
done

suite "cli surface"

out=$("$ROOT/declaudify" --version)
has "--version works" "$out" "declaudify"

out=$("$ROOT/declaudify" --help)
has "--help documents the data loss" "$out" "WHAT IS LOST"

out=$(printf 'S\n\nCo-authored-by: Claude <noreply@anthropic.com>\n' | "$ROOT/declaudify" --__filter-message)
is "re-entry filter mode works" "$out" "S"

out=$("$ROOT/declaudify" 2>&1); rc=$?
is "no argument is an error" "$rc" "1"

out=$("$ROOT/declaudify" --bogus 2>&1); rc=$?
is "unknown option is an error" "$rc" "1"
has "…with a helpful message" "$out" "unknown option"

# =============================================================================

printf '\n%s%d passed, %d failed%s\n' \
    "$([[ $FAIL -eq 0 ]] && printf '%s' "$C_GREEN" || printf '%s' "$C_RED")" \
    "$PASS" "$FAIL" "$C_RESET"

[[ -n $VERBOSE ]] && printf 'fixtures kept at: %s\n' "$TMP" && trap - EXIT

exit $(( FAIL > 0 ? 1 : 0 ))
