#!/bin/sh
# apcc-lite smoke test — cold-home install + load + gate run.
#
# Prerequisites:
#   * maki >= 0.6.0 on PATH (pack.add + maki.setup agent instructions)
#   * a working default model / auth for one headless `-p` run. The cold home
#     starts with NO stored maki credentials, so auth must come from the
#     environment (provider key env vars pass through unchanged). If maki's
#     built-in default model is not usable, set MAKI_SMOKE_MODEL=<model id>.
#   * this script run from inside a git clone of this repository
#     (the pack is installed from the clone at the checked-out rev)
#
# Secrets: the script never reads, stores, or prints credentials — it only
# passes your existing environment through to the gate run.
#
# Overrides (optional): MAKI_BIN=<path to maki>, MAKI_SMOKE_MODEL=<model id>.
#
# What it asserts:
#   1. pack.add installs the pack from this clone (lockfile pins the rev)
#   2. the installed pack copy is byte-identical to plugin/apcc-lite.lua
#   3. a headless `-p` gate run replies exactly "OK" with zero lua errors
#   4. the pack's permissions are approved in the smoke home (no warning)
set -eu

REPO="$(cd "$(dirname "$0")/.." && pwd)"
ENTRY="plugin/apcc-lite.lua"

MAKI_BIN="${MAKI_BIN:-maki}"
command -v "$MAKI_BIN" >/dev/null 2>&1 || { echo "FAIL: maki not on PATH (need >= 0.6.0)"; exit 1; }
[ -f "$REPO/$ENTRY" ] || { echo "FAIL: run from a clone of this repo ($ENTRY missing)"; exit 1; }
REV="$(git -C "$REPO" rev-parse HEAD)" || { echo "FAIL: $REPO is not a git checkout"; exit 1; }

# 1. Cold XDG home: nothing leaks in or out of the user's real config.
HOME_SMOKE="$(mktemp -d)"
trap 'rm -rf "$HOME_SMOKE"' EXIT
mkdir -p "$HOME_SMOKE/.config/maki" "$HOME_SMOKE/proj"

# plugin.toml grants the config-path require its permissions (wrapping agent.*
# slots costs every permission — the honest grant set is the full one).
# The pack auto-starts on load; threshold tuning is an env opt
# (APCC_THRESHOLD_TOKENS), not a setup() call — see README.
cat > "$HOME_SMOKE/.config/maki/plugin.toml" <<'TOML'
min_maki_version = "0.6.0"

[permissions]
fs_read = true
fs_write = true
run = true
env = true
net = true
TOML

cat > "$HOME_SMOKE/.config/maki/init.lua" <<LUA
maki.pack.add({
  { src = "$REPO", name = "apcc-lite", version = "$REV" },
}, { confirm = false, load = true })

maki.setup({
  agent = {
    compaction_instructions = "[apcc] End the summary with a final line 'PERSIST: <one-line recovery note: slugs / exact next action>' or 'PERSIST: none'.",
    post_compaction_instructions = "[apcc] Recovery: re-read .opencode/context/index.md first — it is the map. Pull only the units the current task needs (bd show <id> / read the path). Your first state claim must cite a freshly read artifact, not the summary.",
  },
})
LUA

# The pack auto-starts on load (load = true). require "apcc_lite" does NOT
# resolve in a fresh home (module names register outside the init eval), so the
# headless path is load + documented env opts (e.g. APCC_THRESHOLD_TOKENS).
# Pre-grant the pack's permissions — the headless equivalent of the TUI's
# first-activation approval prompt (schema: site/pack-approvals.json).
mkdir -p "$HOME_SMOKE/.local/share/maki/site"
cat > "$HOME_SMOKE/.local/share/maki/site/pack-approvals.json" <<EOF
{
  "entries": {
    "apcc-lite": {
      "src": "$REPO",
      "permissions": ["fs_read", "fs_write", "net", "run", "env"]
    }
  }
}
EOF

# 2. Gate run in the cold home. HOME/XDG point at the cold home for this
#    invocation only — without the override maki silently uses the real home.
MODEL_ARGS=""
if [ -n "${MAKI_SMOKE_MODEL:-}" ]; then MODEL_ARGS="-m $MAKI_SMOKE_MODEL"; fi
OUT="$(cd "$HOME_SMOKE/proj" && \
  HOME="$HOME_SMOKE" \
  XDG_CONFIG_HOME="$HOME_SMOKE/.config" \
  XDG_DATA_HOME="$HOME_SMOKE/.local/share" \
  XDG_STATE_HOME="$HOME_SMOKE/.local/state" \
  XDG_CACHE_HOME="$HOME_SMOKE/.cache" \
  "$MAKI_BIN" --yolo $MODEL_ARGS -p "Reply with exactly: OK" 2>"$HOME_SMOKE/stderr.log")"
[ "$OUT" = "OK" ] || { echo "FAIL: gate run replied '$OUT' (want OK)"; exit 1; }
if grep -q "permission approval is required" "$HOME_SMOKE/stderr.log"; then
  echo "FAIL: pack permissions not approved in the smoke home"; exit 1
fi

# 3. Zero lua errors in the cold home's maki log.
LOG="$HOME_SMOKE/.local/logs/maki/maki.log"
if [ -f "$LOG" ] && grep -q 'runtime error\|require failed\|lua error' "$LOG"; then
  echo "FAIL: lua errors in smoke run log:"; grep 'runtime error\|require failed\|lua error' "$LOG"; exit 1
fi

# 4. Installed pack copy is byte-identical to the repo's entrypoint.
INSTALLED="$(find "$HOME_SMOKE/.local/share/maki/site/pack/core/apcc-lite" -name apcc-lite.lua | head -1)"
[ -n "$INSTALLED" ] || { echo "FAIL: pack not installed under site/pack/core/apcc-lite"; exit 1; }
if ! cmp -s "$INSTALLED" "$REPO/$ENTRY"; then
  echo "FAIL: installed pack differs from $ENTRY"; exit 1
fi

echo "SMOKE PASS: pack $REV installed byte-identical, gate run OK, log clean"
