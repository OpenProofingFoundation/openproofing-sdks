#pragma once
#include <cstddef>
#include <cstdint>
#include <vector>

namespace spatial_parity {
struct Point { std::int32_t x, y; };
struct Edges {
  std::vector<Point> points;
  std::vector<std::uint64_t> offsets;
};

// Full upright RGB8 only. Caller owns source lifetime and serial execution.
// This operation does not alter global OpenCV thread settings.
// Points are integer source-pixel indices; presentation adds (0.5, 0.5).
Edges detect(const std::uint8_t* rgb, std::size_t availableBytes,
             std::int32_t width, std::int32_t height, std::size_t bytesPerRow);
}
