using System;
using System.Buffers;
using System.Buffers.Binary;
using System.IO;
using System.Text;

namespace CsNbt.Internal;

internal sealed class NbtBinary
{
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);
    private readonly Stream _stream;
    private readonly NbtOptions _options;
    private readonly bool _littleEndian;
    private readonly bool _varInt;

    public NbtBinary(Stream stream, NbtOptions options)
    {
        _stream = stream;
        _options = options;
        _littleEndian = options.Encoding != NbtEncoding.Java;
        _varInt = options.Encoding == NbtEncoding.BedrockNetwork;
    }

    public byte ReadByte()
    {
        int value = _stream.ReadByte();
        if (value < 0) throw new EndOfStreamException();
        return (byte)value;
    }

    public short ReadInt16()
    {
        Span<byte> data = stackalloc byte[2];
        _stream.ReadExactly(data);
        return _littleEndian ? BinaryPrimitives.ReadInt16LittleEndian(data) : BinaryPrimitives.ReadInt16BigEndian(data);
    }

    public int ReadInt32()
    {
        if (_varInt) return DecodeZigZag32(ReadVarUInt32());
        Span<byte> data = stackalloc byte[4];
        _stream.ReadExactly(data);
        return _littleEndian ? BinaryPrimitives.ReadInt32LittleEndian(data) : BinaryPrimitives.ReadInt32BigEndian(data);
    }

    public long ReadInt64()
    {
        if (_varInt) return DecodeZigZag64(ReadVarUInt64());
        Span<byte> data = stackalloc byte[8];
        _stream.ReadExactly(data);
        return _littleEndian ? BinaryPrimitives.ReadInt64LittleEndian(data) : BinaryPrimitives.ReadInt64BigEndian(data);
    }

    public float ReadSingle()
    {
        Span<byte> data = stackalloc byte[4];
        _stream.ReadExactly(data);
        int bits = _littleEndian ? BinaryPrimitives.ReadInt32LittleEndian(data) : BinaryPrimitives.ReadInt32BigEndian(data);
        return BitConverter.Int32BitsToSingle(bits);
    }

    public double ReadDouble()
    {
        Span<byte> data = stackalloc byte[8];
        _stream.ReadExactly(data);
        long bits = _littleEndian ? BinaryPrimitives.ReadInt64LittleEndian(data) : BinaryPrimitives.ReadInt64BigEndian(data);
        return BitConverter.Int64BitsToDouble(bits);
    }

    public int ReadLength()
    {
        int value = ReadInt32();
        if ((uint)value > (uint)_options.MaxCollectionLength) throw new NbtException($"Collection length {value} is invalid or exceeds the configured limit.");
        return value;
    }

    public string ReadString()
    {
        if (!_littleEndian) return ReadModifiedUtf8();
        int length = _varInt ? checked((int)ReadVarUInt32()) : unchecked((ushort)ReadInt16());
        if ((uint)length > (uint)_options.MaxStringBytes) throw new NbtException($"String length {length} exceeds the configured limit.");
        if (length == 0) return string.Empty;
        byte[] rented = ArrayPool<byte>.Shared.Rent(length);
        try
        {
            _stream.ReadExactly(rented.AsSpan(0, length));
            return StrictUtf8.GetString(rented, 0, length);
        }
        catch (DecoderFallbackException exception) { throw new NbtException("String contains invalid UTF-8.", exception); }
        finally { ArrayPool<byte>.Shared.Return(rented); }
    }

    public void WriteByte(byte value) => _stream.WriteByte(value);

    public void WriteInt16(short value)
    {
        Span<byte> data = stackalloc byte[2];
        if (_littleEndian) BinaryPrimitives.WriteInt16LittleEndian(data, value); else BinaryPrimitives.WriteInt16BigEndian(data, value);
        _stream.Write(data);
    }

    public void WriteInt32(int value)
    {
        if (_varInt) { WriteVarUInt32(EncodeZigZag32(value)); return; }
        Span<byte> data = stackalloc byte[4];
        if (_littleEndian) BinaryPrimitives.WriteInt32LittleEndian(data, value); else BinaryPrimitives.WriteInt32BigEndian(data, value);
        _stream.Write(data);
    }

    public void WriteInt64(long value)
    {
        if (_varInt) { WriteVarUInt64(EncodeZigZag64(value)); return; }
        Span<byte> data = stackalloc byte[8];
        if (_littleEndian) BinaryPrimitives.WriteInt64LittleEndian(data, value); else BinaryPrimitives.WriteInt64BigEndian(data, value);
        _stream.Write(data);
    }

    public void WriteSingle(float value)
    {
        Span<byte> data = stackalloc byte[4];
        if (_littleEndian) BinaryPrimitives.WriteSingleLittleEndian(data, value); else BinaryPrimitives.WriteSingleBigEndian(data, value);
        _stream.Write(data);
    }

    public void WriteDouble(double value)
    {
        Span<byte> data = stackalloc byte[8];
        if (_littleEndian) BinaryPrimitives.WriteDoubleLittleEndian(data, value); else BinaryPrimitives.WriteDoubleBigEndian(data, value);
        _stream.Write(data);
    }

    public void WriteLength(int value)
    {
        if ((uint)value > (uint)_options.MaxCollectionLength) throw new NbtException($"Collection length {value} exceeds the configured limit.");
        WriteInt32(value);
    }

    public void WriteString(string value)
    {
        if (!_littleEndian) { WriteModifiedUtf8(value); return; }
        int length;
        try
        {
            length = StrictUtf8.GetByteCount(value);
        }
        catch (EncoderFallbackException exception)
        {
            throw new NbtException("String contains invalid UTF-16.", exception);
        }
        int formatMaximum = _varInt ? int.MaxValue : ushort.MaxValue;
        if (length > _options.MaxStringBytes || length > formatMaximum) throw new NbtException($"Encoded string length {length} exceeds the configured or format limit.");
        if (_varInt) WriteVarUInt32((uint)length); else WriteInt16(unchecked((short)(ushort)length));
        if (length == 0) return;
        byte[] rented = ArrayPool<byte>.Shared.Rent(length);
        try
        {
            int written = StrictUtf8.GetBytes(value, rented);
            _stream.Write(rented, 0, written);
        }
        finally { ArrayPool<byte>.Shared.Return(rented); }
    }

    public void ReadExactly(Span<byte> destination) => _stream.ReadExactly(destination);
    public void Write(ReadOnlySpan<byte> source) => _stream.Write(source);

    private uint ReadVarUInt32()
    {
        uint value = 0;
        for (int shift = 0; shift < 35; shift += 7)
        {
            byte current = ReadByte();
            if (shift == 28 && (current & 0xf0) != 0) throw new NbtException("VarUInt32 overflow.");
            value |= (uint)(current & 0x7f) << shift;
            if ((current & 0x80) == 0) return value;
        }
        throw new NbtException("Malformed VarUInt32.");
    }

    private ulong ReadVarUInt64()
    {
        ulong value = 0;
        for (int shift = 0; shift < 70; shift += 7)
        {
            byte current = ReadByte();
            if (shift == 63 && (current & 0xfe) != 0) throw new NbtException("VarUInt64 overflow.");
            value |= (ulong)(current & 0x7f) << shift;
            if ((current & 0x80) == 0) return value;
        }
        throw new NbtException("Malformed VarUInt64.");
    }

    private void WriteVarUInt32(uint value)
    {
        while (value >= 0x80) { WriteByte((byte)(value | 0x80)); value >>= 7; }
        WriteByte((byte)value);
    }

    private void WriteVarUInt64(ulong value)
    {
        while (value >= 0x80) { WriteByte((byte)(value | 0x80)); value >>= 7; }
        WriteByte((byte)value);
    }

    private static int DecodeZigZag32(uint value) => (int)(value >> 1) ^ -((int)value & 1);
    private static long DecodeZigZag64(ulong value) => (long)(value >> 1) ^ -((long)value & 1);
    private static uint EncodeZigZag32(int value) => (uint)((value << 1) ^ (value >> 31));
    private static ulong EncodeZigZag64(long value) => (ulong)((value << 1) ^ (value >> 63));

    private string ReadModifiedUtf8()
    {
        int length = unchecked((ushort)ReadInt16());
        if (length > _options.MaxStringBytes) throw new NbtException($"String length {length} exceeds the configured limit.");
        if (length == 0) return string.Empty;
        byte[] bytes = ArrayPool<byte>.Shared.Rent(length);
        char[] chars = ArrayPool<char>.Shared.Rent(length);
        try
        {
            _stream.ReadExactly(bytes.AsSpan(0, length));
            int source = 0;
            int destination = 0;
            while (source < length)
            {
                byte first = bytes[source++];
                if ((first & 0x80) == 0)
                {
                    chars[destination++] = (char)first;
                    continue;
                }
                if ((first & 0xe0) == 0xc0)
                {
                    if (source >= length) throw new NbtException("Truncated modified UTF-8 sequence.");
                    byte second = bytes[source++];
                    if ((second & 0xc0) != 0x80) throw new NbtException("Invalid modified UTF-8 continuation byte.");
                    chars[destination++] = (char)(((first & 0x1f) << 6) | (second & 0x3f));
                    continue;
                }
                if ((first & 0xf0) == 0xe0)
                {
                    if (source + 1 >= length) throw new NbtException("Truncated modified UTF-8 sequence.");
                    byte second = bytes[source++];
                    byte third = bytes[source++];
                    if ((second & 0xc0) != 0x80 || (third & 0xc0) != 0x80) throw new NbtException("Invalid modified UTF-8 continuation byte.");
                    chars[destination++] = (char)(((first & 0x0f) << 12) | ((second & 0x3f) << 6) | (third & 0x3f));
                    continue;
                }
                throw new NbtException("Invalid modified UTF-8 leading byte.");
            }
            return new string(chars, 0, destination);
        }
        finally
        {
            ArrayPool<byte>.Shared.Return(bytes);
            ArrayPool<char>.Shared.Return(chars);
        }
    }

    private void WriteModifiedUtf8(string value)
    {
        int length = 0;
        foreach (char character in value)
        {
            length = checked(length + (character is >= (char)1 and <= (char)0x7f ? 1 : character <= 0x7ff ? 2 : 3));
        }
        if (length > _options.MaxStringBytes || length > ushort.MaxValue) throw new NbtException($"Encoded string length {length} exceeds the configured or format limit.");
        WriteInt16(unchecked((short)(ushort)length));
        if (length == 0) return;
        byte[] bytes = ArrayPool<byte>.Shared.Rent(length);
        try
        {
            int offset = 0;
            foreach (char character in value)
            {
                if (character is >= (char)1 and <= (char)0x7f)
                {
                    bytes[offset++] = (byte)character;
                }
                else if (character <= 0x7ff)
                {
                    bytes[offset++] = (byte)(0xc0 | (character >> 6));
                    bytes[offset++] = (byte)(0x80 | (character & 0x3f));
                }
                else
                {
                    bytes[offset++] = (byte)(0xe0 | (character >> 12));
                    bytes[offset++] = (byte)(0x80 | ((character >> 6) & 0x3f));
                    bytes[offset++] = (byte)(0x80 | (character & 0x3f));
                }
            }
            _stream.Write(bytes, 0, length);
        }
        finally { ArrayPool<byte>.Shared.Return(bytes); }
    }
}
