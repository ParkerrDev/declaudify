# declaudify

**/dee-CLAW-dih-fye/** *(verb)*

> **Definition:** to remove the butthole or stink from something.

```sh
curl -fsSL https://raw.githubusercontent.com/ParkerrDev/declaudify/main/install.sh | sh
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

Anyway. That thing ends up sitting in your commit history forever, and this
removes it.

## The part where I explain why this is harder than you think

You already tried the obvious fix. You rewrote the trailer out of your commits,
you force-pushed, you felt good about yourself.

**It is still there.**

GitHub keeps a separate `refs/pull/N/head` ref for every pull request you have
ever opened. A branch push cannot touch those refs. Your original commits, orange
logo and all, are still sitting in the PR's Commits tab and are still reachable
by SHA. Forever. Long after you have forgotten they exist.

Do not take my word for it. Go look at your own repo:

```sh
git clone --mirror https://github.com/YOU/YOUR-REPO.git check.git
git -C check.git for-each-ref | grep refs/pull
```

There it is. Hi.

The only way to actually remove those objects is to replace the repository
itself. So that is what this does.

## How it works

```
0. mirror-clone the repo             4. push the rewritten history into it
1. rewrite the history               5. verify the new repo matches
2. rename the old repo to "<name>."  6. delete the old repo (if you say so)
3. create a fresh repo as "<name>"
```

Nothing gets deleted until step 5 has proved the replacement is complete and its
file content is byte for byte identical to the original. The tool is paranoid on
your behalf, because the alternative is a very bad afternoon.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/ParkerrDev/declaudify/main/install.sh | sh
```

Install and immediately run it on a repo:

```sh
curl -fsSL https://raw.githubusercontent.com/ParkerrDev/declaudify/main/install.sh | sh -s -- owner/repo
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

It will show you a diff of every line it is about to delete, an inventory of what
the migration cannot carry over, and ask what should happen to the old repo:

```
Once the new repo is verified, what should happen to the old one?
    delete  delete ParkerrDev/my-repo. permanently, so the old commits are gone from GitHub
    keep    keep it as ParkerrDev/my-repo. so you can check it first and delete it yourself
Choose [delete/keep]:
```

Then it makes you type the repo name to confirm, and if you chose `delete` it
makes you type `delete` as well, after verification passes. Two different words,
on purpose, so a reflexive `y` cannot vaporize anything.

### Options

| Option | Effect |
|---|---|
| `-n, --dry-run` | Rewrite locally, change nothing on GitHub |
| `-y, --yes` | Skip every prompt. You had better be sure |
| `--keep-old` | Keep the renamed old repo |
| `--delete-old` | Delete it without being asked which you want |
| `--suffix <s>` | Suffix for the renamed old repo (default `.`) |
| `--name` / `--email` | Who to reattribute the AI's commits to |
| `--workdir <dir>` | Where to work. Default keeps the backup in `~/.cache/declaudify` |
| `--drop-regex <re>` | Override which message lines get deleted |
| `--identity-regex <re>` | Override what counts as Claude |
| `--fallback <text>` | Subject for commits whose message was *entirely* boilerplate |
| `--preview <n>` | How many message diffs to show (default 10) |

## About your token

declaudify needs the `repo` scope to rename and create repositories, and
`delete_repo` to remove the old one. If either is missing it tells you up front,
prints the exact command to fix it, and refuses to start a migration it cannot
finish:

```sh
gh auth refresh -h github.com -s repo -s delete_repo
```

If you are only missing `delete_repo`, it offers to migrate anyway and keep the
old repo so you can delete it yourself later. It does not strand you halfway.

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

This is a tool whose last step is `gh repo delete`, so:

- **Dry run mode** does the entire local half and nothing else.
- **A backup bundle** of the original history is written before anything is
  rewritten, and kept afterwards. Restore with `git clone backup.bundle restored`.
- **Content gate.** Every branch and tag must have the same tree hash and commit
  count after the rewrite as before. A history rewrite is supposed to change
  metadata and nothing else, so if a single byte of your actual files moves,
  declaudify stops.
- **Attribution gates.** Zero surviving attribution lines, zero surviving Claude
  identities, checked on the local rewrite and then checked *again* against what
  is really on GitHub after the push.
- **Rollback.** If anything fails after the rename, the old repo gets renamed
  back and a half-created replacement gets removed.
- Deletion happens only after all of the above passes, and only if you asked for
  it, and only after you type the word.

## What you lose

Replacing a repository cannot carry over:

> issues, pull requests, releases, stars, forks, watchers, wiki, webhooks, deploy
> keys, branch protection, Actions secrets and variables, environments,
> collaborators, Pages configuration

It does carry over description, homepage, topics, visibility, default branch, and
obviously every branch, tag and commit.

declaudify prints a live inventory of your repo before asking you to confirm, so
you know exactly what you are trading for a cleaner git log. If that trade is a
bad one for a given repo, use `--dry-run`, look at the numbers, and walk away.
That is a completely reasonable outcome.

## Limitations

- **Forks.** If your repo has forks, deleting it does not purge anything.
  GitHub promotes a fork to root the network and the old commits live on there.
  declaudify warns you when this applies.
- **Existing clones** still have the old history and need re-cloning.
- **Signatures.** Rewriting invalidates GPG and SSH signatures, so they get
  dropped rather than left dangling and broken.
- **Open PRs** die with the old repo. Merge or close them first.
- `git filter-branch` spawns a process per commit, so enormous histories are
  slow. It is used on purpose instead of `git filter-repo`, because it ships with
  git, and a tool whose worst case is "half-migrated repo" should not depend on
  something you might not have installed.

## Tests

```sh
./tests/run-tests.sh
```

68 assertions, no network, no dependencies past git and awk. They build throwaway
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
