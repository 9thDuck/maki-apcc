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

## Without apcc

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

## Result

| | Without | With apcc |
|---|---|---|
| Input tokens processed | 80.7M | 24.0M |
| Average context per turn | ~269k | ~76k |
| Cost, caching on | $3.38 | $1.13 (−67%) |
| Cost, no caching (all input at $0.15) | $12.20 | $3.69 (−70%) |

The four compactions cost about $0.05 together — small next to what they avoid.

## What moves the answer

| If… | Then |
|---|---|
| the task is short (ends before the threshold, ~70 turns here) | no saving; you pay the persist overhead |
| your harness already compacts early on its own | the "without" cost drops, so the saving shrinks |
| the cache misses (idle gaps, expiry) | the "without" cost rises more, so the saving grows |
| saved notes / re-reads are bigger than 12k | the saving shrinks a little |
| the provider charges for cache writes | apcc, which rebuilds the cache more often, pays a bit more |

## Doing it for your own setup

Pick your price per million tokens (input, cached, output), starting context *B*,
growth per turn *g*, turns *N*, and threshold *T*. Without compaction, total input is
N·B + g·N(N−1)/2. With apcc, split the turns into stretches that each end when the
context reaches *T*, sum each stretch the same way, and add the compaction cost.
