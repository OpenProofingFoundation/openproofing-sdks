# @kenshiki-labs/licence-check-trusona

Optional ESM adapter for Trusona's pinned Driver License Verification API 1.0.0.
Its only runtime package dependency is `@kenshiki-labs/licence-check` at the exact
matching version. Install both prepared tarballs into an application; build/source
checkout paths are not runtime dependencies.

```js
import { trusonaAdapter, trusonaConnection } from '@kenshiki-labs/licence-check-trusona';
const connection = trusonaConnection(secretFromHost, {});
if (!connection) throw new Error('Invalid supplier configuration');
const adapter = trusonaAdapter(connection, 'full_available');
const execution = await adapter.execute(admittedRequest, originalDeadlineEpochMs);
```

The host supplies credentials and selects the postal policy. Only the factory can
issue an executable, immutable connection. Production origin is fixed to
`https://authcloud.trusona.net`; redirects are never followed. Only explicitly local
stage plus credential `pulse-licence-e2e-local-only` allows a literal
`http://127.0.0.1:PORT` synthetic stub. A copied/forged connection cannot execute.
Keep credentials out of caller data and logs.

Execution snapshots the request/profile before awaiting, creates exactly once,
and polls the created ID at one-second intervals. The effective deadline is the
minimum of the supplied original operation deadline, authorization expiry and the
30-second profile limit from this call. The host must calculate the original
limit; calling execute again restarts a *new invocation* and is not a retry/replay
control. Unknown outcomes must never be automatically resubmitted.

Request failures before dispatch return `not_dispatched`. Once create may have
been sent, failures return `outcome_unknown` or `supplier_response_invalid` with
closed causes and optional supplier reference; error bodies/exception text are
not returned. Bodies are UTF-8 validated and bounded to 65,536 bytes. Stalled
fetch/body reads are deadline bounded and aborted; a terminal reply at/after the
deadline is not accepted. There is no background job or personal persistence.

An optional trusted `TrusonaRuntime` provides fetch, epoch-millisecond clock and
sleep ports for host adaptation/offline tests. Its fetch must honor AbortSignal;
it must not retain personal data. Ports are trusted application dependencies,
not configurable caller inputs. Arbitrary malicious host code is outside the
package's assurance boundary. Node 22.22.2+ provides the default Web APIs. The
transport uses portable Web APIs, but no actual Cloudflare Worker deployment or
retention qualification is claimed here.

Results preserve every submitted field observation and explicit missing/unsupported
states. Supplier `SUCCESS` never becomes a satisfied qualified evaluation.
`supplierConfirmed` requires a strictly valid completion time; its epoch value is
null for malformed completion metadata. `bindsSubject` requires the explicitly
selected profile; callers cannot let result data choose a weaker postal policy.
The host remains responsible for request/result validation, authority/disclosure,
issuer coverage and qualification, document association, concurrent operation
claims, replay/spend controls and phone-only persistence. No provider calls,
deployment or publication is part of the check script.
