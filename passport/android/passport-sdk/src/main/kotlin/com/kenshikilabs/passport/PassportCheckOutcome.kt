package com.kenshikilabs.passport

/** Individual check outcome; the host owns the combined identity decision. */
enum class PassportCheckOutcome(val wireValue: String) {
    PASS("pass"),
    FAIL("fail"),
    INCONCLUSIVE("inconclusive"),
    UNAVAILABLE("unavailable"),
    UNSUPPORTED("unsupported"),
    NOT_PERFORMED("not_performed"),
}
