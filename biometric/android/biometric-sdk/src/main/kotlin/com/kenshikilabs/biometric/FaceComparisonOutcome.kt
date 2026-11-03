package com.kenshikilabs.biometric

/** A model/policy-scoped comparison observation; the host owns identity acceptance. */
enum class FaceComparisonOutcome(val wireValue: String) {
    PASS("pass"),
    MANUAL_REVIEW("manual_review"),
    FAIL("fail"),
    UNAVAILABLE("unavailable"),
}
