const nbt = @import("nbt");

pub const Fixture = struct {
    name: []const u8,
    bytes: []const u8,
    options: nbt.Options,
};

pub const documents = [_]Fixture{
    .{ .name = "bedrock-item", .bytes = @embedFile("item.bedrock.nbt"), .options = .bedrock },
    .{ .name = "bedrock-entity", .bytes = @embedFile("entity.bedrock.nbt"), .options = .bedrock },
    .{ .name = "bedrock-structure", .bytes = @embedFile("structure.bedrock.nbt"), .options = .bedrock },
    .{ .name = "network-entity", .bytes = @embedFile("entity.network.nbt"), .options = .bedrock_network },
    .{ .name = "java-level", .bytes = @embedFile("level.java.nbt"), .options = .java },
};

pub const compressed = [_]Fixture{
    .{ .name = "external-gzip", .bytes = @embedFile("level.java.gz"), .options = .{ .compression = .gzip } },
    .{ .name = "external-zlib", .bytes = @embedFile("level.java.zlib"), .options = .{ .compression = .zlib } },
    .{ .name = "optional-gzip", .bytes = @embedFile("level.optional.gz"), .options = .{ .compression = .gzip } },
    .{ .name = "fixed-zlib", .bytes = @embedFile("level.fixed.zlib"), .options = .{ .compression = .zlib } },
    .{ .name = "stored-zlib", .bytes = @embedFile("level.stored.zlib"), .options = .{ .compression = .zlib } },
};
