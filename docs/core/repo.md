# `repo.zig` — Internal Documentation

This document explains how `Repository` (merk's core facade) works internally:
its data model, its component graph, the lifecycle of every operation, and the
sharp edges that aren't obvious from reading the code top to bottom. It's
written for someone who needs to _modify_ `repo.zig` safely, not just
call it.

> **Scope note.** This describes `repo/repo.zig` — the internal
> implementation file. Per its own doc comment, external callers should go
> through the top-level `repo.zig` facade, not this file directly.
> Everything here still applies to that facade's behavior, since the facade
> is a thin re-export.

---

## 1. Mental model: five stores, one commit graph

merk keeps repository state in five distinct pieces, each with a narrow job.
Understanding _which one owns what_ is the single most useful thing to
internalize before touching any method on `Repository`.

```
                         ┌──────────────────────────────────────┐
                         │              Repository              │
                         │         (composition root)           │
                         └───────────────┬──────────────────────┘
                                         │
        ┌──────────────┬──────────────┬──┴───────────┬──────────────┐
        │              │              │              │              │
        ▼              ▼              ▼              ▼              ▼
   ┌─────────┐   ┌───────────┐  ┌───────────┐  ┌───────────┐  ┌───────────┐
   │  Store  │   │ PageStore │  │  Staging  │  │  History  │  │ Reference │
   │ (blobs, │   │  (Merkle  │  │  (flat,   │  │  (commit  │  │   Store   │
   │ commits)│   │   tree    │  │  ordered  │  │  objects  │  │  (ref →   │
   │         │   │  pages)   │  │   list)   │  │   + path  │  │  commit)  │
   │         │   │           │  │           │  │   index)  │  │           │
   └─────────┘   └───────────┘  └───────────┘  └───────────┘  └───────────┘
   content-       tree nodes     "what will      commit         "current"
   addressed,      for staged    the NEXT        graph +        pointer +
   append-only     & committed   commit          per-path       named
   (blobs,         trees; keyed  contain"        lookup          channels
   commit          by page hash                  side index
   objects)
```

**Rule of thumb for where a piece of data lives:**

| Question                                                     | Answer lives in                                     |
| ------------------------------------------------------------ | --------------------------------------------------- |
| "What's the byte content behind this hash?"                  | `Store`                                             |
| "What does the Merkle tree for snapshot X look like?"        | `PageStore`                                         |
| "What will the _next_ commit contain if I commit right now?" | `Staging`                                           |
| "What commits exist, and what are their parent edges?"       | `History` (→ `Store` for the actual commit objects) |
| "What commit is `main` currently pointing at?"               | `ReferenceStore`                                    |
| "Which channel am I currently on?"                           | `Repository.channel` (`OwnedChannel`)               |

None of these five own more than one concern. `Repository` itself owns
_none_ of the data — it's purely a composition root that wires them together
and enforces cross-component invariants (path validation, "must be tracked
before you can X", "must resolve before you can Y").

---

## 2. The commit graph shape

```
        (root, no parent)
             c1 ── "add a.txt"
              │
             c2 ── "add b.txt"        ← channel "main" HEAD currently here
              │
             c3 ── "fix typo"
```

Each commit (`commit.zig`'s `Commit`) carries:

- `snapshot: Hash` — the Merkle tree root for that commit's full file state.
  **Not** a diff — every commit's snapshot is a complete, addressable tree.
- `parents: []ParentInfo` — typed parent edges (`ParentKind`: `.normal`,
  `.merge`, `.cherry_pick`, `.rebase`, `.revert`). A root commit has zero
  parents. A normal, non-merge commit has exactly one, `.normal`.
- Author/committer metadata, `Intent`, title, etc. (via `CommitRequest`).

**Good to know:** because `snapshot` is a full tree, not a diff, diffing two
arbitrary commits (`diffCommits`) never needs to walk the graph between them
— it's a direct two-tree comparison (`merkle_mod.diffRoots`), independent of
how many commits separate them or whether one is even an ancestor of the
other.

---

## 3. The three worktree-facing layers, and why they can disagree

This is the part that caused the most confusion earlier in this project, so
it gets its own section.

```
   HEAD's snapshot          Staging's tree              Disk (worktree)
  ┌────────────────┐      ┌────────────────┐        ┌────────────────┐
  │ a.txt = "hello" │     │ a.txt = "hello"│        │ a.txt = "hello │
  │                 │     │                │        │        world"  │
  └────────────────┘      └────────────────┘        └────────────────┘
        committed              staged                  actually on disk
```

**Key fact: `commit()` never touches `staging`.** After a commit succeeds,
`self.staging` still holds exactly whatever blob hashes were last explicitly
`add()`ed — it does **not** reset to mirror the new HEAD, the way git's index
implicitly does right after a commit. This is a deliberate design point, not
an oversight, but it has a real consequence:

> **Good to know:** staging is decoupled from both HEAD _and_ disk,
> indefinitely, until something explicitly touches it (`add`, `unstage`,
> `remove`, `move`, `reset`, or `uncommit`'s `.keep`/`.mixed`/`.hard` modes).
> If you edit a tracked file on disk after committing but never re-`add` it,
> `status()` will show that file simultaneously "clean" relative to staging
> and "modified" relative to disk (`stateOf` catches this in the `unstaged`
> half of `Status`) — staging itself is silently stale and doesn't know it.

`stagingTreeRoot()` is the one function that turns "whatever staging
currently lists" into an actual Merkle tree, and it does so **every time
it's called**, never caching:

```zig
fn stagingTreeRoot(self: *Repository) !Hash {
    return merkle_mod.build(self.alloc, &self.page_store, self.staging.allEntries());
}
```

**Good to know:** this looks wasteful (why rebuild every call?) but isn't —
`PageStore.put` skips writing any page whose hash already exists on disk, so
rebuilding against unchanged staged content touches zero new storage. This
is why `commit`, `status`, and `diffStaged` all call it freely rather than
caching a tree on `Staging` itself — there is deliberately no cached tree to
go stale.

> **Good to know — a staged entry's `mtime` is load-bearing, not just
> informational.** `stateOf`/`status()` decide whether a tracked file is
> "clean" or "modified" in the `unstaged` sense by comparing the staged
> entry's recorded `mtime` (and size/mode) against a fresh `stat()` of the
> file on disk — not by rehashing file content on every call, which would be
> far more expensive. This means **any** code path that rewrites a tracked
> file's content on disk without also updating its staged entry's metadata
> will produce a false "modified" report on the next `status()` call, even
> when the content it just wrote is byte-for-byte identical to what's
> staged. `reset(.hard)` used to have exactly this bug — see
> `writeEntriesToWorktree` in §8 for how it's handled now.

---

## 4. Lifecycle: `init` vs `open`

```
              merk init                         merk <any other command>
                  │                                        │
                  ▼                                        ▼
         Repository.init(...)                     Repository.open(...)
                  │                                        │
    ┌─────────────┴─────────────┐             ┌────────────┴────────────┐
    │ probe: does a Focus file   │             │ read Focus file          │
    │ already exist here?        │             │                          │
    └─────────────┬─────────────┘             └────────────┬─────────────┘
          no │           │ yes                     no Focus │      Focus exists
             ▼           ▼                                  ▼             ▼
        create fresh   force?          error.NotARepository      symbolic → open
        repo, empty      │                                       detached → error.DetachedCurrent
        staging       ┌──┴──┐
                     no     yes
                      │      │
              error.Already  reinitialize:
              Initialized    empty staging,
                             keep "main"
```

`openInternal` is the shared core both paths funnel through. **Critical
implementation detail:** it allocates `Repository` on the heap
(`alloc.create(Repository)`) _before_ filling in fields, rather than building
a local value and returning it by value:

```zig
const self = try alloc.create(Repository);
// ... fill self.store, self.page_store, self.history, etc. in place ...
```

> **Good to know — this is load-bearing, not stylistic.** `History.init`
> takes `&self.store` and `&self.page_store` as pointers. If `Repository`
> were built as a local variable and returned by value, those pointers would
> point at the _local's_ address — which is copied to a new address on
> return, leaving `History`'s internal pointers dangling into a stack frame
> that no longer exists. This was an actual bug that was fixed by switching
> to heap allocation. Never refactor `openInternal` back toward
> return-by-value without re-deriving why this matters.
>
> This is the same class of hazard as a struct holding a slice into one of
> its _own_ fields (self-referential fields) and then being copied/moved —
> the slice's pointer doesn't follow the move. It has shown up more than
> once in this codebase in different guises (see the debug harness's
> `Sandbox` struct for another instance), so it's worth recognizing on
> sight: any struct where one field is computed as a pointer/slice derived
> from `&self.<other_field>` cannot safely be returned by value or copied
> after that field is set.

---

## 5. Cross-cutting pattern: validate everything, mutate nothing, until every check passes

Nearly every mutating method on `Repository` follows the same shape:

```
  1. Validate ALL inputs (paths well-formed, all paths tracked, etc.)
  2. Read/compute everything needed, without touching persistent state
  3. Only once every check has passed, begin mutating
  4. Persist (staging.save() / ref_store.update.../ worktree writes)
```

Examples already in the file: `unstagePaths` checks every path is tracked
_before_ removing any of them. `restorePaths` checks every path is tracked
and has a resolvable blob _before_ writing any file. `removePaths` checks
every path is tracked before deleting any worktree file.

> **Good to know — where this pattern was historically violated, and why it
> matters.** The original `reset()` called `ref_store.updateChannel(...)`
> **first**, then validated the target by reading the commit object
> **second**. If `target` was a bad hash (typo, wrong-repo hash, corrupt
> object), the ref had _already_ moved before the function found out the
> target wasn't a real, readable commit — leaving the channel pointed at
> something broken even though the caller sees a plain error return and
> reasonably assumes nothing happened. The fix moved `commit_mod.read(...)`
> to the very top, before any mutation, including before the `.soft`
> early-return (which previously never validated `target` at all). Same
> root cause was closed in `uncommit`'s `.keep` mode: `syncStagingFromDisk`
> checks every tracked path exists on disk _before_ rehashing/saving any of
> them, returning `error.TrackedPathsMissing` up front rather than silently
> dropping missing paths from the reconstructed tree.

---

## 6. `reset` vs `uncommit` — when to use which

These two are easy to conflate now that `uncommit`'s `.mixed`/`.hard` modes
delegate straight into `reset`. They answer different questions:

```
   reset(target, mode)                    uncommit(mode)
   ────────────────────                   ────────────────
   "move to THIS commit,                  "undo the MOST RECENT
    wherever it is in history"             commit specifically"

   target: caller-supplied Hash,          target: always HEAD's parent,
   anywhere in the graph                  computed internally — no
                                           target parameter at all

   no commit-undo guards                  refuses merge commits;
                                           treats "no parent" as ref
                                           deletion, not an error

   modes: .soft / .mixed / .hard          modes: .soft / .mixed / .hard
                                           (delegate to reset) PLUS
                                           .keep (own logic — reset has
                                           no equivalent)
```

`reset` is the general-purpose primitive: jump anywhere, no opinion about
_why_. `uncommit` is a guarded, narrower policy layer for exactly one
scenario (undo the last commit) with one mode (`.keep`) that `reset`
structurally cannot express, because `reset` only ever reconstructs state
_from a commit object_ — it has no concept of "look at what's currently on
disk right now."

> **Good to know — don't try to delete `reset` in favor of `uncommit`, or
> vice versa.** `uncommit` calling `reset` in a loop can't replace
> `reset(target)` for an arbitrary non-parent target — e.g. "go back three
> commits" or "jump to a specific tagged commit from last week" both need a
> caller-supplied hash, which `uncommit` deliberately doesn't take. Keeping
> both mirrors git's own split (`git reset <commit>` as the general tool; no
> single built-in "undo last commit" beyond `reset HEAD~1`) — merk's
> `uncommit` is the friendlier, guarded affordance git doesn't natively have.

---

## 7. `uncommit` mode reference

```
                    HEAD = C  (commit being undone)
                    parent = P (or none, if C is root)
                    W = current worktree/disk state

  .soft   ── ref moves to P (or deleted if root). Staging: UNTOUCHED.
             Worktree: UNTOUCHED.
             "Just move the pointer, I'll sort out the rest myself."

  .mixed  ── ref moves to P. Staging: rebuilt from P's committed tree
             (or emptied, if root). Worktree: UNTOUCHED.
             Delegates straight into reset(.{ target = P, .mode = .mixed }).

  .hard   ── ref moves to P. Staging: rebuilt from P's tree. Worktree:
             REWRITTEN to match P. Delegates into reset(.hard).
             At root: no P to fall back to — requires
             `confirm_root_hard = true` or refuses outright
             (error.RootHardUncommitRequiresConfirmation), since a root
             hard-uncommit deletes tracked files with nothing left in
             any reachable ref pointing at their content.

  .keep   ── ref moves to P (or deleted if root). Staging: rebuilt from
             CURRENT DISK CONTENT of every tracked path (via
             syncStagingFromDisk) — this is the one mode with no reset()
             equivalent. Worktree: untouched (it's already the source
             of truth for this mode).
             Fails with error.TrackedPathsMissing if any tracked path
             is missing from disk, rather than silently excluding it —
             a missing file might be a deliberate refactor/cleanup
             deletion, and only the caller can know which.
```

### Worked example: the scenario that motivated `.keep`

```
  commit A: a.txt = "hello"
  (no re-add after this)
  edit on disk: a.txt = "hello world"
  uncommit(.soft)   → staging still says a.txt = "hello" (was already
                       stale before uncommit even ran — see §3).
                       status() shows a.txt as BOTH staged-added AND
                       unstaged-modified. Nothing lost, just confusing.

  uncommit(.mixed)  → staging rebuilt from A's PARENT's tree (root here,
                       so staging emptied). Worktree still says
                       "hello world" but it's now completely untracked.

  uncommit(.keep)   → staging rehashed from disk: a.txt = "hello world"
                       becomes the new staged content. The post-commit
                       edit is preserved as the thing you'd commit next.
```

### Worked example: the deletion-safety case

```
  commit A: a.txt exists, tracked
  user deletes a.txt on disk (e.g. mid-refactor cleanup)
  uncommit(.keep)   → syncStagingFromDisk notices a.txt is tracked but
                       missing from disk → error.TrackedPathsMissing.
                       NOTHING moves — ref, staging, and the (already
                       user-deleted) file are all left exactly as they
                       were. User must explicitly `merk rm a.txt` first,
                       confirming the deletion was intentional, then
                       re-run uncommit.

  uncommit(.hard)   → by contrast, THIS mode intentionally can resurrect
                       a.txt: it rewrites the worktree from the PARENT
                       commit's tree, which still has a.txt. This is
                       documented, expected .hard behavior (matches
                       git's real reset --hard), not a bug — but it's the
                       one mode capable of silently undoing a deliberate
                       worktree deletion, so CLI help text for --hard
                       should say so plainly.
```

---

## 8. Method-by-method reference

### `init` / `open` / `openInternal`

See §4. `init` additionally handles the reinitialize-with-`force` path,
which clears staging via `replaceAll(&.{})` rather than any per-entry
teardown — a plain list clear, nothing that can fail with `NotFound`.

### `add(paths)`

```
validateRelativePath(p) for every p   →   staging.addFile(...) for every p
                                            (reads disk, hashes via
                                             store.putReader, upserts into
                                             staging's index)
                                       →   staging.save()
```

> **Good to know:** errors partway through leave already-staged paths
> staged — this method is _not_ all-or-nothing. If you need atomicity
> across a batch, snapshot `staging.allEntries()` first and be prepared to
> restore it on failure; nothing in `add` does this for you.

> **Good to know:** `addFile` hashes via `store.putReader(.blob, size,
file)` — this is content-addressed with type+size framing (git-style
> object hashing), **not** a plain hash of raw bytes. Don't assert
> `blob_hash == someHashFn(content)` in tests; verify by reading the blob
> back through `store.get()` instead.

> **Good to know:** `addFile` always re-`stat`s the file at the moment it's
> called, and that fresh `mtime`/`size`/`mode` is what gets recorded on the
> staged entry. If your code writes a file and calls `add` on it in the
> wrong order — `add` before the write that's meant to "finalize" its
> content — the staged entry's metadata will reflect the pre-write state,
> and the next `status()` will report it as modified even if that wasn't
> your intent. Order matters: write first, then `add`.

### `unstage` / `unstagePaths`

Validates every path is tracked before removing any (§5 pattern). `unstage`
is just `unstagePaths` with a one-element slice — exists for ergonomics.

### `removePaths(paths, options)`

Same validate-first shape. Unless `options.cached`, also deletes the
worktree file — tolerating `error.FileNotFound` (already gone is fine, still
untrack it) but propagating anything else.

### `movePath(from, to, options)`

```
validate from, to  →  reject from == to  →  from must be tracked
  →  to must NOT be tracked (unless options.force)
  →  rename on disk (creating parent dirs for `to` if needed)
  →  staging.remove(from) + staging.addFile(to)   [hash carries over
                                                    conceptually, but
                                                    addFile re-reads and
                                                    re-hashes — content
                                                    didn't change so the
                                                    resulting hash is the
                                                    same either way]
```

### `stagingTreeRoot()` — see §3. Private; the single chokepoint every

staged-tree consumer (`commit`, `status`, `diffStaged`) goes through.

### `commit(request)`

```
read current channel HEAD (may be null → root commit, zero parents)
build staging tree root (stagingTreeRoot)
history.commit(channel, tree_root, parents, request)  → new commit hash
```

Does **not** touch staging afterward (§3). Does **not** move the ref itself
— that's `history.commit`'s job internally (inferred from usage; not shown
in this file).

### `status()`

```
staged   = diffRoots(headSnapshot(), stagingTreeRoot())
unstaged = for each staging entry: staging.stateOf(root, entry);
           collect anything not .clean
```

Two independent comparisons — staged-vs-HEAD, and disk-vs-staged — which is
exactly why the "stale staging" scenario in §3 can produce entries in _both_
lists simultaneously for the same path.

### `diffCommits(from, to)` / `diffStaged()`

Direct two-snapshot diffs (§2 — no graph walk needed, snapshots are full
trees). `diffStaged` is `diffCommits(headSnapshot(), stagingTreeRoot())`
with a friendlier name, matching `status().staged`.

### `reset(options)` — see §5, §6. Current (fixed) shape:

```
1. commit_mod.read(target)         ← validates FIRST, for every mode
                                       (error.NotFound → error.RevNotFound)
2. if .soft: move ref, return
3. merkle_mod.collect(target's snapshot) → entries   ← still no mutation
4. move ref                         ← mutation begins only here
5. staging.replaceAll(entries)
6. if .hard: writeEntriesToWorktree()
     → writes each entry's content to disk, THEN re-stats the file it
       just wrote and updates that entry's size/mode/mtime in staging
       to match, then staging.save()  (see the dedicated entry below)
```

> **Good to know — residual, accepted gap.** Step 6's worktree write is
> still last and can fail partway through (disk full, permissions, one
> obstructed path among many). Each individual file write is atomic
> (temp+rename in `writeBlobToWorktree`), but the _set_ of files being
> updated is not — a mid-loop failure leaves ref+staging already pointing
> at the new target while the worktree only partially matches. Making this
> fully atomic would need a two-phase write (stage all temp files, then
> rename all of them only once every write has succeeded) — treated as not
> worth the complexity unless it's actually been hit in practice, but
> documented here so it isn't mistaken for "fully safe."

### `writeEntriesToWorktree(entries)` — private, `.hard`'s materialization

step, called only from `reset`.

```
snapshot the entries to write FIRST (path + blob_hash, owned copies)
  — mirrors syncStagingFromDisk's snapshot-before-iterate pattern:
    staging.put mutates staging's internal entry list in place, so
    iterating staging.allEntries() directly while calling put on each
    entry would be walking a slice being rewritten out from under you

for each snapshotted entry:
  writeBlobToWorktree(path, blob_hash)     ← writes file content
  stat the just-written file                ← fresh mtime/size/mode
  staging.put(path, blob_hash, fresh size/mode/mtime)
                                              ← re-syncs the STAGED
                                                ENTRY's metadata, not
                                                just the file on disk

staging.save()
```

> **Good to know — this is what makes `reset(.hard)`'s `status.unstaged`
> come back empty immediately afterward, and it's not automatic.**
> `writeBlobToWorktree` only ever touches file _content_ — it has no
> awareness of `Staging` at all. Without this second, explicit re-stat-and-
> resync pass, a freshly hard-reset file gets a brand-new OS `mtime` purely
> as a side effect of being rewritten, while its staged entry still carries
> whatever `mtime` it had _before_ the reset ran. Since `stateOf` compares
> mtimes (see §3's note on why `mtime` is load-bearing), every single file
> `reset(.hard)` touches would then come back falsely reported as
> "modified" — even though its content is byte-for-byte identical to what
> was just written from the target commit. This was an actual bug, caught
> by a debug-harness run showing `status.unstaged (1): modified a.txt`
> immediately after a `.hard` reset whose disk content already matched
> exactly. If you ever add another code path that rewrites tracked file
> content directly (bypassing `add`), it needs this same
> write-then-restat-then-resync treatment, or it will reintroduce the same
> class of false positive.

### `restorePaths(paths)`

Validate-first (every path tracked, every blob resolvable) → then write via
`writeBlobToWorktree` for each.

> **Good to know:** unlike `writeEntriesToWorktree`, `restorePaths` does
> **not** re-sync staged entry metadata after writing — and by design, it
> doesn't need to. `restorePaths` writes worktree content to match what's
> _already staged_, so the staged entry's `blob_hash` was already correct
> before the call; only the disk file was wrong. Once `writeBlobToWorktree`
> rewrites the file, its `mtime` still needs to be re-observed on the
> _next_ `status()` call for `stateOf` to see it as clean again — which
> happens naturally the next time anything re-stats it. If a future change
> makes `restorePaths` report stale "modified" state the way `reset(.hard)`
> used to, look here first.

### `writeBlobToWorktree(path, blob_hash)` — private, the single

materialization chokepoint used by both `writeEntriesToWorktree` (via
`reset(.hard)`) and `restorePaths`.

```
  read blob from store
  ensure parent dirs exist (NotDir → error.ObstructedPath)
  reject only if target path is occupied by a DIRECTORY
    (a stat error that ISN'T FileNotFound must propagate, not be
     swallowed as "safe to proceed")
  write to temp file  ".{basename}.merk-tmp-{nanotimestamp}"
  rename temp → real path   (atomic on POSIX; MOVEFILE_REPLACE_EXISTING
                              semantics on Windows per the code comment,
                              marked as unconfirmed — "?TO confime")
```

> **Good to know:** this is why a failed restore/reset never destroys
> existing content at `path` — the old file is only ever replaced by an
> atomic rename once the new content is fully written to a temp file first.
> A crash or error mid-write leaves the temp file orphaned (harmless
> garbage) and the original untouched. Note this function only ever
> produces file _content_ correctness — see `writeEntriesToWorktree` above
> for why callers that also need staged-metadata correctness (like
> `reset(.hard)`) do extra work on top of it rather than relying on this
> function alone.

### `log(filter)` — thin passthrough to `history.log(channel, filter)`.

### `head()` — thin passthrough to `ref_store.readChannel(channel)`.

Public specifically so every history-facing command (`show`, `commit`,
`uncommit`) reads HEAD _here_ rather than reaching into `ref_store`
directly — keeps "how do I find current HEAD" in exactly one place.

### `resolveRev(raw)`

```
try parse as full 64-char hex hash
  fail → try as an 8+-char prefix against the object store
           Ambiguous → error.AmbiguousRev
           NotFound  → error.RevNotFound
           other     → error.InvalidRev
```

The one place prefix-resolution logic lives — `show` and `diff --rev` both
go through this so a hash that resolves in one resolves identically in the
other.

### `uncommit(options)` — see §6, §7 for full behavior. Internal shape:

```
head_hash = head() orelse NoCommits
read head_hash's commit → c
c.parents.len > 1 → MergeCommit
parent_hash = c.parents[0].hash or null (root)

switch (mode):
  .soft   → nothing extra
  .keep   → syncStagingFromDisk()          [validates, then mutates]
  .mixed  → parent? reset(target=parent, .mixed) : staging.replaceAll(&.{})
  .hard   → parent? reset(target=parent, .hard)
                    : requires confirm_root_hard, else
                      RootHardUncommitRequiresConfirmation;
                      then deleteTrackedWorktreeFiles() + staging.replaceAll(&.{})

move/delete the ref (unless .mixed/.hard with a parent already did it
                      via their reset() call)
```

> **Good to know:** because `.mixed`/`.hard` delegate into `reset`, the
> `.hard` path also inherits `writeEntriesToWorktree`'s metadata resync for
> free — you don't need to (and shouldn't) duplicate that resync logic
> here. If `uncommit(.hard)` ever stops delegating to `reset` for some
> reason, re-derive whether the resync still needs to happen before
> shipping that change.

### `syncStagingFromDisk()` — private, `.keep`'s implementation.

```
snapshot current tracked paths (staging.allEntries() copied to an owned
  list FIRST — addFile mutates staging's internal entry list in place,
  so iterating allEntries() directly while calling addFile would be
  walking a slice being rewritten under you)
check every path exists on disk (cwd().access) → collect any missing
  any missing → error.TrackedPathsMissing, nothing further happens
all present → addFile (rehash from disk) for every path → staging.save()
```

> **Good to know:** this is the same snapshot-before-iterate shape as
> `writeEntriesToWorktree` (above) — both exist because the thing being
> iterated (`staging`'s entry list) is also the thing being mutated inside
> the loop. If you're writing a new method that walks `staging.allEntries()`
> and calls anything that touches staging inside that walk, copy this
> pattern rather than iterating the live list directly.

### `deleteTrackedWorktreeFiles()` — private, only used by root-commit

`.hard` uncommit (no parent tree to write instead, only nothing).

### `headSnapshot()` — private. `head() == null` → `crypto.zero_hash`

(the canonical "empty tree" sentinel used as the baseline for `status`/
`diffStaged` when there's no history yet).

---

## 9. Error-handling shape

Every public method returns a typed error from `RepositoryError`
(`errors_mod`), following the "Options-in / typed-error-out" pattern
documented in `errors.zig`. Concretely relevant patterns seen in this file:

- Raw errors from lower layers (`commit_mod.read`'s `error.NotFound`,
  `store`'s not-found variants) get **translated** at the `Repository`
  boundary into `RepositoryError` variants (`RevNotFound`, etc.) rather than
  leaking implementation-specific error sets upward. `resolveRev` and the
  fixed `reset` both do this explicitly via `catch |err| switch (err) {...}`.
- `errdefer` is used specifically where partial heap allocation could leak
  on a later failure within the same function (e.g. `collected` in `reset`,
  `unstaged` in `status`) — not as a blanket habit, only where there's
  actually something to clean up.

> **Good to know:** when adding a new failure mode, check whether it needs a
> new `RepositoryError` variant with its own doc comment (see
> `errors.zig`), rather than letting a lower-layer error type leak through
> `!void`/`!Hash` return types unchanged. The CLI layer's error→message
> mapping (`describe`) depends on every variant being accounted for
> exhaustively — `describe`'s compile-time exhaustive switch over
> `RepositoryError` is the enforcement mechanism for this.

---

## 10. Quick-reference: "what touches what"

| Method                       | Ref                   | Staging                                 | Worktree (disk)           | Object/Page store            |
| ---------------------------- | --------------------- | --------------------------------------- | ------------------------- | ---------------------------- |
| `add`                        | –                     | write                                   | read                      | write (blobs)                |
| `unstage(Paths)`             | –                     | write                                   | –                         | –                            |
| `removePaths`                | –                     | write                                   | delete (unless `.cached`) | –                            |
| `movePath`                   | –                     | write                                   | rename                    | write (re-hash)              |
| `commit`                     | write (via `history`) | **read only**                           | –                         | write (tree+commit)          |
| `status`                     | read                  | read                                    | read (via `stateOf`)      | read                         |
| `diffCommits` / `diffStaged` | read (staged variant) | read                                    | –                         | read                         |
| `reset(.soft)`               | write                 | –                                       | –                         | read (validates target)      |
| `reset(.mixed)`              | write                 | write                                   | –                         | read                         |
| `reset(.hard)`               | write                 | write (content **and** metadata resync) | write                     | read                         |
| `restorePaths`               | –                     | read                                    | write (content only)      | read                         |
| `uncommit(.soft)`            | write/delete          | –                                       | –                         | read (validates HEAD/parent) |
| `uncommit(.mixed)`           | write/delete          | write                                   | –                         | read                         |
| `uncommit(.hard)`            | write/delete          | write (content **and** metadata resync) | write                     | read                         |
| `uncommit(.keep)`            | write/delete          | write (from disk)                       | **read only**             | write (re-hash)              |

---
