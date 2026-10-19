# Benchmarks

Measured on October 18, 2026 on an AMD Ryzen 5 5500 with Zig 0.17.0. Numbers are medians
unless noted. They show relative cost on one machine, not guarantees.

## nbt-zig 1.3.0 against 1.2.0

`zig build bench` on Windows 11, `ReleaseFast` for the native CPU, `init.gpa`. Both builds ran
the same harness five times, alternating, and each cell is the fastest of those medians in
µs per operation. `write` streams into a reused fixed buffer. The fixtures are
[independently encoded Minecraft-shaped data](../tests/fixtures/README.md).

| Workload | Decode | Serialize | Write |
| --- | ---: | ---: | ---: |
| bedrock-item (203 B) | 0.67 → 0.66 | 0.43 → 0.39 | 0.34 → 0.32 |
| bedrock-entity (2.3 KB) | 7.2 → 6.9 | 4.6 → 4.2 | 3.8 → 3.6 |
| network-entity (2.1 KB) | 7.6 → 7.2 | 4.8 → 4.6 | 3.9 → 3.8 |
| network-structure (11 KB) | 28.7 → 10.9 | 51.2 → 14.4 | 39.6 → 6.4 |
| java-level (18 KB) | 4.0 → 3.6 | 3.2 → 2.9 | 2.6 → 2.2 |
| compound-64 | 2.3 → 2.3 | 1.5 → 1.3 | 1.3 → 1.1 |
| nested-256 | 21.0 → 21.6 | 12.3 → 10.9 | 9.9 → 8.8 |
| string-list-4k | 137 → 113 | 113 → 112 | 49 → 51 |
| network-varints | 0.55 → 0.39 | 0.99 → 0.33 | 0.95 → 0.38 |
| java-structured-mutf8 | 0.23 → 0.21 | 0.27 → 0.21 | 0.22 → 0.17 |

Other workloads (palettes, large compounds, arrays, compressed data) stayed within run-to-run
noise. The network gains come from converting runs of one-byte varints 16 at a time and from
writing wider varints in batches. Serialization gains mostly come from smaller stack frames.

Scanning the same inputs, which only validates and measures:

| Workload | Decode µs | Scan µs |
| --- | ---: | ---: |
| bedrock-item | 0.66 | 0.13 |
| bedrock-entity | 6.9 | 1.4 |
| network-entity | 7.2 | 1.6 |
| network-structure | 10.9 | 2.7 |
| java-level | 3.6 | 0.84 |
| large-compound (4096 entries) | 425 | 21 |
| palette-1024 | 253 | 46 |

## Against the old protocol-zig scanner

The hand-written network NBT scanner from protocol-zig 0.5.0 against `scanOptionalDocument`
with the same limits, in one `ReleaseFast` binary, fastest of 15 alternating batches:

| Document | Old ns | New ns |
| --- | ---: | ---: |
| item (178 B) | 182 | 156 |
| entity (2 KB) | 2,113 | 1,616 |
| structure (11 KB) | 6,809 | 2,625 |

## Against ext-encoding and PocketMine

ext-encoding is a PHP extension of byte buffer primitives rather than an NBT codec, so it is
compared on what it does: reading and writing 4096 ints laid out as a TAG_Int_Array payload,
in network varints, little endian and big endian. "small" values fit one varint byte and
"mixed" span the whole int range. Every side reads the same bytes, written out by
`zig build compare -- <dir>`, and checks its results before timing.

Environment: WSL2 Ubuntu 24.04 (kernel 6.6.87) on the same Ryzen 5 5500. PHP 8.4.14 NTS and
ext-encoding `d5437b5` built with gcc 13.3 at `-O2`, pmmp/NBT `5429a21`, BinaryUtils
`14c044a`, phpz `6a2ba0c`. Cells are medians of 31 batches of about 20 ms, in µs.

### Inside PHP

[tests/bench/php/ext](../tests/bench/php/ext) is a small phpz extension over nbt-zig. Calls
from PHP 8.4 with the opcache tracing JIT:

| Operation | ext-encoding | nbt-zig |
| --- | ---: | ---: |
| varint small decode | 104.3 | 3.2 |
| varint small encode | 89.1 | 8.0 |
| varint mixed decode | 99.5 | 13.0 |
| varint mixed encode | 106.0 | 18.7 |
| LE decode | 89.8 | 3.0 |
| LE encode | 93.5 | 6.9 |
| BE decode | 88.9 | 3.3 |
| BE encode | 91.7 | 7.5 |

ext-encoding reads one value per PHP call, while the extension converts the whole array in
one. That per-call cost, not the codec, is most of the difference.

Whole Bedrock documents, PocketMine's `LittleEndianNbtSerializer` against the extension.
PocketMine builds its tag objects and the extension builds PHP arrays, so the two read rows
are close in work rather than identical. "Length" is `read()` with an offset in PocketMine,
which has to build the tree, and the scanner in nbt-zig.

| Document | PocketMine read | nbt-zig read | PocketMine length | nbt-zig length |
| --- | ---: | ---: | ---: | ---: |
| item (203 B) | 13.9 | 1.2 | 13.6 | 0.09 |
| entity (2.3 KB) | 147.0 | 13.0 | 149.7 | 0.68 |
| structure (36 KB) | 423.3 | 24.4 | 432.4 | 0.95 |

Without the JIT, PocketMine is 1.35 to 1.5 times slower while ext-encoding and nbt-zig barely
change. Full output, including p10 and p90, comes from `tests/bench/php/compare.php`.

### Native

[tests/bench/native/ext_encoding.cpp](../tests/bench/native/ext_encoding.cpp) compiles
ext-encoding's own `Serializers.h` and drives its readers and writers directly against
nbt-zig's `parsePayload` and `serializePayload`. ext-encoding decodes into a reused vector
while nbt-zig allocates each time, which favours ext-encoding.

| Operation | ext-encoding `-O2` | ext-encoding native | nbt-zig x86-64 | nbt-zig native |
| --- | ---: | ---: | ---: | ---: |
| varint small decode | 4.60 | 4.47 | 0.67 | 0.42 |
| varint small encode | 8.47 | 6.40 | 1.01 | 0.80 |
| varint mixed decode | 14.8 | 14.7 | 9.7 | 9.8 |
| varint mixed encode | 18.3 | 17.9 | 11.6 | 11.0 |
| LE decode | 0.20 | 0.20 | 0.33 | 0.23 |
| LE encode | 0.59 | 0.56 | 0.33 | 0.22 |
| BE decode | 1.45 | 1.23 | 1.25 | 0.34 |
| BE encode | 1.81 | 1.59 | 1.26 | 0.47 |

Little endian decode is a plain copy on both sides. glibc picks AVX2 for ext-encoding's copy at
run time, while generic x86-64 Zig is held to SSE2 and also allocates its result. Generic
x86-64 has no vector byte shuffle either, hence the slower big endian rows there.

## Stack use

Smallest thread stack, on Linux, that handled a 512-deep document of nested compounds or lists:

| Operation | ReleaseFast | ReleaseSafe | Debug |
| --- | ---: | ---: | ---: |
| scan | 16 KiB | 16 KiB | 16 KiB |
| parse | 112 KiB | 112 KiB | 2 MiB |
| serialize | 96 KiB | 96 KiB | 768 KiB |
| deinit | 48 KiB | 64 KiB | 384 KiB |
| eql | 112 KiB | 112 KiB | 1 MiB |

Serializing with gzip or zlib needs 192 KiB in ReleaseFast, 256 KiB in ReleaseSafe and 768 KiB
in Debug for a small document, because std's deflate state is built on the caller's stack.

## Reproducing

```sh
zig build bench                       # all workloads
zig build bench -- network            # names containing "network"
zig build compare -- /tmp/nbt-inputs  # nbt-zig natively, also writes the shared inputs

cd tests/bench/php/ext && zig build -Doptimize=ReleaseFast -Dphp-include-dir="$(php-config --include-dir)"
php -d extension=encoding.so -d extension=tests/bench/php/ext/modules/nbt_bench.so     tests/bench/php/compare.php /tmp/nbt-inputs NBT/src BinaryUtils/src

cp ext-encoding/Serializers.h tests/bench/native/shim/
g++ -O2 -std=c++20 -Itests/bench/native/shim tests/bench/native/ext_encoding.cpp -o ext_encoding
./ext_encoding /tmp/nbt-inputs
```

Compare like with like: same machine, inputs, allocator, compiler and build mode.
