# nbt-zig

High-performance [Named Binary Tag](https://minecraft.wiki/w/NBT_format) codec for Zig 0.17, with first-class support for Minecraft Java and Bedrock formats.

<p align="center">
  <a href="https://discord.gg/Yv9qPRQNc3">Join the Bedrock Phanatics Discord</a>
</p>

* Java, Bedrock, and Bedrock Network NBT
* GZip and ZLib compression
* Explicit allocator ownership
* Configurable decode limits for untrusted input
* Reader/writer adapters
* Tested, fuzzed, and benchmarked in CI

## Usage

```zig
const std = @import("std");
const nbt = @import("nbt");

fn load(allocator: std.mem.Allocator, data: []const u8) !void {
    var document = try nbt.parse(
        allocator,
        data,
        nbt.Options.bedrock,
    );
    defer document.deinit(allocator);

    const encoded = try nbt.serialize(
        allocator,
        document,
        nbt.Options.bedrock,
    );
    defer allocator.free(encoded);
}
```

## API

| Function              | Description                                            |
| --------------------- | ------------------------------------------------------ |
| `nbt.parse()`         | Decode NBT into an owned `Document`                    |
| `nbt.serialize()`     | Encode a `Document`                                    |
| `nbt.parseReader()`   | Buffer a `std.Io.Reader`, then decode                   |
| `nbt.writeDocument()` | Stream uncompressed NBT to `std.Io.Writer`             |
| `nbt.builder`         | Safely construct compounds, lists, strings, and arrays |

Encoding presets:

```zig
nbt.Options.java
nbt.Options.bedrock
nbt.Options.bedrock_network
```

Compression can be enabled with `.gzip` or `.zlib`.

### Ownership and construction

`parse()` borrows the input only during the call and returns an independent,
owned tree. Names, strings, arrays, list items, and compound entries belong to
that tree. Free it with `document.deinit(allocator)` using the allocator passed
to `parse()`. Parse failures release partially constructed trees.

`serialize()` and `writeDocument()` borrow the document during the call.
Free serialized bytes with the allocator passed to `serialize()`; the document
remains usable. Neither operation frees or modifies document values.

Builder string and array helpers copy their input. `List.append()`,
`Compound.add()`, and `Document.init()` take ownership of values only on
success; on failure, the caller still owns the value. `Compound.add()` and
`Document.init()` copy names. All values transferred into a tree must use the
same allocator. Copying a `Tag` or `Document` copies its references, not its
owned data; free each tree exactly once.

For example, this construction cleans up on every failure:

```zig
fn makeDocument(allocator: std.mem.Allocator) !nbt.Document {
    var compound = nbt.builder.Compound.init(allocator);
    defer compound.deinit();
    {
        var text = try nbt.builder.string(allocator, "example");
        errdefer text.deinit(allocator);
        try compound.add("name", text);
    }
    try compound.add("count", .{ .int = 42 });
    var root = try compound.finish();
    errdefer root.deinit(allocator);
    return nbt.Document.init(allocator, "", root);
}
```

`finish()` transfers the owned slice and leaves the builder empty and reusable.
Call its `deinit()` when done. Iterate `compound.entries` and `list.items`
directly; `get()` and `getMut()` scan a compound in order and return borrowed
pointers. Those pointers and nested slices remain valid while their storage
is alive and unchanged. The host chooses its allocator, including an arena
for batches; no global allocator or pool is used.

### Limits and I/O

Configure `Options` before reading untrusted input:

```zig
var options = nbt.Options.bedrock_network;
options.compression = .none;
options.max_input_bytes = 8 * 1024 * 1024;
options.max_decompressed_bytes = 16 * 1024 * 1024;
options.max_total_decoded_bytes = 32 * 1024 * 1024;
options.max_output_bytes = 16 * 1024 * 1024;
options.max_depth = 64;
options.reject_trailing_bytes = true;
```

Collection counts, compound entries, and encoded string bytes have separate
limits. Parse/serialize depth includes the root and must be between 1 and 512.
Builders do not track depth; keep constructed trees within that bound for
recursive traversal and cleanup. Java and ordinary
Bedrock strings also have a 65,535-byte wire limit. Java uses modified UTF-8;
owned strings use standard UTF-8. Bedrock strings require valid UTF-8.
Duplicate compound names, negative collection lengths, and nonempty lists of
`TAG_End` are rejected. Empty lists preserve their declared element type.
Network serialization emits minimal signed ZigZag varints and unsigned string
lengths; decoding also accepts nonminimal varints that fit the destination type.

`max_input_bytes` bounds supplied bytes, including compressed input.
`max_decompressed_bytes` bounds decompressed NBT, and
`max_total_decoded_bytes` charges strings, arrays, list storage, and a conservative
compound-entry allowance. This allocation budget is not a cap on allocator
metadata, compression workspaces, or transient peak memory.
`max_output_bytes` bounds both plain NBT and the compressed result independently.
Compression's bit writer can reserve up to eight extra scratch bytes; returned
output still obeys the exact byte limit. Containers that exceed the depth limit
are rejected before allocating child storage or duplicate-name indexes.
Compression defaults to `.none` for every preset, including network NBT.
Gzip/zlib checksums and headers are checked; preset zlib dictionaries are
unsupported. Parsing reads one compression member; strict trailing-byte checks
reject extra members and trailing NBT bytes.

For an existing byte slice, use `parse()` to avoid input buffering.
`parseReader()` buffers the reader through EOF, bounded by `max_input_bytes`.
`writeDocument()` writes directly into a caller-owned writer or fixed buffer
when compression is disabled; compounds with more than 16 entries need
allocator scratch space for duplicate-name validation. Compressed writes buffer the plain and compressed
results. The writer is not flushed, and an error can leave partial output;
discard or reset the destination before retrying.

## Benchmarks

Post-PR #2 measurements on October 7, 2026: Zig 0.17.0, `ReleaseFast`,
Windows AMD64, Ryzen 5 5500. Baseline `0d851b0` and this implementation used the
same expanded fixture harness and `init.gpa`, run sequentially after validation
finished. Each entry is a median of seven samples with warmups for every operation.
Repeated runs confirmed the item/entity, array, and large-compound write gains.
The fixtures are [independently encoded Minecraft-shaped data](tests/fixtures/README.md),
not captured game files. The old 4/64-field microbenchmarks are now named
`compound-4` and `compound-64`; their rates cannot be compared to the new item/entity
rows. Rates count uncompressed NBT bytes. `write` reuses a caller-owned fixed buffer.

Each cell is **before → after MiB/s (before → after µs/op)**.

| Workload | Decode | Serialize | Write |
| --- | ---: | ---: | ---: |
| bedrock-item | 225 → 275 (0.9 → 0.7) | 281 → 351 (0.7 → 0.6) | 378 → 537 (0.5 → 0.4) |
| bedrock-entity | 232 → 288 (9.6 → 7.7) | 329 → 398 (6.8 → 5.6) | 377 → 533 (5.9 → 4.2) |
| bedrock-structure | 1,639 → 3,033 (20.9 → 11.3) | 430 → 831 (79.8 → 41.3) | 1,014 → 5,306 (33.8 → 6.5) |
| network-entity | 189 → 247 (10.4 → 7.9) | 287 → 367 (6.8 → 5.3) | 323 → 462 (6.1 → 4.2) |
| java-level | 2,140 → 3,415 (8.2 → 5.1) | 973 → 1,764 (18.0 → 9.9) | 1,289 → 2,230 (13.6 → 7.9) |
| compound-4 | 245 → 312 (0.3 → 0.2) | 232 → 269 (0.3 → 0.2) | 428 → 537 (0.1 → 0.1) |
| compound-16 | 230 → 294 (0.9 → 0.7) | 256 → 296 (0.8 → 0.7) | 316 → 366 (0.7 → 0.6) |
| compound-64 | 228 → 238 (3.8 → 3.6) | 251 → 366 (3.4 → 2.3) | 291 → 442 (2.9 → 1.9) |
| large-compound | 118 → 118 (519.1 → 520.8) | 150 → 175 (410.7 → 351.4) | 178 → 226 (344.9 → 271.7) |
| java-byte-array | 2,558 → 2,615 (24.4 → 23.9) | 2,399 → 2,427 (26.1 → 25.8) | 55,643 → 55,767 (1.1 → 1.1) |
| java-structured-mutf8 | 1,350 → 1,987 (0.4 → 0.3) | 426 → 802 (1.3 → 0.7) | 647 → 1,138 (0.8 → 0.5) |
| bedrock-structured | 1,780 → 3,438 (0.3 → 0.2) | 682 → 2,689 (0.8 → 0.2) | 1,078 → 6,399 (0.5 → 0.1) |
| network-varints | 881 → 968 (0.6 → 0.5) | 240 → 532 (2.1 → 1.0) | 355 → 535 (1.4 → 0.9) |
| gzip-byte-array | 291 → 292 (214.7 → 213.8) | 152 → 151 (412.3 → 413.9) | 152 → 152 (410.8 → 410.6) |
| zlib-byte-array | 574 → 569 (109.0 → 109.9) | 204 → 202 (306.5 → 309.6) | 205 → 205 (305.3 → 304.7) |
| large-byte-array | 5,911 → 6,058 (676.7 → 660.3) | 6,061 → 6,009 (660.0 → 665.7) | 34,554 → 30,668 (115.8 → 130.4) |

Compression and byte-array-only allocation counts are unchanged. Their timing
movement is host noise, not an optimization claim; 4 MiB runs varied substantially.
Large-compound decode and the 64-entry decode result are also effectively unchanged.
The 16-name linear scan removes small-compound indexes; larger compounds use a
hash table. Serialization reserves a large index once. Fixed-width arrays copy
native-endian bytes or swap in 256-byte batches; network varints append once per
value. Parsed arrays and strings remain owned.

Each allocation cell is **before count/bytes → after count/bytes**. Bytes are
cumulative allocation traffic, including growth, not peak memory. Counts exclude
document construction and the caller's output buffer.

| Workload | Decode | Serialize | Write |
| --- | ---: | ---: | ---: |
| bedrock-item | 35/2,682 → 30/1,882 | 10/1,226 → 5/426 | 5/800 → 0/0 |
| bedrock-entity | 376/30,188 → 325/21,484 | 60/15,517 → 9/6,813 | 51/8,704 → 0/0 |
| bedrock-structure | 517/73,640 → 445/61,576 | 86/152,348 → 8/111,327 | 72/12,064 → 0/0 |
| network-entity | 376/30,188 → 325/21,484 | 60/15,517 → 9/6,813 | 51/8,704 → 0/0 |
| java-level | 157/29,571 → 137/26,235 | 30/50,586 → 10/47,250 | 20/3,336 → 0/0 |
| compound-4 | 9/913 → 8/753 | 5/291 → 4/131 | 1/160 → 0/0 |
| compound-16 | 25/4,399 → 22/3,375 | 8/1,450 → 5/426 | 3/1,024 → 0/0 |
| compound-64 | 75/11,215 → 73/10,759 | 14/8,301 → 10/6,165 | 5/4,336 → 1/2,200 |
| large-compound | 4,121/884,755 → 4,119/884,299 | 26/497,819 → 16/358,451 | 11/278,656 → 1/139,288 |
| java-byte-array | 2/65,545 → 2/65,545 | 3/78,907 → 3/78,907 | 0/0 → 0/0 |
| java-structured-mutf8 | 8/957 → 7/797 | 8/1,569 → 6/1,114 | 1/160 → 0/0 |
| bedrock-structured | 8/954 → 7/794 | 8/1,569 → 5/724 | 1/160 → 0/0 |
| network-varints | 8/954 → 7/794 | 8/1,569 → 7/1,409 | 1/160 → 0/0 |
| gzip-byte-array | 4/213,344 → 4/213,344 | 9/376,244 → 9/376,244 | 9/376,244 → 9/376,244 |
| zlib-byte-array | 4/213,344 → 4/213,344 | 9/376,244 → 9/376,244 | 9/376,244 → 9/376,244 |
| large-byte-array | 2/4,194,313 → 2/4,194,313 | 3/4,549,458 → 3/4,549,458 | 0/0 → 0/0 |

The compression profiler reuses the inflater workspace and discards output, so
these measurements exclude output allocation/copy and NBT tree construction:

| 64 KiB stage | Gzip µs/op | Zlib µs/op |
| --- | ---: | ---: |
| Inflate only | 20.76 | 20.71 |
| Checksum only | 118.50 | 14.83 |
| Inflate plus incremental checksum | 146.60 | 35.62 |

CRC32 dominates gzip's validation cost. Zig 0.17 reads footer metadata without
verifying it; removing our checksum check would lose corruption detection.
An incremental stdlib-hasher experiment did not establish a throughput gain,
so the simpler final-buffer verification remains. Compressed parsing still
allocates a workspace, a bounded decompressed buffer, and an owned tree;
compressed writing still buffers plain and compressed bytes. No pooling or
custom CRC implementation was added.

Run `zig build bench` to print MiB/s, µs/op, allocations and cumulative bytes for
all workloads, followed by the stage profiler. Performance varies by hardware;
use identical payloads, allocator, compiler, and build mode for comparisons.

## Development

```sh
zig build test
zig build fuzz
zig build bench
```

CI runs 57 tests, allocation-failure leak checks, benchmarks, and 100,000 deterministic
random, truncated, and mutated inputs across all encodings and compression modes.
The 19-seed corpus includes the external Minecraft/compression fixtures. Successful
fuzz parses are serialized and parsed again before being freed. Fixture tests cover
every truncated prefix, input ownership, optional gzip fields and FHCRC, footer
corruption, strict concatenated-member rejection, exact limits, growing builders,
and every allocation failure through reader/parse/serialize/write paths.

## License

Apache-2.0
