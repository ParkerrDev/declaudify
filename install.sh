#!/bin/sh
#
# declaudify installer.
#
#   URL=https://raw.githubusercontent.com/ParkerrDev/declaudify/main/install.sh
#
#   curl -fsSL "$URL" | sh
#   curl -fsSL "$URL" | sh -s -- owner/repo     # install, then run on that repo
#
# POSIX sh on purpose: this is piped into whatever /bin/sh happens to be.
#
# Environment:
#   DECLAUDIFY_PREFIX   install prefix (default: ~/.local, or /usr/local as root)
#   DECLAUDIFY_REF      branch or tag to install (default: main)
#   DECLAUDIFY_REPO     source repo (default: ParkerrDev/declaudify)

set -eu

REPO="${DECLAUDIFY_REPO:-ParkerrDev/declaudify}"
REF="${DECLAUDIFY_REF:-main}"

if [ "$(id -u)" -eq 0 ]; then
    PREFIX="${DECLAUDIFY_PREFIX:-/usr/local}"
else
    PREFIX="${DECLAUDIFY_PREFIX:-$HOME/.local}"
fi

SHARE="$PREFIX/share/declaudify"
BIN="$PREFIX/bin"

if [ -t 2 ]; then
    BOLD=$(printf '\033[1m'); DIM=$(printf '\033[2m'); RESET=$(printf '\033[0m')
    RED=$(printf '\033[31m'); GREEN=$(printf '\033[32m'); YELLOW=$(printf '\033[33m')
else
    BOLD=''; DIM=''; RESET=''; RED=''; GREEN=''; YELLOW=''
fi

say()  { printf '%s\n' "$*" >&2; }
ok()   { printf '  %s+%s %s\n' "$GREEN" "$RESET" "$*" >&2; }
warn() { printf '  %s!%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die()  { printf '\n%serror:%s %s\n' "$RED$BOLD" "$RESET" "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

say ""
say "${BOLD}declaudify installer${RESET}"
say ""

# --- dependencies ------------------------------------------------------------

have git || die "git is required but was not found. Install git and try again."
ok "git $(git --version | awk '{print $3}')"

if have gh; then
    ok "gh $(gh --version 2>/dev/null | head -1 | awk '{print $3}')"
else
    warn "gh (the GitHub CLI) was not found."
    warn "declaudify needs it to rename, create and delete repositories."
    warn "Install it from https://cli.github.com then run: gh auth login"
fi

# --- fetch -------------------------------------------------------------------

if [ -d "$SHARE/.git" ]; then
    say ""
    say "Updating $SHARE ..."
    git -C "$SHARE" fetch --quiet origin "$REF" ||
        die "could not fetch $REF from $REPO"
    git -C "$SHARE" reset --hard --quiet "FETCH_HEAD"
    ok "updated to $(git -C "$SHARE" rev-parse --short HEAD)"
else
    say ""
    say "Installing to $SHARE ..."
    mkdir -p "$(dirname "$SHARE")"
    rm -rf "$SHARE"
    git clone --quiet --depth 1 --branch "$REF" \
        "https://github.com/$REPO.git" "$SHARE" ||
        die "could not clone https://github.com/$REPO (is it public, and does branch '$REF' exist?)"
    ok "cloned $REPO@$REF"
fi

chmod +x "$SHARE/declaudify"

# --- link --------------------------------------------------------------------

mkdir -p "$BIN"
ln -sf "$SHARE/declaudify" "$BIN/declaudify"
ok "linked $BIN/declaudify"

# --- PATH check --------------------------------------------------------------

case ":${PATH}:" in
    *":$BIN:"*) ;;
    *)
        say ""
        warn "$BIN is not on your PATH. Add it:"
        say ""
        say "    ${BOLD}export PATH=\"\$PATH:$BIN\"${RESET}      # bash / zsh"
        say "    ${BOLD}fish_add_path $BIN${RESET}               # fish"
        say ""
        ;;
esac

# --- token check -------------------------------------------------------------
#
# Told now rather than halfway through a migration, when a missing scope would
# be far more annoying to discover.

if have gh; then
    if gh auth status >/dev/null 2>&1; then
        SCOPES=$(gh api -i -X GET user 2>/dev/null | awk '
            tolower($0) ~ /^x-oauth-scopes:/ {
                sub(/^[^:]*:[ \t]*/, ""); gsub(/[,\r]/, " "); print; exit
            }') || SCOPES=''

        if [ -z "$SCOPES" ]; then
            warn "could not read your token's scopes (fine-grained PAT or App token)."
            warn "declaudify will tell you if a permission is missing when it runs."
        else
            MISSING=''
            case " $SCOPES " in *" repo "*) ;; *) MISSING="repo" ;; esac
            case " $SCOPES " in
                *" delete_repo "*) ;;
                *) MISSING="${MISSING:+$MISSING,}delete_repo" ;;
            esac

            if [ -n "$MISSING" ]; then
                say ""
                warn "your GitHub token is missing: ${BOLD}$MISSING${RESET}"
                warn "declaudify needs 'repo' to rename and create repos, and"
                warn "'delete_repo' to remove the old one. Grant them with:"
                say ""
                say "    ${BOLD}gh auth refresh -h github.com -s repo -s delete_repo${RESET}"
                say ""
                warn "Without delete_repo you can still migrate, but you will have to"
                warn "delete the old repo yourself (declaudify will offer to keep it)."
            else
                ok "GitHub token has the repo and delete_repo scopes"
            fi
        fi
    else
        say ""
        warn "gh is installed but not logged in. Run: ${BOLD}gh auth login${RESET}"
    fi
fi

# --- done --------------------------------------------------------------------

say ""
say "${GREEN}${BOLD}declaudify is installed.${RESET}"
say ""

if [ "$#" -gt 0 ]; then
    say "Running: declaudify $*"
    say ""
    # Prompts inside declaudify read from /dev/tty, so this stays interactive
    # even though this installer itself arrived through a pipe.
    exec "$SHARE/declaudify" "$@"
fi

say "Try it out. This changes nothing on GitHub:"
say ""
say "    ${BOLD}declaudify --dry-run owner/repo${RESET}"
say ""
say "Then, when you are happy with what it reports:"
say ""
say "    ${BOLD}declaudify owner/repo${RESET}"
say ""
say "${DIM}It will show you what it plans to do and ask before touching anything.${RESET}"
say ""
