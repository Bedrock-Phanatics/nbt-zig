# nbt-zig

A fast, allocation-aware [NBT](https://minecraft.wiki/w/NBT_format) library for Zig 0.17.

<p align="center">
  <a href="https://discord.gg/Yv9qPRQNc3">Join the Bedrock Phanatics Discord</a>
</p>

- Java, Bedrock and Bedrock network encodings, plus gzip and zlib
- A validating scanner that never allocates
- Owned trees, leak-free builders, headerless payloads and exact encoded sizes
- Configurable limits for every length, depth and size
- PocketMine compatible options for raw strings and duplicate names

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
var document = try nbt.parse(allocator, bytes, .bedrock);
defer document.deinit(allocator);

if (document.root.compound.get("Name")) |name| std.debug.print("{s}\n", .{name.string});

const encoded = try nbt.serialize(allocator, document, .java);
defer allocator.free(encoded);
```

Building a document:

```zig
var root = nbt.builder.Compound.init(allocator);
defer root.deinit();
try root.add("Count", .{ .byte = 64 });
try root.add("Damage", .{ .short = 3 });

var document = try nbt.Document.init(allocator, "", try root.finish());
defer document.deinit(allocator);
```

Checking untrusted input without building a tree:

```zig
var options = nbt.Options.bedrock_network;
options.max_depth = 64;

const len = try nbt.scanOptionalDocument(packet[offset..], options);
const nbt_bytes = packet[offset..][0..len];
```

## API

| | |
| --- | --- |
| `parse`, `serialize` | Whole documents, optionally compressed |
| `parsePrefix` | A document at the start of a buffer and the bytes it used |
| `parsePayload`, `serializePayload` | Headerless payloads of a known tag type |
| `parseReader`, `writeDocument`, `writePayload` | `std.Io` readers and writers |
| `scanDocument`, `scanOptionalDocument`, `scanPayload` | Validate and measure without allocating |
| `encodedLength` | Exact output size, for writing into a caller's buffer |
| `builder` | Strings, arrays, lists and compounds |
| `Options` | Encoding, compression, limits and compatibility switches |

Trees own their memory and are freed with `deinit` and the allocator that built them.
Serialization only borrows them.

The scanner checks everything `parse` does except duplicate names and
`max_total_decoded_bytes`, which would need memory, and it never reads past
`max_input_bytes`. `scanOptionalDocument` also accepts the lone TAG_End Bedrock uses for
absent NBT.

Parsing and serializing recurse, needing about 112 KiB of stack at the maximum depth of 512
in optimized builds. Compressed serialization needs about 256 KiB for std's deflate state.
The scanner needs 16 KiB.

## Development

```sh
zig build test
zig build fuzz
zig build bench
```

See [docs/benchmarks.md](docs/benchmarks.md) for measurements against ext-encoding and
PocketMine, and [docs/php.md](docs/php.md) for PHP extension use.

## License

Apache-2.0
