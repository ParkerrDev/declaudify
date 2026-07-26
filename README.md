# declaudify

Remove Claude attribution from a GitHub repository's entire history — including
the places a force-push cannot reach.

## Why this exists

Stripping `Co-authored-by: Claude <noreply@anthropic.com>` from your commits and
force-pushing **does not remove it from GitHub.** GitHub keeps a separate
`refs/pull/N/head` ref for every pull request you have ever opened, and a branch
push cannot touch those refs. The original commits stay visible in the PR's
Commits tab and reachable by SHA indefinitely.

You can see this for yourself on any repo that has ever had a PR:

```bash
git clone --mirror https://github.com/OWNER/REPO.git check.git
git -C check.git for-each-ref | grep refs/pull
```

The only way to actually remove those objects is to replace the repository
itself. That is what declaudify does.

## How it works

```
0. mirror-clone the repo             4. push the rewritten history into it
1. rewrite the history               5. verify the new repo matches
2. rename the old repo to "<name>."  6. delete the old repo
3. create a fresh repo as "<name>"
```

Nothing is deleted until step 5 has proved the replacement is complete and its
file content is byte-identical to the original.

## Install

```bash
git clone https://github.com/ParkerrDev/declaudify.git
cd declaudify
./declaudify --help
```

Requires `git`, `awk`, and an authenticated [`gh`](https://cli.github.com) with
the `delete_repo` scope:

```bash
gh auth refresh -h github.com -s delete_repo
```

declaudify checks for that scope **before** it renames anything, so a missing
scope fails fast instead of stranding a half-migrated repo.

## Usage

Always dry-run first. It clones, rewrites and reports locally, and touches
nothing on GitHub:

```bash
./declaudify --dry-run ParkerrDev/my-repo
```

Then, for real:

```bash
./declaudify ParkerrDev/my-repo
```

You will be shown a diff of every message line that will be removed, an
inventory of what the migration cannot carry over, and asked to type the repo
name to confirm. Deletion asks a second time.

### Options

| Option | Effect |
|---|---|
| `-n, --dry-run` | Rewrite locally, change nothing on GitHub |
| `-y, --yes` | Skip confirmations (dangerous by design) |
| `--keep-old` | Do everything except deleting the renamed old repo |
| `--suffix <s>` | Suffix for the renamed old repo (default `.`) |
| `--name` / `--email` | Identity to reattribute Claude-authored commits to |
| `--workdir <dir>` | Where to work; default keeps the backup under `~/.cache/declaudify` |
| `--drop-regex <re>` | Override which message lines are deleted |
| `--identity-regex <re>` | Override which identities count as Claude |
| `--fallback <text>` | Subject for commits whose message was entirely boilerplate |
| `--preview <n>` | How many message diffs to show (default 10) |

## What gets rewritten

- `Co-authored-by:`, `Co-developed-by:`, `Assisted-by:`, `Helped-by:` and
  `Signed-off-by:` trailers naming Claude or an `anthropic.com` address
- `🤖 Generated with [Claude Code](…)` lines and `claude.ai/code` /
  `claude.com/claude-code` links
- Commit **authors** and **committers** that are Claude — reattributed to the
  repo's most frequent human author (override with `--name` / `--email`)
- **Annotated tag** messages and taggers, which `git filter-branch --msg-filter`
  never sees
- Every branch and tag, not just the default branch

Commits whose entire message was boilerplate get a fallback subject (`Update`).

Attribution is scanned **before** pull-request refs are dropped, so a repo whose
branches are already clean but whose PR refs still carry Claude is correctly
reported and migrated, rather than dismissed as "nothing to do".

## What is deliberately left alone

The identity pattern is narrower than a bare `/claude/` so real people are not
swept up. These all survive untouched:

- Prose that happens to mention Claude — `Fix claude parser crash`
- A human contributor named Claude — `Claude Dubois <claude.dubois@example.fr>`
- Human `Co-authored-by:` and `Signed-off-by:` trailers

Override with `--identity-regex` / `--drop-regex` if your case differs.

## Safety

- **Dry-run mode** does the entire local half and nothing else.
- **Backup bundle** of the pre-rewrite history is written before anything is
  rewritten, and kept after success. Restore with
  `git clone backup.bundle restored`.
- **Content gate** — every branch and tag must have the same tree SHA and commit
  count after the rewrite as before. A history rewrite must change metadata
  only; if a single byte of file content moves, declaudify aborts.
- **Attribution gates** — zero surviving attribution lines and zero surviving
  Claude identities, checked on the local rewrite *and* re-checked against what
  is actually on GitHub after the push.
- **Rollback** — if any step fails after the rename, the old repo is renamed
  back and a newly created replacement is removed.
- Deletion happens only after all of the above passes, and asks for a second
  explicit confirmation.

## What is lost

Replacing a repository cannot carry over:

> issues, pull requests, releases, stars, forks, watchers, wiki, webhooks,
> deploy keys, branch protection, Actions secrets and variables, environments,
> collaborators, Pages configuration

Carried over: description, homepage, topics, visibility, default branch, and of
course all branches, tags and commits.

declaudify prints a live inventory of the target repo before asking you to
confirm, so you know exactly what you are trading.

## Limitations

- **Forks.** If the repo has forks, deleting it does not purge the old commits —
  GitHub promotes a fork to root the network and the objects live on there.
  declaudify warns when the target has forks.
- **Existing clones** keep the old history and will need re-cloning.
- **Signatures.** Rewriting invalidates GPG/SSH commit signatures; they are
  dropped rather than left broken.
- **Open PRs** are destroyed along with the old repo. Merge or close them first.
- `git filter-branch` spawns a process per commit, so very large histories are
  slow. It is used deliberately over `git filter-repo` because it ships with
  git, and a tool whose failure mode is "half-migrated repo" should not depend
  on something that may not be installed.

## Tests

```bash
./tests/run-tests.sh
```

54 assertions, no network and no dependencies beyond git and awk. They build
throwaway repos containing every flavour of attribution — plus the
false-positive bait above, and a commit reachable only from `refs/pull/1/head` —
run the real rewrite passes, and assert trees are unchanged, all refs are
covered, and the rewrite is idempotent.

## Layout

| Path | Role |
|---|---|
| `declaudify` | CLI and migration orchestration |
| `lib/common.sh` | Output, confirmation prompts, dry-run guard, rollback stack |
| `lib/rewrite.sh` | The rewrite passes, integrity snapshots and gates |
| `lib/github.sh` | `gh` wrappers; every mutation routed through `mutate()` |
| `tests/run-tests.sh` | Dependency-free test suite |

## License

MIT
