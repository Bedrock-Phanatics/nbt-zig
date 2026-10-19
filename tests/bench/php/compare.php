<?php

// php -d extension=encoding.so -d extension=nbt_bench.so compare.php <inputs> [pmmp/NBT/src] [pmmp/BinaryUtils/src]
// <inputs> comes from `zig build compare -- <inputs>`. Missing extensions or sources are skipped.

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
    fwrite(STDERR, "usage: php compare.php <inputs> [pmmp/NBT/src] [pmmp/BinaryUtils/src]\n");
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
    while (($elapsed = timed($op, $iterations)) < TARGET_NS / 4) $iterations *= 2;
    $iterations = max(1, intdiv($iterations * TARGET_NS, $elapsed));

    $samples = [];
    for ($i = 0; $i < BATCHES; ++$i) $samples[] = timed($op, $iterations) / $iterations;
    sort($samples);

    $median = $samples[intdiv(BATCHES, 2)];
    printf("%-52s %12.1f %12.1f %12.1f %10.1f\n", $name, $median, $samples[intdiv(BATCHES, 10)], $samples[intdiv(BATCHES * 9, 10)], $bytes / $median * 1e9 / 1048576);
}

function check(bool $ok, string $what): void
{
    if (!$ok) throw new RuntimeException($what);
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

$encoding = extension_loaded('encoding');
$zig = extension_loaded('nbt_bench');
$pocketmine = $nbtSource !== null && $utilsSource !== null;

printf("%-52s %12s %12s %12s %10s\n", 'case (ns per operation)', 'median', 'p10', 'p90', 'MiB/s');

foreach (['small', 'mixed'] as $set) {
    $values = expected($set);
    foreach ([['varint', 'varint', VarInt::class, 2], ['LE', 'le', LE::class, 1], ['BE', 'be', BE::class, 0]] as [$label, $file, $codec, $format]) {
        $bytes = file_get_contents("$dir/$file-$set.bin");
        $name = "$label int[" . COUNT . "] $set";

        if ($encoding) {
            $read = static function () use ($bytes, $codec): array {
                $reader = new ByteBufferReader($bytes);
                $count = $codec::readSignedInt($reader);
                $out = [];
                for ($i = 0; $i < $count; ++$i) $out[] = $codec::readSignedInt($reader);
                return $out;
            };
            $write = static function () use ($values, $codec): string {
                $writer = new ByteBufferWriter();
                $codec::writeSignedInt($writer, count($values));
                foreach ($values as $value) $codec::writeSignedInt($writer, $value);
                return $writer->getData();
            };
            check($read() === $values && $write() === $bytes, "ext-encoding $name");
            run("ext-encoding $name decode", strlen($bytes), $read);
            run("ext-encoding $name encode", strlen($bytes), $write);
        }

        if ($zig) {
            check(nbt_bench_decode_int_array($bytes, $format) === $values, "nbt-zig $name decode");
            check(nbt_bench_encode_int_array($values, $format) === $bytes, "nbt-zig $name encode");
            run("nbt-zig $name decode", strlen($bytes), static fn() => nbt_bench_decode_int_array($bytes, $format));
            run("nbt-zig $name encode", strlen($bytes), static fn() => nbt_bench_encode_int_array($values, $format));
        }
    }
}

$serializer = $pocketmine ? new LittleEndianNbtSerializer() : null;
foreach (['bedrock-item', 'bedrock-entity', 'bedrock-structure'] as $name) {
    $bytes = file_get_contents("$dir/$name.bin");

    if ($serializer !== null) {
        $root = $serializer->read($bytes);
        check($serializer->write($root) === $bytes, "pocketmine $name round trip");
        run("pocketmine nbt $name read", strlen($bytes), static fn() => $serializer->read($bytes));
        run("pocketmine nbt $name write", strlen($bytes), static fn() => $serializer->write($root));
        run("pocketmine nbt $name consumed length", strlen($bytes), static function () use ($serializer, $bytes): int {
            $offset = 0;
            $serializer->read($bytes, $offset);
            return $offset;
        });
    }

    if ($zig) {
        check(nbt_bench_scan($bytes, 1) === strlen($bytes), "nbt-zig $name scan");
        run("nbt-zig nbt $name read to arrays", strlen($bytes), static fn() => nbt_bench_decode($bytes, 1));
        run("nbt-zig nbt $name consumed length", strlen($bytes), static fn() => nbt_bench_scan($bytes, 1));
    }
}
