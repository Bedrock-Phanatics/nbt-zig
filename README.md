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
Compression defaults to `.none` for every preset, including network NBT.
Gzip/zlib checksums and headers are checked; preset zlib dictionaries are
unsupported. Parsing reads one compression member; strict trailing-byte checks
reject extra members and trailing NBT bytes.

For an existing byte slice, use `parse()` to avoid input buffering.
`parseReader()` buffers the reader through EOF, bounded by `max_input_bytes`.
`writeDocument()` writes directly into a caller-owned writer or fixed buffer
when compression is disabled; compound duplicate-name validation still needs
allocator scratch space. Compressed writes buffer the plain and compressed
results. The writer is not flushed, and an error can leave partial output;
discard or reset the destination before retrying.

## Benchmarks

Audit measurements on October 6, 2026: Zig 0.17.0, `ReleaseFast`, Windows
10.0.26200, AMD64 Family 25 Model 80. Baseline and updated code used the same
benchmark harness and `init.gpa` allocator, run sequentially. Each result is
the median of seven samples. Rates are MiB/s of uncompressed NBT, including
compression workloads. `write` uses a reused, caller-allocated fixed buffer.

| Workload | Decode before/after | Serialize before/after | Write before/after |
| -------- | ------------------: | ---------------------: | -----------------: |
| Bedrock item, 4 fields | 145 / 161 | 159 / 150 | 152 / 237 |
| Bedrock entity, 64 fields | 147 / 132 | 133 / 138 | 111 / 174 |
| Bedrock compound, 4,096 fields | 48 / 62 | 71 / 79 | 67 / 101 |
| Java byte array, 64 KiB | 1,159 / 1,567 | 941 / 1,413 | 912 / 43,293 |
| Java structured / modified UTF-8 | 464 / 602 | 177 / 237 | 202 / 351 |
| Bedrock structured | 836 / 1,137 | 283 / 417 | 306 / 659 |
| Network / VarInt | 410 / 544 | 100 / 147 | 105 / 302 |
| Gzip byte array, 64 KiB | 351 / 199 | 92 / 102 | 93 / 100 |
| Zlib byte array, 64 KiB | 366 / 309 | 114 / 124 | 118 / 120 |
| Java byte array, 4 MiB | 3,022 / 3,475 | 2,885 / 3,374 | 1,999 / 10,086 |

Direct writes remove the intermediate serialization buffer. Gzip/zlib reads
now verify checksums; that necessary work slows compressed decoding,
particularly CRC32 for gzip. Host timing variability also moved unchanged
workloads; timing ratios should not be treated as isolated code speedups.
These synthetic shapes are not captured item/entity/chunk fixtures.

| Workload | Decode allocations before/after | Write allocations before/after | Write allocated bytes before/after |
| -------- | ------------------------------: | -----------------------------: | ---------------------------------: |
| Bedrock item | 9 / 9 | 5 / 1 | 291 / 160 |
| Bedrock entity | 75 / 75 | 14 / 5 | 8,301 / 4,336 |
| Large compound | 4,121 / 4,121 | 26 / 11 | 497,819 / 278,656 |
| Java structured | 12 / 8 | 8 / 1 | 1,569 / 160 |
| Java byte array, 4 MiB | 3 / 2 | 3 / 0 | 4,549,458 / 0 |

Allocation counters cover one operation, excluding document construction and
the caller's output buffer. Byte counts are cumulative allocation traffic,
including growth, rather than peak resident memory. Large compounds still
allocate one owned name per entry and temporary duplicate-name indexes.
Fixed-width number arrays decode into one allocation; lists allocate their
declared item slice once after length and minimum-input checks. There is no
size-estimation pass before serialization; allocating output grows geometrically
within its limit. Compressed reads retain bounded plain bytes until parsing
finishes, and compressed writes retain plain and compressed buffers.

Run them yourself:

```sh
zig build bench
zig build -Doptimize=ReleaseSafe test
zig build -Doptimize=ReleaseFast test
```

Performance varies by hardware. Cross-language comparisons should use identical payloads and benchmark conditions.

## Development

```sh
zig build test
zig build fuzz
zig build bench
```

CI runs tests, allocation-failure leak checks, benchmarks, and 100,000 deterministic
random, truncated, and mutated inputs across all encodings and compression modes.
Successful fuzz parses are serialized and parsed again before being freed.

## License

Apache-2.0
