# apcc-lite

A plugin for [maki](https://github.com/) that saves your agent's in-flight work to
files **before** a context compaction, compacts early (at a token level you choose),
and gets the session going again afterwards — so a long task doesn't lose its
scope, decisions and "exact next action" to a lossy summary.

**Who it is for:** people who run long agentic sessions in maki and keep task notes
in files (or in [beads](https://github.com/steveyegge/beads)). If your sessions are
short, or you are happy with maki's built-in compaction, you do not need this.
Why it can save tokens: every turn re-sends the whole context, so compacting at a
lower level (e.g. 135k instead of the window limit) keeps each turn cheaper, and the
saved notes mean you lose less when it does compact. The author reports a clear drop
in usage-limit drain; there are no measured numbers, so treat savings as
workload-dependent.

## Quick start (about 5 minutes)

Requires **maki 0.6.0 or newer** and a working default model.

**1. Add this to your global `~/.config/maki/init.lua`:**

```lua
maki.pack.add({
  { src = "https://github.com/9thDuck/maki-apcc", name = "apcc-lite", version = "v0.2.0" },
}, { confirm = false, load = true })

maki.setup({
  agent = {
    compaction_instructions = "[apcc] End the summary with a final line 'PERSIST: <one-line recovery note: slugs / exact next action>' or 'PERSIST: none'.",
    post_compaction_instructions = "[apcc] Recovery: re-read .opencode/context/index.md first — it is the map. Pull only the units the current task needs. Your first state claim must cite a freshly read artifact, not the summary.",
  },
})
```

Copy the two instruction strings exactly (the `PERSIST:` tail is parsed).
If you already call `maki.setup` in your init.lua, put the two `agent` keys inside
your existing call — `maki.setup` should appear once.

**2. Turn it on for a project.** The plugin does nothing in a project until that
project has a `.opencode/context/` folder (or a `.beads/` folder). Create it
yourself, in the project root, and keep it out of git:

```sh
mkdir -p .opencode/context
echo ".opencode/" >> .gitignore
```

**3. Start maki once in a terminal and approve the permission prompt**
(`Allow package apcc-lite these permissions … [y/N]` → `y`). The answer is saved;
you are not asked again. The plugin needs the full permission set because it wraps
maki's agent hooks; it does not need or use them for anything else.

**4. Set your trigger point (optional but recommended).** By default the plugin
acts at 60% of the model's context window — late on a large window. To pick a
fixed number instead, start maki with an environment variable:

```sh
APCC_THRESHOLD_TOKENS=135000 maki
```

Pick a value comfortably below the point
where maki would compact on its own.

## How do I know it is working?

It is quiet by design. After your first message in a project that has
`.opencode/context/`, a state file appears:

```sh
ls ~/.local/state/maki/apcc_lite/
```

You should see a file like `state-_home_you_myproject.json` (your project path with `/` replaced by `_`). When the context crosses your
threshold, the assistant will tell you it is saving notes and then add rows to
`.opencode/context/index.md`; after compaction it picks the work back up on its own.
For detail, `grep apcc-lite ~/.local/logs/maki/maki.log`.

**Nothing at all?** Check, in order: maki is ≥ 0.6.0; the project has
`.opencode/context/`; you ran maki in a terminal once and answered `y`;
`APCC_LITE` is not set to `0`. More in [Troubleshooting](#troubleshooting).

## Manual save

Type `/persist` in maki to ask for a save at any time, without waiting for the threshold.

## Turn it off

Set `APCC_LITE=0` in the environment (per run), or remove the `pack.add` block.
Your notes in `.opencode/context/` are plain files and stay put.

## What it touches

Writes only inside the project's `.opencode/context/` (and `docs/research/` when it
asks the assistant to record findings), plus its state file under maki's state
directory. While a save is pending it temporarily blocks the assistant's
non-read tool calls until a note lands — that is the "gate". Beads (`bd`) is
optional; without it the file notes carry the loop.

---

# Reference


Persist → gate → compact → restore loop for maki. Structured persistence into
beads plus deliberate compaction at lower context levels — so summarization
never eats the work.

```
directive  agent.stop / mid-turn   context near the persist threshold → one rung-1
                                   directive per epoch (owned channel maki.session.prompt;
                                   in-band tool-denial text as fallback), asking for a
                                   persist of small linked units
persist    tool.*.input            persist-class writes observed (ground truth) + the
                                   end-of-reply `PERSISTED:` marker (armed-unverified alone)
verify     agent.stop / idle       freshness-bound all-or-nothing verification of marker
                                   slugs against the context index (2-attempt retry → loud
                                   abandonment consumes the marker)
fallback   rung 2                  directive ignored → after a backoff, forced compaction
                                   (persist UNVERIFIED, honestly receipted); withheld while
                                   a subagent is running
veto       agent.compact.before    auto-skip veto: compaction while a persist turn is
                                   pending is skipped (bounded, fail-open)
backstop   ladder done + growing   compaction regardless, if the ladder closed and
                                   context keeps growing
restore    CompactionDone          new context epoch: the summary's `PERSIST:` line appended
                                   to the context index, then a continuation wake — only
                                   when the persist field is non-quiet or folds exist;
                                   never after a manual compaction
recover    first message           fresh epochs get the recovery contract (re-read the
                                   context index first; cite freshly read artifacts)
```

## The problem

Normal summarized compaction is lossy. The session continues afterwards — the
harness keeps going regardless — but it continues on thinner context: the
summary keeps the gist and drops the load-bearing detail (the exact next
action, decisions taken, gotchas hit, where a task actually stopped). What is
dropped is gone for good, and you find out later, when the model re-derives
something wrongly or redoes finished work.

Two things make it worse. First, "please persist before compaction" asks the
model to do its best bookkeeping exactly when attention is scarcest — with
nothing checking the answer. Second, the native compaction trigger fires late,
near the window limit, exactly when the summarizer has the least room to
preserve structure.

## The approach

apcc-lite attacks both halves.

**Structured persistence.** Near the threshold the plugin asks — once per
epoch — for the in-flight work to be persisted as small linked units into
beads: notes on the task's existing beads, new issues only for genuinely new
work, each unit with a slug, index rows in a shallow context index as the map,
deep units as docs under `.opencode/context/`. Beads stays the durable,
cross-session store (and is optional — without it the file channel carries the
loop). The answer is verified honestly: freshness bounds and all-or-nothing
slug checks, so a stale or hollow persist is reported `UNVERIFIED` out loud,
never silently counted.

**Compaction at lower context levels.** The threshold and the rung ladder make
compaction happen early and deliberately — at a context level you chose, with
the persist already verified — instead of at the native trigger where you take
what the summarizer gives you. If the directive is ignored, rung 2 forces the
compaction after a backoff and its summary says honestly whether the persist
was verified. Native compactions that would cut a pending persist short are
vetoed. After compaction, a machine-readable `PERSIST:` line lands in the
index, the session wakes, and its first act is to re-read that map — recovery
by citation of freshly read artifacts, not by trusting the summary.

## Honest status

The directive/persist/verification/veto chain and the restore loop
are verified headless and live (log-receipted). The idle fire (`/compact` dispatch on
session idle) and owned-channel pickup of queued prompts are interactive-TUI behavior:
headless `-p` runs cannot dispatch `/compact` and may drop queued prompts when the
run exits. The in-band denial-text fallback is perceivable but stochastic headless —
the owned channel is the primary delivery path. On a 512k-window model the native
compaction trigger sits far above the plugin's hard limit, so the veto is
live-relevant only on smaller windows; compaction at native points still computes
status honestly.

State lives in `<maki state dir>/apcc_lite/state-<sanitized cwd>.json`; the loop's
file channel is `.opencode/context/index.md` (shallow map, never contents) plus unit
destinations (`.opencode/context/session-notes.md`, `docs/research/`).

**Tracking gate:** the plugin is inert unless the project is tracked — a
`.opencode/context/` directory or a `.beads/` directory exists in the project root.

## Install details

The [Quick start](#quick-start-about-5-minutes) is enough for most people; this section explains each part and the headless/CI variant.

Requires **maki ≥ 0.6.0** and a **working default model** (headless: pass
`-m <model id>`; a maki install whose built-in default model was retired
provider-side 404s every turn — see Troubleshooting). One block in your global
`init.lua`:

```lua
maki.pack.add({
  { src = "https://github.com/9thDuck/maki-apcc", name = "apcc-lite", version = "v0.2.0" },
}, { confirm = false, load = true })

maki.setup({
  agent = {
    compaction_instructions = "[apcc] End the summary with a final line 'PERSIST: <one-line recovery note: slugs / exact next action>' or 'PERSIST: none'.",
    post_compaction_instructions = "[apcc] Recovery: re-read .opencode/context/index.md first — it is the map. Pull only the units the current task needs (bd show <id> / read the path). Your first state claim must cite a freshly read artifact, not the summary.",
  },
})
```

Why two calls: `maki.setup` exists **only while init.lua is evaluated** — a pack
module cannot call it at activation or from runtime hooks (verified: the call is
`nil` in both contexts). The pack self-installs and auto-starts, but the two
instruction strings that drive the restore loop must come from init.lua. Copy them
verbatim; the plugin's verification and wake logic parse that exact `PERSIST:` tail.

Notes on the `pack.add` spec:

- `name = "apcc-lite"` is the **recommended identity anchor**: it fixes the pack
  directory (`site/pack/core/apcc-lite/<rev>/`), the `pack-lock.json` key, the
  approvals-store key, and the `/packdel` target. It is **not** load-bearing for
  loading itself — re-verified 2026-10-15 (maki 0.6.0 rig): omitting `name`
  resolves the package as the repo basename (`maki-apcc`) while the entrypoint
  ships as `plugin/apcc-lite.lua`, and the plugin still loads and runs fully
  (persist-event receipts in both configurations). The entrypoint is resolved
  from the `plugin/*.lua` glob, not the package name.
- `confirm` and `load` are **second-argument opts** of `maki.pack.add`, not spec
  fields — putting them inside the spec table crashes init.lua with
  `pack.add spec: unknown field "load"`. `confirm = false` skips the interactive
  "Apply these package changes?" prompt (needed for headless/CI installs);
  `load = true` activates the package after install.
- `version` pins the pack: a tag (`v0.2.0`) or a branch (`main`) both resolve once
  and the **resolved rev is pinned in `pack-lock.json`** — pack.add never chases
  the source HEAD afterwards. Delete the lockfile to force re-resolution.

**First activation asks one interactive permission approval** for the plugin's
grants (`fs_read`, `fs_write`, `net`, `run`, `env` — apcc wraps agent.* slots,
which cost every permission). The prompt looks like
`Allow package apcc-lite these permissions: …? [y/N]`. Run maki once in a
terminal and approve; the decision is saved (`pack-approvals.json` in the
**data** dir, keyed by name + src + permissions) and every later run —
including headless `-p` — loads the pack without prompting.

### Headless / CI recipe

`maki -p` runs init.lua and `pack.add` (fetch → install → lockfile → approval
check → entrypoint) but cannot answer the approval prompt, and `require("apcc_lite")`
does **not** resolve in a fresh home (pack module names register outside the init
eval — verified on maki 0.6.0). The verified headless pattern (this is exactly what
`scripts/smoke.sh` does): install with `load = true` (the pack auto-starts),
pre-grant the approvals file, tune via env opts:

```lua
maki.pack.add({
  { src = "https://github.com/9thDuck/maki-apcc", name = "apcc-lite", version = "v0.2.0" },
}, { confirm = false, load = true })

maki.setup({
  agent = {
    compaction_instructions = "[apcc] End the summary with a final line 'PERSIST: <one-line recovery note: slugs / exact next action>' or 'PERSIST: none'.",
    post_compaction_instructions = "[apcc] Recovery: re-read .opencode/context/index.md first — it is the map. Pull only the units the current task needs (bd show <id> / read the path). Your first state claim must cite a freshly read artifact, not the summary.",
  },
})
```

and the approval grant, written before the first run
(`<data dir>/maki/site/pack-approvals.json`, where `<data dir>` is
`$XDG_DATA_HOME` or `~/.local/share`; `src` is the same string passed to
`pack.add`):

```json
{
  "entries": {
    "apcc-lite": {
      "src": "https://github.com/9thDuck/maki-apcc",
      "permissions": ["fs_read", "fs_write", "net", "run", "env"]
    }
  }
}
```

**Kill switch:** `APCC_LITE=0` in the environment.

## Options

Pack installs take options from the environment (a pack module loads after
init.lua, so `setup()` opts are unreachable there):

| env var                 | values              | default | meaning                                                          |
|-------------------------|---------------------|---------|------------------------------------------------------------------|
| `APCC_THRESHOLD_TOKENS` | positive integer    | derived | absolute persist-trigger threshold in tokens                     |
| `APCC_POST_PERSIST`     | `compact`, `fresh`  | `compact`| idle fire compacts in place, or hands off to a brand-new session |
| `APCC_BEADS`            | `true`, `false`     | (auto)  | force beads capability on/off (default: probe `bd` on PATH)      |
| `APCC_LITE`             | `0`/`false`         | —       | disable the plugin entirely                                      |

`APCC_THRESHOLD_TOKENS` overrides the derived threshold; the recommended operating
point is an **absolute** value (`persist_trigger_tokens = 135000` in the author's
512k-window live config) — model-independent, clamped internally so it can never
fire past the compaction point minus headroom. Unset, the threshold derives from
the window (`threshold_ratio` — model-dependent by nature).

Vendoring (copy the file to `~/.config/maki/lua/apcc_lite.lua` and `require` it)
unlocks the full `setup()` opts table:

| opt                     | default        | meaning                                                                 |
|-------------------------|----------------|-------------------------------------------------------------------------|
| `enabled`               | `true`         | master switch                                                           |
| `persist_trigger_tokens`| `0` (derived)  | absolute rung-1 trigger; 0 = derive from `threshold_ratio`              |
| `threshold_ratio`       | `0.6`          | derived threshold = ratio × context window                              |
| `hard_limit_tokens`     | `0` (derived)  | rung-2 forced-compaction line; 0 = threshold + 40k, then **capped at `0.8·window − 10k`** so a forced compaction always wins the race against maki's native 20%-buffer auto-compact (on a 129k window: cap 93.4k; the native proactive trigger sits at ~72.9k) |
| `post_persist`          | `"compact"`    | idle fire: compact in place, or `"fresh"` handoff (event-verified only) |
| `beads`                 | `"auto"`       | `true` / `false` / `"auto"` (probe `bd` on PATH, memoized lazily)       |
| `floor_tokens`          | `"auto"`       | marker floor = threshold − 1 (carry-forward below floor); `0`/`false` = kill switch; n = explicit |
| `floor_wobble_tokens`   | `10000`        | directive-armed meter wobble band                                       |
| `enforced_fallback`     | `true`         | rung 2 on at all (opencode default ON)                                  |
| `nudge_backoff_ms`      | `600000`       | rung 1 → rung 2 escalation delay                                        |
| `retry_window_ms`       | `60000`        | minimum spacing between compaction attempts paired to one marker        |
| `attempt_cap`           | `3`            | compaction attempts paired to one marker                                |
| `utterance_ring_max`    | `12`           | owner-utterance ring depth (memory-only)                                |
| `utterance_text_cap`    | `1500`         | per-utterance text cap                                                  |
| `fold_text_cap`         | `500`          | fold display cap (owner prompts folded while a directive is latched)    |

The module auto-starts on require with default/env opts; set the global
`APCC_NO_AUTOSTART = true` before require for explicit control.

## Dependencies

- **maki ≥ 0.6.0** — the only hard dependency.
- **beads (`bd`) is optional.** With beads, persists go through `bd create/update`
  and recovery references `bd show <id>` (durable, cross-session units). Install
  beads separately ([beads](https://github.com/steveyegge/beads)) and keep it on
  PATH. Without it, every model-facing text drops its bd mentions and the file
  channel alone carries the loop (`.opencode/context/` files); the plugin never
  requires and never installs beads — it degrades gracefully and logs one WARN.

## The marker contract

End a persist reply with, as its **last non-empty line** (outside an unbalanced code
fence):

```
NEXT: <one-line next action>        ← optional, feeds the continuation brief
PERSISTED: <n> units (<slugs>)      ← or: PERSISTED: none (never arms)
```

`PERSISTED: none` acknowledges without arming. Marker slugs are verified
**all-or-nothing** against the context index table (a 2-attempt retry window, then
a loud abandonment consumes the marker — nothing silently half-recovers). A marker
with no observed persist-class writes still arms, but flagged **unverified** — the
compaction summary then says so honestly, and `fresh` mode refuses to hand off on
it. An optional `NEXT:` line right above the marker becomes the continuation brief
in the post-compaction wake and in fresh-session handoffs.

## Modes

- `compact` (default): verified/armed persist + idle → `/compact` in place. After
  the compaction the plugin appends the `PERSIST:` row to the context index and
  **wakes the session automatically** (`maki.session.notify` with `wake = true`) —
  but only when the persist field is non-quiet or folds exist; a manual compaction
  is never woken after.
- `fresh`: armed persist + idle → a **new session** is spawned with a handoff prompt
  (recovery map + `NEXT:` brief); the old session stays intact in `/sessions`. Fresh
  hands off only on **event-verified** persists (observed persist-class writes); a
  marker-only arm falls back to compaction, because a hollow handoff would recover
  from nothing. Cost: one `/sessions` row per cycle.

## TUI vs headless

| behavior                          | interactive TUI | headless `-p`                          |
|-----------------------------------|-----------------|----------------------------------------|
| rung-1 directive (owned channel)  | ✓               | — (in-band denial-text fallback, stochastic perception) |
| persist-event observation         | ✓               | ✓                                       |
| marker capture + verification     | ✓               | ✓                                       |
| rung-2 enforced fallback          | ✓               | ✓ (via `APCC_TEST_FIRE` seam at stop)   |
| native window-overflow compaction + veto | ✓        | ✓ (`agent.compact.before` fires)        |
| idle fire (`/compact` on idle)    | ✓               | ✗ (dispatch fails without a UI)         |
| owned-channel pickup of queued prompts | ✓          | ✗ (queued prompts can be lost at exit)  |
| CompactionDone → index row → wake | ✓               | ✓ via seam; real wake needs a UI        |
| fresh-session handoff             | ✓               | ✗                                       |
| pack install + entrypoint execution | ✓             | ✓ (`confirm = false`)                   |
| first-activation approval         | ✓               | ✗ (pre-seed or run once interactively)  |

## Troubleshooting

- **Every turn fails with `API error (404) … no longer supported`** (TUI shows
  an agent error per prompt; the pack is loaded and innocent). maki's built-in
  default model was retired provider-side — no agent turn can run until you
  pass `-m <model id>` or configure a default model in maki.
- **Nothing loads, no errors anywhere.** Silent-drop phases: (1) entrypoint /
  init.lua-phase `maki.log.*` lines are dropped — the log sink attaches when an
  agent run starts, so a correctly loaded pack looks quiet at startup; (2) a
  declared-but-inactive package (`load` not `true`) logs nothing. Verify liveness
  via runtime effects (state file, persist-event log lines), never startup logs.
  (A name↔filename mismatch — spec `name` vs the `plugin/*.lua` filename — is
  NOT a failure on maki >= 0.6.0: the entrypoint is glob-resolved and the
  mismatched pack still loads; verified 2026-10-15. A `plugin/` dir with no
  `.lua` file at all fails loudly with `has no plugin/*.lua entrypoint`.)
- **Pack fails to load in headless with a permission error.** The approvals store
  (`pack-approvals.json` in the **data** dir — `~/.local/share/maki/site/`, not
  config) is keyed by name + src + permissions; renaming the package or changing
  the src path re-triggers approval. maki does not authenticate the file's writer:
  a hand-written grant with the correct schema is honored (this is exactly how the
  headless/CI recipe above pre-grants — verified), and a malformed one is ignored
  with a stderr warning (`permission approval is required for …`).
- **Source edits don't take effect.** maki installs packs to
  `site/pack/core/<name>/<rev>/` — a locked rev never chases the source HEAD.
  Delete `~/.config/maki/pack-lock.json` to force re-resolution, or bump
  `version`. `/reload` re-reads config and plugins; a cold restart is needed for
  some config changes (e.g. window size).
- **Lua edits break maki at startup.** There is no standalone lua on the host; the
  syntax check IS a headless `-p` run (`maki --yolo -p "Reply with exactly: OK"`,
  then grep the log for lua errors). Always load-test before calling an edit done.

## Plugin-author notes (learned the hard way)

- **`maki.setup` is init.lua-eval-scoped.** It is `nil` at pack activation and in
  runtime slots — a pack cannot set `compaction_instructions` itself (verified with
  file-oracle probe packs in both contexts). Instructions must come from init.lua.
- **Entrypoint/init-phase `maki.log.*` lines are silently dropped** — the log sink
  attaches when an agent run starts. A correctly loaded pack looks completely quiet
  at startup; verify liveness via runtime effects, not startup logs.
- **`maki.fs` writes yield** (`mkdir`, `atomic_write`) — calling them during
  activation (inside the wrapped entrypoint/init chain) dies with "yield across
  metamethod/C-call boundary". Write files from runtime slots/autocmds only.
- **Never call `maki.fn.*` on the plugin-load path** — host roundtrips there hang
  `/reload` with zero log trace. Probe lazily on first use (this plugin memoizes its
  `bd` probe on the first text build).
- A shipped `plugin.toml` must exist and name permissions explicitly; wrapping
  `agent.*` slots costs every permission, so the honest grant set is the full one.
- A package must ship a `plugin/*.lua` **entrypoint** — it is executed on
  activation. A bare `lua/` module with no entrypoint fails to load with
  `has no plugin/*.lua entrypoint`.
- Headless runs (`maki --yolo -p`) DO run user `init.lua` and `maki.pack.add`
  (fetch + install + lockfile all work headless with `confirm = false`), and a
  `load = true` pack entrypoint does execute headless. What headless cannot do:
  answer the one-time pack permission approval, dispatch `/compact`, or guarantee
  owned-channel pickup of queued prompts.
- Dev/test seams: `APCC_TEST_FIRE=1` (idle-chain fire at `agent.stop` — the TUI idle
  path is unreachable headless) and `APCC_TEST_BACKOFF_MS` (compress the rung-2
  backoff). `maki.log` timestamps are UTC.
- `agent.compaction_buffer` is inert at runtime — both `"60%"` and numeric forms
  are accepted by `maki.setup` but leave the native trigger unmoved. Do not rely
  on it; the plugin's hard-limit cap math handles the race instead.

## Verification (v9, log-receipted)

- Rung-1 directive once per epoch (mid-turn net = block first non-read tool call;
  stop-after-persist text), none-reply ladder close, rung-2 enforced fallback +
  dispatch-failure escalation queue, prohibition latch withholding rung 2, floor
  carry-forward (armed survives sub-floor idle), verification retry window,
  backstop, fold capture — all headless-tested via the `APCC_TEST_FIRE` seam.
- Live full cycle: nudge at threshold → persist events → armed (event-verified) →
  idle `/compact` → compaction → epoch bump → `PERSIST` row appended →
  `auto-continue: resume wake dispatched` → agent run started with `message_len: 0`
  (no user prompt). Recovery prefix, fresh handoff, and `NEXT:` capture verified
  live. Log lines: `persist event #n`, `persist marker …`,
  `auto-continue: resume wake dispatched`, `fresh handoff: new session <id> spawned`.
