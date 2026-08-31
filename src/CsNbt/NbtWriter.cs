using System;
using System.IO;
using CsNbt.Internal;

namespace CsNbt;

/// <summary>Writer for complete NBT trees.</summary>
public sealed class NbtWriter
{
    private readonly NbtBinary _binary;
    private readonly NbtOptions _options;

    public NbtWriter(Stream stream, NbtOptions? options = null)
    {
        ArgumentNullException.ThrowIfNull(stream);
        _options = options ?? NbtOptions.Java;
        _options.Validate();
        _binary = new NbtBinary(stream, _options);
    }

    public void WriteDocument(NbtDocument document)
    {
        ArgumentNullException.ThrowIfNull(document);
        _binary.WriteByte((byte)document.Root.Type);
        _binary.WriteString(document.Name);
        WritePayload(document.Root, 0);
    }

    private void WritePayload(NbtTag tag, int depth)
    {
        if (depth >= _options.MaxDepth) throw new NbtException($"NBT nesting exceeds the configured depth of {_options.MaxDepth}.");
        switch (tag)
        {
            case NbtByte value: _binary.WriteByte(value.Value); break;
            case NbtShort value: _binary.WriteInt16(value.Value); break;
            case NbtInt value: _binary.WriteInt32(value.Value); break;
            case NbtLong value: _binary.WriteInt64(value.Value); break;
            case NbtFloat value: _binary.WriteSingle(value.Value); break;
            case NbtDouble value: _binary.WriteDouble(value.Value); break;
            case NbtString value: _binary.WriteString(value.Value); break;
            case NbtByteArray value: _binary.WriteLength(value.Value.Length); _binary.Write(value.Value); break;
            case NbtIntArray value:
                _binary.WriteLength(value.Value.Length);
                foreach (int item in value.Value) _binary.WriteInt32(item);
                break;
            case NbtLongArray value:
                _binary.WriteLength(value.Value.Length);
                foreach (long item in value.Value) _binary.WriteInt64(item);
                break;
            case NbtList value:
                _binary.WriteByte((byte)value.ElementType);
                _binary.WriteLength(value.Count);
                foreach (NbtTag item in value) WritePayload(item, depth + 1);
                break;
            case NbtCompound value:
                if (value.Count > _options.MaxCollectionLength)
                    throw new NbtException($"Compound entry count {value.Count} exceeds the configured limit.");
                foreach ((string name, NbtTag item) in value)
                {
                    _binary.WriteByte((byte)item.Type);
                    _binary.WriteString(name);
                    WritePayload(item, depth + 1);
                }
                _binary.WriteByte((byte)NbtTagType.End);
                break;
            default: throw new NbtException($"Unsupported tag implementation {tag.GetType().FullName}.");
        }
    }
}
