import Foundation
@testable import KenshikiReference

/// Synthetic historical metadata for archive regressions. No prompts, tokenizer or inference.
actor ArchiveDescriptorFixture {
    init(modelDirectory: URL, contractDirectory: URL) {}

    func describe(pass: LiquidEvidencePass, request: LiquidPassRequest) throws -> LiquidPassDescriptor {
        let evidence = try LiquidPassContract.evidence(pass: pass, request: request)
        return LiquidPassDescriptor(task: pass, profileID: LiquidPassProfile.id,
            artifactSHA256: LiquidProfile.weightsSHA256, promptContractSHA256: LiquidPassProfile.sha256,
            contextSHA256: LiquidPromptContract.digest(evidence.context),
            promptSHA256: String(repeating: "a", count: 64), schemaSHA256: String(repeating: "b", count: 64),
            contextJSON: evidence.context, modelInputJSON: evidence.modelInput,
            modelInputSHA256: LiquidPromptContract.digest(evidence.modelInput))
    }
}
