# Commits

`commit.zig` (plus its `commit/` submodules) is how merk creates and
reads commits. This document explains the on-disk format, the public
API, and how to extend the format without breaking old commits or old
binaries.

Merk terminology note: a merk "Snapshot" is git's "tree", "Fuse" is
git's "merge", "Transplant" is git's "cherry-pick", "Replay" is git's
"rebase". The wire format and code below still use the familiar
git-adjacent names (`snapshot`, `merge`, `cherry_pick`, `rebase`) since
that's what the type/field names in code use.

## Why this isn't git's commit model

Two decisions shape everything else in this module:

1. **A commit points at a snapshot, not a tree.** In git, a commit's
   tree reference is itself a recursive structure of blobs and
   subtrees, so the commit format and the storage format are
   entangled. In merk, `Commit.snapshot` is a single opaque 32-byte
   hash. `commit.zig` has no idea what produced it (a Merkle B-tree
   today, potentially something else tomorrow) and never looks past
   it. Callers resolve their own snapshot root elsewhere and hand it
   to `CommitBuilder.init` like any other field.

2. **Parents are typed, not bare hashes.** Git's `parents` list is
   flat — a merge is only distinguishable from an ordinary commit by
   having more than one entry, and cherry-picks, rebases, and reverts
   leave no structural trace at all. Merk's `ParentInfo` carries a
   `ParentKind` next to each hash, so "why does this edge exist" is
   commit data, queryable directly, not something history tooling has
   to infer from a diff or a message convention.

## Module layout

```
commit.zig              CommitBuilder, CommitRequest, read(), Commit
commit/wire.zig          shared length-prefixed read/write helpers
commit/snapshot.zig       Hash serialize/deserialize (no wrapper type)
commit/parent.zig         ParentKind, ParentInfo, parent list (de)serialization
commit/identity.zig       author/committer: IdentityInfo, Identity, CommitIdentity
commit/metadata.zig       Intent, timestamp, labels: CommitMetadataInfo/CommitMetadata
commit/message.zig        title, body, trailers: MessageInfo/Message, TrailerInfo/Trailer
commit/testing.zig        MockReader, used only by submodule unit tests
```

Every field type follows the same three-piece shape:

- an **`...Info` struct** — what a caller supplies. Borrowed slices,
  validated but not yet persisted (`MessageInfo`, `ParentInfo`,
  `CommitMetadataInfo`, ...).
- **`serialize` / `deserialize`** over `anytype` readers/writers,
  built on the shared helpers in `commit/wire.zig` (length-prefixed
  strings, counted arrays, the `timestamp_ms == 0` auto-fill
  convention).
- an **owned result type**, read back from storage and freed with
  `.deinit` (`Message`, `CommitIdentity`, `CommitMetadata`, `Commit`
  itself).

`commit.zig` composes these; it doesn't reimplement any of them.

## Wire format

A commit object's payload, in order:

| Field              | Encoding                                                                                                      |
| ------------------ | ------------------------------------------------------------------------------------------------------------- |
| magic              | `u32` little-endian, `0x4E4F4455`                                                                             |
| version            | `u8`, currently `1`                                                                                           |
| snapshot           | 32 raw bytes (`commit/snapshot.zig`)                                                                          |
| parents            | `u8` count, then each as 32-byte hash + `u8` `ParentKind`                                                     |
| author             | `u16`-len name, `u16`-len email, `i64` timestamp (ms)                                                         |
| committer          | same shape as author — always written, even when the caller didn't set one (see "Committer defaulting" below) |
| metadata timestamp | `i64` (ms)                                                                                                    |
| intent             | `u8` (`Intent` enum)                                                                                          |
| labels             | `u16` count, then each as `u16`-len string                                                                    |
| title              | `u16`-len string                                                                                              |
| body               | `u32`-len string                                                                                              |
| trailers           | `u8` count, then each as `u8`-len key + `u16`-len value                                                       |

Reading is strict: an unrecognized `magic` is `error.CorruptCommit`,
and a `version` merk doesn't understand is
`error.UnsupportedCommitVersion` — merk never guesses at a format
it doesn't recognize (see "Versioning and extensibility" below).

### Committer defaulting

`CommitIdentityInfo.committer` is `null` when a caller never calls
`.committer(...)` on the builder. At serialization time a `null`
committer is filled in with a copy of the author's name/email/
timestamp, so the wire format is always symmetric (author and
committer are both always present on disk) even though the _input_
API lets committer be omitted. `CommitIdentity.isAuthorCommitter()`
tells a reader whether the two ended up identical, which is the
common case for an ordinary (non-transplant, non-replay) commit.

### Timestamp auto-fill

Both `TimestampedIdentityInfo.timestamp_ms` and
`CommitMetadataInfo.timestamp_ms` treat `0` as "use current wall-clock
time at serialization", via `wire.resolveTimestampMs`. `CommitBuilder`
doesn't rely on this for the metadata timestamp — it defaults to the
_author's_ timestamp when `.timestamp()` isn't called, which is
usually what you want (the metadata timestamp and the author
timestamp agreeing) — but the `0`-means-now convention is still there
for any caller building `CommitMetadataInfo`/`TimestampedIdentityInfo`
directly.

## Public API

### Creating a commit

`CommitBuilder` is the only supported way to build a commit — there is
no public function that accepts a hand-assembled commit struct. This
is deliberate: required-field checks, committer/timestamp defaulting,
and validation all live in one place instead of being re-derived by
every caller.

```zig
var b = CommitBuilder.init(alloc, snapshot_root);
defer b.deinit();
_ = b.author("Ada Lovelace", "ada@lab.net", now_ms);
_ = b.intent(.feature);
_ = b.title("Add builder API");
_ = try b.trailer("closes", "#42");
const commit_hash = try b.write(&store);
```

Required fields — snapshot, author, title, intent — aren't checked
until `.write()`, where a missing one fails loudly:

| Missing                        | Error                   |
| ------------------------------ | ----------------------- |
| snapshot (still the zero hash) | `error.MissingSnapshot` |
| author                         | `error.MissingAuthor`   |
| title                          | `error.MissingTitle`    |
| intent                         | `error.MissingIntent`   |

`error.MissingSnapshot` fires specifically on the zero-hash sentinel
(`crypto.zero_hash`). The builder has no way to know whether some
other, non-zero hash is actually valid or saved anywhere — that's the
snapshot/tree implementation's job — but the zero hash unambiguously
means "nothing was ever set."

Parents default to `.normal` via `.parent()`; use `.parentWithKind()`
(or the batch forms `.parentsFrom()` / `.parentsWithKind()`) for
merges, transplants (cherry-picks), replays (rebases), and reverts:

```zig
_ = try b.parentWithKind(base_hash, .normal);
_ = try b.parentWithKind(other_channel_hash, .merge);
```

### Building from a `CommitRequest`

Most callers (a CLI command, `Repository.commit`) already have
author/committer/intent/title/body/labels/trailers bundled up from
user input, independent of snapshot/parent resolution (which is
usually a separate step — reading Current, resolving the current
snapshot root). `CommitRequest` captures exactly that bundle:

```zig
pub const CommitRequest = struct {
    author_name: []const u8,
    author_email: []const u8,
    author_timestamp_ms: i64,
    committer_name: ?[]const u8 = null,
    committer_email: ?[]const u8 = null,
    committer_timestamp_ms: ?i64 = null,
    intent: Intent,
    title: []const u8,
    body: []const u8 = "",
    labels: []const []const u8 = &.{},
    trailers: []const TrailerInfo = &.{},
};
```

If the snapshot root is already resolved when the request is built,
use the one-call shortcut:

```zig
var b = try CommitBuilder.fromRequest(alloc, snapshot_root, request);
defer b.deinit();
const commit_hash = try b.write(&store);
```

Otherwise, `applyRequest` does the same thing as a second step (e.g.
if the builder needs to exist before the snapshot is known, or parents
need to be added between construction and applying the request):

```zig
var b = CommitBuilder.init(alloc, snapshot_root);
defer b.deinit();
_ = try b.applyRequest(request);
const commit_hash = try b.write(&store);
```

Either way, parents are still added separately via `.parent()` /
`.parentWithKind()` — `CommitRequest` intentionally doesn't carry
them, since parent resolution tends to be specific to the caller
(a plain commit vs. a fuse vs. a transplant), not something a generic
request struct should have an opinion about.

### Reading a commit

```zig
var c = try commit.read(alloc, &store, commit_hash);
defer c.deinit(alloc);
```

`read` returns `error.WrongObjectType` if the hash points at something
other than a commit object, `error.CorruptCommit` for a bad magic
number or an out-of-range enum byte, and
`error.UnsupportedCommitVersion` for a version this build doesn't
know how to parse.

`Commit` carries a few small helpers for the common "what kind of node
in the history graph is this" questions, so callers doing simple graph
work don't each re-derive them:

```zig
c.isRoot();                     // true: no parents
c.isMerge();                    // true: more than one parent
try c.parentHashesAlloc(alloc); // owned []Hash, ParentKind dropped
```

`isMerge()` only reports parent _count_ — it doesn't imply every
parent is tagged `.merge`. A commit can have two parents without
either being `.merge`, and a single non-`.normal` parent (e.g. a
`.cherry_pick`) isn't a merge. Check `parents[i].kind` directly when
the distinction matters.

For trailer lookups, `Message.trailer(key)` returns the first match,
and `Message.trailersFor(key, &out, alloc)` collects every match (a
commit can carry more than one `closes` trailer, for instance).

## Validation

Every submodule validates its own borrowed `...Info` struct before
it's allowed to serialize, and `CommitInfo.validate()` in `commit.zig`
just calls each of them in turn. A sample of what's enforced:

- **Identity** (`commit/identity.zig`): non-empty, length-bounded
  name/email; no control characters or `<`/`>` in the name; a
  syntactically sane single `@` in the email.
- **Message** (`commit/message.zig`): non-empty title after trimming;
  no newlines/nulls in the title (prevents header injection); trailer
  keys are printable ASCII with no colon or whitespace.
- **Metadata** (`commit/metadata.zig`): label count and length bounds.
- **Parents** (`commit/parent.zig`): no more than `MAX_PARENTS` (255)
  entries.

All of this runs both at write time (on the caller-supplied `Info`
structs) and again at read time (on the bytes just deserialized,
before they're handed back as an owned struct) — corrupt or
hand-edited object files are caught on the way out, not just on the
way in.

## Versioning and extensibility

`COMMIT_VERSION` is checked exactly, not range-checked: a version this
build doesn't recognize is `error.UnsupportedCommitVersion`, not a
best-effort partial read. Merk fails closed here so that an old binary
reading a commit written by a newer one never silently misinterprets
fields it doesn't know about.

To add a new field to the commit (say, a detached signature):

1. Write `commit/signature.zig` following the three-piece shape above
   — `commit/parent.zig` is the smallest complete example to copy.
2. Add it to the private `CommitInfo` struct and the public `Commit`
   struct in `commit.zig`, and call its serialize/deserialize from
   `writeCommit` / `read` in the same field order on both sides.
3. Add a setter on `CommitBuilder` (and a `CommitRequest` field, if
   it's something an ordinary caller supplies directly) and fold it
   into `build()`'s required/defaulted-field logic if it needs
   validation beyond what the submodule already does.
4. Bump `COMMIT_VERSION` and channel on it in `read` if the new field
   changes the wire layout for existing commits (as opposed to being
   safely omittable, e.g. an empty count for a brand-new counted
   list).

Growing an existing field's _range_ of values — a new `ParentKind`
variant, a new `Intent` — never touches `commit.zig` at all, since
those enums live in their own submodules for exactly this reason.
Adding one is a one-line enum change plus whatever validation/wire
logic the submodule already has; `commit.zig` just passes the byte
through.

## Testing

`commit.zig`'s own tests exercise the whole write → store → read →
assert round-trip using `storage.TestFs` (an in-memory filesystem) and a
real `Store`. Each submodule additionally unit-tests its own
`validate`/`serialize`/`deserialize` in isolation, using
`commit/testing.zig`'s `MockReader` over hand-built byte buffers —
this is what pins down the exact wire layout (see the byte-for-byte
expected buffers in `identity.zig`, `message.zig`, and
`metadata.zig`'s tests) and what exercises corrupt-input paths
(truncated buffers, out-of-range enum bytes) without needing a real
store at all.
