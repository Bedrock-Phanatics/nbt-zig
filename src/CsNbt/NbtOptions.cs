using System;

namespace CsNbt;

public enum NbtEncoding
{
    Java,
    Bedrock,
    BedrockNetwork,
}

public enum NbtCompression
{
    None,
    GZip,
    ZLib,
}

/// <summary>Codec settings and resource limits. Instances are immutable and reusable.</summary>
public sealed record NbtOptions
{
    public static NbtOptions Java { get; } = new();
    public static NbtOptions Bedrock { get; } = new() { Encoding = NbtEncoding.Bedrock };
    public static NbtOptions BedrockNetwork { get; } = new() { Encoding = NbtEncoding.BedrockNetwork };

    public NbtEncoding Encoding { get; init; } = NbtEncoding.Java;
    public NbtCompression Compression { get; init; }
    public int MaxDepth { get; init; } = 512;
    public int MaxCollectionLength { get; init; } = 16 * 1024 * 1024;
    public int MaxStringBytes { get; init; } = 1 * 1024 * 1024;
    public bool LeaveOpen { get; init; }

    internal void Validate()
    {
        if (!Enum.IsDefined(Encoding)) throw new ArgumentOutOfRangeException(nameof(Encoding));
        if (!Enum.IsDefined(Compression)) throw new ArgumentOutOfRangeException(nameof(Compression));
        if (MaxDepth < 1) throw new ArgumentOutOfRangeException(nameof(MaxDepth));
        if (MaxCollectionLength < 0) throw new ArgumentOutOfRangeException(nameof(MaxCollectionLength));
        if (MaxStringBytes < 0) throw new ArgumentOutOfRangeException(nameof(MaxStringBytes));
    }
}
