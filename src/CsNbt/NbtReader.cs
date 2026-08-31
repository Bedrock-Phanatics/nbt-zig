using System;
using System.IO;
using CsNbt.Internal;

namespace CsNbt;

/// <summary>Forward-only reader for complete NBT trees.</summary>
public sealed class NbtReader
{
    private readonly NbtBinary _binary;
    private readonly NbtOptions _options;

    public NbtReader(Stream stream, NbtOptions? options = null)
    {
        ArgumentNullException.ThrowIfNull(stream);
        _options = options ?? NbtOptions.Java;
        _options.Validate();
        _binary = new NbtBinary(stream, _options);
    }

    public NbtDocument ReadDocument()
    {
        NbtTagType type = ReadType();
        if (type == NbtTagType.End) throw new NbtException("The root tag cannot be End.");
        string name = _binary.ReadString();
        return new NbtDocument(name, ReadPayload(type, 0));
    }

    private NbtTag ReadPayload(NbtTagType type, int depth)
    {
        if (depth >= _options.MaxDepth) throw new NbtException($"NBT nesting exceeds the configured depth of {_options.MaxDepth}.");
        return type switch
        {
            NbtTagType.Byte => new NbtByte(_binary.ReadByte()),
            NbtTagType.Short => new NbtShort(_binary.ReadInt16()),
            NbtTagType.Int => new NbtInt(_binary.ReadInt32()),
            NbtTagType.Long => new NbtLong(_binary.ReadInt64()),
            NbtTagType.Float => new NbtFloat(_binary.ReadSingle()),
            NbtTagType.Double => new NbtDouble(_binary.ReadDouble()),
            NbtTagType.ByteArray => ReadByteArray(),
            NbtTagType.String => new NbtString(_binary.ReadString()),
            NbtTagType.List => ReadList(depth + 1),
            NbtTagType.Compound => ReadCompound(depth + 1),
            NbtTagType.IntArray => ReadIntArray(),
            NbtTagType.LongArray => ReadLongArray(),
            _ => throw new NbtException($"Invalid payload tag type {(byte)type}.")
        };
    }

    private NbtByteArray ReadByteArray()
    {
        byte[] values = GC.AllocateUninitializedArray<byte>(_binary.ReadLength());
        _binary.ReadExactly(values);
        return new NbtByteArray(values);
    }

    private NbtIntArray ReadIntArray()
    {
        int[] values = GC.AllocateUninitializedArray<int>(_binary.ReadLength());
        for (int i = 0; i < values.Length; i++) values[i] = _binary.ReadInt32();
        return new NbtIntArray(values);
    }

    private NbtLongArray ReadLongArray()
    {
        long[] values = GC.AllocateUninitializedArray<long>(_binary.ReadLength());
        for (int i = 0; i < values.Length; i++) values[i] = _binary.ReadInt64();
        return new NbtLongArray(values);
    }

    private NbtList ReadList(int depth)
    {
        NbtTagType elementType = ReadType();
        int length = _binary.ReadLength();
        if (elementType == NbtTagType.End && length != 0) throw new NbtException("A non-empty list cannot have End elements.");
        var list = new NbtList(elementType, length);
        for (int i = 0; i < length; i++) list.Add(ReadPayload(elementType, depth));
        return list;
    }

    private NbtCompound ReadCompound(int depth)
    {
        var compound = new NbtCompound();
        int count = 0;
        while (true)
        {
            NbtTagType type = ReadType();
            if (type == NbtTagType.End) return compound;
            if (++count > _options.MaxCollectionLength)
                throw new NbtException($"Compound entry count exceeds the configured limit of {_options.MaxCollectionLength}.");
            string name = _binary.ReadString();
            try { compound.Add(name, ReadPayload(type, depth)); }
            catch (ArgumentException exception) { throw new NbtException($"Compound contains duplicate name '{name}'.", exception); }
        }
    }

    private NbtTagType ReadType()
    {
        byte value = _binary.ReadByte();
        if (value > (byte)NbtTagType.LongArray) throw new NbtException($"Unknown tag type {value}.");
        return (NbtTagType)value;
    }
}
