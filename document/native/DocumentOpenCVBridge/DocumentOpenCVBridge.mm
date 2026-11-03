#include "DocumentOpenCVBridge.h"

#include <DocumentDetector.h>
#include <opencv2/imgproc.hpp>

#include <cmath>
#include <exception>
#include <vector>

bool IEOpenCVID1Matrices(const double *sourcePoints, double *forward, double *inverse) {
  if (!sourcePoints || !forward || !inverse) return false;
  try {
    std::vector<cv::Point2f> source;
    for (int i = 0; i < 4; ++i) {
      if (!std::isfinite(sourcePoints[2*i]) || !std::isfinite(sourcePoints[2*i+1])) return false;
      source.emplace_back(sourcePoints[2*i], sourcePoints[2*i+1]);
    }
    if (!cv::isContourConvex(source) || std::abs(cv::contourArea(source)) < 1) return false;
    const std::vector<cv::Point2f> destination = {{0,0}, {85.60f,0}, {85.60f,53.98f}, {0,53.98f}};
    const cv::Mat matrix = cv::getPerspectiveTransform(source, destination, cv::DECOMP_LU);
    cv::Mat backward;
    if (!cv::checkRange(matrix) || cv::invert(matrix, backward, cv::DECOMP_LU) == 0
        || !cv::checkRange(backward)) return false;
    for (int i = 0; i < 9; ++i) {
      forward[i] = matrix.at<double>(i/3, i%3);
      inverse[i] = backward.at<double>(i/3, i%3);
    }
    return true;
  } catch (...) { return false; }
}

bool IEOpenCVWarpRGBA(const uint8_t *pixels, int32_t width, int32_t height,
  size_t bytesPerRow, const double *sourceToOutput, uint8_t *output,
  int32_t outputWidth, int32_t outputHeight, size_t outputBytesPerRow) {
  if (!pixels || !sourceToOutput || !output || width <= 0 || height <= 0
      || outputWidth <= 0 || outputHeight <= 0
      || bytesPerRow < size_t(width)*4 || outputBytesPerRow < size_t(outputWidth)*4) return false;
  try {
    cv::Mat matrix(3, 3, CV_64F, const_cast<double *>(sourceToOutput));
    if (!cv::checkRange(matrix) || std::abs(cv::determinant(matrix)) < 1e-15) return false;
    cv::Mat source(height, width, CV_8UC4, const_cast<uint8_t *>(pixels), bytesPerRow);
    cv::Mat destination(outputHeight, outputWidth, CV_8UC4, output, outputBytesPerRow);
    cv::warpPerspective(source, destination, matrix, destination.size(), cv::INTER_LINEAR,
      cv::BORDER_CONSTANT, cv::Scalar(0,0,0,0));
    return true;
  } catch (...) { return false; }
}

namespace {

IEOpenCVPoint bridgePoint(const cv::Point &point) {
  return IEOpenCVPoint{
    .x = static_cast<double>(point.x),
    .y = static_cast<double>(point.y),
  };
}

}  // namespace

bool IEOpenCVDetectDocumentQuadrilateralRGBA(
  const uint8_t *pixels,
  int32_t width,
  int32_t height,
  size_t bytesPerRow,
  int32_t resizeThreshold,
  double areaScaleMinFactor,
  IEOpenCVQuadrilateral *output
) {
  if (
    pixels == nullptr || output == nullptr || width <= 0 || height <= 0
    || bytesPerRow < static_cast<size_t>(width) * 4 || resizeThreshold <= 0
    || !std::isfinite(areaScaleMinFactor) || areaScaleMinFactor <= 0
    || areaScaleMinFactor >= 1
  ) {
    return false;
  }

  try {
    cv::Mat rgba(
      height,
      width,
      CV_8UC4,
      const_cast<uint8_t *>(pixels),
      bytesPerRow
    );
    cv::Mat bgr;
    cv::cvtColor(rgba, bgr, cv::COLOR_RGBA2BGR);

    detector::DocumentDetector detector(bgr, resizeThreshold, 0, 1.0);
    detector.options.areaScaleMinFactor = areaScaleMinFactor;
    const std::vector<std::vector<cv::Point>> candidates = detector.scanPoint();
    if (candidates.empty() || candidates.front().size() != 4) {
      return false;
    }

    const std::vector<cv::Point> &points = candidates.front();
    *output = IEOpenCVQuadrilateral{
      .topLeft = bridgePoint(points[0]),
      .topRight = bridgePoint(points[1]),
      .bottomRight = bridgePoint(points[2]),
      .bottomLeft = bridgePoint(points[3]),
    };
    return true;
  } catch (const std::exception &) {
    return false;
  } catch (...) {
    return false;
  }
}
