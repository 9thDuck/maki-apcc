import test from "node:test"
import assert from "node:assert/strict"
import fs from "node:fs"
import os from "node:os"
import path from "node:path"
import {
  learnedReserve,
  parseTokenCount, resolveThreshold, resolveWindow, lastMainContextTokens, parseMarker, decideNudge, freshSession,
  newEpoch, persistStatus, nudgeText, recoveryText, tailLines, handle, stateFile, ownerMessages, recentOwnerWords, ownerWordsMarkdown, ownerWordsFile, DEFAULT_THRESHOLD_TOKENS, REARM_TOKENS, REARM_MS,
} from "./apcc.mjs"

const asst = (usage, extra = {}) => JSON.stringify({ type: "assistant", message: { usage }, ...extra })

test("parseTokenCount handles k/M suffixes and junk", () => {
  assert.equal(parseTokenCount("200k"), 200_000)
  assert.equal(parseTokenCount("1M"), 1_000_000)
  assert.equal(parseTokenCount(150000), 150_000)
  assert.equal(parseTokenCount("0"), 0)
  assert.equal(parseTokenCount("abc"), 0)
  assert.equal(parseTokenCount(undefined), 0)
})

test("threshold: env override, compaction point (window - 33k reserve) minus 25k headroom, default", () => {
  assert.equal(resolveThreshold({ APCC_PERSIST_THRESHOLD_TOKENS: "90000" }, {}), 90_000)
  assert.equal(resolveThreshold({}, { autoCompactWindow: 170000 }), 122_000)
  assert.equal(resolveThreshold({}, { autoCompactWindow: 100000 }), 52_000)
  assert.equal(resolveThreshold({}, { autoCompactWindow: 200000 }), 152_000)
  assert.equal(resolveThreshold({ CLAUDE_CODE_AUTO_COMPACT_WINDOW: "300000" }, { autoCompactWindow: 200000 }), 252_000)
  assert.equal(resolveThreshold({}, { autoCompactWindow: 160000 }, 40_000), 105_000) // learned reserve wins when larger
  assert.equal(resolveThreshold({}, { autoCompactWindow: 160000 }, 10_000), 112_000) // never below the default reserve
  assert.equal(resolveThreshold({}, {}), DEFAULT_THRESHOLD_TOKENS)
})

test("context meter sums input+cache+output of the LAST main-chain assistant turn", () => {
  const t = [
    asst({ input_tokens: 10, cache_read_input_tokens: 1000, cache_creation_input_tokens: 0, output_tokens: 5 }),
    asst({ input_tokens: 9, cache_read_input_tokens: 99999, cache_creation_input_tokens: 1, output_tokens: 1 }, { isSidechain: true }),
    asst({ input_tokens: 20, cache_read_input_tokens: 2000, cache_creation_input_tokens: 300, output_tokens: 80 }),
    JSON.stringify({ type: "user", message: {} }),
  ].join("\n")
  assert.equal(lastMainContextTokens(t), 20 + 2000 + 300 + 80)
})

test("context meter tolerates a torn first line and empty input", () => {
  assert.equal(lastMainContextTokens('{"type":"assi\n' + asst({ input_tokens: 5, output_tokens: 5 })), 10)
  assert.equal(lastMainContextTokens(""), 0)
})

test("marker is end-anchored and ignores quoted grammar", () => {
  assert.deepEqual(parseMarker("done\n\nPERSISTED: 3 units (a, b, c)"), { kind: "persisted", manual: false, units: 3 })
  assert.deepEqual(parseMarker("ok\nPERSISTED (manual): 1 unit (x)\n"), { kind: "persisted", manual: true, units: 1 })
  assert.equal(parseMarker("PERSISTED: none").kind, "acknowledged")
  assert.equal(parseMarker("PERSISTED: 2 units (a)\nand then more text").kind, "none") // not the last line
  assert.equal(parseMarker("see:\n```\nPERSISTED: 2 units (a)").kind, "none") // inside an unbalanced fence
  assert.equal(parseMarker("```\nPERSISTED: 2 units (a)\n```").kind, "none") // last line is the fence
  assert.equal(parseMarker("I will write PERSISTED: 2 units later").kind, "none")
  assert.equal(parseMarker("PERSISTED: 0 units").kind, "acknowledged")
  assert.equal(parseMarker(undefined).kind, "none")
})

test("nudge decision: once per epoch, one final reminder, never after persist", () => {
  const th = 100_000
  let st = freshSession(0)
  assert.equal(decideNudge({ tokens: 99_999, threshold: th, st, now: 0 }), null)
  assert.equal(decideNudge({ tokens: 100_000, threshold: th, st, now: 0 }), 1)
  st = { ...st, nudges: 1, lastNudgeAt: 0, lastNudgeTokens: 100_000 }
  assert.equal(decideNudge({ tokens: 100_500, threshold: th, st, now: 1000 }), null) // backoff
  assert.equal(decideNudge({ tokens: 100_000 + REARM_TOKENS, threshold: th, st, now: 1000 }), 2) // grew
  assert.equal(decideNudge({ tokens: 100_500, threshold: th, st, now: REARM_MS }), 2) // waited
  st = { ...st, nudges: 2 }
  assert.equal(decideNudge({ tokens: 500_000, threshold: th, st, now: 10 * REARM_MS }), null) // capped
  st = { ...freshSession(0), persistedEpoch: 0, units: 2 }
  assert.equal(decideNudge({ tokens: 500_000, threshold: th, st, now: 0 }), null) // already persisted
  assert.equal(decideNudge({ tokens: 500_000, threshold: 0, st: freshSession(0), now: 0 }), null) // disabled
})

test("epoch resets persist state; status is honest", () => {
  let st = { ...freshSession(0), persistedEpoch: 0, units: 3, nudges: 2 }
  assert.equal(persistStatus(st), "DONE")
  st = newEpoch(st)
  assert.equal(st.epoch, 1)
  assert.equal(st.nudges, 0)
  assert.equal(persistStatus(st), "NOT DONE")
  assert.match(persistStatus({ ...freshSession(0), persistedEpoch: 0, units: 0 }), /NOT NEEDED/)
})

test("texts stay under the 10k additionalContext cap and carry the contract", () => {
  const n = nudgeText({ tokens: 140_000, threshold: 135_000, which: 1 })
  assert.match(n, /PERSISTED: <n> units/)
  assert.match(n, /bd note/)
  assert.ok(n.length < 3000)
  const huge = "x".repeat(50_000)
  const r = recoveryText({ source: "compact", st: freshSession(0), indexTail: huge, tokensBefore: 150_000 })
  assert.ok(r.length <= 9000)
  assert.match(recoveryText({ source: "compact", st: freshSession(0), indexTail: "", tokensBefore: 0 }), /Persist status before compaction: NOT DONE/)
  assert.match(recoveryText({ source: "compact", st: { ...freshSession(0), persistedEpoch: 0, units: 2 }, indexTail: "", tokensBefore: 0 }), /: DONE/)
  assert.equal(tailLines("a\n\nb\nc\nd", 2), "c\nd")
})

// ---- end to end through handle() with a real temp project, transcript, and state dir ----

function rig({ tokens, tracked = true } = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "apcc-"))
  const proj = path.join(root, "proj")
  fs.mkdirSync(path.join(proj, tracked ? ".beads" : "src"), { recursive: true })
  const transcript = path.join(root, "t.jsonl")
  const setTokens = (n) => fs.writeFileSync(transcript, asst({ input_tokens: n, output_tokens: 0 }) + "\n")
  setTokens(tokens ?? 0)
  const env = { CLAUDE_PROJECT_DIR: proj, APCC_CC_STATE_DIR: path.join(root, "state"), CLAUDE_CONFIG_DIR: path.join(root, "cfg"), APCC_PERSIST_THRESHOLD_TOKENS: "100000" }
  const input = (extra = {}) => ({ session_id: "s1", transcript_path: transcript, cwd: proj, hook_event_name: "UserPromptSubmit", ...extra })
  return { root, proj, env, input, setTokens }
}

test("e2e: below threshold is silent; crossing nudges once; persisted marker silences", () => {
  const r = rig({ tokens: 50_000 })
  assert.equal(handle("nudge", r.input(), r.env, 1000), null)
  r.setTokens(120_000)
  const first = handle("nudge", r.input(), r.env, 2000)
  assert.match(first.hookSpecificOutput.additionalContext, /Persist now/)
  assert.equal(first.hookSpecificOutput.hookEventName, "UserPromptSubmit")
  assert.equal(handle("nudge", r.input({ hook_event_name: "PostToolUse" }), r.env, 3000), null) // backoff
  const stop = handle("stop", r.input({ last_assistant_message: "saved.\nPERSISTED: 2 units (a, b)" }), r.env, 4000)
  assert.match(stop.systemMessage, /2 unit\(s\) persisted/)
  r.setTokens(125_000)
  assert.equal(handle("nudge", r.input(), r.env, 9_999_999), null) // persisted just now
  r.setTokens(300_000)
  assert.match(handle("nudge", r.input(), r.env, 9_999_999).hookSpecificOutput.additionalContext, /Persist now/) // that persist is stale
})

test("e2e: ignored nudge gets exactly one final reminder", () => {
  const r = rig({ tokens: 120_000 })
  assert.ok(handle("nudge", r.input(), r.env, 0))
  r.setTokens(140_000)
  const second = handle("nudge", r.input(), r.env, 1000)
  assert.match(second.hookSpecificOutput.additionalContext, /Final reminder/)
  r.setTokens(400_000)
  assert.equal(handle("nudge", r.input(), r.env, 99_999_999), null)
})

test("e2e: subagent calls, untracked projects, kill switch and missing session are inert", () => {
  const r = rig({ tokens: 500_000 })
  assert.equal(handle("nudge", r.input({ agent_id: "sub-1" }), r.env, 0), null)
  assert.equal(handle("nudge", r.input(), { ...r.env, APCC_CC: "0" }, 0), null)
  assert.equal(handle("nudge", { ...r.input(), session_id: undefined }, r.env, 0), null)
  const u = rig({ tokens: 500_000, tracked: false })
  assert.equal(handle("nudge", u.input(), u.env, 0), null)
})

test("e2e: compact restore reports the honest status and re-arms the next epoch", () => {
  const r = rig({ tokens: 120_000 })
  fs.mkdirSync(path.join(r.proj, ".opencode", "context"), { recursive: true })
  fs.writeFileSync(path.join(r.proj, ".opencode", "context", "index.md"), "| 2026-10-01 | slug-a | bd note x | did a thing |\n")
  handle("nudge", r.input(), r.env, 0) // nudged, NOT persisted
  assert.equal(handle("precompact", r.input({ hook_event_name: "PreCompact", trigger: "auto", context_tokens_before: 130_000 }), r.env, 1000), null)
  const rec = handle("restore", r.input({ hook_event_name: "SessionStart", source: "compact" }), r.env, 2000)
  const ctx = rec.hookSpecificOutput.additionalContext
  assert.match(ctx, /Persist status before compaction: NOT DONE/)
  assert.match(ctx, /slug-a/)
  assert.match(ctx, /~130k tokens/)
  // new epoch: crossing the threshold again nudges again
  r.setTokens(130_000)
  assert.ok(handle("nudge", r.input(), r.env, 3000))
})

test("e2e: compaction that SessionStart never announced is detected by the meter drop", () => {
  const r = rig({ tokens: 130_000 })
  assert.ok(handle("nudge", r.input(), r.env, 0))
  handle("stop", r.input({ last_assistant_message: "PERSISTED: 1 unit (a)" }), r.env, 10)
  r.setTokens(20_000)
  handle("nudge", r.input(), r.env, 20) // meter fell off a cliff -> new epoch
  r.setTokens(130_000)
  assert.ok(handle("nudge", r.input(), r.env, 30))
})

test("e2e: resume of a big stale session warns the user, small ones stay quiet", () => {
  const r = rig({ tokens: 0 })
  const big = handle("restore", r.input({ hook_event_name: "SessionStart", source: "resume", prompt_cache_likely_expired: true, context_tokens: 182_000, seconds_since_last_response: 5400, estimated_cache_write_usd: 1.14 }), r.env, 0)
  assert.match(big.systemMessage, /cache expired/)
  assert.match(big.systemMessage, /\$1\.14/)
  assert.equal(handle("restore", r.input({ source: "resume", prompt_cache_likely_expired: true, context_tokens: 10_000 }), r.env, 0), null)
  assert.equal(handle("restore", r.input({ source: "startup" }), r.env, 0), null)
})

test("e2e: precompact never blocks (no decision, no output)", () => {
  const r = rig({ tokens: 0 })
  assert.equal(handle("precompact", r.input({ trigger: "manual" }), r.env, 0), null)
})

test("e2e: warns once when context is past the configured window with no compaction", () => {
  const r = rig({ tokens: 200_000 })
  fs.mkdirSync(r.env.CLAUDE_CONFIG_DIR, { recursive: true })
  fs.writeFileSync(path.join(r.env.CLAUDE_CONFIG_DIR, "settings.json"), JSON.stringify({ autoCompactWindow: 170000 }))
  const env = { ...r.env, APCC_PERSIST_THRESHOLD_TOKENS: "135000" }
  const first = handle("nudge", r.input(), env, 0)
  assert.match(first.systemMessage, /past your auto-compact window \(170k\)/)
  assert.match(first.systemMessage, /\/autocompact 170k/)
  assert.match(first.hookSpecificOutput.additionalContext, /Persist now/) // nudge still delivered alongside
  r.setTokens(210_000)
  const second = handle("nudge", r.input(), env, 20 * 60 * 1000)
  assert.equal(second.systemMessage, undefined) // warned once per epoch
  const inside = rig({ tokens: 160_000 })
  fs.mkdirSync(inside.env.CLAUDE_CONFIG_DIR, { recursive: true })
  fs.writeFileSync(path.join(inside.env.CLAUDE_CONFIG_DIR, "settings.json"), JSON.stringify({ autoCompactWindow: 170000 }))
  assert.equal(handle("nudge", inside.input(), { ...inside.env, APCC_PERSIST_THRESHOLD_TOKENS: "135000" }, 0).systemMessage, undefined)
})

test("e2e: stop message says nothing was compacted", () => {
  const r = rig({ tokens: 150_000 })
  const msg = handle("stop", r.input({ last_assistant_message: "x\nPERSISTED: 2 units (a, b)" }), r.env, 0).systemMessage
  assert.match(msg, /NOT compacted/)
})

test("delta persist: once, only after a persist, right at the window", () => {
  const st = { ...freshSession(0), persistedEpoch: 0, units: 2 }
  const base = { threshold: 102_000, compactAt: 127_000, st, now: 0 }
  assert.equal(decideNudge({ ...base, tokens: 110_000 }), null)
  assert.equal(decideNudge({ ...base, tokens: 120_000 }), 3)
  assert.equal(decideNudge({ ...base, tokens: 120_000, st: { ...st, deltaEpoch: 0 } }), null)
  assert.equal(decideNudge({ ...base, tokens: 120_000, compactAt: 0 }), null)
})

test("meter: no reading between a compact boundary and the next assistant turn", () => {
  const u = { input_tokens: 1, cache_read_input_tokens: 250_000, cache_creation_input_tokens: 0, output_tokens: 1 }
  const boundary = JSON.stringify({ type: "system", subtype: "compact_boundary" })
  const user = JSON.stringify({ type: "user", message: { role: "user", content: "summary" } })
  assert.equal(lastMainContextTokens([asst(u), boundary, user].join("\n")), 0)
  assert.equal(lastMainContextTokens([asst(u), boundary, user, asst({ ...u, cache_read_input_tokens: 20_000 })].join("\n")), 20_002)
})

const boundary = (ts, trigger, preTokens) => JSON.stringify({ type: "system", subtype: "compact_boundary", timestamp: ts, compactMetadata: { trigger, preTokens } })

test("the host reserve is learned per window as a median, from transcript compact_boundary records only", () => {
  const r = rig({ tokens: 10_000 })
  const env = { ...r.env, CLAUDE_CODE_AUTO_COMPACT_WINDOW: "160000" }
  delete env.APCC_PERSIST_THRESHOLD_TOKENS
  const samples = () => JSON.parse(fs.readFileSync(stateFile(r.proj, env), "utf8")).compactions
  const lines = [boundary("t1", "manual", 90_000), boundary("t2", "auto", 127_000), boundary("t3", "auto", 127_500), boundary("t4", "auto", 40_000)]
  fs.appendFileSync(r.input().transcript_path, lines.join("\n") + "\n")
  handle("precompact", r.input({ trigger: "auto" }), env, 1)
  handle("restore", r.input({ source: "compact" }), env, 2)
  assert.equal(samples(), undefined) // nothing is learned until the next nudge reads the transcript
  handle("nudge", r.input(), env, 3)
  assert.equal(samples().length, 3) // the manual boundary is not a trigger measurement
  assert.equal(learnedReserve(samples(), 160_000), 33_000) // median: one odd reading cannot move it
  assert.equal(learnedReserve(samples(), 180_000), 0) // another window: nothing learned yet
  handle("precompact", r.input({ trigger: "auto" }), env, 4)
  handle("restore", r.input({ source: "compact" }), env, 5)
  handle("nudge", r.input(), env, 6)
  assert.equal(samples().length, 3) // the same boundaries are never counted twice
})

test("a PreCompact/SessionStart pair with no compact_boundary in the transcript teaches nothing", () => {
  const r = rig({ tokens: 119_000 })
  const env = { ...r.env, CLAUDE_CODE_AUTO_COMPACT_WINDOW: "180000" }
  const f = stateFile(r.proj, env)
  handle("precompact", r.input({ trigger: "auto" }), env, 0) // seen live: fires when background subagents finish
  handle("restore", r.input({ source: "compact" }), env, 1)
  handle("nudge", r.input(), env, 2)
  assert.equal(JSON.parse(fs.readFileSync(f, "utf8")).compactions, undefined)
  handle("precompact", r.input({ trigger: "auto", agent_id: "sub-1" }), env, 3) // subagent
  handle("restore", r.input({ source: "clear" }), env, 4)
  handle("nudge", r.input(), env, 5)
  assert.equal(JSON.parse(fs.readFileSync(f, "utf8")).compactions, undefined)
})

test("a legacy learnedReserve scalar in the state file is discarded, not trusted", () => {
  const r = rig()
  const env = { ...r.env, CLAUDE_CODE_AUTO_COMPACT_WINDOW: "180000" }
  const f = stateFile(r.proj, env)
  fs.mkdirSync(path.dirname(f), { recursive: true })
  fs.writeFileSync(f, JSON.stringify({ sessions: {}, learnedReserve: 80_434 }))
  handle("precompact", r.input({ trigger: "manual", context_tokens_before: 90_000 }), env, 0)
  assert.equal(JSON.parse(fs.readFileSync(f, "utf8")).learnedReserve, undefined)
})

test("stop: a later PERSISTED: none keeps the unit count of an earlier real persist in the same epoch", () => {
  const r = rig()
  handle("stop", r.input({ last_assistant_message: "done\nPERSISTED: 3 units (a, b, c)" }), r.env, 0)
  handle("stop", r.input({ last_assistant_message: "later\nPERSISTED: none" }), r.env, 1)
  const st = JSON.parse(fs.readFileSync(stateFile(r.proj, r.env), "utf8")).sessions[r.input({}).session_id]
  assert.equal(st.units, 3)
})

const u = (content, extra = {}) => JSON.stringify({ type: "user", timestamp: "t", message: { role: "user", content }, ...extra })

test("owner words: keeps typed and queued messages, drops tool output, notifications, meta and duplicates", () => {
  const lines = [
    u("first instruction"),
    u([{ type: "tool_result", content: "noise" }]),
    u("<task-notification>done</task-notification>"),
    u("<local-command-stdout>Compacted</local-command-stdout>"),
    u("meta", { isMeta: true }),
    u("summary", { isCompactSummary: true }),
    u("side", { isSidechain: true }),
    u("<command-name>/compact</command-name><command-message>compact</command-message><command-args>keep the budget in mind</command-args>"),
    JSON.stringify({ type: "attachment", timestamp: "t", attachment: { type: "queued_command", prompt: "typed while busy" } }),
    u([{ type: "text", text: "first instruction" }]),
    u("real <system-reminder>injected</system-reminder> words"),
    "{torn",
  ].join("\n")
  assert.deepEqual(ownerMessages(lines).map((m) => m.text), ["first instruction", "/compact keep the budget in mind", "typed while busy", "real  words"])
})

test("owner words: newest fit the inline budget, oldest first; one oversized message is truncated", () => {
  const md = ownerWordsMarkdown([1, 2, 3, 4].map((i) => ({ ts: `t${i}`, text: "x".repeat(100) + i })))
  const r = recentOwnerWords(md, 250)
  assert.equal(r.total, 4)
  assert.equal(r.shown, 2)
  assert.match(r.text, /## t3[\s\S]*## t4/)
  assert.match(recentOwnerWords(ownerWordsMarkdown([{ ts: "t", text: "y".repeat(500) }]), 100).text, /truncated/)
})

test("e2e: precompact saves the owner's words; restore makes reading them contract item 1", () => {
  const r = rig({ tokens: 120_000 })
  fs.writeFileSync(r.input().transcript_path, [u("make the UI great"), u("budget is tight"), asst({ input_tokens: 120_000, output_tokens: 0 })].join("\n") + "\n")
  handle("precompact", r.input({ hook_event_name: "PreCompact", trigger: "manual" }), r.env, 1000)
  const wf = ownerWordsFile(r.proj, "s1", r.env)
  assert.match(fs.readFileSync(wf, "utf8"), /make the UI great[\s\S]*budget is tight/)
  const ctx = handle("restore", r.input({ hook_event_name: "SessionStart", source: "compact" }), r.env, 2000).hookSpecificOutput.additionalContext
  assert.match(ctx, /1\. The summary paraphrases[\s\S]*Read .*owner-words.*all 2 of the owner's messages/)
  assert.match(ctx, /budget is tight/)
  assert.doesNotMatch(ctx, /Continue from the next unfinished atomic step/)
  assert.ok(ctx.length <= 9_000)
  // /clear starts a new session id: it still finds the project's latest words file
  const clr = handle("restore", r.input({ session_id: "s2", hook_event_name: "SessionStart", source: "clear" }), r.env, 3000).hookSpecificOutput.additionalContext
  assert.ok(clr.includes(wf))
})

import { decideGate, MAX_GATE_DENIALS, GATE_GRACE_TOKENS, HARD_ZONE_TOKENS } from "./apcc.mjs"

test("gate: allows until the final reminder was ignored, then only persist/read calls", () => {
  const st = { ...freshSession(0), nudges: 2 }
  const base = { st, tokens: 115_000, threshold: 101_000 }
  assert.equal(decideGate({ ...base, tool: "Bash", toolInput: { command: "pnpm build" } }).allow, false)
  assert.equal(decideGate({ ...base, tool: "Edit", toolInput: { file_path: "/x/src/a.ts" } }).allow, false)
  assert.equal(decideGate({ ...base, tool: "Read", toolInput: {} }).allow, true)
  assert.equal(decideGate({ ...base, tool: "Bash", toolInput: { command: "bd note abc 'x'" } }).allow, true)
  assert.equal(decideGate({ ...base, tool: "Write", toolInput: { file_path: "/r/.opencode/context/session-notes.md" } }).allow, true)
  const done = decideGate({ ...base, tool: "Bash", toolInput: { command: "echo '| a |' >> .opencode/context/index.md" } })
  assert.equal(done.completes, true)
  assert.equal(decideGate({ ...base, st: { ...st, nudges: 0 }, tool: "Bash", toolInput: { command: "ls" } }).allow, true)
  assert.equal(decideGate({ ...base, tokens: 50_000, tool: "Bash", toolInput: { command: "ls" } }).allow, true)
  assert.equal(decideGate({ ...base, st: { ...st, persistedEpoch: st.epoch }, tool: "Bash", toolInput: { command: "ls" } }).allow, true)
  assert.equal(decideGate({ ...base, st: { ...st, gateDenials: MAX_GATE_DENIALS }, tool: "Bash", toolInput: { command: "ls" } }).allow, true)
})

test("an early persist goes stale: it does not suppress the threshold nudge or read as DONE", () => {
  const st = { ...freshSession(0), persistedEpoch: 0, persistedTokens: 70_000, units: 0 }
  assert.equal(persistStatus(st, 75_000), "NOT NEEDED (acknowledged)")
  assert.match(persistStatus(st, 125_000), /^NOT DONE \(last persist was at ~70k/)
  assert.equal(decideNudge({ tokens: 105_000, threshold: 100_000, st, now: 1, compactAt: 127_000 }), 1)
  assert.equal(decideNudge({ tokens: 105_000, threshold: 100_000, st: { ...st, persistedTokens: 100_000 }, now: 1, compactAt: 127_000 }), null)
})

test("gate engages after the FIRST nudge plus a short grace, not only after the second", () => {
  // The second nudge fires REARM_TOKENS (15k) after the first: that is the compaction point,
  // so a gate that waited for it could never engage before compaction.
  const st = { ...freshSession(0), nudges: 1 }
  const ls = { tool: "Bash", toolInput: { command: "ls" } }
  const threshold = 132_000
  assert.equal(decideGate({ st, tokens: threshold + 1_000, threshold, ...ls }).allow, true) // grace: finish the atomic step
  assert.equal(decideGate({ st, tokens: threshold + GATE_GRACE_TOKENS, threshold, ...ls }).allow, false)
  assert.equal(decideGate({ st: { ...st, nudges: 0 }, tokens: threshold + 9_000, threshold, ...ls }).allow, true) // never told yet
})

test("gate: in the last stretch before compaction the denial cap no longer releases it", () => {
  const st = { ...freshSession(0), nudges: 2, gateDenials: MAX_GATE_DENIALS }
  const ls = { tool: "Bash", toolInput: { command: "ls" } }
  const threshold = 132_000
  const compactAt = 147_000
  assert.equal(decideGate({ st, tokens: 134_000, threshold, compactAt, ...ls }).allow, true) // cap still protects against a deadlock early on
  assert.equal(decideGate({ st, tokens: compactAt - HARD_ZONE_TOKENS, threshold, compactAt, ...ls }).allow, false)
  // persist writes stay allowed, so the hard zone cannot deadlock the session
  assert.equal(decideGate({ st, tokens: 145_000, threshold, compactAt, tool: "Write", toolInput: { file_path: "/r/.opencode/context/session-notes.md" } }).allow, true)
  assert.equal(decideGate({ st, tokens: 145_000, threshold, compactAt, tool: "Read", toolInput: {} }).allow, true)
})

test("gate: cloud thread messaging tools stay allowed while the gate blocks", () => {
  const st = { ...freshSession(0), nudges: 2 }
  const base = { st, tokens: 115_000, threshold: 101_000 }
  assert.equal(decideGate({ ...base, tool: "Bash", toolInput: { command: "ls" } }).allow, false)
  assert.equal(decideGate({ ...base, tool: "mcp__hearthbot__post_message", toolInput: { text: "x" } }).allow, true)
  assert.equal(decideGate({ ...base, tool: "mcp__github__create_pull_request", toolInput: {} }).allow, false)
})

test("remote-only: the repo copy stays silent outside cloud sessions", () => {
  const r = rig({ tokens: 120_000 })
  const local = { ...r.env, APCC_CC_REMOTE_ONLY: "1" }
  assert.equal(handle("nudge", r.input(), local, 1000), null)
  const cloud = { ...local, CLAUDE_CODE_REMOTE: "true" }
  assert.ok(handle("nudge", r.input(), cloud, 2000).hookSpecificOutput.additionalContext.includes("[apcc]"))
})

test("gate: read-only bd queries stay allowed so recovery can re-read beads", () => {
  const st = { ...freshSession(0), nudges: 2 }
  const base = { st, tokens: 115_000, threshold: 101_000 }
  assert.equal(decideGate({ ...base, tool: "Bash", toolInput: { command: "bd show astro-template-qaz6" } }).allow, true)
  assert.equal(decideGate({ ...base, tool: "Bash", toolInput: { command: "bd show astro-template-qaz6 2>&1 | head -60" } }).allow, true)
  assert.equal(decideGate({ ...base, tool: "Bash", toolInput: { command: "bd list --status in_progress" } }).allow, true)
  assert.equal(decideGate({ ...base, tool: "Bash", toolInput: { command: "bd show x; pnpm build" } }).allow, false)
  assert.equal(decideGate({ ...base, tool: "Bash", toolInput: { command: "bd show x && rm -rf src" } }).allow, false)
  assert.equal(decideGate({ ...base, tool: "Bash", toolInput: { command: "bd close x" } }).allow, false)
})

test("threshold honours CLAUDE_AUTOCOMPACT_PCT_OVERRIDE (host compacts at (window - 20k) * pct)", () => {
  const env = { CLAUDE_CODE_AUTO_COMPACT_WINDOW: "180000", CLAUDE_AUTOCOMPACT_PCT_OVERRIDE: "80" }
  // live cloud thread 2026-10-21: last readings before compaction 127,978 and 127,449
  assert.equal(resolveThreshold(env, {}), 113_000)
  assert.ok(resolveThreshold(env, {}) < 127_449)
  assert.equal(resolveThreshold({ ...env, CLAUDE_AUTOCOMPACT_PCT_OVERRIDE: "95" }, {}), 132_000) // usual point is lower
  assert.equal(resolveThreshold({ ...env, CLAUDE_AUTOCOMPACT_PCT_OVERRIDE: "junk" }, {}), 132_000)
})

test("a persist write near the threshold counts before the gate engages", () => {
  const r = rig({ tokens: 95_000 }) // threshold 100k (rig), inside the 12k freshness window
  const env = r.env
  handle("gate", r.input({ hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: { command: "bd note abc --stdin" } }), env, 1000)
  r.setTokens(101_000)
  assert.equal(handle("nudge", r.input(), env, 2000), null) // covered: no nudge
  const far = rig({ tokens: 60_000 })
  handle("gate", far.input({ hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: { command: "bd note abc --stdin" } }), far.env, 1000)
  far.setTokens(101_000)
  assert.ok(handle("nudge", far.input(), far.env, 2000).hookSpecificOutput.additionalContext.includes("[apcc]")) // too early to count
})

test("persist writes seen by the gate count as units, so precompact reports DONE without a marker", () => {
  const r = rig({ tokens: 101_000 })
  const gate = (command) => handle("gate", r.input({ hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: { command } }), r.env, 1000)
  gate("bd note abc --stdin")
  gate("echo '| d | s | x | y |' >> .opencode/context/index.md")
  handle("precompact", r.input({ hook_event_name: "PreCompact", trigger: "auto" }), r.env, 2000)
  const st = JSON.parse(fs.readFileSync(stateFile(r.proj, r.env), "utf8")).sessions.s1
  assert.equal(st.units, 2)
  assert.equal(st.compactStatus, "DONE")
})
