# nbt-zig

High-performance [Named Binary Tag](https://minecraft.wiki/w/NBT_format) codec for Zig 0.16, with first-class support for Minecraft Java and Bedrock formats.

<p align="center">
  <a href="https://discord.gg/Yv9qPRQNc3">Join the Bedrock Phanatics Discord</a>
</p>

* Java, Bedrock, and Bedrock Network NBT
* GZip and ZLib compression
* Explicit allocator ownership
* Configurable decode limits for untrusted input
* Streaming reader/writer APIs
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
| `nbt.parseReader()`   | Decode from `std.Io.Reader`                            |
| `nbt.writeDocument()` | Encode to `std.Io.Writer`                              |
| `nbt.builder`         | Safely construct compounds, lists, strings, and arrays |

Encoding presets:

```zig
nbt.Options.java
nbt.Options.bedrock
nbt.Options.bedrock_network
```

Compression can be enabled with `.gzip` or `.zlib`.

## Benchmarks

`ReleaseFast`, Zig 0.16.0, Ubuntu 24.04 GitHub Actions runner. Results are the median of 7 samples.

| Workload                 |          Decode |          Encode |
| ------------------------ | --------------: | --------------: |
| Bedrock structured       | **1,108 MiB/s** |   **681 MiB/s** |
| Bedrock Network / VarInt |   **426 MiB/s** |   **212 MiB/s** |
| 64 KiB Java byte array   | **1,706 MiB/s** | **1,485 MiB/s** |
| 4 MiB byte array         | **3,762 MiB/s** | **4,177 MiB/s** |

Run them yourself:

```sh
zig build bench
```

Performance varies by hardware. Cross-language comparisons should use identical payloads and benchmark conditions.

## Development

```sh
zig build test
zig build fuzz
zig build bench
```

CI runs tests, leak checking, benchmarks, and 100,000 deterministic malformed-input fuzz cases.

## License

Apache-2.0
