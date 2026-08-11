# merk

merk is a small, content-addressed distributed version control system written in Zig.
It focuses on a clean core/CLI separation, structured commit metadata, and an extensible diff engine — with an eye toward being pleasant to read and to contribute to, not just to use.

If you know git, you already know most of merk's mental model. A few things are deliberately different — see [Terminology](#terminology-if-youre-coming-from-git) below before you go looking for `branch` or `HEAD`.

> **Status note:** configuration (default identity, default diff settings, aliases) is under active development and not implemented yet — see [Configuration](#configuration-work-in-progress).

## Features

- Content-addressed object store using BLAKE3
- Structured commits with intent, labels, trailers, and separate author/committer identity
- Interactive, hunk-level staging (`stage --patch`) — review and select individual hunks, not just whole files
- A configurable diff engine with three algorithms (Myers, Patience, Histogram), word-level highlighting, and multiple render formats
- Safe history editing (`uncommit`) with soft/mixed/hard/keep modes
- An advisory lock around staging writes, so two `merk` processes touching the same repository at once fail loudly instead of silently corrupting each other's work

## Quick start

```bash
zig build install
./zig-out/bin/merk init
./zig-out/bin/merk stage src/**/*.zig
./zig-out/bin/merk commit -m "feat: add initial diff command"
./zig-out/bin/merk diff
```

If you want to run `merk` without using the install prefix directly, add the install bin directory to your `PATH`:

```bash
export PATH="$PWD/zig-out/bin:$PATH"
```

## Terminology, if you're coming from git

merk keeps git's underlying model but renames a couple of concepts where git's own naming is either overloaded or just not very evocative. The full command surface still reads as ordinary English either way — nothing here is renamed just for flavor:

| git term                                   | merk term | why                                                                      |
| ------------------------------------------ | --------- | ------------------------------------------------------------------------ |
| `add`                                      | `stage`   | Names what the command actually does, rather than the generic "add"      |
| `HEAD`                                     | `current` | The current position in history — reads naturally in prose and in output |
| `branch` (internal, not yet a CLI concept) | `channel` | A channel carries a current — see [Planned](#planned)                    |

Everywhere else — `commit`, `diff`, `status`, `log`, `restore`, `rm`/`mv` semantics — uses the same words git does, because they're already the right words.

## Commands

Commands are grouped below the way the CLI groups them internally: repository, staging, history, and plumbing.

### Repository

#### `merk init [directory]`

Initialize a new repository (default: current directory).

- `-f`, `--force` — reinitialize an existing repository (resets the current position and index; does **not** delete existing objects or commits)
- `-q`, `--quiet` — only print errors and warnings

### Staging

#### `merk stage [options] [<path>|<dir>...]`

Stage changes from one or more paths. Passing a directory (or `.`) picks up new, never-before-staged files too, the way `git add .` does.

- `-A`, `--all` — restage every already-tracked path with a pending modification (does not discover new files — pass a directory for that)
- `-n`, `--dry-run` — preview what would be staged without making changes
- `-p`, `--patch` — interactively choose hunks to stage
- `--context <c>` — context lines shown around each hunk in `--patch` mode (default: 3)

> **Tip:** `--all` mirrors git's `add -u` (update tracked files), not `add -A` (stage everything). If you've just created new files and want them picked up too, pass the directory: `merk stage .`

#### `merk unstage <path>...`

Remove paths from staging and, unless `--cached`, delete them from the working tree too.

- `--cached` — only unstage; leave the working tree file alone

#### `merk restore <path>...`

Restore working tree paths from the index, discarding local changes. With `--staged`, unstages the path(s) instead, leaving the working tree untouched.

- `--staged` — unstage the path(s) instead of touching the working tree

#### `merk mv <from>... <to>`

Move or rename tracked files or directories, updating both the staging area and the working tree. With multiple sources, `<to>` must be a tracked directory.

- `--force` — overwrite an already-tracked destination path

#### `merk status`

Show staged, modified, and deleted paths against the current commit.

### History

#### `merk commit -m <message> [options] [labels...]`

Record staged changes as a new commit.

- `-m`, `--message <msg>` — commit title (required)
- `--body <text>` — extended description; trailing `key: value` lines are parsed as trailers automatically
- `--no-body-trailers` — treat the body as plain text; skip trailer extraction
- `--trailer <key=value>` — append a trailer (repeatable)
- `-i`, `--intent <intent>` — `feature|fix|refactor|docs|test|performance|security|build|ci|release|chore`, or a custom name
- `-l`, `--label <label[,label]>` — comma-separated scope labels (positional args also accepted)
- `--author <name>`, `--author-email <addr>`, `--author-date <date>` / `--date <date>` — author identity and timestamp (Unix-ms or `YYYY-MM-DD`)
- `--committer <name>` / `--committer-name`, `--committer-email <addr>`, `--committer-date <date>` — committer identity, defaulting to the author's

#### `merk uncommit [--hard | --mixed | --keep] [--yes]`

Move the current branch back to its parent, undoing the last commit.

- `--soft` (default) — keep the undone changes staged
- `--mixed` — reset staging to the parent commit; leave the working tree alone
- `--hard` — reset staging **and** the working tree to the parent commit (destructive)
- `--keep` — rebuild staging from the current on-disk content of tracked paths
- `-y`, `--yes` — required to confirm a `--hard` uncommit of the root commit, since that deletes tracked files with nothing else pointing at their content

#### `merk diff [options] [<path>...]`

Show changes between staging and the working tree by default, or between commits with `--rev`.

- `-f`, `--format <fmt>` — `unified`, `side-by-side`, `blocks`, `ops`, `summary`
- `-l`, `--level <lvl>` — `file`, `hunk`, `line`, `word`
- `-c`, `--context <n>` — context lines (a number, or `minimal`, `normal`, `full`)
- `-g`, `--group <mode>` — `none`, `files`, `dirs`
- `--algo <name>` — `myers`, `patience`, `histogram` (default: `histogram`)
- `--rev <hash>` — commit to compare; pass twice to compare two commits (default: working tree vs. staging). Takes a real commit hash, not a symbolic name like `current`.
- `--word` — inline word-level highlighting
- `--only-added` / `--only-deleted` / `--only-modified` — shortcuts for filtering to one change type
- `--show <types>` — comma-separated `added,deleted,modified`
- `--detect-moves` — heuristic move detection
- `--color <when>` / `--no-color` — `auto`, `always`, `never`
- `--profile <name>` — `review`, `ci`, `debug` output presets
- `--staged` — summarize staged changes only (structural; mutually exclusive with `--rev`)
- `--working` — diff working tree changes (default)

#### `merk inspect [<commit-hash>] [<commit-hash>] [options]`

Show a commit's metadata and its changes against its parent, or the changes between two commits when two hashes are given. With no arguments, inspects the current commit. Accepts short hash prefixes.

- `-s`, `--stat` — per-file change summary with totals instead of a full diff
- `--name-only` — list only changed file paths
- `-w`, `--word` — word-level highlighted diff
- `--format <fmt>` — `unified|side_by_side|blocks|ops|summary` (default: `unified`) — note the underscore in `side_by_side`; `diff`'s equivalent flag uses a hyphen. This is a known inconsistency between the two commands' parsers, not intentional — worth normalizing eventually.
- `-a`, `--algorithm <algo>` — `myers|patience|histogram` (default: `histogram`)
- `-U`, `--context <n>` — lines of context around changes (default: 3)
- `--group-by <mode>` — `none|files|dirs`
- `--filter <list>` — comma list of `added,deleted,modified` (default: all)
- `--path <prefix>` — limit to paths starting with this prefix (repeatable)
- `--no-header` — suppress the commit metadata header (0-/1-arg forms only)

#### `merk log`

Print commits reachable from the current position, each with its hash, author, committer, message, and parents. (A pager for long output is planned but not yet implemented.)

### Plumbing

#### `merk write-tree`

Write the current staging area as a Merkle root and print its hash.

## Diff algorithms

`--algo` / `--algorithm` selects the line-matching strategy used by `diff` and `inspect`:

- `myers` — the classic shortest-edit-script algorithm
- `patience` — better output on code with repeated lines, at some cost to run time
- `histogram` — patience-derived and the default; usually the best balance of speed and readable output

## Architecture, briefly

For anyone deciding whether to dig into the code:

- **Core/CLI separation.** `src/core/` has no knowledge of argv, flags, or terminal output — it's a library. `src/cli/` parses arguments and calls into it. This means the core is usable as a library independent of the CLI, and is where most unit tests live.
- **Content-addressed storage.** Blobs, trees, and commits are all stored by their BLAKE3 hash under an object store — the same content staged twice never gets written twice.
- **Staging is a flat list, not a live tree.** Rather than maintaining a Merkle tree incrementally as files are staged, `Staging` holds a simple, path-sorted list of entries and rebuilds a tree on demand only at the two moments that actually need one (committing, and diffing staged vs. current). Since objects are content-addressed, rebuilding the same entries into a tree repeatedly is cheap — no page is ever written twice.
- **The diff engine is layered.** A line-level algorithm (Myers/Patience/Histogram) produces an edit script; a hunk-grouping layer turns that into reviewable, independently selectable hunks with context; a patch-application layer reconstructs file content from a hunk selection. `stage --patch`'s interactive loop is built entirely on top of those lower layers — the interactive prompt logic itself doesn't know anything about diffing.
- **I/O is Zig 0.16's `std.Io.Reader`/`std.Io.Writer`.** Interactive code (the patch-staging prompt loop) is written against the post-"Writergate" concrete, pointer-based I/O interfaces rather than the older `anytype`-generic style — worth knowing if you're used to older Zig I/O patterns.

## Testing

```bash
zig build test
```

runs the unit test suite, which lives alongside the code it tests throughout `src/`.

There's also a standalone **end-to-end simulation** under `tests/` that spawns the actual compiled `merk` binary against real temporary directories and drives it through realistic and adversarial sessions — not a `zig test`, but its own executable:

```bash
zig build
zig-out/bin/merk_e2e_sim ./zig-out/bin/merk   # add --keep-tmp to inspect the sandbox afterward
```

It covers, roughly:

- A full realistic session — init, stage, commit, diff, mv, restore, unstage, log, inspect, write-tree, and uncommit in all its modes
- Systematic flag coverage across every command, including invalid-value rejection
- Performance and load — bulk file staging/committing at scale, plus a repeated-commit-cycle check for accidental quadratic blowups in the staging/commit path
- Memory and CPU profiling via `/usr/bin/time -v` where available, degrading gracefully to wall-clock-only timing where it isn't
- Difficult conditions — large binary files, deep path nesting, Unicode and space-containing filenames, path-traversal and absolute-path rejection, oversized commit messages, and other edge cases where the bar is "doesn't crash or hang," not "exact output"
- Concurrency — two real processes racing a `stage` call against the same repository, to exercise the advisory lock without asserting a specific winner

If you're adding a new command or flag, extending this harness alongside the unit tests is the easiest way to catch cross-cutting bugs a unit test in isolation wouldn't — several real bugs (including a crash-free-but-wrong default-identity path on commit) were only found by driving the real binary this way.

## Configuration (work in progress)

A configuration module is currently under active development and isn't implemented yet — there's no config file merk reads today, and every example in this README that doesn't pass `--author`/`--author-email` explicitly is relying on whatever default identity resolution exists in the meantime.

The intent, once it lands, is a `.merk/config` (repository-level) with a user-level fallback, covering at minimum:

- Default author/committer identity, so `commit` doesn't require `--author-email` on every invocation
- Default diff algorithm and render profile (today's defaults — `histogram`, `unified` — are hardcoded)
- Color preferences (today's `--color`/`--no-color` are per-invocation only)
- Command aliases

If you're interested in this piece specifically, it's a good area to check in on before starting — the shape above is a starting intent, not a finalized design.

## Planned

Two different kinds of "not built yet" below: version-control features with git equivalents (where the interesting open question is naming, not whether the feature exists), and merk-specific tooling that doesn't have a direct git analog at all.

### Version control parity

Branching, tagging, and remote support (fetch/push/pull, merge, rebase, cherry-pick, stash) are reflected in internal naming but not yet exposed as CLI commands. The naming for these follows the same "carries meaning, not just git's word for it" approach as `stage`/`current`/`channel` above — candidates under consideration, not yet finalized:

| git concept   | candidate merk name                         |
| ------------- | ------------------------------------------- |
| switch branch | `flow`                                      |
| merge         | `join` (or the more conservative `combine`) |
| stash         | `shelve` (tis one is euh tbh)               |
| tag           | `mark`                                      |
| blame         | `trace`                                     |
| bisect        | `narrow`(Narrow down the bad commit)        |
| clone         | `copy`                                      |
| fetch         | `fetch`                                     |
| rebase        | `reroute`                                   |
| cherry-pick   | `pick`                                      |

### Beyond git parity

Ideas that aren't about matching git's feature set, in roughly the order they'd be useful to have:

- **Ignore patterns** (`.merkignore`) — a gitignore-style pattern file, so `stage .` and `status` don't have to be told by hand to skip build output, dependency directories, and the like.
- **Repository verification** (`merk verify` or similar) — a CLI-level entry point onto the staged-vs-store integrity check that already exists internally (`Staging.verify`), extended to check the whole object graph reachable from history, not just staged entries — useful after a crash, a manual filesystem edit, or once garbage collection (below) exists to make "prune too aggressively" a real failure mode worth having a checker for.
- **Garbage collection / pruning** — sweep blobs no longer reachable from any commit or the staging area. Doesn't matter today (nothing deletes objects), but matters once history rewriting (`uncommit --hard`, and eventually `reroute`) has run enough times to accumulate orphaned content.
- **Hooks** — pre-commit / post-commit script execution, for local validation or notification.
- **Machine-readable output** — a `--json` (or similar) mode on `status`, `log`, and `diff`, so merk is scriptable without parsing human-formatted text.
- **Shell completions** — bash/zsh/fish completion scripts for commands, flags, and flag values (most of which are closed enumerations already, like `--format`'s options, so completions would be cheap to generate accurately).
- **Commit signing** — GPG or SSH-based commit signatures and verification.

On the storage side, the index is being rebuilt as a content-defined-chunked Merkle B-tree, which should improve diff and staging performance on large trees once complete.

## Requirements

- **Zig 0.16 or newer.** merk's interactive staging code depends on the post-"Writergate" `std.Io.Reader`/`std.Io.Writer` interfaces (`std.io.fixedBufferStream` and friends were removed in this era of Zig) — an older toolchain will not build it.
- **Linux or another POSIX-like OS.** Not tested on Windows.
- `/usr/bin/time` (GNU time) is optional, only used by the E2E harness's memory/CPU profiling — everything else works without it.

## Development

Build and test with Zig:

```bash
zig build
zig build test
```

Install the built executable with Zig's install step:

```bash
zig build install
# or install to a custom prefix:
zig build install --prefix /usr/local
```

## Repository layout

- `src/core/` — the library: repository state, staging, the content-addressed object store, and the diff engine. Has no knowledge of argv or terminal output.
  - `src/core/repo/` — the `Repository` type itself and its supporting modules (options, status, errors)
  - `src/core/repository.zig` — the public facade re-exporting `src/core/repo/`'s types for the CLI to depend on
- `src/diff/` — the diff engine: line-level algorithms, hunk grouping and patch application, interactive hunk selection, and render formatting — `src/diff.zig` is its public facade
- `src/cli/` — argument parsing, command dispatch, and shared CLI plumbing (errors, output context)
  - `src/cli/commands/` — one file per command (`stage.zig`, `commit.zig`, `diff.zig`, etc.)
- `tests/` — the standalone E2E simulation binary (see [Testing](#testing))
- `docs/` — command and internal design documentation
- `build.zig` — build configuration
- `zig-out/` — build outputs

## Contributing

merk is under active development and contributions are welcome — bug reports, small fixes, and larger features alike.

A few things that'll make a change easier to review:

- **Explain the "why," not just the "what."** The existing code leans heavily on doc comments that explain design decisions and known sharp edges (see `src/core/repo/repo.zig` or `src/core/staging.zig` for the tone to match) — a PR that changes behavior without updating the doc comment explaining the old behavior's rationale is harder to review than one that does.
- **Tests alongside the change.** Unit tests for core logic, and — for anything touching the CLI surface or a cross-cutting concern like staging's lock or the diff pipeline — consider extending the E2E harness in `tests/` too.
- **Small, focused PRs** are easier to review than large ones, especially for a project this early where the internals are still settling.

If you're looking for a place to start: the [Planned](#planned) section above is a reasonable source of larger project ideas, and any `TODO`/`FIXME` comment in the source is fair game for a smaller one.

## License

Not yet specified in this repository — if you're planning to depend on or contribute to merk, please open an issue to clarify licensing before relying on it for anything beyond personal experimentation.

## Notes

This project is under active development. Some CLI flags and advanced diff modes are accepted in the parser but may still be planned in the core implementation.
