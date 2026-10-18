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
directly; `get()` scans a compound in order and returns a borrowed, mutable
pointer. Those pointers and nested slices remain valid while their storage
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
metadata, compression workspaces, or transient peak memory. Inflating always
needs room for the 32 KiB deflate window, even under smaller limits.
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
allocator scratch space for duplicate-name validation, reused across the whole
call. Compressed writes buffer the plain and compressed results. The writer is
not flushed, and an error can leave partial output; discard or reset the
destination before retrying.

## Benchmarks

Version 1.2.0 against 1.1.5 on October 18, 2026: Zig 0.17.0, `ReleaseFast`,
Windows AMD64, Ryzen 5 5500, `init.gpa`. Both builds ran the same harness five
times, alternating, and each cell is the fastest of those five medians. The
fixtures are [independently encoded Minecraft-shaped data](tests/fixtures/README.md),
not captured game files. `write` streams into a reused fixed buffer.

Each cell is **µs/op before → after**.

| Workload | Decode | Serialize | Write |
| --- | ---: | ---: | ---: |
| bedrock-item | 0.73 → 0.68 | 0.46 → 0.43 | 0.37 → 0.35 |
| bedrock-entity | 7.8 → 7.2 | 4.6 → 4.8 | 4.2 → 3.9 |
| bedrock-structure | 11.6 → 10.6 | 22.0 → 23.1 | 6.4 → 6.0 |
| network-entity | 8.2 → 7.6 | 5.0 → 4.8 | 4.3 → 4.0 |
| java-level | 5.6 → 3.8 | 8.0 → 3.3 | 7.8 → 2.6 |
| compound-4 | 0.22 → 0.19 | 0.17 → 0.12 | 0.12 → 0.10 |
| compound-16 | 0.79 → 0.77 | 0.63 → 0.56 | 0.55 → 0.49 |
| compound-64 | 4.0 → 2.3 | 2.0 → 1.5 | 2.0 → 1.3 |
| large-compound | 638 → 415 | 309 → 212 | 284 → 179 |
| nested-256 | 22.5 → 21.4 | 13.2 → 12.4 | 12.7 → 10.0 |
| palette-1024 | 305 → 262 | 215 → 211 | 167 → 139 |
| network-palette-1024 | 315 → 285 | 240 → 228 | 176 → 160 |
| int-list-64k | 1,089 → 513 | 423 → 99 | 529 → 40 |
| string-list-4k | 165 → 143 | 121 → 111 | 55 → 50 |
| java-structured-mutf8 | 0.32 → 0.22 | 0.56 → 0.26 | 0.48 → 0.23 |
| bedrock-structured | 0.16 → 0.16 | 0.15 → 0.10 | 0.09 → 0.08 |
| network-varints | 0.54 → 0.54 | 1.15 → 0.97 | 1.00 → 0.96 |
| gzip-byte-array | 233 → 103 | 478 → 363 | 459 → 354 |
| zlib-byte-array | 115 → 105 | 348 → 343 | 339 → 345 |

Byte-array-only rows are dominated by the allocator and memcpy and moved within
noise, as did the rows within a few percent above. Serialize makes one fewer
allocator call on every workload: the output is allocated once, plus a shrink when
network varints make the size hint inexact and one shared index for compounds
over 16 entries. Compressed serialization dropped from 11 allocator calls to 4.

Where it came from:

* Decoders and encoders are specialized per encoding at compile time, so byte
  order and varint choices cost nothing per value.
* Scalar lists decode and encode in bulk, and byte arrays share the number-array path.
* Duplicate-name checks reuse one index per call instead of building one per compound.
* Tag bytes are range checked instead of scanned, and short ASCII names skip the
  general UTF-8 validator.
* Java strings with no NUL or supplementary characters are copied as-is instead
  of being transcoded.
* Serialization sizes its buffer exactly for Java strings, and serialize and
  write share one inlined output path.
* Inflate writes straight into the bounded output, which doubles as its history
  window, sized from the gzip footer when available.
* Gzip checksums use a slicing-by-8 CRC32 instead of std's byte-at-a-time table.

Run `zig build bench` for every workload, allocation counts, malformed-input
rejection costs, and a compression stage profile. Pass a name to run a subset,
for example `zig build bench -- palette`. Results vary by machine; compare with
the same payloads, allocator, compiler, and build mode.

## Development

```sh
zig build test
zig build fuzz
zig build bench
```

CI runs 62 tests, allocation-failure leak checks, benchmarks, and 100,000 deterministic
random, truncated, and mutated inputs across all encodings and compression modes.
The 19-seed corpus includes the external Minecraft/compression fixtures. Successful
fuzz parses are serialized and parsed again before being freed. Fixture tests cover
every truncated prefix, input ownership, optional gzip fields and FHCRC, footer
corruption, CRC agreement with the standard library, strict concatenated-member
rejection, exact limits, growing builders, small thread stacks, and every allocation
failure through reader/parse/serialize/write paths.

## License

Apache-2.0
