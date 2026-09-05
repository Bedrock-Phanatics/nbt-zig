# nbt.zig

A production-oriented Named Binary Tag codec for Zig 0.16. It supports the three dialects implemented by the original CsNbt library:

| Preset | Byte order | Integers and lengths | Strings |
|---|---|---|---|
| `Options.java` | big endian | fixed width | Java modified UTF-8 |
| `Options.bedrock` | little endian | fixed width | strict UTF-8 |
| `Options.bedrock_network` | little endian | ZigZag VarInt integers and lengths | VarUInt length + strict UTF-8 |

GZip and ZLib containers are supported through Zig's standard-library flate implementation.

## Design

- Explicit allocator ownership: `parse` returns an owned `Document`; call `document.deinit(allocator)` with the same allocator.
- No global mutable state or locks. Independent operations can run concurrently when their inputs and allocators permit it.
- Ordered compounds and homogeneous lists match NBT's encoded model without virtual dispatch or one allocation per scalar tag.
- Uncompressed slices passed to `parse` are decoded directly without copying. Compressed parsing allocates a bounded temporary decompression buffer; `parseReader` buffers its bounded input before decoding.
- Configurable limits cover nesting, strings, lists/arrays, compound entries, total decoded memory, decompression output, and trailing bytes.
- Every partially initialized tree is cleaned up with `errdefer` on failure.
- Parsed trees are capped at 512 levels. Manually constructed `Tag` trees must observe the same invariant before calling recursive `eql` or `deinit` operations.

## Usage

```zig
const std = @import("std");
const nbt = @import("nbt");

fn load(allocator: std.mem.Allocator, bytes: []const u8) !void {
    var document = try nbt.parse(allocator, bytes, nbt.Options.bedrock);
    defer document.deinit(allocator);

    if (document.root == .compound) {
        if (document.root.compound.get("name")) |name| {
            if (name.* == .string) std.debug.print("{s}\n", .{name.string});
        }
    }

    const encoded = try nbt.serialize(allocator, document, nbt.Options.bedrock);
    defer allocator.free(encoded);
}
```

## Basic API

| API | Purpose |
|---|---|
| `nbt.parse(allocator, bytes, options)` | Decode bytes into an owned `Document`. |
| `nbt.serialize(allocator, document, options)` | Encode a document into an owned byte slice. |
| `nbt.parseReader(allocator, reader, options)` | Read and decode from a Zig `std.Io.Reader`. |
| `nbt.writeDocument(allocator, writer, document, options)` | Encode and write to a Zig `std.Io.Writer`. |
| `nbt.Document.init(allocator, name, root)` | Copy the root name and create an owned document. |
| `compound.get(name)` / `compound.getMut(name)` | Look up a compound value by name. |

Use `nbt.Options.java`, `.bedrock`, or `.bedrock_network` as a starting preset. Set `options.compression` to `.none`, `.gzip`, or `.zlib` and adjust the resource limits when reading untrusted data.

`nbt.Tag` is the tagged union for every NBT value. Scalar tags can be created directly, while `nbt.builder.string`, `byteArray`, `intArray`, and `longArray` copy slice data. Use `nbt.builder.List` and `nbt.builder.Compound` to construct owned containers safely.

For Zig I/O, use `parseReader` and `writeDocument`. Reader/writer ownership always remains with the caller.

Builder `append` and `add` calls transfer a tag only on success. Keep an owned tag in a named variable until the call succeeds; after an error, the caller must deinitialize it. `finish` transfers the accumulated tree to its returned tag, and `Document.init` transfers the root only on success. Avoid passing newly allocated tags as anonymous temporaries to fallible builder calls. Compression is selected with, for example:

```zig
var options = nbt.Options.java;
options.compression = .gzip;
options.max_input_bytes = 8 * 1024 * 1024;          // input bytes
options.max_decompressed_bytes = 32 * 1024 * 1024;  // inflated bytes
options.max_output_bytes = 32 * 1024 * 1024;        // output bytes
options.max_total_decoded_bytes = 32 * 1024 * 1024; // owned tree memory
```

## Build, test, fuzz, benchmark

```console
zig build test
zig build bench
```

The test suite uses `std.testing.allocator` for leak detection and covers all tag families and encodings, golden payloads, modified UTF-8, stream I/O, compression, duplicate rejection, independent resource limits, truncation at every byte, malformed inputs, homogeneity, round trips, and deterministic arbitrary-input decoding. `zig build test --fuzz` exercises the native Zig 0.16 fuzz target.

The benchmark reports measured throughput and latency for small, medium, and large-array encode/decode workloads. Results depend on the machine and should be collected locally rather than treated as universal claims.

## Package integration

Add this repository as a Zig dependency and import its exposed `nbt` module. The package requires Zig 0.16.0 or newer within the 0.16 release line.

Licensed under Apache-2.0.