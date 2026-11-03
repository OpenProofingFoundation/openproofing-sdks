/**
 * Types of the Pulse DLDV contract (pulse.dldv.v1; pulse-compliance
 * references/aamva/pulse-dldv.openapi.yaml): the CompareRequest a host has already parsed, and the
 * CompareResult an adapter returns. Moved from pulse-worker (licenseRecordComparisonWire.ts and
 * licenseComparisonAdapter.ts) without change of meaning. Parsing stays with the host for now.
 */

export const CHECK_FIELDS = [
  "document_number", "document_type", "family_name", "given_name", "middle_names", "name_suffix", "birth_date",
  "issue_date", "expiration_date", "street_line1", "street_line2", "city", "address_state", "zip5", "zip4",
  "eye_color", "height", "weight", "recorded_sex",
] as const;
export type CheckField = typeof CHECK_FIELDS[number];

export interface Name {
  readonly value: string;
  readonly truncation: "complete" | "truncated" | "unknown";
}
export interface PostalCode {
  readonly zip5: string;
  readonly extension_state: "present" | "absent" | "unknown_padding";
  readonly zip4: string | null;
}
export interface Quantity<U extends string> {
  readonly value: number;
  readonly unit: U;
}
export interface LicenseDocument {
  readonly document_type: "driver_license" | "state_id";
  readonly issuer_iin: string;
  readonly issuing_jurisdiction: string;
  readonly document_number: string;
  readonly family_name: Name;
  readonly given_name: Name;
  readonly middle_names?: Name;
  readonly name_suffix?: string;
  readonly birth_date: string;
  readonly issue_date?: string;
  readonly expiration_date?: string;
  readonly address: {
    readonly street_line1: string;
    readonly street_line2?: string;
    readonly city: string;
    readonly state: string;
    readonly postal_code: PostalCode;
  };
  readonly eye_color?: string;
  readonly height?: Quantity<"in" | "cm">;
  readonly weight?: Quantity<"lb" | "kg">;
  readonly recorded_sex?: "1" | "2" | "9";
}
export interface CompareRequest {
  readonly contract_version: "pulse.dldv.v1";
  readonly operation_id: string;
  readonly profile_version: string;
  readonly expires_at: string;
  readonly evidence: {
    readonly capture_reference: string;
    readonly request_revision: string;
    readonly decoder_version: string;
    readonly parser_version: string;
    readonly normalization_version: string;
    readonly corrected_fields: readonly CheckField[];
    readonly document: LicenseDocument;
    readonly captured_at: string;
  };
}

export type PostalPolicy = "zip5" | "full_available";
type Outcome = "match" | "mismatch" | "not_checked" | "unsupported" | "unavailable" | "indeterminate";
export interface Check {
  submitted: boolean;
  compared: boolean | null;
  outcome: Outcome;
  comparison_scope: "exact_value" | "truncation_aware" | "zip5" | "zip4" | "quantity_with_unit" | "unqualified" | "not_applicable";
  reason_code: "matched" | "mismatched" | "not_present" | "not_requested" | "unsupported_jurisdiction"
    | "unsupported_field" | "supplier_unavailable" | "omitted_result" | "truncated_input"
    | "comparison_scope_unknown" | "invalid_supplier_response";
}
export interface Provider {
  provider_id: string; product: string; api_version: string; adapter_version: string; qualification_revision: string;
}
export interface ComparisonProfile {
  profile_version: string;
  policy_version: string;
  postal_policy: PostalPolicy;
  max_processing_ms: number;
  provider: Provider;
}
export interface CompareResult {
  contract_version: "pulse.dldv.v1";
  operation_id: string;
  profile_version: string;
  capture_reference: string;
  request_revision: string;
  completed_at: string;
  provider: Provider;
  checks: Record<CheckField, Check>;
  evaluation: {
    status: "satisfied" | "not_satisfied" | "incomplete";
    policy_version: string;
    postal_policy: PostalPolicy;
    required_checks: CheckField[];
    unsatisfied_checks: CheckField[];
    incomplete_checks: CheckField[];
  };
}

export type FieldValue = string | Name | PostalCode | Quantity<string>;

/** YYYY-MM-DD that names a real calendar day (JSON Schema `format: date`). */
export function isCalendarDate(value: string): boolean {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value);
  if (!match) return false;
  const [year, month, day] = [Number(match[1]), Number(match[2]), Number(match[3])];
  const date = new Date(0);
  date.setUTCFullYear(year, month - 1, day);
  return date.getUTCFullYear() === year && date.getUTCMonth() === month - 1 && date.getUTCDate() === day;
}

/** RFC 3339 date-time without calendar/time overflow normalization. Leap seconds are not
 * accepted by this execution profile: the host cannot represent them as an epoch millisecond. */
export function isDateTime(value: unknown): value is string {
  if (typeof value !== "string") return false;
  const match = /^(\d{4}-\d{2}-\d{2})T(\d{2}):(\d{2}):(\d{2})(\.\d+)?(Z|([+-])(\d{2}):(\d{2}))$/.exec(value);
  return match !== null && isCalendarDate(match[1]!) && Number(match[2]) <= 23
    && Number(match[3]) <= 59 && Number(match[4]) <= 59
    && (match[6] === "Z" || (Number(match[8]) <= 23 && Number(match[9]) <= 59))
    && Number.isFinite(Date.parse(value));
}

/** Each check field's evidence, undefined when absent: the one place the document's fields are read.
 * Names keep their truncation, and zip4 is the whole postal code (its extension state decides it). */
export function documentFieldValues(document: LicenseDocument): Record<CheckField, FieldValue | undefined> {
  const { address } = document;
  return {
    document_number: document.document_number, document_type: document.document_type,
    family_name: document.family_name, given_name: document.given_name, middle_names: document.middle_names,
    name_suffix: document.name_suffix, birth_date: document.birth_date, issue_date: document.issue_date,
    expiration_date: document.expiration_date, street_line1: address.street_line1, street_line2: address.street_line2,
    city: address.city, address_state: address.state, zip5: address.postal_code.zip5, zip4: address.postal_code,
    eye_color: document.eye_color, height: document.height, weight: document.weight, recorded_sex: document.recorded_sex,
  };
}
