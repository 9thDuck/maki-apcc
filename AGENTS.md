# AGENTS.md — contract for AI agents and contributors

This file serves two audiences: **AI agents running under the plugin** (you will
see `[apcc]` directives and recovery prompts) and **AI contributors editing this
repo** (the plugin's lua and docs). Both halves are contracts — violating either
breaks the persist → compact → restore loop the plugin exists to protect.

## If you are running under the plugin

### When a `[apcc]` persist directive appears

A directive means context is near the persist threshold. Do, in order:

1. **Persist now, in small linked units** — beads issues (`bd create/update`) or
   files under `.opencode/context/` / `docs/research/`. Many small units, not one
   monolith; each unit gets a slug.
2. **End the reply with the marker** (last non-empty line, outside an unbalanced
   code fence):
   ```
   NEXT: <one-line next action>        ← optional, becomes the continuation brief
   PERSISTED: <n> units (<slugs>)      ← exact form; or PERSISTED: none
   ```
   `PERSISTED: none` acknowledges without arming — use it only when you truly
   persisted nothing. Marker slugs are verified **all-or-nothing** against the
   context index table; a slug that is not an index row fails verification.
3. **Stop after persisting.** The directive asks for stop-after-persist; do not
   start new work in the same turn.

Ignoring the directive is not a escape: after a backoff, rung 2 forces a compaction
and the summary will honestly say the persist was `UNVERIFIED`.

### After any compaction (the recovery contract)

Your first action is always: **re-read `.opencode/context/index.md` first — it is
the map.** Pull only the units the current task needs (`bd show <id>` / read the
path). Your first state claim must cite a freshly read artifact, not the compaction
summary. If the summary's last line is `PERSIST: <note>`, that note is the
machine-readable recovery pointer the plugin appended to the index.

### Where the text is parsed (do not reformat)

- `PERSISTED: <n> units (<slugs>)` / `PERSISTED: none` — parsed from your reply
  tail by the plugin (`tool.*.input` + stop-layer handlers).
- `PERSIST: <one-line note>` — requested via `agent.compaction_instructions`, parsed
  from the compaction summary by the `CompactionDone` handler, appended as a row to
  `.opencode/context/index.md`. Keep the init.lua instruction strings verbatim.
- `NEXT: <one-line next action>` — captured as the continuation brief for the
  post-compaction wake and fresh-session handoffs.

## State file schema

`<maki state dir>/apcc_lite/state-<sanitized cwd>.json` — one JSON object, top
level `{ sessions: { <session-id>: <session state> } }`. Session fields (groups):

- **epoch/clock**: `epoch`, `updatedAt`, `lastTokens`, `lastTokensAt`,
  `lastIdleTokens`, `compactionEndedAt`, `recovered`
- **rung ladder**: `directiveSent`, `directiveTokens`, `directiveSentAt`,
  `nudgeCount`, `nudgeLastAt`, `pendingNudge`, `escalated`, `subagentsInFlight`,
  `ladderClosedByNone`, `noneClaimedAt`, `ladderClosedByUnits`, `commandPersist`,
  `commandPersistMarkerAt`
- **marker lifecycle (epoch-scoped)**: `markerEpoch`, `markerSeenAt`, `markerOnly`,
  `markerManual`, `markerManualCompact`, `markerUnits`, `markerSlugs`,
  `markerAmbiguous`, `markerNext`, `markerVerifyAttempts`, `markerVerifyReceipted`,
  `markerAbandoned`, `lastAttemptedMarkerEpoch`, `attempts`, `compactionPending`,
  `autoCompactAt`, `backstopFiredAt`, `lastOrderRefusalAt`
- **persist ground truth (maki-native)**: `persistEvents`, `persistedEpoch`,
  `persistedTokens`, `lastPersistEventAt`, `units`, `nextAction`
- **owner words**: `utterances` (memory-only ring, stripped at save), `folds`
  (persisted — must survive reload), `prohibitedAt`, `prohibitedStanding`,
  `prohibitedText`, `prohibitedMsg`, `intentReceiptKey`
- **compaction provenance**: `lastCompactReason`, `lastCompactManual`,
  `pendingContinuation`
- **one-per-epoch receipt latches** (reset by `new_epoch`): `floorConfigLogged`,
  `floorSkipLogged`, `floorStaleLogged`, `floorExemptLogged`, `floorWaiveLogged`,
  `stuckLogged`, `enforcedLogged`, `enforcedWithheldLogged`, `rungFloorLogged`,
  `nudgeMissLogged`

The state file is the plugin's own; **agents must not hand-edit it** — delete it to
reset a wedged project (the plugin rebuilds it), never patch it in place.

## Do-not-break invariants (contributors)

1. **Freshness bound**: an armed persist is only "verified" when
   `lastPersistEventAt > max(directiveSentAt, compactionEndedAt)` — observed writes
   must postdate both the directive and the last compaction. Never weaken this;
   stale writes must not verify a fresh marker.
2. **Veto never blocks**: reads always pass the `tool.*.input` gate, persist-class
   writes are never denied, denials are bounded, and every gate error fails **open**.
   The `agent.compact.before` auto-skip veto applies only while a persist turn is
   genuinely pending.
3. **Enforced-fallback honesty**: a rung-2 forced compaction with an unverified
   persist must say `UNVERIFIED` in the summary — never silently claim `done`.
   Compaction status is exactly `done / not-done / none`.
4. **Wake discipline**: the continuation wake fires only when the persist field is
   non-quiet or folds exist, and **never after a manual compaction**. A quiet
   manual `/compact` stays quiet.
5. **Fail-open everywhere**: no plugin error may strand a session — wrap, log, and
   let the call pass. The kill switch `APCC_LITE=0` must always work.
6. **Lazy host probes**: never call `maki.fn.*` on the plugin-load path (hangs
   `/reload`); never call `maki.setup` outside init.lua evaluation (it is `nil`
   there); never write files via `maki.fs` during activation (yield-illegal).

## Per-batch gate expectation (contributors)

There is no standalone lua on the host — the syntax/load check **is** a headless
run. Before calling any plugin edit done:

```sh
maki --yolo -p "Reply with exactly: OK"   # in a rig project dir
```

then assert: output is exactly `OK`, the maki log has zero lua/runtime errors for
the run, and the loaded copy is byte-identical to the pack variant. Pack builds are
regenerated from the live plugin file (single source of truth); never hand-edit the
pack variant. Behavior changes get a scenario in the headless rig (log-receipted
pass conditions) before merge — see README "Verification" for the receipt lines.
