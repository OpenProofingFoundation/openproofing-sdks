#include "kenshiki/face_alignment.hpp"
#include <cassert>
#include <limits>
#include <cmath>
using namespace kenshiki;
namespace {
constexpr FaceLandmarks canonical{{{38.2946,51.6963},{73.5318,51.5014},{56.0252,71.7366},
                                   {41.5493,92.3655},{70.7299,92.2041}}};
void refused(const FaceLandmarks& points) {
    bool failed=false;
    try { static_cast<void>(fit_face(points)); } catch(const ContractError&) { failed=true; }
    assert(failed);
}
}
int main() {
    const auto identity=fit_face(canonical);
    assert(std::abs(identity.real-1)<1e-12 && std::abs(identity.imaginary)<1e-12);
    assert(std::abs(identity.translate_x)<1e-10 && std::abs(identity.translate_y)<1e-10);
    auto transformed=canonical;
    for (auto& p: transformed) { const auto x=p.x; p.x=-2*p.y+300; p.y=2*x+20; }
    const auto inverse=fit_face(transformed);
    assert(std::abs(inverse.real)<1e-12 && std::abs(inverse.imaginary+.5)<1e-12);
    assert(std::abs(inverse.translate_x+10)<1e-10 && std::abs(inverse.translate_y-150)<1e-10);
    refused(FaceLandmarks{});
    FaceLandmarks collinear{};
    for(size_t i=0;i<5;++i) collinear[i]={static_cast<double>(i),static_cast<double>(2*i)};
    refused(collinear);
    auto nonfinite=canonical; nonfinite[4].x=std::numeric_limits<double>::quiet_NaN(); refused(nonfinite);
    nonfinite=canonical; nonfinite[1].y=std::numeric_limits<double>::infinity(); refused(nonfinite);
    auto mirrored=canonical; for(auto& p:mirrored) p.x=112-p.x;
    const auto preserved=fit_face(mirrored);
    assert(preserved.real*preserved.real+preserved.imaginary*preserved.imaginary>0);
    // Reflection never produces an exact orientation-preserving recovery.
    double residual=0;
    for(size_t i=0;i<5;++i) {
        const double x=preserved.real*mirrored[i].x-preserved.imaginary*mirrored[i].y+preserved.translate_x;
        const double y=preserved.imaginary*mirrored[i].x+preserved.real*mirrored[i].y+preserved.translate_y;
        residual+=std::hypot(x-canonical[i].x,y-canonical[i].y);
    }
    assert(residual>1);
    std::vector<std::byte> bytes(112*112*3);
    for(size_t i=0;i<bytes.size();++i) bytes[i]=static_cast<std::byte>(i%256);
    const Fields fields{{"width",std::int64_t{112}},{"height",std::int64_t{112}},
        {"format",std::string("rgb8")},{"rowStrideBytes",std::int64_t{336}},
        {"byteLength",std::int64_t{37632}},{"orientation",std::int64_t{1}},{"sha256",sha256(bytes)}};
    const auto image=PixelSnapshot::create(fields,bytes);
    const auto aligned=align_face(image,canonical);
    assert(aligned.digest()==image.digest());
    auto outside=canonical; outside[0].x=-1;
    bool rejected=false;
    try { static_cast<void>(align_face(image,outside)); } catch(const ContractError&) { rejected=true; }
    assert(rejected);
    transformed=canonical;
    for(auto& p: transformed) { p.x+=10000; p.y+=10000; }
    rejected=false;
    try { static_cast<void>(align_face(image,transformed)); } catch(const ContractError&) { rejected=true; }
    assert(rejected);
}
