#define SQLITE_HAS_CODEC 1
#include <SQLCipher/sqlite3.h>
#include "KenshikiSQLCipherBridge.h"
int kenshiki_sqlcipher_key(void *database, const void *key, int length) {
    return sqlite3_key((sqlite3 *)database, key, length);
}

int kenshiki_sqlcipher_preserve_wal_on_close(void *database) {
    return sqlite3_db_config((sqlite3 *)database, SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE, 1, NULL);
}
