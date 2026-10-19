<?php

// PHP half of the comparison, see docs/benchmarks.md. Reads the inputs written by
// `zig build compare -- <dir>` so both sides decode the same bytes.
//
// php -d extension=encoding.so compare.php <dir> <pmmp/NBT>/src <pmmp/BinaryUtils>/src

declare(strict_types=1);

use pmmp\encoding\BE;
use pmmp\encoding\ByteBufferReader;
use pmmp\encoding\ByteBufferWriter;
use pmmp\encoding\LE;
use pmmp\encoding\VarInt;
use pocketmine\nbt\LittleEndianNbtSerializer;

const BATCHES = 31;
const TARGET_NS = 20_000_000;
const COUNT = 4096;

[, $dir, $nbtSource, $utilsSource] = $argv + [null, null, null, null];
if ($dir === null) {
    fwrite(STDERR, "usage: php compare.php <input dir> [pmmp/NBT src] [pmmp/BinaryUtils src]\n");
    exit(1);
}

spl_autoload_register(static function (string $class) use ($nbtSource, $utilsSource): void {
    foreach (['pocketmine\\nbt\\' => $nbtSource, 'pocketmine\\utils\\' => $utilsSource] as $prefix => $source) {
        if ($source !== null && str_starts_with($class, $prefix)) {
            $file = $source . '/' . str_replace('\\', '/', substr($class, strlen($prefix))) . '.php';
            if (is_file($file)) require $file;
        }
    }
});

function timed(callable $op, int $iterations): int
{
    $start = hrtime(true);
    for ($i = 0; $i < $iterations; ++$i) $op();
    return hrtime(true) - $start;
}

function run(string $name, int $bytes, callable $op): void
{
    $iterations = 1;
    while (true) {
        $elapsed = timed($op, $iterations);
        if ($elapsed >= TARGET_NS / 4) {
            $iterations = max(1, intdiv($iterations * TARGET_NS, $elapsed));
            break;
        }
        $iterations *= 2;
    }

    $samples = [];
    for ($i = 0; $i < BATCHES; ++$i) $samples[] = timed($op, $iterations) / $iterations;
    sort($samples);

    $median = $samples[intdiv(BATCHES, 2)];
    printf("%-40s %12.1f %12.1f %12.1f %10.1f %8s\n", $name, $median, $samples[intdiv(BATCHES, 10)], $samples[intdiv(BATCHES * 9, 10)], $bytes / $median * 1e9 / 1048576, '-');
}

function expected(string $set): array
{
    $values = [];
    for ($i = 0; $i < COUNT; ++$i) {
        if ($set === 'small') {
            $values[] = ($i * 7919) % 128 - 64;
        } else {
            $value = ($i * 2654435761) & 0xffffffff;
            $values[] = $value >= 0x80000000 ? $value - 0x100000000 : $value;
        }
    }
    return $values;
}

printf("%-40s %12s %12s %12s %10s %8s\n", 'case', 'median ns', 'p10 ns', 'p90 ns', 'MiB/s', 'allocs');

foreach (['small', 'mixed'] as $set) {
    $values = expected($set);
    foreach ([['varint', 'varint', VarInt::class], ['LE', 'le', LE::class], ['BE', 'be', BE::class]] as [$label, $file, $codec]) {
        $bytes = file_get_contents("$dir/$file-$set.bin");
        $read = static function () use ($bytes, $codec): array {
            $reader = new ByteBufferReader($bytes);
            $count = $codec::readSignedInt($reader);
            $out = [];
            for ($i = 0; $i < $count; ++$i) $out[] = $codec::readSignedInt($reader);
            return $out;
        };
        if ($read() !== $values) throw new RuntimeException("$label $set decoded wrong values");

        $write = static function (ByteBufferWriter $writer) use ($values, $codec): void {
            $codec::writeSignedInt($writer, count($values));
            foreach ($values as $value) $codec::writeSignedInt($writer, $value);
        };
        $fresh = static function () use ($write): string {
            $writer = new ByteBufferWriter();
            $write($writer);
            return $writer->getData();
        };
        if ($fresh() !== $bytes) throw new RuntimeException("$label $set encoded different bytes");

        $reused = new ByteBufferWriter();
        $name = "$label int[" . COUNT . "] $set";
        run("$name decode", strlen($bytes), $read);
        run("$name encode", strlen($bytes), $fresh);
        run("$name write to buffer", strlen($bytes), static function () use ($write, $reused): void {
            $reused->clear();
            $write($reused);
        });
    }
}

if ($nbtSource === null || $utilsSource === null) exit(0);

$serializer = new LittleEndianNbtSerializer();
foreach (['bedrock-item', 'bedrock-entity', 'bedrock-structure'] as $name) {
    $bytes = file_get_contents("$dir/$name.bin");
    $root = $serializer->read($bytes);
    if ($serializer->write($root) !== $bytes) throw new RuntimeException("$name did not round trip");

    run("nbt $name read", strlen($bytes), static fn() => $serializer->read($bytes));
    run("nbt $name write", strlen($bytes), static fn() => $serializer->write($root));
    run("nbt $name consumed length", strlen($bytes), static function () use ($serializer, $bytes): int {
        $offset = 0;
        $serializer->read($bytes, $offset);
        return $offset;
    });
}
