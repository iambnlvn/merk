# `nodus diff`

> **Status:** Core engine stable. CLI surface in active development. Some features listed below are **planned** and not yet implemented.

---

## Overview

`nodus diff` compares two sets of files and produces a human-readable or machine-parseable delta. It is the default command for reviewing changes in the Nodus DVCS.

Unlike Git's diff, Nodus separates **what to compare**, **how to render**, and **how much detail to show** into independent axes. This lets you compose commands like:

```bash
nodus diff --format side-by-side --level word --context full
```

---

## Philosophy

- **Raw-source first:** The diff engine operates on bytes, not ASTs. The AST delta layer consumes these results.
- **Two passes:** Every changed file gets a line-level diff (for display) and a word-level diff (for precision / intent classification).
- **Pluggable line-diff algorithm:** Myers, Patience, and Histogram are all available (`--algo`). Word-level diffing always uses Myers — the inputs are small enough that the extra structure Patience/Histogram offer doesn't pay for itself.
- **Core/CLI separation:** `core/diff.zig` knows nothing about flags, terminals, or argv. `cmds/diff.zig` translates user input into a `RenderConfig` and calls into the core.

---

## Quick Start

```bash
# Default: modern unified view of working tree changes
nodus diff

# Side-by-side review mode (recommended)
nodus diff --format side-by-side

# Only see what files changed
nodus diff --level file

# Deep inspection with full context and word-level changes
nodus diff --format unified --level word --context full

# Use a preset profile
nodus diff --profile review

# Pick a different line-diff algorithm
nodus diff --algo patience
```

---

## Command Reference

### A. What to Compare _(Partially Planned)_

| Invocation        | Description                                             | Status                                                                                                                       |
| ----------------- | ------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| _(no args)_       | Compare working tree against the index                  | **Stable**                                                                                                                   |
| `--working`       | Explicitly compare working tree against index (default) | **Stable**                                                                                                                   |
| `--staged`        | Compare the index against HEAD (staged changes)         | **Not implemented** — flag is accepted by the parser but the command errors out (`error.NotImplemented`) rather than running |
| `<ref>`           | Compare `<ref>` against the working tree                | **Planned**                                                                                                                  |
| `<ref-a> <ref-b>` | Compare two refs/commits                                | **Planned**                                                                                                                  |

```bash
nodus diff                    # working vs index
nodus diff --staged           # currently errors: not implemented
nodus diff HEAD~1             # planned: ref vs working
nodus diff v1.0.0 main        # planned: two refs
```

---

### B. Output Format (`--format`, `-f`)

Controls the visual layout of the diff.

| Value          | Description                                             | Status     |
| -------------- | ------------------------------------------------------- | ---------- |
| `unified`      | Git-like patch with `+` / `-` prefixes and hunk headers | **Stable** |
| `side-by-side` | Two-column before/after view                            | **Stable** |
| `blocks`       | Change blocks grouped as BEFORE/AFTER sections          | **Stable** |
| `ops`          | Explicit edit operations (FROM line / TO line)          | **Stable** |
| `summary`      | One-line per file                                       | **Stable** |

```bash
nodus diff -f side-by-side
nodus diff -f blocks
nodus diff --format ops
```

---

### C. Detail Level (`--level`, `-l`)

Controls how granular the output is.

| Value  | Description                                               | Status     |
| ------ | --------------------------------------------------------- | ---------- |
| `file` | Only list files changed (status + counts)                 | **Stable** |
| `hunk` | Grouped hunks (omits unchanged lines)                     | **Stable** |
| `line` | Normal line-by-line diff (default)                        | **Stable** |
| `word` | Inline word-level diff with `[-old-]` / `[+new+]` markers | **Stable** |

```bash
nodus diff -l file
nodus diff --level word
nodus diff -f side-by-side -l word
```

---

### D. Line-Diff Algorithm (`--algo`)

Controls which algorithm produces the line-level edit script. Word-level diffing is unaffected — it always uses Myers regardless of this flag.

| Value       | Description                                                                                                                                            | Status     |
| ----------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------- |
| `myers`     | O(ND) shortest edit script. Minimal edits, but can produce noisy hunks when coincidental matches exist deep in changed regions.                        | **Stable** |
| `patience`  | Anchors on lines that are unique in both files first, then recurses. Falls back to Myers for segments with no unique anchors.                          | **Stable** |
| `histogram` | Like Patience but uses occurrence-frequency buckets instead of requiring strict uniqueness. Default. Degrades to Myers when no useful anchor is found. | **Stable** |

```bash
nodus diff --algo myers
nodus diff --algo patience
nodus diff --algo histogram   # default
```

---

### E. Context Control (`--context`, `-c`)

How many unchanged lines to show around each change.

| Value      | Description                    | Status     |
| ---------- | ------------------------------ | ---------- |
| `<number>` | Exact number of context lines  | **Stable** |
| `minimal`  | Only changed lines (0 context) | **Stable** |
| `normal`   | 3 lines of context (default)   | **Stable** |
| `full`     | Entire file                    | **Stable** |

```bash
nodus diff -c 10
nodus diff --context minimal
nodus diff --context full
```

---

### F. Structural Grouping (`--group`, `-g`)

Group the output by directory or flatten it.

| Value   | Description                       | Status     |
| ------- | --------------------------------- | ---------- |
| `none`  | Flat list (default)               | **Stable** |
| `files` | Group by file (adds file headers) | **Stable** |
| `dirs`  | Group by parent directory         | **Stable** |

```bash
nodus diff --group dirs
```

Output:

```
src/
  auth.zig
  parser.zig

tests/
  auth_test.zig
```

---

### G. Change Type Filters

Show only specific kinds of changes.

| Flag              | Description                                           | Status     |
| ----------------- | ----------------------------------------------------- | ---------- |
| `--only-added`    | New files only                                        | **Stable** |
| `--only-deleted`  | Removed files only                                    | **Stable** |
| `--only-modified` | Modified files only                                   | **Stable** |
| `--show <types>`  | Comma-separated combination: `added,deleted,modified` | **Stable** |

`--show` overrides any of the `--only-*` shorthand flags if both are given.

```bash
nodus diff --only-modified
nodus diff --show added,deleted
```

---

### H. Inline Word Diff (`--word`)

When used with `--level line`, highlights changed words inside lines using `[-old-]` and `[+new+]` markers.

| Status                                                                                                                                                                                                                        |
| ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Partially implemented** — word-level data is computed for every diff. Dedicated rendering (`renderWordDiff` / the `word` level) is stable; interleaving word markers into other formats like `side-by-side` is **planned**. |

```bash
nodus diff --word
nodus diff -f unified --word
```

---

### I. Move Detection (`--detect-moves`)

Heuristic detection of moved lines across files.

| Status                                                                                                                                                                                                                                         |
| ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Planned** — the `--detect-moves` flag exists on the CLI and is accepted, and `RenderConfig.detect_moves` is plumbed through, but no move-detection logic exists in the core engine yet. Setting this flag currently has no effect on output. |

```bash
nodus diff --detect-moves   # accepted, but no effect yet
```

---

### J. Color Control

| Flag             | Description                        | Status                   |
| ---------------- | ---------------------------------- | ------------------------ |
| `--no-color`     | Disable colors                     | **Parsed, not rendered** |
| `--color always` | Force color output                 | **Parsed, not rendered** |
| `--color never`  | Disable colors                     | **Parsed, not rendered** |
| `--color auto`   | Color if stdout is a TTY (default) | **Parsed, not rendered** |

The CLI fully resolves the requested color mode against TTY detection (see `cmds/diff.zig`'s `resolveColor`), but no renderer currently emits ANSI escape codes — `core/diff.zig`'s output is always plain text regardless of what `--color` resolves to. This is intentionally separated: color is a CLI/presentation concern and the core renderers don't carry a color dependency at all.

```bash
nodus diff --no-color       # accepted, output is plain text either way
nodus diff --color always   # accepted, output is plain text either way
```

---

### K. Profiles (`--profile`)

Pre-configured combinations of flags for common workflows.

| Profile  | Equivalent Flags                                   | Status     |
| -------- | -------------------------------------------------- | ---------- |
| `review` | `--format side-by-side --level line --group files` | **Stable** |
| `ci`     | `--format summary --level file`                    | **Stable** |
| `debug`  | `--format ops --context full`                      | **Stable** |

```bash
nodus diff --profile review
nodus diff --profile ci
```

---

### L. Path Filtering

Provide paths as positional arguments to limit the diff scope.

| Status                                           |
| ------------------------------------------------ |
| **Stable** — prefix matching against file paths. |

```bash
nodus diff src/
nodus diff src/auth.zig src/parser.zig
```

---

## Practical Examples

### 1. Clean review mode (recommended default)

```bash
nodus diff --format side-by-side --level line --group files
# or simply
nodus diff --profile review
```

### 2. Minimal summary for CI

```bash
nodus diff --format summary --level file
# or
nodus diff --profile ci
```

### 3. Deep inspection mode

```bash
nodus diff --format unified --level word --context full
```

### 4. Structural debugging

```bash
nodus diff --format ops --group dirs
```

### 5. Git-like compatibility mode

```bash
nodus diff --format unified
```

### 6. Review only modified files in a directory

```bash
nodus diff --only-modified --format side-by-side src/
```

### 7. Try a different diff algorithm on a noisy file

```bash
nodus diff --algo patience src/parser.zig
```

### 8. Check what files are dirty before a commit

```bash
nodus diff --level file
```

### 9. Full word-level diff

```bash
nodus diff --level word
```

---

## Architecture

The diff engine (`core/diff.zig`) and the CLI (`cmds/diff.zig`) are deliberately separated. Core has no notion of flags, argv, or terminals; `cmds/diff.zig` is the only place that knows how to turn a string like `"side-by-side"` into `Format.side_by_side`. The parsing functions (`parseFormat`, `parseLevel`, `parseAlgorithm`, etc.), `ColorMode`/`resolveColor`, and `Profile`/`applyProfile` all live as private helpers directly in `cmds/diff.zig`. `cli/command.zig` is a separate, shared file — it provides `Invocation`/`FlagMap`/`Command`, which every command (not just `diff`) uses for flag parsing and help text.

```
cmds/diff.zig: run(inv: *Invocation)
    │
    ├── private parseFormat / parseLevel / parseContext /
    │       parseGroupBy / parseAlgorithm / parseColorMode
    │       → builds core/diff.zig: RenderConfig
    │
    ├── private applyProfile()    (mutates RenderConfig)
    ├── private resolveColor()    (CLI-only; not consumed by core)
    │
    ▼
    walk index entries, read blobs from object store, read working-tree files
    │
    ▼
    core/diff.zig: diffFileWith(alloc, path, old_src, new_src, algorithm)
            │
            ├── splitLines()
            ├── runLineDiff() → dispatches to myersDiff / patienceDiff / histogramDiff
            │       (patience and histogram both fall back to myersDiff on
            │        sub-ranges with no usable anchor)
            └── diffWords() → word deltas (always via myersDiff)
            │
            ▼
    core/diff.zig: renderFileDiff(writer, fd, config)
            │
            ├── Level.file   → one-line summary
            ├── Level.word   → renderWordHighlight
            └── Format dispatch → unified / side_by_side / blocks / ops / summary
            │
            ▼
    (if --group dirs) core/diff.zig: groupByDirectory()
```

### Key Design Decisions

- **Core has no CLI dependency.** `RenderConfig`, `Format`, `Level`, `Context`, `GroupBy`, `ChangeFilter`, and `Algorithm` live in `core/diff.zig` because the renderers and diff functions actually consume them. `ColorMode`, `Profile`/`applyProfile`, and all the `parse*` string-to-enum functions live as private helpers in `cmds/diff.zig` because only that one command needs them — there's no second caller to justify a shared module. If a future command needs the same flag vocabulary, that's the point to extract a shared file, not before.
- **`diffCommit` does not touch the object store.** It only needs an allocator; it diffs two `FileSnapshot` slices in memory. Blob serialization (`serializeLineDiffs` / `serializeWordDiffs`) exists in `core/diff.zig` but is currently unused — `diffCommit` returns zeroed hashes rather than calling them. Wiring these into commit/storage is tracked in the Roadmap.
- **Two-pass engine:** Every file gets both line-level and word-level diffs, regardless of render mode. This lets you switch views without re-computing.
- **Hunk iterator:** Shared across all renderers. Eliminates duplicated hunk-scanning logic between `unified`, `blocks`, and `ops` formats.
- **Pluggable algorithm, shared backtracking:** `patienceDiff` and `histogramDiff` both recurse down to ranges and fall back to `myersDiff` on sub-ranges where they find no useful anchor, so all three algorithms share the same underlying edit-script reconstruction code.

---

## Error Reference

| Error                 | Meaning                                 |
| --------------------- | --------------------------------------- |
| `InvalidFormat`       | Unknown `--format` value                |
| `InvalidLevel`        | Unknown `--level` value                 |
| `InvalidContext`      | Unknown `--context` value               |
| `InvalidGroup`        | Unknown `--group` value                 |
| `InvalidAlgorithm`    | Unknown `--algo` value                  |
| `InvalidProfile`      | Unknown `--profile` value               |
| `InvalidColorMode`    | Unknown `--color` value                 |
| `InvalidChangeFilter` | Unknown value in `--show`               |
| `MissingValue`        | Flag provided without required argument |
| `UnknownFlag`         | Unrecognized flag                       |
| `NotImplemented`      | `--staged` was passed (see section A)   |

---

## Roadmap

| Feature                                          | Status      | Notes                                                                                      |
| ------------------------------------------------ | ----------- | ------------------------------------------------------------------------------------------ |
| Myers line diff                                  | **Stable**  | O(ND) shortest edit script                                                                 |
| Patience line diff                               | **Stable**  | Unique-anchor based, falls back to Myers                                                   |
| Histogram line diff                              | **Stable**  | Frequency-based anchors, falls back to Myers; current default                              |
| Myers word diff                                  | **Stable**  | Always used for word-level diffing regardless of `--algo`                                  |
| Unified format                                   | **Stable**  | Hunk-based patch view                                                                      |
| Side-by-side format                              | **Stable**  | Two-column padded view                                                                     |
| Blocks format                                    | **Stable**  | BEFORE/AFTER sections                                                                      |
| Ops format                                       | **Stable**  | FROM/TO line operations                                                                    |
| Summary format                                   | **Stable**  | One-line per file                                                                          |
| File/hunk/line/word levels                       | **Stable**  | Granularity control                                                                        |
| Context control (minimal/normal/full/exact)      | **Stable**  |                                                                                            |
| Change type filters                              | **Stable**  | `--only-*`, `--show`                                                                       |
| Directory grouping                               | **Stable**  | `--group dirs`                                                                             |
| Profiles                                         | **Stable**  | `review`, `ci`, `debug`                                                                    |
| Path filtering                                   | **Stable**  | Positional prefix matching                                                                 |
| Core/CLI separation                              | **Stable**  | `core/diff.zig` has no flag/terminal/argv knowledge; CLI parsing lives in `cmds/diff.zig`  |
| `--staged` / `--working`                         | **Planned** | `--working` is the only working mode today; `--staged` currently returns an explicit error |
| Ref comparison (`<ref>` / `<ref-a> <ref-b>`)     | **Planned** | Needs a ref resolution layer                                                               |
| Inline word markers in side-by-side              | **Planned** | Word delta data exists; renderer integration pending                                       |
| Move detection (`--detect-moves`)                | **Planned** | Flag and config field exist; no detection logic implemented                                |
| Semantic move detection (hash-based, cross-file) | **Planned** | Depends on move detection landing first                                                    |
| ANSI color sequences in renderers                | **Planned** | CLI-side color resolution exists (`resolveColor`); no renderer emits escape codes yet      |
| Commit-diff blob storage wiring                  | **Planned** | `serializeLineDiffs`/`serializeWordDiffs` exist but `diffCommit` doesn't call them yet     |
| Binary file diff                                 | **Planned** | Not yet implemented                                                                        |
| Rename detection                                 | **Planned** |                                                                                            |
| Diff stat (histogram-style `--stat` output)      | **Planned** | Not to be confused with the `histogram` diff _algorithm_, which is already implemented     |
