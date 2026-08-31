using System;
using System.Collections.Generic;
using System.IO;
using CsNbt;

var tests = new (string Name, Action Body)[]
{
    ("Java golden payload", JavaGoldenPayload),
    ("Java modified UTF-8", JavaModifiedUtf8),
    ("All encodings round trip", AllEncodingsRoundTrip),
    ("Bedrock network uses signed lengths", NetworkLengthGoldenPayload),
    ("Compression round trip", CompressionRoundTrip),
    ("Malformed input is rejected", MalformedInput),
    ("Limits are enforced", LimitsAreEnforced),
    ("Invalid options are rejected", InvalidOptionsAreRejected),
    ("Invalid UTF-16 is rejected", InvalidUtf16IsRejected),
    ("Homogeneous lists are enforced", HomogeneousLists),
};

foreach ((string name, Action body) in tests)
{
    body();
    Console.WriteLine($"PASS {name}");
}

static void JavaGoldenPayload()
{
    var document = new NbtDocument("hello world", new NbtCompound().Add("name", "Bananrama"));
    byte[] expected = Convert.FromHexString("0A000B68656C6C6F20776F726C640800046E616D65000942616E616E72616D6100");
    EqualBytes(expected, document.ToArray());
    var parsed = NbtDocument.Parse(expected);
    Equal("Bananrama", As<NbtCompound>(parsed.Root).Get<NbtString>("name").Value);
}

static void JavaModifiedUtf8()
{
    var document = new NbtDocument("\0😀", new NbtString("\0😀"));
    byte[] data = document.ToArray();
    EqualBytes(Convert.FromHexString("080008C080EDA0BDEDB8800008C080EDA0BDEDB880"), data);
    NbtDocument parsed = NbtDocument.Parse(data);
    Equal("\0😀", parsed.Name);
    Equal("\0😀", As<NbtString>(parsed.Root).Value);
}

static void AllEncodingsRoundTrip()
{
    foreach (NbtOptions options in new[] { NbtOptions.Java, NbtOptions.Bedrock, NbtOptions.BedrockNetwork })
    {
        NbtDocument parsed = NbtDocument.Parse(CreateDocument().ToArray(options), options);
        var root = As<NbtCompound>(parsed.Root);
        Equal(-123456, root.Get<NbtInt>("int").Value);
        Equal(-9_876_543_210L, root.Get<NbtLong>("long").Value);
        Equal("héllø 🌍", root.Get<NbtString>("text").Value);
        Equal(3, root.Get<NbtList>("list").Count);
        Equal(4, root.Get<NbtByteArray>("bytes").Value.Length);
    }
}

static void NetworkLengthGoldenPayload()
{
    var document = new NbtDocument(string.Empty, new NbtList(NbtTagType.Byte).Add(new NbtByte(127)));
    EqualBytes(new byte[] { 9, 0, 1, 2, 127 }, document.ToArray(NbtOptions.BedrockNetwork));
}

static void CompressionRoundTrip()
{
    foreach (NbtCompression compression in new[] { NbtCompression.GZip, NbtCompression.ZLib })
    {
        NbtOptions options = NbtOptions.Java with { Compression = compression };
        byte[] data = CreateDocument().ToArray(options);
        Equal(-123456, As<NbtCompound>(NbtDocument.Parse(data, options).Root).Get<NbtInt>("int").Value);
    }
}

static void MalformedInput()
{
    Throws<NbtException>(() => NbtDocument.Parse(new byte[] { 99 }));
    Throws<EndOfStreamException>(() => NbtDocument.Parse(new byte[] { 10, 0, 0 }));
    byte[] invalidNetworkVarInt = { 3, 0, 0xff, 0xff, 0xff, 0xff, 0x1f };
    Throws<NbtException>(() => NbtDocument.Parse(invalidNetworkVarInt, NbtOptions.BedrockNetwork));
}

static void LimitsAreEnforced()
{
    NbtOptions writeLimits = NbtOptions.Java with { MaxStringBytes = 2 };
    Throws<NbtException>(() => new NbtDocument("root", new NbtInt(1)).ToArray(writeLimits));
    NbtOptions readLimits = NbtOptions.Java with { MaxCollectionLength = 2 };
    Throws<NbtException>(() => NbtDocument.Parse(CreateDocument().ToArray(), readLimits));

    var compound = new NbtDocument(string.Empty, new NbtCompound().Add("a", 1).Add("b", 2));
    NbtOptions compoundLimit = NbtOptions.Java with { MaxCollectionLength = 1 };
    Throws<NbtException>(() => compound.ToArray(compoundLimit));
    Throws<NbtException>(() => NbtDocument.Parse(compound.ToArray(), compoundLimit));
}

static void InvalidOptionsAreRejected()
{
    Throws<ArgumentOutOfRangeException>(() => CreateDocument().ToArray(
        NbtOptions.Java with { Encoding = (NbtEncoding)99 }));
    Throws<ArgumentOutOfRangeException>(() => CreateDocument().ToArray(
        NbtOptions.Java with { Compression = (NbtCompression)99 }));
}

static void InvalidUtf16IsRejected()
{
    var document = new NbtDocument(string.Empty, new NbtString("\ud800"));
    Throws<NbtException>(() => document.ToArray(NbtOptions.Bedrock));
    Throws<NbtException>(() => document.ToArray(NbtOptions.BedrockNetwork));
}

static void HomogeneousLists()
{
    var list = new NbtList(NbtTagType.Int).Add(1);
    Throws<ArgumentException>(() => list.Add("wrong"));
}

static NbtDocument CreateDocument()
{
    var root = new NbtCompound()
        .Add("byte", new NbtByte(255))
        .Add("short", new NbtShort(-3210))
        .Add("int", -123456)
        .Add("long", -9_876_543_210L)
        .Add("float", new NbtFloat(1.25f))
        .Add("double", new NbtDouble(-99.125))
        .Add("text", "héllø 🌍")
        .Add("bytes", new byte[] { 0, 1, 127, 255 })
        .Add("ints", new int[] { int.MinValue, 0, int.MaxValue })
        .Add("longs", new long[] { long.MinValue, 0, long.MaxValue })
        .Add("list", new NbtList(NbtTagType.String).Add("a").Add("b").Add("c"))
        .Add("nested", new NbtCompound().Add("yes", new NbtByte(1)));
    return new NbtDocument("root", root);
}

static T As<T>(NbtTag tag) where T : NbtTag => tag as T ?? throw new Exception($"Expected {typeof(T).Name}.");
static void Equal<T>(T expected, T actual) where T : notnull
{
    if (!EqualityComparer<T>.Default.Equals(expected, actual)) throw new Exception($"Expected {expected}, received {actual}.");
}
static void EqualBytes(byte[] expected, byte[] actual)
{
    if (!expected.AsSpan().SequenceEqual(actual)) throw new Exception($"Expected {Convert.ToHexString(expected)}, received {Convert.ToHexString(actual)}.");
}
static void Throws<T>(Action action) where T : Exception
{
    try { action(); }
    catch (T) { return; }
    throw new Exception($"Expected {typeof(T).Name}.");
}
