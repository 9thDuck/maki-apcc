# Changelog

All notable changes to apcc-lite are documented here. The plugin is a single-file
maki plugin (`plugin/apcc-lite.lua`) — versions track the whole pack.

## [Unreleased]

### Fixed

- `/persist` no longer switches off early compaction for the rest of the window.
- "don't compact the JSON" / "never compact logs" are no longer read as a ban on
  session compaction (foreign-object check first; Lua `|` alternation removed).
- Threshold clamped to (auto-compact cap − 40k), floor 25% of window, logged once.
- Swallowed handler errors are logged; an unreadable index counts as a
  verification attempt instead of deferring forever.
- Save prompts route in-flight state to beads when `bd` is present (file note
  fallback), index row always. The `PERSIST:` init.lua string now asks for the
  four-field form the parser requires (the old free-form string never parsed).

### Docs

- README: honest token pitch (the saving comes from compacting earlier; maki's
  `agent.compaction_buffer` can do that too), no tool gate, rung 2 is
  token-triggered, `APCC_TEST_FIRE` removed, exact save-check rules.
- docs/token-math.md: tuned-maki baselines added.

## [0.2.0] — 2026-10-15

Release candidate. The loop is now an opencode-faithful three-rung ladder with
enforced fallback, honest receipts, and a native-compact veto.

### Added

- **Rung-1 directive, owned channel**: one persist directive per epoch via
  `maki.session.prompt` (stop-after-persist text); in-band tool-denial text as the
  headless fallback; no nudge repetition (latched until epoch close).
- **Rung-2 enforced fallback**: directive ignored → forced compaction after a
  backoff, triggered by a token hard limit (explicit, or threshold + 40k, capped at
  `0.8·window − 10k` so the forced compaction always wins the race against maki's
  native 20%-buffer auto-compact). Withheld while subagents are in flight.
- **Native-compact skip veto**: `agent.compact.before` auto-skip while a persist
  turn is pending (bounded, fail-open, honestly receipted).
- **Freshness-bound verification**: an armed persist verifies only when observed
  persist writes postdate both the directive and the last compaction
  (`lastPersistEventAt > max(directiveSentAt, compactionEndedAt)`); marker slugs
  verify all-or-nothing against the context index with a 2-attempt retry window and
  a loud abandonment path.
- **Owner-directive deference**: keyword-prefixed utterance ring (memory-only),
  clause classifier (prohibit > compact > persist), latest-wins, prohibition latch
  that survives epochs and withholds rung 2.
- **Compaction-status honesty**: every compaction receipt is exactly
  `done / not-done / none`; `UNVERIFIED` persists are said so out loud.
- **Fold capture**: owner prompts arriving while a directive is latched are folded
  and executed post-compaction.
- **Backstop**: ladder closed + context still growing → compact regardless.
- **`M.version` release stamp**, surfaced in the `loaded:` log line for field
  debugging.

### Changed

- **Stale-propagation removal**: armed-marker state no longer leaks across epochs;
  the marker lifecycle is epoch-scoped and reset by `new_epoch`.
- **Epoch hygiene**: one-per-epoch receipt latches; PERSIST-row appends and wake
  decisions are keyed to the epoch that earned them.
- **Wake discipline**: the continuation wake fires only for non-quiet persists or
  existing folds, and never after a manual compaction.
- **README rewritten for the v9 semantics** (the shipped instructions previously
  described the retired arm/idle-fire loop), including the verified install recipe
  and the `maki.setup`-is-init-scoped finding.

### Fixed

- Cold-home packaging defects found by the blind test: `scripts/smoke.sh` now points
  `HOME`/`XDG_*` at the cold home for the gate run, installs with `load = true`
  (`require("apcc_lite")` does not resolve in a fresh home), and pre-grants the
  approvals store; the README headless recipe was replaced with that verified
  pattern. The troubleshooting section no longer claims hand-written approval
  grants are ignored.
- Persist below the trigger no longer arms a compact (threshold gates both the arm
  and the fire; stale/legacy armed state is cleared instead of fired).
- Mid-turn rung 2 + strand guard: the no-idle case forces the follow-through
  instead of stranding the session past the hard limit.
- Question-clause splitting in the owner-utterance classifier (a question no longer
  misclassifies as a compact order).

## [0.1.2] — 2026-10-13

- Owner-directive deference (prohibition latch, compact/persist order parsing) and
  mid-turn threshold nudges.
- Events-verified persists wired into order verification, enforced-fallback
  receipts, and compaction status — closing the directive/marker catch-22.
- git credential handling fix in the release tooling.

## [0.1.1] — 2026-10-12

- **v9 opencode-faithful port**: rung-1/rung-2/backstop ladder, marker floor with
  carry-forward and wobble band, owner-order and prohibition latches, marker
  verification with retry window, recovery contract (`contractText`) and fold
  capture, quiet-unless-pending continuation. The claude-ladder semantics were
  removed.
- Threshold-gate fix: a persist below the trigger no longer arms the idle compact
  (arm-time and fire-time both re-verify the threshold).
- Live-loop fix: compaction wake now fires reliably after idle compactions.

## [0.1.0] — 2026-10-12

- Initial release: persist → gate → arm → idle-fire loop for maki, packaged as a
  self-registering maki pack (`pack.add` + auto-start + env opts
  `APCC_POST_PERSIST` / `APCC_BEADS` / `APCC_THRESHOLD_TOKENS`).
- beads is an optional external dependency (probed on PATH, never bundled).
