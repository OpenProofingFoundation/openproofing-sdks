#if defined(__clang__)
#pragma clang fp contract(off)
#endif
#include "kenshiki/portrait.hpp"
#include <algorithm>
#include <array>
#include <cmath>
#include <limits>
#include <utility>
#if defined(__APPLE__)
#include <CommonCrypto/CommonDigest.h>
#else
#include <openssl/evp.h>
#endif

namespace kenshiki {
namespace {
[[noreturn]] void fail(Failure reason) { throw ContractError(reason); }
bool lower_hex(char value) noexcept { return (value >= '0' && value <= '9') || (value >= 'a' && value <= 'f'); }
bool identifier(const std::string& value) noexcept {
    if (value.size() != 36) return false;
    for (std::size_t i = 0; i < value.size(); ++i) {
        const bool separator = i == 8 || i == 13 || i == 18 || i == 23;
        if (separator ? value[i] != '-' : !lower_hex(value[i])) return false;
    }
    return true;
}
const std::array<std::string, 7> pixel_fields = {
    "width", "height", "format", "rowStrideBytes", "byteLength", "sha256", "orientation"};
const std::array<std::string, 15> binding_fields = {
    "sessionID", "attemptID", "operationID", "referenceCaptureID", "probeCaptureID",
    "referenceArtifactID", "probeArtifactID", "referenceSourceSHA256", "probeSourceSHA256",
    "referenceSHA256", "probeSHA256", "referenceLineageSHA256", "probeLineageSHA256",
    "artifactManifestSHA256", "preprocessingManifestSHA256"};
template <std::size_t N> void require_fields(const Fields& value, const std::array<std::string, N>& names) {
    if (value.size() != names.size()) fail(Failure::invalid_schema);
    for (const auto& name : names) if (!value.contains(name)) fail(Failure::invalid_schema);
}
std::uint64_t positive_integer(const Scalar& value) {
    if (const auto* number = std::get_if<std::uint64_t>(&value)) {
        if (*number > 0 && *number <= static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max())) return *number;
    }
    if (const auto* number = std::get_if<std::int64_t>(&value)) {
        if (*number > 0) return static_cast<std::uint64_t>(*number);
    }
    fail(Failure::invalid_pixels);
}
const std::string& text(const Scalar& value, Failure reason) {
    const auto* string = std::get_if<std::string>(&value);
    if (string == nullptr) fail(reason);
    return *string;
}
} // namespace
bool is_digest(const std::string& value) noexcept {
    return value.size() == 64 && std::all_of(value.begin(), value.end(), lower_hex);
}
std::string sha256(std::span<const std::byte> bytes) {
    std::array<unsigned char, 32> digest{};
#if defined(__APPLE__)
    // Callers of this helper may supply more than the pixel ceiling. Chunking
    // avoids narrowing a size_t length through CommonCrypto's CC_LONG.
    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    while (!bytes.empty()) {
        const auto count = std::min(bytes.size(), static_cast<std::size_t>(std::numeric_limits<CC_LONG>::max()));
        CC_SHA256_Update(&context, bytes.data(), static_cast<CC_LONG>(count));
        bytes = bytes.subspan(count);
    }
    CC_SHA256_Final(digest.data(), &context);
#else
    unsigned int length = 0;
    if (EVP_Digest(bytes.data(), bytes.size(), digest.data(), &length, EVP_sha256(), nullptr) != 1 || length != digest.size())
        fail(Failure::integrity_failure);
#endif
    constexpr char digits[] = "0123456789abcdef";
    std::string result;
    result.reserve(digest.size() * 2);
    for (const auto value : digest) {
        result.push_back(digits[value >> 4]);
        result.push_back(digits[value & 15]);
    }
    return result;
}
PixelSnapshot::PixelSnapshot(std::shared_ptr<const std::vector<std::byte>> owner, std::uint32_t width,
                             std::uint32_t height, std::uint8_t orientation, std::uint8_t channels, std::string digest)
    : owner_(std::move(owner)), width_(width), height_(height), orientation_(orientation), channels_(channels), digest_(std::move(digest)) {}
PixelSnapshot PixelSnapshot::create(const Fields& descriptor, std::span<const std::byte> bytes) {
    require_fields(descriptor, pixel_fields);
    const auto& format = text(descriptor.at("format"), Failure::unsupported_format);
    if (format != "rgb8" && format != "gray8") fail(Failure::unsupported_format);
    const auto width = positive_integer(descriptor.at("width"));
    const auto height = positive_integer(descriptor.at("height"));
    const auto row = positive_integer(descriptor.at("rowStrideBytes"));
    const auto size = positive_integer(descriptor.at("byteLength"));
    const auto orientation = positive_integer(descriptor.at("orientation"));
    if (orientation > 8) fail(Failure::invalid_pixels);
    // Check the dimensions before any multiplication, allocation or pointer use.
    if (width > 16384 || height > 16384) fail(Failure::resource_limit);
    const std::uint64_t pixels = width * height;
    if (pixels > 67108864) fail(Failure::resource_limit);
    const std::uint8_t channels = format == "rgb8" ? 3 : 1;
    const std::uint64_t expected_row = width * channels;
    const std::uint64_t expected_size = expected_row * height;
    if (expected_size > 268435456 || expected_size > std::numeric_limits<std::size_t>::max()) fail(Failure::resource_limit);
    if (row != expected_row || size != expected_size || bytes.size() != expected_size) fail(Failure::invalid_pixels);
    const auto& digest = text(descriptor.at("sha256"), Failure::invalid_schema);
    if (!is_digest(digest)) fail(Failure::invalid_schema);
    // Own first, hash the exact bytes owned. Caller storage must remain stable
    // for this synchronous copy, as for any C++ span read (concurrent mutation is UB).
    auto owner = std::make_shared<const std::vector<std::byte>>(bytes.begin(), bytes.end());
    if (sha256(*owner) != digest) fail(Failure::integrity_failure);
    return PixelSnapshot(std::move(owner), static_cast<std::uint32_t>(width), static_cast<std::uint32_t>(height),
                         static_cast<std::uint8_t>(orientation), channels, digest);
}
ComparisonBinding ComparisonBinding::create(const Fields& fields) {
    require_fields(fields, binding_fields);
    std::map<std::string, std::string> accepted;
    for (const auto& name : binding_fields) {
        const auto& value = text(fields.at(name), Failure::invalid_schema);
        if (name.ends_with("SHA256") ? !is_digest(value) : !identifier(value)) fail(Failure::invalid_schema);
        accepted.emplace(name, value);
    }
    return ComparisonBinding(std::move(accepted));
}
void validate_completion(const ComparisonBinding& expected, const ComparisonBinding& completion) {
    if (expected != completion) fail(Failure::binding_mismatch);
}
ComparisonRequest::ComparisonRequest(ComparisonBinding binding, PixelSnapshot reference, PixelSnapshot probe)
    : binding_(std::move(binding)), reference_(reference), probe_(probe) {
    if (binding_.reference_digest() != reference_.digest() || binding_.probe_digest() != probe_.digest()) fail(Failure::integrity_failure);
}
void CompletionFence::begin(ComparisonRequest request) {
    std::lock_guard lock(mutex_);
    if (current_) fail(Failure::operation_unavailable);
    if (used_operations_.contains(request.binding().operation_id())) fail(Failure::operation_reused);
    used_operations_.insert(request.binding().operation_id());
    current_ = std::move(request);
}
void CompletionFence::cancel(const std::string& operation_id, const std::function<void()>& on_cancel) {
    {
        std::lock_guard lock(mutex_);
        if (!current_ || current_->binding().operation_id() != operation_id) fail(Failure::operation_unavailable);
        current_.reset();
    }
    on_cancel();
}
ComparisonRequest CompletionFence::complete(const ComparisonBinding& completion) {
    std::lock_guard lock(mutex_);
    if (!current_) fail(Failure::operation_unavailable);
    validate_completion(current_->binding(), completion);
    auto request = *current_;
    current_.reset();
    return request;
}
EmbeddingSpace::EmbeddingSpace(std::string manifest, EmbeddingDomain domain, std::uint32_t dimensions, double minimum_norm)
    : manifest_(std::move(manifest)), domain_(domain), dimensions_(dimensions), minimum_norm_(minimum_norm) {
    if (!is_digest(manifest_)) fail(Failure::invalid_digest);
    if (dimensions == 0 || !std::isfinite(minimum_norm) || minimum_norm <= 0 ||
        (domain != EmbeddingDomain::face_identity && domain != EmbeddingDomain::document_revision)) fail(Failure::invalid_space);
}
UnitEmbedding UnitEmbedding::normalize(std::span<const float> features, const EmbeddingSpace& space) {
    if (features.size() != space.dimensions()) fail(Failure::dimension_mismatch);
    double squared = 0;
    for (const float value : features) {
        if (!std::isfinite(value)) fail(Failure::nonfinite_feature);
        const double promoted = value;
        squared += promoted * promoted;
    }
    const double norm = std::sqrt(squared);
    if (!std::isfinite(norm) || norm <= 0 || norm < space.minimum_norm()) fail(Failure::invalid_norm);
    std::vector<double> components;
    components.reserve(features.size());
    for (const auto value : features) components.push_back(static_cast<double>(value) / norm);
    return UnitEmbedding(space, norm, std::move(components));
}
double UnitEmbedding::cosine(const UnitEmbedding& other) const {
    if (space_ != other.space_) fail(Failure::incompatible_space);
    double dot = 0;
    for (std::size_t i = 0; i < components_.size(); ++i) dot += components_[i] * other.components_[i];
    return std::clamp(dot, -1.0, 1.0);
}
double UnitEmbedding::angular_distance(const UnitEmbedding& other) const { return std::acos(cosine(other)); }
CosineObservation UnitEmbedding::observe(const UnitEmbedding& other) const { return CosineObservation(space_, cosine(other)); }
double CosineObservation::angular_distance() const noexcept { return std::acos(value_); }
BoundComparisonObservation::BoundComparisonObservation(ComparisonBinding binding, CosineObservation similarity)
    : binding_(std::move(binding)), similarity_(std::move(similarity)) {
    if (similarity_.space().domain() != EmbeddingDomain::face_identity ||
        similarity_.space().artifact_manifest() != binding_.artifact_manifest()) fail(Failure::binding_mismatch);
}
} // namespace kenshiki
