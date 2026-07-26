# shellcheck shell=bash
#
# Thin wrappers over `gh`. Every call that changes state on GitHub goes through
# mutate(), so --dry-run is enforced in one place.
#
# Repositories are tracked by their numeric id wherever possible: a rename can
# be normalised by GitHub (a trailing "." is not guaranteed to survive), and the
# id is the only handle that stays valid across one.
#
# jq is not a dependency - `gh api --jq` uses gh's built-in jq.

gh_preflight() {
    need_cmd gh "install from https://cli.github.com"
    gh auth status >/dev/null 2>&1 || die "gh is not authenticated - run: gh auth login"
}

# Space-separated OAuth scopes, or empty if the token type does not expose them
# (fine-grained PATs and App tokens do not send the header).
gh_token_scopes() {
    gh api -i -X GET user 2>/dev/null | awk '
        tolower($0) ~ /^x-oauth-scopes:/ {
            sub(/^[^:]*:[[:space:]]*/, "")
            gsub(/[,\r]/, " ")
            print
            exit
        }'
}

gh_has_scope() {
    local want=$1 scopes
    scopes=" $(gh_token_scopes) "
    [[ $scopes == *" $want "* ]]
}

gh_repo_exists() { gh api "repos/$1" >/dev/null 2>&1; }

gh_repo_field() { gh api "repos/$1" --jq "$2" 2>/dev/null; }

# Authoritative current full_name for a repo id - survives any rename.
gh_name_by_id() { gh api "repositories/$1" --jq '.full_name' 2>/dev/null; }

# Everything a rename/recreate migration cannot carry over, phrased for a human
# and listing only what this repo actually has. Sets:
#   GH_LOSS_LIST    e.g. "4 stars, 1 watcher, the wiki"  (empty if nothing)
#   GH_LOSS_STARS   star count, so the caller can shout about it separately
# Stars come first because they are the loss people regret and the only one
# that cannot be recreated by hand afterwards.
gh_inventory() {
    local repo=$1 base releases
    base=$(gh api "repos/$repo" --jq \
        '[.open_issues_count, .stargazers_count, .forks_count,
          .subscribers_count, .has_wiki, .has_pages] | @tsv' 2>/dev/null) || return 1
    releases=$(gh api "repos/$repo/releases?per_page=100" --jq 'length' 2>/dev/null || echo 0)

    local issues stars forks watchers wiki pages
    IFS=$'\t' read -r issues stars forks watchers wiki pages <<<"$base"

    GH_LOSS_STARS=${stars:-0}

    # Stars are deliberately NOT in this list: they get their own, louder line,
    # and GH_LOSS_STARS carries the count for it.
    local -a parts=()
    _count_part parts "${forks:-0}"    "fork"
    _count_part parts "${watchers:-0}" "watcher"
    _count_part parts "${issues:-0}"   "open issue or PR" "open issues and PRs"
    _count_part parts "${releases:-0}" "release"
    if [[ $wiki  == true ]]; then parts+=("the wiki"); fi
    if [[ $pages == true ]]; then parts+=("the Pages site"); fi

    GH_LOSS_LIST=''
    local p
    for p in ${parts[@]+"${parts[@]}"}; do
        GH_LOSS_LIST="${GH_LOSS_LIST:+$GH_LOSS_LIST, }$p"
    done
    return 0
}

# Append "<n> <thing>" (pluralised) to the named array, unless n is zero.
_count_part() {
    local -n __arr=$1
    local n=$2 singular=$3 plural=${4:-${3}s}
    (( n > 0 )) || return 0
    if (( n == 1 )); then __arr+=("$n $singular"); else __arr+=("$n $plural"); fi
}

gh_rename() {
    local repo=$1 newname=$2
    mutate gh api -X PATCH "repos/$repo" -f "name=$newname" >/dev/null
}

gh_create() {
    local full=$1 visibility=$2 description=$3 homepage=$4
    local args=("$full" "--$visibility")
    [[ -n $description ]] && args+=(--description "$description")
    [[ -n $homepage ]] && args+=(--homepage "$homepage")
    mutate gh repo create "${args[@]}" >/dev/null
}

gh_set_default_branch() {
    local repo=$1 branch=$2
    [[ -n $branch ]] || return 0
    mutate gh api -X PATCH "repos/$repo" -f "default_branch=$branch" >/dev/null
}

gh_copy_topics() {
    local from=$1 to=$2 topics t
    topics=$(gh api "repos/$from/topics" --jq '.names | join(" ")' 2>/dev/null) || return 0
    [[ -n $topics ]] || return 0

    local args=(-X PUT "repos/$to/topics")
    for t in $topics; do args+=(-f "names[]=$t"); done
    mutate gh api "${args[@]}" >/dev/null 2>&1 || warn "could not copy topics (non-fatal)"
}

gh_delete() {
    mutate gh repo delete "$1" --yes
}
