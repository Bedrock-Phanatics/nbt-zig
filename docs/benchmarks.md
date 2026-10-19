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

## Against PocketMine and ext-encoding

ext-encoding is a PHP extension of byte buffer primitives, not an NBT codec, so the comparison
has two parts. Both sides read the same bytes, which `zig build compare -- <dir>` writes out,
and check their results before timing.

* Primitive arrays: 4096 ints as a TAG_Int_Array payload. PHP reads and writes them with
  ext-encoding's `VarInt`, `LE` and `BE` calls into a PHP array, nbt-zig with
  `parsePayload`, `serializePayload` and `writePayload`.
* NBT documents: PocketMine's `LittleEndianNbtSerializer` (pure PHP on BinaryUtils, the stack
  PocketMine-MP ships) against `parse` and `serialize` with `raw_strings` and
  `duplicate_names = .keep_first`, matching PocketMine's semantics. "Consumed length" is
  `read()` with an offset in PHP, which must build the tree, and `scanDocument` in Zig.

Environment: WSL2 Ubuntu 24.04 (kernel 6.6.87). PHP 8.4.14 NTS built with gcc 13.3 at `-O2`,
ext-encoding `d5437b5`, pmmp/NBT `5429a21`, BinaryUtils `14c044a`. Zig `ReleaseFast` for
generic x86-64, which matches how ext-encoding was compiled, and for the native CPU. Cells are
medians of 31 batches of about 20 ms in µs. p10 and p90 are in the raw output.

| Operation | PHP JIT | PHP no JIT | Zig x86-64 | Zig native |
| --- | ---: | ---: | ---: | ---: |
| varint int[4096] small decode | 67.9 | 115.6 | 0.64 | 0.42 |
| varint int[4096] small encode | 70.0 | 111.7 | 1.02 | 0.81 |
| varint int[4096] mixed decode | 82.9 | 124.0 | 10.0 | 10.4 |
| varint int[4096] mixed encode | 108.5 | 115.4 | 10.9 | 10.8 |
| LE int[4096] decode | 70.4 | 117.3 | 0.32 | 0.23 |
| LE int[4096] encode | 82.1 | 117.3 | 0.33 | 0.22 |
| BE int[4096] decode | 83.5 | 120.8 | 1.24 | 0.33 |
| BE int[4096] encode | 93.6 | 120.8 | 1.25 | 0.39 |
| bedrock-item read | 16.8 | 18.8 | 0.68 | 0.79 |
| bedrock-item write | 4.7 | 7.1 | 0.36 | 0.39 |
| bedrock-item consumed length | 14.9 | 20.4 | 0.05 | 0.06 |
| bedrock-entity read | 141.1 | 224.7 | 7.2 | 7.5 |
| bedrock-entity write | 44.9 | 74.4 | 3.8 | 4.2 |
| bedrock-structure read | 409.8 | 595.2 | 10.4 | 11.0 |
| bedrock-structure write | 122.9 | 168.5 | 46.5 | 48.6 |

"small" values fit one varint byte, "mixed" span the whole int range. Generic x86-64 has no
vector byte shuffle, hence the slower big-endian arrays there. The structure write on Linux
is dominated by allocating and faulting in a fresh 36 KB output buffer each time. The `write`
row of `zig build bench`, which reuses a buffer, puts the same document at about 5 µs on Windows. nbt-zig parses into a Zig tree while PocketMine builds
PHP objects, so the document rows compare the work each stack has to do, not identical output.

Not measured: PHP calling nbt-zig, since no PHP binding exists yet. See [php.md](php.md).

## Stack use

Smallest thread stack, on Linux, that handled a 512-deep document of nested compounds or lists:

| Operation | ReleaseFast | ReleaseSafe | Debug |
| --- | ---: | ---: | ---: |
| scan | 16 KiB | 16 KiB | 16 KiB |
| parse | 112 KiB | 112 KiB | 2 MiB |
| serialize | 96 KiB | 96 KiB | 768 KiB |
| deinit | 48 KiB | 64 KiB | 384 KiB |
| eql | 112 KiB | 112 KiB | 1 MiB |

## Reproducing

```sh
zig build bench                       # all workloads
zig build bench -- network            # names containing "network"
zig build compare -- /tmp/nbt-inputs  # Zig half, also writes the shared inputs
php -d extension=encoding.so tests/bench/php/compare.php /tmp/nbt-inputs NBT/src BinaryUtils/src
```

Compare like with like: same machine, inputs, allocator, compiler and build mode.
