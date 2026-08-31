using System;
using System.Collections;
using System.Collections.Generic;

namespace CsNbt;

/// <summary>Base class for values in an NBT tree.</summary>
public abstract class NbtTag
{
    public abstract NbtTagType Type { get; }

    public static implicit operator NbtTag(byte value) => new NbtByte(value);
    public static implicit operator NbtTag(sbyte value) => new NbtByte(unchecked((byte)value));
    public static implicit operator NbtTag(short value) => new NbtShort(value);
    public static implicit operator NbtTag(int value) => new NbtInt(value);
    public static implicit operator NbtTag(long value) => new NbtLong(value);
    public static implicit operator NbtTag(float value) => new NbtFloat(value);
    public static implicit operator NbtTag(double value) => new NbtDouble(value);
    public static implicit operator NbtTag(string value) => new NbtString(value);
    public static implicit operator NbtTag(byte[] value) => new NbtByteArray(value);
    public static implicit operator NbtTag(int[] value) => new NbtIntArray(value);
    public static implicit operator NbtTag(long[] value) => new NbtLongArray(value);
}

public sealed class NbtByte(byte value) : NbtTag { public override NbtTagType Type => NbtTagType.Byte; public byte Value { get; } = value; public bool BooleanValue => Value != 0; }
public sealed class NbtShort(short value) : NbtTag { public override NbtTagType Type => NbtTagType.Short; public short Value { get; } = value; }
public sealed class NbtInt(int value) : NbtTag { public override NbtTagType Type => NbtTagType.Int; public int Value { get; } = value; }
public sealed class NbtLong(long value) : NbtTag { public override NbtTagType Type => NbtTagType.Long; public long Value { get; } = value; }
public sealed class NbtFloat(float value) : NbtTag { public override NbtTagType Type => NbtTagType.Float; public float Value { get; } = value; }
public sealed class NbtDouble(double value) : NbtTag { public override NbtTagType Type => NbtTagType.Double; public double Value { get; } = value; }
public sealed class NbtString : NbtTag
{
    public NbtString(string value) => Value = value ?? throw new ArgumentNullException(nameof(value));
    public override NbtTagType Type => NbtTagType.String;
    public string Value { get; }
}

public sealed class NbtByteArray : NbtTag
{
    public NbtByteArray(byte[] value) => Value = value ?? throw new ArgumentNullException(nameof(value));
    public override NbtTagType Type => NbtTagType.ByteArray;
    public byte[] Value { get; }
}

public sealed class NbtIntArray : NbtTag
{
    public NbtIntArray(int[] value) => Value = value ?? throw new ArgumentNullException(nameof(value));
    public override NbtTagType Type => NbtTagType.IntArray;
    public int[] Value { get; }
}

public sealed class NbtLongArray : NbtTag
{
    public NbtLongArray(long[] value) => Value = value ?? throw new ArgumentNullException(nameof(value));
    public override NbtTagType Type => NbtTagType.LongArray;
    public long[] Value { get; }
}

/// <summary>A homogeneous NBT list.</summary>
public sealed class NbtList : NbtTag, IReadOnlyList<NbtTag>
{
    private readonly List<NbtTag> _items;

    public NbtList(NbtTagType elementType, int capacity = 0)
    {
        if (elementType is < NbtTagType.End or > NbtTagType.LongArray) throw new ArgumentOutOfRangeException(nameof(elementType));
        ElementType = elementType;
        _items = new List<NbtTag>(capacity);
    }

    public override NbtTagType Type => NbtTagType.List;
    public NbtTagType ElementType { get; }
    public int Count => _items.Count;
    public NbtTag this[int index] => _items[index];

    public NbtList Add(NbtTag item)
    {
        ArgumentNullException.ThrowIfNull(item);
        if (item.Type != ElementType || item.Type == NbtTagType.End)
            throw new ArgumentException($"Expected {ElementType}, received {item.Type}.", nameof(item));
        _items.Add(item);
        return this;
    }

    public IEnumerator<NbtTag> GetEnumerator() => _items.GetEnumerator();
    IEnumerator IEnumerable.GetEnumerator() => GetEnumerator();
}

/// <summary>An insertion-ordered mapping from names to NBT tags.</summary>
public sealed class NbtCompound : NbtTag, IReadOnlyDictionary<string, NbtTag>
{
    private readonly Dictionary<string, NbtTag> _values;

    public NbtCompound(int capacity = 0) => _values = new Dictionary<string, NbtTag>(capacity, StringComparer.Ordinal);
    public override NbtTagType Type => NbtTagType.Compound;
    public int Count => _values.Count;
    public IEnumerable<string> Keys => _values.Keys;
    public IEnumerable<NbtTag> Values => _values.Values;
    public NbtTag this[string key] { get => _values[key]; set => _values[key] = value ?? throw new ArgumentNullException(nameof(value)); }

    public NbtCompound Add(string name, NbtTag value) { _values.Add(name, value); return this; }
    public bool ContainsKey(string key) => _values.ContainsKey(key);
    public bool TryGetValue(string key, out NbtTag value) => _values.TryGetValue(key, out value!);
    public bool Remove(string key) => _values.Remove(key);
    public T Get<T>(string key) where T : NbtTag => _values[key] as T ?? throw new InvalidCastException($"Tag '{key}' is not {typeof(T).Name}.");
    public bool TryGet<T>(string key, out T? value) where T : NbtTag { value = _values.GetValueOrDefault(key) as T; return value is not null; }
    public IEnumerator<KeyValuePair<string, NbtTag>> GetEnumerator() => _values.GetEnumerator();
    IEnumerator IEnumerable.GetEnumerator() => GetEnumerator();
}
