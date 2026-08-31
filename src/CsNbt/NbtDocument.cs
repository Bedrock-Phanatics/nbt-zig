using System;
using System.IO;
using System.IO.Compression;

namespace CsNbt;

/// <summary>A named root tag and helpers for reading and writing complete NBT documents.</summary>
public sealed class NbtDocument
{
    public NbtDocument(string name, NbtTag root)
    {
        Name = name ?? throw new ArgumentNullException(nameof(name));
        Root = root ?? throw new ArgumentNullException(nameof(root));
        if (root.Type == NbtTagType.End) throw new ArgumentException("The root tag cannot be End.", nameof(root));
    }

    public string Name { get; }
    public NbtTag Root { get; }

    public static NbtDocument Load(Stream stream, NbtOptions? options = null)
    {
        ArgumentNullException.ThrowIfNull(stream);
        options ??= NbtOptions.Java;
        options.Validate();
        using Stream payload = WrapRead(stream, options);
        return new NbtReader(payload, options).ReadDocument();
    }

    public static NbtDocument Parse(ReadOnlySpan<byte> data, NbtOptions? options = null)
    {
        options ??= NbtOptions.Java;
        using var stream = new MemoryStream(data.ToArray(), writable: false);
        return Load(stream, options with { LeaveOpen = false });
    }

    /// <summary>Parses an NBT document without copying the source array.</summary>
    public static NbtDocument Parse(byte[] data, NbtOptions? options = null)
    {
        ArgumentNullException.ThrowIfNull(data);
        options ??= NbtOptions.Java;
        using var stream = new MemoryStream(data, writable: false);
        return Load(stream, options with { LeaveOpen = false });
    }

    public void Save(Stream stream, NbtOptions? options = null)
    {
        ArgumentNullException.ThrowIfNull(stream);
        options ??= NbtOptions.Java;
        options.Validate();
        using Stream payload = WrapWrite(stream, options);
        new NbtWriter(payload, options).WriteDocument(this);
    }

    public byte[] ToArray(NbtOptions? options = null)
    {
        using var stream = new MemoryStream();
        Save(stream, (options ?? NbtOptions.Java) with { LeaveOpen = true });
        return stream.ToArray();
    }

    private static Stream WrapRead(Stream stream, NbtOptions options) => options.Compression switch
    {
        NbtCompression.None => options.LeaveOpen ? new NonDisposingStream(stream) : stream,
        NbtCompression.GZip => new GZipStream(stream, CompressionMode.Decompress, options.LeaveOpen),
        NbtCompression.ZLib => new ZLibStream(stream, CompressionMode.Decompress, options.LeaveOpen),
        _ => throw new ArgumentOutOfRangeException(nameof(options)),
    };

    private static Stream WrapWrite(Stream stream, NbtOptions options) => options.Compression switch
    {
        NbtCompression.None => options.LeaveOpen ? new NonDisposingStream(stream) : stream,
        NbtCompression.GZip => new GZipStream(stream, CompressionLevel.Fastest, options.LeaveOpen),
        NbtCompression.ZLib => new ZLibStream(stream, CompressionLevel.Fastest, options.LeaveOpen),
        _ => throw new ArgumentOutOfRangeException(nameof(options)),
    };

    private sealed class NonDisposingStream(Stream inner) : Stream
    {
        public override bool CanRead => inner.CanRead;
        public override bool CanSeek => inner.CanSeek;
        public override bool CanWrite => inner.CanWrite;
        public override long Length => inner.Length;
        public override long Position { get => inner.Position; set => inner.Position = value; }
        public override void Flush() => inner.Flush();
        public override int Read(byte[] buffer, int offset, int count) => inner.Read(buffer, offset, count);
        public override int Read(Span<byte> buffer) => inner.Read(buffer);
        public override long Seek(long offset, SeekOrigin origin) => inner.Seek(offset, origin);
        public override void SetLength(long value) => inner.SetLength(value);
        public override void Write(byte[] buffer, int offset, int count) => inner.Write(buffer, offset, count);
        public override void Write(ReadOnlySpan<byte> buffer) => inner.Write(buffer);
    }
}
