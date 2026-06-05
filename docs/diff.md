# `nodus diff`

> **Status:** Core engine stable. CLI surface in active development. Some features listed below are **planned** or **work-in-progress (WIP)**.

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
- **O(ND) Myers diff:** Shortest edit script for both lines and words.

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
```

---

## Command Reference

### A. What to Compare _(Partially WIP)_

| Invocation        | Description                                             | Status                                          |
| ----------------- | ------------------------------------------------------- | ----------------------------------------------- |
| _(no args)_       | Compare working tree against the index                  | **Stable**                                      |
| `--working`       | Explicitly compare working tree against index (default) | **Stable**                                      |
| `--staged`        | Compare the index against HEAD (staged changes)         | **WIP** — flag accepted, plumbing not yet wired |
| `<ref>`           | Compare `<ref>` against the working tree                | **Planned**                                     |
| `<ref-a> <ref-b>` | Compare two refs/commits                                | **Planned**                                     |

```bash
nodus diff                    # working vs index
nodus diff --staged           # index vs HEAD (WIP)
nodus diff HEAD~1             # planned: ref vs working
nodus diff v1.0.0 main        # planned: two refs
```

---

### B. Output Format (`--format`, `-f`)

Controls the visual layout of the diff.

| Value          | Description                                                  | Status     |
| -------------- | ------------------------------------------------------------ | ---------- |
| `unified`      | Git-like patch with `+` / `-` prefixes and `@@` hunk headers | **Stable** |
| `side-by-side` | Two-column before/after view                                 | **Stable** |
| `blocks`       | Change blocks grouped as BEFORE/AFTER sections               | **Stable** |
| `ops`          | Explicit edit operations (FROM line / TO line)               | **Stable** |
| `summary`      | One-line per file                                            | **Stable** |

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

### D. Context Control (`--context`, `-c`)

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

### E. Structural Grouping (`--group`, `-g`)

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

### F. Change Type Filters

Show only specific kinds of changes.

| Flag              | Description                                           | Status     |
| ----------------- | ----------------------------------------------------- | ---------- |
| `--only-added`    | New files only                                        | **Stable** |
| `--only-deleted`  | Removed files only                                    | **Stable** |
| `--only-modified` | Modified files only                                   | **Stable** |
| `--show <types>`  | Comma-separated combination: `added,deleted,modified` | **Stable** |

```bash
nodus diff --only-modified
nodus diff --show added,deleted
```

---

### G. Inline Word Diff (`--word`)

When used with `--level line`, highlights changed words inside lines using `[-old-]` and `[+new+]` markers.

| Status                                                                                                                                                                  |
| ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Stable** — word-level data is computed for every diff. Rendering integration is **WIP** for some formats (e.g., `side-by-side` does not yet interleave word markers). |

```bash
nodus diff --word
nodus diff -f unified --word
```

---

### H. Move Detection (`--detect-moves`)

Heuristic detection of moved lines across files. Shows `MOVED` annotations for exact-content matches between deleted and inserted lines.

| Status                                                                                                                                                                         |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **WIP** — `detectMoves()` computes the mapping and `renderMoves()` prints it. Integration into the hunk renderer (suppressing moved lines from `-`/`+` output) is **planned**. |

```bash
nodus diff --detect-moves
```

Output:

```
MOVED
  fn parse() → line 42
  const x = 10; → line 7

--- a/src/main.zig
+++ b/src/main.zig
...
```

---

### I. Color Control

| Flag             | Description                        | Status     |
| ---------------- | ---------------------------------- | ---------- |
| `--no-color`     | Disable colors                     | **Stable** |
| `--color always` | Force ANSI colors                  | **Stable** |
| `--color never`  | Disable colors                     | **Stable** |
| `--color auto`   | Color if stdout is a TTY (default) | **Stable** |

```bash
nodus diff --no-color
nodus diff --color always
```

---

### J. Profiles (`--profile`)

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

### K. Path Filtering

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

### 7. Staged changes with minimal context _(WIP)_

```bash
nodus diff --staged --context minimal
```

### 8. Check what files are dirty before a commit

```bash
nodus diff --level file
```

### 9. Full word-level diff with no color

```bash
nodus diff --level word --no-color
```

---

## Architecture

```
DiffArgs.parse(argv)
    │
    ├── resolves --profile (mutates config)
    ├── resolves --format, --level, --context, --group
    ├── resolves --only-* / --show filters
    └── stores refs[2] + paths + staged/working flags
            │
            ▼
    resolveRefs() → old_files, new_files
            │
            ▼
    diffCommit(alloc, store, old_files, new_files)
            │
            ├── diffFile() per changed file
            │       ├── splitLines()
            │       ├── myersDiff() → line deltas
            │       ├── diffWords() → word deltas
            │       └── (optional) detectMoves() → moves
            │
            ├── serializeLineDiffs() → store blob
            ├── serializeWordDiffs() → store blob
            └── return CommitDiff
            │
            ▼
    renderCommit(writer, cd, config, alloc)
            │
            ├── filterFiles()    ← ChangeFilter + path prefixes
            ├── groupByDirectory() ← if group_by == .dirs
            └── renderFileDiff() per file
                    │
                    ├── Level.file   → one-line summary
                    ├── Level.word   → wordHighlight renderer
                    └── Format dispatch → unified / side_by_side / blocks / ops / summary
```

### Key Design Decisions

- **Pure diff core:** `diffFile` and `diffCommit` only need an allocator. The object store is only used for blob serialization at the end of `diffCommit`.
- **Two-pass engine:** Every file gets both line-level and word-level diffs, regardless of render mode. This lets you switch views without re-computing.
- **Hunk iterator:** Shared across all renderers. Eliminates ~80 lines of duplicated hunk-scanning logic.

---

## Error Reference

| Error            | Meaning                                 |
| ---------------- | --------------------------------------- |
| `InvalidFormat`  | Unknown `--format` value                |
| `InvalidLevel`   | Unknown `--level` value                 |
| `InvalidContext` | Unknown `--context` value               |
| `InvalidGroup`   | Unknown `--group` value                 |
| `InvalidProfile` | Unknown `--profile` value               |
| `MissingValue`   | Flag provided without required argument |
| `UnknownOption`  | Unrecognized flag                       |

---

## Roadmap

| Feature                                          | Status      | Notes                                                                                              |
| ------------------------------------------------ | ----------- | -------------------------------------------------------------------------------------------------- |
| Myers line diff                                  | **Stable**  | O(ND) shortest edit script                                                                         |
| Myers word diff                                  | **Stable**  | Reused for inline precision                                                                        |
| Unified format                                   | **Stable**  | Git-compatible `@@` hunk headers                                                                   |
| Side-by-side format                              | **Stable**  | Two-column padded view                                                                             |
| Blocks format                                    | **Stable**  | BEFORE/AFTER sections                                                                              |
| Ops format                                       | **Stable**  | FROM/TO line operations                                                                            |
| Summary format                                   | **Stable**  | One-line per file                                                                                  |
| File/hunk/line/word levels                       | **Stable**  | Granularity control                                                                                |
| Context control (minimal/normal/full/exact)      | **Stable**  |                                                                                                    |
| Change type filters                              | **Stable**  | `--only-*`, `--show`                                                                               |
| Directory grouping                               | **Stable**  | `--group dirs`                                                                                     |
| Color control                                    | **Stable**  | `--color`, `--no-color`                                                                            |
| Profiles                                         | **Stable**  | `review`, `ci`, `debug`                                                                            |
| Path filtering                                   | **Stable**  | Positional prefix matching                                                                         |
| `--staged` / `--working`                         | **WIP**     | Flags parsed; `--staged` needs HEAD plumbing                                                       |
| Ref comparison (`<ref>` / `<ref-a> <ref-b>`)     | **Planned** | Needs ref resolution layer                                                                         |
| Inline word markers in side-by-side              | **WIP**     | Word data exists; renderer integration pending                                                     |
| Move detection (`--detect-moves`)                | **WIP**     | `detectMoves()` + `renderMoves()` done; suppressing moved lines from `-`/`+` output is **planned** |
| Semantic move detection (hash-based, cross-file) | **Planned** | Currently exact-string heuristic only                                                              |
| ANSI color sequences in renderers                | **Planned** | `ColorMode` wired; escapes not yet emitted                                                         |
| `--word` with `--level line` in all formats      | **WIP**     | Works in `unified` and `wordHighlight`; `side-by-side` pending                                     |
| Binary file diff                                 | **Planned** | Not yet implemented                                                                                |
| Rename detection                                 | **Planned** |                                                                                                    |
| Diff stat (histogram)                            | **Planned** | `--stat` flag                                                                                      |
