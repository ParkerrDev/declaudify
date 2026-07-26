# shellcheck shell=bash
#
# Shared helpers: output, prompts, and guarded execution.
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

# Progress chatter that only appears with --verbose. Anything the user has to
# read, decide on, or act upon is never routed through here.
: "${DECLAUDIFY_VERBOSE:=0}"
detail() {
    [[ $DECLAUDIFY_VERBOSE == 1 ]] || return 0
    printf '    %s·%s %s\n' "$C_DIM" "$C_RESET" "$*" >&2
}

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

# True when there is some terminal we can prompt on.
has_tty() { [[ -t 0 ]] || [[ -r /dev/tty ]]; }

# Read one line from the user into the named variable.
#
# When declaudify is run through a pipe (curl ... | sh) stdin is the script
# itself, so prompts have to come from /dev/tty instead. Getting this wrong
# means a destructive prompt silently reads a line of shell source and treats
# it as the answer, so it is handled here once for every prompt in the tool.
ask() {
    local __var=$1 __prompt=$2 __line
    printf '%s' "$__prompt" >&2
    if [[ -t 0 ]]; then
        IFS= read -r __line || return 1
    elif [[ -r /dev/tty ]]; then
        IFS= read -r __line < /dev/tty || return 1
    else
        return 1
    fi
    printf -v "$__var" '%s' "$__line"
    return 0
}

# Ask for confirmation. With `expect` set, the user must type that exact string
# (used for the destructive steps so a muscle-memory "y" cannot trigger a
# delete).
confirm() {
    local prompt=$1 expect=${2:-}
    local reply=''

    if [[ $DECLAUDIFY_ASSUME_YES == 1 ]]; then
        info "auto-confirmed (--yes): $prompt"
        return 0
    fi

    if ! has_tty; then
        die "$prompt
       There is no terminal to confirm on. Re-run with --yes if you are sure."
    fi

    if [[ -n $expect ]]; then
        printf '\n%s%s%s\n' "$C_BOLD" "$prompt" "$C_RESET" >&2
        ask reply "$(printf 'Type %s%s%s to continue (anything else aborts): ' \
                     "$C_BOLD" "$expect" "$C_RESET")" || die "aborted (could not read a reply)"
        [[ $reply == "$expect" ]] || die "aborted (expected \"$expect\", got \"$reply\")"
    else
        ask reply "$(printf '\n%s%s%s [y/N] ' "$C_BOLD" "$prompt" "$C_RESET")" ||
            die "aborted (could not read a reply)"
        [[ $reply == [yY] || $reply == [yY][eE][sS] ]] || die "aborted"
    fi
    return 0
}

# --- misc --------------------------------------------------------------------

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1${2:+ ($2)}"
}

# Portable lowercase (avoids bash 4 ${var,,} so the filters stay POSIX-friendly).
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# "1 commit" / "3 commits". Third argument overrides an irregular plural.
plural() {
    local n=$1 singular=$2 many=${3:-${2}s}
    if (( n == 1 )); then printf '%s %s' "$n" "$singular"; else printf '%s %s' "$n" "$many"; fi
}
