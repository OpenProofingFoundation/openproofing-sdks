/**
 * DLDV-03's required checks and the subject-binding policy (owner decision 2026-10-17), moved from
 * pulse-worker licenseComparisonAdapter.ts without change of meaning.
 */
import type { CheckField, ComparisonProfile, CompareRequest, CompareResult, LicenseDocument, PostalPolicy,
  Provider } from "./contract.js";

/** DLDV-03: always required. A second address line when present, and ZIP+4 by policy, are added. */
const CORE: readonly CheckField[] = ["document_number", "family_name", "given_name", "birth_date", "street_line1",
  "city", "address_state", "zip5"];

export function requiredChecks(document: LicenseDocument, postalPolicy: PostalPolicy): CheckField[] {
  const required = [...CORE];
  if (document.address.street_line2 !== undefined) required.push("street_line2");
  if (postalPolicy === "full_available" && document.address.postal_code.extension_state === "present") required.push("zip4");
  return required;
}

/**
 * Whether a result binds the document subject for the phone and SSN steps, for a supplier that
 * reported a completed, successful comparison: the result must carry this profile and provider, and
 * its required checks must be exactly DLDV-03's for the submitted document. Every required comparison
 * must be present, valid and an observed match, except that a valid observed first-street-line
 * mismatch is permitted. Binding is of the declared subject, not a verified-address claim.
 */
export function bindsDocumentSubject(result: CompareResult, request: CompareRequest,
  expected: Pick<ComparisonProfile, "profile_version" | "policy_version" | "provider" | "postal_policy">): boolean {
  const { evaluation } = result;
  const postalPolicy = evaluation.postal_policy;
  if (result.profile_version !== expected.profile_version || request.profile_version !== result.profile_version
    || result.contract_version !== request.contract_version || result.operation_id !== request.operation_id
    || result.capture_reference !== request.evidence.capture_reference
    || result.request_revision !== request.evidence.request_revision || postalPolicy !== expected.postal_policy
    || evaluation.policy_version !== expected.policy_version
    || (postalPolicy !== "zip5" && postalPolicy !== "full_available")) return false;
  if ((Object.keys(expected.provider) as (keyof Provider)[]).some((key) => result.provider[key] !== expected.provider[key]))
    return false;
  const required = new Set(requiredChecks(request.evidence.document, postalPolicy));
  if (evaluation.required_checks.length !== required.size
    || new Set(evaluation.required_checks).size !== required.size
    || evaluation.required_checks.some((field) => !required.has(field))) return false;
  return evaluation.required_checks.every((field) => {
    const check = result.checks[field];
    if (check?.submitted !== true || check.compared !== true || check.comparison_scope !== "unqualified") return false;
    return (check.outcome === "match" && check.reason_code === "matched")
      || (field === "street_line1" && check.outcome === "mismatch" && check.reason_code === "mismatched");
  });
}
