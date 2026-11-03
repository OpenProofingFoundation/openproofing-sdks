#include "EdgeDrawingAdapter.hpp"
#include "GraphExtent.hpp"
#include <opencv2/imgproc.hpp>
#include <opencv2/ximgproc/edge_drawing.hpp>
#include <limits>
#include <stdexcept>

namespace spatial_parity {
Edges detect(const std::uint8_t* rgb, std::size_t availableBytes,
             std::int32_t width, std::int32_t height, std::size_t bytesPerRow) {
  if (!rgb || width < 5 || height < 5 ||
      static_cast<std::size_t>(width) > std::numeric_limits<std::size_t>::max() / 3)
    throw std::invalid_argument("Invalid RGB8 dimensions");
  if (!graphExtentRepresentable(width, height))
    throw std::length_error("Image dimensions exceed native graph index representation");
  const auto rowBytes = static_cast<std::size_t>(width) * 3;
  const auto priorRows = static_cast<std::size_t>(height - 1);
  if (bytesPerRow < rowBytes ||
      bytesPerRow > (std::numeric_limits<std::size_t>::max() - rowBytes) / priorRows ||
      priorRows * bytesPerRow + rowBytes > availableBytes)
    throw std::invalid_argument("Truncated or overflowing RGB8 extent");
  const cv::Mat source(height, width, CV_8UC3, const_cast<std::uint8_t*>(rgb), bytesPerRow);
  cv::Mat gray;
  cv::cvtColor(source, gray, cv::COLOR_RGB2GRAY);
  cv::ximgproc::EdgeDrawing::Params p;
  // The CardEdges research configuration is the hypothesis being replayed, not a tuned mobile profile.
  p.PFmode = false; p.EdgeDetectionOperator = cv::ximgproc::EdgeDrawing::PREWITT;
  p.GradientThresholdValue = 20; p.AnchorThresholdValue = 0;
  p.ScanInterval = 1; p.MinPathLength = 3; p.Sigma = 1.0; p.SumFlag = true;
  p.NFAValidation = false; p.MinLineLength = -1;
  p.MaxDistanceBetweenTwoLines = 6.0; p.LineFitErrorThreshold = 1.0; p.MaxErrorThreshold = 1.3;
  auto detector = cv::ximgproc::createEdgeDrawing();
  detector->setParams(p);
  detector->detectEdges(gray);
  Edges result;
  result.offsets.push_back(0);
  for (const auto& chain : detector->getSegments()) {
    if (chain.empty()) continue; // Upstream emits an empty placeholder on an empty scene.
    if (chain.size() > result.points.max_size() - result.points.size() ||
        result.offsets.size() == result.offsets.max_size())
      throw std::length_error("Edge output exceeds container representation");
    for (const auto& point : chain) result.points.push_back({point.x, point.y});
    result.offsets.push_back(result.points.size());
  }
  return result;
}
}
