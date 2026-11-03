#pragma once
#include <array>
#include <cstdint>
#include <vector>

namespace spatial_parity {
struct Vertex { double x, y; };
// Convex-quad seeds follow the desktop pixel-center raster contract.
// Differential fixtures require exact equality, including half-pixel edge ties.
std::vector<std::uint8_t> automaticSeeds(std::array<Vertex, 4> corners,
                                       std::int32_t width, std::int32_t height);
}
