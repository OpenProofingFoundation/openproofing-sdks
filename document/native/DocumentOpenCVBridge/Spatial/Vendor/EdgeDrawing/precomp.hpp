// Local compilation shim; upstream algorithm/header files remain byte-for-byte pinned.
// The module-wide upstream precompiled header imports unavailable private core and all
// ximgproc headers. This translation unit needs only these public dependencies.
#include <opencv2/core.hpp>
#include <opencv2/imgproc.hpp>
#include <opencv2/ximgproc/edge_drawing.hpp>
#include <algorithm>
#include <map>
