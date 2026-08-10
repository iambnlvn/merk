# The Object object

**Modules:** `object_format.zig`, `object.zig`
**Audience:** anyone touching merk's storage layer, or deciding what to build on top of it

This document explains what these two files do, why they're split the way
they are, the reasoning behind every non-obvious decision in the format,
and where the design deliberately leaves room to grow. If you're about to
add a feature to the object object, read §7 (roadmap) first — there's a
decent chance the extension point you need already exists.

---

## 1. Why two files, and what each one owns

|                    | `object_format.zig`                 | `object.zig`                        |
| ------------------ | ----------------------------------- | ----------------------------------- |
| Knows about        | bytes in, bytes out                 | the filesystem                      |
| Doesn't know about | any filesystem, any I/O             | how bytes are encoded               |
| Given              | a payload + type + codec            | a hash                              |
| Produces           | encoded bytes + content hash        | a path, then delegates to `fs`      |
| Testable with      | pure `[]u8` fixtures, no I/O at all | `storage.TestFs`, an in-memory fake |

This split exists because encode/decode logic and filesystem-placement
logic have almost nothing in common and fail for completely different
reasons. A bug in `decodeFromBuffer` is a bytes-shape bug — reproducible
with a byte array in a unit test, no filesystem involved. A bug in
`object.put` is a _placement_ bug — wrong shard, wrong dedup check, wrong
path join. Keeping them in separate files means:

- `object_format.zig` tests run against raw byte buffers and catch format
  bugs immediately, without going through the (slower, more moving-parts)
  filesystem fake.
- `object.zig` can change _how_ objects are placed on disk (different
  sharding depth, a different root layout entirely) without touching a
  single byte of encode/decode logic, and vice versa.
- Nothing about the wire format assumes a particular storage backend.
  If merk ever wanted to back the object object with something other than
  a local filesystem (e.g. an object object service, a single packed
  file), `object_format.zig` doesn't change at all.

---

## 2. On-disk layout

```
<objects_dir>/<xx>/<yy>/<full-hex-content-hash>
```

`xx` is the first 2 hex characters of the content hash, `yy` the next 2.
This is the same two-level sharding scheme git uses for `.git/objects/`,
for the same reason: BLAKE3 output is uniformly distributed, so sharding
by hash prefix spreads objects evenly across `256 * 256 = 65,536`
directories. Without this, a repository with hundreds of thousands of
objects would put all of them in one directory, and most filesystems
degrade badly (linear directory scans, inode table pressure) well before
that count.

Two levels was chosen over one or three as a reasonable middle ground —
one level (`256` dirs) still gets uncomfortable in the tens-of-thousands
range; three levels (`16.7M` dirs) is solving a problem this project
doesn't have yet. If object counts ever get large enough to matter, this
is a config-level tweak (see §7), not an architectural one.

`object` never manages temp files, fsync, or atomic rename itself —
every write goes through `FileSystem.writeFile`, which owns that
responsibility (see `RealFs.writeFileImpl`'s temp-file-then-rename
dance). This is a deliberate boundary: `object` should never need to know
_how_ a write becomes durable, only that `writeFile` guarantees it. If
that guarantee ever needs to change (e.g. adding fsync-on-directory for
crash consistency of the rename itself), it changes in one place.

---

## 3. The object header

Every encoded object starts with a fixed 16-byte header:

| Offset | Size | Field         | Notes                                                      |
| -----: | ---: | ------------- | ---------------------------------------------------------- |
|      0 |    4 | `magic`       | `0x4D_45_52_4B` ("MERK"), little-endian                    |
|      4 |    1 | `version`     | Currently `2`                                              |
|      5 |    1 | `type`        | `ObjectType` — blob / tree / commit / ast                  |
|      6 |    1 | `codec`       | Compression codec used for the body                        |
|      7 |    1 | `flags`       | Bit 0: structural hash trailer present. Bits 1-7: reserved |
|      8 |    4 | `payload_len` | Uncompressed length, u32                                   |
|     12 |    4 | `stored_len`  | On-disk length of the body, u32                            |

Followed by the body and one or two 32-byte BLAKE3 trailers:

```
[ header: 16 bytes ]
[ stored body: stored_len bytes, raw or compressed per codec ]
[ content hash: 32 bytes ]
[ structural hash: 32 bytes, present iff flags bit 0 is set ]
```

### Why a fixed-width header at all?

Two operations in this module are specifically designed to _avoid_
reading the full object: `getHeader()` and `getStructuralHash()`. Both
need to answer a question ("what type is this?", "does this have a
structural hash?") by reading a small, precisely-known number of bytes
from a precisely-known offset — no parsing, no scanning for delimiters.
A fixed-width header with fixed-width trailers is what makes "peek at
just this field" a single `readRange(path, offset, length)` call instead
of "read the whole file and parse forward until you hit what you want."

For large objects (a sizeable `ast` payload, a big `commit` body), this
is the difference between a few dozen bytes of I/O and reading megabytes
just to answer "is this an ast object with a structural hash?"

### `magic` and why it's checked first

`magic` exists purely as a fast, cheap sanity check: if the first 4 bytes
of a file aren't `MERK`, this almost certainly isn't a merk object at
all (wrong file, truncated write, filesystem corruption pointing at
garbage) — and cheap to detect before spending any more effort trying
to interpret the rest as a header.

### `version` vs. `flags`: two different extension mechanisms

This is the header's most important design decision, so it's worth
being explicit about the contract:

- **`version` gates the header _layout_.** If a future change moves
  fields around, changes `header_len`, or otherwise makes the byte
  layout different, that's a version bump. An old reader seeing a
  `version` it doesn't recognize returns `error.UnsupportedVersion` —
  deliberately a _different_ error from `error.CorruptObject`, because
  "I don't know how to read this" and "this is garbage" call for
  different responses from calling code (the former might mean "upgrade
  the tool"; the latter means "this file is actually broken").

- **`flags` is a softer, additive extension point.** A new flag bit
  that doesn't add new on-disk bytes — a pure metadata toggle — doesn't
  need a version bump at all. `decodeHeaderFromBuffer` masks flags into
  known fields and _ignores_ bits it doesn't recognize, rather than
  rejecting them. This means a hypothetical future version that sets an
  additional flag bit (with no new trailer) still decodes cleanly under
  this version's reader — forward compatibility, without a version bump,
  for that specific class of change.

**The hard limit on that guarantee:** it only covers flags that add zero
additional bytes. `decodeFromBuffer`'s expected total length is computed
from the flags _this_ version understands (today: content hash, plus
structural hash iff bit 0 is set). A future flag that appends its own
trailer still requires a version bump, because there is no way for an
old reader to know how many extra bytes to skip past — it would either
misinterpret those bytes as something else, or (if they happen to be
last) fail the length check and reject the object outright. This
distinction is deliberately documented here because it's easy to reach
for "just add a flag bit" as a way to avoid ever bumping `VERSION`, and
that only works for a specific, narrow kind of change.

_(This module previously took the opposite, stricter position —
rejecting any unrecognized flag bit outright. That was reconsidered:
it made every future flag bit a breaking change by construction, which
defeats having a flags byte in the first place. The current
ignore-unknown-bits behavior is the corrected design.)_

### Type and codec bytes: validated, not trusted

```zig
const obj_type = std.meta.intToEnum(ObjectType, bytes[5]) catch return error.CorruptObject;
const codec = std.meta.intToEnum(compression.Codec, bytes[6]) catch return error.CorruptObject;
```

These bytes come straight off disk and are treated as hostile input —
they might be corrupted, bit-rotted, or (in a `verifyAll()` scan)
_exactly the thing being tested for_. `std.meta.intToEnum` is used
deliberately instead of `@enumFromInt`: the latter is a safety-checked
panic in Debug/ReleaseSafe builds and **undefined behavior in
ReleaseFast** when the byte doesn't correspond to a real enum tag. A
corrupted object file should never be able to crash the process or
trigger UB — it should cleanly surface as `error.CorruptObject`, exactly
like every other "this file is bad" condition. This is the single most
important safety property of the header decoder, and the reason
`decodeHeaderFromBuffer` is the _only_ place these bytes are ever
interpreted as their enum types.

---

## 4. The content hash

```
content_hash = BLAKE3(type_byte ++ uncompressed_payload)
```

This is the identifier that names an object on disk — its path is
derived entirely from this hash.

**Why hash the type byte, not just the payload?** Two objects with
identical bytes but different types (say, a `tree` encoding that happens
to produce the exact same byte sequence as some `blob`'s content) would
otherwise collide on the same content hash, and therefore the same file
path — meaning whichever was written second would either silently
overwrite the first, or (worse) get treated as a duplicate and skipped,
silently discarding the fact that this content also exists as the other
type. Folding the type into the hash makes the _identity_ of an object a
function of both "what bytes" and "interpreted as what" — the same
insight that keeps git's blob/tree/commit hashes from colliding as
readily as raw content hashes would.

**Why hash the payload, not the compressed/stored bytes?** So that
identity is compression-agnostic. `compression.choose()` picking a
different codec for the same payload — because the heuristic changed,
or because the same content crossed a size threshold on a different
occasion — never changes the resulting hash. This matters because
`compression.choose` is exactly the kind of internal heuristic that's
expected to be tuned over time; if object identity depended on its
output, every tuning change would silently fork previously-identical
objects into differently-hashed ones.

**Self-verification.** `decodeFromBuffer` recomputes this hash after
decompression and rejects the object with `error.HashMismatch` on any
discrepancy. This is what makes bit-rot and tampering _detectable_
rather than silently trusted — and it's the mechanism `verifyAll()`
relies on for its integrity scan.

---

## 5. Structural hashes

### The problem this solves

Content hashing can only answer "did the bytes change?" It has no way to
answer "did the _meaning_ change?" Reformatting a source file — different
whitespace, comments added or removed, maybe identifiers renamed if you
canonicalize them — produces a completely different content hash even
when the resulting AST is semantically identical. Git has no native
concept of this at all; approximating it means shelling out to an
external tool, computing ASTs yourself, and diffing them out-of-band,
with no help from the object object.

### The mechanism, and where the line is drawn

An `ast` object (in principle any object type, though `ast` is the
motivating case) can carry a second, optional 32-byte trailer: the
`structural_hash`. Critically, **this module has no opinion about what
"structural" means.** It doesn't parse ASTs, doesn't normalize anything,
doesn't know what counts as a semantically-irrelevant difference. The
caller computes `structural_hash` however it sees fit — `blake3(normalize(ast))`,
or something more elaborate — and this module's entire job is to object
it, retrieve it cheaply, and (via `object`) index it. That boundary is
deliberate: normalization policy is a concern of the AST-producing layer,
not the storage layer, and keeping this module ignorant of it means the
normalization strategy can evolve freely without ever touching
`object_format.zig` or `object.zig`.

### Why a flag bit + optional trailer, not a separate object type

The alternative would be something like an `ast_with_structural_hash`
`ObjectType`, or a wrapper object that references a plain `ast` object
plus its hash. Both add real complexity — every consumer of `ObjectType`
now has an extra case to handle, or every structural-hash lookup requires
an extra indirection through a wrapper object — for a property that's
naturally _optional metadata on an object_, not a distinct kind of
object. A flag bit plus an optional trailer models that directly: the
object is still exactly the same `ast` object whether or not it happens
to carry this extra hash, which is exactly the mental model callers
should have.

### The trust boundary this creates

Unlike the content hash, **the structural hash is never independently
verified.** `decodeFromBuffer` has no way to recompute it — it doesn't
know how the caller normalized whatever it hashed — so it simply
round-trips whatever bytes were stored. A bit-flip or deliberate tamper
in that trailer is currently undetectable by this module. This is
documented explicitly (both here and in the module's own doc comments)
because it's the kind of gap that's easy to forget once the API "just
works": `object.findByStructuralHash` trusts this trailer completely, and
anything built on top of it inherits that trust. See §7 for a possible
future mitigation.

---

## 6. The structural-hash side-index

### Why not just scan the object?

The first implementation of "find every object sharing this structural
hash" was a linear scan: walk every object in `objects_dir`, read each
one's structural hash, compare. It's correct, and it's the obvious thing
to reach for first — but it's `O(n)` in total object count, with two
targeted reads per object along the way. That's fine for a test fixture
with a handful of objects. It's the wrong shape for a lookup that might
sit on a hot path — detecting "was this file just reformatted" during a
merge or diff, for instance, is exactly the kind of check you'd want to
be cheap enough to do unconditionally, not something that gets more
expensive as the repository grows.

### The design: a flat, sharded, unparsed index

```
structural_index/<xx>/<yy>/<full-hex-structural-hash>
```

Sharded the same way as `objects_dir`, for the same directory-size
reasons. Each file is nothing more than a flat concatenation of 32-byte
object hashes — no delimiters, no length prefix, no header. This mirrors
the object format's own "no parsing needed" philosophy: reading the
index for a given structural hash is one `readFile` and a
`length / 32` loop. There's genuinely nothing to decode.

This directory is a **sibling** of `objects_dir`, never nested inside
it — this is load-bearing, not incidental. `count()`, `totalSize()`, and
`verifyAll()` all list `objects_dir` and assume every entry they see is
shaped like a loose object (`isObjectFileName` checks for exactly that
shape). If the index lived inside `objects_dir`, every one of those
functions would need to explicitly filter it out, and any future
function that lists `objects_dir` would need to remember to do the same.
Keeping it a sibling makes "things that scan the object object" and
"things that touch the index" structurally incapable of stepping on each
other.

### Write path

`object.putWithStructuralHash`:

1. Encode + write the object (skipped if it already exists — ordinary
   content-addressed dedup, unrelated to structural hashing).
2. If a structural hash was supplied, append the resulting object's
   content hash to that structural hash's index file — _even if step 1
   was a no-op because the object already existed._ This matters: the
   first time a given piece of content is written and the first time a
   structural hash gets associated with it are not necessarily the same
   event. The same `ast` payload might first be stored via plain `put`
   (no structural hash at all), and only later get `putWithStructuralHash`
   called on it once a caller has computed one. If the index update were
   skipped whenever the object already existed, that second call would
   silently fail to register the object under its structural hash.

Appending is de-duplicated: before writing, the existing index file (if
any) is linear-scanned for the incoming hash, and the write is skipped
entirely if it's already present. This matters because
`FileSystem.writeFile` replaces a file's entire contents atomically —
there's no append primitive to build on — so "append" here genuinely
means "read the whole file, decide, maybe rewrite the whole file." For
the realistic size of these files (a handful to a few dozen entries per
structural hash), that's a non-issue; see §7 for where this stops being
true.

### Read path

`object.findByStructuralHash` is a single `readFile` against the
computed index path. A missing file returns an empty result, not an
error — "nobody has ever registered this structural hash" and "this
structural hash has zero current members" are treated as the same
observable state, deliberately, so callers never need a special case for
"index file doesn't exist yet."

### Delete path

`object.delete` now does two things instead of one: look up the object's
structural hash _before_ deleting it (tolerating "object doesn't exist"
or "no structural hash" as a no-op via `catch null`), then prune that
hash's entry from its index file — deleting the index file outright if
it was the last remaining entry, rather than leaving an empty file
behind. This preserves the same invariant from the read path: a
structural hash with no current members looks identical whether it
never existed or every member was deleted.

### Deliberately accepted trade-offs

- **No locking.** Everything here — `object` in general, this index in
  particular — assumes a single writer. A concurrent `put`/`delete`
  racing on the same structural hash's index file can lose an update.
  This is not a new risk introduced by the index; it's the same
  assumption the rest of the module already makes (there's no locking
  around ordinary object writes either).
- **Read-modify-write, not true append.** Already covered above — cheap
  today, first thing to revisit if a single structural hash ever
  accumulates a large number of members (see §7).
- **Index/object divergence is currently unmonitored.** If a crash
  happens mid-write, or an object is removed by means other than
  `object.delete` (direct filesystem surgery, a bug, manual intervention),
  nothing today detects that the index and the actual object object have
  drifted apart. `verifyAll()` only checks content hashes against object
  bodies; it says nothing about whether the structural index is
  consistent with reality. This is the single biggest "known gap" in the
  current design (see §7, "index consistency checker").
- **The delete-time index prune is best-effort, not transactional.**
  `object.delete` swallows a failed index-removal write (`catch {}`)
  rather than aborting the object delete — so the object always actually
  gets deleted (preserving its existing error contract), but a failed
  prune (disk full, permission error) can leave a stale index entry
  pointing at an object that no longer exists. `findByStructuralHash`
  has no way to know this happened.

---

## 7. Roadmap

Roughly ordered by how directly they extend what's already here, not by
priority — pick based on what's actually needed next.

### Near-term, low-risk extensions

**Index consistency checker.** The most obvious gap called out above.
A `object.verifyStructuralIndex()` (or an extension to `verifyAll()`)
that walks `structural_index/`, confirms every referenced object hash
still exists in `objects_dir` and still carries the structural hash its
index file claims, and reports (or prunes) anything stale. This is the
natural next thing to build before this feature sees real load, since
it's currently the only part of the system with zero self-healing.

**Per-type statistics.** `count()`/`totalSize()` already answer "how
much is here" — extending them to break down by `ObjectType` (blob/tree/
commit/ast counts and byte totals individually) is a small addition on
top of the existing scan in each, and answers a question ("what does
this repository's object graph actually look like") that currently has
no built-in answer at all — you'd otherwise reach for ad-hoc scripting
over the raw directory tree.

**Structural-hash trailer integrity.** Since this module can't
recompute the structural hash itself, it can't verify it the way it
verifies the content hash — but it _could_ at least detect bit-rot in
the trailer bytes themselves (as opposed to semantic tampering, which is
out of scope regardless) by storing a checksum over the trailer. Worth
revisiting once there's a concrete normalization step to build against,
so the checksum's scope is well-defined.

### Medium-term architectural changes

**Hash agility.** Add an `algo: u8` byte to the header (BLAKE3 = 0
today), and have both `Hash` and `decodeFromBuffer`'s verification
dispatch on it. This is cheap to add _now_, while there's exactly one
hash algorithm in use anywhere, and expensive to retrofit once tooling,
on-disk data, and assumptions about hash length are baked in everywhere
— this is the shape of migration git is still living through with
SHA-1 → SHA-256, years later. If this is ever going to happen, doing it
before the format sees much real data is the cheap window.

**Content-defined chunked manifests.** For large payloads (big binary
assets, generated files, sizeable logs), splitting at write time into
content-defined chunks and storing a small manifest object referencing
child chunk hashes would let two large files sharing most of their
content dedupe at the chunk level automatically — no packfile/repack
step, ever, unlike git's model where this is bolted on after the fact.
`noOpChunk` in `object_format.zig` is a placeholder marking exactly where
a real chunking callback would plug into `compression.encodeBody` — the
seam already exists, it's just unused.

**Bloom-filter-backed existence index.** `exists()` and
`resolveHashPrefix()` currently cost a filesystem stat or directory
listing. At large object counts, an in-memory (periodically persisted)
Bloom filter over all known hashes, rebuilt incrementally on `put`/
`delete`, turns "is this hash anywhere in the object" into an O(1)
negative check. Only worth building once directory-listing costs are
actually observed to matter — premature before then.

### Larger, more speculative features

**TTL / ephemeral objects with automatic GC.** Some writes are never
meant to be permanent — scratch snapshots mid-operation, speculative
merge previews, build artifacts. Marking these as ephemeral with an
expiry, plus a `object.sweepExpired()`, gives the object a concept git has
none of: everything in git's object object is either referenced or
dangling-until-gc, with no notion of "this was always meant to be
temporary." Would need a small addition to the header (or a side-index
much like the structural-hash one) to track expiry without touching the
core format.

**Envelope encryption codec.** A new `codec` variant — `encrypted`,
alongside `none` and the existing compression codecs — where the stored
bytes are ciphertext but the _content hash_ is still computed over the
plaintext payload, preserving every existing dedup and addressing
guarantee while making the objects directory opaque at rest. This is a
genuinely different trust model (repo-level key management enters the
picture) and probably the largest change on this list in terms of what
it touches outside this module, but the format already has the right
extension point (`codec` is already a first-class, per-object field) —
it's a new enum value and a new channel in `compressAlloc`/`decodeAlloc`,
not a format redesign.

---

## 8. `object` API reference

| Function                                   | Cost                           | Notes                                            |
| ------------------------------------------ | ------------------------------ | ------------------------------------------------ |
| `put(type, payload)`                       | 1 write, skipped if exists     | No structural hash                               |
| `putWithStructuralHash(type, payload, sh)` | 1 write + 1 index read/write   | `sh` optional; `null` behaves exactly like `put` |
| `get(hash)`                                | 1 read + decompress            | Full object, content-hash verified               |
| `getHeader(hash)`                          | 1 range read (16 bytes)        | No decompression                                 |
| `getStructuralHash(hash)`                  | 1-2 range reads                | Header, then trailer only if flagged             |
| `findByStructuralHash(sh)`                 | 1 read                         | Index lookup, not a object scan                  |
| `exists(hash)`                             | 1 stat                         |                                                  |
| `delete(hash)`                             | 1-2 reads + 1-2 writes/deletes | Also prunes the side-index, best-effort          |
| `count()` / `totalSize()`                  | 1 directory listing            | Object object only; index is invisible to these  |
| `verifyAll()`                              | Full scan + decode             | Content-hash verification only, today            |
| `resolveHashPrefix(prefix)`                | 1 shard directory listing      | `Ambiguous`/`NotFound` on 0 or 2+ matches        |

## 9. Compatibility guarantees, stated plainly

- Objects encoded before this feature existed have `flags = 0`, decode
  with `structural_hash = null`, and are otherwise byte-for-byte
  unchanged — no migration step, no version bump was needed for this
  feature specifically.
- An empty or entirely-missing `structural_index/` directory is
  indistinguishable from "no object has ever had a structural hash" —
  exactly the pre-feature state — so nothing needs to special-case a
  freshly-initialized repository versus one that's simply never used
  this feature.
