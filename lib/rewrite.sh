# shellcheck shell=bash
#
# History rewriting: strip Claude attribution from commit messages, commit and
# tag identities, and annotated tag messages.
#
# Design notes
#   * Everything operates on a bare --mirror clone, so all branches, tags and
#     notes are covered in one pass and no working tree can get in the way.
#   * `git filter-branch` is the engine. It is deprecated but it ships with git,
#     which matters for a tool whose failure mode is "half-migrated repo".
#   * The message filter lives in exactly one place (dc_filter_message) and is
#     re-entered via `declaudify --__filter-message`, so commit messages and
#     annotated tag messages can never drift apart in behaviour.

# --- patterns ----------------------------------------------------------------
#
# Both regexes are matched against LOWERCASED text, so they are written in
# lowercase. They are EREs. Override with --drop-regex / --identity-regex.

# Whole message lines to delete.
DC_DROP_RE_DEFAULT='^[[:blank:]]*(co-authored-by|co-developed-by|assisted-by|helped-by|signed-off-by)[[:blank:]]*:.*(claude|anthropic)|generated with.*claude code|claude\.ai/code|claude\.com/claude-code'

# Author/committer/tagger identities to reattribute. Deliberately narrower than
# a bare /claude/ so a human contributor actually named Claude is not swept up;
# the anthropic.com domain is the reliable signal.
DC_IDENT_RE_DEFAULT='@anthropic\.com|^claude$|^claude[[:blank:]]+(opus|sonnet|haiku|code|instant|[0-9])|^claude-|claude code'

dc_drop_re()  { printf '%s' "${DECLAUDIFY_DROP_RE:-$DC_DROP_RE_DEFAULT}"; }
dc_ident_re() { printf '%s' "${DECLAUDIFY_IDENT_RE:-$DC_IDENT_RE_DEFAULT}"; }

# --- message filtering -------------------------------------------------------

# Filter one message: stdin -> stdout.
#
# Drops matching lines, trims the trailing blank lines that removing a trailer
# leaves behind, and substitutes a fallback subject if nothing survives (a
# commit whose entire message was Claude boilerplate).
#
# Patterns arrive through the environment rather than `awk -v` because -v
# processes backslash escapes, which would quietly destroy `\.` in the regex.
dc_filter_message() {
    DC_DROP_RE="$(dc_drop_re)" \
    DC_FALLBACK="${DECLAUDIFY_FALLBACK:-Update}" \
    awk '
        BEGIN { drop_re = ENVIRON["DC_DROP_RE"]; fallback = ENVIRON["DC_FALLBACK"] }
        { if (tolower($0) ~ drop_re) next; buf[n++] = $0 }
        END {
            while (n > 0 && buf[n-1] ~ /^[[:space:]]*$/) n--
            if (n == 0) { if (fallback != "") print fallback; exit }
            for (i = 0; i < n; i++) print buf[i]
        }
    '
}

# True if an identity should be reattributed.
dc_is_claude_identity() {
    local name email re
    name=$(lower "${1:-}")
    email=$(lower "${2:-}")
    re=$(dc_ident_re)
    if printf '%s\n' "$name"  | grep -qE "$re"; then return 0; fi
    if printf '%s\n' "$email" | grep -qE "$re"; then return 0; fi
    return 1
}

# --- inspection --------------------------------------------------------------

# Populates DC_SCAN_* with what a rewrite would touch. One `git log` per class,
# so this stays fast on large histories.
dc_scan() {
    local repo=$1

    DC_SCAN_MSG_COUNT=$(
        { git -C "$repo" log --all --format='%x01%H%n%B' 2>/dev/null || true; } |
        DC_DROP_RE="$(dc_drop_re)" awk '
            BEGIN { RS = "\001"; drop_re = ENVIRON["DC_DROP_RE"]; hits = 0 }
            NF == 0 { next }
            {
                n = split($0, lines, "\n")
                for (i = 2; i <= n; i++)
                    if (tolower(lines[i]) ~ drop_re) { hits++; break }
            }
            END { print hits + 0 }
        '
    )

    DC_SCAN_IDENT_COUNT=$(
        { git -C "$repo" log --all --format='%an%x1f%ae%x1f%cn%x1f%ce' 2>/dev/null || true; } |
        DC_IDENT_RE="$(dc_ident_re)" awk -F '\037' '
            BEGIN { re = ENVIRON["DC_IDENT_RE"]; hits = 0 }
            {
                if (tolower($1) ~ re || tolower($2) ~ re ||
                    tolower($3) ~ re || tolower($4) ~ re) hits++
            }
            END { print hits + 0 }
        '
    )

    DC_SCAN_TAG_COUNT=0
    local tag
    while IFS= read -r tag; do
        [[ -n $tag ]] || continue
        [[ $(git -C "$repo" cat-file -t "refs/tags/$tag") == tag ]] || continue
        if [[ $(dc_tag_message "$repo" "$tag") != "$(dc_tag_message "$repo" "$tag" | dc_filter_message)" ]] ||
           dc_is_claude_identity "$(git -C "$repo" for-each-ref --format='%(taggername)' "refs/tags/$tag")" \
                                 "$(dc_tag_email "$repo" "$tag")"; then
            DC_SCAN_TAG_COUNT=$((DC_SCAN_TAG_COUNT + 1))
        fi
    done < <(git -C "$repo" for-each-ref --format='%(refname:strip=2)' refs/tags)

    DC_SCAN_TOTAL=$(( DC_SCAN_MSG_COUNT + DC_SCAN_IDENT_COUNT + DC_SCAN_TAG_COUNT ))
}

# Print a before/after preview of up to $2 affected commits.
dc_preview() {
    local repo=$1 limit=${2:-10} shown=0 sha subject before after
    while IFS= read -r sha; do
        [[ -n $sha ]] || continue
        before=$(git -C "$repo" log -1 --format='%B' "$sha")
        after=$(printf '%s\n' "$before" | dc_filter_message)
        if [[ $before != "$after" ]]; then
            shown=$((shown + 1))
            subject=$(git -C "$repo" log -1 --format='%h %s' "$sha")
            say "    ${C_DIM}--- $subject${C_RESET}"
            diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") 2>/dev/null |
                sed -n 's/^< /        - /p' >&2 || true
            if (( shown >= limit )); then break; fi
        fi
    done < <(git -C "$repo" log --all --format='%H')
    return 0
}

# --- tag helpers -------------------------------------------------------------

# Message body of an annotated tag, with any PGP signature stripped.
dc_tag_message() {
    git -C "$1" cat-file -p "refs/tags/$2" |
        awk 'seen { print } /^$/ && !seen { seen = 1 }' |
        awk '/^-----BEGIN PGP SIGNATURE-----$/ { exit } { print }'
}

dc_tag_email() {
    local raw
    raw=$(git -C "$1" for-each-ref --format='%(taggeremail)' "refs/tags/$2")
    raw=${raw#<}; raw=${raw%>}
    printf '%s' "$raw"
}

# --- rewrite passes ----------------------------------------------------------

# Pass 1: commit messages + author/committer identities, across all branches
# and tags.
dc_rewrite_commits() {
    local repo=$1 self=$2

    # The env-filter is evaluated by filter-branch's own /bin/sh, so it must be
    # POSIX sh and must export in place (it cannot be a subprocess). It shares
    # DC_IDENT_RE with dc_is_claude_identity so both agree on what "Claude" is.
    local env_filter='
        if printf "%s\n%s\n" "$GIT_AUTHOR_NAME" "$GIT_AUTHOR_EMAIL" |
             tr "[:upper:]" "[:lower:]" | grep -qE "$DC_IDENT_RE"; then
            GIT_AUTHOR_NAME="$DC_NEW_NAME"
            GIT_AUTHOR_EMAIL="$DC_NEW_EMAIL"
            export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL
        fi
        if printf "%s\n%s\n" "$GIT_COMMITTER_NAME" "$GIT_COMMITTER_EMAIL" |
             tr "[:upper:]" "[:lower:]" | grep -qE "$DC_IDENT_RE"; then
            GIT_COMMITTER_NAME="$DC_NEW_NAME"
            GIT_COMMITTER_EMAIL="$DC_NEW_EMAIL"
            export GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
        fi
    '

    DC_IDENT_RE="$(dc_ident_re)" \
    DC_NEW_NAME="$DECLAUDIFY_NEW_NAME" \
    DC_NEW_EMAIL="$DECLAUDIFY_NEW_EMAIL" \
    DECLAUDIFY_DROP_RE="$(dc_drop_re)" \
    DECLAUDIFY_FALLBACK="${DECLAUDIFY_FALLBACK:-Update}" \
    FILTER_BRANCH_SQUELCH_WARNING=1 \
    git -C "$repo" filter-branch -f \
        --msg-filter "'$self' --__filter-message" \
        --env-filter "$env_filter" \
        --tag-name-filter cat \
        -- --branches --tags >/dev/null 2>&1
}

# Pass 2: annotated tag messages and taggers, which --msg-filter never sees.
dc_rewrite_tags() {
    local repo=$1
    local tag obj name email date msg newmsg changed=0

    while IFS= read -r tag; do
        [[ -n $tag ]] || continue
        [[ $(git -C "$repo" cat-file -t "refs/tags/$tag") == tag ]] || continue

        obj=$(git -C "$repo" rev-parse "refs/tags/$tag^{}")
        name=$(git -C "$repo" for-each-ref --format='%(taggername)' "refs/tags/$tag")
        date=$(git -C "$repo" for-each-ref --format='%(taggerdate:raw)' "refs/tags/$tag")
        email=$(dc_tag_email "$repo" "$tag")
        msg=$(dc_tag_message "$repo" "$tag")
        newmsg=$(printf '%s\n' "$msg" | dc_filter_message)

        if dc_is_claude_identity "$name" "$email"; then
            name=$DECLAUDIFY_NEW_NAME
            email=$DECLAUDIFY_NEW_EMAIL
        fi

        # Recreate unconditionally: cheap, and it also drops signatures that the
        # commit rewrite already invalidated. An empty GIT_COMMITTER_DATE is
        # rejected by git, so only set it when the original had one.
        local -a env=(GIT_COMMITTER_NAME="$name" GIT_COMMITTER_EMAIL="$email")
        [[ -n $date ]] && env+=(GIT_COMMITTER_DATE="$date")

        if env "${env[@]}" git -C "$repo" tag -a -f --cleanup=whitespace \
                -F - "$tag" "$obj" <<<"$newmsg" >/dev/null 2>&1; then
            changed=$((changed + 1))
        else
            warn "could not rewrite annotated tag: $tag"
        fi
    done < <(git -C "$repo" for-each-ref --format='%(refname:strip=2)' refs/tags)

    printf '%s' "$changed"
}

# Pass 3: drop filter-branch's refs/original/* backups. Without this the
# pre-rewrite commits stay reachable and would be pushed to the new repo.
dc_drop_original_refs() {
    local repo=$1 ref dropped=0
    while IFS= read -r ref; do
        [[ -n $ref ]] || continue
        git -C "$repo" update-ref -d "$ref"
        dropped=$((dropped + 1))
    done < <(git -C "$repo" for-each-ref --format='%(refname)' refs/original 2>/dev/null)
    printf '%s' "$dropped"
}

# Drop anything that is not a branch, tag or note: refs/pull/*, refs/remotes/*
# and friends are either unpushable or not ours to migrate.
dc_prune_foreign_refs() {
    local repo=$1 ref pruned=0
    while IFS= read -r ref; do
        [[ -n $ref ]] || continue
        case $ref in
            refs/heads/*|refs/tags/*|refs/notes/*) continue ;;
        esac
        git -C "$repo" update-ref -d "$ref" 2>/dev/null || true
        pruned=$((pruned + 1))
    done < <(git -C "$repo" for-each-ref --format='%(refname)')
    printf '%s' "$pruned"
}

dc_gc() {
    local repo=$1
    git -C "$repo" reflog expire --expire=now --all >/dev/null 2>&1 || true
    git -C "$repo" gc --prune=now --quiet >/dev/null 2>&1 || true
}

# --- integrity ---------------------------------------------------------------

# "<ref> <tree-sha> <commit-count>" per branch/tag. Captured before and after
# the rewrite; the trees MUST be identical afterwards, which is what proves the
# rewrite changed metadata only and not a single byte of file content.
dc_snapshot() {
    local repo=$1 ref tree count
    while IFS= read -r ref; do
        [[ -n $ref ]] || continue
        tree=$(git -C "$repo" rev-parse "$ref^{tree}" 2>/dev/null) || continue
        count=$(git -C "$repo" rev-list --count "$ref^{commit}" 2>/dev/null || echo 0)
        printf '%s %s %s\n' "$ref" "$tree" "$count"
    done < <(git -C "$repo" for-each-ref --format='%(refname)' refs/heads refs/tags | sort)
}

# Loose, informational: any mention of claude/anthropic still reachable. Expected
# to be non-zero on repos that legitimately discuss Claude or have a human
# contributor named Claude — it is reported, never used as a gate.
dc_residual_count() {
    local repo=$1
    { git -C "$repo" log --all --format='%an%n%ae%n%cn%n%ce%n%B' 2>/dev/null || true; } |
        grep -icE 'claude|anthropic' || true
}

# Strict: message lines that still match the drop pattern, i.e. real attribution
# the rewrite failed to remove. This one IS a gate — it must be zero.
dc_residual_attribution_count() {
    local repo=$1
    { git -C "$repo" log --all --format='%B' 2>/dev/null || true; } |
        DC_DROP_RE="$(dc_drop_re)" awk '
            BEGIN { re = ENVIRON["DC_DROP_RE"]; n = 0 }
            tolower($0) ~ re { n++ }
            END { print n + 0 }
        '
}

# Strict: commits still authored or committed by a Claude identity. Also a gate.
dc_residual_identity_count() {
    local repo=$1
    { git -C "$repo" log --all --format='%an%x1f%ae%x1f%cn%x1f%ce' 2>/dev/null || true; } |
        DC_IDENT_RE="$(dc_ident_re)" awk -F '\037' '
            BEGIN { re = ENVIRON["DC_IDENT_RE"]; n = 0 }
            {
                if (tolower($1) ~ re || tolower($2) ~ re ||
                    tolower($3) ~ re || tolower($4) ~ re) n++
            }
            END { print n + 0 }
        '
}
