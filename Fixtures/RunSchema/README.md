These fixture files pin on-disk run-file shapes that the mod has written. The
`v*-` prefix in each filename is historical — it dates the fixture to the
schema version that existed when it was added. Versions are no longer used at
runtime; the loader detects the per-instance vs. pooled shape structurally.
New fixtures added going forward do not need a `v*-` prefix.

- `v1-pooled-run.json`
  Pooled shape. Aggregates are keyed by card definition id and do not carry
  the per-instance resume metadata introduced later. Loads as historical-only;
  cannot rebuild live state.
- `v2-per-instance-run.json`
  Earliest per-instance shape. Aggregates are keyed by per-instance card id
  and include the resume-only snapshots (`instance_numbers_by_def`,
  `def_counters`) needed to rebuild numbering after hot reload.
- `v3-per-instance-effects-run.json`
  Per-instance shape extended with applied-effect summaries nested under each
  card aggregate.
- `v4-per-instance-effects-exhaust-run.json`
  Adds the per-card "times exhausted" count.
- `v5-per-instance-block-ledger-run.json`
  Adds absorbed/wasted block aggregates.
- `v6-per-instance-artifact-block-run.json`
  Adds per-effect Artifact-blocked debuff counters.
- `v7-per-instance-poison-damage-run.json`
  Adds per-effect downstream damage and overkill counters so dedicated poison
  rows can report observed poison outcomes, not just poison applied.
- `v8-per-instance-regent-stars-run.json`
  Adds Regent star-resource spend/gain fields alongside the existing energy
  and per-instance attribution data.
- `v9-per-instance-blocked-draw-run.json`
  Adds per-card blocked-draw attribution counts.
- `v9-per-instance-forge-run.json`
  Per-card forge granted tracking from the forge-tracking branch (added in
  parallel with the v9 blocked-draw work).
- `v10-per-instance-forge-run.json`
  Per-card forge granted tracking on top of the v9 blocked-draw fields.
- `v11-per-instance-no-draw-blocked-run.json`
  Adds per-effect downstream blocked-draw counts so powers like No Draw can
  report how many cards they actually prevented from being drawn.
- `v12-per-instance-draw-attempt-gap-run.json`
  Adds per-card attempted draw counts so draw cards can show what they tried
  to draw versus what actually landed.
- `v13-per-instance-blocked-draw-reasons-run.json`
  Adds categorized blocked-draw reasons so draw cards can say why missing
  draws were prevented.
- `v14-per-instance-make-it-so-run.json`
  Adds per-card summon-to-hand tracking for cards like `Make It So`.
- `v15-bag-of-marbles-run.json`
  Adds relic aggregate storage for Bag of Marbles combat-start Vulnerable
  tracking.
- `v16-red-mask-run.json`
  Adds Red Mask Weak tracking to relic aggregates.
- `v17-orichalcum-run.json`
  Adds Orichalcum additional block gained tracking to relic aggregates.
- `v18-pocketwatch-run.json`
  Adds Pocketwatch additional cards drawn tracking to relic aggregates.

Why these exist:

- new shape work should be validated against real checked-in examples, not memory
- pooled vs. per-instance is not a lossless migration, so the old pooled shape
  needs to stay visible when changing loader behavior
- additive follow-on shapes still need fixture coverage so "old but resumable"
  behavior stays intentional
- future tests can read these files directly without having to reconstruct old
  JSON by hand
