#ifndef KENSHIKI_OFIQ_NATIVE_H
#define KENSHIKI_OFIQ_NATIVE_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
#define OFIQ_NATIVE_COMPONENT_COUNT 28
/* Per-component codes retain the exact OFIQ QualityMeasureReturnCode values. */
typedef struct {
    int32_t measure_id;
    int32_t code;
    double native_value;
    double mapped_value;
} OFIQNativeComponent;
typedef struct {
    int32_t return_code;
    int32_t face_count;
    OFIQNativeComponent components[OFIQ_NATIVE_COMPONENT_COUNT];
} OFIQNativeResult;
/* Directory must be an immutable, verified copy of the exact pinned profile.
 * It is borrowed only through initialization. No models are downloaded.
 * failure: 1 invalid argument, 2 allocation limit, 3 runtime/version, 4 OFIQ init. */
void *ofiq_native_create(const char *directory, int32_t *failure);
void ofiq_native_destroy(void *session);
/* Owns a defensive RGB8 copy for this synchronous assessment. Packed rows, physical
 * orientation 1, no colour swap/crop/resize before the exact upstream OFIQ Image.
 * Output storage must not alias input. Return: 0 delivered actual OFIQ result,
 * 1 invalid argument, 2 allocation limit, 3 native failure. No exception crosses C. */
int32_t ofiq_native_assess(void *session, const uint8_t *rgb, size_t count,
    uint32_t width, uint32_t height, OFIQNativeResult *result);
#ifdef __cplusplus
}
#endif
#endif
