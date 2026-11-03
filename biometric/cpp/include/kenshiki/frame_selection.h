#ifndef KENSHIKI_FRAME_SELECTION_H
#define KENSHIKI_FRAME_SELECTION_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Resource bound only; this is not a calibrated image-quality policy. */
#define FACE_SELECTION_MAX_CANDIDATES 32
#define FACE_SELECTION_IDENTIFIER_CAPACITY 129
#define FACE_SELECTION_DIGEST_CAPACITY 65

typedef enum {
    FACE_SELECTION_FIRST_ELIGIBLE = 0,
    FACE_SELECTION_HIGHEST_NATIVE_UQS = 1
} FaceSelectionPolicy;
typedef enum {
    FACE_SELECTION_MATCHER_NOT_ASSESSED = 0,
    FACE_SELECTION_MATCHER_PASSED = 1,
    FACE_SELECTION_MATCHER_FAILED = 2
} FaceSelectionMatcherStatus;
typedef enum {
    FACE_SELECTION_SUCCESS = 0,
    FACE_SELECTION_INVALID_CONFIGURATION = 1,
    FACE_SELECTION_INVALID_CANDIDATE = 2,
    FACE_SELECTION_DUPLICATE_IDENTIFIER = 3,
    FACE_SELECTION_DUPLICATE_INDEX = 4,
    FACE_SELECTION_TOO_MANY_CANDIDATES = 5,
    FACE_SELECTION_INVALID_BUFFERS = 6
} FaceSelectionStatus;
typedef uint32_t FaceSelectionExclusion;
#define FACE_SELECTION_QUALITY_FAILED 1U
#define FACE_SELECTION_FACE_COUNT 2U
#define FACE_SELECTION_UQS_FAILED 4U
#define FACE_SELECTION_INVALID_UQS 8U
#define FACE_SELECTION_QUALITY_SOURCE_MISMATCH 16U
#define FACE_SELECTION_MATCHER_NOT_PASSED 32U
#define FACE_SELECTION_MATCHER_SOURCE_MISMATCH 64U
#define FACE_SELECTION_ALIGNED_UNAVAILABLE 128U

typedef struct {
    char identifier[FACE_SELECTION_IDENTIFIER_CAPACITY];
    char sha256[FACE_SELECTION_DIGEST_CAPACITY];
} FaceSelectionIdentity;
typedef struct {
    int32_t policy;
    FaceSelectionIdentity policy_identity;
    FaceSelectionIdentity quality_artifact;
    FaceSelectionIdentity matcher_artifact;
} FaceSelectionConfiguration;
typedef struct {
    char candidate_id[FACE_SELECTION_IDENTIFIER_CAPACITY];
    uint32_t original_frame_index;
    char source_sha256[FACE_SELECTION_DIGEST_CAPACITY];
    /* Empty optional digests exclude the observation; malformed nonempty digests reject the batch. */
    char quality_source_sha256[FACE_SELECTION_DIGEST_CAPACITY];
    char matcher_source_sha256[FACE_SELECTION_DIGEST_CAPACITY];
    char aligned_sha256[FACE_SELECTION_DIGEST_CAPACITY];
    int32_t quality_return_code;
    int32_t face_count;
    int32_t uqs_return_code;
    double uqs_native;
    double uqs_mapped;
    int32_t matcher_status;
} FaceSelectionCandidate;
typedef struct {
    uint8_t has_selection;
    size_t selected_input_offset;
    FaceSelectionCandidate selected;
    /* Host-supplied lineage, validated structurally; not an attestation. */
    FaceSelectionConfiguration configuration;
} FaceSelectionResult;
/* Output result/exclusion buffers must not alias configuration/candidate input storage.
 * Success with has_selection == 0 is an explicit no-selection result. On errors,
 * result and writable exclusion slots are zeroed. No image, identity, cosine,
 * PAD, or acceptance threshold is consumed. Equal scores use earliest frame index.
 * Duplicate pixel hashes are allowed; IDs and original indices must be unique. */
FaceSelectionStatus face_select_frame(const FaceSelectionConfiguration* configuration,
    const FaceSelectionCandidate* candidates, size_t count,
    FaceSelectionExclusion* exclusions, size_t exclusion_capacity,
    FaceSelectionResult* result);
#ifdef __cplusplus
}
#endif
#endif
