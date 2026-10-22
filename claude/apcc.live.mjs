// End-to-end: runs the REAL hook CLI (node apcc.mjs <event>) as separate processes with
// stdin JSON, a fake transcript, an isolated state dir, and the real ~/.claude/settings.json.
import { execFileSync } from "node:child_process"
import fs from "node:fs"
import path from "node:path"
import os from "node:os"
const root = path.join(os.homedir(), ".local", "state", "apcc-cc-live")
fs.rmSync(root, { recursive: true, force: true })
const proj = path.join(root, "proj")
fs.mkdirSync(path.join(proj, ".opencode", "context"), { recursive: true })
const tr = path.join(root, "t.jsonl")
const env = { ...process.env, APCC_CC_STATE_DIR: path.join(root, "state"), CLAUDE_PROJECT_DIR: proj }
delete env.APCC_PERSIST_THRESHOLD_TOKENS
const setTokens = (n) => fs.writeFileSync(tr, JSON.stringify({ type: "assistant", message: { usage: { input_tokens: 1, cache_read_input_tokens: n - 101, cache_creation_input_tokens: 100, output_tokens: 0 } } }) + "\n")
const hook = (event, extra = {}) => {
  const input = { session_id: "live", cwd: proj, transcript_path: tr, hook_event_name: event === "gate" ? "PreToolUse" : "UserPromptSubmit", ...extra }
  const out = execFileSync("node", ["/home/duck/.claude/hooks/apcc/apcc.mjs", event], { input: JSON.stringify(input), env }).toString()
  return out ? JSON.parse(out) : null
}
const gate = (tool, tool_input) => { const r = hook("gate", { tool_name: tool, tool_input }); return r?.hookSpecificOutput?.permissionDecision === "deny" ? "DENY" : "allow" }
const nudged = (r) => (r?.hookSpecificOutput?.additionalContext ?? "").includes("[apcc]") ? "NUDGE" : "none"
const rows = []
const check = (what, got, want) => { rows.push({ what, got, want, ok: got === want }); }
setTokens(120_000); check("120k: prompt -> no nudge", nudged(hook("nudge")), "none")
setTokens(134_000); check("134k: prompt -> first nudge", nudged(hook("nudge")), "NUDGE")
check("134k: Bash ls inside grace", gate("Bash", { command: "ls" }), "allow")
setTokens(138_000)
check("138k: Bash ls after grace", gate("Bash", { command: "ls" }), "DENY")
check("138k: Edit src file", gate("Edit", { file_path: "/x/src/a.ts" }), "DENY")
check("138k: Read", gate("Read", { file_path: "/x" }), "allow")
check("138k: bd note", gate("Bash", { command: "bd note abc 'x'" }), "allow")
check("138k: Write session-notes", gate("Write", { file_path: ".opencode/context/session-notes.md" }), "allow")
check("138k: Bash ls still blocked (index not written)", gate("Bash", { command: "ls" }), "DENY")
check("138k: 4th denial cap reached; 5th ls", gate("Bash", { command: "ls" }), "DENY")
setTokens(145_000)
check("145k hard zone after cap: Bash ls", gate("Bash", { command: "ls" }), "DENY")
check("145k hard zone: index.md write", gate("Bash", { command: "echo '| x |' >> .opencode/context/index.md" }), "allow")
check("145k after persist: Bash ls", gate("Bash", { command: "ls" }), "allow")
for (const r of rows) console.log(`${r.ok ? "PASS" : "FAIL"}  ${r.what}  (got ${r.got}, want ${r.want})`)
process.exit(rows.every((r) => r.ok) ? 0 : 1)
