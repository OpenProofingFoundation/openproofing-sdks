#include "GrabCutAdapter.hpp"
#include "GraphExtent.hpp"
#include <opencv2/imgproc.hpp>
#include <algorithm>
#include <limits>
#include <stdexcept>

namespace spatial_parity {
namespace {
std::size_t checkedSize(std::int32_t width, std::int32_t height) {
  if (width < 1 || height < 1 ||
      static_cast<std::size_t>(width) > std::numeric_limits<std::size_t>::max() / height)
    throw std::invalid_argument("Invalid segmentation dimensions");
  return static_cast<std::size_t>(width) * height;
}
void checkLabels(const std::vector<std::uint8_t>& labels, std::size_t size) {
  if (labels.size() != size || std::any_of(labels.begin(), labels.end(), [](auto p) { return p > 3; }))
    throw std::invalid_argument("Invalid segmentation labels");
}
}

std::vector<std::uint8_t> selectCore(const std::vector<std::uint8_t>& labels,
                                  const std::vector<std::uint8_t>& seeds,
                                  std::int32_t width, std::int32_t height) {
  const auto size = checkedSize(width, height);
  checkLabels(labels, size); checkLabels(seeds, size);
  cv::Mat foreground(height, width, CV_8UC1);
  for (std::size_t i = 0; i < size; ++i)
    foreground.data[i] = labels[i] == cv::GC_FGD || labels[i] == cv::GC_PR_FGD;
  cv::Mat connected, stats, centroids;
  cv::connectedComponentsWithStats(foreground, connected, stats, centroids, 4);
  int core = 0;
  for (std::int32_t y = 0; y < height; ++y) for (std::int32_t x = 0; x < width; ++x) {
    if (seeds[static_cast<std::size_t>(y) * width + x] != cv::GC_FGD) continue;
    const int component = connected.at<int>(y, x);
    if (component == 0 || (core != 0 && component != core))
      throw std::invalid_argument("Foreground core split or missing");
    core = component;
  }
  if (core == 0) throw std::invalid_argument("Foreground core split or missing");
  std::vector<std::uint8_t> result(size);
  for (std::int32_t y = 0; y < height; ++y) for (std::int32_t x = 0; x < width; ++x)
    result[static_cast<std::size_t>(y) * width + x] = connected.at<int>(y, x) == core;
  return result;
}

Segmentation segment(const std::uint8_t* rgb, std::size_t availableBytes,
                     std::int32_t width, std::int32_t height, std::size_t bytesPerRow,
                     const std::vector<std::uint8_t>& seeds) {
  if (!graphExtentRepresentable(width, height))
    throw std::length_error("Image dimensions exceed native graph index representation");
  const auto size = checkedSize(width, height);
  checkLabels(seeds, size);
  const auto max = std::numeric_limits<std::size_t>::max();
  if (!rgb || static_cast<std::size_t>(width) > max / 3)
    throw std::invalid_argument("Invalid RGB8 dimensions");
  const auto row = static_cast<std::size_t>(width) * 3, rows = static_cast<std::size_t>(height - 1);
  if (bytesPerRow < row || (rows > 0 && bytesPerRow > (max - row) / rows) ||
      rows * bytesPerRow + row > availableBytes)
    throw std::invalid_argument("Truncated or overflowing RGB8 extent");
  Segmentation result{seeds, {}};
  const cv::Mat source(height, width, CV_8UC3, const_cast<std::uint8_t*>(rgb), bytesPerRow);
  cv::Mat bgr;
  cv::cvtColor(source, bgr, cv::COLOR_RGB2BGR);
  cv::Mat mask(height, width, CV_8UC1, result.labels.data());
  cv::Mat background = cv::Mat::zeros(1, 65, CV_64FC1), foreground = cv::Mat::zeros(1, 65, CV_64FC1);
  // OpenCV RNG state is thread-local. Restore it even when grabCut throws; do not
  // change process-wide thread settings or disturb another operation on this thread.
  struct RestoreRNG {
    RestoreRNG() = default;
    RestoreRNG(const RestoreRNG&) = delete;
    RestoreRNG& operator=(const RestoreRNG&) = delete;
    RestoreRNG(RestoreRNG&&) = delete;
    RestoreRNG& operator=(RestoreRNG&&) = delete;
    std::uint64_t state = cv::theRNG().state;
    ~RestoreRNG() { cv::theRNG().state = state; }
  } restoreRNG;
  cv::setRNGSeed(0);
  cv::grabCut(bgr, mask, cv::Rect(), background, foreground, 5, cv::GC_INIT_WITH_MASK);
  result.component = selectCore(result.labels, seeds, width, height);
  return result;
}
}
