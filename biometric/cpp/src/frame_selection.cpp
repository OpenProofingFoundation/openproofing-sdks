#include "kenshiki/frame_selection.h"
#include <cmath>
#include <cstring>

namespace {
template <size_t N> bool identifier(const char (&value)[N]) {
    for (size_t i = 0; i < N; ++i) {
        const auto byte = static_cast<unsigned char>(value[i]);
        if (byte == 0) return i > 0;
        if (byte < 0x21 || byte > 0x7e) return false;
    }
    return false;
}
bool digest(const char (&value)[FACE_SELECTION_DIGEST_CAPACITY], bool optional = false) {
    if (optional && value[0] == 0) return true;
    for (size_t i = 0; i < 64; ++i) {
        if (!((value[i] >= '0' && value[i] <= '9') || (value[i] >= 'a' && value[i] <= 'f'))) return false;
    }
    return value[64] == 0;
}
bool identity(const FaceSelectionIdentity& value) {
    return identifier(value.identifier) && digest(value.sha256);
}
bool valid(const FaceSelectionCandidate& value) {
    return identifier(value.candidate_id) && digest(value.source_sha256)
        && digest(value.quality_source_sha256, true) && digest(value.matcher_source_sha256, true)
        && digest(value.aligned_sha256, true)
        && value.matcher_status >= FACE_SELECTION_MATCHER_NOT_ASSESSED
        && value.matcher_status <= FACE_SELECTION_MATCHER_FAILED;
}
FaceSelectionExclusion excluded(const FaceSelectionCandidate& value) {
    FaceSelectionExclusion mask = 0;
    if (value.quality_return_code != 0) mask |= FACE_SELECTION_QUALITY_FAILED;
    if (value.face_count != 1) mask |= FACE_SELECTION_FACE_COUNT;
    if (value.uqs_return_code != 0) mask |= FACE_SELECTION_UQS_FAILED;
    if (!std::isfinite(value.uqs_native) || !std::isfinite(value.uqs_mapped)
        || value.uqs_mapped < 0 || value.uqs_mapped > 100) mask |= FACE_SELECTION_INVALID_UQS;
    if (std::strcmp(value.source_sha256, value.quality_source_sha256) != 0)
        mask |= FACE_SELECTION_QUALITY_SOURCE_MISMATCH;
    if (value.matcher_status != FACE_SELECTION_MATCHER_PASSED) mask |= FACE_SELECTION_MATCHER_NOT_PASSED;
    if (std::strcmp(value.source_sha256, value.matcher_source_sha256) != 0)
        mask |= FACE_SELECTION_MATCHER_SOURCE_MISMATCH;
    if (value.aligned_sha256[0] == 0) mask |= FACE_SELECTION_ALIGNED_UNAVAILABLE;
    return mask;
}
bool precedes(const FaceSelectionCandidate& next, const FaceSelectionCandidate& current, int32_t policy) {
    if (policy == FACE_SELECTION_HIGHEST_NATIVE_UQS && next.uqs_native != current.uqs_native)
        return next.uqs_native > current.uqs_native;
    return next.original_frame_index < current.original_frame_index;
}
}

extern "C" FaceSelectionStatus face_select_frame(const FaceSelectionConfiguration* configuration,
    const FaceSelectionCandidate* candidates, size_t count, FaceSelectionExclusion* exclusions,
    size_t exclusion_capacity, FaceSelectionResult* result) {
    if (result != nullptr) *result = {};
    if (exclusions != nullptr) {
        const size_t writable = exclusion_capacity < FACE_SELECTION_MAX_CANDIDATES
            ? exclusion_capacity : FACE_SELECTION_MAX_CANDIDATES;
        for (size_t i = 0; i < writable; ++i) exclusions[i] = 0;
    }
    if (count > FACE_SELECTION_MAX_CANDIDATES) return FACE_SELECTION_TOO_MANY_CANDIDATES;
    if (result == nullptr || (count > 0 && (candidates == nullptr || exclusions == nullptr || exclusion_capacity < count)))
        return FACE_SELECTION_INVALID_BUFFERS;
    if (configuration == nullptr || (configuration->policy != FACE_SELECTION_FIRST_ELIGIBLE
        && configuration->policy != FACE_SELECTION_HIGHEST_NATIVE_UQS)
        || !identity(configuration->policy_identity) || !identity(configuration->quality_artifact)
        || !identity(configuration->matcher_artifact)) return FACE_SELECTION_INVALID_CONFIGURATION;
    for (size_t i = 0; i < count; ++i) {
        if (!valid(candidates[i])) return FACE_SELECTION_INVALID_CANDIDATE;
        for (size_t previous = 0; previous < i; ++previous) {
            if (std::strcmp(candidates[i].candidate_id, candidates[previous].candidate_id) == 0)
                return FACE_SELECTION_DUPLICATE_IDENTIFIER;
            if (candidates[i].original_frame_index == candidates[previous].original_frame_index)
                return FACE_SELECTION_DUPLICATE_INDEX;
        }
    }
    result->configuration = *configuration;
    for (size_t i = 0; i < count; ++i) {
        exclusions[i] = excluded(candidates[i]);
        if (exclusions[i] != 0) continue;
        if (result->has_selection == 0 || precedes(candidates[i], result->selected, configuration->policy)) {
            result->has_selection = 1;
            result->selected_input_offset = i;
            result->selected = candidates[i];
        }
    }
    return FACE_SELECTION_SUCCESS;
}
