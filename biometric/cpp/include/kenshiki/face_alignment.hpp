#pragma once
#include "kenshiki/portrait.hpp"
#include <array>

namespace kenshiki {
struct FacePoint final { double x, y; };
// Top-left, pixel-centre coordinates, image-left eye first, then image-right
// eye, nose tip, image-left and image-right mouth corners. No reflection/fallback.
using FaceLandmarks = std::array<FacePoint, 5>;
struct FaceSimilarityTransform final {
    double real, imaginary, translate_x, translate_y;
};
[[nodiscard]] FaceSimilarityTransform fit_face(const FaceLandmarks& source);
[[nodiscard]] PixelSnapshot align_face(const PixelSnapshot& source, const FaceLandmarks& landmarks);
} // namespace kenshiki
