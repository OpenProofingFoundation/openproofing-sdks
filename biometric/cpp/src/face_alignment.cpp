#include "kenshiki/face_alignment.hpp"
#include <cmath>
#include <cfenv>
#include <algorithm>
#if defined(__clang__)
#pragma clang fp contract(off)
#endif
#if defined(__FAST_MATH__)
#error "Alignment requires IEEE floating-point semantics"
#endif
namespace kenshiki {
namespace {
// ArcFace 112 template, pinned explicitly by the alignment route contract.
constexpr FaceLandmarks target{{{38.2946,51.6963},{73.5318,51.5014},{56.0252,71.7366},
                                {41.5493,92.3655},{70.7299,92.2041}}};
void invalid() { throw ContractError(Failure::invalid_pixels); }
}
FaceSimilarityTransform fit_face(const FaceLandmarks& source) {
    if (std::fegetround() != FE_TONEAREST) invalid();
    FacePoint mean{}, destination{};
    for (std::size_t i=0; i<source.size(); ++i) {
        if (!std::isfinite(source[i].x) || !std::isfinite(source[i].y)) invalid();
        mean.x += source[i].x / 5; mean.y += source[i].y / 5;
        destination.x += target[i].x / 5; destination.y += target[i].y / 5;
    }
    double denominator=0, real=0, imaginary=0, xx=0, yy=0, xy=0;
    for (std::size_t i=0; i<source.size(); ++i) {
        const double x=source[i].x-mean.x, y=source[i].y-mean.y;
        const double u=target[i].x-destination.x, v=target[i].y-destination.y;
        denominator += x*x+y*y; xx+=x*x; yy+=y*y; xy+=x*y;
        real += x*u+y*v; imaginary += x*v-y*u;
    }
    // Numerical degeneracy only, not a learned recognition/quality threshold.
    if (!std::isfinite(denominator) || denominator <= 0 ||
        xx*yy-xy*xy <= denominator*denominator*1e-12) invalid();
    real/=denominator; imaginary/=denominator;
    const double determinant=real*real+imaginary*imaginary;
    if (!std::isfinite(determinant) || determinant <= 1e-24) invalid();
    return {real, imaginary, destination.x-real*mean.x+imaginary*mean.y,
                             destination.y-imaginary*mean.x-real*mean.y};
}
PixelSnapshot align_face(const PixelSnapshot& source, const FaceLandmarks& landmarks) {
    if (source.channels()!=3 || source.orientation()!=1) invalid();
    for (const auto& p: landmarks) {
        if (p.x<0 || p.y<0 || p.x>source.width() || p.y>source.height()) invalid();
    }
    const auto t=fit_face(landmarks);
    const double determinant=t.real*t.real+t.imaginary*t.imaginary;
    std::vector<std::byte> output(112*112*3);
    const auto sample=[&](double x, double y, std::size_t c) -> double {
        if (x<0 || y<0 || x>=source.width() || y>=source.height()) return 0;
        const auto offset=(static_cast<std::size_t>(y)*source.width()+static_cast<std::size_t>(x))*3+c;
        return std::to_integer<unsigned char>(source.bytes()[offset]);
    };
    for (std::size_t y=0; y<112; ++y) for (std::size_t x=0; x<112; ++x) {
        const double u=static_cast<double>(x)+.5-t.translate_x, v=static_cast<double>(y)+.5-t.translate_y;
        const double sx=(t.real*u+t.imaginary*v)/determinant-.5;
        const double sy=(-t.imaginary*u+t.real*v)/determinant-.5;
        if (!std::isfinite(sx) || !std::isfinite(sy)) invalid();
        const double ix=std::floor(sx), iy=std::floor(sy), dx=sx-ix, dy=sy-iy;
        for (std::size_t c=0; c<3; ++c) {
            const double top=sample(ix,iy,c)*(1-dx)+sample(ix+1,iy,c)*dx;
            const double bottom=sample(ix,iy+1,c)*(1-dx)+sample(ix+1,iy+1,c)*dx;
            const auto value=static_cast<unsigned char>(std::clamp(std::floor(top*(1-dy)+bottom*dy+.5),0.0,255.0));
            output[(y*112+x)*3+c]=static_cast<std::byte>(value);
        }
    }
    const Fields fields{{"width",std::int64_t{112}},{"height",std::int64_t{112}},
                        {"format",std::string("rgb8")},{"rowStrideBytes",std::int64_t{336}},
                        {"byteLength",std::int64_t{37632}},{"orientation",std::int64_t{1}},
                        {"sha256",sha256(output)}};
    return PixelSnapshot::create(fields,output);
}
} // namespace kenshiki
