/** Bounded, memory-only Trusona create-once/retrieve execution. No automatic create retry. */
import { isDateTime, type CompareRequest, type CompareResult, type SupplierFailure } from "@kenshiki-labs/licence-check";
import { encodeTrusonaRequest, translateTrusonaResult, type TrusonaProfile } from "./dldv.js";

export const TRUSONA_BASE_URL = "https://authcloud.trusona.net";
const CREATE_PATH = "/api/v1/id_verifications";
const MAX_RESPONSE_BYTES = 65_536;
const POLL_INTERVAL_MS = 1_000;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const issuedConnections = new WeakSet<object>();
declare const connectionBrand: unique symbol;

/** Opaque connection issued only by trusonaConnection; copied/forged objects are not executable. */
export interface TrusonaConnection {
  readonly key: string;
  readonly baseURL: string;
  readonly [connectionBrand]: true;
}
export interface TrusonaHostStage {
  readonly deploymentEnvironment?: string | undefined;
  readonly localTestBaseURL?: string | undefined;
}

export function trusonaConnection(key: string, stage: TrusonaHostStage): TrusonaConnection | null {
  if (!key || key.trim() !== key || /[\r\n]/.test(key)) return null;
  let baseURL = TRUSONA_BASE_URL;
  if (stage.deploymentEnvironment === "local" && stage.localTestBaseURL !== undefined) {
    baseURL = stage.localTestBaseURL;
    if (key !== "pulse-licence-e2e-local-only" || baseURL !== baseURL.trim()
      || !/^http:\/\/127\.0\.0\.1:[1-9]\d{0,4}$/.test(baseURL)
      || Number(baseURL.slice(baseURL.lastIndexOf(":") + 1)) > 65_535) return null;
  }
  const connection = Object.freeze({ key, baseURL }) as TrusonaConnection;
  issuedConnections.add(connection);
  return connection;
}

/** Trusted host ports, injectable for offline tests. fetch must honor AbortSignal; now is epoch ms.
 * These ports confer no authority or supplier qualification. Never populate them from caller JSON. */
export interface TrusonaRuntime {
  readonly fetch: typeof fetch;
  readonly now: () => number;
  readonly sleep: (milliseconds: number) => Promise<void>;
}
const runtimeDefaults: TrusonaRuntime = {
  fetch: (...args) => fetch(...args), now: () => Date.now(),
  sleep: (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds)),
};
type Reply = { kind: "response"; status: number; body: unknown } | { kind: "not_dispatched" } | null;

async function boundedText(response: Response): Promise<string | null> {
  if (!response.body) return "";
  const reader = response.body.getReader();
  const decoder = new TextDecoder("utf-8", { fatal: true });
  let received = 0;
  let text = "";
  for (;;) {
    const chunk = await reader.read();
    if (chunk.done) return text + decoder.decode();
    received += chunk.value.byteLength;
    if (received > MAX_RESPONSE_BYTES) { await reader.cancel(); return null; }
    text += decoder.decode(chunk.value, { stream: true });
  }
}

async function send(connection: TrusonaConnection, method: "POST" | "GET", path: string,
  body: unknown, deadlineMs: number, runtime: TrusonaRuntime): Promise<Reply> {
  const remaining = Math.ceil(deadlineMs - runtime.now());
  if (remaining <= 0) return { kind: "not_dispatched" };
  const controller = new AbortController();
  let timer: ReturnType<typeof setTimeout> | undefined;
  const expired = new Promise<null>((resolve) => {
    timer = setTimeout(() => { controller.abort(); resolve(null); }, remaining);
  });
  const exchange = async (): Promise<Reply> => {
    let dispatched = false;
    try {
      const headers: Record<string, string> = {
        authorization: `Bearer ${connection.key}`, accept: "application/json", "cache-control": "no-store",
      };
      if (body !== undefined) headers["content-type"] = "application/json";
      const init: RequestInit = {
        method, headers, body: body === undefined ? null : JSON.stringify(body),
        redirect: "manual", signal: controller.signal,
      };
      if (runtime.now() >= deadlineMs) return { kind: "not_dispatched" };
      dispatched = true;
      const response = await runtime.fetch(`${connection.baseURL}${path}`, init);
      const text = await boundedText(response);
      if (runtime.now() >= deadlineMs) return null;
      if (text === null) return { kind: "response", status: response.status, body: undefined };
      try { return { kind: "response", status: response.status, body: text ? JSON.parse(text) as unknown : undefined }; }
      catch { return { kind: "response", status: response.status, body: undefined }; }
    } catch { return dispatched ? null : { kind: "not_dispatched" }; } // Never surface supplier text or credentials.
  };
  try { return await Promise.race([exchange(), expired]); }
  finally { clearTimeout(timer); }
}

type TrusonaExecution =
  | { kind: "result"; result: CompareResult; retrieved: Record<string, unknown>; verificationId: string }
  | { kind: "supplier_response_invalid" | "outcome_unknown"; cause: SupplierFailure; verificationId: string | null }
  | { kind: "not_dispatched" };

function createFailure(status: number): SupplierFailure {
  if (status === 401 || status === 403) return "create_rejected_credentials";
  if (status === 422) return "create_duplicate_transaction";
  return status === 201 ? "create_malformed" : "create_http_status";
}
function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** Already-admitted request only. The host owns authority, operation claim, coverage and replay.
 * Snapshot before any await; dispatch and translation must refer to the same admitted bytes/policy. */
export async function executeTrusonaComparison(connection: TrusonaConnection, request: CompareRequest,
  profile: TrusonaProfile, deadlineMs: number, runtime: TrusonaRuntime = runtimeDefaults): Promise<TrusonaExecution> {
  const started = runtime.now();
  if (!issuedConnections.has(connection) || !Number.isSafeInteger(deadlineMs)
    || !Number.isSafeInteger(started) || !isDateTime(request.expires_at)
    || !Number.isSafeInteger(profile.max_processing_ms) || profile.max_processing_ms <= 0
    || profile.max_processing_ms > 30_000 || request.profile_version !== profile.profile_version)
    return { kind: "not_dispatched" };
  request = structuredClone(request);
  profile = structuredClone(profile);
  deadlineMs = Math.min(deadlineMs, Date.parse(request.expires_at), started + profile.max_processing_ms);
  if (deadlineMs <= started) return { kind: "not_dispatched" };
  const encoded = encodeTrusonaRequest(request);
  const created = await send(connection, "POST", CREATE_PATH, encoded.body, deadlineMs, runtime);
  if (created === null) return { kind: "outcome_unknown", cause: "create_lost", verificationId: null };
  if (created.kind === "not_dispatched") return created;
  const id = isRecord(created.body) ? created.body.id : undefined;
  if (created.status !== 201 || typeof id !== "string" || !UUID.test(id))
    return { kind: "supplier_response_invalid", cause: createFailure(created.status), verificationId: null };
  for (;;) {
    if (runtime.now() >= deadlineMs) return { kind: "outcome_unknown", cause: "deadline", verificationId: id };
    const read = await send(connection, "GET", `${CREATE_PATH}/${id}`, undefined, deadlineMs, runtime);
    if (read === null) return { kind: "outcome_unknown", cause: "retrieve_lost", verificationId: id };
    if (read.kind === "not_dispatched") return { kind: "outcome_unknown", cause: "deadline", verificationId: id };
    if (read.status !== 200 || !isRecord(read.body) || read.body.id !== id)
      return { kind: "supplier_response_invalid", cause: read.status === 200 ? "retrieve_malformed" : "retrieve_http_status",
        verificationId: id };
    const status = read.body.dmvStatus;
    if (status !== null && status !== undefined && status !== "PENDING") {
      if (runtime.now() >= deadlineMs) return { kind: "outcome_unknown", cause: "deadline", verificationId: id };
      return { kind: "result", verificationId: id, retrieved: read.body,
        result: translateTrusonaResult(request, profile, encoded, read.body, new Date(runtime.now()).toISOString()) };
    }
    if (runtime.now() + POLL_INTERVAL_MS >= deadlineMs)
      return { kind: "outcome_unknown", cause: "deadline", verificationId: id };
    try { await runtime.sleep(POLL_INTERVAL_MS); }
    catch { return { kind: "outcome_unknown", cause: "deadline", verificationId: id }; }
  }
}
