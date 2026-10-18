const std = @import("std");

pub const Encoding = enum {
    java,
    bedrock,
    bedrock_network,
};

pub const Compression = enum {
    none,
    gzip,
    zlib,
};

/// Encoding and string handling together, so codecs can specialize on both at compile time.
pub const Format = enum {
    java,
    bedrock,
    bedrock_network,
    java_raw,
    bedrock_raw,
    bedrock_network_raw,

    pub fn encoding(self: Format) Encoding {
        return @fromBackingInt(@backingInt(self) % 3);
    }

    pub fn rawStrings(self: Format) bool {
        return @backingInt(self) >= 3;
    }
};

pub const DuplicateNames = enum {
    /// Fail with `error.DuplicateName`.
    reject,
    /// Keep the first value and drop later ones, like PocketMine does for old worlds.
    keep_first,
};

pub const Options = struct {
    encoding: Encoding = .java,
    compression: Compression = .none,

    max_depth: usize = 512,
    max_collection_length: usize = 16 * 1024 * 1024,
    max_compound_entries: usize = 16 * 1024 * 1024,
    max_string_bytes: usize = 1024 * 1024,
    /// Applies to TAG_Byte_Array on top of `max_collection_length`.
    max_byte_array_length: usize = std.math.maxInt(usize),

    max_input_bytes: usize = 256 * 1024 * 1024,
    max_decompressed_bytes: usize = 256 * 1024 * 1024,
    max_output_bytes: usize = 256 * 1024 * 1024,
    max_total_decoded_bytes: usize = 256 * 1024 * 1024,

    reject_trailing_bytes: bool = false,
    /// Network varints with redundant trailing zero groups fail with `error.NonCanonicalVarInt`.
    reject_noncanonical_varints: bool = false,
    /// Strings are opaque bytes: no UTF-8 checks and no modified UTF-8 conversion.
    raw_strings: bool = false,
    duplicate_names: DuplicateNames = .reject,

    /// Deepest nesting any option set may allow, which also bounds the scanner's fixed stack.
    pub const max_supported_depth = 512;

    pub const java: Options = .{};

    pub const bedrock: Options = .{
        .encoding = .bedrock,
    };

    pub const bedrock_network: Options = .{
        .encoding = .bedrock_network,
    };

    pub fn format(self: Options) Format {
        const offset: u3 = if (self.raw_strings) 3 else 0;
        return @fromBackingInt(@as(u3, @backingInt(self.encoding)) + offset);
    }

    pub fn validate(self: Options) error{InvalidOptions}!void {
        const invalid =
            self.max_depth == 0 or
            self.max_depth > max_supported_depth or
            self.max_input_bytes == 0 or
            self.max_decompressed_bytes == 0 or
            self.max_output_bytes == 0 or
            self.max_total_decoded_bytes == 0;

        if (invalid) return error.InvalidOptions;
    }
};
