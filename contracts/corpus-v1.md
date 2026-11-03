# Canonical development corpus v1

The local corpus lives outside Git in the face workbench's `data/canonical/`. `index.sqlite` is its authoritative index; `media/image/` and `media/video/` hold one original-byte specimen per content digest. Files are named by SHA-256 and verified format/container extension, not provider person/folder names. No model should select training examples by recursively globbing all media: task, label provenance, subject/session reconciliation and split membership come from the index.

| Record | Key and required meaning |
| --- | --- |
| Dataset | Provider ref and pinned version, title/licence metadata, verified archive and file-manifest digests, reconciled source-file count and migration state |
| Media | SHA-256 of exact bytes, image/video kind, canonical relative path, byte length and inspected image format/dimensions where applicable |
| Source observation | Stable digest of provider ref/version/locator, media digest, task/attack hints, the basis of those hints, review state, nullable verified subject/session and nullable split |
| Annotation | Provider/version/locator, content digest, byte length and necessary source annotation content retained in the index for reconciliation |
| Migration receipt | Verified byte/count reconciliation, canonical specimen preservation and original-source cleanup state |

Dataset-title hints are explicitly unreviewed. They do not assert a per-file attack label, shared identity, capture session, genuine/attack ground truth or certification. Provider folder names remain provenance locators only; they are not our identity taxonomy. Exact duplicates share one media record and keep distinct source observations. Conflicting observations are retained for review; no majority label or automatic subject merge is invented.

Verified subject/session identifiers and train/calibration/test membership remain unset until review. Split assignment must group reconciled subjects, linked capture sessions and duplicate/derived media across datasets. Different video frames or provider copies are not independent people/attempts. Face PAD and document PAD remain separate task domains even when their learned operators are shared.

After every canonical byte and source record is reconciled and committed, the owner-authorized cleanup removes redundant downloaded ZIPs and vendor folder trees. Necessary annotations/provenance remain in the index. Canonical originals are read-only; decoded frames, crops, alignment, augmentation and model features are separately versioned derivatives with source digest and transformation identity. Organization does not authorize lossy replacement of original media.

Acquisition validates pinned file names/sizes, ZIP paths/symlinks, CRCs and per-file hashes. Image format/dimensions are inspected; the initial download receipt does not claim complete video decoding or face detection. Video metadata/decoding, subject reconciliation, trusted task labels, quality checks and split creation are separate preparation steps. Public catalogue titles describe the provider's advertised collection, not inspected sample counts.
