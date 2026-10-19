# Using nbt-zig from PHP

nbt-zig is meant to sit under a native PHP extension, for example one written in Zig with
phpz, that backs PocketMine's NBT serializers.
This page maps PocketMine's API onto nbt-zig and notes where behaviour differs.

## Mapping

| PocketMine | nbt-zig |
| --- | --- |
| `LittleEndianNbtSerializer` | `Options.bedrock` |
| `BigEndianNbtSerializer` | `Options.java` with `raw_strings = true` |
| `NetworkNbtSerializer` (PocketMine-MP) | `Options.bedrock_network` |
| `read($buffer, &$offset, $maxDepth)` | `parsePrefix(allocator, buffer[offset..], options)`, then `offset += len` |
| `readHeadless($buffer, $type, &$offset)` | `parsePayload(allocator, buffer[offset..], type, options)` |
| `readMultiple($buffer)` | `parsePrefix` in a loop until the buffer is used up |
| `write(TreeRoot)` | `encodedLength`, then `writeDocument` into a buffer of that size |
| `writeHeadless(Tag)` | `encodedLength(tag)`, then `writePayload` |
| `writeMultiple($roots)` | `writeDocument` once per root into one writer |
| `$maxDepth` | `max_depth`, see below |

`scanDocument` answers "how long is this document?" without building anything, which PocketMine
can only do by reading the whole tree.

## Matching PocketMine

Set these for PocketMine-compatible results:

* `raw_strings = true`. PocketMine treats strings as bytes, with no UTF-8 checks and no
  modified UTF-8 conversion in big-endian NBT.
* `duplicate_names = .keep_first`. PocketMine keeps the first value of a repeated name, since
  old worlds contain such compounds.
* `max_string_bytes = 32767`, PocketMine's string limit.
* `max_depth`: PocketMine counts nested compounds and lists, root included, and treats 0 as
  unlimited. nbt-zig counts every level, so a value inside the root compound is level 2. Use
  `$maxDepth + 1`, or 512 for 0.

Remaining differences:

* A negative list length reads as an empty list in PocketMine and fails here with
  `error.InvalidLength`.
* TAG_Long_Array (12) is unknown to PocketMine and supported here.

## Recommended native interface

PHP to native calls are expensive compared to NBT decoding itself, so an extension should
cross the boundary once per document, not once per tag:

* `read(string $buffer, int &$offset, int $maxDepth): TreeRoot` parses with `parsePrefix` and
  builds the PHP objects in one native call. Byte arrays become PHP strings with one copy, and
  int arrays are converted to PHP arrays in bulk.
* `write(TreeRoot): string` walks the PHP objects once, asks `encodedLength` for the size,
  allocates the `zend_string` at that size and writes into it with `writeDocument` over a
  fixed `std.Io.Writer`, so the output is never copied.
* `length(string $buffer, int $offset): int` can expose `scanDocument` directly.

A C ABI is not provided. A phpz extension imports the Zig module directly, and a C interface
for trees would duplicate the tree types without serving another caller. If one is added,
it should map every error to a status code and never let a Zig error or panic cross the
boundary. nbt-zig reports bad input as errors rather than panicking, which the fuzzer checks
in ReleaseSafe.

Map errors to PocketMine's exceptions by category: anything from parsing or scanning is
`NbtDataException`, while `error.OutOfMemory` should stay PHP's own out-of-memory handling.
