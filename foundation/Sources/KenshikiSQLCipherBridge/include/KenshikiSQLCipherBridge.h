#ifndef KENSHIKI_SQLCIPHER_BRIDGE_H
#define KENSHIKI_SQLCIPHER_BRIDGE_H
#include <stddef.h>
/* A separate C boundary exposes only the codec entry point hidden behind SQLITE_HAS_CODEC. */
int kenshiki_sqlcipher_key(void *database, const void *key, int length);
int kenshiki_sqlcipher_preserve_wal_on_close(void *database);
#endif
