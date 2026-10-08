"""Independent, deterministic Minecraft-shaped NBT and Python zlib/gzip vectors."""
import gzip
from pathlib import Path
import struct
import zlib

ROOT = Path(__file__).resolve().parent


def varuint(value):
    result = bytearray()
    while value >= 128:
        result.append((value & 127) | 128)
        value >>= 7
    result.append(value)
    return bytes(result)


def encode(root, encoding, name=""):
    endian = ">" if encoding == "java" else "<"

    def integer(value, width):
        if encoding == "network":
            return varuint((value << 1) ^ (value >> (width - 1)))
        return struct.pack(endian + ("i" if width == 32 else "q"), value)

    def string(value):
        if encoding == "java":
            units = struct.unpack(">" + "H" * (len(value.encode("utf-16-be")) // 2), value.encode("utf-16-be"))
            data = bytearray()
            for unit in units:
                if 1 <= unit <= 127:
                    data.append(unit)
                elif unit <= 2047:
                    data.extend((192 | (unit >> 6), 128 | (unit & 63)))
                else:
                    data.extend((224 | (unit >> 12), 128 | ((unit >> 6) & 63), 128 | (unit & 63)))
            data = bytes(data)
        else:
            data = value.encode("utf-8")
        length = varuint(len(data)) if encoding == "network" else struct.pack(endian + "H", len(data))
        return length + data

    def payload(kind, value):
        if kind in (1, 2, 5, 6):
            return struct.pack(endian + {1: "b", 2: "h", 5: "f", 6: "d"}[kind], value)
        if kind in (3, 4):
            return integer(value, 32 if kind == 3 else 64)
        if kind == 7:
            return integer(len(value), 32) + value
        if kind == 8:
            return string(value)
        if kind == 9:
            element, items = value
            return bytes((element,)) + integer(len(items), 32) + b"".join(payload(element, item) for item in items)
        if kind == 10:
            return b"".join(bytes((tag,)) + string(key) + payload(tag, item) for key, (tag, item) in value.items()) + b"\0"
        if kind in (11, 12):
            return integer(len(value), 32) + b"".join(integer(item, 32 if kind == 11 else 64) for item in value)
        raise ValueError(kind)

    return b"\x0a" + string(name) + payload(10, root)


def item(slot=0):
    return {
        "Name": (8, "minecraft:diamond_sword"), "Count": (1, 1),
        "Damage": (2, 17), "Slot": (1, slot),
        "tag": (10, {
            "display": (10, {"Name": (8, "\u00a7bBlade \U0001f30d"), "Lore": (9, (8, ["Forged in \u6771\u4eac", "Line two"]))}),
            "ench": (9, (10, [{"id": (2, 16), "lvl": (2, 3)}, {"id": (2, 17), "lvl": (2, 2)}])),
            "Unbreakable": (1, 1),
        }),
    }


ENTITY = {
    "identifier": (8, "minecraft:zombie"), "UniqueID": (4, -9_876_543_210),
    "Pos": (9, (5, [123.5, 64.0, -456.25])), "Motion": (9, (5, [0.0, -0.125, 0.0])),
    "Rotation": (9, (5, [90.0, 0.0])), "Health": (2, 20), "Air": (2, 300),
    "Fire": (2, -1), "OnGround": (1, 1), "Invulnerable": (1, 0),
    "CustomName": (8, "Zombie \U0001f9df"), "CustomNameVisible": (1, 1),
    "Attributes": (9, (10, [
        {"Name": (8, name), "Base": (5, value), "Current": (5, value), "Min": (5, 0.0), "Max": (5, 1024.0)}
        for name, value in [("minecraft:health", 20.0), ("minecraft:movement", 0.23), ("minecraft:attack_damage", 3.0)]
    ])),
    "Inventory": (9, (10, [item(slot) for slot in range(9)])),
    "Tags": (9, (8, ["hostile", "spawned_by_fixture"])),
}

CHEST = {"id": (8, "Chest"), "x": (3, 16), "y": (3, 64), "z": (3, -5),
         "Items": (9, (10, [item(0), item(1)])), "CustomName": (8, "Supplies \u03a9")}
STRUCTURE = {
    "format_version": (3, 1), "size": (9, (3, [16, 16, 16])),
    "structure_world_origin": (9, (3, [16, 64, -5])),
    "structure": (10, {
        "block_indices": (9, (11, [[index % 3 for index in range(4096)], [-1] * 4096])),
        "entities": (9, (10, [ENTITY])),
        "palette": (10, {"default": (10, {
            "block_palette": (9, (10, [
                {"name": (8, name), "states": (10, states), "version": (3, 18168865)}
                for name, states in [("minecraft:air", {}), ("minecraft:stone", {}),
                                     ("minecraft:chest", {"facing_direction": (3, 2)})]
            ])),
            "block_position_data": (10, {"0": (10, {"block_entity_data": (10, CHEST)})}),
        })}),
    }),
}
JAVA = {
    "DataVersion": (3, 4189), "LevelName": (8, "World \x00 \U0001f30d"),
    "RandomSeed": (4, -(2**63)), "SpawnX": (3, 16), "SpawnY": (3, 64), "SpawnZ": (3, -5),
    "Player": (10, {"Pos": (9, (6, [16.5, 64.0, -5.5])), "Inventory": (9, (10, [item()]))}),
    "Sections": (9, (10, [{"Y": (1, 4), "Blocks": (7, bytes(index % 3 for index in range(4096))),
                            "Data": (7, bytes(2048)), "BlockLight": (7, bytes([255]) * 2048)}])),
    "HeightMap": (11, [64 + index % 16 for index in range(256)]),
    "PackedStates": (12, [-(2**63), 2**63 - 1] + [index * 65537 for index in range(1022)]),
    "TileEntities": (9, (10, [CHEST])),
}


def main():
    cases = [("item.bedrock.nbt", item(), "bedrock", ""),
             ("entity.bedrock.nbt", ENTITY, "bedrock", ""),
             ("structure.bedrock.nbt", STRUCTURE, "bedrock", ""),
             ("entity.network.nbt", ENTITY, "network", ""),
             ("level.java.nbt", JAVA, "java", "Data")]
    for filename, root, encoding, name in cases:
        (ROOT / filename).write_bytes(encode(root, encoding, name))
    plain = (ROOT / "level.java.nbt").read_bytes()
    vectors = {"level.java.gz": gzip.compress(plain, compresslevel=6, mtime=0),
               "level.java.zlib": zlib.compress(plain, level=6)}
    base = vectors["level.java.gz"]
    header = base[:3] + b"\x1e" + base[4:10] + b"\x08\0NT\x04\0test" + b"level.dat\0Python interoperability\0"
    vectors["level.optional.gz"] = header + struct.pack("<H", zlib.crc32(header) & 65535) + base[10:]
    for strategy, filename in [(zlib.Z_FIXED, "level.fixed.zlib"), (zlib.Z_DEFAULT_STRATEGY, "level.stored.zlib")]:
        compressor = zlib.compressobj(level=0 if "stored" in filename else 6, strategy=strategy)
        vectors[filename] = compressor.compress(plain) + compressor.flush()
    for filename, data in vectors.items():
        assert (gzip.decompress(data) if filename.endswith("gz") else zlib.decompress(data)) == plain
        (ROOT / filename).write_bytes(data)
    print(f"Wrote {len(cases) + len(vectors)} vectors using Python zlib {zlib.ZLIB_RUNTIME_VERSION}")


if __name__ == "__main__":
    main()
