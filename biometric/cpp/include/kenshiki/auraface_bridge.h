#ifndef KENSHIKI_AURAFACE_BRIDGE_H
#define KENSHIKI_AURAFACE_BRIDGE_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
// All inputs borrowed for the synchronous call only. No exceptions cross C ABI.
// 0 success, 1 invalid input/alignment, 2 model/runtime failure.
void *face_aura_create(const uint8_t *model, size_t count);
void face_aura_destroy(void *session);
// Exact embedding-route alignment without a model or inference. Output is the
// aligned RGB112 digest; successful geometry does not establish face identity.
int face_aura_preflight(const uint8_t *rgb, size_t count, uint32_t width,
                       uint32_t height, const double *points, char *aligned_sha256);
int face_aura_embed(void *session, const uint8_t *rgb, size_t count,
                       uint32_t width, uint32_t height, const double *points,
                       float *features, char *aligned_sha256);
#ifdef __cplusplus
}
#endif
#endif
