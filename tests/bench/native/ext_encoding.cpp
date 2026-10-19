// Times ext-encoding's own Serializers.h on the inputs `zig build compare -- <dir>` writes.
// Copy Serializers.h into shim/, then g++ -O2 -std=c++20 -Ishim ext_encoding.cpp.

#include <climits>
#include <cstdint>
#include <cstring>
#include "Serializers.h"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iterator>
#include <stdexcept>
#include <string>
#include <vector>

constexpr int batches = 31;
constexpr double target_ns = 20e6;
constexpr int count = 4096;

static std::vector<unsigned char> load(const std::string &path) {
	std::ifstream file(path, std::ios::binary);
	if (!file) throw std::runtime_error("missing " + path);
	return {std::istreambuf_iterator<char>(file), {}};
}

static std::vector<int32_t> expected(bool small) {
	std::vector<int32_t> values;
	for (uint64_t i = 0; i < count; i++) {
		values.push_back(small ? int32_t(i * 7919 % 128) - 64 : int32_t(uint32_t(i * 2654435761u)));
	}
	return values;
}

template<typename Op>
static double timed(Op &op, long iterations) {
	auto start = std::chrono::steady_clock::now();
	for (long i = 0; i < iterations; i++) op();
	return std::chrono::duration<double, std::nano>(std::chrono::steady_clock::now() - start).count();
}

template<typename Op>
static void run(const std::string &name, size_t bytes, Op op) {
	long iterations = 1;
	double elapsed;
	while ((elapsed = timed(op, iterations)) < target_ns / 4) iterations *= 2;
	iterations = std::max(1L, long(iterations * target_ns / elapsed));

	std::vector<double> samples;
	for (int i = 0; i < batches; i++) samples.push_back(timed(op, iterations) / iterations);
	std::sort(samples.begin(), samples.end());

	double median = samples[batches / 2];
	std::printf("%-40s %12.1f %12.1f %12.1f %10.1f\n", name.c_str(), median, samples[batches / 10], samples[batches * 9 / 10], bytes / median * 1e9 / 1048576);
}

struct Input {
	unsigned char *data;
	size_t size;
};

// Decoding reuses one output vector, and the input sits 2 KiB from it modulo a page. Left to
// the heap, the copy could hit 4K aliasing and run 20x slower depending on the run.
template<typename Read, typename Write>
static void cases(const std::string &name, const std::vector<unsigned char> &bytes, std::vector<int32_t> values, Read read, Write write) {
	std::vector<int32_t> decoded;
	decoded.reserve(values.size());
	const auto target = (reinterpret_cast<uintptr_t>(decoded.data()) + 2048) % 4096;

	auto *storage = static_cast<unsigned char *>(std::aligned_alloc(4096, bytes.size() + 8192));
	Input input{storage + target, bytes.size()};
	std::memcpy(input.data, bytes.data(), bytes.size());

	if (!read(input, decoded) || decoded != values) throw std::runtime_error(name + " decoded wrong values");

	std::vector<unsigned char> encoded;
	write(values, encoded);
	if (encoded != bytes) throw std::runtime_error(name + " encoded different bytes");

	run(name + " decode", bytes.size(), [&] {
		decoded.clear();
		if (!read(input, decoded)) throw std::runtime_error(name);
		asm volatile("" : : "r"(decoded.data()) : "memory");
	});
	run(name + " encode", bytes.size(), [&] {
		std::vector<unsigned char> out;
		write(values, out);
		asm volatile("" : : "r"(out.data()) : "memory");
	});
	std::free(storage);
}

// Each encode starts from an empty buffer like a fresh ByteBufferWriter. The big endian
// writer swaps `values` in place, which costs the same either way round.
template<typename WriteCount, typename WriteValues>
static void encodeWith(std::vector<int32_t> &values, std::vector<unsigned char> &out, WriteCount writeCount, WriteValues writeValues) {
	unsigned char *buffer = nullptr;
	size_t length = 0, offset = 0;
	writeCount(buffer, length, offset, int32_t(values.size()));
	writeValues(buffer, length, offset, values);
	out.assign(buffer, buffer + offset);
	std::free(buffer);
}

template<ByteOrder order>
static void fixedCases(const std::string &name, const std::vector<unsigned char> &bytes, const std::vector<int32_t> &values) {
	cases(name, bytes, values,
		[](Input in, std::vector<int32_t> &out) {
			size_t offset = 0;
			int32_t len;
			return readFixedSizeType<int32_t, order>(in.data, in.size, offset, len) &&
				readFixedSizeTypeArray<int32_t, order>(in.data, in.size, offset, size_t(len), out);
		},
		[](std::vector<int32_t> &in, std::vector<unsigned char> &out) {
			encodeWith(in, out, writeFixedSizeType<int32_t, order>, writeFixedSizeTypeArray<int32_t, order>);
		});
}

int main(int argc, char **argv) {
	if (argc < 2) {
		std::fprintf(stderr, "usage: ext_encoding <inputs>\n");
		return 1;
	}
	std::string dir = argv[1];
	std::printf("%-40s %12s %12s %12s %10s\n", "case (ns per operation)", "median", "p10", "p90", "MiB/s");

	for (std::string set : {"small", "mixed"}) {
		auto values = expected(set == "small");
		std::string suffix = " int[4096] " + set;

		cases("varint" + suffix, load(dir + "/varint-" + set + ".bin"), values,
			[](Input in, std::vector<int32_t> &out) {
				size_t offset = 0;
				int32_t len;
				if (!readSignedVarInt<uint32_t, int32_t>(in.data, in.size, offset, len)) return false;
				out.reserve(size_t(len));
				return readComplexTypeArray<int32_t, readSignedVarInt<uint32_t, int32_t>>(in.data, in.size, offset, size_t(len), out);
			},
			[](std::vector<int32_t> &in, std::vector<unsigned char> &out) {
				encodeWith(in, out, writeSignedVarInt<uint32_t, int32_t>, writeComplexTypeArray<int32_t, writeSignedVarInt<uint32_t, int32_t>>);
			});
		fixedCases<ByteOrder::LittleEndian>("LE" + suffix, load(dir + "/le-" + set + ".bin"), values);
		fixedCases<ByteOrder::BigEndian>("BE" + suffix, load(dir + "/be-" + set + ".bin"), values);
	}
}
