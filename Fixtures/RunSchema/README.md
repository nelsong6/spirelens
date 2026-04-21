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
- `v7-per-instance-poison-ledger-run.json`
  Current schema. Adds downstream poison damage attribution on top of the v6
  artifact-block counters.

Why these exist:

- schema work should be validated against real checked-in examples, not memory
- `v1 -> v2` is not a lossless migration, so the old pooled shape needs to stay
  visible when changing loader behavior
- additive follow-on schemas (like `v2 -> v3`, `v4 -> v5`, `v5 -> v6`, and `v6 -> v7`) still need fixture coverage so
  "old but resumable" behavior stays intentional
- future tests can read these files directly without having to reconstruct old
  JSON by hand
