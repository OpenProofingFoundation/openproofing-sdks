#include "SeedAdapter.hpp"
#include <algorithm>
#include <cmath>
#include <limits>
#include <stdexcept>

namespace spatial_parity {
namespace {
using Ring = std::vector<Vertex>;
constexpr double pi = 3.141592653589793238462643383279502884;
Vertex minus(Vertex a, Vertex b) { return {a.x - b.x, a.y - b.y}; }
double cross(Vertex a, Vertex b) { return a.x * b.y - a.y * b.x; }
double length(Vertex a) { return std::hypot(a.x, a.y); }

// Half-open scanlines select pixel centers; rounded x intersections reproduce the desktop
// raster contract's edge ties. OpenCV fillPoly and a contains(point) predicate differ here.
void rasterize(const Ring& ring, int width, int height, std::uint8_t value,
               std::vector<std::uint8_t>& pixels) {
  for (int y = 0; y < height; ++y) {
    const double center = y + .5;
    std::vector<double> intersections;
    for (std::size_t i = 0; i < ring.size(); ++i) {
      auto a = ring[i], b = ring[(i + 1) % ring.size()];
      if (a.y > b.y) std::swap(a, b);
      if (center >= a.y && center < b.y)
        intersections.push_back((center - a.y) * (b.x - a.x) / (b.y - a.y) + a.x);
    }
    std::sort(intersections.begin(), intersections.end());
    if (intersections.size() % 2) throw std::runtime_error("Odd raster intersection count");
    for (std::size_t i = 0; i < intersections.size(); i += 2) {
      const auto begin = std::max(0, static_cast<int>(std::floor(intersections[i] + .5)));
      const auto end = std::min(width, static_cast<int>(std::floor(intersections[i + 1] + .5)));
      for (int x = begin; x < end; ++x) pixels[static_cast<std::size_t>(y) * width + x] = value;
    }
  }
}

Ring inset(const Ring& quad, double band) {
  Ring clipped = quad;
  for (std::size_t i = 0; i < quad.size(); ++i) {
    const auto origin = quad[i], edge = minus(quad[(i + 1) % quad.size()], origin);
    const auto distance = [&](Vertex p) { return cross(edge, minus(p, origin)) / length(edge) - band; };
    Ring next;
    for (std::size_t j = 0; j < clipped.size(); ++j) {
      const auto a = clipped[j], b = clipped[(j + 1) % clipped.size()];
      const double da = distance(a), db = distance(b);
      if (da >= 0) next.push_back(a);
      if ((da >= 0) != (db >= 0)) {
        const double t = da / (da - db);
        next.push_back({a.x + t * (b.x - a.x), a.y + t * (b.y - a.y)});
      }
    }
    clipped = std::move(next);
  }
  return clipped;
}

Ring outset(const Ring& quad, double band) {
  Ring result;
  for (std::size_t i = 0; i < quad.size(); ++i) {
    const auto center = quad[i];
    const auto before = minus(center, quad[(i + 3) % 4]);
    const auto after = minus(quad[(i + 1) % 4], center);
    const Vertex a{before.y / length(before), -before.x / length(before)};
    const Vertex b{after.y / length(after), -after.x / length(after)};
    const double start = std::atan2(a.y, a.x);
    double end = std::atan2(b.y, b.x);
    while (end <= start) end += 2 * pi;
    const int segments = static_cast<int>((end - start) / (pi / 32) + .5);
    result.push_back({center.x + band * a.x, center.y + band * a.y});
    for (int j = 1; j < segments; ++j) {
      const double angle = start + j * (end - start) / segments;
      result.push_back({center.x + band * std::cos(angle), center.y + band * std::sin(angle)});
    }
    result.push_back({center.x + band * b.x, center.y + band * b.y});
  }
  return result;
}
}

std::vector<std::uint8_t> automaticSeeds(std::array<Vertex, 4> corners, int width, int height) {
  if (width < 1 || height < 1 || static_cast<std::size_t>(width) >
      std::numeric_limits<std::size_t>::max() / height) throw std::invalid_argument("Invalid dimensions");
  for (const auto p : corners)
    if (!std::isfinite(p.x) || !std::isfinite(p.y) || p.x < 0 || p.y < 0 || p.x > width || p.y > height)
      throw std::invalid_argument("Invalid prior");
  Ring quad(corners.begin(), corners.end());
  double area = 0;
  for (int i = 0; i < 4; ++i) area += cross(quad[i], quad[(i + 1) % 4]);
  if (area < 0) std::reverse(quad.begin(), quad.end());
  double shortest = std::numeric_limits<double>::max();
  for (int i = 0; i < 4; ++i) {
    const auto a = minus(quad[(i + 1) % 4], quad[i]), b = minus(quad[(i + 2) % 4], quad[(i + 1) % 4]);
    if (cross(a, b) <= 0) throw std::invalid_argument("Expected convex ordered quadrilateral");
    shortest = std::min(shortest, length(a));
  }
  const double band = .04 * shortest;
  const Ring inner = inset(quad, band), outer = outset(quad, band);
  if (inner.size() < 3) throw std::invalid_argument("Empty foreground seed core");
  for (const auto p : outer)
    if (p.x < 0 || p.y < 0 || p.x > width || p.y > height)
      throw std::invalid_argument("Seed geometry outside source");
  std::vector<std::uint8_t> seeds(static_cast<std::size_t>(width) * height, 0);
  rasterize(outer, width, height, 2, seeds);
  rasterize(quad, width, height, 3, seeds);
  rasterize(inner, width, height, 1, seeds);
  for (const auto label : {0, 1})
    if (std::find(seeds.begin(), seeds.end(), label) == seeds.end())
      throw std::invalid_argument("Missing definite seed class");
  return seeds;
}
}
