These fixture files pin the on-disk run-file shapes that the mod has written.

- `v1-pooled-run.json`
  Legacy schema. Aggregates are keyed by card definition id and do not carry
  the per-instance resume metadata introduced later.
- `v2-per-instance-run.json`
  Legacy-but-resumable per-instance schema. Aggregates are keyed by per-instance
  card id and include the resume-only snapshots needed to rebuild numbering
  after hot reload.
- `v3-per-instance-effects-run.json`
  Legacy-but-resumable additive schema. Extends the per-instance shape with
  applied-effect summaries nested under each card aggregate.
- `v4-per-instance-effects-exhaust-run.json`
  Legacy-but-resumable additive schema. Adds the per-card "times exhausted"
  count on top of the v3 effect summaries.
- `v5-per-instance-block-ledger-run.json`
  Legacy-but-resumable additive schema. Adds absorbed/wasted block aggregates
  on top of the v4 effect and exhaust fields.
- `v6-per-instance-artifact-block-run.json`
  Legacy-but-resumable additive schema. Adds per-effect Artifact-blocked debuff counters on top of
  the v5 block ledger fields.
- `v7-per-instance-poison-damage-run.json`
  Legacy-but-resumable additive schema. Adds per-effect downstream damage and overkill counters so
  dedicated poison rows can report observed poison outcomes, not just poison applied.
- `v8-per-instance-regent-stars-run.json`
  Legacy-but-resumable additive schema. Adds Regent star-resource spend/gain fields alongside the
  existing energy and per-instance attribution data.
- `v9-per-instance-blocked-draw-run.json`
  Legacy-but-resumable additive schema. Adds per-card blocked-draw attribution
  counts on top of the v8 Regent-star fields.
- `v9-per-instance-forge-run.json`
  Legacy-but-resumable additive schema from the forge-tracking branch. Adds
  per-card forge granted tracking alongside the existing energy, star, and
  per-instance attribution data.
- `v10-per-instance-forge-run.json`
  Legacy-but-resumable additive schema. Adds per-card forge granted tracking
  on top of the v9 blocked-draw fields.
- `v11-per-instance-no-draw-blocked-run.json`
  Legacy-but-resumable additive schema. Adds per-effect downstream blocked-draw
  counts so powers like No Draw can report how many cards they actually
  prevented from being drawn.
- `v12-per-instance-draw-attempt-gap-run.json`
  Legacy-but-resumable additive schema. Adds per-card attempted draw counts so
  draw cards can show what they tried to draw versus what actually landed,
  alongside the v11 effect-level blocked-draw totals.
- `v13-per-instance-blocked-draw-reasons-run.json`
  Legacy-but-resumable additive schema. Adds categorized blocked-draw reasons so draw cards can say
  why missing draws were prevented, alongside the v12 attempted/actual gap.
- `v14-per-instance-make-it-so-run.json`
  Current schema. Adds per-card summon-to-hand tracking for cards like
  `Make It So`, alongside the existing forge, blocked-draw, and per-instance
  attribution data.

Why these exist:

- schema work should be validated against real checked-in examples, not memory
- `v1 -> v2` is not a lossless migration, so the old pooled shape needs to stay
  visible when changing loader behavior
- additive follow-on schemas (like `v2 -> v3`, `v4 -> v5`, `v5 -> v6`, `v6 -> v7`, `v7 -> v8`, `v8 -> v9`, `v9 -> v10`, `v10 -> v11`, `v11 -> v12`, and `v12 -> v13`) still need fixture coverage so
- additive follow-on schemas (like `v2 -> v3`, `v4 -> v5`, `v5 -> v6`, `v6 -> v7`, `v7 -> v8`, `v8 -> v9`, `v9 -> v10`, `v10 -> v11`, `v11 -> v12`, `v12 -> v13`, and `v13 -> v14`) still need fixture coverage so
  "old but resumable" behavior stays intentional
- future tests can read these files directly without having to reconstruct old
  JSON by hand
