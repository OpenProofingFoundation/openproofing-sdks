# AXON sample corpus

The complete public catalogue was paginated through `[20, 20, 3, 0]` returned entries: 43 datasets. The API capped results at 20 despite `pageSize=100`; one response was not the full catalogue. [axon-catalog.json](axon-catalog.json) records metadata and page digests. The acquisition selects 29 relevant face/identity, ageing, bona fide, synthetic-face and presentation-attack sample datasets; voice, palm, MRI, phone-damage and unrelated POV products are excluded.

The earlier 313-image figure described only one downloaded selfie/ID archive. It was never AXON's collection size or a verified person count. The current canonical corpus count is read from its actual index, not marketing titles or source folder counts.

Use the external workbench `/Users/shf/Developer/kenshiki-face-workbench`. Working media and metadata belong under `data/canonical/`, with `index.sqlite` as the source of truth. The owner's instruction authorizes removal of redundant ZIPs/vendor trees after canonical byte/count reconciliation. [corpus-v1.md](../../contracts/corpus-v1.md) defines our organization and provenance/review semantics. No biometric media, original annotations, private indexes or weights are committed to Git.

From `biometric/`:

```sh
/absolute/external/workbench/venv/bin/python tools/face_lab/axon_bulk.py --workdir /absolute/external/workbench --catalog docs/axon-catalog.json --workers 4 --transport aria2
/absolute/external/workbench/venv/bin/python tools/face_lab/canonical.py --workdir /absolute/external/workbench --retire-sources --watch --expected 29
```

The accelerated downloader uses aria2 1.37.0 (`brew install aria2` on this Mac); archive/file/CRC verification still runs after transfer. Keep `.partial.aria2` control files: segmented partials must resume with `--transport aria2`, never by treating sparse file length as completed bytes. Already canonicalized datasets are verified and reused rather than downloaded again.

`--retire-sources` is the explicit cleanup switch; do not use it for unrelated inputs without owner authorization. During this acquisition, private operational receipts/logs are in `data/catalog/`. Source staging is transient `data/quarantine/`. Canonical preparation must not re-download retired datasets or reintroduce competing training roots; resume behavior and summary receipts must account for completed canonical migrations.

Face print/replay/mask samples do not automatically supply ID-card material/liveness labels. Review source annotations, reconcile identities/sessions/duplicates and assign frozen splits before using the corpus for measured model selection.
