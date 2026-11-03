#include "DocumentOpenCVBridge.h"
#include "Native/EdgeDrawingAdapter.hpp"
#include "Native/GrabCutAdapter.hpp"
#include "Native/SeedAdapter.hpp"
#include "Native/GraphExtent.hpp"
#include <algorithm>
#include <array>
#include <limits>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <vector>

struct IEOpenCVCardAnalysis {
  spatial_parity::Edges edges;
  std::vector<IEOpenCVPixelPoint> points;
  std::vector<uint8_t> mask;
};

int32_t IEOpenCVAnalyzeCardRGB(const uint8_t *pixels, size_t availableBytes,
    int32_t width, int32_t height, size_t bytesPerRow, const double *corners,
    IEOpenCVCardAnalysis **output) {
  if (!output) return IEOpenCVCardInvalidInput;
  *output = nullptr;
  if (!pixels || !corners || width < 5 || height < 5) return IEOpenCVCardInvalidInput;
  const size_t w = static_cast<size_t>(width), h = static_cast<size_t>(height);
  if (!spatial_parity::graphExtentRepresentable(width, height)) return IEOpenCVCardResourceLimit;
  const size_t row = w * 3, rows = h - 1;
  if (bytesPerRow < row || bytesPerRow > (std::numeric_limits<size_t>::max() - row) / rows ||
      rows * bytesPerRow + row > availableBytes) return IEOpenCVCardInvalidInput;
  try {
    // Only one memory-heavy analysis may run at a time, regardless of calling host.
    static std::mutex analysisMutex;
    std::lock_guard<std::mutex> execution(analysisMutex);
    std::array<spatial_parity::Vertex, 4> prior;
    for (size_t i = 0; i < prior.size(); ++i) prior[i] = {corners[i * 2], corners[i * 2 + 1]};
    const auto seeds = spatial_parity::automaticSeeds(prior, width, height);
    auto result = std::make_unique<IEOpenCVCardAnalysis>();
    // Detection scratch buffers are released before allocating the GrabCut graph.
    // Every observed chain is retained; no display-budget truncation or resizing occurs.
    result->edges = spatial_parity::detect(pixels, availableBytes, width, height, bytesPerRow);
    result->mask = spatial_parity::segment(pixels, availableBytes, width, height, bytesPerRow, seeds).component;
    result->points.reserve(result->edges.points.size());
    for (const auto p : result->edges.points) result->points.push_back({p.x, p.y});
    result->edges.points.clear();
    result->edges.points.shrink_to_fit();
    *output = result.release();
    return IEOpenCVCardSuccess;
  } catch (const std::length_error&) {
    return IEOpenCVCardResourceLimit;
  } catch (const std::bad_alloc&) {
    return IEOpenCVCardResourceLimit;
  } catch (const std::invalid_argument&) {
    return IEOpenCVCardInvalidInput;
  } catch (...) {
    // Exceptions must not cross a C/Swift boundary. No input or provider data is logged.
    return IEOpenCVCardProcessingFailure;
  }
}

const IEOpenCVPixelPoint *IEOpenCVCardAnalysisPoints(const IEOpenCVCardAnalysis *result, size_t *count) {
  if (count) *count = result ? result->points.size() : 0;
  return result && !result->points.empty() ? result->points.data() : nullptr;
}
const uint64_t *IEOpenCVCardAnalysisOffsets(const IEOpenCVCardAnalysis *result, size_t *count) {
  if (count) *count = result ? result->edges.offsets.size() : 0;
  return result ? result->edges.offsets.data() : nullptr;
}
const uint8_t *IEOpenCVCardAnalysisMask(const IEOpenCVCardAnalysis *result, size_t *count) {
  if (count) *count = result ? result->mask.size() : 0;
  return result ? result->mask.data() : nullptr;
}
void IEOpenCVCardAnalysisRelease(IEOpenCVCardAnalysis *result) {
  // The C caller transfers the result back to its original unique ownership.
  const std::unique_ptr<IEOpenCVCardAnalysis> owned(result);
}
