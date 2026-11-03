#pragma once

#include "kenshiki/auraface_input.hpp"

// Private dependency seam for model-free runtime conformance tests. This header
// is not installed or exported by the optional adapter target.
namespace kenshiki::auraface::detail {
class Engine final {
public:
    explicit Engine(std::span<const std::byte> model);
    explicit Engine(std::vector<std::byte> owned_model);
    ~Engine();
    Engine(const Engine&) = delete;
    Engine& operator=(const Engine&) = delete;
    [[nodiscard]] std::array<float, feature_count> run(const std::array<float, tensor_elements>& tensor);
private:
    class Impl;
    std::unique_ptr<Impl> impl_;
};
} // namespace kenshiki::auraface::detail
