#include "kenshiki/frame_selection.h"
#include <array>
#include <cassert>
#include <cstring>
#include <limits>

namespace {
template <size_t N> void text(char (&target)[N], const char* value) {
    assert(std::strlen(value) < N);
    std::strcpy(target, value);
}
constexpr const char* hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
constexpr const char* other = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
FaceSelectionConfiguration config(int32_t policy = FACE_SELECTION_HIGHEST_NATIVE_UQS) {
    FaceSelectionConfiguration output{};
    output.policy = policy;
    for (auto* item : {&output.policy_identity, &output.quality_artifact, &output.matcher_artifact}) {
        text(item->identifier, "artifact-v1"); text(item->sha256, hash);
    }
    return output;
}
FaceSelectionCandidate candidate(uint32_t index, double native = 20) {
    FaceSelectionCandidate output{};
    text(output.candidate_id, index == 0 ? "frame-zero" : "frame-other");
    output.original_frame_index = index;
    for (auto* item : {&output.source_sha256, &output.quality_source_sha256,
                      &output.matcher_source_sha256, &output.aligned_sha256}) text(*item, hash);
    output.face_count = 1; output.uqs_native = native; output.uqs_mapped = 50;
    output.matcher_status = FACE_SELECTION_MATCHER_PASSED;
    return output;
}
struct Run {
    FaceSelectionResult result{};
    std::array<FaceSelectionExclusion, FACE_SELECTION_MAX_CANDIDATES> exclusions{};
    FaceSelectionStatus apply(FaceSelectionConfiguration configuration, const FaceSelectionCandidate* inputs, size_t count) {
        return face_select_frame(&configuration, inputs, count, exclusions.data(), exclusions.size(), &result);
    }
};
void ordering() {
    auto first = candidate(0, 10); auto later = candidate(9, 80);
    std::array inputs{later, first}; Run run;
    assert(run.apply(config(FACE_SELECTION_FIRST_ELIGIBLE), inputs.data(), 2) == FACE_SELECTION_SUCCESS);
    assert(run.result.selected_input_offset == 1);
    assert(run.apply(config(), inputs.data(), 2) == FACE_SELECTION_SUCCESS);
    assert(run.result.selected_input_offset == 0);
    inputs[1].uqs_native = 80;
    assert(run.apply(config(), inputs.data(), 2) == FACE_SELECTION_SUCCESS);
    assert(run.result.selected_input_offset == 1);
    // Mapped values must not replace native UQS ranking. Identical pixels remain distinct frames.
    inputs[1].uqs_native = 79; inputs[1].uqs_mapped = 100; inputs[0].uqs_mapped = 0;
    assert(run.apply(config(), inputs.data(), 2) == FACE_SELECTION_SUCCESS);
    assert(run.result.selected_input_offset == 0);
    assert(std::strcmp(run.result.selected.source_sha256, hash) == 0);
    assert(std::strcmp(run.result.configuration.matcher_artifact.sha256, hash) == 0);
}
void exclusions() {
    const auto original = candidate(0); Run run;
    auto check = [&](FaceSelectionCandidate input, FaceSelectionExclusion expected) {
        assert(run.apply(config(), &input, 1) == FACE_SELECTION_SUCCESS);
        assert(run.result.has_selection == 0 && run.exclusions[0] == expected);
    };
    auto input = original; input.quality_return_code = 5; check(input, FACE_SELECTION_QUALITY_FAILED);
    input = original; input.face_count = 0; check(input, FACE_SELECTION_FACE_COUNT);
    input.face_count = 2; check(input, FACE_SELECTION_FACE_COUNT);
    input = original; input.uqs_return_code = 3; check(input, FACE_SELECTION_UQS_FAILED);
    for (double invalid : {std::numeric_limits<double>::infinity(), std::numeric_limits<double>::quiet_NaN()}) {
        input = original; input.uqs_native = invalid; check(input, FACE_SELECTION_INVALID_UQS);
        input = original; input.uqs_mapped = invalid; check(input, FACE_SELECTION_INVALID_UQS);
    }
    for (double invalid : {-0.01, 100.01}) {
        input = original; input.uqs_mapped = invalid; check(input, FACE_SELECTION_INVALID_UQS);
    }
    input = original; text(input.quality_source_sha256, other); check(input, FACE_SELECTION_QUALITY_SOURCE_MISMATCH);
    input = original; input.quality_source_sha256[0] = 0; check(input, FACE_SELECTION_QUALITY_SOURCE_MISMATCH);
    input = original; text(input.matcher_source_sha256, other); check(input, FACE_SELECTION_MATCHER_SOURCE_MISMATCH);
    input = original; input.aligned_sha256[0] = 0; check(input, FACE_SELECTION_ALIGNED_UNAVAILABLE);
    for (auto state : {FACE_SELECTION_MATCHER_NOT_ASSESSED, FACE_SELECTION_MATCHER_FAILED}) {
        input = original; input.matcher_status = state; check(input, FACE_SELECTION_MATCHER_NOT_PASSED);
    }
    input = original; input.uqs_native = -1; input.uqs_mapped = 0;
    assert(run.apply(config(), &input, 1) == FACE_SELECTION_SUCCESS && run.result.has_selection == 1);
}
void invalidRequests() {
    Run run; auto input = candidate(0); auto configuration = config();
    configuration.policy = 8;
    assert(run.apply(configuration, &input, 1) == FACE_SELECTION_INVALID_CONFIGURATION);
    configuration = config(); configuration.policy_identity.sha256[0] = 'A';
    assert(run.apply(configuration, &input, 1) == FACE_SELECTION_INVALID_CONFIGURATION);
    configuration = config(); configuration.quality_artifact.identifier[0] = 0;
    assert(run.apply(configuration, &input, 1) == FACE_SELECTION_INVALID_CONFIGURATION);
    for (auto* value : {&input.source_sha256, &input.quality_source_sha256, &input.matcher_source_sha256, &input.aligned_sha256}) {
        (*value)[63] = 0;
        assert(run.apply(config(), &input, 1) == FACE_SELECTION_INVALID_CANDIDATE);
        text(*value, hash);
    }
    input.matcher_status = 99;
    assert(run.apply(config(), &input, 1) == FACE_SELECTION_INVALID_CANDIDATE);
    input = candidate(0); std::memset(input.candidate_id, 'x', sizeof(input.candidate_id));
    assert(run.apply(config(), &input, 1) == FACE_SELECTION_INVALID_CANDIDATE);
    std::array inputs{candidate(0), candidate(9)};
    inputs[1].quality_return_code = 1; text(inputs[1].candidate_id, inputs[0].candidate_id);
    assert(run.apply(config(), inputs.data(), 2) == FACE_SELECTION_DUPLICATE_IDENTIFIER);
    text(inputs[1].candidate_id, "different"); inputs[1].original_frame_index = 0;
    assert(run.apply(config(), inputs.data(), 2) == FACE_SELECTION_DUPLICATE_INDEX);
    assert(run.result.has_selection == 0 && run.exclusions[0] == 0 && run.exclusions[1] == 0);
}
void bounds() {
    Run run; assert(run.apply(config(), nullptr, 0) == FACE_SELECTION_SUCCESS && run.result.has_selection == 0);
    std::array<FaceSelectionCandidate, FACE_SELECTION_MAX_CANDIDATES> inputs{};
    for (size_t i = 0; i < inputs.size(); ++i) {
        inputs[i] = candidate(static_cast<uint32_t>(i));
        // Unique bounded ASCII IDs, no dependency on formatting libraries.
        inputs[i].candidate_id[0] = static_cast<char>('A' + i); inputs[i].candidate_id[1] = 0;
    }
    assert(run.apply(config(), inputs.data(), inputs.size()) == FACE_SELECTION_SUCCESS);
    assert(run.result.selected.original_frame_index == 0);
    assert(run.apply(config(), nullptr, 33) == FACE_SELECTION_TOO_MANY_CANDIDATES);
    auto configuration = config();
    assert(face_select_frame(&configuration, inputs.data(), 1, nullptr, 0, &run.result) == FACE_SELECTION_INVALID_BUFFERS);
    assert(face_select_frame(&configuration, inputs.data(), 1, run.exclusions.data(), 0, &run.result) == FACE_SELECTION_INVALID_BUFFERS);
    assert(face_select_frame(&configuration, nullptr, 0, nullptr, 0, nullptr) == FACE_SELECTION_INVALID_BUFFERS);
}
}
int main() { ordering(); exclusions(); invalidRequests(); bounds(); }
