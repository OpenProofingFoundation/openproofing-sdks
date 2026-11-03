/**
 * Trusona behind the licence-check seam (the core's LicenseComparisonAdapter): its profile for the
 * deployment's fixed postal policy, and one bounded execution through http.ts.
 */
import { isDateTime, type LicenseComparisonAdapter, type PostalPolicy } from "@kenshiki-labs/licence-check";
import { trusonaConfirmed, trusonaProfile } from "./dldv.js";
import { executeTrusonaComparison, type TrusonaConnection, type TrusonaRuntime } from "./http.js";

export function trusonaAdapter(connection: TrusonaConnection, postalPolicy: PostalPolicy,
  runtime?: TrusonaRuntime): LicenseComparisonAdapter {
  const profile = trusonaProfile(postalPolicy);
  const adapter: LicenseComparisonAdapter = {
    profile,
    async execute(request, deadlineMs) {
      const execution = await executeTrusonaComparison(connection, request, profile, deadlineMs, runtime);
      if (execution.kind === "not_dispatched") return execution;
      if (execution.kind !== "result")
        return { kind: execution.kind, cause: execution.cause, supplierReference: execution.verificationId };
      const completedAt = isDateTime(execution.retrieved.completedAt) ? Date.parse(execution.retrieved.completedAt) : null;
      return { kind: "result", result: execution.result, supplierReference: execution.verificationId,
        supplierCompletedAtMs: completedAt,
        supplierConfirmed: trusonaConfirmed(execution.retrieved) };
    },
  };
  return Object.freeze(adapter);
}
