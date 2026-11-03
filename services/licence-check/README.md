# Licence-check packages

This workspace contains two independent ESM npm artifacts: the supplier-neutral
`@kenshiki-labs/licence-check` core and its optional
`@kenshiki-labs/licence-check-trusona` adapter. The adapter declares its exact core
version and imports its public package entry point. Neither needs a sibling source
checkout after packing and installation. Both ship JavaScript and TypeScript
declarations; consumers need no TypeScript runtime loader.

These are private `0.0.0` extraction artifacts. There is no registry publication or
automatic publish hook. Release policy and registry publication remain separate.

## Build and verify

From this directory, use Node >=22.22.2 and the pinned workspace dependencies:

```sh
npm ci --ignore-scripts
npm run check
```

This builds both packages, strictly type-checks their implementation and tests,
executes every test (including all 66 pinned synthetic Trusona vectors and actual
loopback HTTP integration), and packs/installs both tarballs into a fresh offline
consumer. The consumer executes emitted JavaScript through public exports and
compiles a separate TypeScript caller against emitted declarations. Its logs and
receipt remain under `.build/consumer/`. No test calls a vendor.

`npm run build`, `npm test`, and `npm run test:consumer` select the corresponding
steps. Run build first when selecting tests/consumer individually. Package-local
`npm run check` retains boundary/type/test checks without repository-global tools.
The parent monorepo enforces the reviewed source inventory and a mandatory Node
qualification lane. Its all-platform aggregate also installs the pinned package
dependencies and executes that lane. The wrapper preserves checkout, platform,
input, test, consumer and artifact evidence under `.build/licence-check/` at the
repository root; rejected attempts preserve failed receipts there as well.

## Contract and scope

The extraction preserves `pulse.dldv.v1`, pinned profile `trusona-dldv-2` and
`pulse-dldv-03-05-street-observation-1`. `contracts/provenance.json` records hashes of
the supplied Pulse OpenAPI 0.1.7, supplier OpenAPI 1.0.0, and byte-identical synthetic
vectors from `pulse-compliance/references/aamva`. These pinned documents ground the
implementation; current live-provider documentation and production behavior are
not established by this package's tests. The vector scope excludes host admission.

The core exports the contract types, required-check calculation and the existing
application subject-binding policy. This is a policy helper over already admitted,
validated data, not an HTTP parser, authentication service or general decision
engine. The helper binds contract, operation, capture, revision, profile, provider,
postal policy and exact required checks. The pinned policy permits only an observed
first-street-line mismatch; it preserves that mismatch and the incomplete,
unqualified evaluation. A subject association is not identity acceptance, address
verification, document authenticity or driving entitlement.

Trusona remains **unqualified**. Its observed field booleans remain unqualified and
its required-field evaluation remains incomplete. A successful synthetic exchange
does not establish jurisdiction coverage, zero retention, supplier accuracy,
billing behavior, PAD, identity assurance or production enablement.

This increment contains no public HTTP route, authority/device implementation,
operation/replay store, customer config loader, Node/Workers deployment host,
Persona adapter, Pulse adoption or app migration. Hosts must admit/validate each
request and result; enforce authority, disclosure, issuer/coverage, document
association, concurrent operation claims and replay/spend controls; choose one
supplier per deployment; and preserve the original deadline and phone-only
persistence obligations. No fallback or create retry is provided.

See [core](core/README.md) and [Trusona](trusona/README.md) for the public seam.
