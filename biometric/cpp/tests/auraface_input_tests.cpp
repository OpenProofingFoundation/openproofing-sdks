#include "kenshiki/auraface_input.hpp"
#include <array>
#include <bit>
#include <cstdint>
#include <cfenv>
#include <iostream>
#include <stdexcept>
#include <vector>

namespace {
#include "auraface_vectors.inc"
std::size_t assertions = 0;
void check(bool value) {
    ++assertions;
    if (!value) throw std::runtime_error("auraface_input_assertion");
}
kenshiki::PixelSnapshot pixels(std::vector<std::byte>& bytes, std::int64_t width = 112,
                              std::int64_t height = 112, std::int64_t orientation = 1,
                              bool gray = false) {
    const std::int64_t channels = gray ? 1 : 3;
    return kenshiki::PixelSnapshot::create({{"width", width}, {"height", height},
        {"orientation", orientation}, {"format", std::string(gray ? "gray8" : "rgb8")},
        {"rowStrideBytes", width * channels}, {"byteLength", width * height * channels},
        {"sha256", kenshiki::sha256(bytes)}}, bytes);
}
void reject(const kenshiki::PixelSnapshot& snapshot) {
    bool rejected = false;
    try { static_cast<void>(kenshiki::auraface::aligned_tensor(snapshot)); }
    catch (const kenshiki::auraface::Error& error) {
        rejected = error.reason() == kenshiki::auraface::Failure::invalid_input;
    }
    check(rejected);
}
}
int main() {
    try {
        // This rational oracle is deliberately different from the production
        // multiply-by-rounded-reciprocal implementation. All possible RGB bytes
        // occur in each plane; channel offsets make RGB/BGR mistakes observable.
        std::vector<std::byte> bytes(112 * 112 * 3);
        for (std::size_t p = 0; p < 112 * 112; ++p)
            for (std::size_t c = 0; c < 3; ++c)
                bytes[p * 3 + c] = static_cast<std::byte>((p + c * 73) % 256);
        const auto original = bytes;
        const auto snapshot = pixels(bytes);
        const auto tensor = kenshiki::auraface::aligned_tensor(snapshot);
        for (const auto& common : common_vectors) {
            std::vector<std::byte> vector_bytes(112 * 112 * 3);
            for (std::size_t p = 0; p < 112 * 112; ++p)
                for (std::size_t c = 0; c < 3; ++c)
                    vector_bytes[p * 3 + c] = static_cast<std::byte>(std::string(common[0]) == "ramp"
                        ? (p * 37 + c * 83) % 256 : std::string(common[0]) == "black" ? 0 : 255);
            const auto vector_pixels = pixels(vector_bytes);
            check(vector_pixels.digest() == common[1]);
            const auto converted = kenshiki::auraface::aligned_tensor(vector_pixels);
            std::vector<std::byte> little_endian;
            little_endian.reserve(converted.size() * 4);
            for (const float value : converted) {
                const auto bits = std::bit_cast<std::uint32_t>(value);
                for (unsigned int shift = 0; shift < 32; shift += 8)
                    little_endian.push_back(static_cast<std::byte>((bits >> shift) & 255));
            }
            check(kenshiki::sha256(little_endian) == common[2]);
        }
        for (std::size_t p = 0; p < 112 * 112; ++p) {
            for (std::size_t c = 0; c < 3; ++c) {
                const int value = std::to_integer<int>(original[p * 3 + c]);
                // Profile mandates two FP32 operations. Reconstruct reciprocal
                // from its independently specified IEEE754 bit pattern.
                const float reciprocal = std::bit_cast<float>(std::uint32_t{0x3c008081});
                const float expected = static_cast<float>(2 * value - 255) * 0.5F * reciprocal;
                check(std::bit_cast<std::uint32_t>(tensor[c * 112 * 112 + p]) ==
                      std::bit_cast<std::uint32_t>(expected));
            }
        }
        bytes.assign(bytes.size(), std::byte{0});
        bytes.clear(); bytes.shrink_to_fit();
        check(kenshiki::auraface::aligned_tensor(snapshot) == tensor);
        check(kenshiki::sha256(snapshot.bytes()) == snapshot.digest());
        for (const auto& negative : common_negative_vectors) {
            const bool gray = negative[3] != 0;
            std::vector<std::byte> copy(static_cast<std::size_t>(negative[0] * negative[1] * (gray ? 1 : 3)));
            reject(pixels(copy, negative[0], negative[1], negative[2], gray));
        }
        for (const auto shape : {std::array<std::int64_t, 2>{111,112}, {112,111}, {113,112}, {112,113}, {1,1}}) {
            std::vector<std::byte> copy(static_cast<std::size_t>(shape[0] * shape[1] * 3));
            reject(pixels(copy, shape[0], shape[1]));
        }
        const auto previous_rounding = std::fegetround();
        check(std::fesetround(FE_DOWNWARD) == 0);
        bool wrong_rounding_rejected = false;
        try { static_cast<void>(kenshiki::auraface::aligned_tensor(snapshot)); }
        catch (const kenshiki::auraface::Error& error) {
            wrong_rounding_rejected = error.reason() == kenshiki::auraface::Failure::invalid_input;
        }
        const auto restore_result = std::fesetround(previous_rounding);
        check(restore_result == 0 && wrong_rounding_rejected);
        check(kenshiki::is_digest(std::string(kenshiki::auraface::preprocessing_sha256())));
        check(kenshiki::is_digest(std::string(kenshiki::auraface::artifact_manifest_sha256())));
        check(kenshiki::auraface::preprocessing_sha256() != kenshiki::auraface::artifact_manifest_sha256());
        std::cout << "auraface_input_assertions=" << assertions << '\n';
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n'; return 1;
    }
}
