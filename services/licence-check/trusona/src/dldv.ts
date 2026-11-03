/**
 * Trusona adapter for the Pulse DLDV contract (`x-supplier-adapters.trusona`, adapter version
 * trusona-id-verification-v1-draft-1). Pure: request encoding, result translation and the DLDV-05
 * evaluation. The reference implementation it ports is pulse-compliance tools/dldv_trusona_adapter.py.
 *
 * The adapter is unqualified. Every observed Trusona boolean is kept as match/mismatch with
 * comparison_scope "unqualified", so the evaluation is "incomplete" until qualification closes;
 * Trusona's overall dmvStatus never becomes a Pulse verdict.
 */
import { bindsDocumentSubject, CHECK_FIELDS, documentFieldValues, isDateTime, requiredChecks, type Check, type CheckField,
  type ComparisonProfile, type CompareRequest, type CompareResult, type FieldValue, type LicenseDocument,
  type PostalPolicy } from "@kenshiki-labs/licence-check";

export type TrusonaProfile = ComparisonProfile;

const TRUSONA_ADAPTER_VERSION = "trusona-id-verification-v1-draft-1";
const EYE_COLORS = new Set(["BLK", "BLU", "BRO", "DIC", "GRY", "GRN", "HAZ", "MAR", "PNK"]);
/** Pulse check field -> [request location, documented dmvMatches key or null]. */
const MAPPING: Record<CheckField, readonly [request: string, result: string | null]> = {
  document_number: ["dmv.documentNumber", "documentNumber"], document_type: ["dmv.documentCategory", "documentType"],
  family_name: ["lastName", "lastName"], given_name: ["firstName", "firstName"],
  middle_names: ["middleName", "middleName"], name_suffix: ["suffix", null], birth_date: ["dateOfBirth", "dateOfBirth"],
  issue_date: ["dmv.issueDate", "issueDate"], expiration_date: ["dmv.expiryDate", "expiryDate"],
  street_line1: ["address1", "address1"], street_line2: ["address2", "address2"], city: ["city", "city"],
  address_state: ["state", "state"], zip5: ["zipCode", "zipCode"], zip4: ["zip4", "zip4"],
  eye_color: ["dmv.eyeColor", "eyeColor"], height: ["dmv.height", "height"], weight: ["dmv.weight", "weight"],
  recorded_sex: ["dmv.sex", "sex"],
};

export function trusonaProfile(postalPolicy: PostalPolicy): TrusonaProfile {
  if (postalPolicy !== "zip5" && postalPolicy !== "full_available") throw new TypeError("Invalid postal policy");
  return Object.freeze({
    profile_version: "trusona-dldv-2", policy_version: "pulse-dldv-03-05-street-observation-1", postal_policy: postalPolicy,
    max_processing_ms: 30_000,
    provider: Object.freeze({ provider_id: "trusona", product: "Driver License Verification API", api_version: "1.0.0",
      adapter_version: TRUSONA_ADAPTER_VERSION, qualification_revision: "unqualified" }),
  });
}

/** Each check field the evidence carries, as the value the adapter encodes: the submitted string
 * exactly, a holder's correction included (the route admitted it only as the front's printed
 * reading exactly; licenseDocumentAssociation.ts), and a name's value without its truncation flag. */
function presentValues(document: LicenseDocument): Partial<Record<CheckField, unknown>> {
  const present: Partial<Record<CheckField, unknown>> = {};
  for (const [field, value] of Object.entries(documentFieldValues(document)) as [CheckField, FieldValue | undefined][]) {
    if (value === undefined) continue;
    if (field === "family_name" || field === "given_name" || field === "middle_names") present[field] = (value as { value: string }).value;
    else if (field === "zip4") {
      const zip4 = (value as { zip4: string | null }).zip4;
      if (zip4 !== null) present[field] = zip4;
    } else present[field] = value;
  }
  return present;
}

/** The supplier encoding of one field, or null when the documented format cannot represent it exactly. */
function encodeValue(field: CheckField, value: unknown): string | null {
  switch (field) {
    case "document_type": return value === "driver_license" ? "DL" : "ID";
    case "recorded_sex": return value === "1" ? "M" : value === "2" ? "F" : null;
    case "eye_color": return EYE_COLORS.has(value as string) ? value as string : null;
    case "height": {
      const { value: amount, unit } = value as { value: number; unit: string };
      if (unit !== "in" || !Number.isInteger(amount)) return null;
      const feet = Math.floor(amount / 12);
      return feet >= 1 && feet <= 9 ? `${feet}${String(amount % 12).padStart(2, "0")}` : null;
    }
    case "weight": {
      const { value: amount, unit } = value as { value: number; unit: string };
      return unit === "lb" && Number.isInteger(amount) && amount >= 100 && amount <= 999 ? String(amount) : null;
    }
    default: return value as string;
  }
}

interface EncodedRequest {
  body: { transactionId: string; verifiers: { dmv: Record<string, string> }; [field: string]: unknown };
  submitted: ReadonlySet<CheckField>;
  unsupported: ReadonlySet<CheckField>;
}

/** CompareRequest -> Trusona IdVerificationRequest. DMV verifier only: no mno, phoneNumber or callbackUrl. */
export function encodeTrusonaRequest(request: CompareRequest): EncodedRequest {
  const document = request.evidence.document;
  const dmv: Record<string, string> = { documentCountry: "US", documentJurisdiction: document.issuing_jurisdiction };
  const body: EncodedRequest["body"] = { transactionId: request.operation_id, verifiers: { dmv } };
  const submitted = new Set<CheckField>();
  const unsupported = new Set<CheckField>();
  for (const [field, value] of Object.entries(presentValues(document)) as [CheckField, unknown][]) {
    const encoded = encodeValue(field, value);
    if (encoded === null) { unsupported.add(field); continue; }
    const target = MAPPING[field][0];
    if (target.startsWith("dmv.")) dmv[target.slice(4)] = encoded;
    else body[target] = encoded;
    submitted.add(field);
  }
  return { body, submitted, unsupported };
}

const check = (outcome: Check["outcome"], reason: Check["reason_code"], scope: Check["comparison_scope"],
  submitted: boolean, compared: boolean | null): Check =>
  ({ submitted, compared, outcome, comparison_scope: scope, reason_code: reason });

function fieldCheck(field: CheckField, encoded: EncodedRequest, retrieved: Record<string, unknown>): Check {
  if (encoded.unsupported.has(field)) return check("unsupported", "unsupported_field", "not_applicable", false, false);
  if (!encoded.submitted.has(field)) return check("not_checked", "not_present", "not_applicable", false, false);
  const status = retrieved.dmvStatus;
  if (status === "FAILURE" || status === "FATAL")
    return check("indeterminate", "comparison_scope_unknown", "unqualified", true, null);
  const matches = retrieved.dmvMatches;
  if (status !== "SUCCESS" || !isDateTime(retrieved.completedAt) || typeof matches !== "object" || matches === null
    || Array.isArray(matches)) return check("indeterminate", "invalid_supplier_response", "unqualified", true, null);
  const key = MAPPING[field][1];
  if (key === null || !Object.hasOwn(matches, key)) return check("indeterminate", "omitted_result", "unqualified", true, null);
  const observed = (matches as Record<string, unknown>)[key];
  if (typeof observed !== "boolean") return check("indeterminate", "invalid_supplier_response", "unqualified", true, null);
  // Observed, but unqualified until jurisdiction and comparison semantics are qualified.
  return observed ? check("match", "matched", "unqualified", true, true)
    : check("mismatch", "mismatched", "unqualified", true, true);
}

/** IdVerificationResponse -> CompareResult. The evaluation follows DLDV-05, never dmvStatus. */
export function translateTrusonaResult(request: CompareRequest, profile: TrusonaProfile, encoded: EncodedRequest,
  retrieved: Record<string, unknown>, completedAt: string): CompareResult {
  const document = request.evidence.document;
  const checks = Object.fromEntries(CHECK_FIELDS.map((field) => [field, fieldCheck(field, encoded, retrieved)])) as
    Record<CheckField, Check>;
  const required = requiredChecks(document, profile.postal_policy);
  const failed: CheckField[] = [];
  const incomplete: CheckField[] = [];
  for (const field of required) {
    const { outcome, comparison_scope: scope } = checks[field];
    const name = field === "family_name" || field === "given_name" ? document[field] : null;
    const truncated = name !== null && name.truncation !== "complete";
    if (scope === "unqualified" || truncated || (outcome !== "match" && outcome !== "mismatch")) incomplete.push(field);
    else if (outcome === "mismatch") failed.push(field);
  }
  return {
    contract_version: "pulse.dldv.v1", operation_id: request.operation_id, profile_version: request.profile_version,
    capture_reference: request.evidence.capture_reference, request_revision: request.evidence.request_revision,
    completed_at: completedAt, provider: { ...profile.provider }, checks,
    evaluation: { status: incomplete.length > 0 ? "incomplete" : failed.length > 0 ? "not_satisfied" : "satisfied",
      policy_version: profile.policy_version, postal_policy: profile.postal_policy, required_checks: required,
      unsatisfied_checks: failed, incomplete_checks: incomplete },
  };
}

/** Trusona reported a completed, successful comparison: dmvStatus SUCCESS with a valid completedAt. */
export function trusonaConfirmed(retrieved: Record<string, unknown>): boolean {
  return retrieved.dmvStatus === "SUCCESS" && isDateTime(retrieved.completedAt);
}

/** Whether this Trusona comparison binds the document subject for the phone and SSN steps: Trusona
 * confirmed it, and the result meets the core binding policy (bindsDocumentSubject) for the
 * Trusona profile. The profile, policy and provider it is held to do not vary with postal policy. */
export function bindsSubject(result: CompareResult, retrieved: Record<string, unknown>, request: CompareRequest,
  profile: TrusonaProfile): boolean {
  return trusonaConfirmed(retrieved) && bindsDocumentSubject(result, request, profile);
}
