#pragma once
#include <cstddef>
#include <cstdint>
#include <vector>

namespace spatial_parity {
struct Segmentation {
  std::vector<std::uint8_t> labels;
  std::vector<std::uint8_t> component;
};
// Explicit caller-supplied seed labels only. No polygon buffering or seed inference.
Segmentation segment(const std::uint8_t* rgb, std::size_t availableBytes,
                     std::int32_t width, std::int32_t height, std::size_t bytesPerRow,
                     const std::vector<std::uint8_t>& seeds);
std::vector<std::uint8_t> selectCore(const std::vector<std::uint8_t>& labels,
                                  const std::vector<std::uint8_t>& seeds,
                                  std::int32_t width, std::int32_t height);
}
