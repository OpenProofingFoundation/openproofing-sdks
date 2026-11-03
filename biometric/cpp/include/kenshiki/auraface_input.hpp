#pragma once

#include "kenshiki/portrait.hpp"
#include <array>
#include <string_view>

namespace kenshiki::auraface {
inline constexpr std::size_t width = 112;
inline constexpr std::size_t height = 112;
inline constexpr std::size_t channels = 3;
inline constexpr std::size_t tensor_elements = width * height * channels;
inline constexpr std::size_t feature_count = 512;
inline constexpr std::size_t model_size = 260694151;
enum class Failure {
    invalid_input, artifact_size, artifact_integrity, runtime_version,
    runtime_failure, model_metadata, output_metadata, resource_limit
};
class Error final : public std::exception {
public:
    explicit Error(Failure reason) noexcept : reason_(reason) {}
    [[nodiscard]] Failure reason() const noexcept { return reason_; }
    [[nodiscard]] const char* what() const noexcept override { return "auraface_failure"; }
private:
    Failure reason_;
};
// Identifiers are SHA-256 of the exact checked-in profile/manifest bytes.
[[nodiscard]] std::string_view artifact_manifest_sha256() noexcept;
[[nodiscard]] std::string_view preprocessing_sha256() noexcept;
[[nodiscard]] std::array<float, tensor_elements> aligned_tensor(const PixelSnapshot& pixels);
} // namespace kenshiki::auraface
