# CsNbt

CsNbt is a compact, allocation-conscious NBT library for .NET 10. It supports standard Java NBT, little-endian Bedrock storage, and Bedrock network VarInts, with optional GZip and ZLib compression.

The API uses strongly typed tags instead of untyped object graphs. Parsing is bounded by configurable nesting, collection, and string limits. Hot paths use spans, pooled UTF-8 buffers, exact stream reads, and uninitialized primitive arrays.

## Quick start

```csharp
using CsNbt;

var root = new NbtCompound()
    .Add("name", "Steve")
    .Add("health", new NbtShort(20))
    .Add("position", new NbtList(NbtTagType.Double)
        .Add(new NbtDouble(12.5))
        .Add(new NbtDouble(64))
        .Add(new NbtDouble(-8.25)));

var document = new NbtDocument("Player", root);
byte[] bytes = document.ToArray(NbtOptions.Bedrock);

NbtDocument decoded = NbtDocument.Parse(bytes, NbtOptions.Bedrock);
string name = ((NbtCompound)decoded.Root).Get<NbtString>("name").Value;
```

For streams, use `NbtDocument.Load(stream, options)` and `document.Save(stream, options)`. Stream ownership is controlled by `NbtOptions.LeaveOpen`.

## Formats

| Option | Byte order | Integer representation |
|---|---|---|
| `NbtOptions.Java` | Big endian | Fixed width |
| `NbtOptions.Bedrock` | Little endian | Fixed width |
| `NbtOptions.BedrockNetwork` | Little endian | ZigZag VarInt for signed integers; VarUInt for lengths |

Customize options using record `with` syntax:

```csharp
var options = NbtOptions.BedrockNetwork with
{
    Compression = NbtCompression.ZLib,
    MaxDepth = 128,
    MaxCollectionLength = 1_000_000,
    LeaveOpen = true,
};
```

## Build and test

```console
dotnet build CsNbt.slnx --configuration Release
dotnet run --project tests/CsNbt.Tests --configuration Release
```

CsNbt is licensed under Apache-2.0.
