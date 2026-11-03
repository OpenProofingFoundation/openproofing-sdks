package com.kenshikilabs.document

/** Individual check outcome; the host owns the combined identity decision. */
enum class DocumentCheckOutcome(val wireValue: String) {
    PASS("pass"),
    FAIL("fail"),
    INCONCLUSIVE("inconclusive"),
    UNAVAILABLE("unavailable"),
    UNSUPPORTED("unsupported"),
    NOT_PERFORMED("not_performed"),
}
