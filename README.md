# merk

merk is a small, content-addressed distributed version control system written in Zig.
It focuses on a clean core/CLI separation, structured commit metadata, and an extensible diff engine.

## Features

- `merk init` — initialize a repository
- `merk add` — stage files in the index
- `merk commit` — create structured commits with trailers, intent, labels, and author/committer metadata
- `merk diff` — compare working tree, index, or commit histories with configurable diff rendering
- `merk show` — inspect commit contents and metadata
- `merk write-tree` — write the current index as a tree object
- Content-addressed object store using BLAKE3

## Quick start

```bash
zig build install
./zig-out/bin/merk init
./zig-out/bin/merk add src/**/*.zig
./zig-out/bin/merk commit -m "feat: add initial diff command"
./zig-out/bin/merk diff
```

If you want to run `merk` without using the install prefix directly, add the install bin directory to your `PATH`:

```bash
export PATH="$PWD/zig-out/bin:$PATH"
```

## Commands

### `merk init`

Create a new repository in the current directory.

### `merk add <path>`

Stage files into the index.

### `merk commit -m <message>`

Record staged changes as a new commit.

### `merk diff [options] [<path>...]`

Show changes between the working tree and index, or between commits using `--rev`.

### `merk show`

Inspect commit data and differences for a commit or range.

### `merk write-tree`

Write the current staging index as a tree object.

## Diff command overview

`merk diff` supports:

- `--format` — `unified`, `side-by-side`, `blocks`, `ops`, `summary`
- `--level` — `file`, `hunk`, `line`, `word`
- `--algo` — `myers`, `patience`, `histogram`
- `--context` — `minimal`, `normal`, `full`, or a numeric value
- `--group` — `none`, `files`, `dirs`
- `--show` — `added`, `deleted`, `modified`
- `--rev` — compare commits by full or short hash prefixes

`merk diff --rev <hash>` now resolves short commit prefixes against the local object store.

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

- `src/` — command and core implementation
- `docs/` — command documentation
- `build.zig` — build configuration
- `zig-out/` — build outputs

## Notes

This project is under active development. Some CLI flags and advanced diff modes are accepted in the parser but may still be planned in the core implementation.
