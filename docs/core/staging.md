# `staging.zig` — Internal Documentation

This document explains how `Staging` works internally: its data model, its
relationship to `EntryIndex` and `ComponentDir`, the lifecycle of every
operation, and the sharp edges that aren't obvious from reading the code top
to bottom. It's written for someone who needs to _modify_ `staging.zig`
safely, not just call it.

> **Scope note.** `Staging` is one of the five stores wired together by
> `Repository` (see `repo.zig`'s internal docs, §1). This document goes one
> level deeper than that overview — it's about what's _inside_ the
> "flat, ordered list" box, not about how `Repository` uses it.

---

## 1. Mental model: a flat list, deliberately not a tree

`Staging` tracks "what will the next commit contain if I commit right now."
The obvious way to build that would be to maintain a live Merkle tree as
files are staged. `Staging` does **not** do this, and the type doc comment
explains why in some detail — it's worth restating plainly, because the
reasoning drives most of the rest of this file's design:

```
   EARLIER DESIGN (rejected)              CURRENT DESIGN
   ────────────────────────               ──────────────
   Staging builds + persists a            Staging holds a flat,
   Merkle tree on every save(),           unstructured list of
   into its OWN "staging/pages"           Entry{path, blob_hash,
   directory — separate from the          size, mode, mtime}.
   repo's permanent "index/pages"         No tree. No page store.
   PageStore.
                                           The one tree Merk ever
   Hazard: a staged tree's hash is        needs from staged content
   only resolvable in the store it        is built ON DEMAND, directly
   was built into. Committing has         into the repo's shared,
   to remember to re-materialize          PERMANENT PageStore, at the
   it into the permanent store —          two moments that actually
   any path that forgets (or reads        need a hash: committing, and
   a staged hash before that step         diffing staged vs. HEAD. See
   runs) hits error.NotFound.             Repository.stagingTreeRoot.
```

**Good to know:** because pages are content-addressed, rebuilding the same
staged entries into a tree repeatedly is cheap — `PageStore.put` skips
writing any page whose hash already exists on disk. That's what makes "never
cache a tree here, just rebuild on demand" a real design decision rather
than a performance trap. See `repo.zig` §3 for the caller side of this.
`totalStagedSize()` (§9) exists partly to make that on-demand rebuild's cost
predictable ahead of time, without changing the "never cache it" decision
itself.

**What `Staging` owns:** the flat entry list and its on-disk persistence
(now including a `dirty` bit tracking whether that persisted copy is
current — see §4). **What it explicitly does not own:** worktree content
correctness (it only _reads_ worktree files to hash them; it never treats
itself as the source of truth for what's on disk), and it does not own the
Merkle tree that represents it.

---

## 2. Two layers: `Staging` (I/O) wraps `EntryIndex` (pure data structure)

```
                    ┌───────────────────────────────────┐
                    │              Staging               │
                    │  - fs: Vfs, dir: ComponentDir       │
                    │  - dirty: bool                      │
                    │  - disk I/O (load/save), lock file  │
                    │  - worktree reads (addFile, stateOf)│
                    │  - store writes (addFile → blobs)   │
                    └──────────────┬──────────────────────┘
                                   │ owns
                                   ▼
                    ┌───────────────────────────────────┐
                    │            EntryIndex               │
                    │  - entries: ArrayList(Entry)        │
                    │  - path_index: path -> u32 position │
                    │  - knows NOTHING about disk, Vfs,   │
                    │    or Merkle pages                  │
                    └──────────────────────────────────────┘
```

This split exists so the "pure in-memory sorted, path-indexed collection"
logic can be reasoned about (and tested — see `entry_index.zig`'s test
suite) completely independently of filesystem concerns. `Staging` is the
thin shell that knows _where_ the entries live on disk and _how_ to hash a
worktree file into a `blob_hash`; `EntryIndex` is the shell-agnostic part
that knows how to keep a sorted list and a lookup map consistent with each
other under insert/replace/remove.

`dirty` lives on `Staging`, not `EntryIndex`, for the same reason: it's a
persistence-layer concept ("does disk match memory?"), not something a pure
in-memory collection has any business tracking about itself.

**Good to know:** `Staging.index` is a public field, not hidden behind
accessors — several of `Staging`'s own tests reach directly into
`staging.index.entries` to set up fixtures that bypass `addFile`/`put`
(e.g. constructing entries with a specific `mtime` without touching a real
filesystem). This is intentional for testability, but production code
outside `staging.zig` should still go through `Staging`'s methods
(`lookup`, `put`, `remove`, `allEntries`, ...) rather than reaching into
`.index` directly — see `allEntries`'s own doc comment for the reasoning
(keeps `Staging` free to change how it stores entries later).

**Sharp edge for test authors:** because `dirty` is set only by `Staging`'s
own mutators (`put`, `remove`, `addFile*`), a test that appends straight to
`staging.index.entries` and then calls `staging.save()` will find `save()`
silently does nothing — `dirty` is still `false`. Set `staging.dirty = true`
by hand right after the direct append, same as any other internal-state
fixture that bypasses the public API.

---

## 3. `ComponentDir`: where the "entries" file (and its lock) actually live

`Staging`'s on-disk state is a single file, `entries`, under `staging_dir`
(typically `.merk/staging` when `fs` is rooted at the repo root). `save()`
also creates and deletes a sibling `entries.lock` for the duration of each
write (§13):

```
staging/
├── entries        <- flat, length-prefixed serialization of the entry list
└── entries.lock    <- present only while a save() is in flight
```

`Staging.dir` is a `ComponentDir`, not a raw string. `ComponentDir` exists
because this exact "join repo_dir with a sub-path, or just use the sub-path
when repo_dir is empty" logic used to be reimplemented separately by every
component that needed on-disk state (`Staging`'s own `subPath`, and again in
`object_store.zig`) — duplication that let the empty-`repo_dir` convention
drift between components. `ComponentDir.join` is now the one shared
implementation; `Staging.load`/`save` both go through
`self.dir.join(self.alloc, "entries")` rather than building the path
themselves. `entries.lock`'s path is derived from that same joined path
(`"{entries_path}.lock"`), not built independently — so it stays a true
sibling even if `entriesPath()`'s own logic ever changes.

**Good to know:** `ComponentDir` also has `shardedPath`, for two-level hex
sharding of hash-keyed stores (`xx/yy/<hex>`, used by loose objects and the
structural-hash side index). `Staging` doesn't use `shardedPath` — its
entries file isn't hash-keyed, it's a single flat file — but it's worth
knowing that method exists on the same type so a future change that makes
staging content-addressed doesn't reinvent that sharding logic from
scratch.

---

## 4. Lifecycle: `init` / `load` / `save`, and the `dirty` flag

```
        Staging.init(alloc, fs, staging_dir)
                     │           (dirty: false)
                     ▼
         (in-memory only: index is empty,
          nothing touched on disk yet)
                     │
              ┌──────┴──────┐
              ▼             ▼
          load()         addFile()/put()/... directly
              │             (no load() needed for a
              ▼              freshly-init'd empty area —
     entries file exists?    e.g. Repository.init's
              │              fresh-repo path; each of
       ┌──────┴──────┐       these sets dirty = true)
      yes            no
       │              │
       ▼              ▼
  deserialize    index stays empty;
  into index,    sortAndReindex()
  sortAndReindex  still runs, so
  (dirty := false) path_index is a
                  valid (empty) map
                  (dirty := false)
```

**Good to know:** `load()` unconditionally calls `self.index.clear()` as its
first step, even on the "nothing on disk yet" path. This matters if you ever
call `load()` on a `Staging` that already has entries in memory from prior
`addFile`/`put` calls that were never saved — `load()` will discard them
silently, replacing in-memory state with whatever's on disk (or nothing).
`load()` is a _reload from disk_, not a merge. Either way, `load()` finishes
by setting `dirty = false`: a freshly loaded `Staging` is, by definition,
in sync with what's on disk.

**`save()` is now conditional.** Every mutator (`put`, `remove`,
`addFile`/`addFileFromDir`, `addFiles`/`addFilesFromDir`) sets
`self.dirty = true`. `save()` checks that flag first and returns
immediately if it's `false` — skipping the `sortAndReindex()` call, the
serialize, and (importantly) the lock-file dance in §13, none of which have
anything to do if nothing has changed since the last `load()`/`save()`.
This matters in practice because `Repository.commit`/`status` can end up
calling into staging more than once within a single CLI invocation; without
this, each of those calls would re-sort, re-serialize, and re-write a file
whose contents hadn't changed.

`replaceAll` is the one exception: it always wants disk to end up matching
its argument exactly, even when that argument happens to be identical to
what's already persisted (e.g. replacing empty with empty). It bypasses the
`dirty` check via a private `forceSave()` — see §11.

`save()` still always calls `self.index.sortAndReindex()` first (once it's
decided to actually write) — see §9 for why this is necessary and not just
defensive.

---

## 5. Adding a file: `addFile` / `addFileFromDir`

```
addFile(store, repo_root, path)
   │
   │  joins repo_root + path, delegates to addOneFromRoot(..., std.fs.cwd(), ...)
   ▼
addOneFromRoot(store, dir, repo_root, path)
   │
   │  joins repo_root + path, opens via the given `dir`
   ▼
addFileFromDir(store, dir, fs_path, staged_path)
   │
   1. validatePath(staged_path)              ← reject malformed paths
   2. dir.openFile(fs_path)                  ← must exist and be openable
   3. stat.kind != .file → error.NotAFile    ← rejects directories, etc.
   4. store.putReader(.blob, stat.size, file) ← content-addressed hash+write
   5. index.upsert({ path, blob_hash,
        size: stat.size, mode: stat.mode,
        mtime: stat.mtime })                  ← in-memory only; no save()
   6. self.dirty = true
```

**Good to know — the `dir`-parameterized middle layer.** `addOneFromRoot`
is a thin seam between `addFile` (always reads from `std.fs.cwd()`) and
`addFileFromDir` (takes an explicit `std.fs.Dir`). It exists so
`addFiles`/`addFilesFromDir` (§6) can share the exact same join-then-read
logic `addFile` uses, including in tests that need to point reads at a
`tmp_dir` instead of the real process `cwd` — the same reason
`addFileFromDir` itself exists as a separate entry point from `addFile`.

**Good to know:** `addFile`/`addFileFromDir` still do **not** call `save()`
— that part of the contract hasn't changed. Every caller that wants the
addition to survive a process restart must call `save()` itself afterward
(`Repository.add` does this after its loop over paths). What has changed is
that both now flip `dirty = true` as their last step, so a `save()` that
does eventually run knows there's something to write; mid-session,
`lookup()` and `allEntries()` already reflected un-saved additions
correctly before this change too — only the bookkeeping around persistence
is new.

**Good to know — content-addressing, not raw hashing.** `addFileFromDir`
hashes via `store.putReader(.blob, stat.size, file)`, which frames the
content with its type and size before hashing (git-style object hashing) —
**not** a plain hash of the raw bytes. Don't assert
`entry.blob_hash == someHashFn(fileContent)` in tests; verify by reading the
blob back through `store.get()` instead. (This point is inherited directly
from `repo.zig`'s own note on `add()` — it's the same `store` call underneath
`Repository.add`, just reached one layer down here.)

**Good to know — why `addFileFromDir` stays on `std.fs.Dir`, not `Vfs`.**
Every other piece of `Staging`'s own persistent state (the `entries` file
and its lock) goes through `self.fs: Vfs`. Worktree files are a different
concern — they're arbitrary user content that can live anywhere on disk,
not part of the repository's internal storage — so reading them
deliberately uses `std.fs.Dir` instead. Don't "simplify" this by routing
worktree reads through `Vfs` too; the two are different address spaces on
purpose.

**Good to know — freshness of the stat.** `addFileFromDir` always re-`stat`s
the file at the moment it's called, and _that_ `mtime`/`size`/`mode` is what
lands on the staged entry. If a caller writes a file and then calls
`addFile` before that write has actually landed (e.g. wrong ordering in a
larger operation), the staged entry's metadata reflects stale state, and the
next `stateOf` check will misreport it. This is the same hazard `repo.zig`
documents for `Repository.add` — it originates here, in `addFileFromDir`,
not in the `Repository` wrapper.

---

## 6. Batch adding files: `addFiles` / `addFilesFromDir`

```
addFiles(store, repo_root, paths)
   │  delegates to addFilesFromDir(..., std.fs.cwd(), ...)
   ▼
addFilesFromDir(store, dir, repo_root, paths):

   1. snapshot := deep copy of index.allEntries()   (fresh .path dupes)
   2. for each path in paths:
        addOneFromRoot(store, dir, repo_root, path)
           │
           ├─ success → append hash to result list, continue
           └─ failure → index.clear()
                         index.entries := snapshot (ownership moves in)
                         index.sortAndReindex()
                         free the snapshot LIST (not its entries — they
                           now belong to index)
                         return the error
   3. all succeeded → free the snapshot (entries + list), dirty := true,
      return the hash list
```

**What problem this closes.** Looping `addFile` yourself has no atomicity:
a failure partway through the loop leaves every path _before_ the failure
staged, with no built-in way to undo just that partial batch. `addFiles`
closes that gap at the layer that actually owns the mutation — the caller
gets an all-or-nothing guarantee (`self.index` after a failed call is
byte-for-byte the same as before the call) instead of having to snapshot
and restore staging state itself.

**Good to know — this is index rollback, not store rollback.** Blob content
already written to `store` for paths that succeeded before the failure is
**not** undone. Objects are content-addressed and immutable, so an orphaned
blob from a rolled-back batch is harmless — just unreferenced by anything in
`index` until either the same content is staged again later, or a future GC
sweeps it. Don't add store-side cleanup here; it isn't needed and would add
complexity for no correctness benefit.

**Good to know — why the snapshot duplicates entries instead of borrowing
them.** `index.clear()` (used both mid-rollback and by the next `load()`)
frees every entry's `.path`. If the snapshot merely borrowed the current
entries instead of duping them, the moment anything in the loop triggered a
`clear()`-based path, the snapshot's borrowed pointers would already be
dangling. The dupe is what makes "restore exactly the pre-call state" safe
regardless of what the failed call already did to `index` before erroring.

**Good to know — `snapshot_owned` is a manual ownership flag, not a typo.**
The success path frees the snapshot itself (its entries were never needed —
`self.index` was left untouched by every successful iteration). The failure
path instead _moves_ the snapshot's entries into `self.index` and then frees
only the now-empty backing list. A `defer` guards the common ("snapshot
still owns its entries") case; the failure channel explicitly disarms it
before returning, precisely because at that point ownership has already
moved and a second free would be a double-free. See §9 for the same pattern
stated as a table row.

**Good to know — same `dir`-parameterization as `addFile`/`addFileFromDir`
(§5).** `addFiles` is the `std.fs.cwd()`-based public entry point;
`addFilesFromDir` is what it (and tests pointing at a `tmp_dir`) actually
call. Don't add a third variant — extend `addFilesFromDir` and keep
`addFiles` a one-line forwarder, same as `addFile` is over `addOneFromRoot`.

---

## 7. `stateOf` / `stateOfInDir`: how "clean vs. modified vs. deleted" is decided

```
stateOfInDir(dir, fs_path, entry):

  dir.statFile(fs_path)
       │
       ├─ error.FileNotFound → .deleted
       ├─ other error        → propagate (never swallowed)
       └─ ok: stat
              │
              ├─ stat.kind != .file  → .modified
              ├─ stat.size  != entry.size  → .modified
              ├─ stat.mode  != entry.mode  → .modified
              ├─ stat.mtime != entry.mtime → .modified
              └─ otherwise                  → .clean
```

This is a **metadata comparison, not a content comparison.** `Staging` never
rehashes file content to answer "is this clean?" — it trusts that
size+mode+mtime matching the recorded entry means the content is
unchanged. This is what makes `status()` cheap to call often (see `repo.zig`
§3's note on why a staged entry's `mtime` is load-bearing, not just
informational).

**Good to know — this is exact-match, not "newer than."** A file whose
`mtime` moved _backward_ (e.g. restored from a backup, or a clock
adjustment) is reported `.modified` just as readily as one that moved
forward — `stateOfInDir` does `!=`, not `>`. If you're ever tempted to
"fix" a false-positive by comparing `>=` instead, don't: that would let a
genuinely modified file with an _earlier_ mtime than what's staged pass as
clean, which is worse.

**Good to know — nanosecond precision isn't guaranteed everywhere.** The
doc comment on `stateOfInDir` flags this directly: some filesystems don't
preserve `mtime` at full nanosecond precision. A write-then-immediately-stat
round trip that changes precision between the two reads could, in principle,
produce a `.modified` false positive even though content is identical. This
hasn't been the source of an actual bug in this codebase (contrast with
§8's `.hard`-reset bug, which _was_ real and is now fixed), but it's a known,
accepted limitation of comparing `mtime` at all — not something `stateOfInDir`
tries to work around.

**Good to know — only `FileNotFound` becomes `.deleted`.** Any other stat
error (permission denied, a path component that's not a directory, etc.)
propagates as a Zig error rather than being folded into `.modified` or
`.deleted`. Don't broaden the `catch` to swallow more error variants into
`.deleted` — a permissions error genuinely isn't the same situation as "the
file is gone," and callers further up (`status()`) need to be able to tell
the difference (or at least not lie about it).

---

## 8. Why staged `mtime` correctness is `Staging`'s responsibility, not just `Repository`'s

`repo.zig` documents (§3, §8) that `reset(.hard)`'s worktree-write path had
a real bug: `writeBlobToWorktree` rewrote file content without updating the
corresponding staged entry's `mtime`, so every hard-reset file came back
falsely `.modified` on the next `status()` — even though its content
matched exactly. That bug's _fix_ lives in `Repository.writeEntriesToWorktree`
(it re-stats after writing and calls `staging.put(...)` to resync), but the
reason the bug was even possible to introduce lives here: `stateOfInDir`'s
strict metadata equality (§7) means **any** code path anywhere that rewrites
a tracked file's content without also calling `Staging.put`/`addFile`
afterward will reproduce the same class of false positive.

**Good to know — this is the contract `Staging` exposes, and it has teeth.**
`Staging` itself has no way to detect "someone rewrote this file behind my
back" — it only ever answers `stateOf` questions by trusting whatever
metadata is currently recorded. Every future caller that materializes
content onto disk on `Staging`'s behalf (not just `reset(.hard)`) needs to
follow the same write-then-restat-then-`put` sequence, or `stateOf` will
lie for that path until something else happens to re-add it. `put`'s own
side effect of setting `dirty = true` means that resync is also guaranteed
to eventually reach disk the next time anything calls `save()` — it isn't
possible to "fix" the in-memory entry via `put` and have that silently fail
to persist.

---

## 9. `EntryIndex`: sorted list + path index, `contains`, and `entriesUnder`

```
   entries: ArrayList(Entry)          path_index: StringHashMapUnmanaged(u32)
   ┌───────────────────────┐          ┌─────────────────────────────────┐
   │ [0] a.txt              │◄─────── │ "a.txt" → 0                     │
   │ [1] b.txt              │◄─────── │ "b.txt" → 1                     │
   │ [2] c.txt              │◄─────── │ "c.txt" → 2                     │
   └───────────────────────┘          └─────────────────────────────────┘
```

`lookup(path)` never scans `entries` — it's a direct `path_index.get(path)`
followed by an index into `entries`. `contains(path)` is a one-line wrapper
over the same map lookup, returning a `bool` instead of the full `Entry`
— for the (common) case of a caller that only ever wanted the yes/no answer
and was writing `lookup(...) != null` itself. `Staging.contains` is the
`Staging`-level equivalent, forwarding straight through.

This is why the test _"staging lookup works after addFile without an
intervening save"_ deliberately inserts lexicographically out of order
(`zzz.txt` before `aaa.txt`) and still expects both to resolve: `lookup`
(and, by extension, `contains`) doesn't care about sort order at all.

**Good to know — sort order is NOT continuously maintained.** This is the
sharpest edge in this file, and it's easy to miss because `allEntries`'s
own doc comment says entries come back "sorted by path" without qualifying
when that's actually true.

```
  upsert(new_path)  →  appendOne  →  appended at the END of entries,
                                      NOT inserted at its sorted position

  upsert(existing_path) → replaceAt → entry stays at its current
                                       position (position unchanged,
                                       so sort order is preserved for
                                       in-place replacements)

  remove(path)      →  orderedRemove → preserves relative order of
                                        everything else (sort order
                                        preserved for removals)
```

So: **replacing** an existing path or **removing** a path never disturbs
sort order. **Adding a genuinely new path** does — the new entry lands at
the end of `entries`, wherever that happens to sort. `allEntries()` is only
guaranteed sorted immediately after `sortAndReindex()` has run — which
happens inside `load()`, `save()` (once it decides to actually write —
see §4), and `replaceAll()`, but **not** inside plain
`upsert`/`addFile`/`put` calls.

**Practical consequence:** if you call `addFile` for several new paths in a
row and then inspect `allEntries()` _before_ calling `save()`, you may see
them in insertion order, not path order. `lookup()`/`contains()` are
unaffected (they never relied on order), but any code that assumes
`allEntries()` is sorted at every point in time — not just after a save —
will be wrong.

**`entriesUnder(prefix)` inherits this caveat directly, and its contract is
stricter about it than `allEntries()`'s.** It returns the contiguous slice
of `entries` whose path begins with `prefix`, found via a binary search for
the run's start followed by a linear scan to its end — `O(log n + k)`
instead of an `O(n)` filter over the whole list. That binary search is only
correct against a sorted list: called against an unsorted `entries`, it
doesn't error, it just silently returns a wrong slice (too small, too
large, or a "contiguous" run that doesn't actually correspond to every
matching entry). Callers must either call `entriesUnder` only in the
window right after a `load()`/`save()`/`replaceAll()`/`sortAndReindex()`
— exactly the pattern the existing tests use — or call
`sortAndReindex()` themselves first if that guarantee doesn't already
hold. `Staging.entriesUnder(prefix)` forwards straight to
`EntryIndex.entriesUnder` and carries the same requirement.

**Good to know — why `entriesUnder` doesn't force a sort itself.** It's a
`*const` method precisely so it stays a cheap, side-effect-free read —
matching `allEntries`/`lookup`/`count`. Forcing a `sortAndReindex()` inside
it would make it silently mutating (surprising for a `*const`-shaped API)
and would hide the cost of an out-of-order call rather than surfacing it.
If a caller can't guarantee sortedness, making that caller call
`sortAndReindex()` explicitly is more honest than `entriesUnder` doing it
invisibly on their behalf.

**Good to know — why `remove`'s reindex only touches positions, not
hashes.** `EntryIndex.remove` shifts every entry after the removed index
down by one (unavoidably O(n) for a mid-list removal, since `entries` is a
plain `ArrayList`), but it only rewrites the shifted entries' _integer
positions_ in `path_index` — it never recomputes or re-inserts their path
strings as hash keys. Rehashing long path strings is the expensive part;
overwriting an already-present key's value with a new `u32` is not. If
you're tempted to "simplify" this into a full `reindex()` call after every
`remove`, don't — that turns an O(n) position-fixup into an O(n) full
rehash for no behavioral difference.

---

## 10. Ownership rules across the `Staging` / `EntryIndex` boundary

Every `Entry.path` is a heap allocation (`alloc.dupe(u8, ...)`), and
ownership of it moves in exactly one direction at a time. Getting this
backwards is a leak-or-double-free bug, so it's worth stating the rules
explicitly:

| Call                                                    | On success                                                                                                       | On failure                                                                                                                                                  |
| ------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Staging.addFileFromDir` / `addOneFromRoot`             | new `Entry` (with fresh duped path) handed to `index.upsert`                                                     | nothing staged; no leak (upsert frees on error path — see below)                                                                                            |
| `EntryIndex.upsert`                                     | takes ownership of `entry` (and its `.path`)                                                                     | frees `entry` (`errdefer`) before returning                                                                                                                 |
| `EntryIndex.appendUnique`                               | takes ownership                                                                                                  | frees `entry` (`errdefer`), returns `error.DuplicatePath` if the path was already present                                                                   |
| `EntryIndex.remove`                                     | frees the removed entry's `.path` internally                                                                     | n/a (only `error.NotFound`, nothing was allocated)                                                                                                          |
| `Staging.put` / `EntryIndex.upsert` (direct-entry form) | takes ownership of the passed-in `Entry`                                                                         | frees it on failure, same as any other `upsert`                                                                                                             |
| `Staging.replaceAll` / `EntryIndex.replaceAll`          | takes ownership of **every** entry in the passed slice; old entries are freed via `clear()` first                | n/a — `error.TooManyEntries` is the only failure mode, and it happens before any entries are touched                                                        |
| `Staging.addFiles` / `addFilesFromDir`                  | snapshot (deep-duped) entries freed once the whole batch succeeds; `self.index` itself untouched by the snapshot | on any per-path failure, the snapshot's entries move into `self.index` (ownership transfer, not a copy), and the snapshot's now-empty backing list is freed |
| `Staging.verify`                                        | returned `MissingEntry.path` values **borrow** from `self.index` — never duped, never owned by the caller        | n/a — the only failure mode is allocation failure building the result list                                                                                  |

**Good to know — `replaceAll` callers must not free `entries[i].path`
themselves, and must not reuse the backing slice.** Both `Staging.replaceAll`
and the tests exercising it (`"staging replaceAll discards current entries
and persists the replacement"`) are explicit about this: the caller builds
an `ArrayList(Entry)`, hands `.items` to `replaceAll`, and then calls
`.deinit(alloc)` on the _list_ (freeing the backing array) but never touches
each entry's `.path` — that ownership already moved into `Staging.index`.

**Good to know — `appendUnique` vs `upsert` exist for different trust
levels.** `upsert` is the general "insert or replace" primitive used by
normal staging operations (`addFile`, `put`). `appendUnique` is for
callers that have already established a path _must_ be new — currently,
that's nowhere in `staging.zig` itself, but it exists specifically for
callers like deserialization, where a repeated path in the byte stream
means the data is corrupt, not that a legitimate later write should
silently win. If you add a new caller that parses untrusted or
externally-supplied entries, prefer `appendUnique` over `upsert` so a
duplicate becomes a loud `error.DuplicatePath` instead of a silent
overwrite.

**Good to know — `verify`'s borrowed paths are a sharper lifetime hazard
than most of this table.** Unlike every other row, `MissingEntry.path`
isn't a fresh allocation the caller now owns — it's a pointer straight into
`self.index`'s own `Entry.path` allocations, kept alive only as long as
`self.index` is. `VerifyResult.deinit` frees the `[]MissingEntry` slice
itself (the array of borrowed pointers), never the paths they point to —
freeing those would double-free entries `Staging` still owns. A caller that
needs a `MissingEntry.path` to outlive the `Staging` it came from (e.g.
queuing missing-blob paths for a later report, after the repo object might
be torn down) must `dupe` it themselves before that point.

---

## 11. On-disk format: flat, not tree-shaped, now versioned

```
┌─────────┬─────────────┬──────────────────────────────────────────────────┐
│ u8       │ u32 count   │  count × entry records                            │
│ version  │             │                                                    │
└─────────┴─────────────┴──────────────────────────────────────────────────┘

each entry record:
┌───────────┬──────────────┬────────────┬──────────┬──────────┬───────────┐
│ u32       │ path bytes    │ 32-byte    │ u64      │ u64      │ i128      │
│ path_len  │ (path_len)    │ blob_hash  │ size (LE)│ mode (LE)│ mtime (LE)│
└───────────┴──────────────┴────────────┴──────────┴──────────┴───────────┘
```

All integers little-endian. Field widths (`u64` for size/mode, `i128` for
mtime) match `Entry`'s own types exactly — `serializeEntries`'s doc comment
calls out that this also matches the widths `node.zig`'s leaf-entry wire
format already uses, so there's no narrowing cast anywhere in the
serialize/deserialize path.

**The leading `u8` is new: a format version.** `current_entries_format_version`
(currently `1`) is written as the very first byte, before the entry count.
`deserializeEntries` reads it first and returns
`error.UnsupportedStagingFormat` immediately if it doesn't match — distinct
from `error.CorruptStagingEntries`, which still covers the "well-formed
version byte, but the rest of the buffer is truncated or otherwise
malformed" cases below it. This distinction is the whole point: before this
byte existed, there was no way for a future format change (an added field,
switching to varint lengths, whatever) to tell "valid file in the old
format" apart from "valid file in a newer format" apart from "actually
corrupt" — all three would have looked the same (garbage falls out of
misaligned reads, or a bounds check happens to trip). It was added while
there's presumably no `entries` data in the wild yet that would need a
migration path, since retrofitting a version byte onto files that don't
have one is the expensive direction.

**Good to know — this is intentionally "just the list," not a page format.**
No tree structure, no page chunking, no content-addressing of the
serialized blob itself. It's the simplest possible framing that round-trips
exactly — see §1 for why a richer, tree-shaped on-disk format was
specifically rejected for this file. The version byte doesn't change that;
it's the one piece of forward-compatibility machinery this flat format
gets.

**Good to know — `deserializeEntries` bounds-checks every field before
reading it**, returning `error.CorruptStagingEntries` the moment a length
prefix would read past the end of the buffer (checked separately before
each of: the version byte itself, the 4-byte entry count, the 4-byte path
length, the path bytes themselves, the 32-byte hash, the two 8-byte
integers, and the 16-byte mtime). A truncated or corrupted `entries` file
fails cleanly on `load()` rather than reading garbage memory or silently
producing a partial entry list.

---

## 12. Advisory locking around `save()`

```
saveInternal(force):
   if !force and !dirty → return   (§4 — nothing to do, no lock taken)

   sortAndReindex()
   serialize entries

   lock_path := entries_path ++ ".lock"
   if readFile(lock_path) succeeds → return error.StagingLocked
   writeFile(lock_path, "")                       ┐
   ... write tmp file, rename over entries ...     ├─ the "critical section"
   deleteFile(lock_path)  (via defer, best-effort) ┘

   dirty := false
```

**What problem this narrows.** Two `merk` processes racing a `save()`
against the same staging area used to have no coordination at all — nothing
stopped one process's write from landing in the middle of, or immediately
after, the other's, silently clobbering whichever write lost the race. The
lock makes the far more common version of that scenario loud instead of
silent: if a lock file is already present when `save()` goes to write, it
returns `error.StagingLocked` rather than proceeding.

**Good to know — this is check-then-write, not true exclusive create, and
that distinction matters.** `Vfs` doesn't currently expose an atomic
"create this file, fail if it already exists" primitive — only the
`readFile`/`writeFile`/`deleteFile`/`renameFile` primitives `Staging`
already used elsewhere. The lock is built from those: read the lock path
first, and only write it if that read fails. That leaves a narrow window
where two processes can both observe "no lock file" before either has
written one, and both proceed. This is a real, currently-accepted gap —
not a bug to "fix" by adding more checks around the same two calls; closing
it for real needs an actual atomic exclusive-create primitive added to
`Vfs` (at which point `saveInternal` should switch to that instead of the
check-then-write pair). Until then, this narrows the original hazard
(catches the ordinary case: an obviously still-running, or
crashed-and-abandoned, `merk` process) without eliminating the theoretical
race.

**Good to know — no staleness policy for an abandoned lock.** If a process
crashes while holding the lock, `entries.lock` is left behind and every
subsequent `save()` returns `error.StagingLocked` indefinitely — there's no
max-age check that decides to treat an old lock as stale and proceed
anyway. The lock file must be removed by hand (or by the CLI, on the user's
explicit confirmation that no other `merk` process is running), the same
way git tells a user to check for a stale `index.lock`. Don't add automatic
staleness expiry without a real design pass on it — a wrong guess about
"stale" is exactly the silent-clobber scenario this lock exists to prevent.

**Good to know — `load()` still takes no lock, and the load-mutate-save
cycle as a whole still isn't serialized.** The lock only wraps the write
inside `save()` itself. A `load()` in one process can still interleave with
a concurrent `save()` in another (reading a file that's mid-`renameFile` on
a `Vfs` backend where rename isn't atomic — POSIX rename is, but not every
backend is guaranteed to be), and nothing stops process A's
`load()`-then-mutate-then-`save()` sequence from interleaving with process
B's own such sequence around the lock, since the lock is only held for the
narrow write step, not the whole cycle. Full read/write serialization
across an entire load-mutate-save cycle is a bigger design question, left
open — the lock added here closes the sharper, more common hazard (two
writers landing on top of each other), not every concurrency hazard this
file has.

---

## 13. `verify()`: staged-vs-store integrity

```
verify(store):
   missing := []
   for each entry in index.allEntries():
       if !store.exists(entry.blob_hash):
           missing.append({ path: entry.path, blob_hash: entry.blob_hash })
   return VerifyResult{ missing }
```

**What problem this closes.** Nothing about normal staging operation ever
checks that a staged entry's `blob_hash` actually resolves in the object
`Store` — and in the common case, it always does, because every hash in
`index` came from a `store.putReader` call moments before `addFileFromDir`
staged it. That invariant can still break silently later, independent of
anything `Staging` does: a future GC/prune feature, a manual
`rm -rf .merk/objects`, or an `entries` file that's been hand-edited (or
corrupted in a way that still parses) to reference a hash nobody ever wrote.
Without `verify()`, the first place that breakage surfaces is deep inside
`stagingTreeRoot()`'s tree construction, as a bare `error.NotFound` with no
indication of which entry, or how many, are affected.

**Good to know — read-only, and does not touch the worktree.** `verify`
only compares `index`'s recorded hashes against `store.exists`; it doesn't
re-hash worktree files (that's `stateOf`'s job, and a different question —
"is the worktree file still what I staged" vs. "does what I staged still
exist in the store") and it never mutates `index` or `store`. A repo with
zero staged entries trivially verifies clean (`missing.len == 0`).

**Good to know — `VerifyResult.ok()` vs. inspecting `missing` directly.**
`ok()` is just `missing.len == 0`, provided as a readable one-liner for
callers that only care about the yes/no answer (e.g. a `commit` guard that
wants to refuse to proceed). Callers that want to report specifics — "N of
M staged blobs are missing, here they are" — read `missing` directly; both
paths are supported, `ok()` doesn't replace the detailed view.

**Good to know — ownership: see §10's table.** `MissingEntry.path` borrows
from `self.index`, it isn't duped. `VerifyResult.deinit` only frees the
`[]MissingEntry` array itself. Don't add a path-freeing loop to `deinit` —
that would double-free entries `Staging` still owns.

---

## 14. Method-by-method reference

### `init(alloc, fs, staging_dir)`

Pure in-memory setup — allocates nothing on disk, doesn't require the
`entries` file (or its directory) to exist yet. Safe to call for a
brand-new repo before anything has ever been staged. `dirty` starts `false`.

### `deinit()`

Delegates to `index.deinit()`, which frees every entry's `path` and the
backing `ArrayList`/`StringHashMapUnmanaged`. Does not touch anything on
disk — `deinit` is memory cleanup only, never an implicit `save()`. Does
not check or clear `dirty` — there's no on-disk state left to reconcile
once the in-memory side is gone.

### `load()` — see §4.

Always starts from `index.clear()`. Missing `entries` file is not an error
— it's the expected shape for a freshly-`init`ed repo — and still runs
`sortAndReindex()` on the (empty) result so `path_index` is in a consistent,
usable state either way. Always finishes by setting `dirty = false`.

### `save()` — see §4, §9, §11, §12.

Thin wrapper over `saveInternal(force: false)`: returns immediately if
`!dirty`. When it does proceed: `sortAndReindex()`, serialize (including
the format-version byte), take the advisory lock, write via a
temp-file-then-rename, release the lock, and set `dirty = false`. No
partial-write handling beyond whatever `Vfs.writeFile`'s own implementation
provides for the temp file itself — `Staging` doesn't do anything fancier
than the lock plus the existing temp-then-rename dance.

### `forceSave()` _(private)_

`saveInternal(force: true)` — same body as `save()`, but skips the `dirty`
check. Exists solely for `replaceAll`, which always wants to persist its
result regardless of whether anything "looks" dirty. Ordinary callers
should never need this; if you find yourself reaching for it outside
`replaceAll`, that's a sign the calling code should be setting `dirty`
correctly instead.

### `lookup(path)` — see §9. O(1) via `path_index`; order-independent.

### `contains(path)` — see §9.

`bool` wrapper over the same `path_index` lookup `lookup` uses. Prefer this
over `lookup(...) != null` at call sites that only need the yes/no answer.

### `totalStagedSize()`

`u64` sum of `entry.size` across `allEntries()`. `O(n)` — not cached,
recomputed on every call — so it's fine for an occasional "about to commit
this much data" check but not something to call in a hot loop over many
staged entries. See §1 for how this relates to the on-demand tree-build
design.

### `entriesUnder(prefix)` — see §9.

`[]const Entry` slice, `O(log n + k)` where `k` is the size of the matching
run. Requires `entries` to already be sorted (via a recent
`load`/`save`/`replaceAll`/`sortAndReindex`) — see §9 for the full caveat;
this is not defensively re-sorted on your behalf.

### `remove(path)` — see §9, §10.

`error.NotFound` if the path isn't currently staged. Does **not** touch the
worktree file — a deliberate boundary: callers that want the file gone too
(e.g. undoing a staged addition) must delete it themselves. `Staging` only
ever tracks _intent to commit_, never worktree deletion as a side effect of
untracking. Sets `dirty = true` on success.

### `addFile(store, repo_root, path)` / `addOneFromRoot(store, dir, repo_root, path)` / `addFileFromDir(store, dir, fs_path, staged_path)` — see §5.

The only methods that touch the object `Store` (write a blob) and read
arbitrary worktree content. None of them calls `save()`. All set
`dirty = true` on success.

### `addFiles(store, repo_root, paths)` / `addFilesFromDir(store, dir, repo_root, paths)` — see §6.

All-or-nothing batch add. Snapshots `index` before the loop; restores it on
any per-path failure. Doesn't call `save()`. Sets `dirty = true` only on
full success (a rolled-back failure leaves `index` — and therefore
`dirty` — exactly as they were before the call).

### `verify(store)` — see §13.

Read-only. Doesn't touch `dirty`, `index`, or `store`'s contents — purely a
check. Caller owns the returned `VerifyResult` and must call its
`deinit(alloc)`.

### `stateOf(repo_root, entry)` / `stateOfInDir(dir, fs_path, entry)` — see §7, §8.

Read-only; never mutates `Staging` or the entry passed in, and never
touches `dirty`. `stateOf` is the `repo_root`-relative convenience wrapper;
`stateOfInDir` is the version that takes an explicit `std.fs.Dir`, used the
same way `addFile`/`addFileFromDir` split.

### `allEntries()`

Read-only view (`index.allEntries()` under the hood — same underlying
slice, no copy). See §9 for the important caveat about when this is
actually guaranteed sorted.

### `count()`

`index.count()` — O(1), just `entries.items.len`.

### `put(entry)`

Thin wrapper over `index.upsert(entry)` — the entry-metadata-in-hand
counterpart to `addFile`/`addFileFromDir` for callers that already have a
constructed `Entry` (tests, or restoring from a snapshot such as
`Repository.writeEntriesToWorktree`'s post-write resync). Does not persist;
call `save()` when the caller is ready. Sets `dirty = true`.

### `replaceAll(entries)`

Wraps `index.clear()` + append-all + `sortAndReindex()`, then immediately
`forceSave()`s — unlike every other mutator here, `replaceAll` persists as
part of the same call rather than leaving that to the caller, and it does
so unconditionally (via `forceSave`, not `save`) rather than trusting
`dirty`. This matches its main call sites (`Repository.init`'s force-reinit
path, `reset`'s staging rebuild) where "replace and persist, no matter
what" is always exactly what's wanted in one step. See §10 for ownership
rules.

---

## 15. Quick-reference: what touches what

| Method                                          | In-memory (`index`)                      | `dirty`                        | Disk (`entries` + lock)  | Worktree (arbitrary file)    | Object `Store`         |
| ----------------------------------------------- | ---------------------------------------- | ------------------------------ | ------------------------ | ---------------------------- | ---------------------- |
| `init`                                          | –                                        | set `false`                    | –                        | –                            | –                      |
| `deinit`                                        | free                                     | –                              | –                        | –                            | –                      |
| `load`                                          | clear + rebuild from disk                | set `false`                    | read                     | –                            | –                      |
| `save`                                          | sort + reindex (if dirty)                | check; set `false` if it wrote | write (+ lock, if dirty) | –                            | –                      |
| `forceSave` _(private)_                         | sort + reindex                           | set `false`                    | write (+ lock)           | –                            | –                      |
| `lookup`                                        | read                                     | –                              | –                        | –                            | –                      |
| `contains`                                      | read                                     | –                              | –                        | –                            | –                      |
| `totalStagedSize`                               | read                                     | –                              | –                        | –                            | –                      |
| `entriesUnder`                                  | read                                     | –                              | –                        | –                            | –                      |
| `remove`                                        | write                                    | set `true`                     | –                        | –                            | –                      |
| `addFile` / `addOneFromRoot` / `addFileFromDir` | write (upsert)                           | set `true`                     | –                        | read (stat + open)           | write (blob)           |
| `addFiles` / `addFilesFromDir`                  | write (upsert loop; rollback on failure) | set `true` (success only)      | –                        | read (stat + open, per path) | write (blob, per path) |
| `verify`                                        | read                                     | –                              | –                        | –                            | read (`exists`)        |
| `stateOf` / `stateOfInDir`                      | read (entry passed in)                   | –                              | –                        | read (stat only)             | –                      |
| `allEntries`                                    | read                                     | –                              | –                        | –                            | –                      |
| `count`                                         | read                                     | –                              | –                        | –                            | –                      |
| `put`                                           | write (upsert)                           | set `true`                     | –                        | –                            | –                      |
| `replaceAll`                                    | clear + write + sort + reindex           | set `false` (via `forceSave`)  | write (via `forceSave`)  | –                            | –                      |

---
