# The Index

`Index` (`src/core/index.zig`) is merk's staging area. It represents the
current tracked state of the working tree, mapping each tracked path to
its associated metadata, including the blob hash, file size, mode, and
modification time. The index is maintained in memory while it is being
modified and can be serialized to disk.

Conceptually, it serves the same role as Git's .git/index, but its
persistence format is fundamentally different. Git stores the index
as a single sorted file, whereas Merk serializes the in-memory index
into a persistent, content-addressed Merkle B-tree. Its immutable pages
are identified by their BLAKE3 hashes, allowing successive index states
to share unchanged pages instead of rewriting the entire structure.

This document describes the index's architecture, including its in-memory
representation, on-disk format, serialization and loading process, tree layout,
structural diffing algorithm, and the abstractions that make the
implementation testable without relying on a physical filesystem.

---

## 1. Why a Merkle B-tree, not a flat file

A flat sorted index (git's approach) is simple, but every save rewrites
the whole file — there's no way to say "this index and that index share
90% of their entries" without a full scan-and-compare.

merk instead serializes `entries` into a B-tree of fixed-size (4 KiB)
pages, where every page is content-addressed by its BLAKE3 hash and pages
are immutable once written. This buys three things:

- **Structural sharing.** Two index states that differ by one file only
  differ in the leaf page containing that file, plus the internal pages
  on the path from that leaf to the root (typically 1–3 pages for trees
  with thousands of entries). Everything else is byte-for-byte identical
  and simply isn't rewritten — `PageStore.put`'s existence check makes
  this literal: a page whose hash already exists on disk is never
  written twice.
- **Fast structural diffing.** Comparing two index states means comparing
  two root hashes. If they're equal, you're done — no disk access at all.
  If they differ, the diff walks down through unequal subtrees only,
  short-circuiting the moment two child hashes match (see §6).
- **A natural fit for commits.** Since a commit really just needs to
  remember an index root hash, storing an entire tree's worth of state
  costs one hash's worth of metadata; the actual pages are shared with
  whatever previous trees already wrote them.

The tradeoff is complexity: instead of a linear read/write, there's a
tree structure, a page format, and a content-defined chunking scheme to
keep that structural sharing meaningful as the tree grows and shrinks.

---

## 2. On-disk layout

Given `Index.init(alloc, fs, index_dir)` with `index_dir = "merk"`, the
on-disk footprint (relative to `fs`'s root) is:

```
merk/
  index/
    index_root              — 32 raw bytes: the BLAKE3 hash of the root page
    pages/
      xx/
        yy/
          <64-char-hex>      — one 4 KiB page, named by its own hash
```

`index_root` is the single piece of _mutable_ state in the whole index —
every save rewrites it (atomically, via `FileSystem.writeFile`) to point
at a new root page. Everything under `pages/` is immutable and
content-addressed, exactly like `merk/objects/` for blobs (see
`object.Store` — `PageStore` is deliberately its structural twin: same
`fs`/`<subdir>_dir` shape, same sharded-by-hash-prefix layout, same
"caller decides whether `fs` is already scoped or needs a subdir prefix"
convention via the `pages_dir`/`objects_dir` field being allowed to be
`""`).

An empty index (zero entries) is represented as `index_root =
hash_mod.zero_hash` — no page is ever written for the empty state, so an
empty repo's `merk/index/` has no `pages/` subdirectory at all until
the first `save()` with at least one entry.

---

## 3. Data model

### 3.1 `Entry` (in-memory)

The unit `Index.entries` holds — one per tracked path:

```zig
pub const Entry = struct {
    path: []const u8,     // owned, repo-relative
    blob_hash: Hash,       // BLAKE3 hash of the file's content, as stored in object.Store
    size: u64,
    mode: u64,             // POSIX file mode bits
    mtime: i128,            // nanoseconds; used for cheap dirty-checking
};
```

`Index` owns every `path` slice it holds (duplicated on insert via
`self.alloc.dupe`) and frees them in `deinit`/`clearEntries`/`remove`/
`upsert`'s replace path.

### 3.2 `path_index`: the O(1) lookup layer

`entries` is a flat `std.ArrayList(Entry)`, kept sorted by path for
deterministic tree construction and diffing. But sorted-array lookups by
path would be O(log n) at best and awkward to keep in sync incrementally,
so `Index` also maintains `path_index: StringHashMapUnmanaged(usize)`
mapping `path -> index into entries`. Every mutation (`upsert`, `remove`)
updates both structures together; `rebuildPathIndex` recomputes the whole
map from scratch after any operation (`load`, `save`) that might have
reordered `entries`.

This split exists because the two structures serve different masters:
`entries` needs to be sorted for `merkle_mod.build`, but `path_index`
needs to answer "is `src/main.zig` tracked, and if so what's its current
state" without caring about ordering at all. The `entries` ordering is a
tree-construction concern; `path_index` is a query concern.

### 3.3 `index_root`: the tree's identity

A single `Hash` (BLAKE3, 32 bytes) that names the root page of whatever
tree was last built from `entries` via `save()`, or loaded from disk via
`load()`. This is the value a commit actually persists — a commit's
"tree" is just this hash, plus a `PageStore` to walk it with.

---

## 4. The page format (leaf and internal pages)

Each page is exactly `PAGE_SIZE` (4 KiB) bytes, one of two kinds:

- **Leaf pages** hold a run of `LeafEntry` records directly (key,
  path, blob hash, size, mode, mtime) — the actual tracked-file data.
- **Internal pages** hold a run of `ChildRef` records (separator key +
  child page hash) — pointers down to either more internal pages or
  leaf pages.

Both begin with a small fixed header (`writePageHeader`: page kind +
entry count), then a packed sequence of fixed- or variable-length
records written via `std.Io.Writer.fixed` directly into the 4 KiB buffer.

### 4.1 Building a tree (`tree.build`)

1. Entries are sorted by `entry_mod.btreeLessThan` (effectively by
   `pathKey(path)`, a folded hash of the path used as the B-tree key).
2. **Leaf pages are packed greedily**: keep appending entries to the
   current page until either (a) the next entry wouldn't fit in the
   remaining 4 KiB, forcing a new page, or (b) a **content-defined
   boundary** is hit.
3. **Content-defined chunking** (`isChunkBoundary(key, LEAF_BOUNDARY_MASK)`,
   mask `0x1F`) cuts a page whenever an entry's key has its low 5 bits
   all zero — independent of _where_ in the page that happens. This is
   the same idea as rolling-hash content-defined chunking used for blob
   deduplication, applied to B-tree pages: it means an insertion or
   deletion in the middle of a leaf page **doesn't cascade** and shift
   every following page's boundary. Without CDC, inserting one entry
   near the start of a 10,000-entry leaf-page run would ripple-shift
   every subsequent page boundary, destroying structural sharing for
   the entire rest of the tree on every single edit. With CDC, only the
   page(s) actually containing the change (plus, at most, its immediate
   neighbor) differ; everything after the next chunk boundary is
   byte-identical to before and reuses its existing page hash.
4. **Internal levels** are built the same way, one level at a time, until
   exactly one page remains — the root. Internal pages use a coarser
   mask (`INTERNAL_BOUNDARY_MASK = 0xF`) folded from the _child page
   hash_ rather than a key, since internal pages don't have their own
   natural key stream.
5. **Determinism**: because chunking is content-defined (a function of
   the data, not insertion order), `build()` is order-independent — the
   same entry set produces the same root hash regardless of what order
   the entries were appended in. (Verified directly: see `tree.zig`'s
   "build is deterministic" test.)
6. Every page, once fully written, is handed to `PageStore.put`, which
   hashes it and writes it only if that hash isn't already on disk.

### 4.2 Reading a tree back (`tree.collect`)

Recursive: given a root hash, fetch and parse the page (`PageStore.get`
→ `node.parsePage`); if it's a leaf, append its entries to the output
list; if it's internal, recurse into every child. `collect` doesn't need
to know anything about chunking — it just walks whatever shape the tree
happens to have.

---

## 5. `PageStore`: content-addressed page storage

```zig
pub const PageStore = struct {
    alloc: std.mem.Allocator,
    fs: io.FileSystem,
    pages_dir: []const u8,   // e.g. "merk/index/pages", or "" if fs is already scoped there
};
```

Three operations:

- **`put(page_bytes)`** — hash the page, check `fs.fileExists` at its
  sharded path, write only if absent. Pages are immutable, so there's
  never a need to compare _content_ on a hash collision at the
  filesystem level — the hash check alone is sufficient (and BLAKE3
  collisions are not a practical concern).
- **`getBytes(hash)`** — read the page back, verify its length is
  exactly `PAGE_SIZE` (`error.CorruptIndexPage` if not — e.g. a
  truncated write), verify its content re-hashes to the requested hash
  (`error.HashMismatch` if not — bit rot / on-disk corruption), and
  return the raw bytes.
- **`get(hash)`** — `getBytes` + `node.parsePage`, i.e. the structured
  view most callers actually want.

All three go through `io.FileSystem` (see §8) rather than a raw
`std.fs.Dir`, which is what makes `PageStore` — and therefore the whole
Index layer — testable with an in-memory filesystem instead of real
tmpdir I/O.

Writes are atomic "for free": `FileSystem.writeFile` (both the real and
in-memory implementations) already does create-parent-dirs +
write-to-temp + atomic-rename internally, so `PageStore.put` doesn't
implement any of that itself — it's just "does this hash exist yet? if
not, write it."

---

## 6. Diffing (`diff.diffRoots`)

`Index.diffAgainst(other_root)` computes the set of path-level changes
between the index's _current_ `index_root` and some other root hash
(typically a previous commit's tree) — without ever materializing either
tree's full entry list.

The algorithm is a recursive tree walk with two key short-circuits:

1. **Identical hash ⇒ identical subtree, stop.** `diffNodes` checks
   `hashEq(old_hash, new_hash)` before touching disk at all. Since pages
   are content-addressed, equal hashes _guarantee_ equal content — no
   need to read either page to know nothing changed underneath. This is
   the main payoff of the whole content-addressed design: a diff between
   two trees that share 99% of their pages does disk I/O proportional to
   the 1% that changed, not the size of either tree.
2. **Prefix/suffix alignment for internal nodes.** `diffInternal` doesn't
   just zip two children-lists index-by-index — it first strips off any
   matching leading and trailing children (by separator + hash), then
   only recurses into the misaligned middle region. This matters because
   a single insertion or deletion shifts every subsequent child's index
   position in a naive zip, which would make the _entire rest of the
   node_ look "different" even though the actual subtrees are unchanged.
   Prefix/suffix alignment recovers the structural sharing that CDC
   already bought at page-build time.

When a genuine mismatch is found and one side has descended into a leaf
while the other is still internal (or vice versa — this happens when a
subtree's _size_ has changed enough to change its page-count), both
sides get flattened to a plain sorted list of `LeafEntry` via
`flattenChildren`/`flattenSubtree`, and diffed with a straightforward
three-way merge (`diffLeafLists`) — walk both sorted lists in lockstep,
classify each divergence as `added`, `removed`, or `modified` (same
path, different hash/size/mode).

`diffRoots` itself takes a pre-built `*const PageStore` rather than
constructing one internally — this keeps `diff.zig` decoupled from
knowing the `pages_dir`/`fs` convention entirely; that's `Index`'s (or
any other caller's) job.

> **Known gap:** there's a disabled test in `diff.zig`
> (`diffRoots handles mixed add/remove/modify across a multi-page tree`,
> `//TODO: inspect failure`) covering a multi-page tree with one
> addition, one removal, and one modification scattered across ~400
> entries. It's currently failing for reasons not yet root-caused — flag
> this if you're relying on diff correctness across page boundaries with
> mixed change types.

---

## 7. Load / save lifecycle

### `load()`

1. Clear all in-memory state (`entries`, `path_index`).
2. Read `<index_dir>/index/index_root` via `fs.readFile`. If it doesn't
   exist, the index starts empty — this is the normal state for a
   freshly-initialized repo, not an error.
3. If the stored root is `zero_hash` (an explicitly-saved empty index),
   stop — no pages to read.
4. Otherwise, build a `PageStore` scoped to `<index_dir>/index/pages` and
   `tree.collect` the whole tree into `entries`.
5. Sort `entries` and rebuild `path_index`.

### `save()`

1. Sort `entries` and rebuild `path_index` (belt-and-suspenders — should
   already be sorted from `upsert`/`remove`, but `save` doesn't assume
   that invariant was maintained perfectly by every caller).
2. Best-effort delete a legacy `<index_dir>/index` file if one exists
   (an artifact of an older, pre-paged on-disk format, where the index
   root apparently lived directly at that path) — this is defensive
   cleanup so `RealFs` can create `index/` as a _directory_ without
   tripping over a leftover file occupying that name. Failure here is
   swallowed (`catch {}`) since the common case is "there was nothing to
   clean up."
3. `tree.build` the current `entries` into a fresh tree (writing any new
   pages, reusing any that already exist), producing a new root hash.
4. Write that root hash to `<index_dir>/index/index_root`.
5. Update `self.index_root`.

Note that `save()` never deletes old pages that are no longer reachable
from the new root — merk's page store, like git's object store, is
currently append-only / no garbage collection. Old, now-unreferenced
pages simply accumulate on disk.

---

## 8. The `io.FileSystem` abstraction

Every piece of Index/PageStore/Store I/O goes through `io.FileSystem` — a
small vtable interface (`readFile`, `readRange`, `writeFile`,
`openReader`, `deleteFile`, `fileExists`, `statFile`, `renameFile`,
`copyFile`, `deleteDir`, `listFiles`) with two implementations:

- **`RealFs`** — backed by a real `std.fs.Dir`. Used in production.
  Handles atomic writes (temp file + rename), parent-directory creation,
  and best-effort pruning of now-empty parent directories after a
  delete/rename.
- **`TestFs`** — a pure in-memory `StringHashMap`. Used in tests. Same
  semantics (atomicity is trivially true — a hashmap write is one
  operation), but with none of real disk's latency, cleanup burden, or
  platform-dependent edge cases (e.g. path separator normalization,
  which `RealFs` has to handle explicitly and `TestFs` doesn't need to).

Every test in `index.zig`, `page_store.zig`, `tree.zig`, and `diff.zig`
that doesn't specifically need to prove something about real-disk
behavior (atomic rename semantics, directory pruning) uses `TestFs` —
which is most of them. This is why the whole Index test suite runs in
milliseconds rather than doing hundreds of real file creates/deletes per
`zig build test` invocation.

The one place that deliberately **stays** on raw `std.fs.Dir` is
`addFileFromDir`/`stateOfInDir` — reading arbitrary _worktree_ files
(the user's actual project files, at arbitrary caller-supplied paths),
which is a different concern from the index's own internal storage and
doesn't currently benefit from the `FileSystem` abstraction the way
content-addressed storage does.

---

## 9. Public API summary

| Method                                                            | Purpose                                                                                                                                                                                                                                                              |
| ----------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Index.init(alloc, fs, index_dir)`                                | Construct an unopened index. Caller owns `fs` (typically a `RealFs` in production, `TestFs` in tests) and keeps it alive for the `Index`'s lifetime.                                                                                                                 |
| `deinit()`                                                        | Free all owned entries and the path index.                                                                                                                                                                                                                           |
| `load()`                                                          | Populate `entries`/`index_root` from whatever's on disk (empty if nothing saved yet).                                                                                                                                                                                |
| `save()`                                                          | Persist current `entries` as a fresh tree; updates `index_root`.                                                                                                                                                                                                     |
| `lookup(path)`                                                    | O(1) — is `path` tracked, and if so, its current `Entry`.                                                                                                                                                                                                            |
| `remove(path)`                                                    | Untrack a path. `error.NotFound` if it wasn't tracked. Does **not** touch the worktree file.                                                                                                                                                                         |
| `addFile(store, repo_root, path)`                                 | Read `repo_root/path` from the real filesystem, store its content as a blob via `store` (an `object.Store`), and upsert the resulting entry.                                                                                                                         |
| `addFileFromDir(store, dir, fs_path, index_path)`                 | Same, but with an explicit `Dir` handle and separate "path to open" vs. "path to record" — used internally, and directly by tests that want an isolated tmpdir.                                                                                                      |
| `stateOf(repo_root, entry)` / `stateOfInDir(dir, fs_path, entry)` | Compare a tracked `Entry` against the current worktree file: `.clean`, `.modified`, or `.deleted`. Comparison is by size + mode + mtime — **not** content hash, so it's a cheap "probably unchanged" check, not a guarantee (mirrors git's own stat-cache tradeoff). |
| `diffAgainst(other_root)`                                         | Structural diff between this index's current tree and another root hash. Returns owned `[]EntryChange` — free with `merkle_mod.freeChanges`.                                                                                                                         |

---

## 10. Invariants worth knowing

- **`entries` and `path_index` must never drift.** Every method that
  mutates one updates the other in the same call (`upsert`, `remove`) or
  explicitly calls `rebuildPathIndex()` afterward (`load`, `save`). If
  you're adding a new mutation method, don't forget this.
- **`index_root` only reflects the _last_ `load()` or `save()`.**
  Mutating `entries` directly (as several tests do, for setup
  convenience) does _not_ update `index_root` — it stays stale until the
  next `save()`. Don't read `index_root` as "the hash of the current
  `entries`" unless you know a `save()` happened since the last mutation.
- **Pages are immutable and content-addressed; nothing currently garbage
  collects unreachable ones.** Don't rely on old pages disappearing.
- **`stateOf`/`stateOfInDir` use mtime-based dirty-checking**, which
  inherits the well-known git caveat: a filesystem with coarse mtime
  resolution, or a modification that lands within the same tick, can
  produce a false `.clean` result. This is a deliberate performance
  tradeoff (avoiding a full content hash on every status check), not an
  oversight.
- **`FileSystem` handles passed into `Index.init`/`PageStore.init` must
  outlive the struct.** Both `RealFs.fs()` and `TestFs.fs()` return a
  `FileSystem` whose `ptr` points back at the `RealFs`/`TestFs` value
  itself — moving or letting that value go out of scope while an
  `Index`/`PageStore`/`Store` still holds the resulting `FileSystem` is
  a dangling-pointer bug.
