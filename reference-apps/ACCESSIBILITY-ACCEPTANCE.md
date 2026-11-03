# Native presentation acceptance record

24 October navigation correction: the SDK app opens with visible capability tabs.
The first-run guided wizard is no longer the default. The live iOS Document tab
adds explicit camera admission, front/back image review, OCR/PDF417 observations,
portrait candidates, retakes and clearing on withdrawal/backgrounding. Automated
controller and simulator checks qualify only their named assertions. Physical
front/back acquisition, glare/blur handling, portrait correctness, VoiceOver,
largest text/RTL and sensor interruption acceptance remain pending for this build.

19 October owner feedback confirms the preceding SHF passport-photo and face
comparison happy path worked. This is not acceptance of the subsequent guided
wizard. Its Passport → Selfie → Result route, stage announcements, single
confirmation, cancel/retry, retake, details disclosure, background clearing,
largest text/RTL and return from SDK examples require fresh native/manual evidence.
Full VoiceOver and physical negative-path acceptance remain pending.

Status: **full manual and physical acceptance pending**. Static source/resource checks and compilation do not establish WCAG conformance. Automated iOS UI smoke and controller tests cover only their named assertions. The governing requirements are APP-ARCH-001 A11Y-01 through A11Y-07; the complete [55-criterion applicability matrix](WCAG-MATRIX.md) records owners and required acceptance evidence separately from this execution checklist.

For every run record source revision and dirty state, app/APK hash, build receipt, device/OS, locale, appearance, font scale, reduced-motion setting, assistive technology, journey and findings. Supported authored locale is English; en-XA and ar-XB are expanded/RTL test resources, not released translations.

| Journey / setting | iOS VoiceOver | Android TalkBack | Required observations |
| --- | --- | --- | --- |
| iOS home → Saved work / Developer tools → Back; deletion review → Keep saved work | Pending | iOS reference navigation only | One primary start; saved timestamps and reuse context confined to Saved work; Back/Keep preserve data; predictable heading focus and reachable controls at large text and RTL |
| Capability selection → start | Pending | Pending | Heading, disclosure and accessible action labels; logical reading order |
| iOS live document front/back → image/text/barcode/portrait review → retake/reset | Pending | Capture not implemented | Explicit camera start; original/prepared images and provisional face-region scope distinguishable; tab navigation stays available; leaving/backgrounding clears evidence; controls and guidance understandable with assistive technology |
| Android simulations → complete | Not applicable | Pending | Current step/status understandable; simulation explicit; focus and announcements predictable |
| Simulated service failure → retry | Pending | Pending | Specific recoverable message; reachable retry and cancel; no hidden workflow change |
| Live selfie consent → guide/blink/depth → review → Use this selfie; denial/restriction/retry | Pending | Capture not implemented | Accessible guidance/status without announcement flooding; review image has a meaningful label; retake and Use actions remain reachable; local handoff is distinguished from matching or identity acceptance |
| Selfie review → retake/cancel/background; foreground loss and rotation | Pending | Capture not implemented | Review focus/order and guidance remain understandable; interruption clears evidence and requires deliberate restart; rotation preserves the admitted image and its original receipt; readiness updates retain control focus |
| Compare faces → visible processing → cosine result or specific error → retake/discard | Pending | Capture not implemented | Completion receives deliberate focus/announcement once; repeated Use does not deliver twice; local processing and observation-only scope are explicit; discard is accessible; no image, receipt or raw digest is spoken or logged as a status message; cancellation cannot produce a late completion |
| Cancellation at every active stage | Pending | Pending | No later completion; understandable cancelled state; return to chooser |
| Background and restart | Pending | Pending | Guided iOS evidence clears and requires Begin; simulations expose their explicit restore behavior; no automatic success |
| Largest supported text and landscape | Pending | Pending | All content/actions remain available through scrolling; no clipping |
| Expanded pseudolocale; RTL with mixed text | Pending | Pending | Leading/trailing layout; complete readable instructions; no action loss |
| Dark/light; increased contrast | Pending | Pending | Text/non-text contrast, labels independent of color, visible focus |
| Keyboard, switch and voice input | Pending | Pending | All actions reachable and activatable; no focus traps |
| Reduced motion | Pending | Pending | No nonessential animation; stable reading position |

Remaining release evidence: execution of the native criterion matrix; full rendered state/appearance/scale/RTL coverage; measured native target bounds and contrast; hosted Android instrumentation coverage; VoiceOver/TalkBack full journeys; physical qualification of the existing camera/NFC/inference integration. Process-death restoration remains outside this implementation. The optional iOS capture route adds live permissions and sensor orchestration; physical sensor and assistive-technology acceptance remain pending.

Local native execution now includes UIKit tab/back workflow tests and a dedicated Android API 36 emulator journey with saved screenshots and fresh UIAutomator assertions. Refer to `.build/presentation/` for exact artifact/source hashes and settings. These automated observations do not check off manual VoiceOver/TalkBack or physical acceptance criteria.

For the live iOS selfie journey, record the TrueDepth device/OS, permission state,
capture and decoded-pixel identities. Verify denial/restriction, readiness changes,
review rotation, Compare faces, retake and cancellation using VoiceOver and large
text. Acquisition must stop on withdrawal; a retired callback cannot replace a
new session. Evidence clears on Done/Cancel, backgrounding and termination.
Real biometric artifacts stay outside the repository.

Live passport acceptance covers MRZ/manual input → one confirmation → system NFC
sheet → original portrait → Continue to selfie. Check YYMMDD fields, keyboard,
text scaling/RTL, details disclosure, pull-away/reposition recovery and original
portrait binding. CoreNFC sheet resign-active must not cancel the read; true
backgrounding and withdrawal must. Exercise the separate passport/biometric
examples and their return to the guided entry as well.

## Result and motion-details acceptance

The result now reserves the fixed action area for Done. Retake/retry and View
details use the native result menu; technical passport checks, workflow motion
ranges and Copy report use a second-level sheet. Manual acceptance remains pending
for menu discovery, sheet entry/Close/swipe dismissal, focus return, largest text,
RTL, and scrolling while sensor events arrive. Ranges must identify recorded
coverage, permissions and gaps, including workflows resumed from saved evidence.

Fresh server-backed passport acceptance additionally requires this app's own
production App Attest registration, a nonce-bound NFC read, visible percentage and
completion on the system sheet, and a matching Pulse server verdict. Compilation,
mocked replies and installation cannot establish those physical/server outcomes.

## Prior physical observations

- On 17 October 2026 the owner exercised the preceding SHF selfie route and
  identified its obsolete Start Demonstration entry, which was subsequently
  removed. This did not record rotation, denial/retry or VoiceOver acceptance.
- A screenshot of the preceding SHF build (iPhone 17 Pro Max, recorded OS 27.2)
  showed retained selfie state and Discard. That establishes selected-state
  reachability for that artifact; its confirmation layout and labels predate the
  current reviewed-selfie/comparison journey. Local receipts remain under
  `.build/selfie-shf/receipts/`.
- The 19 October portrait/comparison happy-path feedback above applies to the
  preceding repair, not full wizard or assistive-technology acceptance.

## Local quality selection addition, 23 October 2026

Fresh phone acceptance remains pending for the bounded selfie window, visible
per-frame quality/preparation progress, no-selection refusal, retake and background
cancellation. Confirm the selected review image is the same original used for
comparison, and that the earlier original's own depth/motion/admission receipt
is preserved when it wins. Check VoiceOver progress announcement rate, focus
retention and largest text/RTL separately from native controller test evidence.
A signed installation or Mac runtime measurement does not check off this list.

## Shared document front surface, 25 October 2026

Native controller and rendering tests cover automatic/manual request ownership,
preview attachment, advisory level availability, wrapping guidance and appearance
changes. Physical front acquisition and manual VoiceOver acceptance remain
pending. Check capture/cancel discovery, level value announcements, largest text,
RTL, scrolling, permission denial/retry, rotation and background withdrawal on the
exact installed artifact. The level reports positioning only; it is not document
readiness or authenticity evidence.
