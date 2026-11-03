package com.kenshikilabs.biometric

import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicInteger

class ComparisonOperationFenceTest {
    private fun request(operation: String = "00000001-0000-0000-0000-000000000000"): ComparisonRequest {
        val digest = "6e340b9cffb37a989ca544e6bb780a2c78901d3fb33738768511a30617afa01d"
        val pixels = PortraitPixels(1, 1, "gray8", 1, 1, 1, digest, byteArrayOf(0))
        val fields = PortraitBinding.fieldNames.associateWith {
            if (it.endsWith("SHA256")) "a".repeat(64) else "00000000-0000-0000-0000-000000000000"
        }.toMutableMap()
        fields["operationID"] = operation
        fields["referenceSHA256"] = digest
        fields["probeSHA256"] = digest
        return ComparisonRequest(PortraitBinding(fields), pixels, pixels)
    }
    private fun reject(reason: PortraitFailure, operation: () -> Unit) {
        val failure = assertThrows(PortraitException::class.java, operation)
        assertEquals(reason, failure.reason)
    }

    @Test fun unsubmittedDuplicateAndReusedCompletionsCannotPublish() {
        val request = request()
        val fence = ComparisonOperationFence()
        reject(PortraitFailure.OPERATION_UNAVAILABLE) { fence.complete(request.binding) }
        fence.begin(request)
        reject(PortraitFailure.OPERATION_UNAVAILABLE) { fence.begin(request) }
        fence.complete(request.binding)
        reject(PortraitFailure.OPERATION_UNAVAILABLE) { fence.complete(request.binding) }
        reject(PortraitFailure.OPERATION_REUSED) { fence.begin(request) }
    }

    @Test fun everyForeignBindingLeavesOriginalRequestOutstanding() {
        val request = request()
        val fence = ComparisonOperationFence()
        fence.begin(request)
        for (field in PortraitBinding.fieldNames) {
            val changed = request.binding.fields().toMutableMap()
            changed[field] = if (field.endsWith("SHA256")) "f".repeat(64) else "ffffffff-0000-0000-0000-000000000000"
            reject(PortraitFailure.BINDING_MISMATCH) { fence.complete(PortraitBinding(changed)) }
        }
        assertEquals(request, fence.complete(request.binding))
    }

    @Test fun reentrantCancellationCannotResurrectCancelledOperation() {
        val first = request()
        val replacement = request("00000002-0000-0000-0000-000000000000")
        val fence = ComparisonOperationFence()
        fence.begin(first)
        var cancellationRan = false
        fence.cancel(first.binding.fields().getValue("operationID")) {
            cancellationRan = true
            reject(PortraitFailure.OPERATION_UNAVAILABLE) { fence.complete(first.binding) }
            reject(PortraitFailure.OPERATION_REUSED) { fence.begin(first) }
            fence.begin(replacement)
            reject(PortraitFailure.BINDING_MISMATCH) { fence.complete(first.binding) }
        }
        assertTrue(cancellationRan)
        assertEquals(replacement, fence.complete(replacement.binding))
    }

    @Test fun foreignCancellationDoesNotInvalidateLiveRequest() {
        val request = request()
        val fence = ComparisonOperationFence()
        fence.begin(request)
        var cancellationRan = false
        reject(PortraitFailure.OPERATION_UNAVAILABLE) {
            fence.cancel("ffffffff-0000-0000-0000-000000000000") { cancellationRan = true }
        }
        assertFalse(cancellationRan)
        assertEquals(request, fence.complete(request.binding))
    }

    @Test fun concurrentDuplicateCompletionHasExactlyOneWinner() {
        val request = request()
        val fence = ComparisonOperationFence()
        fence.begin(request)
        val accepted = AtomicInteger(0)
        val rejected = AtomicInteger(0)
        val unexpected = AtomicInteger(0)
        val start = CountDownLatch(1)
        val workers = List(16) {
            Thread {
                start.await()
                try {
                    fence.complete(request.binding)
                    accepted.incrementAndGet()
                } catch (failure: PortraitException) {
                    if (failure.reason == PortraitFailure.OPERATION_UNAVAILABLE) rejected.incrementAndGet()
                    else unexpected.incrementAndGet()
                }
            }.apply { start() }
        }
        start.countDown()
        workers.forEach { it.join(5000); assertFalse(it.isAlive) }
        assertEquals(1, accepted.get())
        assertEquals(15, rejected.get())
        assertEquals(0, unexpected.get())
    }
    @Test fun throwingCancellationCannotRestoreOutstandingRequest() {
        val first = request()
        val next = request("00000002-0000-0000-0000-000000000000")
        val fence = ComparisonOperationFence()
        fence.begin(first)
        assertThrows(IllegalStateException::class.java) {
            fence.cancel(first.binding.fields().getValue("operationID")) { throw IllegalStateException() }
        }
        reject(PortraitFailure.OPERATION_UNAVAILABLE) { fence.complete(first.binding) }
        reject(PortraitFailure.OPERATION_REUSED) { fence.begin(first) }
        fence.begin(next)
        fence.complete(next.binding)
    }
}
