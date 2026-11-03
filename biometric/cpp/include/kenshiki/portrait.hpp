#pragma once

#include <cstddef>
#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <set>
#include <span>
#include <stdexcept>
#include <string>
#include <utility>
#include <variant>
#include <vector>

namespace kenshiki {
enum class Failure {
    invalid_schema, invalid_pixels, unsupported_format, resource_limit,
    integrity_failure, binding_mismatch, invalid_digest, invalid_space,
    dimension_mismatch, nonfinite_feature, invalid_norm, incompatible_space,
    operation_unavailable, operation_reused
};
class ContractError final : public std::exception {
public:
    explicit ContractError(Failure reason) noexcept : reason_(reason) {}
    [[nodiscard]] Failure reason() const noexcept { return reason_; }
    [[nodiscard]] const char* what() const noexcept override { return "contract_failure"; }
private:
    Failure reason_;
};
// Schema ingress preserves JSON number/boolean distinctions. monostate represents
// null or an unsupported composite; no JSON parser or coercion lives in the core.
using Scalar = std::variant<std::monostate, bool, std::int64_t, std::uint64_t, double, std::string>;
using Fields = std::map<std::string, Scalar>;
[[nodiscard]] bool is_digest(const std::string& value) noexcept;
[[nodiscard]] std::string sha256(std::span<const std::byte> bytes);

class PixelSnapshot final {
public:
    [[nodiscard]] static PixelSnapshot create(const Fields& descriptor, std::span<const std::byte> bytes);
    // Copies share immutable storage. Explicitly declaring copy operations keeps
    // moved-from objects valid as well: an rvalue copies the live ownership lease.
    PixelSnapshot(const PixelSnapshot&) = default;
    PixelSnapshot& operator=(const PixelSnapshot&) = default;
    [[nodiscard]] std::span<const std::byte> bytes() const noexcept { return *owner_; }
    [[nodiscard]] std::uint32_t width() const noexcept { return width_; }
    [[nodiscard]] std::uint32_t height() const noexcept { return height_; }
    [[nodiscard]] std::uint8_t orientation() const noexcept { return orientation_; }
    [[nodiscard]] std::uint8_t channels() const noexcept { return channels_; }
    [[nodiscard]] const std::string& digest() const noexcept { return digest_; }
private:
    PixelSnapshot(std::shared_ptr<const std::vector<std::byte>> owner, std::uint32_t width,
                  std::uint32_t height, std::uint8_t orientation, std::uint8_t channels, std::string digest);
    std::shared_ptr<const std::vector<std::byte>> owner_;
    std::uint32_t width_, height_;
    std::uint8_t orientation_, channels_;
    std::string digest_;
};

class ComparisonBinding final {
public:
    ComparisonBinding(const ComparisonBinding&) = default;
    ComparisonBinding& operator=(const ComparisonBinding&) = default;
    [[nodiscard]] static ComparisonBinding create(const Fields& fields);
    [[nodiscard]] bool operator==(const ComparisonBinding&) const = default;
    [[nodiscard]] const std::string& operation_id() const { return fields_.at("operationID"); }
    [[nodiscard]] const std::string& reference_digest() const { return fields_.at("referenceSHA256"); }
    [[nodiscard]] const std::string& probe_digest() const { return fields_.at("probeSHA256"); }
    [[nodiscard]] const std::string& artifact_manifest() const { return fields_.at("artifactManifestSHA256"); }
private:
    explicit ComparisonBinding(std::map<std::string, std::string> fields) : fields_(std::move(fields)) {}
    std::map<std::string, std::string> fields_;
};
void validate_completion(const ComparisonBinding& expected, const ComparisonBinding& completion);
class ComparisonRequest final {
public:
    ComparisonRequest(ComparisonBinding binding, PixelSnapshot reference, PixelSnapshot probe);
    [[nodiscard]] const ComparisonBinding& binding() const noexcept { return binding_; }
    [[nodiscard]] const PixelSnapshot& reference() const noexcept { return reference_; }
    [[nodiscard]] const PixelSnapshot& probe() const noexcept { return probe_; }
private:
    ComparisonBinding binding_;
    PixelSnapshot reference_, probe_;
};
// Optional interactive envelope, separate from batch image/math operations.
// consume/cancel/begin are serialized atomically; invalidation precedes external
// resource cancellation. A mismatched completion never consumes the live request.
class CompletionFence final {
public:
    void begin(ComparisonRequest request);
    void cancel(const std::string& operation_id, const std::function<void()>& on_cancel);
    [[nodiscard]] ComparisonRequest complete(const ComparisonBinding& completion);
private:
    std::mutex mutex_;
    std::optional<ComparisonRequest> current_;
    std::set<std::string> used_operations_;
};

enum class EmbeddingDomain { face_identity, document_revision };
class EmbeddingSpace final {
public:
    EmbeddingSpace(std::string manifest, EmbeddingDomain domain, std::uint32_t dimensions, double minimum_norm);
    EmbeddingSpace(const EmbeddingSpace&) = default;
    EmbeddingSpace& operator=(const EmbeddingSpace&) = default;
    [[nodiscard]] bool operator==(const EmbeddingSpace&) const = default;
    [[nodiscard]] std::uint32_t dimensions() const noexcept { return dimensions_; }
    [[nodiscard]] double minimum_norm() const noexcept { return minimum_norm_; }
    [[nodiscard]] EmbeddingDomain domain() const noexcept { return domain_; }
    [[nodiscard]] const std::string& artifact_manifest() const noexcept { return manifest_; }
private:
    std::string manifest_;
    EmbeddingDomain domain_;
    std::uint32_t dimensions_;
    double minimum_norm_;
};
class CosineObservation;
class UnitEmbedding final {
public:
    UnitEmbedding(const UnitEmbedding&) = default;
    UnitEmbedding& operator=(const UnitEmbedding&) = default;
    [[nodiscard]] static UnitEmbedding normalize(std::span<const float> features, const EmbeddingSpace& space);
    [[nodiscard]] double raw_norm() const noexcept { return norm_; }
    [[nodiscard]] std::span<const double> components() const noexcept { return components_; }
    [[nodiscard]] double cosine(const UnitEmbedding& other) const;
    [[nodiscard]] double angular_distance(const UnitEmbedding& other) const;
    [[nodiscard]] CosineObservation observe(const UnitEmbedding& other) const;
private:
    UnitEmbedding(EmbeddingSpace space, double norm, std::vector<double> components)
        : space_(std::move(space)), norm_(norm), components_(std::move(components)) {}
    EmbeddingSpace space_;
    double norm_;
    std::vector<double> components_;
};
class CosineObservation final {
public:
    [[nodiscard]] const EmbeddingSpace& space() const noexcept { return space_; }
    [[nodiscard]] double value() const noexcept { return value_; }
    [[nodiscard]] double angular_distance() const noexcept;
private:
    friend class UnitEmbedding;
    CosineObservation(EmbeddingSpace space, double value) : space_(std::move(space)), value_(value) {}
    EmbeddingSpace space_;
    double value_;
};
class BoundComparisonObservation final {
public:
    BoundComparisonObservation(ComparisonBinding binding, CosineObservation similarity);
    [[nodiscard]] const ComparisonBinding& binding() const noexcept { return binding_; }
    [[nodiscard]] const CosineObservation& similarity() const noexcept { return similarity_; }
private:
    ComparisonBinding binding_;
    CosineObservation similarity_;
};
} // namespace kenshiki
