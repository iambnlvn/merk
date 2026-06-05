# nodus diff

Compare repository states and visualize changes between the working tree, index, commits, branches, and tags.

## Synopsis

```bash
nodus diff [options] [ref-a] [ref-b] [paths...]
```

## Description

`nodus diff` compares repository content and displays the differences using one of several rendering formats.

The command can compare:

- Working tree against the index
- Index against `HEAD`
- A reference against the working tree
- Two commits, branches, or tags
- Specific files or directories

---

# Command Reference

## A. What to Compare

| Flag / Argument   | Description                                             |
| ----------------- | ------------------------------------------------------- |
| _(no args)_       | Compare working tree against the index                  |
| `--working`       | Explicitly compare working tree against index (default) |
| `--staged`        | Compare the index against `HEAD` (staged changes)       |
| `<ref>`           | Compare `<ref>` against the working tree                |
| `<ref-a> <ref-b>` | Compare two refs/commits                                |

### Examples

```bash
nodus diff HEAD~1
nodus diff --staged
nodus diff v1.0.0 main
```

---

## B. Output Format (`--format`, `-f`)

Controls the visual layout of the diff.

| Value          | Description                                        |
| -------------- | -------------------------------------------------- |
| `unified`      | Git-like patch with `+` and `-` prefixes (default) |
| `side-by-side` | Two-column before/after view                       |
| `blocks`       | Change blocks grouped as BEFORE/AFTER sections     |
| `ops`          | Explicit edit operations (FROM line / TO line)     |
| `summary`      | One-line per file                                  |

### Examples

```bash
nodus diff -f side-by-side
nodus diff -f blocks
nodus diff --format ops
```

---

## C. Detail Level (`--level`, `-l`)

Controls how granular the output is.

| Value  | Description                               |
| ------ | ----------------------------------------- |
| `file` | Only list files changed (status + counts) |
| `hunk` | Grouped hunks (omits unchanged lines)     |
| `line` | Normal line-by-line diff (default)        |
| `word` | Inline word-level diff                    |

### Examples

```bash
nodus diff -l file
nodus diff --level word
nodus diff -f side-by-side -l word
```

---

## D. Context Control (`--context`, `-c`)

Determines how many unchanged lines are displayed around each change.

| Value      | Description                    |
| ---------- | ------------------------------ |
| `<number>` | Exact number of context lines  |
| `minimal`  | Only changed lines (0 context) |
| `normal`   | 3 lines of context (default)   |
| `full`     | Entire file                    |

### Examples

```bash
nodus diff -c 10
nodus diff --context minimal
nodus diff --context full
```

---

## E. Structural Grouping (`--group`, `-g`)

Group diff output by file or directory.

| Value   | Description                       |
| ------- | --------------------------------- |
| `none`  | Flat list (default)               |
| `files` | Group by file (adds file headers) |
| `dirs`  | Group by parent directory         |

### Examples

```bash
nodus diff --group dirs
```

Output:

```text
src/
  auth.zig
  parser.zig

tests/
  auth_test.zig
```

---

## F. Change Type Filters

Show only specific categories of file changes.

| Flag              | Description                                                   |
| ----------------- | ------------------------------------------------------------- |
| `--only-added`    | New files only                                                |
| `--only-deleted`  | Removed files only                                            |
| `--only-modified` | Modified files only                                           |
| `--show <types>`  | Comma-separated combination of `added`, `deleted`, `modified` |

### Examples

```bash
nodus diff --only-modified
nodus diff --show added,deleted
```

---

## G. Inline Word Diff (`--word`)

Highlights changed words within modified lines.

Word-level markers:

```text
[-old-]
[+new+]
```

### Examples

```bash
nodus diff --word
nodus diff -f unified --word
```

Example output:

```text
const port = [-3000-][+8080+];
```

---

## H. Move Detection (`--detect-moves`)

Enables heuristic detection of moved content across files.

Moved content is displayed using `MOVED` annotations.

### Example

```bash
nodus diff --detect-moves
```

Example output:

```text
MOVED

Function:
  parseConfig()

From:
  src/config.zig

To:
  src/core/config.zig
```

---

## I. Color Control

Configure ANSI color output.

| Flag             | Description                                  |
| ---------------- | -------------------------------------------- |
| `--color always` | Force ANSI colors                            |
| `--color never`  | Disable colors                               |
| `--color auto`   | Enable colors when stdout is a TTY (default) |
| `--no-color`     | Alias for `--color never`                    |

### Examples

```bash
nodus diff --no-color
nodus diff --color always
```

---

## J. Profiles (`--profile`)

Profiles provide predefined combinations of common options.

| Profile  | Equivalent Flags                                   |
| -------- | -------------------------------------------------- |
| `review` | `--format side-by-side --level line --group files` |
| `ci`     | `--format summary --level file`                    |
| `debug`  | `--format ops --context full`                      |

### Examples

```bash
nodus diff --profile review
nodus diff --profile ci
```

---

## K. Path Filtering

Limit diff output to specific files or directories.

### Examples

```bash
nodus diff src/
nodus diff src/auth.zig src/parser.zig
```

---

# Practical Examples

## 1. Clean Review Mode

Recommended for code reviews.

```bash
nodus diff --format side-by-side --level line --group files
```

Or:

```bash
nodus diff --profile review
```

---

## 2. Minimal Summary for CI

```bash
nodus diff --format summary --level file
```

Or:

```bash
nodus diff --profile ci
```

---

## 3. Deep Inspection Mode

```bash
nodus diff --format unified --level word --context full
```

---

## 4. Structural Debugging

```bash
nodus diff --format ops --group dirs
```

---

## 5. Git-Compatible View

```bash
nodus diff --format unified
```

---

## 6. Review Modified Files in a Directory

```bash
nodus diff --only-modified --format side-by-side src/
```

---

## 7. Review Staged Changes with Minimal Context

```bash
nodus diff --staged --context minimal
```

---

## 8. Check Which Files Are Dirty

```bash
nodus diff --level file
```

---

## 9. Full Word-Level Diff Without Colors

```bash
nodus diff --level word --no-color
```

---

# Exit Codes

| Code | Meaning                              |
| ---- | ------------------------------------ |
| `0`  | No differences found                 |
| `1`  | Differences detected                 |
| `2`  | Invalid arguments or execution error |

---

# Error Reference

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

# See Also

- `nodus status`
- `nodus add`
- `nodus commit create`
- `nodus branch`
- `nodus merge`
