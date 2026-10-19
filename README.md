# nbt-zig

Fast, allocation-conscious [NBT](https://minecraft.wiki/w/NBT_format) for Zig 0.17, covering
Java, Bedrock and Bedrock network encodings.

<p align="center">
  <a href="https://discord.gg/Yv9qPRQNc3">Join the Bedrock Phanatics Discord</a>
</p>

## Features

* Java (big endian, modified UTF-8), Bedrock (little endian) and Bedrock network (varint) NBT
* Gzip and zlib with checksum, header and decompression-size validation
* A scanner that validates NBT and reports its length without allocating
* Owned trees with explicit allocators, plus builders that never leak on failure
* Headerless payloads, documents inside larger buffers and exact encoded sizes
* Configurable limits for depth, lengths, strings, input and output sizes
* PocketMine compatibility options: raw strings and keep-first duplicate names
* Tested in every build mode, fuzzed, and differentially checked against itself

## Installation

```sh
zig fetch --save git+https://github.com/Bedrock-Phanatics/nbt-zig
```

```zig
const nbt = b.dependency("nbt", .{ .target = target, .optimize = optimize });
module.addImport("nbt", nbt.module("nbt"));
```

## Usage

```zig
const std = @import("std");
const nbt = @import("nbt");

fn roundTrip(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var document = try nbt.parse(allocator, bytes, .bedrock);
    defer document.deinit(allocator);

    if (document.root.compound.get("Name")) |name| std.debug.print("{s}\n", .{name.string});

    return nbt.serialize(allocator, document, .bedrock);
}
```

Checking untrusted network NBT without building a tree:

```zig
var options = nbt.Options.bedrock_network;
options.max_depth = 64;
options.max_input_bytes = 64 * 1024;

const len = try nbt.scanOptionalDocument(packet[offset..], options);
const document_bytes = packet[offset..][0..len];
```

## API

| Function | Purpose |
| --- | --- |
| `parse`, `serialize` | Whole documents, optionally compressed |
| `parsePrefix` | A document at the start of a buffer, plus how many bytes it used |
| `parsePayload`, `serializePayload` | Headerless payloads of a known tag type |
| `parseReader`, `writeDocument`, `writePayload` | `std.Io` readers and writers |
| `scanDocument`, `scanOptionalDocument`, `scanPayload` | Validate and measure without allocating |
| `encodedLength` | Exact uncompressed size of a document or tag |
| `builder` | Build strings, arrays, lists and compounds |

Presets are `nbt.Options.java`, `.bedrock` and `.bedrock_network`. Set `compression` to `.gzip`
or `.zlib` for compressed documents.

Parsed trees own all their memory, free them with `deinit` and the same allocator. An arena
works well for batches. Serialization borrows the tree. Builders copy names and take values
only when they succeed.

### Scanner

The scanner walks NBT in place with a fixed 2.5 KiB stack and never touches an allocator, so it
suits packet decoding and quick validation. It applies the same checks and limits as `parse`,
with two deliberate exceptions, since both need memory that grows with the input: duplicate
compound names are not detected, and `max_total_decoded_bytes` is not charged. Reading past
`max_input_bytes` fails with `error.SizeLimitExceeded`, so a scan never wanders into the rest
of a buffer. `scanOptionalDocument` also accepts the lone TAG_End that Bedrock sends for absent
NBT. Concatenated documents are walked by scanning `input[offset..]` and adding the result.

Compressed input is not scanned. Decompress it first, which does allocate.

### Limits

`Options` bounds nesting depth (at most 512), collection lengths, compound entries, string and
byte array lengths, input, decompressed and output sizes, and the bytes a parse may allocate.
Malformed, truncated and oversized input fails with an error, never a crash. Parsing and
serializing recurse on the native stack, about 112 KiB at depth 512 in optimized builds and
several MiB in Debug, so lower `max_depth` for small thread stacks. The scanner needs 16 KiB.
Compressing also places std's roughly 230 KB deflate state on the stack, so compressed
serialization needs about 256 KiB in optimized builds. Decompression needs little.

## Development

```sh
zig build test
zig build fuzz
zig build bench
```

[docs/benchmarks.md](docs/benchmarks.md) has measurements, including against PocketMine and
ext-encoding, and [docs/php.md](docs/php.md) covers PHP extension use.

## License

Apache-2.0
