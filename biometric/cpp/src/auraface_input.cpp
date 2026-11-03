#if defined(__clang__)
#pragma clang fp contract(off)
#endif
#include "kenshiki/auraface_input.hpp"
#include <cfenv>
#include <limits>

#if defined(__FAST_MATH__)
#error "AuraFace requires IEEE floating-point semantics"
#endif
static_assert(sizeof(float) == 4 && std::numeric_limits<float>::is_iec559);

namespace kenshiki::auraface {
std::string_view artifact_manifest_sha256() noexcept {
    return "9db36f239a89adfa6794f616f7face61f5ba1b0ca0c7f26b93a6204001856347";
}
std::string_view preprocessing_sha256() noexcept {
    return "70da7b12bc90fda352222d941cc51e97288305de9522320fde8633b22a38e1d9";
}
std::array<float, tensor_elements> aligned_tensor(const PixelSnapshot& pixels) {
    if (std::fegetround() != FE_TONEAREST || pixels.width() != width || pixels.height() != height ||
        pixels.channels() != channels || pixels.orientation() != 1 ||
        pixels.bytes().size() != tensor_elements) {
        throw Error(Failure::invalid_input);
    }
    std::array<float, tensor_elements> tensor{};
    constexpr std::size_t plane = width * height;
    constexpr float scale = static_cast<float>(1.0 / 127.5);
    for (std::size_t pixel = 0; pixel < plane; ++pixel) {
        for (std::size_t channel = 0; channel < channels; ++channel) {
            const auto value = std::to_integer<unsigned char>(pixels.bytes()[pixel * channels + channel]);
            tensor[channel * plane + pixel] = (static_cast<float>(value) - 127.5F) * scale;
        }
    }
    return tensor;
}
} // namespace kenshiki::auraface
