#pragma once

#include "kenshiki/auraface_input.hpp"

namespace kenshiki::auraface {
class EmbeddingResult final {
public:
    [[nodiscard]] const std::string& input_sha256() const noexcept { return input_sha256_; }
    [[nodiscard]] std::string_view artifact_manifest() const noexcept { return artifact_manifest_sha256(); }
    [[nodiscard]] std::string_view preprocessing() const noexcept { return preprocessing_sha256(); }
    [[nodiscard]] const std::array<float, feature_count>& raw_features() const noexcept { return features_; }
    [[nodiscard]] const UnitEmbedding& embedding() const noexcept { return embedding_; }
private:
    friend class Session;
    EmbeddingResult(std::string input, std::array<float, feature_count> features, UnitEmbedding embedding)
        : input_sha256_(std::move(input)), features_(features), embedding_(std::move(embedding)) {}
    std::string input_sha256_;
    std::array<float, feature_count> features_;
    UnitEmbedding embedding_;
};
// Optional synchronous CPU inference. The caller keeps the supplied model span
// stable for construction; the session owns a verified copy thereafter. Calls on
// one Session serialize; cancellation is checked by the surrounding operation
// fence before publication. This API performs no acquisition, alignment or I/O.
class Session final {
public:
    explicit Session(std::span<const std::byte> model);
    ~Session();
    Session(const Session&) = delete;
    Session& operator=(const Session&) = delete;
    [[nodiscard]] EmbeddingResult infer(const PixelSnapshot& pixels);
private:
    class Impl;
    std::unique_ptr<Impl> impl_;
};
} // namespace kenshiki::auraface
