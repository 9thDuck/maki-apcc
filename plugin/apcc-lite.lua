-- apcc_lite.lua — persist -> compact -> restore for maki, v9.
-- FAITHFUL SEMANTIC PORT of the opencode persisting-context plugin v6.9.1
-- (opencode/plugins/persisting-context.js in the opencode repo,
-- ratified directive 2026-10-12). Delivery
-- channels are maki-native (slot wrappers, autocmds); the SEMANTICS — ladder,
-- floor, owner-order parsing, marker verification, recovery contract — are the
-- opencode plugin's, owner-ratified over months.
--
--   directive Rung 1: ONE persist directive per context epoch at/after the
--             persist threshold (opencode directiveSent). Delivered mid-turn
--             by blocking the first non-read, non-persist tool call (maki has
--             no promptAsync injection — the block IS the net) or at turn end.
--             Mains get stop-after-persist: "STOP this turn after the marker;
--             a prompt arriving mid-persist is folded and executed after
--             compaction." There is NO nudge repetition and NO tool gate after
--             the directive: an ignored directive escalates ONCE.
--   rung 2    ENFORCED FALLBACK: directive delivered, >= nudge_backoff_ms ago,
--             no marker, tokens still >= threshold -> forced compaction with
--             NO marker verification, receipted as the data-loss tradeoff
--             (opencode Branch B rung 2). Floor blocks it below the floor.
--   backstop  Ladder done (escalated or closed by a none-reply) and the
--             context keeps growing past the threshold -> compact regardless
--             of persist state (opencode backstop), still respecting
--             owner words and the floor.
--   floor     Marker floor = threshold - 1 (opencode upstream, owner-
--             ratified option (b)): an armed marker compacts at idle only
--             when CURRENT tokens >= floor; below it the marker STAYS ARMED
--             (carry-forward, no epoch close) and fires at the first idle
--             past the floor. A directive-armed marker inside the wobble band
--             (arming measurement crossed the threshold, idle re-measure
--             within floor_wobble_tokens below it) waives the floor. The
--             floor never decides on a stale (pre-compaction) measurement
--             (E-01). 0/false = kill switch; explicit floor >= threshold is
--             invalid and disables the floor with a loud once-per-epoch
--             receipt naming value, provenance, threshold.
--   manual    Marker tags: (manual) / (manual+compact). Reconcile rule
--             (opencode manual-tag mismatch): a manual marker with NO
--             recorded owner ask is treated as self-triggered (floor-gated);
--             (manual+compact) or a manual marker under a recorded owner
--             persist ask is owner-issued -> floor-exempt (owner discretion).
--             Maki deviation from opencode F1, owner's v8 call: a plain
--             (manual) persist below the floor does NOT fire — only an
--             explicit compaction authorization is exempt.
--   orders    OWNER WORDS DECIDE (opencode B1): owner messages are captured
--             (keyword-prefiltered ring, memory-only) and classified per
--             clause at decision time: question -> inert; past-tense report
--             -> inert; conditional ("compact when/if") -> inert; prohibition
--             ("don't/never [auto-]compact") -> PROHIBIT (latched; standing
--             forms survive epoch closes); negated compaction -> PROHIBIT;
--             session-object imperative ("compact the context") or
--             lead-word imperative ("compact now") -> compact ORDER; foreign
--             object ("tidy the imports") -> inert; casual ("fresh start")
--             -> order; persist asks -> recorded, never veto. LATEST WINS:
--             the last classified owner utterance decides; an explicit
--             compaction order clears a prohibition latch. A compaction
--             order with NO marker refuses fail-closed (the order is never
--             its own verification), receipted, throttled 1/min.
--   verify    Marker verification is all-or-nothing (opencode): every claimed
--             slug must exist in the .opencode/context/index.md table rows
--             AND declared units == slugs == distinct; slugs-missing /
--             count-mismatch get a 2-attempt retry window (armed-unverified,
--             receipted once), then loud abandonment consumes the marker;
--             ambiguous/empty claims consume immediately; index-read failure
--             counts against the shared attempt budget (cap 3). Maki keeps
--             its EVENTS channel (observed persist-class writes) as ground
--             truth: event-verified arms skip slug verification.
--   contract  Every compaction gets the recovery contract (opencode
--             contractText): honest three-way persist status (done /
--             none-claimed / not-done), index-first recovery map, reference-
--             don't-restate, and the machine line
--             `PERSIST: <date> | <slug> | <destination> | <in-flight state>`.
--             Post-commit the line is parsed, appended to the index, and
--             drives continuation: wake ONLY when owner-requested work was
--             pending (field-4 not quiet) or owner prompts were folded;
--             NEVER after a manual compaction (owner policy 2026-09-14
--             shape); failed wakes retry 5x at 30s at idles. Deviation from
--             maki v3's always-wake (owner call superseded by the
--             opencode-faithful directive, 2026-10-12).
--   modes     post_persist = "compact" (default) | "fresh" (event-verified
--             marker fires hand off to a NEW session; maki-native owner
--             call, kept). NEXT: line above the marker feeds the brief.
--   deps      beads (bd) optional: lazy probe; texts adapt.
--   bounds    attempts cap 3 paired to one marker (fresh marker re-arms);
--             compaction attempts separated by retry_window_ms; compaction
--             pending expires after a 15-min watchdog. The wake -> persist
--             -> fire loop is uncapped (owner call; APCC_LITE=0 kills all).
--
-- Fail-open everywhere: every entry point is pcall-wrapped and returns/pass-
-- through on any error. Kill switch: APCC_LITE=0. Test seam:
-- APCC_TEST_BACKOFF_MS compresses the rung-2 backoff for rig tests.
-- Token source: ctx.context_size / maki.session.read() — no transcript parsing.
-- State: <maki state dir>/apcc_lite/state-<sanitized cwd>.json (nono-allowlisted).

local M = {}

M.version = "0.2.0" -- release stamp (pack-lock pinning + field debugging via the loaded: log line)

-- ---- tunables ----
local defaults = {
  enabled = true,
  post_persist = "compact", -- "compact" (default) | "fresh": marker fire hands off to a new session
  beads = "auto",           -- "auto" probes bd on PATH | true | false
  threshold_ratio = 0.6,    -- unpinned threshold = ratio x context window (opencode THRESHOLD_RATIO)
  hard_limit_tokens = 0,    -- rung-2 token hard limit; 0 = threshold + 40k (capped under native auto-compact)
  persist_trigger_tokens = 0, -- absolute trigger (e.g. 135000 on a 512k window). 0 = derive from threshold_ratio
  floor_tokens = "auto",    -- "auto" = threshold - 1 | 0/false = kill switch | n = explicit floor
  enforced_fallback = true, -- rung 2: force compaction when the directive is ignored (opencode default ON)
  nudge_backoff_ms = 10 * 60 * 1000, -- rung 1 -> rung 2 escalation delay (opencode NUDGE_BACKOFF_MS)
  floor_wobble_tokens = 10000, -- FLOOR_WOBBLE_MARGIN: directive-armed meter wobble band
  attempt_cap = 3,          -- compaction attempts paired to one marker (opencode ATTEMPT_CAP)
  retry_window_ms = 60 * 1000, -- RETRY_WINDOW between compaction attempts
  utterance_ring_max = 12,  -- owner-utterance ring (memory-only)
  utterance_text_cap = 1500,
  fold_text_cap = 500,      -- fold display cap
}
local opts = {}

-- capability flags: texts adapt to what actually exists (lazy probe — never
-- on the plugin-load path; an eager probe hung /reload once).
local caps = { beads = true, probed = false }

local function probe_beads()
  if caps.probed then return caps.beads end
  caps.probed = true
  if opts.beads == true then
    caps.beads = true
  elseif opts.beads == false then
    caps.beads = false
  else
    local okp, resp = pcall(maki.fn.executable, "bd")
    caps.beads = (okp and resp == 1) or false
  end
  if not caps.beads then
    maki.log.warn("[apcc-lite] bd not found — beads persists disabled; file persists (.opencode/context/, docs/research/) carry the loop")
  end
  return caps.beads
end

local has_time = (os ~= nil and os.time ~= nil)
local function now_ms()
  if has_time then return os.time() * 1000 end
  return 0
end

-- test seam: compress the rung-2 backoff in rig tests only
local function backoff_ms()
  if has_time then
    local v = tonumber(maki.uv.os_getenv("APCC_TEST_BACKOFF_MS") or "")
    if v and v > 0 then return v end
  end
  return opts.nudge_backoff_ms
end

-- ---- state ----
local state_cache = nil

local function state_path()
  local dir = maki.fs.joinpath(maki.env.state_dir(), "apcc_lite")
  local proj = (maki.uv.cwd() or "unknown"):gsub("[^%w%-_%.]", "_")
  return maki.fs.joinpath(dir, "state-" .. proj .. ".json")
end

local function load_state()
  if state_cache then return state_cache end
  state_cache = { sessions = {} }
  local text = maki.fs.read(state_path())
  if text then
    local ok, data = pcall(maki.json.decode, text)
    if ok and type(data) == "table" and type(data.sessions) == "table" then
      state_cache = data
    end
  end
  return state_cache
end

-- utterances are MEMORY-ONLY decision evidence (opencode: stripped at save);
-- folds persist (they must survive a reload to reach the continuation).
local function save_state()
  local stripped = {}
  for sid, st in pairs(state_cache.sessions) do
    if type(st) == "table" and st.utterances then
      stripped[sid] = st.utterances
      st.utterances = nil
    end
  end
  maki.fs.mkdir(maki.fs.dirname(state_path()), { recursive = true })
  maki.fs.atomic_write(state_path(), maki.json.encode(state_cache))
  for sid, uts in pairs(stripped) do
    if state_cache.sessions[sid] then state_cache.sessions[sid].utterances = uts end
  end
end

local function fresh_session(t)
  return {
    epoch = 0, updatedAt = t,
    lastTokens = 0, lastTokensAt = 0, lastIdleTokens = 0, compactionEndedAt = 0,
    -- rung ladder
    directiveSent = false, directiveTokens = 0, nudgeCount = 0, nudgeLastAt = 0, directiveSentAt = 0,
    pendingNudge = nil, escalated = false,
    subagentsInFlight = 0,
    ladderClosedByNone = false, noneClaimedAt = 0,
    ladderClosedByUnits = false, commandPersist = false, commandPersistMarkerAt = 0,
    -- marker (opencode: armed marker is an epoch-scoped lifecycle)
    markerEpoch = -1, markerSeenAt = 0, markerOnly = false,
    markerManual = false, markerManualCompact = false,
    markerUnits = 0, markerSlugs = nil, markerAmbiguous = false, markerNext = "",
    markerVerifyAttempts = 0, markerVerifyReceipted = false, markerAbandoned = false,
    lastAttemptedMarkerEpoch = -1, attempts = 0,
    compactionPending = false, autoCompactAt = 0, backstopFiredAt = 0, lastOrderRefusalAt = 0,
    -- maki-native arm evidence (kept from v2: observed persist-class writes)
    persistEvents = 0, persistedEpoch = -1, persistedTokens = 0, lastPersistEventAt = 0, units = 0, nextAction = "",
    -- owner words (utterances memory-only; folds persisted)
    utterances = nil, folds = nil, recovered = false,
    prohibitedAt = 0, prohibitedStanding = false, prohibitedText = "", prohibitedMsg = "",
    intentReceiptKey = "",
    -- compaction provenance
    lastCompactReason = "", lastCompactManual = false,
    pendingContinuation = nil,
    -- one-per-epoch receipt latches (reset by new_epoch)
    floorConfigLogged = false, floorSkipLogged = false, floorStaleLogged = false,
    floorExemptLogged = false, floorWaiveLogged = false, stuckLogged = false,
    enforcedLogged = false, enforcedWithheldLogged = false, rungFloorLogged = false,
    nudgeMissLogged = false,
  }
end

local function new_epoch(st, t)
  local n = fresh_session(t)
  n.epoch = st.epoch + 1
  return n
end

local function session_state(sid, t)
  local all = load_state()
  local st = all.sessions[sid]
  if type(st) ~= "table" then
    st = fresh_session(t)
    all.sessions[sid] = st
  end
  return st
end

-- ---- decision core ----
local function k(n) return tostring(math.floor((n or 0) / 1000)) .. "k" end

local function resolve_threshold(window)
  if (opts.persist_trigger_tokens or 0) > 0 then return opts.persist_trigger_tokens end
  if (window or 0) <= 0 then return 0 end
  return math.floor(window * opts.threshold_ratio)
end

-- freshness-bound persist verification: the observed writes must belong to the
-- current epoch AND postdate both the directive and the last compaction end —
-- a stale persist tail from before the directive must not verify a later
-- compaction (status honesty: "done" means verified NOW, not someday)
local function events_verified(st)
  return (st.persistedEpoch or -1) == (st.epoch or -1)
    and (st.persistedTokens or 0) > 0
    and (st.lastPersistEventAt or 0) > math.max(st.directiveSentAt or 0, st.compactionEndedAt or 0)
end

-- rung-2 hard limit (token-shaped, not time-shaped): the enforced fallback
-- fires when TOKENS cross this line. Base: explicit hard_limit_tokens, else
-- threshold + 40k; then capped under maki's native auto-compact point
-- (usable = window - compaction_buffer, default 20%) minus a 10k margin so a
-- forced compaction always wins the race against the native one.
local function resolve_hard_limit(window)
  local base = 0
  if (opts.hard_limit_tokens or 0) > 0 then
    base = opts.hard_limit_tokens
  elseif (opts.persist_trigger_tokens or 0) > 0 then
    base = opts.persist_trigger_tokens + 40000
  elseif resolve_threshold(window) > 0 then
    base = resolve_threshold(window) + 40000
  end
  if (window or 0) <= 0 then return base end
  local usable = window - math.floor(window * 0.2) -- compaction_buffer default 20%
  local cap = usable - 10000
  if base <= 0 then return 0 end
  return math.min(base, cap)
end

-- floor verdict (opencode floorVerdict): explicit 0/false = kill switch;
-- explicit >= threshold = invalid (disable + loud receipt); "auto" (or nil)
-- derives threshold - 1.
local function floor_verdict(threshold)
  local raw = opts.floor_tokens
  if raw == false then return { floor = 0, source = "config", invalid = false } end
  if type(raw) == "number" then
    if raw > 0 then
      if threshold > 0 and raw >= threshold then
        return { floor = 0, source = "config", invalid = true }
      end
      return { floor = raw, source = "config", invalid = false }
    end
    if raw == 0 then return { floor = 0, source = "config", invalid = false } end
  end
  return { floor = (threshold > 0) and (threshold - 1) or 0, source = "auto", invalid = false }
end

local function measurement_fresh(st)
  local at = st.lastTokensAt or 0
  if at == 0 then return true end
  return at >= (st.compactionEndedAt or 0)
end

-- ---- owner-utterance classification (opencode B1, Lua pattern port) ----
local ORDER_KEYWORDS = { "persist", "save", "checkpoint", "compact", "compaction", "tidy",
  "keep", "write", "note", "record", "remember", "store", "stash" }
local COMPACT_WORDS = { "compact", "compaction", "tidy" }
local NEGATORS = { "no", "not", "don't", "dont", "never", "without", "stop" }
local IMPERATIVE_LEADS = { "please", "now", "then", "first", "next", "also", "just",
  "actually", "and", "run", "do", "trigger", "force", "start", "begin", "go" }
local SESSION_OBJECTS = { session = true, context = true, conversation = true,
  epoch = true, window = true, history = true }

-- boundary-checked keyword find: no word char or hyphen glued to either edge
-- (the regex \b(?:...)\b(?!-) shapes; Lua has no lookahead).
local function find_word(text, word, hyphen_right, start)
  local pos = start or 1
  while true do
    local s, e = text:find(word, pos, true)
    if not s then return nil end
    local before = s > 1 and text:sub(s - 1, s - 1) or ""
    local after = text:sub(e + 1, e + 1) or ""
    local left_ok = (before == "" or not before:match("[%w%-]"))
    local right_ok = (after == "" or not after:match("[%w%-]"))
    if hyphen_right and after == "-" then right_ok = false end
    if left_ok and right_ok then return s, e end
    pos = e + 1
  end
end

local function has_order_keyword(lower_text)
  for _, kw in ipairs(ORDER_KEYWORDS) do
    if find_word(lower_text, kw, false) then return true end
  end
  return false
end

local function find_compact_word(lower_text)
  for _, kw in ipairs(COMPACT_WORDS) do
    local s = find_word(lower_text, kw, true)
    if s then return s end
  end
  return nil
end

local function negated_compact(lower_text, cpos)
  local seg_start = 1
  for i = cpos - 1, 1, -1 do
    local ch = lower_text:sub(i, i)
    if ch:match("[%.%;%!%?]") or ch == "—" then seg_start = i + 1; break end
  end
  local seg = lower_text:sub(seg_start, cpos - 1)
  if #seg > 30 then seg = seg:sub(#seg - 29) end
  for _, neg in ipairs(NEGATORS) do
    if find_word(seg, neg, false) then return true end
  end
  return false
end

local function compact_object_session(lower_text)
  return lower_text:match("%f[%w](compact|tidy)%s+(up%s+)?(the%s+|this%s+|our%s+|a%s+)?(session|context|conversation|epoch|window|history)%f[%W]") ~= nil
end

local function compact_object_foreign(lower_text)
  for _, _, obj in lower_text:gmatch("%f[%w](compact|tidy|compaction)%s+(the|a|an|this|these|those|all|my|your)%s+([a-z]+)") do
    if not SESSION_OBJECTS[obj] then return true end
  end
  return false
end

local function past_tense_compact(lower_text)
  return lower_text:match("%f[%w](compact|compaction|tidy)%s+((was|is|has|had|got|just)%s+)?(done|finished|fired|ran|started|kicked|completed|happened|occurred|ended|failed)%f[%W]") ~= nil
end

local function conditional_compact(lower_text)
  return lower_text:match("%f[%w](compact|compaction|tidy)%s+(when|whenever|if|unless|until|once|after)%f[%W]") ~= nil
end

-- imperative shape: clause-initial (only whitespace/comma/dash before it) or
-- preceded by an imperative lead word (opencode COMPACT_IMPERATIVE_RE).
local function imperative_shape(lower_text, cpos)
  local seg_start = 1
  for i = cpos - 1, 1, -1 do
    local ch = lower_text:sub(i, i)
    if ch:match("[%.%;%!%?]") or ch == "—" then seg_start = i + 1; break end
  end
  local head = lower_text:sub(seg_start, cpos - 1)
  if head:match("^[%s,]*$") then return true end
  if head:match("^[%s%-—]+$") then return true end
  local lead = head:match("(%a+)%s*$")
  if lead then
    for _, w in ipairs(IMPERATIVE_LEADS) do
      if lead == w then return true end
    end
  end
  return false
end

local function casual_compact(lower_text)
  return lower_text:match("%f[%w](clear|wipe|freeing|free|empty)%s+(up%s+)?(the%s+)?(head|context|slate|window)%f[%W]") ~= nil
    or lower_text:match("%f[%w](fresh|clean)%s+(start|slate)%f[%W]") ~= nil
    or (find_word(lower_text, "start", false) ~= nil and lower_text:match("start%s+(fresh|over)%f[%W]") ~= nil)
end

local function prohibit_compact(lower_text)
  return lower_text:match("%f[%w](do%s+not|don't|dont|never)%s+(auto[-%s]?|tidy[-%s]?)?compact") ~= nil
    or lower_text:match("%f[%w]no%s+compaction%f[%W]") ~= nil
    or lower_text:match("%f[%w]without%s+compaction%f[%W]") ~= nil
end

local function standing_prohibit(lower_text)
  return find_word(lower_text, "never", false) ~= nil
    or lower_text:match("from%s+now%s+on") ~= nil
    or find_word(lower_text, "permanently", false) ~= nil
    or find_word(lower_text, "forever", false) ~= nil
    or find_word(lower_text, "always", false) ~= nil
    or lower_text:match("for%s+(this|the)%s+(session|project|repo|epoch)%f[%W]") ~= nil
end

local function persist_ask(lower_text)
  local verbs = { "keep", "save", "store", "stash", "write", "note", "record", "remember" }
  for _, v in ipairs(verbs) do
    local from = 1
    while true do
      local s, e = find_word(lower_text, v, false, from)
      if not s then break end
      local window = lower_text:sub(e + 1, e + 46)
      if window:match("^[%s%a%',%-]+(this|that|it|everything|the state|the context|for later|for now|down|somewhere)%f[%W]")
        or window:match("^[%s%a%',%-]+all of (this|that)")
        or window:match("^[%s%a%',%-]+somewhere safe") then
        return true
      end
      from = e + 1
    end
  end
  return false
end

local function has_persist_order(lower_text)
  return find_word(lower_text, "persist", false) ~= nil
    or find_word(lower_text, "save", false) ~= nil
    or find_word(lower_text, "checkpoint", false) ~= nil
end

-- classify one clause (opencode classifyClause order: question, past-tense,
-- prohibition, conditional, negation, session-object, foreign-object,
-- imperative, casual; then persist order/ask).
local function classify_clause(clause)
  local c = clause:lower()
  if c:match("%?%s*$") then return nil end
  if c == "" or not c:match("%a") then return nil end
  local cpos = find_compact_word(c)
  if cpos then
    if past_tense_compact(c) then return nil end
    if prohibit_compact(c) then return "prohibit" end
    if conditional_compact(c) then return nil end
    if negated_compact(c, cpos) then return "prohibit" end
    if compact_object_session(c) then return "compact" end
    if compact_object_foreign(c) then return nil end
    if imperative_shape(c, cpos) then return "compact" end
    if casual_compact(c) then return "compact" end
    return nil
  end
  if prohibit_compact(c) then return "prohibit" end
  if has_persist_order(c) then return "persist" end
  if persist_ask(c) then return "persist" end
  return nil
end

-- classify an utterance: strip double-quoted spans, classify per clause,
-- combine conservatively prohibit > compact > persist (opencode classifyUtterance).
local function classify_utterance(text)
  local stripped = text:gsub('"[^"]*"', " ")
  -- opencode CLAUSE_SPLIT_RE lookbehind semantics: `.`/`!`/`?` stay attached
  -- to the clause they end, so the question guard sees a trailing "?";
  -- `;` and em-dash are consumed as separators. (FX-006 class: the 2026-10-12
  -- 14:45Z latch fired on "did you stop the pre compaction work?" because the
  -- old splitter ate the "?" and the question guard never fired.)
  local marked = stripped:gsub("([%.%;%!%?])%s+", "%1\n")
  marked = marked:gsub("%s*[—]%s*", "\n"):gsub("%s*;%s*", "\n")
  local rank = { prohibit = 3, compact = 2, persist = 1 }
  local best = nil
  for clause in marked:gmatch("[^\n]+") do
    local kind = classify_clause(clause)
    if kind and (best == nil or rank[kind] > rank[best]) then best = kind end
  end
  return best
end

-- latest wins: the LAST classified owner utterance decides (opencode
-- resolveOwnerIntent); role resolution is structural in maki — the
-- user_message slot only sees owner input.
local function resolve_intent(st)
  local latest, latest_text = nil, nil
  local superseded = 0
  if type(st.utterances) == "table" then
    for _, u in ipairs(st.utterances) do
      local kind = classify_utterance(u.text or "")
      if kind then
        if latest then superseded = superseded + 1 end
        latest = kind
        latest_text = u.text
      end
    end
  end
  return { latest = latest, text = latest_text, superseded = superseded }
end

-- ---- texts ----
local function directive_text(tokens, threshold, stop_after)
  local lines = {
    "[apcc] This session is at ~" .. k(tokens) .. " tokens (pre-compaction persist threshold ~" .. k(threshold) .. ").",
    "Before continuing the owner's request: run the persist step now — visibly, in this turn.",
    "Persist the durable state per its routing (tracker notes first, index rows always):",
  }
  if probe_beads() then
    lines[#lines + 1] = "- progress / blocker / decision on a tracked task -> `bd note <id> --stdin`"
    lines[#lines + 1] = '- durable decision -> `bd create "Decision: <slug>" -t decision`'
  end
  lines[#lines + 1] = "- research or reusable findings -> docs/research/<topic>.md (one ## section per finding)"
  lines[#lines + 1] = "- in-flight state (where I am, tried/failed, exact next action) -> .opencode/context/session-notes.md (newest on top)"
  lines[#lines + 1] = "Append one line per unit to .opencode/context/index.md: `| date | slug | destination | one-line summary |` (ensure .opencode/ is gitignored first). Do not re-summarize units already persisted; point at them."
  lines[#lines + 1] = "If there is genuinely nothing durable to persist, do not manufacture units."
  lines[#lines + 1] = 'Either way, end this turn\'s reply with exactly one line, as its LAST line: `PERSISTED: <n> units (<slugs>)`, or `PERSISTED: none` if nothing needed saving. Optionally put `NEXT: <one-line next action>` on its own line right before the marker — it feeds the continuation brief.'
  lines[#lines + 1] = stop_after
    and "After the marker line, STOP this turn — do not continue other work (stop-after-persist). A prompt arriving mid-persist is folded into the persist and executed only after compaction. Owner directives always outrank this notice: if the owner's latest instruction was to stop or wait, persist (so nothing is lost) and then stop."
    or "Then continue your assigned task."
  return table.concat(lines, "\n")
end

local function escalation_text(tokens, threshold)
  return "[apcc][ESCALATION] This session is at ~" .. k(tokens) .. " tokens (persist threshold ~" .. k(threshold) .. ")."
    .. " The injected persist directive was ignored — no PERSISTED marker appeared, and the plugin could not force compaction itself."
    .. " The owner must act: run /persist now (or compact manually)."
    .. " This notice keeps recurring on a slower cadence while the context keeps growing — you will not be left in silence."
end

-- /persist command text (opencode commands/persist.md, ported to maki's
-- routing). Persist ONLY — compaction and continuation stay with the apcc
-- loop (owner directive 2026-10-12). Not [apcc]-prefixed: it is a genuine
-- owner-triggered prompt and must go through the normal capture path.
local function command_persist_text()
  return table.concat({
    "[/persist] Execute the persist step now for this session, visibly, in this turn.",
    "Distill the conversation into durable units: in-flight state (task, where it stopped, the exact next action), decisions, gotchas, pending owner decisions. Never persist trivia, tool output, or secrets (redact).",
    "Routing: tracker notes first (`bd note <id> --stdin`; `bd create` only for genuinely new work items), index rows always, deep units to docs under `.opencode/context/`.",
    "Every unit appends exactly one row to `.opencode/context/index.md` (`| date | slug | destination | one-line summary |`). The index stays shallow — a map, never contents.",
    "Do not re-summarize units that are already persisted; point at them.",
    "Do not explore, refactor, or change code. Persist, then stop.",
    "If there is genuinely nothing durable to persist, do not manufacture units.",
    "Finish your reply with exactly one line, as the last line:",
    "PERSISTED: <n> units (<comma-separated slugs>) — or — PERSISTED: none (nothing durable)",
  }, "\n")
end

local function contract_text(status)
  local status_line
  if status == "done" then
    status_line = "Pre-compaction persist: DONE this context epoch — its units are in the recovery map and tracker. Point at them; do not re-summarize them."
  elseif status == "none" then
    status_line = "Pre-compaction persist: NONE-CLAIMED this context epoch — the model reported nothing durable to persist (none-reply). If that is wrong, the units are NOT in the recovery map."
  else
    status_line = "Pre-compaction persist: NOT DONE this context epoch — carry critical in-flight state directly in this summary (it will not survive otherwise), kept short."
  end
  return table.concat({
    "## Persisting-context contract (auto-injected)",
    "",
    status_line,
    "The authoritative recovery map is `.opencode/context/index.md`.",
    "",
    "Your summary MUST include, verbatim where possible:",
    "- An explicit first recovery step: read `.opencode/context/index.md` before re-exploring",
    "- Open tracker/bead IDs and any pending user decisions — reference them, do not restate their content",
    "- In-flight state ONLY for anything that could not be persisted",
    "",
    "Do not re-summarize units already persisted (bead notes, topic docs, session notes); point to them instead. Keep the summary short.",
    "",
    "Finally, emit exactly one machine-parsed line as the last line of the summary:",
    "PERSIST: <YYYY-MM-DD> | <short-slug> | <destination> | <one-line in-flight state>",
    "(destination = the tracker ID, doc path, or the literal word index; this line keeps the recovery index current)",
    "The owner's newest message wins over any recovered plan or note.",
  }, "\n")
end

local function continuation_text(state, folds, unverified)
  local lines = {
    "[apcc] Auto-resume: this session was auto-compacted and the compaction summary reports pending owner-requested work"
      .. ((state and state ~= "") and (' (pre-compaction in-flight state: "' .. state .. '").') or "."),
    "Read .opencode/context/index.md first (the recovery map), pull only the units the task needs, and continue from the exact next action. Do not re-explore or redo completed work. If the work turns out to be resolved, say so and stop.",
    "Your first state claim must cite a freshly read artifact.",
    "Owner directives outrank this hook: if the owner's latest instruction was to stop or wait, do NOT continue — acknowledge and stand by.",
  }
  if unverified then
    table.insert(lines, 2, "The pre-compaction persist was NOT verified — the in-flight state above was carried in the compaction summary, not the recovery map; re-verify against freshly read artifacts before trusting it.")
  end
  if folds and #folds > 0 then
    lines[#lines + 1] = "Owner prompts that arrived mid-persist (folded — execute them as part of continuing):"
    for _, f in ipairs(folds) do
      local txt = tostring(f.text or "")
      if #txt > opts.fold_text_cap then txt = txt:sub(1, opts.fold_text_cap) .. "…" end
      lines[#lines + 1] = "- " .. txt:gsub("\n", " ")
    end
  end
  return table.concat(lines, "\n")
end

local function handoff_text(next_action)
  local cont = (next_action and next_action ~= "")
    and ("Then continue: " .. next_action)
    or "Then continue the interrupted work (the newest index rows and the plan say where it stands)."
  return "[apcc] Fresh session continuing prior work in this project (the previous session is intact — /sessions lists it if you need history). "
    .. "Re-read .opencode/context/index.md first (it is the map), then pull only the units the current task needs. " .. cont
    .. " Your first state claim must cite a freshly read artifact."
    .. " Owner directives outrank this hook: if the owner's latest instruction was to stop or wait, do NOT continue — acknowledge and stand by."
end

-- ---- marker grammar (end-anchored, outside an unbalanced fence) ----
-- Canonical: `PERSISTED: <n> units (<slugs>)` with optional (manual) /
-- (manual+compact) tag right after PERSISTED; `PERSISTED: none` never arms.
local function parse_marker(text)
  if type(text) ~= "string" or text == "" then return { kind = "none" } end
  local fences = 0
  for line in text:gmatch("[^\n]+") do
    if line:match("^%s*```") then fences = fences + 1 end
  end
  if fences % 2 == 1 then return { kind = "none" } end
  local prev_line, last = "", ""
  for line in text:gmatch("[^\n]+") do
    local t = line:match("^%s*(.-)%s*$")
    if t ~= "" then prev_line = last; last = t end
  end
  local lower = last:lower()
  -- hardening: a NEXT: line after the marker is the common model slip; accept
  -- marker+NEXT (marker still within the last two non-empty lines)
  local next_after = nil
  if not lower:match("^persisted") and lower:match("^next:") then
    local nl = prev_line:lower()
    if nl:match("^persisted") then
      next_after = last:match("^%s*[Nn][Ee][Xx][Tt]:%s*(.+)$")
      prev_line, last = "", prev_line
      lower = last:lower()
    end
  end
  if not lower:match("^persisted") then return { kind = "none" } end
  local manual_compact = lower:match("^persisted%s*%(%s*manual%+compact%s*%)") ~= nil
  local manual = manual_compact or lower:match("^persisted%s*%(%s*manual%s*%)") ~= nil
  local after = lower:match(":%s*(.+)$")
  if not after then return { kind = "none" } end
  if after:match("^none") then
    return { kind = "acknowledged", manual = manual, manual_compact = manual_compact }
  end
  local units = tonumber(after:match("^(%d+)%s+units?"))
  if not (units and units > 0) then
    return { kind = "acknowledged", manual = manual, manual_compact = manual_compact }
  end
  local next_action = next_after
  if not next_action then
    local ntail = prev_line:lower():match("^next:%s*(.+)$")
    if ntail then next_action = prev_line:sub(#prev_line - #ntail + 1) end
  end
  -- trailing paren group = slug list; another '(' before it = ambiguous (fail-closed)
  local slugs, ambiguous = {}, false
  local tail = after:match("%(([^%(%)]*)%)%s*$")
  if tail then
    local group_start = after:find(tail, 1, true)
    local first_open = after:find("%(", 1, false)
    if first_open and group_start and first_open < group_start - 1 then ambiguous = true end
    for slug in tail:gmatch("[^,]+") do
      slug = slug:match("^%s*(.-)%s*$")
      if slug ~= "" then slugs[#slugs + 1] = slug end
    end
  end
  return { kind = "persisted", manual = manual, manual_compact = manual_compact,
    units = units, slugs = slugs, ambiguous = ambiguous, next_action = next_action }
end

-- ---- marker verification (all-or-nothing vs index.md table rows) ----
local function read_index_slugs()
  local proj = maki.uv.cwd() or "."
  local idx = maki.fs.joinpath(proj, ".opencode", "context", "index.md")
  local text = maki.fs.read(idx)
  if not text then return nil end
  local slugs = {}
  for line in text:gmatch("[^\n]+") do
    if line:match("^%s*|") then
      local cols = {}
      for col in line:gmatch("[^|]+") do cols[#cols + 1] = col:match("^%s*(.-)%s*$") end
      if #cols >= 2 and cols[1]:match("^%d%d%d%d%-%d%d%-%d%d$") then
        slugs[#slugs + 1] = cols[2]
      end
    end
  end
  return slugs
end

-- returns true (verified) or false, reason-class
local function verify_marker_slugs(marker)
  if marker.ambiguous then return false, "ambiguous-claim-set" end
  if not marker.slugs or #marker.slugs == 0 then return false, "empty-claim-set" end
  local rows = read_index_slugs()
  if rows == nil then return false, "index-read-failed" end
  local present = {}
  for _, s in ipairs(rows) do present[s] = true end
  for _, s in ipairs(marker.slugs) do
    if not present[s] then return false, "slugs-missing" end
  end
  local seen, distinct = {}, 0
  for _, s in ipairs(marker.slugs) do
    if not seen[s] then seen[s] = true; distinct = distinct + 1 end
  end
  if marker.units ~= #marker.slugs or marker.units ~= distinct then
    return false, "count-mismatch"
  end
  return true
end

-- ---- environment guards ----
local function enabled()
  if not opts.enabled then return false end
  local sw = maki.uv.os_getenv("APCC_LITE")
  if sw == "0" or sw == "false" then return false end
  return true
end

local function tracked()
  local proj = maki.uv.cwd() or ""
  for _, marker in ipairs({ ".beads", ".opencode/context" }) do
    local meta = maki.fs.metadata(maki.fs.joinpath(proj, marker))
    if meta then return true end
  end
  return false
end

local function main_session(ctx)
  if ctx and ctx.task_id then return nil end -- subagent: its own window
  return (ctx and ctx.session_id) or maki.session.current() or "headless"
end

local function read_tokens(ctx, sid)
  if ctx and ctx.context_size and ctx.context_size > 0 then return ctx.context_size, ctx.context_window end
  local s = maki.session.read({ session = sid })
  if not s then return 0, 0 end
  return s.context_size or 0, s.context_window or 0
end

-- tool allowlist for the directive net: read-class tools always pass
local READ_TOOLS = {
  read = true, grep = true, glob = true, index = true,
  list = true, skill = true,
  webfetch = true, code_execution = false,
}
local PERSIST_DEST = { [".opencode/context/"] = true, ["docs/research/"] = true }

local PERSIST_WRITE_TOOLS = { write = true, edit = true, multiedit = true, edit_lines = true }
local function is_persist_write(tool, value)
  if tool == "bash" and type(value.command) == "string" then
    local flat = " " .. value.command:gsub("%s+", " ") .. " "
    if flat:find(" bd note ", 1, true) or flat:find(" bd create ", 1, true) or flat:find(" bd remember ", 1, true)
      or flat:find(" bd comment ", 1, true) then
      return true
    end
    for dest in pairs(PERSIST_DEST) do
      if flat:find(dest, 1, true)
        and (flat:find(">>", 1, true) or flat:find(" > ", 1, true) or flat:find("tee ", 1, true)
          or flat:find("sed -i", 1, true) or flat:find("cp ", 1, true) or flat:find("mv ", 1, true)) then
        return true
      end
    end
    return false
  end
  if not PERSIST_WRITE_TOOLS[tool] then return false end
  local target = tostring(value.path or value.file_path or "")
  if target == "" then return false end
  for dest in pairs(PERSIST_DEST) do
    if target:find(dest, 1, true) then return true end
  end
  return false
end

-- PERSIST: <date> | <slug> | <destination> | <in-flight state> (opencode
-- extractPersistLine: first matching line, exactly 4 non-empty fields)
local function extract_persist_line(text)
  if type(text) ~= "string" then return nil end
  for line in text:gmatch("[^\n]+") do
    local tail = line:match("^%s*PERSIST:%s*(.-)%s*$")
    if tail then
      local parts = {}
      for part in tail:gmatch("[^|]+") do parts[#parts + 1] = part:match("^%s*(.-)%s*$") end
      if #parts ~= 4 then return nil end
      for _, p in ipairs(parts) do if p == "" then return nil end end
      return parts
    end
  end
  return nil
end

-- quiet-state denylist: unrecognized in-flight text defaults to CONTINUE
-- (opencode QUIET_STATE_RE — the continuation prompt tells the model to stop
-- if the work turns out resolved).
local function quiet_state(state)
  if state:match("^none%f[%W]") or state:match("^none$") then return true end
  if state:match("^nothing%f[%W]") or state:match("^nothing$") then return true end
  if state:match("^no in%-flight") or state:match("^no pending") then return true end
  if state:match("^nothing durable") then return true end
  if state:match("^awaiting user") then return true end
  if state:match("^waiting for%s+(the%s+)?(user|owner|input|approval|review)") then return true end
  if state:match("^blocked on%s+(user|owner)") then return true end
  if state:match("^all%s+(work%s+)?(done|complete[d]?)") then return true end
  if state:match("^resolved") then return true end
  return false
end

-- v4 pack opt path: a pack module loads after init.lua, so consumers cannot
-- call setup() there — env overrides fill the gap (checked after the table,
-- so an explicit setup call still wins).
local function env_overrides()
  local pv = maki.uv.os_getenv("APCC_POST_PERSIST")
  if pv == "fresh" or pv == "compact" then opts.post_persist = pv end
  local bv = maki.uv.os_getenv("APCC_BEADS")
  if bv == "true" then opts.beads = true elseif bv == "false" then opts.beads = false end
  local tv = tonumber(maki.uv.os_getenv("APCC_THRESHOLD_TOKENS") or "")
  if tv and tv > 0 then opts.persist_trigger_tokens = math.floor(tv) end
end

-- ---- public setup ----

function M.setup(user_opts)
  opts = {}
  for kk, v in pairs(defaults) do opts[kk] = v end
  if type(user_opts) == "table" then
    for kk, v in pairs(user_opts) do
      if defaults[kk] ~= nil or kk == "floor_tokens" then opts[kk] = v end
    end
  end
  if opts.post_persist ~= "fresh" then opts.post_persist = "compact" end
  if opts.beads ~= true and opts.beads ~= false then opts.beads = "auto" end
  if opts.floor_tokens == nil then opts.floor_tokens = "auto" end
  env_overrides() -- pack: env opts fill the gap (a pack module loads after init.lua)
end

function M.start()
  if not enabled() then
    maki.log.info("[apcc-lite] disabled (APCC_LITE=0 or setup) — inert")
    return
  end

  local idle_dispatch -- forward decl (agent.stop's test seam calls it; defined below)

  -- compaction dispatch (maki-native channel; opencode uses session.summarize)
  local function dispatch_compaction(st, sid, kind, threshold)
    local okc, errc = maki.api.run_command("/compact")
    if okc then
      maki.log.info("[apcc-lite] compaction dispatched (" .. kind .. ") -> session " .. tostring(sid))
      return true
    end
    st.compactionPending = false
    if kind == "marker" and (st.attempts or 0) >= opts.attempt_cap then
      st.markerEpoch = -1
      st.armed = false
      st.markerAbandoned = true
      maki.log.warn("[apcc-lite] auto-compaction abandoned after " .. tostring(opts.attempt_cap)
        .. " attempts — marker consumed (abandonment is receipted)")
    end
    if kind ~= "marker" then st.escalated = true end
    st.pendingNudge = escalation_text(st.lastTokens or 0, threshold or 0)
    save_state()
    maki.log.warn("[apcc-lite] compaction dispatch failed (" .. tostring(errc) .. ") — escalation notice queued")
    return false
  end

  -- agent.stop: marker lifecycle, rung-1 directive, pending escalation notice.
  maki.api.set_slot("agent.stop", function(prev, stop, ctx)
    local seam_sid = nil
    local ok, res = pcall(function()
      local sid = main_session(ctx)
      seam_sid = sid
      if not sid or not tracked() then return nil end
      local t = now_ms()
      local tokens, window = read_tokens(ctx, sid)
      if tokens <= 0 or window <= 0 then return nil end
      local threshold = resolve_threshold(window)
      local st = session_state(sid, t)
      -- meter fell off a cliff -> new epoch (host compaction we did not see)
      if st.lastTokens > 0 and tokens < st.lastTokens * 0.6 then
        maki.log.warn("[apcc-lite] token cliff (~" .. k(st.lastTokens) .. " -> ~" .. k(tokens)
          .. ") — new context epoch assumed (host compaction we did not see)")
        st = new_epoch(st, t)
        load_state().sessions[sid] = st
      end
      st.lastTokens = tokens
      st.lastTokensAt = t

      local marker = parse_marker(stop and stop.last_message or nil)
      if marker.kind ~= "none" then
        local prior_units = st.persistedEpoch == st.epoch and st.units or 0
        st.persistedEpoch = st.epoch
        st.persistedTokens = tokens
        st.units = math.max(marker.units or 0, prior_units)
        st.nextAction = marker.next_action or ""
        -- a marker reply answers the directive: consume the rung-1 counter but
        -- KEEP directiveSent latched until epoch close (opencode: the fold
        -- window stays open; resetting here would re-deliver the directive
        -- after every compliant persist)
        st.nudgeCount = 0
        st.nudgeLastAt = 0
        st.pendingNudge = nil
        if marker.kind == "acknowledged" then
          -- none-reply closes the ladder for this epoch (opencode ladderClosedByNone)
          st.ladderClosedByNone = true
          st.noneClaimedAt = t
          st.commandPersist = false
          st.markerEpoch = -1
          st.markerSeenAt = 0
          st.markerOnly = false
          st.armed = false
          maki.log.info("[apcc-lite] none-reply: persist ladder closed for this epoch (nothing durable reported)")
        else
          st.markerEpoch = st.epoch
          st.markerSeenAt = t
          st.markerManual = marker.manual or false
          st.markerManualCompact = marker.manual_compact or false
          st.markerUnits = marker.units
          st.markerSlugs = marker.slugs
          st.markerAmbiguous = marker.ambiguous or false
          st.markerNext = marker.next_action or ""
          st.markerVerifyAttempts = 0
          st.markerVerifyReceipted = false
          st.markerAbandoned = false
          if st.commandPersist then
            -- owner directive 2026-10-12: /persist is PERSIST-ONLY. The marker
            -- is recorded and the rung ladder closes, but the follow-through
            -- (compaction + continuation) stays with the apcc loop. A later
            -- explicit owner compaction order verifies against this marker via
            -- commandPersistMarkerAt (opencode OQ-2 recovery: "persist
            -- genuinely, then re-order to compact").
            st.commandPersistMarkerAt = t
            st.ladderClosedByUnits = true
            st.armed = false
            st.commandPersist = false
            maki.log.info("[apcc-lite] /persist marker recorded (units=" .. tostring(marker.units)
              .. ") — persist-only, no follow-through (owner directive 2026-10-12)")
          elseif (st.persistEvents or 0) > 0 then
            st.markerOnly = false
            st.armed = true
          else
            st.markerOnly = true
            st.armed = true
            maki.log.warn("[apcc-lite] armed on marker without observed persist writes (unverified)")
          end
          maki.log.info("[apcc-lite] persist marker (units=" .. tostring(marker.units)
            .. ", events=" .. tostring(st.persistEvents or 0) .. ", armed=" .. tostring(st.armed)
            .. ", manual=" .. tostring(st.markerManual) .. "+" .. tostring(st.markerManualCompact)
            .. ") at ~" .. k(tokens) .. " tokens")
        end
        save_state()
        return nil
      end

      -- pending escalation notice (single-writer latch, delivered once)
      if st.pendingNudge then
        local p = st.pendingNudge
        st.pendingNudge = nil
        save_state()
        maki.log.warn("[apcc-lite] escalation notice delivered")
        return { continue = p }
      end

      -- rung 1: the persist directive, ONCE per epoch (opencode directiveSent)
      if threshold > 0 and tokens >= threshold and not st.directiveSent
        and not st.ladderClosedByNone and not st.ladderClosedByUnits then
        st.directiveSent = true
        st.directiveTokens = tokens
        st.nudgeCount = math.max(st.nudgeCount or 0, 1)
        st.nudgeLastAt = t
        st.directiveSentAt = t
        st.escalated = false
        save_state()
        maki.log.warn("[apcc-lite] persist directive (rung 1) at ~" .. k(tokens)
          .. " (threshold ~" .. k(threshold) .. ")")
        return { continue = directive_text(tokens, threshold, true) }
      end
      return nil
    end)
    if not ok then
      maki.log.warn("[apcc-lite] stop layer errored; failing open: " .. tostring(res))
      return prev(stop, ctx)
    end
    -- Idle chain at turn end: turn end IS an effective idle, and
    -- SessionStatusChanged is not reliably delivered after /reload (observed:
    -- a TUI session whose idle chain never ran post-reload while agent.stop
    -- kept working). compactionPending + retry_window guard double-dispatch
    -- against the SessionStatusChanged path.
    if seam_sid then
      idle_dispatch(seam_sid, now_ms())
    end
    if res then return res end
    return prev(stop, ctx)
  end)

  -- tool.*.input: persist-event recording + rung-1 mid-turn net. NO gate
  -- ladder: after the directive is delivered, tools pass (opencode has no
  -- gate; rung 2 is the stick).
  maki.api.set_slot("tool.*.input", function(prev, value, ctx)
    local ok, deny = pcall(function()
      local tool = ctx and ctx.tool or ""
      -- v2 persist-event recording (maki-native ground truth; subagent calls
      -- attributed to the focused main session)
      if is_persist_write(tool, value or {}) then
        local ev_sid = main_session(ctx) or maki.session.current()
        if ev_sid and tracked() then
          local t_ev = now_ms()
          local st_ev = session_state(ev_sid, t_ev)
          st_ev.persistEvents = (st_ev.persistEvents or 0) + 1
          st_ev.persistedEpoch = st_ev.epoch
          st_ev.persistedTokens = read_tokens(nil, ev_sid)
          st_ev.lastPersistEventAt = t_ev
          save_state()
          maki.log.info("[apcc-lite] persist event #" .. tostring(st_ev.persistEvents)
            .. " (" .. tool .. (ctx and ctx.task_id and ", subagent" or "") .. ") -> session " .. ev_sid)
        end
      end
      local sid = main_session(ctx)
      if not sid or not tracked() then return nil end
      if READ_TOOLS[tool] then return nil end
      if is_persist_write(tool, value or {}) then return nil end -- never block a persist attempt
      -- rung 1 net: deliver the directive ONCE via the owned channel
      -- (maki.session.prompt starts/queues a turn of our own — no tool denial,
      -- no stolen turn); on dispatch failure fall back to the denial path.
      local st = session_state(sid, now_ms())
      if not st.directiveSent and not st.ladderClosedByNone and not st.ladderClosedByUnits then
        local tokens_m, window_m = read_tokens(nil, sid)
        if tokens_m > 0 and window_m > 0 then
          local threshold_m = resolve_threshold(window_m)
          if threshold_m > 0 and tokens_m >= threshold_m then
            local t_m = now_ms()
            st.directiveSent = true
            st.directiveTokens = tokens_m
            st.nudgeCount = math.max(st.nudgeCount or 0, 1)
            st.nudgeLastAt = t_m
            st.directiveSentAt = t_m
            st.escalated = false
            save_state()
            local state_p, errp = maki.session.prompt(directive_text(tokens_m, threshold_m, true), { session = sid })
            if state_p then
              maki.log.warn("[apcc-lite] persist directive (rung 1, mid-turn net) at ~" .. k(tokens_m)
                .. " -> owned-channel prompt (" .. tostring(state_p) .. ") -> session " .. sid)
            else
              maki.log.warn("[apcc-lite] owned-channel prompt failed (" .. tostring(errp)
                .. ") — blocking the " .. tool .. " call to deliver the directive in-band")
              return nil, directive_text(tokens_m, threshold_m, true)
            end
          end
        end
      end
      -- Branch B rung 2, mid-turn (opencode: "Branch B rung 2 owns
      -- the no-idle case" — the 44m41s no-idle incident): the directive was
      -- delivered, TOKENS crossed the hard limit, still no marker and NO idle
      -- fire — force the compaction mid-turn instead of stranding the session
      -- past the hard limit. Once per epoch (escalated); the idle rung 2 owns
      -- retries. Backoff no longer gates this: the limit is the trigger.
      if st.directiveSent and (st.nudgeCount or 0) > 0 and not st.armed
        and not st.ladderClosedByNone and not st.ladderClosedByUnits
        and not st.escalated and not st.compactionPending
        and (st.prohibitedAt or 0) == 0 then
        local tokens_e, window_e = read_tokens(nil, sid)
        local t_e = now_ms()
        local threshold_e = resolve_threshold(window_e)
        if threshold_e > 0 and tokens_e >= resolve_hard_limit(window_e)
          and (t_e - (st.autoCompactAt or 0)) >= (opts.retry_window_ms or 120000) then
          st.escalated = true
          st.compactionPending = true
          st.autoCompactAt = t_e
          save_state()
          maki.log.warn("[apcc-lite] ENFORCED FALLBACK (mid-turn, no idle since the directive): forced compaction proceeds; persist UNVERIFIED — the data-loss tradeoff is receipted")
          dispatch_compaction(st, sid, "enforced-midturn", threshold_e)
          return nil
        end
      end
      -- Strand margin (upstream fix, STRAND_MARGIN_TOKENS = 25k): an ARMED
      -- marker whose session keeps generating past threshold + 25k with no
      -- idle fire must not strand (the owner's "never strand the session at
      -- high context" / the 200k shape) — force the follow-through mid-turn.
      -- WITHHELD while subagents are in flight (their turns still owe persist
      -- writes) — unless tokens cross the hard limit, where the limit wins.
      local tokens_s, window_s = read_tokens(nil, sid)
      if st.armed and st.markerEpoch == st.epoch and not st.compactionPending
        and (st.prohibitedAt or 0) == 0
        and ((st.subagentsInFlight or 0) == 0 or tokens_s >= resolve_hard_limit(window_s)) then
        local t_s = now_ms()
        local threshold_s = resolve_threshold(window_s)
        if threshold_s > 0 and tokens_s >= threshold_s + 25000
          and (t_s - (st.markerSeenAt or 0)) >= backoff_ms()
          and (t_s - (st.autoCompactAt or 0)) >= (opts.retry_window_ms or 120000) then
          st.compactionPending = true
          st.autoCompactAt = t_s
          save_state()
          maki.log.warn("[apcc-lite] STRAND GUARD: armed marker stranded past threshold+25k with no idle fire — forcing the follow-through compaction")
          dispatch_compaction(st, sid, "strand", threshold_s)
          return nil
        end
      end
      return nil
    end)
    if not ok then
      maki.log.warn("[apcc-lite] net layer errored; failing open: " .. tostring(deny))
      return prev(value, ctx)
    end
    if deny then return nil, deny end
    return prev(value, ctx)
  end)

  -- agent.user_message: owner-utterance capture (decision evidence) +
  -- fold window (owner prompts arriving mid-persist, executed post-compaction).
  -- Plugin-carried texts ([apcc]-prefixed) never capture.
  maki.api.set_slot("agent.user_message", function(prev, value, ctx)
    local oku, resu = pcall(function()
      local sid = main_session(ctx)
      if not sid or not tracked() then return nil end
      local text
      if type(value) == "string" then text = value
      elseif type(value) == "table" and type(value.text) == "string" then text = value.text end
      if text == nil or text == "" then return nil end
      local st = session_state(sid, now_ms())
      local t = now_ms()
      if text:find("^%[apcc%]") then
        st.recovered = true -- wake/continuation carried the recovery line already
        save_state()
        return nil
      end
      -- post-compaction recovery prefix on the first owner message of a fresh
      -- epoch (covers MANUAL compactions, which never auto-continue)
      local prefix = nil
      if not st.recovered and (st.epoch or 0) > 0 then
        st.recovered = true
        prefix = "[apcc] Recovery: re-read .opencode/context/index.md first (it is the map), then pull only the units the current task needs."
          .. " Your first state claim must cite a freshly read artifact, not the summary."
          .. " Owner directives outrank this hook: if the owner's latest instruction was to stop or wait, do NOT resume — acknowledge and stand by.\n\n"
        maki.log.info("[apcc-lite] recovery prefix injected (epoch " .. tostring(st.epoch) .. ")")
      end
      -- fold window: owner prompt arriving while the persist directive is latched
      if st.directiveSent then
        st.folds = st.folds or {}
        st.folds[#st.folds + 1] = { at = t, text = text:sub(1, opts.utterance_text_cap) }
        if #st.folds > 20 then table.remove(st.folds, 1) end
        maki.log.info("[apcc-lite] owner prompt folded mid-persist (" .. tostring(#st.folds) .. " folded)")
      end
      -- decision evidence: keyword-prefiltered, memory-only
      if has_order_keyword(text:lower()) then
        st.utterances = st.utterances or {}
        st.utterances[#st.utterances + 1] = { at = t, text = text:sub(1, opts.utterance_text_cap) }
        if #st.utterances > opts.utterance_ring_max then table.remove(st.utterances, 1) end
      end
      save_state()
      if prefix == nil then return nil end
      if type(value) == "string" then return prefix .. value end
      local nv = {}
      for kk, v in pairs(value) do nv[kk] = v end
      nv.text = prefix .. text
      return nv
    end)
    if oku and resu then return resu end
    return prev(value, ctx) -- capture only unless the recovery prefix rewrites
  end)

  -- agent.compact.before: the recovery contract into EVERY compaction
  -- (opencode contractText via experimental.session.compacting).
  maki.api.set_slot("agent.compact.before", function(prev, prep, ctx)
    local ok, res = pcall(function()
      local sid = main_session(ctx)
      if not sid or not tracked() then return nil end
      local st = session_state(sid, now_ms())
      -- SKIP VETO (maki agent.compact.before skip=true): a NATIVE auto compaction
      -- arriving while our own persist turn is still pending would summarize
      -- UNVERIFIED state — defer it. Never vetoed: manual/overflow reasons, our
      -- own dispatched compaction (compactionPending), a closed ladder, an armed
      -- fresh marker, verified events, or tokens at/over the hard limit (there
      -- the enforced fallback must win the race).
      local reason_v = tostring(prep and prep.reason or "")
      if reason_v == "auto" and not st.compactionPending
        and not st.ladderClosedByNone and not st.ladderClosedByUnits
        and st.directiveSent
        and not (st.armed and st.markerEpoch == st.epoch
          and (st.markerSeenAt or 0) > (st.directiveSentAt or 0))
        and not events_verified(st) then
        local tokens_v, window_v = read_tokens(nil, sid)
        if (tokens_v or (prep and prep.context_size) or 0) < resolve_hard_limit(window_v) then
          maki.log.warn("[apcc-lite] native auto-compact deferred: persist turn pending, tokens below hard limit — agent.compact.before asked to skip")
          return { skip = true }
        end
      end
      local status = "not-done"
      -- hybrid verification (v2 ground truth): observed persist writes this
      -- epoch (is_persist_write events) prove persist just like a marker —
      -- below the threshold the directive never fires, so the marker cannot
      -- exist and events are the ONLY evidence (live incident 2026-10-12)
      -- (events_verified is freshness-bound: post-directive/post-compaction only)
      if st.armed and st.markerEpoch == st.epoch
        and (st.markerSeenAt or 0) > (st.directiveSentAt or 0) then
        status = "done"
      elseif events_verified(st) then
        status = "done"
      elseif (st.noneClaimedAt or 0) > (st.compactionEndedAt or 0) then
        status = "none"
      end
      local reason = tostring(prep and prep.reason or "?")
      st.lastCompactReason = reason
      st.lastPersistStatus = status -- restore honesty: what CompactionDone may propagate
      -- our OWN dispatched compaction (compactionPending) is never "manual" —
      -- maki's run_command("/compact") reports a manual-ish reason string
      st.lastCompactManual = (not st.compactionPending) and reason:find("manual", 1, true) ~= nil
      save_state()
      maki.log.info("[apcc-lite] compaction (" .. reason .. ") — persist status: " .. status)
      return { instructions = contract_text(status) }
    end)
    if ok and res then return res end
    return prev(prep, ctx)
  end)

  -- restore half: any compaction starts a new context epoch. Continuation
  -- policy (opencode owner policy 2026-09-14): wake ONLY when owner-requested
  -- work was pending (summary PERSIST line field 4 not quiet) or owner
  -- prompts were folded mid-persist; NEVER after a manual compaction.
  maki.api.create_autocmd("CompactionDone", {
    callback = function(ev)
      pcall(function()
        if not enabled() then return end
        local ev_sid = ev.data and ev.data.session_id
        if ev_sid and load_state().sessions[ev_sid] == nil then
          -- epoch hygiene: subagent/foreign sessions own no apcc state — never
          -- fold their compactions into a main session's epoch (no current()
          -- fallback for ids we do not track)
          maki.log.info("[apcc-lite] CompactionDone for untracked session " .. tostring(ev_sid)
            .. " — ignored (subagent or foreign)")
          return
        end
        local sid = ev_sid or maki.session.current() or "headless"
        local t = now_ms()
        local prev_st = session_state(sid, t)
        local status = prev_st.lastPersistStatus or "not-done"
        load_state().sessions[sid] = new_epoch(prev_st, t)
        local st = session_state(sid, t)
        st.compactionEndedAt = t
        save_state()
        maki.log.info("[apcc-lite] CompactionDone -> new context epoch " .. tostring(prev_st.epoch + 1))
        -- PERSIST: line -> index row, gated on status honesty: only a verified
        -- "done" propagates the summary's line; "not-done" appends an explicit
        -- UNVERIFIED marker row instead; "none" appends nothing (no stale line).
        local parts = extract_persist_line(ev.data and ev.data.summary)
        local state_field = nil
        local unverified = false
        if parts and status == "done" then
          local proj = maki.uv.cwd() or "."
          local idx = maki.fs.joinpath(proj, ".opencode", "context", "index.md")
          if not maki.fs.metadata(idx) then
            maki.fs.mkdir(maki.fs.dirname(idx), { recursive = true })
            maki.fs.atomic_write(idx,
              "# Context index — shallow map, never contents\n\n| date | slug | destination | one-line summary |\n|---|---|---|---|\n")
          end
          local row = "| " .. parts[1] .. " | " .. parts[2]:gsub("|", "\\|") .. " | "
            .. parts[3]:gsub("|", "\\|") .. " | " .. parts[4]:gsub("|", "\\|") .. " |\n"
          maki.fs.atomic_write(idx, maki.fs.read(idx) .. row)
          state_field = parts[4]
          maki.log.info("[apcc-lite] summary PERSIST line appended to index (" .. parts[2] .. ")")
        elseif parts and status == "not-done" then
          local proj = maki.uv.cwd() or "."
          local idx = maki.fs.joinpath(proj, ".opencode", "context", "index.md")
          if not maki.fs.metadata(idx) then
            maki.fs.mkdir(maki.fs.dirname(idx), { recursive = true })
            maki.fs.atomic_write(idx,
              "# Context index — shallow map, never contents\n\n| date | slug | destination | one-line summary |\n|---|---|---|---|\n")
          end
          local ts = "unknown"
          if has_time and os.date then
            ts = os.date("%Y-%m-%d %H:%M", math.floor(t / 1000))
          end
          local row = "| " .. (has_time and os.date and os.date("%Y-%m-%d", math.floor(t / 1000)) or "unknown")
            .. " | unverified | - | PERSIST: UNVERIFIED " .. ts:gsub("|", "\\|") .. " |\n"
          maki.fs.atomic_write(idx, maki.fs.read(idx) .. row)
          state_field = parts[4]
          unverified = true
          maki.log.info("[apcc-lite] persist NOT verified this epoch — UNVERIFIED row appended to index (summary PERSIST line withheld)")
        end
        if prev_st.lastCompactManual then
          maki.log.info("[apcc-lite] manual compaction — no auto-continue")
          return
        end
        local folds = prev_st.folds
        local pending = nil
        if state_field and state_field ~= "" and not quiet_state(state_field) then
          pending = state_field
        end
        if pending == nil and (folds == nil or #folds == 0) then
          maki.log.info("[apcc-lite] no pending work in the summary — staying quiet")
          return
        end
        local prompt = continuation_text(pending, folds, unverified)
        local okw, errw = maki.session.notify(prompt, { session = sid, wake = true })
        if okw then
          maki.log.info("[apcc-lite] auto-continue: continuation wake dispatched -> session " .. sid)
        else
          local nst = session_state(sid, now_ms())
          nst.pendingContinuation = { tries = 0, prompt = prompt, at = now_ms() }
          save_state()
          maki.log.warn("[apcc-lite] continuation wake failed (" .. tostring(errw) .. ") — will retry at idles")
        end
      end)
    end,
  })

  -- Idle dispatch (SessionStatusChanged leaving "working"): the opencode
  -- gate chain in order — intent decisions, prohibit latch, marker freshness,
  -- retry window, attempt budget, floor (E-01 stale / carry-forward /
  -- wobble / owner exemption), fire; then Branch B rung 2 (enforced) and the
  -- backstop; plus the pending-continuation retry driver.
  -- The chain is a function so the test seam (APCC_TEST_FIRE=1) can run it
  -- at agent.stop in headless -p runs, where SessionStatusChanged never fires.
  idle_dispatch = function(sid, t)
    pcall(function()
    if not sid or not tracked() then return end
    local t = now_ms()
    local st = session_state(sid, t)

    -- pending-continuation retry driver (5 x 30s, opencode shape)
    if st.pendingContinuation and has_time then
      local pc = st.pendingContinuation
      if t - (pc.at or 0) >= 30000 then
        local okw = maki.session.notify(pc.prompt, { session = sid, wake = true })
        if okw then
          st.pendingContinuation = nil
          maki.log.info("[apcc-lite] continuation retry delivered")
        else
          pc.tries = (pc.tries or 0) + 1
          pc.at = t
          if (pc.tries or 0) >= 5 then
            st.pendingContinuation = nil
            maki.log.warn("[apcc-lite] continuation abandoned after 5 retries")
          end
        end
        save_state()
      end
    end

    -- token telemetry
    local tokens, window = read_tokens(nil, sid)
    if tokens > 0 then
      st.growthContinuing = (st.lastIdleTokens or 0) > 0 and tokens > st.lastIdleTokens or false
      st.lastTokens = tokens
      st.lastTokensAt = t
      st.lastIdleTokens = tokens
    end
    local threshold = resolve_threshold(window)
    local floor_v = floor_verdict(threshold)
    if floor_v.invalid and not st.floorConfigLogged then
      st.floorConfigLogged = true
      save_state()
      maki.log.warn("[apcc-lite] invalid floor " .. tostring(opts.floor_tokens)
        .. " (>= threshold ~" .. k(threshold) .. ", source " .. floor_v.source
        .. ") — floor DISABLED (kill-switch behavior); fix the config")
    end
    local floor = floor_v.floor
    local fresh = measurement_fresh(st)
    local fresh_marker = st.armed and st.markerEpoch == st.epoch
    local recently_requested = has_time and (st.autoCompactAt or 0) > 0
      and (t - st.autoCompactAt < opts.retry_window_ms)
    -- watchdog: a compaction that never commits releases the chain
    if st.compactionPending and has_time and (t - (st.autoCompactAt or 0)) > (15 * 60 * 1000) then
      st.compactionPending = false
      maki.log.warn("[apcc-lite] compaction pending expired (watchdog) — chain released")
    end

    -- owner words decide first (opencode resolveOwnerIntent before guards)
    local intent = resolve_intent(st)

    if intent.latest == "prohibit" then
      local standing = intent.text and standing_prohibit(intent.text:lower()) or false
      if (st.prohibitedAt or 0) == 0 or intent.text ~= st.prohibitedText then
        st.prohibitedAt = t
        st.prohibitedStanding = standing
        st.prohibitedText = intent.text and intent.text:sub(1, 200) or ""
        st.prohibitedMsg = "utterance-" .. tostring(#(st.utterances or {}))
        save_state()
        maki.log.warn('[apcc-lite] owner prohibition latched ("' .. st.prohibitedText
          .. '"' .. (standing and ", standing" or ", epoch-scoped")
          .. ((intent.superseded or 0) > 0 and (", supersedes " .. intent.superseded .. " earlier order(s)") or "")
          .. ") — auto-compaction gated")
      end
      return
    end

    if intent.latest == "compact" then
      if recently_requested then return end
      -- hybrid verification (v2 ground truth restored for the v9 ladder):
      -- marker OR /persist marker (OQ-2) OR observed persist writes this
      -- epoch — the order is never its own verification, but the map writes are
      -- (events_verified is freshness-bound; the /persist marker must postdate it too)
      local command_verified = (st.commandPersistMarkerAt or 0) > math.max(st.directiveSentAt or 0, st.compactionEndedAt or 0)
      local verified = fresh_marker or command_verified or events_verified(st)
      if not verified then
        if not has_time or not st.lastOrderRefusalAt or (t - st.lastOrderRefusalAt >= 60000) then
          st.lastOrderRefusalAt = t
          save_state()
          maki.log.warn("[apcc-lite] owner compaction order REFUSED: no persist marker and no persist events on record (the order is never its own verification) — persist first")
        end
        return
      end
      maki.log.info("[apcc-lite] owner-ordered compaction verified ("
        .. (fresh_marker and "marker" or command_verified and "/persist marker"
          or "events #" .. tostring(st.persistEvents or 0) .. ", ~" .. k(st.persistedTokens or 0) .. " of map writes")
        .. ")")
      st.prohibitedAt = 0; st.prohibitedStanding = false; st.prohibitedText = ""; st.prohibitedMsg = ""
      st.attempts = 0
      st.lastAttemptedMarkerEpoch = st.markerEpoch
      st.lastPersistStatus = "done" -- the order verified against fresh evidence
      st.compactionPending = true
      st.autoCompactAt = t
      save_state()
      maki.log.info("[apcc-lite] owner-ordered compaction triggered (latest-wins supersedes any prohibition)")
      dispatch_compaction(st, sid, "owner-order", threshold)
      return
    end

    if intent.latest == "persist" then
      maki.log.info("[apcc-lite] owner persist ask on record — never vetoes the idle fire")
    end

    -- prohibit latch gates the default path (receipt keyed, no noise)
    if (st.prohibitedAt or 0) > 0 and fresh_marker then
      local latch_key = "prohibit-latch:" .. tostring(st.prohibitedAt) .. ":marker"
      if st.intentReceiptKey ~= latch_key then
        st.intentReceiptKey = latch_key
        save_state()
        maki.log.warn('[apcc-lite] auto-compaction skipped: '
          .. (st.prohibitedStanding and "standing" or "epoch-scoped")
          .. ' owner prohibition gates the follow-through ("' .. st.prohibitedText .. '")')
      end
      return
    end

    -- marker path: freshness, retry window, attempt budget
    local new_marker = fresh_marker and st.markerEpoch ~= st.lastAttemptedMarkerEpoch
    local stand_down = (st.attempts or 0) >= opts.attempt_cap
    if fresh_marker and not recently_requested and not st.compactionPending
      and not (stand_down and not new_marker) then
      -- floor checks (never on a stale measurement — E-01)
      local proceed = true
      if floor > 0 then
        if not fresh then
          if not st.floorStaleLogged then
            st.floorStaleLogged = true
            save_state()
            maki.log.info("[apcc-lite] auto-compaction deferred: stale token measurement — the floor needs a fresh measurement; the armed marker stays armed")
          end
          proceed = false
        elseif (st.lastTokens or 0) < floor then
          -- owner-issued exemption: explicit compaction authorization only
          -- (maki v8 owner call: a plain persist below the floor never fires)
          local owner_issued = st.markerManualCompact == true
            or (st.markerManual == true and intent.latest == "compact")
          local wobble = st.directiveSent and (st.directiveTokens or 0) >= threshold
            and (st.lastTokens or 0) >= (threshold - opts.floor_wobble_tokens)
          if owner_issued then
            if not st.floorExemptLogged then
              st.floorExemptLogged = true
              save_state()
              maki.log.info("[apcc-lite] owner-issued persist below the floor — owner discretion wins over the floor (receipted exemption)")
            end
          elseif wobble then
            if not st.floorWaiveLogged then
              st.floorWaiveLogged = true
              save_state()
              maki.log.info("[apcc-lite] floor waived (directive-armed wobble band): arming measurement ~"
                .. k(st.directiveTokens) .. " crossed the threshold; idle re-measure ~" .. k(st.lastTokens))
            end
          else
            -- carry-forward: the marker STAYS ARMED, no epoch closes
            if not st.floorSkipLogged then
              st.floorSkipLogged = true
              save_state()
              maki.log.info("[apcc-lite] auto-compaction skipped: floor holds (~" .. k(st.lastTokens)
                .. " < floor ~" .. k(floor) .. ") — the armed marker stays armed for the first idle past the floor")
            end
            proceed = false
          end
        end
      end
      if proceed then
        -- marker verification (marker-only arms; events are ground truth)
        local verified = true
        local reason = nil
        if st.markerOnly then
          verified, reason = verify_marker_slugs({
            units = st.markerUnits, slugs = st.markerSlugs, ambiguous = st.markerAmbiguous,
          })
        end
        if not verified and reason == "index-read-failed" then
          -- counts against the shared attempt budget (cap 3)
          maki.log.warn("[apcc-lite] marker verification deferred: index unreadable (attempt "
            .. tostring(st.attempts + 1) .. "/" .. tostring(opts.attempt_cap) .. ")")
          proceed = false -- retried at the next idle via the attempt chain
        elseif not verified then
          -- retry window: 2 attempts, then loud abandonment consumes
          st.markerVerifyAttempts = (st.markerVerifyAttempts or 0) + 1
          if st.markerVerifyAttempts < 2 then
            if not st.markerVerifyReceipted then
              st.markerVerifyReceipted = true
              save_state()
              maki.log.warn("[apcc-lite] marker UNVERIFIED (" .. reason .. ") — claimed units not all in the index; armed-unverified, retrying at the next idle")
            end
            proceed = false
          else
            st.markerEpoch = -1
            st.armed = false
            st.markerAbandoned = true
            save_state()
            maki.log.warn("[apcc-lite] marker verification ABANDONED after 2 attempts (" .. reason .. ") — marker consumed; persist ladder re-opens")
            proceed = false
          end
        end
      end
      if proceed then
        st.attempts = (st.attempts or 0) + 1
        st.lastAttemptedMarkerEpoch = st.markerEpoch
        st.compactionPending = true
        st.autoCompactAt = t
        save_state()
        maki.log.info("[apcc-lite] auto-compaction triggered (armed marker, epoch "
          .. tostring(st.markerEpoch) .. ", attempt " .. tostring(st.attempts) .. ")")
        -- maki-native fresh handoff (owner call; event-verified only)
        if opts.post_persist == "fresh" and (st.persistEvents or 0) > 0 then
          local prompt = handoff_text(st.markerNext ~= "" and st.markerNext or st.nextAction or "")
          maki.log.info("[apcc-lite] fresh handoff prompt: " .. prompt)
          local okn, errn = maki.session.new({ prompt = prompt, focus = true })
          if okn then
            maki.log.info("[apcc-lite] fresh handoff: new session " .. tostring(okn) .. " spawned")
            return
          end
          maki.log.warn("[apcc-lite] fresh handoff failed (" .. tostring(errn) .. ") — falling back to /compact")
        end
        dispatch_compaction(st, sid, "marker", threshold)
      end
      return
    end

    -- blocked marker chain: stuck-marker diagnostic (f2fb shape)
    if fresh_marker and not st.compactionPending and floor > 0 and fresh
      and (st.lastTokens or 0) >= floor and not st.stuckLogged
      and (recently_requested or (stand_down and not new_marker)) then
      st.stuckLogged = true
      save_state()
      maki.log.warn("[apcc-lite] stuck-marker diagnostic: an armed persist marker is past the floor (~"
        .. k(st.lastTokens) .. " >= ~" .. k(floor) .. ") but no compaction fired at this idle — reason: "
        .. (recently_requested and "retry window" or "attempt cap exhausted with no new marker"))
    end

    -- Branch B rung 2 (enforced fallback): directive delivered, TOKENS at the
    -- hard limit, still no marker -> forced compaction, persist UNVERIFIED
    -- (backoff no longer gates this path — the hard limit is the trigger)
    if not fresh_marker and not st.compactionPending and not recently_requested
      and st.directiveSent and (st.nudgeCount or 0) > 0 and not st.ladderClosedByNone
      and not st.ladderClosedByUnits
      and fresh and threshold > 0 and (st.lastTokens or 0) >= resolve_hard_limit(window)
      and has_time then
      if not opts.enforced_fallback then
        if not st.enforcedWithheldLogged then
          st.enforcedWithheldLogged = true
          save_state()
          maki.log.info("[apcc-lite] enforced fallback withheld (enforced_fallback=false)")
        end
      elseif floor > 0 and (st.lastTokens or 0) < floor then
        if not st.rungFloorLogged then
          st.rungFloorLogged = true
          save_state()
          maki.log.info("[apcc-lite] enforced fallback deferred: floor holds — never force compaction below the floor")
        end
      elseif (st.prohibitedAt or 0) > 0 then
        if not st.enforcedWithheldLogged then
          st.enforcedWithheldLogged = true
          save_state()
          maki.log.info('[apcc-lite] enforced fallback withheld: owner prohibition ("' .. st.prohibitedText .. '")')
        end
      else
        if not st.enforcedLogged then
          st.enforcedLogged = true
          st.escalated = true
          save_state()
          -- honest receipt (hybrid): events may have already proven persist —
          -- the marker tail is only the model's DECLARATION channel
          -- (events_verified is freshness-bound: post-directive/post-compaction only)
          if events_verified(st) then
            maki.log.warn("[apcc-lite] ENFORCED FALLBACK: persist verified by events (#"
              .. tostring(st.persistEvents or 0) .. ", ~" .. k(st.persistedTokens or 0)
              .. " of map writes) but the PERSISTED marker tail was never written — forcing the follow-through compaction")
          else
            maki.log.warn("[apcc-lite] ENFORCED FALLBACK: the persist directive was ignored (no marker, no events, tokens at the hard limit) — forced compaction proceeds; persist UNVERIFIED — the data-loss tradeoff is receipted")
            pcall(maki.notify, "[apcc] compacted WITHOUT a verified persist — summary carries unsaved state")
            pcall(maki.session.notify, "[apcc] compacted WITHOUT a verified persist — summary carries unsaved state", { session = sid, wake = false })
          end
        end
        st.compactionPending = true
        st.autoCompactAt = t
        save_state()
        dispatch_compaction(st, sid, "enforced", threshold)
        return
      end
    end

    -- backstop: ladder done and the context keeps growing past the
    -- threshold -> compact regardless of persist state (upstream).
    -- WITHHELD while subagents are in flight — unless tokens cross the hard
    -- limit, where the enforced fallback wins regardless.
    local ladder_done = st.escalated or st.ladderClosedByNone
    if ladder_done and not st.compactionPending and not recently_requested
      and threshold > 0 and (st.lastTokens or 0) >= threshold
      and st.growthContinuing and (st.prohibitedAt or 0) == 0
      and ((st.subagentsInFlight or 0) == 0 or (st.lastTokens or 0) >= resolve_hard_limit(window))
      and has_time and (t - (st.backstopFiredAt or 0)) >= (opts.retry_window_ms * 2) then
      st.backstopFiredAt = t
      st.compactionPending = true
      st.autoCompactAt = t
      save_state()
      maki.log.warn("[apcc-lite] BACKSTOP: the persist ladder is done and the context keeps growing past the threshold — compacting regardless of persist state")
      dispatch_compaction(st, sid, "backstop", threshold)
    end
    end)
  end

  maki.api.create_autocmd("SessionStatusChanged", {
    callback = function(ev)
      pcall(function()
        local d = ev.data or {}
        if d.status == "working" then return end
        local sid = d.session_id or maki.session.current()
        if not sid then return end
        idle_dispatch(sid, now_ms())
      end)
    end,
  })

  -- subagent lifecycle (TaskStatusChanged): in-flight subagents withhold the
  -- strand guard and the backstop — a subagent's turn may still owe persist
  -- writes, so firing under it would summarize UNVERIFIED state. The hard
  -- limit still wins: at resolve_hard_limit the enforced fallback fires.
  maki.api.create_autocmd("TaskStatusChanged", {
    callback = function(ev)
      pcall(function()
        local d = ev.data or {}
        local sid = d.session_id or maki.session.current()
        if not sid then return end
        local st_t = session_state(sid, now_ms())
        if d.status == "working" then
          st_t.subagentsInFlight = (st_t.subagentsInFlight or 0) + 1
          maki.log.info("[apcc-lite] subagent started (" .. tostring(d.name or "?")
            .. ") — in-flight " .. tostring(st_t.subagentsInFlight) .. " -> session " .. sid)
        elseif d.status == "done" or d.status == "error" then
          st_t.subagentsInFlight = math.max(0, (st_t.subagentsInFlight or 0) - 1)
          maki.log.info("[apcc-lite] subagent " .. tostring(d.status) .. " (" .. tostring(d.name or "?")
            .. ") — in-flight " .. tostring(st_t.subagentsInFlight) .. " -> session " .. sid)
        end
        save_state()
      end)
    end,
  })

  -- /persist command (opencode commands/persist.md): persist ONLY. The
  -- compaction + continuation succession belongs to the apcc loop (owner
  -- directive 2026-10-12). A marker from a /persist turn is recorded and
  -- closes the rung ladder but never arms; a later explicit owner compaction
  -- order verifies against it via commandPersistMarkerAt.
  maki.api.register_command({
    name = "/persist",
    description = "Persist durable session context now, visibly. Persist only — compaction/continuation stay with the apcc loop.",
    nargs = "*",
    handler = function(cmd_opts)
      local sid = maki.session.current()
      if not sid or not tracked() then
        maki.notify("/persist: no tracked session focused")
        return
      end
      local st = session_state(sid, now_ms())
      st.commandPersist = true
      save_state()
      local text = command_persist_text()
      local cargs = (cmd_opts and cmd_opts.args) or ""
      if cargs ~= "" then text = text .. "\n\n" .. cargs end
      local state, err = maki.session.prompt(text)
      if not state then
        st.commandPersist = false
        save_state()
        maki.log.warn("[apcc-lite] /persist prompt failed: " .. tostring(err))
        maki.notify("/persist failed: " .. tostring(err))
        return
      end
      maki.log.info("[apcc-lite] /persist command (" .. tostring(state) .. ") -> session " .. sid)
    end,
  })

  maki.log.info("[apcc-lite] loaded v" .. tostring(M.version or "?") .. " (opencode-faithful): rung1 directive (once/epoch, stop-after-persist,"
    .. " owned-channel session.prompt with denial fallback) + rung2 enforced fallback on a token hard limit"
    .. " (subagent withholding) + agent.compact.before auto-skip veto + backstop + marker floor"
    .. " (threshold-1, carry-forward, wobble) + freshness-bound verification"
    .. " + owner-order/prohibition latches (latest-wins) + marker verification (all-or-nothing)"
    .. " + recovery contract + folds + quiet-unless-pending continuation (post_persist="
    .. tostring(opts.post_persist) .. ", beads=" .. tostring(opts.beads) .. ", enforced_fallback="
    .. tostring(opts.enforced_fallback) .. ")")
end

-- Pack installs: settings come from env (APCC_POST_PERSIST, APCC_BEADS,
-- APCC_THRESHOLD_TOKENS). Auto-start with defaults + env overrides; fail-open.
-- Vendored consumers: APCC_NO_AUTOSTART=true before require(), then .setup()/.start().
if _G.APCC_NO_AUTOSTART ~= true then
  local ok_auto, err_auto = pcall(function()
    M.setup()
    M.start()
  end)
  if not ok_auto then
    maki.log.warn("[apcc-lite] auto-start failed: " .. tostring(err_auto))
  end
end

return M
