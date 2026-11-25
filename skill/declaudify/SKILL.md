---
name: declaudify
description: Remove Claude attribution (Co-authored-by trailers, "Generated with Claude Code" lines, Claude as author or committer) from the history of one of the user's GitHub repositories with the declaudify tool, and clear it from GitHub's contributor lists. Use when asked to declaudify a repo, to get Claude out of a repo's contributors or sidebar, or to strip AI attribution from commits that are already pushed. Not for writing new commits: those simply never get attribution in the first place.
---

# declaudify

`declaudify` rewrites a GitHub repository's whole history so that nothing in
it credits Claude, force-pushes it back to the same repository, and then
toggles the default branch away and back so that the homepage's contributor
sidebar clears as well as Insights. Its README in the declaudify repository
says why both steps are needed.

It force-pushes every branch and tag. Every commit SHA changes, and every
existing clone (the user's own, other machines', collaborators') has to be
cloned again. Treat each run as an irreversible change to that repository,
because to everyone holding a clone it is one.

## Before anything

1. `command -v declaudify`. If it is not there, install it with the repo's
   own installer, which puts it in `~/.local/share/declaudify` and links
   `~/.local/bin/declaudify`:

   ```sh
   curl -fsSL https://raw.githubusercontent.com/ParkerrDev/declaudify/master/install.sh | sh
   ```

   A checkout at `~/Dev/GitHub/declaudify` works as well: run
   `~/Dev/GitHub/declaudify/declaudify` from it.
2. `gh auth status`: it needs push access to the repository, and admin rights
   for the sidebar flush. Without admin the rewrite still runs and Insights
   clears, but the user then has to flip the default branch in Settings.
3. Look for local clones of the repository on this machine (usually under
   `~/Dev/GitHub/<repo>`, `~/Dev/<repo>`, `~/Work/<repo>`). For each, check
   `git status` and `git log @{u}..` for work that is not pushed. Unpushed
   commits or stashes there are lost to the new history unless they are pushed
   first or carried over by hand afterwards. Tell the user about each one
   before going on.

## The run

1. Always a dry run first. It clones, rewrites locally, and shows each line it
   would remove, touching nothing on GitHub:

   ```sh
   declaudify --dry-run OWNER/REPO
   ```

2. Show the user what the dry run found: how many commits and tags change, the
   lines removed, and who the Claude commits are reattributed to. It defaults
   to the repository's most frequent human author. The user's own identity is
   `ParkerrDev <114211845+ParkerrDev@users.noreply.github.com>`, and `--name`
   and `--email` set it explicitly.
3. Ask the user, in so many words, whether to rewrite that repository, and
   name it. Run it for real only on a clear yes to that repository. A yes to
   a different repository, or an earlier general yes, does not count.
4. Run it without `--yes`, so that the tool's own prompt (type the repository
   name) stays in place. Use `--yes` only if the user asked for it by name.
   The tool reads its prompt from `/dev/tty`, so run it in a terminal the user
   can see or type into. If it cannot be answered from here, give the user the
   exact command to run and stop.

   ```sh
   declaudify --name ParkerrDev --email 114211845+ParkerrDev@users.noreply.github.com OWNER/REPO
   ```

5. While it waits for GitHub to recompute the contributor lists ("Do not push
   or change settings until this finishes"), push nothing and change nothing in
   that repository.

## Afterwards

- Report what it printed: each surface it saw come back clean, and where the
  backup bundle is kept (under `~/.cache/declaudify` unless `--workdir` was
  given). If a run fails, declaudify prints the exact commands that push the
  backup back: pass them on, word for word.
- Every local clone is now on the old history. Re-clone each one, or, for a
  clone with nothing unpushed, `git fetch` and `git reset --hard @{u}` on each
  branch. Do that only for clones whose status was checked clean above, and say
  which ones were reset.
- A private repository's sidebar cannot be read back by the tool. When it says
  so, tell the user to look at the repository's page themselves.
- Old commits stay reachable by SHA and in `refs/pull/N/head` on GitHub.
  Neither feeds a contributor list. Only deleting the repository removes them,
  and that is never this skill's to suggest as a step: mention it only if the
  user asks how to make the old objects truly gone.

## Never

- Never run it on a repository the user has not named in this conversation,
  and never on a repository they do not own.
- Never delete, rename or archive a repository, and never use `--no-flush`
  unless asked.
- Never add Co-Authored-By trailers, "Generated with" lines or an assistant's
  name to any commit in the first place. The user's rules forbid them
  everywhere, which is what makes declaudify a cleanup tool and not a habit.
