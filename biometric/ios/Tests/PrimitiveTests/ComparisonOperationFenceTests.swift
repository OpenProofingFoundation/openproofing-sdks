import Foundation
import XCTest
@testable import BiometricSDK

final class ComparisonOperationFenceTests: XCTestCase {
    private func request(operation: String = "00000001-0000-0000-0000-000000000000") throws -> ComparisonRequest {
        let digest = "6e340b9cffb37a989ca544e6bb780a2c78901d3fb33738768511a30617afa01d"
        let pixels = try PortraitPixels(layout: .init(width: 1, height: 1, format: "gray8", rowStrideBytes: 1,
                                                      byteLength: 1, orientation: 1), sha256: digest, bytes: [0])
        var fields = Dictionary(uniqueKeysWithValues: PortraitBinding.fieldNames.map { name in
            (name, name.hasSuffix("SHA256") ? String(repeating: "a", count: 64) : "00000000-0000-0000-0000-000000000000")
        })
        fields["operationID"] = operation
        fields["referenceSHA256"] = digest
        fields["probeSHA256"] = digest
        return try ComparisonRequest(binding: PortraitBinding(fields: fields), reference: pixels, probe: pixels)
    }

    func testUnsubmittedDuplicateAndReusedCompletionsCannotPublish() async throws {
        let request = try request()
        try await MainActor.run {
            let fence = ComparisonOperationFence()
            XCTAssertThrowsError(try fence.complete(binding: request.binding)) {
                XCTAssertEqual($0 as? PortraitFailure, .operationUnavailable)
            }
            try fence.begin(request)
            XCTAssertThrowsError(try fence.begin(request)) {
                XCTAssertEqual($0 as? PortraitFailure, .operationUnavailable)
            }
            _ = try fence.complete(binding: request.binding)
            XCTAssertThrowsError(try fence.complete(binding: request.binding)) {
                XCTAssertEqual($0 as? PortraitFailure, .operationUnavailable)
            }
            XCTAssertThrowsError(try fence.begin(request)) {
                XCTAssertEqual($0 as? PortraitFailure, .operationReused)
            }
        }
    }

    func testEveryForeignBindingLeavesOriginalRequestOutstanding() async throws {
        let request = try request()
        try await MainActor.run {
            let fence = ComparisonOperationFence()
            try fence.begin(request)
            for field in PortraitBinding.fieldNames {
                var changed = request.binding.fields
                changed[field] = field.hasSuffix("SHA256") ? String(repeating: "f", count: 64) : "ffffffff-0000-0000-0000-000000000000"
                let foreign = try PortraitBinding(fields: changed)
                XCTAssertThrowsError(try fence.complete(binding: foreign), field) {
                    XCTAssertEqual($0 as? PortraitFailure, .bindingMismatch)
                }
            }
            let consumed = try fence.complete(binding: request.binding)
            XCTAssertEqual(consumed.binding, request.binding)
        }
    }

    func testReentrantCancellationCannotResurrectCancelledOperation() async throws {
        let first = try request()
        let replacement = try request(operation: "00000002-0000-0000-0000-000000000000")
        try await MainActor.run {
            let fence = ComparisonOperationFence()
            try fence.begin(first)
            var cancellationRan = false
            try fence.cancel(operationID: first.binding.fields["operationID"]!) {
                cancellationRan = true
                Self.assertReentrantReplacement(fence, cancelled: first, replacement: replacement)
            }
            XCTAssertTrue(cancellationRan)
            _ = try fence.complete(binding: replacement.binding)
        }
    }

    private static func assertReentrantReplacement(
        _ fence: ComparisonOperationFence,
        cancelled first: ComparisonRequest,
        replacement: ComparisonRequest
    ) {
        XCTAssertThrowsError(try fence.complete(binding: first.binding)) {
            XCTAssertEqual($0 as? PortraitFailure, .operationUnavailable)
        }
        XCTAssertThrowsError(try fence.begin(first)) {
            XCTAssertEqual($0 as? PortraitFailure, .operationReused)
        }
        XCTAssertNoThrow(try fence.begin(replacement))
        XCTAssertThrowsError(try fence.complete(binding: first.binding)) {
            XCTAssertEqual($0 as? PortraitFailure, .bindingMismatch)
        }
    }

    func testForeignCancellationDoesNotInvalidateLiveRequest() async throws {
        let request = try request()
        try await MainActor.run {
            let fence = ComparisonOperationFence()
            try fence.begin(request)
            var cancellationRan = false
            XCTAssertThrowsError(try fence.cancel(operationID: "ffffffff-0000-0000-0000-000000000000") {
                cancellationRan = true
            }) {
                XCTAssertEqual($0 as? PortraitFailure, .operationUnavailable)
            }
            XCTAssertFalse(cancellationRan)
            _ = try fence.complete(binding: request.binding)
        }
    }

    func testConcurrentDuplicateCompletionHasExactlyOneWinner() async throws {
        let request = try request()
        let fence = ComparisonOperationFence()
        try fence.begin(request)
        let counts = await withTaskGroup(of: (Int, Int, Int).self) { group in
            for _ in 0..<16 {
                group.addTask {
                    do {
                        _ = try fence.complete(binding: request.binding)
                        return (1, 0, 0)
                    } catch PortraitFailure.operationUnavailable {
                        return (0, 1, 0)
                    } catch {
                        return (0, 0, 1)
                    }
                }
            }
            var result = (0, 0, 0)
            for await count in group {
                result = (result.0 + count.0, result.1 + count.1, result.2 + count.2)
            }
            return result
        }
        XCTAssertEqual(counts.0, 1)
        XCTAssertEqual(counts.1, 15)
        XCTAssertEqual(counts.2, 0)
    }
    func testThrowingCancellationCannotRestoreOutstandingRequest() throws {
        enum CancellationFailure: Error { case interrupted }
        let first = try request()
        let next = try request(operation: "00000002-0000-0000-0000-000000000000")
        let fence = ComparisonOperationFence()
        try fence.begin(first)
        XCTAssertThrowsError(try fence.cancel(operationID: first.binding.fields["operationID"]!) {
            throw CancellationFailure.interrupted
        }) { XCTAssertTrue($0 is CancellationFailure) }
        XCTAssertThrowsError(try fence.complete(binding: first.binding)) {
            XCTAssertEqual($0 as? PortraitFailure, .operationUnavailable)
        }
        XCTAssertThrowsError(try fence.begin(first)) {
            XCTAssertEqual($0 as? PortraitFailure, .operationReused)
        }
        try fence.begin(next)
        _ = try fence.complete(binding: next.binding)
    }
}
