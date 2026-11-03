# Native reference application guidance

The default iOS route exposes the Face, Document and Passport capability tabs.
Do not hide capability navigation behind an enrollment-style first-run wizard.
Guided steps belong inside the selected capability. The older app-level
Passport → Selfie → Result journey remains available to explicit debug regression
launches; it is not the production startup route. `PassportFaceJourneyController`
retains its session transitions and typed handoffs. Preserve explicit
visibility-bound acquisition admission, generation fencing and in-memory erasure
for selfies and comparison state. The explicitly saved passport checkpoint uses
the shared protected SQLite store, survives session reset, and has its own durable
delete action. Restoring it must not claim a fresh NFC read or server verification.

Follow [root guidance](../AGENTS.md) and [APP-ARCH-001 revision 0.2](../governance/architecture/APP-ARCH-001.md). The iOS biometric tab composes an original passport portrait, live selfie acquisition and optional AuraFace similarity processing; the document tab composes public document camera, image preparation, OCR/PDF417 and portrait observations for local front/back review; the iOS passport tab uses the live MRZ/NFC/result/portrait flow. All three Android workflows remain simulations. Preserve explicit scope and demonstration-only outcomes where simulation is still used. Document capture is not issuing-state verification or durable enrollment; leaving/backgrounding the page clears its in-memory review. Document observations commit to a dedicated protected SQLite store before advancing; explicit Open saved capture restores authenticated historical bytes without camera or processing. Session reset does not delete committed captures. Delete saved capture has an explicit confirmation and erases only document custody. Local signatures do not establish sensor authenticity or identity verification.

Document completion is transactional: the snapshot, descriptor, declared independently signed motion records and current pointer publish together. Reopen verifies the entire declared set. Preserve original front-motion proofs when pairing a back image, and do not invent motion for historical captures or uncollected sides. Bounded motion retention carries explicit limits, omissions and unavailable states; it does not establish continuous coverage or exact still-exposure alignment.

**NO LOGIC IN SWIFTUI EVER.** UIKit/Android renderers also only consume prepared state and emit typed events. Hosts own platform wiring, localization, lifecycle and focus. Controllers own workflow transitions. Styling and authored copy originate in `design-system/` JSONC. Do not add live permissions, sensors, keys, storage, inference or transport without their contracts, boundaries and verification.

Run root `npm run check` and every affected `scripts/presentation_check.py` lane. New source/resources and target graphs require inventory, guard and CI coverage. Keep [WCAG-MATRIX.md](WCAG-MATRIX.md) and [ACCESSIBILITY-ACCEPTANCE.md](ACCESSIBILITY-ACCEPTANCE.md) accurate; a simulator smoke test does not establish VoiceOver/TalkBack or physical-device acceptance. Preserve independent headless SDK consumption. No commits, distribution or deployment are implied by implementation work.
