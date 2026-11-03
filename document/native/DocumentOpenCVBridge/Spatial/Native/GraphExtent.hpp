#pragma once
#include <cstdint>
#include <limits>

namespace spatial_parity {
// OpenCV 4.12 grabcut.cpp evaluates this graph allocation expression using signed int:
// 2*(4*width*height - 3*(width+height) + 2). GCGraph also reserves two sentinel edges
// and stores edge/node indices as int. Check each intermediate before calling it;
// this is a representability requirement, not a camera-resolution or memory budget.
inline bool graphExtentRepresentable(std::int32_t width, std::int32_t height) {
  if (width < 1 || height < 1) return false;
  const auto w = static_cast<std::uint64_t>(width), h = static_cast<std::uint64_t>(height);
  const auto maximum = static_cast<std::uint64_t>(std::numeric_limits<int>::max());
  const auto pixels = w * h, sum = w + h;
  if (pixels > maximum / 4 || sum > maximum / 3) return false;
  const auto undirected = 4 * pixels + 2 - 3 * sum;
  return undirected <= (maximum - 2) / 2;
}
}
