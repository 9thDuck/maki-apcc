# apcc for Claude Code

Hook-based persist -> gate -> compact -> restore loop for Claude Code (same idea as the
maki plugin in `../plugin/`). Pure Node, no dependencies.

## Install

```sh
mkdir -p ~/.claude/hooks/apcc
cp apcc.mjs ~/.claude/hooks/apcc/
```

Merge the `hooks` block from `settings.example.json` into `~/.claude/settings.json`
(do not overwrite an existing `hooks` block; append to each event's array). The loop only
nudges when `autoCompactWindow` is set (or `CLAUDE_CODE_AUTO_COMPACT_WINDOW`).

## Test

```sh
node --test apcc.test.mjs
```

`apcc.live.mjs` runs the real hook CLI end to end and reads your real `~/.claude/settings.json`.

## Switches

`APCC_CC=0` disables it. `APCC_PERSIST_THRESHOLD_TOKENS` overrides the threshold. `APCC_DEBUG=1` prints errors.
