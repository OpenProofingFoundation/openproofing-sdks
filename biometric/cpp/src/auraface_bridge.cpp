#include "kenshiki/auraface_bridge.h"
#include "kenshiki/auraface.hpp"
#include "kenshiki/face_alignment.hpp"
#include <algorithm>
namespace {
// Both entry points consume this one owned raster and alignment implementation.
kenshiki::PixelSnapshot aligned_snapshot(const uint8_t *rgb, size_t count,
                                        uint32_t width, uint32_t height, const double *points) {
    if (!rgb || !points || width==0 || height==0 || width>4096 || height>4096 ||
        static_cast<uint64_t>(width)*height>8388608 ||
        static_cast<uint64_t>(width)*height*3!=count)
        throw kenshiki::ContractError(kenshiki::Failure::invalid_pixels);
    const std::span<const std::byte> bytes{reinterpret_cast<const std::byte*>(rgb),count};
    const kenshiki::Fields fields{{"width",static_cast<std::int64_t>(width)},
        {"height",static_cast<std::int64_t>(height)},{"format",std::string("rgb8")},
        {"rowStrideBytes",static_cast<std::int64_t>(width)*3},
        {"byteLength",static_cast<std::int64_t>(count)},{"orientation",std::int64_t{1}},
        {"sha256",kenshiki::sha256(bytes)}};
    const auto source=kenshiki::PixelSnapshot::create(fields,bytes);
    kenshiki::FaceLandmarks landmarks{};
    for (size_t i=0;i<5;++i) landmarks[i]={points[2*i],points[2*i+1]};
    return kenshiki::align_face(source,landmarks);
}
void copy_digest(const kenshiki::PixelSnapshot& aligned, char *digest) {
    std::copy(aligned.digest().begin(),aligned.digest().end(),digest);
    digest[64]='\0';
}
}
extern "C" void *face_aura_create(const uint8_t *model, size_t count) {
    if (!model || count!=kenshiki::auraface::model_size) return nullptr;
    try { return new kenshiki::auraface::Session({reinterpret_cast<const std::byte*>(model),count}); }
    catch (...) { return nullptr; }
}
extern "C" void face_aura_destroy(void *session) {
    delete static_cast<kenshiki::auraface::Session*>(session);
}
extern "C" int face_aura_preflight(const uint8_t *rgb, size_t count,
                                      uint32_t width, uint32_t height,
                                      const double *points, char *aligned_sha256) {
    if (!aligned_sha256) return 1;
    try {
        const auto aligned=aligned_snapshot(rgb,count,width,height,points);
        copy_digest(aligned,aligned_sha256);
        return 0;
    } catch (const kenshiki::ContractError&) { return 1; }
    catch (...) { return 2; }
}
extern "C" int face_aura_embed(void *session, const uint8_t *rgb, size_t count,
                                  uint32_t width, uint32_t height, const double *points,
                                  float *features, char *aligned_sha256) {
    if (!session || !features || !aligned_sha256) return 1;
    try {
        const auto aligned=aligned_snapshot(rgb,count,width,height,points);
        const auto result=static_cast<kenshiki::auraface::Session*>(session)->infer(aligned);
        std::copy(result.raw_features().begin(),result.raw_features().end(),features);
        copy_digest(aligned,aligned_sha256);
        return 0;
    } catch (const kenshiki::ContractError&) { return 1; }
    catch (...) { return 2; }
}
