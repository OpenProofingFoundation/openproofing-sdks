# Kenshiki SDK monorepo guidance

<!-- BEGIN kenshiki-universal v1 · synced from @kenshiki/config (Kenshiki-Labs/ci packages/config/agents.md) · edit it there, not here -->
## Kenshiki rules for every repository

These apply to every coding agent (Claude, Codex, Cursor, Copilot and others) and to the people
directing them. The repository's own rules follow this block. Where the two differ, the stricter one
applies. A repository section may add rules; it never grants an exception to these.

### Authorization

- Do not stage, commit, push, merge, deploy or publish unless the person directing you asked for
  that specific action. Approval for one action does not extend to the next.
- Irreversible operations need explicit confirmation first: `git checkout`/`restore`/`reset`/`clean`
  over changed files, `rm`, force-push, overwriting a file you have not read, dropping a database
  table. Being confident you understood is not permission.
- Never bypass hooks (`--no-verify`).
- Live calls that cost money or reach real people (SMS, carrier lookups, payment, email) need
  authorization for that task.

### Preserve other work

- Read `git status` before editing. Uncommitted changes you did not make belong to someone else:
  leave them alone, never stage them, never revert them.
- Other sessions and other developers work in these repositories at the same time. If a file changed
  on disk since you read it, read it again.

### Branches and worktrees

- Two long-lived branches: `dev`, where work is integrated and pull requests land, and `main`, what is
  released and deployed. No other branch lives longer than its task.
- Every task is one topic branch off `dev`, named `feat/`, `fix/`, `chore/` or `docs/` plus a short
  name. It reaches `dev` by a pull request with green checks, is merged (squash unless the repository's
  own procedure says otherwise), and is deleted on merge.
- `main` moves only by promotion of a `dev` commit whose checks are green: a fast-forward, or a merge
  commit where the repository's promotion procedure says so. Never commit or open a topic pull request
  into `main`, and never squash or rebase `dev` into `main`.
- Work in progress is committed to its topic branch and pushed. The only copy of work is never a stash,
  an unpushed branch or a temporary directory.
- Extra worktrees live at `~/Developer/<repo>.worktrees/<branch>`, never under `/tmp` or a scratch
  directory, and are created and removed with `npx @kenshiki/config work start|clean`. Never remove a
  worktree that holds uncommitted or unpushed work.
- Tags are for releases only, made by the repository's release process.

### Verify before you assert

- Read a file in full before you make a claim about it, edit it, review it or brief another agent on
  it. Search output locates files and proves absence; it is not evidence of what code does.
- Cite `file:line` for claims about code, or say "unverified".
- For any external system (a vendor API, an Apple framework, an RFC, ICAO, AAMVA) read the current
  contract before writing integration code or diagnosing a failure. What you remember is a hypothesis.
  If you cannot reach the document, say so.
- A passing test is not proof the behaviour is right; tests can encode the defect. Check behaviour
  against the contract, the wire payload or the server's enforcement.
- A briefing to another agent is an assertion: read the governing gate or contract before writing it,
  and tell the agent to read files in full, never to "spot-check".

### Gates

- Run the repository's check (`npm run check`, `make check` or what its section names) before
  proposing a commit.
- Executable declarations (guards, contract files, lockfiles, CI checks) outrank your reading of the
  code. If one blocks your change, fix the real cause or raise it. Never edit a declaration to match
  what you just did, never weaken or delete a gate, never suppress a finding to clear it.
- Shared tooling comes from Kenshiki-Labs/ci: CI through its reusable workflows, Biome, ESLint and
  TypeScript settings from `@kenshiki/config`. Do not add a local copy of something it provides.
- Dependencies are pinned exactly. Node is pinned in `.node-version`.

### Secrets and personal data

- Never print, log, commit or paste secrets, tokens, private keys or personal data (phone numbers,
  document images, identity records) into code, diffs, logs or chat.
- Credentials live in ignored local files or the platform's secret store (Worker secrets, GitHub
  secrets, the keychain). Real identity data and sample documents never go into a repository.

### Code

- Propagate errors by default. Catch only to recover or to add context before rethrowing; a catch that
  logs and continues, returns an empty value or rethrows unchanged is not allowed.
- Await, return or hand off every Promise to an owned lifecycle (`ctx.waitUntil`). `void promise` is
  not error handling.
- Fail closed on integrity and authorization checks.

### Scope

- An instruction that says _only_, _don't_ or _one_ narrows the work. A follow-up narrows the earlier
  instruction; it never widens it.
- If you think a case is an exception, ask before acting. Do not leave it out silently and do not
  announce it afterwards.
- Change one thing, show the result, wait. Add the new thing beside the old, move one call site, and
  delete the old one only after the new one is accepted.
- On visual work, produce the screenshot before the second change.
- "Stop" means stop now.

### Decisions and checkpoints

- A decision that is genuinely the owner's goes to them as a question, with your recommendation as the
  first option. Use the client's question tool when it has one; never bury the choice in prose.
- An engineering-correctness fork has one right answer. Work it out, state it and do it; do not offer
  a menu. Asking is never a substitute for working.
- Work expected to run past about 30 minutes or touch more than three files checkpoints at every unit
  that leaves the tree green: a three-line status (done, in progress, next), the gates on the touched
  files, and an offer to commit the work in progress. An offer, not a commit.

### Reporting

- Name the level of evidence: written, compiles, covered by a named test, verified by a named run,
  verified on a device. Do not say "verified" without a run in this session.
- Report only checks you actually ran, with the commit and whether the tree was clean. Separate what
  you measured from what you inferred.
- Report a defect as the file, the line, the cause and the fix. Do not add who wrote it.
- State a correction plainly, once, and carry on.
<!-- END kenshiki-universal -->

Read [APP-ARCH-001 revision 0.2](governance/architecture/APP-ARCH-001.md), [the repository guide](README.md), [migration and validation notes](governance/monorepo.md), and the relevant capability's AGENTS.md, contracts and extraction ledger before implementation.

- `document/`, `passport/` and `biometric/` are independently consumable iOS/Android products with independent release versions. Optional presentation and adapters stay separate from headless capability APIs. The biometric Linux/NIST adapter is an explicit delivery track.
- Shared SQLite, key custody, platform attestation and lifecycle mechanisms belong in `foundation/`; shared wire contracts and conformance vectors belong in `contracts/`. Selected Swift mechanisms are implemented; their platform qualification and Android counterparts are tracked separately in `foundation/README.md`. Never duplicate those mechanisms between capabilities.
- **NO LOGIC IN SWIFTUI EVER.** Native renderers consume supplied state and forward typed events. Controllers/use cases outside SwiftUI/UIKit/Compose/Views own behavior, decisions, formatting, async work, storage and networking.
- All authored user-facing strings, including accessibility and platform usage descriptions, must be localizable. The entire design system is schema-validated JSONC with deterministic native generation and drift checks. Require WCAG 2.2 A/AA native applicability and actual VoiceOver/TalkBack/manual evidence when presentation is introduced.
- Keep BFF authority server-side. Public clients return typed observations, scoped outcomes and reason codes with bound source/model/policy lineage; client flags never authorize complete identity acceptance.
- Run `npm ci --ignore-scripts`, `npm run bootstrap`, and `npm run check`. Run `python3 scripts/check.py --sdk <product> --platform all` for affected native changes. Root CI runs all three products and all five lanes. Shared changes validate every consumer.
- Zero-debt guards and their adversarial tests move with implementation. New targets, languages, assets, dependencies and foundation/presentation modules require guard and CI coverage in the same change. The imported boundary engines retain their pinned source hashes.
- Keep real identity data, sample images, private indexes, environments and model weights outside the entire monorepo. The existing external face workbench remains usable; do not copy it into Git.
- Ground biometric/document algorithms in [the pinned research pack](governance/research/README.md) and its equation/assumption notes. Read relevant primary method sections, identify adopted equations and deviations, and carry common positive/negative vectors into Swift, Kotlin and C++20/NIST. Paper inclusion does not select a model or establish measured accuracy. Keep source/portrait binding, artifact-specific preprocessing, learned observations and product policy separate. Use the [method notes](governance/research/method-notes.md) and the [portrait/selfie contract](contracts/portrait-selfie-v1.md); C++20/Linux NIST is a required contract consumer alongside Swift and Kotlin.
- Distinguish scaffold, implemented behavior, source checks, native build, integration, installed/physical acceptance and external evaluation. Record executed commands and receipts; no source guard establishes UI accessibility or NIST performance.
- Checkpoint source in Git before switching or consolidating worktrees. Before removing a checkout, require a clean status and preserve every unique commit in the canonical branches or a verified external Git bundle. Archive untracked source and receipts with hashes before removal. Use Git worktree operations for registered checkouts.
- Implementation planning belongs in the architecture appendices. `governance/references/` is a frozen, hash-pinned reference snapshot; its source-code links refer to the original identity checkout. The active app architecture authority is `governance/architecture/APP-ARCH-001.md`.

Repository consolidation is authorized. It does not authorize production deployment, public visibility changes, release publication, destructive removal of predecessor repositories or migration of the existing identity SDK implementation.

Shared QA mechanisms live once in `quality/`; capability entry points bind explicit roots. Keep original supplier/source hashes and attributed patch provenance. Root tooling locks cover every shared file. Check **all GitHub check runs, including SonarCloud**, before declaring a checkpoint clean or advancing main. Passing Actions jobs alone is insufficient; record Sonar gate, open issue and duplication results separately. Verified false positives require concrete evidence.
