using System;
using System.IO;

namespace CsNbt;

/// <summary>Thrown when an NBT payload is malformed or violates configured limits.</summary>
public sealed class NbtException : IOException
{
    public NbtException(string message) : base(message) { }
    public NbtException(string message, Exception innerException) : base(message, innerException) { }
}
