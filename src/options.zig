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

/// Parsing and serialization limits.
pub const Options = struct {
    encoding: Encoding = .java,
    compression: Compression = .none,

    max_depth: usize = 512,
    max_collection_length: usize = 16 * 1024 * 1024,
    max_compound_entries: usize = 16 * 1024 * 1024,
    max_string_bytes: usize = 1024 * 1024,

    max_input_bytes: usize = 256 * 1024 * 1024,
    max_decompressed_bytes: usize = 256 * 1024 * 1024,
    max_output_bytes: usize = 256 * 1024 * 1024,
    max_total_decoded_bytes: usize = 256 * 1024 * 1024,

    reject_trailing_bytes: bool = false,

    pub const java: Options = .{};
    pub const bedrock: Options = .{
        .encoding = .bedrock,
    };
    pub const bedrock_network: Options = .{
        .encoding = .bedrock_network,
    };

    pub fn validate(self: Options) error{InvalidOptions}!void {
        if (self.max_depth == 0 or
            self.max_depth > 512 or
            self.max_input_bytes == 0 or
            self.max_decompressed_bytes == 0 or
            self.max_output_bytes == 0 or
            self.max_total_decoded_bytes == 0)
        {
            return error.InvalidOptions;
        }
    }
};
