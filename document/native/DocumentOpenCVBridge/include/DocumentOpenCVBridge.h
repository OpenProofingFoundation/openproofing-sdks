#ifndef IDENTITY_EVIDENCE_OPENCV_BRIDGE_H
#define IDENTITY_EVIDENCE_OPENCV_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct IEOpenCVPoint {
  double x;
  double y;
} IEOpenCVPoint;

typedef struct IEOpenCVQuadrilateral {
  IEOpenCVPoint topLeft;
  IEOpenCVPoint topRight;
  IEOpenCVPoint bottomRight;
  IEOpenCVPoint bottomLeft;
} IEOpenCVQuadrilateral;

__attribute__((visibility("default"))) bool IEOpenCVDetectDocumentQuadrilateralRGBA(
  const uint8_t *pixels,
  int32_t width,
  int32_t height,
  size_t bytesPerRow,
  int32_t resizeThreshold,
  double areaScaleMinFactor,
  IEOpenCVQuadrilateral *output
);

// Four top-left-origin pixel-edge points, TL/TR/BR/BL; row-major 3x3 matrices.
__attribute__((visibility("default"))) bool IEOpenCVID1Matrices(const double *sourcePoints, double *forward, double *inverse);
__attribute__((visibility("default"))) bool IEOpenCVWarpRGBA(const uint8_t *pixels, int32_t width, int32_t height,
  size_t bytesPerRow, const double *sourceToOutput, uint8_t *output,
  int32_t outputWidth, int32_t outputHeight, size_t outputBytesPerRow);


// Full upright RGB8; convex ordered prior in source pixel-edge coordinates. The prior
// initializes segmentation and is never substituted for the resulting observed mask.
// This synchronous operation is serialized internally and must run off the UI thread.
// Inputs remain caller-owned and unchanged; no pointer is retained. Dimensions must
// fit OpenCV's signed graph-index arithmetic. There is no resolution or point-count
// budget; allocation can still fail. No resizing or truncation. Status is not authenticity.
typedef struct IEOpenCVCardAnalysis IEOpenCVCardAnalysis;
typedef struct IEOpenCVPixelPoint { int32_t x; int32_t y; } IEOpenCVPixelPoint;
enum {
  IEOpenCVCardSuccess = 0,
  IEOpenCVCardInvalidInput = 1,
  IEOpenCVCardResourceLimit = 2,
  IEOpenCVCardProcessingFailure = 3
};
__attribute__((visibility("default"))) int32_t IEOpenCVAnalyzeCardRGB(
  const uint8_t *pixels, size_t availableBytes, int32_t width, int32_t height,
  size_t bytesPerRow, const double *corners, IEOpenCVCardAnalysis **output);
// Borrowed read-only buffers remain valid until Release. Points are integer pixel
// indices: add (0.5, 0.5) when rendering. Offsets include the terminal point count;
// each adjacent pair bounds one complete chain. Mask is row-major 0/1, width*height.
__attribute__((visibility("default"))) const IEOpenCVPixelPoint *IEOpenCVCardAnalysisPoints(
  const IEOpenCVCardAnalysis *result, size_t *count);
__attribute__((visibility("default"))) const uint64_t *IEOpenCVCardAnalysisOffsets(
  const IEOpenCVCardAnalysis *result, size_t *count);
__attribute__((visibility("default"))) const uint8_t *IEOpenCVCardAnalysisMask(
  const IEOpenCVCardAnalysis *result, size_t *count);
__attribute__((visibility("default"))) void IEOpenCVCardAnalysisRelease(IEOpenCVCardAnalysis *result);

#ifdef __cplusplus
}
#endif

#endif
