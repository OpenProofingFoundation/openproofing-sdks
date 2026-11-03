/**
 * The supplier seam: one adapter per deployment, chosen by configuration and never by the caller
 * (pulse-compliance records/LICENCE-CHECK-PACKAGE-2026-10-20.md). Moved from pulse-worker
 * licenseComparisonAdapter.ts without change of meaning.
 */
import type { CompareRequest, CompareResult, ComparisonProfile } from "./contract.js";

/** Why a dispatched exchange produced no result: a closed vocabulary for the host's log, never
 * supplier text. A supplier is reached by one create and its retrieval. */
export type SupplierFailure = "create_lost" | "create_rejected_credentials" | "create_duplicate_transaction"
  | "create_http_status" | "create_malformed" | "retrieve_lost" | "retrieve_http_status" | "retrieve_malformed"
  | "deadline";

export type ComparisonExecution =
  | {
    kind: "result";
    result: CompareResult;
    /** The supplier's identifier for this comparison, recorded with the operation. */
    supplierReference: string;
    /** The supplier's own completion time, when it gave a valid one. */
    supplierCompletedAtMs: number | null;
    /** The supplier reported a completed, successful comparison: the precondition for binding.
     * True only with a supplierCompletedAtMs, from which the 24-hour pass runs. */
    supplierConfirmed: boolean;
  }
  | { kind: "supplier_response_invalid" | "outcome_unknown"; cause: SupplierFailure; supplierReference: string | null }
  /** The deadline passed before anything was sent: nothing reached the supplier. */
  | { kind: "not_dispatched" };

export interface LicenseComparisonAdapter {
  readonly profile: ComparisonProfile;
  /** One authorized comparison, already admitted. Once anything may have reached the supplier, it is
   * never sent again: every later failure is outcome_unknown or supplier_response_invalid (DLDV-06). */
  execute(request: CompareRequest, deadlineMs: number): Promise<ComparisonExecution>;
}
