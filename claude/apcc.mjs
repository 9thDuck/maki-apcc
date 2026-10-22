#!/usr/bin/env node
// apcc-cc: Claude Code port of the opencode persisting-context plugin (APCC).
// persist -> compact -> recover, built from hooks. Bead lds-b94.
//
// What it does (and, honestly, what it cannot):
//   nudge     (UserPromptSubmit, PostToolUse) when the main conversation crosses the
//             persist threshold, inject ONE "persist now" directive per context epoch
//             (a second, final reminder only if it was ignored). Subagent calls skipped.
//   stop      (Stop) detect the end-anchored `PERSISTED: <n> units` marker in the last
//             reply, record it, and tell the user the state is saved and /compact is cheap.
//   precompact(PreCompact) record the honest persist status. NEVER blocks compaction
//             (apcc's hold-and-spawn gate wedged in the field; same decision here).
//   restore   (SessionStart) after compact/clear: bump the epoch and inject the recovery
//             contract (persist status + index tail). On resume of a big stale session,
//             warn the user that the prompt cache expired.
//
// Cannot do: trigger /compact (Claude Code hooks cannot). Compaction stays ahead of the
// nudge only because autoCompactWindow is set in ~/.claude/settings.json (default on
// 1M-window models is ~967K tokens, far past the persist threshold).
//
// Fail-open: any error exits 0 with no output. Kill switch: APCC_CC=0.

import fs from "node:fs"
import os from "node:os"
import path from "node:path"
import crypto from "node:crypto"

export const DEFAULT_THRESHOLD_TOKENS = 135_000 // matches the opencode apcc default
// Persist at 80% of the auto-compact window so the host compacts shortly AFTER the persist turn
// (window 180k -> nudge 132k). Lower ratios leave a long un-compacted tail; the
// persist turn itself needs roughly 15-30k tokens of headroom before the host compacts.
export const PERSIST_HEADROOM_TOKENS = 15_000 // measured 2026-10-04: 15 persist turns cost median ~4k, max ~8.2k tokens (docs/research/apcc-compaction-measurements.md)
export const DELTA_HEADROOM_TOKENS = 8_000 // second, delta-only persist this close to the compaction point
// Claude Code auto-compacts BELOW autoCompactWindow: it keeps an output + buffer reserve.
// Observed 2026-10-01: window 160k compacted at 126,950 tokens, before the old window-25k
// threshold (135k) ever fired, so no persist happened. Each auto compaction is recorded
// with the window it ran under; the reserve is learned as the MEDIAN of (window - tokens at
// compaction) over >= MIN_RESERVE_SAMPLES samples of the SAME window. (A one-way max() let one odd
// reading lower the threshold for good: 2026-10-04 stored 80k against 29 real compactions at ~33k.)
export const HOST_RESERVE_TOKENS = 33_000
export const MIN_RESERVE_SAMPLES = 3
export const MAX_RESERVE_SAMPLES = 20
export const MIN_THRESHOLD_RATIO = 0.5
export const PERSIST_FRESH_TOKENS = 12_000 // a persist covers only this much later growth; earlier persists go stale
export const REARM_TOKENS = 15_000 // growth past the first nudge before the final reminder
export const REARM_MS = 10 * 60 * 1000
export const MAX_NUDGES = 2
export const RETENTION_MS = 30 * 24 * 60 * 60 * 1000
const TAIL_BYTES = 600_000
const CONTEXT_CAP_CHARS = 9_000 // additionalContext hard cap is 10,000

export function parseTokenCount(v) {
  if (typeof v === "number") return Number.isFinite(v) && v > 0 ? Math.floor(v) : 0
  if (typeof v !== "string") return 0
  const m = v.trim().match(/^(\d+(?:\.\d+)?)\s*([kKmM]?)$/)
  if (!m) return 0
  const n = parseFloat(m[1])
  const mult = m[2].toLowerCase() === "m" ? 1_000_000 : m[2].toLowerCase() === "k" ? 1_000 : 1
  return Math.floor(n * mult)
}

export function resolveWindow(env, settings) {
  return parseTokenCount(env.CLAUDE_CODE_AUTO_COMPACT_WINDOW) || parseTokenCount(settings?.autoCompactWindow)
}

// Real host compactions as the transcript recorded them: the only trustworthy source of the trigger point.
export function compactBoundaries(text) {
  const out = []
  for (const line of String(text).split("\n")) {
    if (!line.includes("compact_boundary")) continue
    try {
      const o = JSON.parse(line)
      const m = o.compactMetadata
      if (m && typeof m.preTokens === "number") out.push({ ts: o.timestamp, trigger: m.trigger, pre: m.preTokens })
    } catch {}
  }
  return out
}

export function learnedReserve(samples, window) {
  const r = (Array.isArray(samples) ? samples : [])
    .filter((s) => s && s.window === window && s.pre > 0 && s.pre < window)
    .map((s) => window - s.pre)
    .sort((a, b) => a - b)
  return r.length >= MIN_RESERVE_SAMPLES ? r[Math.floor(r.length / 2)] : 0
}

// Claude Code compacts at (window - output reserve) * pct when CLAUDE_AUTOCOMPACT_PCT_OVERRIDE is set,
// if that is lower than its usual point. Measured 2026-10-21 in a cloud thread (window 180k, pct 80):
// last readings before compaction 127,978 and 127,449, i.e. (180k - 20k) * 0.8 = 128k, not 147k.
export const HOST_OUTPUT_RESERVE_TOKENS = 20_000
export function autocompactPct(env) {
  const pct = parseFloat(env?.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE)
  return Number.isFinite(pct) && pct > 0 && pct < 100 ? pct : 0
}

// Where the host actually compacts for a given window (0 = unknown).
export function compactPoint(window, learnedReserve = 0, pct = 0) {
  if (window <= 0) return 0
  const usual = window - Math.max(HOST_RESERVE_TOKENS, learnedReserve)
  return pct > 0 ? Math.min(usual, Math.floor(((window - HOST_OUTPUT_RESERVE_TOKENS) * pct) / 100)) : usual
}

// env override -> compaction point minus persist headroom (so little work falls between persist and host compaction) -> default
export function resolveThreshold(env, settings, learnedReserve = 0) {
  const override = parseTokenCount(env.APCC_PERSIST_THRESHOLD_TOKENS)
  if (override > 0) return override
  const window = resolveWindow(env, settings)
  if (window > 0) return Math.max(Math.floor(window * MIN_THRESHOLD_RATIO), compactPoint(window, learnedReserve, autocompactPct(env)) - PERSIST_HEADROOM_TOKENS)
  return DEFAULT_THRESHOLD_TOKENS
}

// Size of the main conversation as of the last assistant turn: the next request will
// carry input + cache reads + cache writes + that turn's output. Sidechains (subagents)
// are skipped: their context is not the main window.
export function lastMainContextTokens(jsonlText) {
  const lines = jsonlText.split("\n")
  for (let i = lines.length - 1; i >= 0; i--) {
    const line = lines[i]
    if (!line || line[0] !== "{") continue
    let o
    try {
      o = JSON.parse(line)
    } catch {
      continue // partial first line of a tail read, or a torn write
    }
    // Reached the compaction boundary before any newer assistant turn: the older usage figures
    // describe the pre-compact context, so there is no reading yet (not a stale ~250k).
    if (o.type === "system" && o.subtype === "compact_boundary") return 0
    if (o.type !== "assistant" || o.isSidechain || o.isApiErrorMessage) continue
    const u = o.message?.usage
    if (!u) continue
    return (
      (u.input_tokens ?? 0) + (u.cache_read_input_tokens ?? 0) + (u.cache_creation_input_tokens ?? 0) + (u.output_tokens ?? 0)
    )
  }
  return 0
}

function readTail(file, bytes = TAIL_BYTES) {
  const fd = fs.openSync(file, "r")
  try {
    const { size } = fs.fstatSync(fd)
    const len = Math.min(size, bytes)
    const buf = Buffer.alloc(len)
    fs.readSync(fd, buf, 0, len, size - len)
    return buf.toString("utf8")
  } finally {
    fs.closeSync(fd)
  }
}

// END-ANCHORED marker: the reply's last non-empty line, outside an unbalanced code fence.
// Quoted grammar (code blocks, pasted receipts, docs) must never register (apcc learned
// this from three unintended compactions on 2026-09-13).
export function parseMarker(text) {
  if (typeof text !== "string") return { kind: "none" }
  if ((text.match(/^\s*```/gm) ?? []).length % 2 === 1) return { kind: "none" }
  const last = text.split("\n").map((l) => l.trim()).filter(Boolean).pop() ?? ""
  const m = last.match(/^PERSISTED(?: \((manual)\))?:\s*(none|(\d+)\s+units?\b.*)$/i)
  if (!m) return { kind: "none" }
  const manual = Boolean(m[1])
  if (m[2].toLowerCase() === "none") return { kind: "acknowledged", manual, units: 0 }
  const units = parseInt(m[3] ?? "0", 10)
  return units > 0 ? { kind: "persisted", manual, units } : { kind: "acknowledged", manual, units: 0 }
}

export function freshSession(now = Date.now()) {
  return { epoch: 0, nudges: 0, lastNudgeAt: 0, lastNudgeTokens: 0, persistedEpoch: -1, persistedTokens: 0, units: 0, lastTokens: 0, windowWarnedEpoch: -1, deltaEpoch: -1, gateDenials: 0, updatedAt: now }
}

export function newEpoch(st, now = Date.now()) {
  return { ...st, epoch: st.epoch + 1, nudges: 0, lastNudgeAt: 0, lastNudgeTokens: 0, persistedEpoch: -1, persistedTokens: 0, units: 0, lastTokens: 0, windowWarnedEpoch: -1, deltaEpoch: -1, gateDenials: 0, updatedAt: now }
}

// A persist covers the context only while little has been added since. persistedTokens
// absent (legacy state) counts as covered. tokens 0 = unknown: trust the epoch flag.
export function isCovered(st, tokens = 0) {
  if (st.persistedEpoch !== st.epoch) return false
  if (!(st.persistedTokens > 0) || !(tokens > 0)) return true
  return tokens - st.persistedTokens <= PERSIST_FRESH_TOKENS
}

export function persistStatus(st, tokens = 0) {
  if (isCovered(st, tokens)) return st.units > 0 ? "DONE" : "NOT NEEDED (acknowledged)"
  if (st.persistedEpoch === st.epoch) return `NOT DONE (last persist was at ~${Math.round(st.persistedTokens / 1000)}k tokens, ~${Math.round((tokens - st.persistedTokens) / 1000)}k tokens of work since is unsaved)`
  return "NOT DONE"
}

// Pure decision: should this call inject a nudge, and which one?
export function decideNudge({ tokens, threshold, st, now, compactAt = 0 }) {
  if (threshold <= 0 || tokens < threshold) return null
  if (isCovered(st, tokens)) {
    // Already persisted, but work kept accruing before the host compacts: one delta persist.
    if (compactAt > 0 && tokens >= compactAt - DELTA_HEADROOM_TOKENS && st.deltaEpoch !== st.epoch) return 3
    return null
  }
  if (st.nudges === 0) return 1
  if (st.nudges < MAX_NUDGES && (tokens >= st.lastNudgeTokens + REARM_TOKENS || now - st.lastNudgeAt >= REARM_MS)) return 2
  return null
}

export const MAX_GATE_DENIALS = 4 // bounded early on: a gate must never deadlock the session
export const GATE_GRACE_TOKENS = 5_000 // after the first nudge: room to finish the atomic step before tools are blocked
export const HARD_ZONE_TOKENS = 10_000 // this close to the compaction point the denial cap no longer releases the gate
const PERSIST_DEST = /\.opencode\/context\/|docs\/research\//
const PERSIST_CMD = /\bbd\s+(note|create|remember)\b/
// Read-only tracker queries: recovery starts with `bd show` (recoveryText step 2), so blocking them would block recovery.
const READ_CMD = /^\s*bd\s+(show|list|ready|prime|history|search|count|stats)\b/

// Pure decision: once the model has been told (first nudge) and the grace has passed, only persisting
// (and reading) may proceed. The second nudge fires REARM_TOKENS after the first, i.e. at the
// compaction point, so waiting for it meant the gate could never engage before compaction.
// Persist writes are always allowed, so even the hard zone cannot deadlock a session.
export function decideGate({ tool, toolInput, st, tokens, threshold, compactAt = 0 }) {
  if (threshold <= 0 || tokens < threshold) return { allow: true }
  if (isCovered(st, tokens)) return { allow: true }
  const nudges = st.nudges ?? 0
  if (nudges < 1) return { allow: true }
  if (nudges < MAX_NUDGES && tokens < threshold + GATE_GRACE_TOKENS) return { allow: true }
  const hardZone = compactAt > 0 && tokens >= compactAt - HARD_ZONE_TOKENS
  if ((st.gateDenials ?? 0) >= MAX_GATE_DENIALS && !hardZone) return { allow: true }
  if (["Read", "Grep", "Glob", "TaskOutput"].includes(tool)) return { allow: true }
  if (String(tool).startsWith("mcp__hearthbot__")) return { allow: true } // cloud project threads reach the user only through these
  const target = String(toolInput?.file_path ?? toolInput?.command ?? "")
  if (tool === "Bash" && READ_CMD.test(target) && !/[;&|]\s*\S/.test(target.replace(/\s*2>&1\s*\|\s*(head|tail)\b[^;&|]*$/, ""))) return { allow: true }
  const persistCall = (["Write", "Edit"].includes(tool) && PERSIST_DEST.test(target)) || (tool === "Bash" && (PERSIST_CMD.test(target) || PERSIST_DEST.test(target)))
  if (persistCall) return { allow: true, completes: /\.opencode\/context\/index\.md/.test(target) }
  return { allow: false }
}

const k = (n) => `${Math.round(n / 1000)}k`

export function nudgeText({ tokens, threshold, which }) {
  const head =
    which === 3
      ? `[apcc] Context is ~${k(tokens)} tokens, right at the auto-compact window. Host compaction is imminent. Persist ONLY what changed since your last persist (new decisions, progress, exact next action), as small units.`
      : which === 1
      ? `[apcc] Context is ~${k(tokens)} tokens (persist threshold ${k(threshold)}). Persist now, at the next safe boundary: finish the atomic step you are on, never abandon in-flight edits.`
      : `[apcc] Final reminder: context is ~${k(tokens)} tokens and nothing has been persisted this context. Persist at the next safe boundary.`
  return [
    head,
    "Save what compaction would lose, as small linked units (one fact each; what + why + state + next action):",
    "- progress / blocker / decision / next action on the bead you are working on -> `bd note <id> --stdin` (REQUIRED whenever a bead is in play: recovery re-reads beads first, so state kept only in session-notes is easy to miss)",
    '- durable decision -> `bd create "Decision: <slug>" -t decision`',
    "- research or reusable findings -> docs/research/<topic>.md (one ## section per finding)",
    "- in-flight state (where I am, tried/failed, exact next action) -> .opencode/context/session-notes.md (newest on top)",
    "Append one line per unit to .opencode/context/index.md: `| date | slug | destination | one-line summary |` (ensure .opencode/ is gitignored first).",
    "Skip tool output, resolved dead-ends, and anything re-derivable from the repo in seconds.",
    "Then end that reply with the marker as its LAST line: `PERSISTED: <n> units (<slugs>)`, or `PERSISTED: none` if nothing needed saving. If the user asked you to persist, write `PERSISTED (manual): ...`. A persist never ends a turn: keep working afterwards.",
  ].join("\n")
}

export function recoveryText({ source, st, indexTail, tokensBefore, ownerWords = null }) {
  const status = persistStatus(st, tokensBefore)
  const lines = [
    source === "compact"
      ? `[apcc] The conversation was just compacted${tokensBefore ? ` (from ~${k(tokensBefore)} tokens)` : ""}. Persist status before compaction: ${status}.`
      : "[apcc] The conversation was cleared. Recover state from the tracker, not from memory.",
  ]
  if (source === "compact" && status.startsWith("NOT DONE")) {
    lines.push("Nothing was persisted before compaction: rebuild in-flight state from the bead notes, `git status`/`git diff`, and the summary above. Treat anything you cannot find there as lost, not as known.")
  }
  const words = ownerWords?.file
    ? `1. The summary paraphrases and drops instructions. Before acting, Read ${ownerWords.file} in full: all ${ownerWords.total} of the owner's messages, verbatim. Any instruction there that you have neither acted on nor recorded is open work, not history.`
    : "1. No verbatim copy of the owner's messages was saved; treat the summary's account of their instructions as possibly incomplete."
  lines.push(
    "Recovery contract:",
    words,
    "2. Re-read the requirement chain fresh (`bd show` the in-progress bead plus its parent and child beads). Recalled memory is not a recorded requirement.",
    "3. Your first state claim must cite a freshly read artifact (command output, file, bead), not the summary.",
    "4. The owner's newest message wins over any recovered plan or note.",
    source === "compact"
      ? "5. Before resuming the next step, check it still serves the owner's goal and instructions (not just the task list); then continue without waiting for confirmation."
      : "",
  )
  if (ownerWords?.recent) lines.push("", `Owner's newest messages (${ownerWords.shown} of ${ownerWords.total}, verbatim):`, ownerWords.recent)
  if (indexTail) lines.push("", "Recovery map (tail of .opencode/context/index.md; `bd show <id>` / read the path for detail):", indexTail)
  return lines.filter((l) => l !== "").join("\n").slice(0, CONTEXT_CAP_CHARS)
}

export function tailLines(text, n, maxChars = 3_000) {
  const out = text.split("\n").filter((l) => l.trim()).slice(-n).join("\n")
  return out.length > maxChars ? out.slice(out.length - maxChars) : out
}

// ---- owner's words: the lossless layer under the lossy compaction summary ----
// Compaction summaries paraphrase and drop instructions (observed 2026-10-02: the owner's
// budget limits and "the UI/UX is really bad" main charge both vanished across compactions).
// Before each compaction, every message the owner typed is copied verbatim to a file; restore
// shows the newest ones inline and points at the file for the rest.

const NOISE_PREFIXES = ["<task-notification", "<local-command-stdout", "<local-command-caveat", "[Request interrupted"]

export function cleanOwnerText(raw) {
  let text = String(raw ?? "").replace(/<system-reminder>[\s\S]*?<\/system-reminder>/g, "").trim()
  const cmd = text.match(/<command-name>([^<]*)<\/command-name>[\s\S]*?<command-args>([\s\S]*?)<\/command-args>/)
  if (cmd) text = `${cmd[1].trim()} ${cmd[2].trim()}`.trim()
  if (!text || NOISE_PREFIXES.some((p) => text.startsWith(p))) return ""
  return text
}

function partsText(c) {
  if (typeof c === "string") return c
  if (Array.isArray(c)) return c.filter((p) => p?.type === "text").map((p) => p.text).join("\n")
  return ""
}

export function ownerMessages(jsonlText) {
  const out = []
  const seen = new Set()
  for (const line of jsonlText.split("\n")) {
    if (!line.trim()) continue
    let r
    try {
      r = JSON.parse(line)
    } catch {
      continue
    }
    if (r.isSidechain) continue
    let raw
    if (r.type === "user" && !r.isMeta && !r.isCompactSummary) raw = partsText(r.message?.content)
    else if (r.type === "attachment" && r.attachment?.type === "queued_command") raw = partsText(r.attachment.prompt) // typed while Claude was busy
    else continue
    const text = cleanOwnerText(raw)
    if (!text || seen.has(text)) continue
    seen.add(text)
    out.push({ ts: r.timestamp ?? "", text })
  }
  return out
}

export function ownerWordsMarkdown(msgs) {
  return [`# Owner's words, verbatim (${msgs.length} messages, oldest first)`, "", ...msgs.map((m) => `## ${m.ts}\n${m.text}\n`)].join("\n")
}

// Newest messages that fit the budget, oldest first.
export function recentOwnerWords(markdown, maxChars = 3_500) {
  const sections = markdown.split(/\n(?=## )/).slice(1)
  const picked = []
  let used = 0
  for (let i = sections.length - 1; i >= 0; i--) {
    const s = sections[i].trim()
    if (used + s.length > maxChars) {
      if (!picked.length) picked.push(`${s.slice(0, maxChars)} …[truncated]`)
      break
    }
    picked.unshift(s)
    used += s.length + 1
  }
  return { text: picked.join("\n"), shown: picked.length, total: sections.length }
}

export function ownerWordsFile(proj, sessionId, env = process.env) {
  return stateFile(proj, env).replace(/state-([0-9a-f]+)\.json$/, `owner-words-$1-${String(sessionId).slice(0, 8)}.md`)
}

// /clear starts a new session id: fall back to the project's newest words file.
function latestOwnerWordsFile(proj, sessionId, env) {
  const own = ownerWordsFile(proj, sessionId, env)
  if (fs.existsSync(own)) return own
  const dir = path.dirname(own)
  const prefix = path.basename(own).replace(/-[^-]+\.md$/, "-")
  try {
    const files = fs.readdirSync(dir).filter((f) => f.startsWith(prefix) && f.endsWith(".md"))
    files.sort((a, b) => fs.statSync(path.join(dir, b)).mtimeMs - fs.statSync(path.join(dir, a)).mtimeMs)
    return files.length ? path.join(dir, files[0]) : ""
  } catch {
    return ""
  }
}

// ---- state (user-level, never inside the project) ----

export function stateFile(proj, env = process.env) {
  const base = env.APCC_CC_STATE_DIR || path.join(env.XDG_STATE_HOME || path.join(os.homedir(), ".local", "state"), "apcc-cc")
  return path.join(base, `state-${crypto.createHash("sha1").update(proj).digest("hex").slice(0, 12)}.json`)
}

function loadState(file) {
  try {
    const s = JSON.parse(fs.readFileSync(file, "utf8"))
    return s && typeof s === "object" && s.sessions ? s : { sessions: {} }
  } catch {
    return { sessions: {} }
  }
}

function saveState(file, state, now) {
  for (const [id, s] of Object.entries(state.sessions)) if (now - (s.updatedAt ?? 0) > RETENTION_MS) delete state.sessions[id]
  fs.mkdirSync(path.dirname(file), { recursive: true })
  const tmp = `${file}.${process.pid}.tmp`
  fs.writeFileSync(tmp, JSON.stringify(state))
  fs.renameSync(tmp, file) // atomic
}

// Tiny cross-process lock: parallel PostToolUse hooks must not both nudge.
function withLock(file, fn) {
  const lock = `${file}.lock`
  fs.mkdirSync(path.dirname(file), { recursive: true })
  for (let i = 0; i < 40; i++) {
    try {
      fs.closeSync(fs.openSync(lock, "wx"))
      try {
        return fn()
      } finally {
        fs.rmSync(lock, { force: true })
      }
    } catch (e) {
      if (e.code !== "EEXIST") throw e
      try {
        if (Date.now() - fs.statSync(lock).mtimeMs > 5_000) fs.rmSync(lock, { force: true }) // stale
      } catch {}
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 25)
    }
  }
  return fn() // lock never freed: proceed unlocked rather than block the session
}

function projectDir(input, env) {
  return env.CLAUDE_PROJECT_DIR || input.cwd || process.cwd()
}

// Only act where persistence has somewhere to go.
export function isTracked(proj) {
  return fs.existsSync(path.join(proj, ".beads")) || fs.existsSync(path.join(proj, ".opencode", "context"))
}

function readUserSettings(env) {
  try {
    return JSON.parse(fs.readFileSync(path.join(env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), ".claude"), "settings.json"), "utf8"))
  } catch {
    return {}
  }
}

const out = (obj) => process.stdout.write(JSON.stringify(obj))

export function handle(event, input, env = process.env, now = Date.now()) {
  if (env.APCC_CC === "0" || env.APCC_CC === "false") return null
  // Opt-in guard: a hook entry that sets this only acts in cloud sessions, so a copy wired into
  // project settings cannot double-nudge on the owner's laptop, where the user-level hooks run apcc.
  if (env.APCC_CC_REMOTE_ONLY === "1" && env.CLAUDE_CODE_REMOTE !== "true") return null
  const proj = projectDir(input, env)
  if (!isTracked(proj) || !input.session_id) return null
  const file = stateFile(proj, env)
  const settings = readUserSettings(env)
  return withLock(file, () => {
    const state = loadState(file)
    delete state.learnedReserve // legacy one-way scalar: unverifiable, never trusted again
    const win = resolveWindow(env, settings)
    const reserve = learnedReserve(state.compactions, win)
    const threshold = resolveThreshold(env, settings, reserve)
    const compactAt = compactPoint(win, reserve, autocompactPct(env))
    let st = state.sessions[input.session_id] ?? freshSession(now)
    let result = null

    if (event === "nudge") {
      if (input.agent_id) return null // subagent: its own context, not the main window
      if (!input.transcript_path || !fs.existsSync(input.transcript_path)) return null
      if (st.learnPending) {
        st.learnPending = false
        const seen = new Set((state.compactions ?? []).map((c) => c.boundaryAt).filter(Boolean))
        for (const bd of compactBoundaries(fs.readFileSync(input.transcript_path, "utf8")))
          if (bd.trigger === "auto" && win > 0 && bd.pre > 0 && bd.pre < win && !seen.has(bd.ts))
            state.compactions = [...(state.compactions ?? []), { window: win, pre: bd.pre, at: now, boundaryAt: bd.ts }].slice(-MAX_RESERVE_SAMPLES)
      }
      const tokens = lastMainContextTokens(readTail(input.transcript_path))
      // Compaction/clear that SessionStart did not announce: the meter fell off a cliff.
      if (st.lastTokens > 0 && tokens > 0 && tokens < st.lastTokens * 0.6) st = newEpoch(st, now)
      if (tokens > 0) st.lastTokens = tokens
      const window = win
      if (window > 0 && tokens > window * 1.05 && st.windowWarnedEpoch !== st.epoch) {
        // Past the configured window with no compaction: the setting is not in effect in this
        // session (it is read at startup; only /autocompact changes a running session).
        st.windowWarnedEpoch = st.epoch
        result = { systemMessage: `apcc: context is ~${k(tokens)} tokens, past your auto-compact window (${k(window)}), but nothing compacted. The setting applies at session start; run /autocompact ${k(window)} (or restart) so unattended runs compact on their own.` }
      }
      const which = decideNudge({ tokens, threshold, st, now, compactAt })
      if (which) {
        if (which === 3) st.deltaEpoch = st.epoch
        else st.nudges = which
        st.lastNudgeAt = now
        st.lastNudgeTokens = tokens
        result = { ...result, hookSpecificOutput: { hookEventName: input.hook_event_name || "UserPromptSubmit", additionalContext: nudgeText({ tokens, threshold, which }) } }
      }
    } else if (event === "gate") {
      if (input.agent_id) return null
      // st.lastTokens comes from the PostToolUse nudge, which sees the transcript one assistant
      // message behind this call (it misses the latest tool result). Read the transcript here.
      const fresh = input.transcript_path && fs.existsSync(input.transcript_path) ? lastMainContextTokens(readTail(input.transcript_path)) : 0
      const tokens = fresh > 0 ? fresh : st.lastTokens || 0
      const g = decideGate({ tool: input.tool_name, toolInput: input.tool_input, st, tokens, threshold, compactAt })
      // A persist write made close to the threshold counts even when the gate was not engaged yet:
      // compaction can land before the Stop hook ever sees a PERSISTED marker (live test 2026-10-21).
      const target = String(input.tool_input?.file_path ?? input.tool_input?.command ?? "")
      const earlyPersist =
        tokens >= threshold - PERSIST_FRESH_TOKENS &&
        ((["Write", "Edit"].includes(input.tool_name) && /\.opencode\/context\/index\.md/.test(target)) ||
          (input.tool_name === "Bash" && (PERSIST_CMD.test(target) || /\.opencode\/context\/index\.md/.test(target))))
      if (g.completes || earlyPersist) {
        // Count the write as a unit: in project threads the reply often ends in a tool call, so the
        // Stop hook never sees the PERSISTED marker and units stayed 0 ("NOT NEEDED" after a real persist).
        st.units = (st.persistedEpoch === st.epoch ? st.units ?? 0 : 0) + 1
        st.persistedEpoch = st.epoch
        st.persistedTokens = tokens
        st.nudges = 0
        st.lastNudgeAt = 0
      }
      if (!g.allow) {
        st.gateDenials = (st.gateDenials ?? 0) + 1
        result = {
          hookSpecificOutput: {
            hookEventName: "PreToolUse",
            permissionDecision: "deny",
            permissionDecisionReason: `[apcc] Context is ~${k(tokens)} tokens and you ignored the persist reminders; host compaction is near and would lose unsaved scope. Persist now: write units (bd note / .opencode/context/session-notes.md / docs/research), append a line to .opencode/context/index.md LAST (that unlocks tools), then continue. Reads are still allowed.`,
          },
        }
      }
    } else if (event === "stop") {
      const marker = parseMarker(input.last_assistant_message)
      if (marker.kind !== "none") {
        const nowTokens = input.transcript_path && fs.existsSync(input.transcript_path) ? lastMainContextTokens(readTail(input.transcript_path)) : st.lastTokens
        const priorUnits = st.persistedEpoch === st.epoch ? st.units : 0 // a later "none" must not erase an earlier real persist
        st.persistedEpoch = st.epoch
        st.persistedTokens = nowTokens
        st.units = Math.max(marker.units, priorUnits)
        st.nudges = 0
        st.lastNudgeAt = 0
        if (marker.kind === "persisted") {
          const tokens = input.transcript_path && fs.existsSync(input.transcript_path) ? lastMainContextTokens(readTail(input.transcript_path)) : st.lastTokens
          if (tokens >= threshold)
            result = {
              systemMessage: `apcc: ${marker.units} unit(s) persisted at ~${k(tokens)} tokens. NOT compacted: hooks cannot run /compact. If you are here, run /compact now (state is saved). Unattended, the host auto-compacts at ${compactAt ? `~${k(compactAt)}` : "its window"} and recovers from the saved state.`,
            }
        }
      }
    } else if (event === "precompact") {
      if (input.agent_id) return null // a subagent's own compaction says nothing about the main window
      st.compactingAt = now
      // The host does not report its token count here; read the main transcript like the nudge does.
      const fromTranscript = input.transcript_path && fs.existsSync(input.transcript_path) ? lastMainContextTokens(readTail(input.transcript_path)) : 0
      st.tokensBefore = input.context_tokens_before ?? (fromTranscript || st.lastTokens)
      st.compactTrigger = input.trigger
      st.compactStatus = persistStatus(st, st.tokensBefore)
      // Save the owner's words verbatim before the summary replaces them.
      try {
        if (input.transcript_path && fs.existsSync(input.transcript_path)) {
          const msgs = ownerMessages(fs.readFileSync(input.transcript_path, "utf8"))
          if (msgs.length) {
            const wf = ownerWordsFile(proj, input.session_id, env)
            fs.mkdirSync(path.dirname(wf), { recursive: true })
            fs.writeFileSync(wf, ownerWordsMarkdown(msgs))
          }
        }
      } catch {}
      // observational only: must never block compaction
    } else if (event === "restore") {
      const source = input.source
      if (source === "compact" || source === "clear") {
        const tokensBefore = source === "compact" ? st.tokensBefore || st.lastTokens : 0
        const statusSnapshot = { ...st } // status as of the context that just ended
        // A PreCompact/SessionStart pair also fires without any real compaction (seen 2026-10-04 when background
        // subagents finished), so it only schedules learning; the transcript's compact_boundary is the ground truth.
        const learnPending = source === "compact" && st.compactTrigger === "auto"
        st = newEpoch(st, now)
        if (learnPending) st.learnPending = true
        let indexTail = ""
        try {
          indexTail = tailLines(fs.readFileSync(path.join(proj, ".opencode", "context", "index.md"), "utf8"), 15)
        } catch {}
        let ownerWords = null
        try {
          const wf = latestOwnerWordsFile(proj, input.session_id, env)
          if (wf) ownerWords = { file: wf, ...(({ text, shown, total }) => ({ recent: text, shown, total }))(recentOwnerWords(fs.readFileSync(wf, "utf8"))) }
        } catch {}
        if (source === "compact" || indexTail || ownerWords)
          result = { hookSpecificOutput: { hookEventName: "SessionStart", additionalContext: recoveryText({ source, st: statusSnapshot, indexTail, tokensBefore, ownerWords }) } }
      } else if (source === "resume" && input.prompt_cache_likely_expired && (input.context_tokens ?? 0) >= threshold) {
        const usd = typeof input.estimated_cache_write_usd === "number" ? ` (re-caching ≈ $${input.estimated_cache_write_usd.toFixed(2)})` : ""
        result = {
          systemMessage: `apcc: resumed a ~${k(input.context_tokens)}-token session after ${Math.round((input.seconds_since_last_response ?? 0) / 60)} min idle; the prompt cache expired${usd}. Persist state, then /compact or /clear before continuing to keep costs down.`,
        }
      }
    }

    st.updatedAt = now
    state.sessions[input.session_id] = st
    saveState(file, state, now)
    return result
  })
}

async function main() {
  const event = process.argv[2]
  let raw = ""
  for await (const chunk of process.stdin) raw += chunk
  const input = raw.trim() ? JSON.parse(raw) : {}
  const result = handle(event, input)
  if (result) out(result)
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch((e) => {
    if (process.env.APCC_DEBUG) process.stderr.write(`apcc: ${e?.stack || e}\n`)
    process.exit(0) // fail-open
  })
}
