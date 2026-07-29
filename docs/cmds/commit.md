# `merk commit`

Record staged changes as a new commit.

---

## Table of contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Basic usage](#basic-usage)
- [How it works](#how-it-works)
  - [1. Validation](#1-validation)
  - [2. Identity resolution](#2-identity-resolution)
  - [3. Trailer extraction](#3-trailer-extraction)
  - [4. Tree and object writing](#4-tree-and-object-writing)
  - [5. Ref update](#5-ref-update)
  - [6. Summary output](#6-summary-output)
- [Message](#message)
  - [Title](#title)
  - [Body](#body)
  - [Trailers](#trailers)
  - [Trailer ordering](#trailer-ordering)
  - [Disabling body trailer parsing](#disabling-body-trailer-parsing)
- [Classification](#classification)
  - [Intent](#intent)
  - [Labels](#labels)
- [Identity](#identity)
  - [Author](#author)
  - [Committer](#committer)
  - [Date formats](#date-formats)
  - [Environment variables](#environment-variables)
- [Flag reference](#flag-reference)
- [Examples](#examples)
- [Error reference](#error-reference)

---

## Overview

`merk commit` snapshots the current index into a content-addressed commit
object and advances the current branch ref to point at it. Each commit carries:

- a **title** and optional **body** (the human-readable message)
- structured **trailers** (key/value metadata at the end of the message)
- an **intent** (semantic classification of the change)
- zero or more **labels** (free-form grouping tags)
- an **author** identity with timestamp
- a **committer** identity with timestamp (defaults to the author)
- a **snapshot** — the tree hash of the staged files plus any parent commit hashes

---

## Prerequisites

The index must be non-empty. Stage files first:

```
merk add <path>
```

Running `merk commit` against an empty index returns an error immediately.

---

## Basic usage

```
merk commit -m "fix: correct off-by-one in range parser"
```

The `-m` / `--message` flag is the only required input. Everything else has
a sensible default.

---

## How it works

### 1. Validation

The title is checked for emptiness and for illegal characters (`\n`, `\r`,
`\x00`). If `--intent` is supplied its value is looked up against the `Intent`
enum; an unrecognised string is a hard error. Trailer keys from both the body
and `--trailer` flags are validated against the git trailer character rules
(printable ASCII, no whitespace, no colon) before the commit object is written.

### 2. Identity resolution

Author name and email are resolved in priority order (flag → env var →
fallback). If none of the committer-specific flags are present the committer
field is left as `null` inside `CommitIdentityInfo`; the core serialiser then
writes a copy of the author bytes for the committer slot, keeping the wire
format symmetric without any extra work from the cmd layer.

If any committer flag is supplied — even just `--committer-email` — a full
`TimestampedIdentityInfo` is built for the committer, inheriting any
unspecified fields from the author.

### 3. Trailer extraction

Trailers are collected in two passes, in this order:

1. **Body trailers** — lines at the tail of `--body` that match `key: value`
   (see [Trailers](#trailers) below). These are stripped from the stored body
   text so they are not double-recorded.
2. **Explicit `--trailer` flags** — appended after the body trailers.

This ordering means explicit flags can extend or shadow what was embedded in
the body without any special-casing.

### 4. Tree and object writing

`commit_mod.buildAndWrite` builds a tree object from the current index, writes
it to the object store, then writes the commit object with all resolved fields
and returns the new commit hash.

### 5. Ref update

The current branch is resolved via `refs.headBranch`. If HEAD is detached or
no branch can be found, `main` is used as the branch name. The branch ref is
updated atomically to the new commit hash.

### 6. Summary output

A one-line summary is printed to stderr:

```
[a1b2c3d (root-commit)] fix: correct off-by-one in range parser
  author    : Alice <alice@example.com>
  intent    : fix
  files     : 3
```

When a distinct committer is set, a `committer` line appears after `author`.
Labels and trailers are printed if present.

---

## Message

### Title

```
merk commit -m "feat: add histogram diff algorithm"
```

The title is required. It must be non-empty after trimming whitespace and must
not contain newlines or null bytes. Maximum length is 65 535 bytes (u16).

### Body

```
merk commit -m "refactor: split diff engine" \
  --body "Myers, Patience, and Histogram are now separate modules.

The shared LCS core is extracted into diff/lcs.zig."
```

The body is optional extended prose. It is stored separately from the title and
has a maximum size of ~4 GB (u32). Leading and trailing whitespace is trimmed
before storage.

### Trailers

Trailers are structured `key: value` pairs appended after the body. They are
stored as a typed list inside the commit object (not as free text in the body),
so they are queryable without parsing.

**Two ways to supply trailers:**

**1. Embedded in `--body`** (extracted automatically)

```
merk commit -m "fix: memory leak in store" \
  --body "Freed the slab on error paths.

closes: #88
reviewed-by: bob@example.com"
```

The `closes: #88` and `reviewed-by: …` lines are detected, stripped from the
stored body, and recorded as structured trailers.

**2. Explicit `--trailer` flag**

```
merk commit -m "fix: memory leak in store" \
  --trailer "closes=#88,reviewed-by=bob@example.com"
```

`--trailer` accepts one or more `key=value` pairs separated by commas. Note
the separator between key and value is `=` here (not `:`) to avoid ambiguity
with the comma delimiter.

**Key rules** (enforced by `TrailerInfo.validate`):

- Printable ASCII only (`0x21`–`0x7E`)
- No whitespace
- No colon (`:` is the display separator)
- Maximum key length: 255 bytes
- Maximum value length: 65 535 bytes
- Maximum trailers per commit: 255

**Duplicate keys are allowed.** Order is preserved.

Common trailer keys by convention:

| Key              | Meaning                                   |
| ---------------- | ----------------------------------------- |
| `closes`         | Issue or ticket number this commit closes |
| `fixes`          | Bug report reference                      |
| `reviewed-by`    | Reviewer name or email                    |
| `co-authored-by` | Additional author                         |
| `breaks`         | API or config surface this change breaks  |
| `cherry-picked`  | Source commit hash for cherry-picks       |

### Trailer ordering

Trailers are always stored in this order:

1. Body-embedded trailers (in the order they appear in the body, top to bottom)
2. Explicit `--trailer` flags (in the order they appear, left to right)

### Disabling body trailer parsing

If the body contains `key: value` lines that are not trailers (e.g. YAML
front-matter, prose that happens to use colons), pass `--no-body-trailers` to
treat the entire body as plain text:

```
merk commit -m "docs: add config reference" \
  --body "timeout: 30s
retries: 3
host: localhost" \
  --no-body-trailers
```

---

## Classification

### Intent

```
merk commit -m "fix: null check on empty ref" --intent fix
```

Intent is a machine-readable semantic tag for the type of change. It maps to
the `Intent` enum in `metadata.zig`. Valid values:

| Value         | Meaning                                     |
| ------------- | ------------------------------------------- |
| `feature`     | New user-visible functionality (default)    |
| `fix`         | Bug fix                                     |
| `refactor`    | Internal restructuring, no behaviour change |
| `docs`        | Documentation only                          |
| `test`        | Test additions or fixes                     |
| `performance` | Speed or memory improvement                 |
| `security`    | Security fix or hardening                   |
| `build`       | Build system, dependencies, toolchain       |
| `ci`          | CI/CD pipeline changes                      |
| `release`     | Version bump, changelog, release automation |
| `chore`       | Maintenance with no production impact       |

Default is `feature`. The short flag `-i` is also accepted.

### Labels

Labels are free-form strings for grouping, filtering, and release automation.
They have no enforced schema — use whatever conventions suit the project.

**Via `--label` flag** (comma-separated):

```
merk commit -m "feat: dark mode" --label "ui,design-system"
```

**Via positional arguments** (appended after any `--label` values):

```
merk commit -m "feat: dark mode" -- ui design-system
```

Both can be combined. Labels from `--label` come first, then positional args,
in the order they are supplied.

---

## Identity

### Author

The author is the person who wrote the change.

```
merk commit -m "fix: typo" \
  --author "Alice" \
  --author-email "alice@example.com" \
  --author-date "2025-03-14"
```

Resolution order for each field:

| Field     | Flag                       | Env var             | Fallback        |
| --------- | -------------------------- | ------------------- | --------------- |
| Name      | `--author`                 | `merk_AUTHOR_NAME`  | `$USER`         |
| Email     | `--author-email`           | `merk_AUTHOR_EMAIL` | `unknown@local` |
| Timestamp | `--author-date` / `--date` | —                   | current time    |

### Committer

The committer is the person who applied the change to the repository. In
normal local development the committer is the same as the author, so merk
omits the committer field entirely and the core serialiser mirrors the author
bytes on the wire.

Supply any committer flag to create a distinct committer record:

```
merk commit -m "chore: apply patch from upstream" \
  --author "Alan Turing" \
  --author-email "alan@lab.net" \
  --committer "merk Bot" \
  --committer-email "bot@merk.dev" \
  --committer-date "2025-06-01"
```

Partial specification is allowed. Unspecified committer fields inherit from the
author:

```
# Only the committer email differs; name and date mirror the author.
merk commit -m "ci: apply formatter" --committer-email "fmt-bot@ci.internal"
```

Resolution order for committer fields:

| Field     | Flag                               | Fallback         |
| --------- | ---------------------------------- | ---------------- |
| Name      | `--committer` / `--committer-name` | author name      |
| Email     | `--committer-email`                | author email     |
| Timestamp | `--committer-date`                 | current time (0) |

### Date formats

Both `--author-date` / `--date` and `--committer-date` accept:

**Unix milliseconds** — an integer timestamp:

```
--author-date 1700000000000
```

**ISO-8601 date** — interpreted as UTC midnight:

```
--author-date 2025-03-14
```

Passing a string that matches neither format is a hard error.

### Environment variables

| Variable            | Used for                |
| ------------------- | ----------------------- |
| `merk_AUTHOR_NAME`  | Author name fallback    |
| `merk_AUTHOR_EMAIL` | Author email fallback   |
| `USER`              | Author name last-resort |

---

## Flag reference

```
usage: merk commit -m <msg> [options] [labels...]

options:
  -m, --message <msg>          commit title (required)
      --body <text>            extended description; 'key: value' trailers at
                               the tail are extracted automatically
      --no-body-trailers       treat body as plain text; skip trailer extraction
      --trailer <key=value>    explicit trailer, appended after body trailers
                               (comma-separated for multiple)

  -i, --intent <intent>        feature|fix|refactor|docs|test|performance|
                               security|build|ci|release|chore  (default: feature)
  -l, --label <label[,label]>  comma-separated scope labels; positional args
                               also accepted

      --author <name>          author name  ($merk_AUTHOR_NAME / $USER fallback)
      --author-email <addr>    author email  ($merk_AUTHOR_EMAIL fallback)
      --author-date <date>     author timestamp: Unix-ms or YYYY-MM-DD (default: now)
      --date <date>            alias for --author-date

      --committer <name>       committer name  (default: same as author)
      --committer-name <name>  alias for --committer
      --committer-email <addr> committer email  (default: same as author)
      --committer-date <date>  committer timestamp: Unix-ms or YYYY-MM-DD
                               (default: same as author)

  -h, --help                   show this help
```

---

## Examples

**Minimal commit:**

```
merk commit -m "fix: handle empty index gracefully"
```

**With body and intent:**

```
merk commit -m "refactor: extract LCS core" \
  --body "Myers, Patience, and Histogram all share the same LCS primitive now." \
  --intent refactor
```

**With labels:**

```
merk commit -m "feat: add dark mode toggle" --intent feature --label "ui,a11y"
```

**Body trailers extracted automatically:**

```
merk commit -m "fix: double-free in test teardown" \
  --body "The slab was freed twice on error paths in commit_test.zig.

closes: #102
reviewed-by: carol@example.com"
```

Stored body: `"The slab was freed twice on error paths in commit_test.zig."`
Stored trailers: `closes=#102`, `reviewed-by=carol@example.com`

**Explicit trailers only:**

```
merk commit -m "chore: bump zig toolchain" \
  --trailer "breaks=build.zig.zon,reviewed-by=alice@example.com"
```

**Mixed body and explicit trailers:**

```
merk commit -m "feat: patience diff" \
  --body "Implements the Patience algorithm alongside Myers.

closes: #77" \
  --trailer "reviewed-by=bob@example.com"
```

Trailer order in the stored object: `closes=#77`, then `reviewed-by=bob@example.com`.

**Backdated commit:**

```
merk commit -m "docs: initial readme" --date 2024-01-01
```

**Cherry-pick with distinct committer:**

```
merk commit -m "fix: backport null check from main" \
  --author "Alice" \
  --author-email "alice@example.com" \
  --author-date 2025-01-15 \
  --committer "merk Bot" \
  --committer-email "bot@merk.dev" \
  --trailer "cherry-picked=a1b2c3d4"
```

**Suppress body trailer extraction:**

```
merk commit -m "docs: config schema reference" \
  --body "timeout: 30s
host: localhost" \
  --no-body-trailers
```

---

## Error reference

| Error             | Cause                                                                  |
| ----------------- | ---------------------------------------------------------------------- |
| `MissingMessage`  | `-m` / `--message` was not supplied                                    |
| `EmptyMessage`    | Title is blank after whitespace trimming                               |
| `UnknownIntent`   | `--intent` value does not match any `Intent` enum tag                  |
| `BadDate`         | Date string is neither a valid Unix-ms integer nor a `YYYY-MM-DD` date |
| `BadTrailer`      | `--trailer` token lacks `=`, or the key fails character validation     |
| `NothingToCommit` | The index is empty — nothing has been staged                           |
