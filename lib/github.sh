# shellcheck shell=bash
#
# Thin wrappers over `gh`. Every call that changes state on GitHub goes through
# mutate(), so --dry-run is enforced in one place.
#
# jq is not a dependency - `gh api --jq` uses gh's built-in jq.

gh_preflight() {
    need_cmd gh "install from https://cli.github.com"
    gh auth status >/dev/null 2>&1 || die "gh is not authenticated - run: gh auth login"
}

gh_repo_exists() { gh api "repos/$1" >/dev/null 2>&1; }

gh_repo_field() { gh api "repos/$1" --jq "$2" 2>/dev/null; }

# --- sidebar cache -----------------------------------------------------------
#
# The repo homepage "Contributors" sidebar has its own cache, separate from
# Insights (stats/contributors). A force-push does NOT clear it: measured stale
# for 919 seconds while nothing was done to the repo. Toggling the default
# branch away and back does clear it, reproducibly, in about 60 to 80 seconds.
#
# Measurements, each with a no-op control window first:
#   control 919s stale -> toggle -> cleared 81s later
#   control 240s stale -> toggle -> cleared 61s later
# Archive/unarchive and pushing an extra commit were tested and did nothing.

DC_FLUSH_BRANCH=declaudify-cache-flush

gh_flush_sidebar_cache() {
    local repo=$1 default=$2 sha
    sha=$(gh api "repos/$repo/git/refs/heads/$default" --jq '.object.sha' 2>/dev/null) || return 1

    mutate gh api -X POST "repos/$repo/git/refs" \
        -f "ref=refs/heads/$DC_FLUSH_BRANCH" -f "sha=$sha" >/dev/null 2>&1 || return 1

    if ! mutate gh api -X PATCH "repos/$repo" -f "default_branch=$DC_FLUSH_BRANCH" >/dev/null 2>&1; then
        mutate gh api -X DELETE "repos/$repo/git/refs/heads/$DC_FLUSH_BRANCH" >/dev/null 2>&1
        return 1
    fi

    # Put it back immediately; the flush is triggered by the change itself.
    mutate gh api -X PATCH "repos/$repo" -f "default_branch=$default" >/dev/null 2>&1
    mutate gh api -X DELETE "repos/$repo/git/refs/heads/$DC_FLUSH_BRANCH" >/dev/null 2>&1
    return 0
}

# Contributor logins as the repo homepage renders them. There is no REST
# equivalent: /contributors omits co-authors entirely and stats/contributors is
# the Insights cache, so this reads the same private endpoint the page itself
# uses. Needs a token; returns nothing if unreadable.
gh_sidebar_contributors() {
    local repo=$1 token
    token=$(gh auth token 2>/dev/null) || return 1
    curl -sS --max-time 20 \
        -H "Authorization: token $token" \
        -H 'Accept: application/json' \
        -H 'X-Requested-With: XMLHttpRequest' \
        -H 'User-Agent: Mozilla/5.0' \
        "https://github.com/$repo/_sidebar" 2>/dev/null |
        grep -o '"login":"[^"]*"' | cut -d'"' -f4
}
