# declaudify

**/dee-CLAW-dih-fye/** *(verb)*

> **Definition:** to remove the butthole or stink from something.

```sh
curl -fsSL https://raw.githubusercontent.com/ParkerrDev/declaudify/master/install.sh | sh
```

## Why I built this

I'm not trying to hide the fact that I use AI to code, and I don't know why you
would, since that is what everyone is doing nowadays.

I just don't like to see a bright orange butthole logo next to my name every
time I commit!!!

## A unified theory of AI company logos

Look at them. Really look at them.

Every single one is a butthole. Anthropic's is just the most confident about it:
bright orange, perfectly centered, radiating outward like it has something to
announce. OpenAI went with the tasteful monochrome version. Google's is a
butthole doing a gradient.

This is not a coincidence. It is structural. The logos look like buttholes
because the companies are full of shit, and good branding should reflect the
product.

Anyway. That thing ends up in your contributors list, and this removes it.

## The part where I explain why this is harder than you think

You already tried the obvious fix. You stripped the `Co-authored-by` trailers,
you force-pushed, you felt good about yourself.

Go look at your repo homepage. **Claude is still in the Contributors sidebar.**

GitHub renders contributors from **two separate caches**, and a force-push only
clears one of them:

| Surface | Cleared by | How long |
|---|---|---|
| Insights > Contributors | the force-push | a few minutes |
| **Repo homepage sidebar** | **toggling the default branch** | **60 to 80 seconds** |

I measured this properly, with no-op control windows, on a clone of a real
200-commit repo:

```
force-push only, nothing else   ->  sidebar STILL STALE after 919s
archive + unarchive             ->  no effect
extra commit on default branch  ->  no effect
default-branch toggle           ->  cleared in 61s / 81s / 62s
```

So the internet's advice to "just wait 24 to 48 hours" is wrong twice over. The
sidebar does not fix itself in any useful timeframe, and once you toggle the
default branch it clears in about a minute.

It gets better: the sidebar is **invisible to the REST API**.
`/repos/{owner}/{repo}/contributors` omits co-authors entirely, so your repo can
look perfectly clean through the API while the homepage still credits Claude to
every visitor. declaudify reads the same private `/_sidebar` endpoint the page
itself uses, so it can actually tell.

## What it does

```
1. mirror-clone your repo, and bundle a full backup first
2. rewrite every commit message, author, committer, tag message and tagger
3. force-push it back to the SAME repo
4. verify on GitHub that content is byte-identical and attribution is gone
5. toggle the default branch away and back, flushing the sidebar cache
6. wait until BOTH contributor lists actually come back clean
```

Your repository is never renamed, replaced or deleted. **Stars, issues, pull
requests, forks, releases, webhooks and settings are all untouched.** The only
cost is that commit SHAs change, so existing clones need re-cloning.

Old commits do stay reachable by SHA and inside `refs/pull/N/head`, which no
force-push can reach. Neither feeds a contributor list, so Claude will not appear
anywhere GitHub renders contributors, but the objects are still on the server.
If you need them genuinely gone, nothing short of deleting the repository does
that, and that is your call to make, not this tool's.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/ParkerrDev/declaudify/master/install.sh | sh
```

Install and immediately run it on a repo:

```sh
curl -fsSL https://raw.githubusercontent.com/ParkerrDev/declaudify/master/install.sh | sh -s -- owner/repo
```

Or the boring way:

```sh
git clone https://github.com/ParkerrDev/declaudify.git
cd declaudify && ./declaudify --help
```

The installer drops the tool in `~/.local/share/declaudify`, links it into
`~/.local/bin`, tells you if that is not on your `PATH`, and checks your GitHub
token before you get halfway through a migration and discover it was missing a
permission. Override the location with `DECLAUDIFY_PREFIX`.

You need `git` and [`gh`](https://cli.github.com). Yes, even piped into `sh`,
every prompt still works: it reads from `/dev/tty`, not stdin.

## Usage

Dry run first. Always. It clones, rewrites, and shows you everything it would
do, while touching precisely nothing on GitHub:

```sh
declaudify --dry-run ParkerrDev/my-repo
```

Then for real:

```sh
declaudify ParkerrDev/my-repo
```

It shows a diff of every line it is about to remove, then makes you type the
repo name:

```
Rewrite ParkerrDev/my-repo?
Type my-repo to continue (anything else aborts):
```

After the push it flushes the sidebar cache and waits, reporting each surface as
it comes back clean:

```
==> Waiting for GitHub to recompute
    Do not push or change settings until this finishes.
    ✓ Insights contributors clean after 0s (ParkerrDev)
    ✓ homepage sidebar clean after 62s (ParkerrDev)
```

`--dry-run` walks the whole thing and stops right before the prompt. Nothing on
GitHub is touched.

### Options

| Option | Effect |
|---|---|
| `-n, --dry-run` | Rewrite locally, change nothing on GitHub |
| `-y, --yes` | Skip every prompt. You had better be sure |
| `-v, --verbose` | Show every step instead of just the important ones |
| `--no-flush` | Skip the default-branch toggle (leaves the sidebar stale) |
| `--name` / `--email` | Who to reattribute the AI's commits to |
| `--workdir <dir>` | Where to work. Default keeps the backup in `~/.cache/declaudify` |
| `--drop-regex <re>` | Override which message lines get deleted |
| `--identity-regex <re>` | Override what counts as Claude |
| `--fallback <text>` | Subject for commits whose message was *entirely* boilerplate |
| `--preview <n>` | How many message diffs to show (default 10) |

## About your token

declaudify needs an authenticated `gh` with **push access**. That is it. There is
no `delete_repo` scope to grant, because nothing is ever deleted.

**Admin** rights are needed only for the default-branch toggle that flushes the
sidebar. Without them the rewrite still runs and Insights still clears; you will
be told to flip the default branch yourself in Settings, or you can pass
`--no-flush` to skip it deliberately.

## What it rewrites

- `Co-authored-by:`, `Co-developed-by:`, `Assisted-by:`, `Helped-by:` and
  `Signed-off-by:` trailers naming Claude or an `anthropic.com` address
- `🤖 Generated with [Claude Code](...)` lines, and `claude.ai/code` and
  `claude.com/claude-code` links
- Commit **authors** and **committers** that are Claude, reattributed to the
  repo's most frequent human author (override with `--name` and `--email`)
- **Annotated tag** messages and taggers, which `git filter-branch --msg-filter`
  silently ignores and almost every homegrown script forgets about
- Every branch and every tag, not just the default branch

Commits whose entire message was boilerplate get a fallback subject, because git
is happier with something than nothing.

Attribution is scanned **before** pull-request refs are dropped, so a repo whose
branches you already cleaned but whose PR refs still have the logo gets correctly
reported instead of being waved through as "nothing to do."

## What it deliberately leaves alone

The identity pattern is narrower than a bare `/claude/` so it does not eat
actual human beings. All of this survives untouched:

- Prose that happens to mention Claude, like `Fix claude parser crash`
- A human contributor named Claude, like `Claude Dubois <claude.dubois@example.fr>`
- Human `Co-authored-by:` and `Signed-off-by:` trailers

Claude Dubois has done nothing wrong and deserves to keep his commits.

## Safety

- **Dry run mode** does the entire local half and touches nothing on GitHub.
- **A backup bundle** of the original history, pull-request refs included, is
  written before anything is rewritten and kept afterwards. If a run fails,
  declaudify prints the exact commands to push it back.
- **Content gate.** Every branch and tag must have the same tree hash and commit
  count after the rewrite as before. A history rewrite changes metadata and
  nothing else, so if a single byte of your files moves, it stops before pushing.
- **Attribution gates.** Zero surviving attribution lines and zero surviving
  Claude identities, checked on the local rewrite and then checked *again*
  against what is really on GitHub after the push.
- **Verified, not assumed.** It re-clones the pushed repo and compares it to the
  local rewrite rather than trusting that the push did what it said.

## What it costs

**Commit SHAs change.** That is the entire cost. Anyone with a clone, including
you, needs to re-clone:

```sh
git clone https://github.com/OWNER/REPO.git
```

Nothing is renamed, replaced or deleted. Your stars, issues, pull requests,
forks, releases, watchers, wiki, webhooks, branch protection, Actions secrets and
Pages config all stay exactly as they were.

## Limitations

- **Existing clones** keep the old history and need re-cloning.
- **Signatures.** Rewriting invalidates GPG and SSH commit signatures, so they
  are dropped rather than left dangling and broken.
- **Old objects survive on the server.** `refs/pull/N/head` is read-only, so
  those commits stay fetchable by SHA. They do not appear in either contributor
  list, but if you need them actually gone, only deleting the repository does
  that.
- **The sidebar flush needs admin.** Without it, Insights clears and the homepage
  sidebar does not.
- `git filter-branch` spawns a process per commit, so enormous histories are
  slow. It is used on purpose instead of `git filter-repo` because it ships with
  git, and a tool that force-pushes your history should not depend on something
  you might not have installed.

## Tests

```sh
./tests/run-tests.sh
```

73 assertions, no network, no dependencies past git and awk. They build throwaway
repos containing every flavour of attribution, plus the false-positive bait
mentioned above and a commit reachable only from `refs/pull/1/head`, run the real
rewrite passes, and assert that trees are unchanged, every ref is covered, and
the whole thing is idempotent.

One of the tests asserts this repository contains no em-dashes. I have my
reasons.

## Layout

| Path | Role |
|---|---|
| `declaudify` | CLI and migration orchestration |
| `install.sh` | The `curl \| sh` installer |
| `lib/common.sh` | Output, prompts, dry-run guard, rollback stack |
| `lib/rewrite.sh` | The rewrite passes, integrity snapshots and gates |
| `lib/github.sh` | `gh` wrappers, every mutation routed through `mutate()` |
| `tests/run-tests.sh` | The test suite |

## License

MIT. Do whatever you want with it.
