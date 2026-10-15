# Token math: with and without apcc

This is a **model**, not a measurement. It shows why compacting early saves input
tokens, and roughly how much, for one made-up but realistic workload. Your numbers
will differ; the method is here so you can plug in your own.

## The idea

Every turn sends the whole current context to the model as input. Total input over
a task is the sum of the context size at every turn — the area under the
context-size curve. Without early compaction the context keeps growing toward the
model's window. With apcc it is compacted at a threshold you choose, so it stays low.

## Assumptions

| Input | Value | Source |
|---|---|---|
| Model pricing | input $0.15, cached input $0.04, output $0.50 per million tokens | GLM-5.3-Flash on synthetic.new, pricing page as of 2026-10-16 |
| Window | 512k (524,288 tokens) | same page |
| Turns | 300 | assumption |
| Starting context | 15,000 tokens | assumption |
| Growth | 1,700 new tokens per turn (tool output + replies), so turn 300 sits at 523,300 — right at the window | assumption |
| Output | 600 tokens per turn, same in both cases | assumption |
| Caching | everything except the newest 1,700 tokens is a cache hit; the first turn after a compaction is a full cache miss | assumption (best case for caching) |
| apcc threshold | 135,000 | example setting |
| After compaction | context restarts at 27,000 (15k base + summary, plus a 12k re-read of saved notes, carried on every later turn) | assumption |
| Compaction cost (apcc) | per compaction: one extra persist turn (reads ~135.8k cached, writes 3k) + the compaction call (reads ~135.8k cached, writes a 1.5k summary) | assumption |
| Cache-write fee | none | none listed on the pricing page |

## Baselines

Four baselines, because "no compaction at all" is not what maki does, and maki can
be told to compact earlier without apcc:

- **maki default**: auto-compaction fires at the window minus a 20% buffer,
  ~419,430 on a 524,288 window, restarting at ~15k (one compaction call reads the
  context from cache and writes a 1.5k summary). The 20% default is from
  [maki's configuration docs](https://maki.sh/docs/configuration)
  (`agent.compaction_buffer`); that page does **not** say exactly when
  auto-compaction triggers or how big the summary is, so the trigger point and the
  1.5k summary are **inferred**, not documented.
- **maki tuned to 135k**: the same, but `agent.compaction_buffer` set so it
  compacts at ~135k, restarting at ~15k. Whether the setting moves maki's trigger at
  runtime is untested here; this row assumes it does.
- **maki tuned + same 12k notes re-read**: tuned maki, plus the same 12k of notes
  re-read after every compaction via `post_compaction_instructions` (restart at 27k,
  like apcc) — the closest no-plugin equivalent.
- **Never compacts** (an upper bound only): the context climbs to 523,300.

## Without apcc — never compacts (upper bound)

Context at turn *t* (t = 0…299) is 15,000 + 1,700·t. No compaction happens.

- Total input = 300 × 15,000 + 1,700 × (299 × 300 / 2) = 4,500,000 + 76,245,000 = **80,745,000**
- Uncached = 15,000 (first turn) + 299 × 1,700 (new tokens each later turn) = 523,300
- Cached = 80,745,000 − 523,300 = 80,221,700

Cost:

- cached 80.2217M × $0.04 = $3.2089
- uncached 0.5233M × $0.15 = $0.0785
- output 0.18M × $0.50 = $0.0900
- **Total $3.38**

## With apcc

Compaction triggers when the context would pass 135,000. Starting at 15,000 that
takes 71 turns; restarting at 27,000 it takes 64. In 300 turns: 71 + 64 + 64 + 64 +
37, i.e. **4 compactions**.

Total input across the stretches:

- 71 turns from 15k: 71 × 15,000 + 1,700 × (70 × 71 / 2) = 5,289,500
- 3 × 64 turns from 27k: 3 × (64 × 27,000 + 1,700 × (63 × 64 / 2)) = 15,465,600
- 37 turns from 27k: 37 × 27,000 + 1,700 × (36 × 37 / 2) = 2,131,200
- **Total 22,886,300**

Uncached (first turn of each stretch in full, then 1,700 per turn):
134,000 + 3 × 134,100 + 88,200 = 624,500. Cached = 22,261,800.

Compaction overhead: 4 × (2 × ~135.8k cached reads) = 1,086,200 cached input, plus
4 × 4,500 = 18,000 output.

Cost:

- cached 22.2618M × $0.04 = $0.8905
- uncached 0.6245M × $0.15 = $0.0937
- output 0.18M × $0.50 = $0.0900
- compaction 1.0862M × $0.04 + 0.018M × $0.50 = $0.0524
- **Total $1.13**

## Without apcc — maki default compaction

Same 300 turns. Context reaches 419,430 at turn ~238, compacts once, restarts at 15k.
Total input 56.1M tokens, **$2.39** (cached) / $8.50 (no cache). Computed with the same
method as the other cases.

## Without apcc — maki tuned to 135k

Same stretches as apcc's first one, but restarting at 15k (no notes) and with only
the compaction call as overhead (no persist turn): 22.1M input tokens, **$1.04**
(cached) / $3.41 (no cache). Adding the same 12k notes re-read after each
compaction (restart at 27k): 23.4M, **$1.10** / $3.61.

## Result

| 300 turns | Never compacts (bound) | maki default | maki tuned to 135k | maki tuned + 12k notes re-read | apcc at 135k |
|---|---|---|---|---|---|
| Input tokens processed | 80.7M | 56.1M | 22.1M | 23.4M | 24.0M |
| Cost, caching on | $3.38 | $2.39 | $1.04 | $1.10 | $1.13 |
| Cost, no caching | $12.20 | $8.50 | $3.41 | $3.61 | $3.69 |

Said plainly:

- **Against maki default**, apcc is about 57% fewer input tokens and ~53% cheaper.
  That saving comes from **compacting earlier**, not from apcc as such.
- **Against maki tuned to the same trigger**, apcc costs about **$0.03–0.09 more**
  per 300-turn task (~3–9% more input tokens: 24.0M vs 23.4M–22.1M). That is the
  price of the persist turn and the re-read notes.
- Tuning the trigger alone gets you all of the saving; apcc keeps about 94% of it
  ((56.1 − 24.0) / (56.1 − 22.1)).
- **Below ~70 turns** (before the context first reaches 135k) there is no saving.
- The 67–70% figures only apply against the never-compacts upper bound.

**Persist break-even.** apcc's extra over tuned maki is ~1.9M tokens
(24.0M − 22.1M), about 475k per compaction. Near the trigger a turn costs ~135k
input, so the saved notes pay for themselves if they prevent about **3.5 wasted
turns per compaction** (re-exploring, redoing finished work). How many they really
prevent is **unmeasured**.

This is a model: the assumptions (growth per turn, summary size, notes size,
caching, where maki really triggers) drive the result.

## What this does not model

- **Quality.** It is a cost model only. It does not claim the agent works better, or
  worse, at 135k versus 400k context, nor that early compaction loses less.
- **Note quality.** apcc verifies that the claimed note slugs exist in
  `.opencode/context/index.md`, not that the notes are good. Savings are only worth it
  if the saved notes carry what the task needs after compaction.
- Output and growth per turn are flat assumptions; real tasks vary.

## What moves the answer

| If… | Then |
|---|---|
| the task is short (ends before the threshold, ~70 turns here) | no saving; you pay the persist overhead |
| your harness already compacts early on its own (e.g. maki with `compaction_buffer` tuned) | the saving vanishes; apcc costs a few percent more |
| the cache misses (idle gaps, expiry) | the "without" cost rises more, so the saving grows |
| saved notes / re-reads are bigger than 12k | the saving shrinks a little |
| the provider charges for cache writes | apcc, which rebuilds the cache more often, pays a bit more |

## Doing it for your own setup

Pick your price per million tokens (input, cached, output), starting context *B*,
growth per turn *g*, turns *N*, and threshold *T*. Without compaction, total input is
N·B + g·N(N−1)/2. With apcc, split the turns into stretches that each end when the
context reaches *T*, sum each stretch the same way, and add the compaction cost.
