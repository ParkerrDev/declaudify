# shellcheck shell=bash
#
# Shared helpers: output, prompts, guarded execution, and rollback bookkeeping.
#
# Sourced by `declaudify` and by the test suite. Everything here is pure bash
# with no external dependencies beyond coreutils.

# --- output ------------------------------------------------------------------

if [[ -t 2 && -z ${NO_COLOR:-} ]]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'
else
    C_RESET=''; C_BOLD=''; C_DIM=''
    C_RED=''; C_GREEN=''; C_YELLOW=''; C_CYAN=''
fi

# Everything human-facing goes to stderr so stdout stays clean for piping.
say()  { printf '%s\n' "$*" >&2; }
step() { printf '\n%s==>%s %s%s%s\n' "$C_CYAN$C_BOLD" "$C_RESET" "$C_BOLD" "$*" "$C_RESET" >&2; }
ok()   { printf '    %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*" >&2; }
info() { printf '    %s·%s %s\n' "$C_DIM" "$C_RESET" "$*" >&2; }
warn() { printf '    %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
bad()  { printf '    %s✗%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }

die() {
    printf '\n%serror:%s %s\n' "$C_RED$C_BOLD" "$C_RESET" "$*" >&2
    exit 1
}

# --- execution guards --------------------------------------------------------

: "${DECLAUDIFY_DRY_RUN:=0}"
: "${DECLAUDIFY_ASSUME_YES:=0}"

# Run a command that changes remote state. In dry-run mode it is printed, not run.
# Every GitHub mutation in this tool goes through here, so --dry-run is total.
mutate() {
    if [[ $DECLAUDIFY_DRY_RUN == 1 ]]; then
        printf '    %s[dry-run]%s %s\n' "$C_DIM" "$C_RESET" "$*" >&2
        return 0
    fi
    "$@"
}

# Ask for confirmation. With `expect` set, the user must type that exact string
# (used for the destructive steps so muscle-memory "y" cannot trigger a delete).
confirm() {
    local prompt=$1 expect=${2:-}
    local reply

    if [[ $DECLAUDIFY_ASSUME_YES == 1 ]]; then
        info "auto-confirmed (--yes): $prompt"
        return 0
    fi

    if [[ ! -t 0 ]]; then
        die "$prompt — refusing to continue without a terminal to confirm on. Re-run with --yes if you are sure."
    fi

    if [[ -n $expect ]]; then
        printf '\n%s%s%s\n' "$C_BOLD" "$prompt" "$C_RESET" >&2
        printf 'Type %s%s%s to continue (anything else aborts): ' "$C_BOLD" "$expect" "$C_RESET" >&2
        read -r reply
        [[ $reply == "$expect" ]] || die "aborted (expected \"$expect\", got \"$reply\")"
    else
        printf '\n%s%s%s [y/N] ' "$C_BOLD" "$prompt" "$C_RESET" >&2
        read -r reply
        [[ $reply == [yY] || $reply == [yY][eE][sS] ]] || die "aborted"
    fi
    return 0
}

# --- rollback ----------------------------------------------------------------
#
# Steps that change remote state push an undo command here. If the run dies
# after that point, the undo commands run in reverse order. This is what keeps a
# half-finished migration from leaving the repo stranded under its renamed name.

ROLLBACK_CMDS=()

# No-op in dry-run: nothing was mutated, so there is nothing to undo.
rollback_push() {
    [[ ${DECLAUDIFY_DRY_RUN:-0} == 1 ]] && return 0
    ROLLBACK_CMDS+=("$1")
    return 0
}

rollback_clear() { ROLLBACK_CMDS=(); }

rollback_run() {
    local i
    [[ ${#ROLLBACK_CMDS[@]} -gt 0 ]] || return 0

    step "Rolling back"
    for (( i = ${#ROLLBACK_CMDS[@]} - 1; i >= 0; i-- )); do
        say "    ${C_DIM}\$ ${ROLLBACK_CMDS[i]}${C_RESET}"
        if eval "${ROLLBACK_CMDS[i]}" >/dev/null 2>&1; then
            ok "undone"
        else
            bad "rollback command failed — you may need to finish this by hand:"
            say "        ${ROLLBACK_CMDS[i]}"
        fi
    done
    rollback_clear
}

# --- misc --------------------------------------------------------------------

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1${2:+ ($2)}"
}

# Portable lowercase (avoids bash 4 ${var,,} so the filters stay POSIX-friendly).
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
