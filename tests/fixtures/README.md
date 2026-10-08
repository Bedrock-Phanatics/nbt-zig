# Minecraft-shaped interoperability corpus

These are independently encoded, realistically structured fixtures, not captured
world files. `generate.py` uses only Python's standard library. The committed
compression vectors were produced with Python's zlib 1.3.2; gzip timestamps are
zero. Compressor versions can change compressed bytes without changing NBT.

| Fixture | Contents |
| --- | --- |
| `item.bedrock.nbt` | Diamond sword, slot/count/damage, display/lore, enchantments |
| `entity.bedrock.nbt` | Zombie, signed ID, position/motion, attributes, nine inventory items |
| `structure.bedrock.nbt` | 16×16×16 mcstructure-style palette, two 4,096-element block-index arrays, entities and chest data |
| `entity.network.nbt` | Same entity with signed ZigZag integers and unsigned string lengths |
| `level.java.nbt` | Named Java root, nested player/section/block entity, byte/int/long arrays, NUL and supplementary Unicode |
| `level.java.gz`, `level.java.zlib` | External dynamic DEFLATE vectors |
| `level.optional.gz` | FEXTRA, FNAME, FCOMMENT and FHCRC |
| `level.fixed.zlib`, `level.stored.zlib` | Fixed-Huffman and stored DEFLATE vectors |

The entire binary corpus is under 100 KiB. It mixes representative Minecraft
structures and older section fields to exercise the codec; it is not a promise
that a particular game version loads this data. Network NBT does not include
packet framing, and mcstructure data does not include a LevelDB chunk envelope.

Regenerate with `python tests/fixtures/generate.py`. The generator checks its
compressed vectors with Python's gzip/zlib decoders before writing them.
Tests check semantic fields, canonical bytes, owned input independence, every
truncated prefix, corruption, limits, and allocation failure cleanup. Fuzzing
mutates these vectors alongside every encoding/compression combination.

Compression follows [RFC 1952](https://www.rfc-editor.org/rfc/rfc1952) and
[RFC 1950](https://www.rfc-editor.org/rfc/rfc1950). Strict parsing accepts one
member and rejects concatenated members and any suffix; permissive parsing
returns the first member. Zlib preset dictionaries are unsupported.
