# @kenshiki-labs/licence-check

Supplier-neutral ESM contract types and pure required-check/subject-association
policy for `pulse.dldv.v1`. Runtime dependency count: zero. Emitted entry points:
`dist/index.js` and `dist/index.d.ts`, selected through the package root export.

```js
import { requiredChecks, bindsDocumentSubject } from '@kenshiki-labs/licence-check';
const required = requiredChecks(admittedRequest.evidence.document, profile.postal_policy);
const associated = supplierConfirmed
  && bindsDocumentSubject(validatedResult, admittedRequest, profile);
```

The host supplies the immutable admitted request and configured profile. The
binding helper requires the pinned policy's unqualified observed comparisons; it
is not a general qualification policy and cannot authenticate supplier evidence or
prove provenance. It does not parse untrusted JSON, authorize requests, claim an
operation or persist anything. Calendar/time validation rejects overflow-normalized
dates/times; leap-second timestamps are outside this execution profile.

To create a local artifact after the workspace build, run
`npm pack --ignore-scripts --pack-destination /chosen/output` here. Install that
archive into a consumer with `npm install /chosen/output/archive.tgz`. Package files
contain only emitted JavaScript/declarations, this guide and npm metadata. Private
`0.0.0` status intentionally prevents registry publication.
