#include "kenshiki/portrait.hpp"
#include <atomic>
#include <cmath>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <numbers>
#include <thread>
#include <utility>

using namespace kenshiki;
namespace {
std::size_t assertions = 0;
void check(bool condition) {
    ++assertions;
    if (!condition) throw std::runtime_error("test_assertion");
}
const char* reason(Failure value) {
    switch (value) {
    case Failure::invalid_schema: return "invalid_schema";
    case Failure::invalid_pixels: return "invalid_pixels";
    case Failure::unsupported_format: return "unsupported_format";
    case Failure::resource_limit: return "resource_limit";
    case Failure::integrity_failure: return "integrity_failure";
    case Failure::binding_mismatch: return "binding_mismatch";
    case Failure::invalid_digest: return "invalid_digest";
    case Failure::invalid_space: return "invalid_space";
    case Failure::dimension_mismatch: return "dimension_mismatch";
    case Failure::nonfinite_feature: return "nonfinite_feature";
    case Failure::invalid_norm: return "invalid_norm";
    case Failure::incompatible_space: return "incompatible_space";
    case Failure::operation_unavailable: return "operation_unavailable";
    case Failure::operation_reused: return "operation_reused";
    }
    throw std::runtime_error("unknown_reason");
}
template <typename Function> void expect(const std::string& id, const std::string& expected, Function operation) {
    std::string actual = "valid";
    try { operation(); } catch (const ContractError& error) { actual = reason(error.reason()); }
    if (actual != expected) throw std::runtime_error(id+": "+actual+" != "+expected);
    check(true);
}
std::vector<std::byte> decode_hex(const std::string& hex) {
    std::vector<std::byte> bytes;
    if (hex.size() % 2 != 0) throw std::runtime_error("odd_fixture_hex");
    for (std::size_t i = 0; i < hex.size(); i += 2) {
        bytes.push_back(static_cast<std::byte>(std::stoul(hex.substr(i, 2), nullptr, 16)));
    }
    return bytes;
}
void pixel_case(const std::string& id, const Fields& descriptor, const std::vector<std::byte>& bytes, const std::string& expected) {
    expect(id, expected, [&] { static_cast<void>(PixelSnapshot::create(descriptor, bytes)); });
}
void binding_case(const std::string& id, const Fields& fields, const std::string& expected);
#include "portrait_vectors.inc"
void binding_case(const std::string& id, const Fields& fields, const std::string& expected) {
    expect(id, expected, [&] { validate_completion(ComparisonBinding::create(base_binding), ComparisonBinding::create(fields)); });
}
void ownership_and_bounds() {
    auto source = base_payload;
    auto snapshot = PixelSnapshot::create(base_pixels, source);
    source[0] = std::byte{255};
    source.clear();
    source.shrink_to_fit();
    check(snapshot.bytes()[0] == std::byte{0});
    check(sha256(snapshot.bytes()) == snapshot.digest());
    check(snapshot.width() == 2 && snapshot.height() == 2 && snapshot.channels() == 3 && snapshot.orientation() == 1);
    const auto lease = snapshot;
    auto rvalue_copy = std::move(snapshot);
    check(rvalue_copy.digest() == snapshot.digest());
    check(lease.bytes().data() == snapshot.bytes().data());
    const auto surviving = [] {
        auto input = base_payload;
        auto original = PixelSnapshot::create(base_pixels, input);
        const auto copied = original;
        return copied;
    }();
    check(sha256(surviving.bytes()) == surviving.digest());
    check(sha256({}) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
    for (const auto huge : {std::uint64_t{4294967296ULL}, static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max())}) {
        auto fields = base_pixels;
        fields["width"] = huge;
        pixel_case("overflow-before-allocation", fields, {}, "resource_limit");
    }
    for (const auto invalid : {static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max())+1, std::numeric_limits<std::uint64_t>::max()}) {
        auto fields = base_pixels;
        fields["width"] = invalid;
        pixel_case("outside-signed64-ingress", fields, {}, "invalid_pixels");
    }
    // Resource-valid maximum metadata still rejects truncated payload before allocation.
    auto fields = base_pixels;
    fields["width"] = std::int64_t{16384}; fields["height"] = std::int64_t{4096};
    fields["rowStrideBytes"] = std::int64_t{49152}; fields["byteLength"] = std::int64_t{201326592};
    pixel_case("maximum-metadata-truncated", fields, {}, "invalid_pixels");
}
void completion_races() {
    auto matching_fields = base_binding;
    matching_fields["referenceSHA256"] = base_pixels.at("sha256");
    auto binding = ComparisonBinding::create(matching_fields);
    const auto binding_copy = std::move(binding);
    check(binding == binding_copy);
    const auto pixels = PixelSnapshot::create(base_pixels, base_payload);
    const ComparisonRequest request(binding, pixels, pixels);
    expect("request-substituted-input", "integrity_failure", [&] {
        static_cast<void>(ComparisonRequest(ComparisonBinding::create(base_binding), pixels, pixels));
    });
    auto foreign_fields = matching_fields;
    foreign_fields["attemptID"] = std::string{"ffffffff-0000-0000-0000-000000000000"};
    foreign_fields["operationID"] = std::string{"ffffffff-0000-0000-0000-000000000000"};
    const auto foreign = ComparisonBinding::create(foreign_fields);
    const ComparisonRequest foreign_request(foreign, pixels, pixels);
    CompletionFence fence;
    expect("no-active", "operation_unavailable", [&] { static_cast<void>(fence.complete(binding)); });
    fence.begin(request);
    expect("busy-begin", "operation_unavailable", [&] { fence.begin(foreign_request); });
    expect("foreign-completion", "binding_mismatch", [&] { static_cast<void>(fence.complete(foreign)); });
    expect("foreign-cancel", "operation_unavailable", [&] { fence.cancel(foreign.operation_id(), [] {}); });
    check(fence.complete(binding).reference().digest() == pixels.digest());
    expect("duplicate", "operation_unavailable", [&] { static_cast<void>(fence.complete(binding)); });
    expect("consumed-reuse", "operation_reused", [&] { fence.begin(request); });
    fence.begin(foreign_request);
    fence.cancel(foreign.operation_id(), [&] {
        expect("reentrant-late-completion", "operation_unavailable", [&] { static_cast<void>(fence.complete(foreign)); });
    });
    expect("cancelled-late-completion", "operation_unavailable", [&] { static_cast<void>(fence.complete(foreign)); });
    expect("cancelled-reuse", "operation_reused", [&] { fence.begin(foreign_request); });
    CompletionFence throwing_cancel;
    throwing_cancel.begin(request);
    bool callback_threw = false;
    try {
        throwing_cancel.cancel(binding.operation_id(), [] { throw std::runtime_error("callback_failure"); });
    } catch (const std::runtime_error&) { callback_threw = true; }
    check(callback_threw);
    expect("throwing-cancel-stays-invalid", "operation_unavailable", [&] { static_cast<void>(throwing_cancel.complete(binding)); });
    expect("throwing-cancel-stays-spent", "operation_reused", [&] { throwing_cancel.begin(request); });
    throwing_cancel.begin(foreign_request);
    check(throwing_cancel.complete(foreign).binding() == foreign);
    // A different envelope cannot reuse an already spent operation identity.
    foreign_fields["operationID"] = base_binding.at("operationID");
    expect("foreign-envelope-reuse", "operation_reused", [&] { fence.begin(ComparisonRequest(ComparisonBinding::create(foreign_fields), pixels, pixels)); });
    expect("idle-completion", "operation_unavailable", [&] { static_cast<void>(fence.complete(binding)); });
    CompletionFence racing;
    racing.begin(request);
    std::atomic<unsigned int> accepted{0};
    std::vector<std::thread> workers;
    std::atomic<unsigned int> rejected{0};
    for (unsigned int i = 0; i < 16; ++i) workers.emplace_back([&] {
        try { static_cast<void>(racing.complete(binding)); ++accepted; }
        catch (const ContractError& error) { if (error.reason() == Failure::operation_unavailable) ++rejected; }
    });
    for (auto& worker : workers) worker.join();
    check(accepted == 1 && rejected == 15);
}
EmbeddingSpace space(std::uint32_t size = 2, double floor = 0.01, EmbeddingDomain domain = EmbeddingDomain::face_identity,
                     const std::string& digest = std::string(64, 'a')) {
    return EmbeddingSpace(digest, domain, size, floor);
}
UnitEmbedding embedding(std::vector<float> values, const EmbeddingSpace& contract) {
    return UnitEmbedding::normalize(values, contract);
}
void near(double actual, double expected, double tolerance = 1e-12) { check(std::isfinite(actual) && std::abs(actual - expected) <= tolerance); }
#include "math_vectors.inc"
void embedding_parity() {
    const auto contract = space();
    auto raw = std::vector<float>{3, 4};
    auto a = UnitEmbedding::normalize(raw, contract);
    raw[0] = 99;
    near(a.raw_norm(), 5); near(a.components()[0], .6); near(a.components()[1], .8);
    const auto b = embedding({4, -3}, contract);
    near(a.cosine(b), 0); near(a.angular_distance(b), std::numbers::pi / 2);
    near(a.cosine(embedding({6, 8}, contract)), 1);
    near(a.cosine(embedding({-3, -4}, contract)), -1);
    near(a.angular_distance(embedding({-3, -4}, contract)), std::numbers::pi);
    auto observation_fields = base_binding;
    observation_fields["artifactManifestSHA256"] = std::string(64,'a');
    const auto observation_binding = ComparisonBinding::create(observation_fields);
    const BoundComparisonObservation bound(observation_binding, a.observe(b));
    near(bound.similarity().value(), 0);
    near(bound.similarity().angular_distance(), std::numbers::pi/2);
    check(bound.binding() == observation_binding);
    expect("wrong-observation-artifact", "binding_mismatch", [&] {
        static_cast<void>(BoundComparisonObservation(ComparisonBinding::create(base_binding), a.observe(b)));
    });
    const auto document = embedding({3,4},space(2,.01,EmbeddingDomain::document_revision));
    expect("wrong-observation-domain", "binding_mismatch", [&] {
        static_cast<void>(BoundComparisonObservation(observation_binding, document.observe(document)));
    });
    for (auto values : {std::vector<float>{}, {1}, {1,2,3}})
        expect("wrong-feature-count", "dimension_mismatch", [&] { static_cast<void>(embedding(values, contract)); });
    for (const auto value : {std::numeric_limits<float>::quiet_NaN(), std::numeric_limits<float>::infinity(), -std::numeric_limits<float>::infinity()})
        expect("nonfinite-features", "nonfinite_feature", [&] { static_cast<void>(embedding({value, 1}, contract)); });
    expect("zero-norm", "invalid_norm", [&] { static_cast<void>(embedding({0,0}, contract)); });
    near(embedding({3,4}, space(2,5)).raw_norm(), 5);
    expect("below-floor", "invalid_norm", [&] { static_cast<void>(embedding({1,1}, space(2,5))); });
    for (const auto& incompatible : {space(2,.02), space(2,.01,EmbeddingDomain::document_revision),
                                    space(2,.01,EmbeddingDomain::face_identity,std::string(64,'b')), space(1)}) {
        std::vector<float> values(incompatible.dimensions(), 1);
        expect("incompatible-space", "incompatible_space", [&] { static_cast<void>(a.cosine(embedding(values,incompatible))); });
    }
    const auto tiny = std::numeric_limits<float>::denorm_min();
    const auto extremes = space(2,static_cast<double>(tiny)/2);
    const auto small = embedding({tiny,0},extremes);
    const auto large = embedding({std::numeric_limits<float>::max(),0},extremes);
    near(small.cosine(large),1); check(small.raw_norm()>0); check(std::isfinite(large.raw_norm()));
    for (const auto& digest : {std::string{}, std::string(64,'A'),std::string(64,'g'),std::string(63,'a')})
        expect("invalid-manifest", "invalid_digest", [&] { static_cast<void>(space(2,.01,EmbeddingDomain::face_identity,digest)); });
    expect("zero-dimension", "invalid_space", [&] { static_cast<void>(space(0)); });
    for (const auto floor : {0.0,-1.0,std::numeric_limits<double>::quiet_NaN(),std::numeric_limits<double>::infinity()})
        expect("invalid-floor", "invalid_space", [&] { static_cast<void>(space(2,floor)); });
    const auto copied = std::move(a);
    near(a.cosine(copied),1);
}
} // namespace
int main() {
    try {
        shared_vectors(); shared_math_vectors(); ownership_and_bounds(); completion_races(); embedding_parity();
        std::cout << "PASS C++ portable contract assertions: " << assertions << '\n';
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return EXIT_FAILURE;
    }
    return EXIT_SUCCESS;
}
