-- agents: what each AI agent running in a pane is doing.
--
-- Reads `ai peers --json` every few seconds (ai-session: each agent's
-- profile, repo, branch, busy or idle, and its ranma pane), and:
--   - marks each agent pane's border: ● working, ? needs you (it went idle
--     while you were not looking), nothing once you have seen it;
--   - toasts when an agent finishes out of sight, saying which agent
--     (its session name and profile), what it was on, and where (session,
--     workspace, pane); a click on the toast jumps to its pane (ranma with
--     toast.on_click);
--   - leader i opens a screen of every agent, grouped: Needs you, Working,
--     Idle, with the selected one's last lines below.
-- On the screen: enter jump to its pane, m message it (ai send), x stop it
-- (esc into its pane), o options.
--
-- An agent that is not Claude Code reports no state to ai; it is listed as
-- running, and its screen is watched for a question (agents.ask). A Claude
-- agent whose state is missing for a look (ai could not ask Claude) keeps
-- the last one it had: it is never watched, as Claude's own footer reads
-- like a question. One toast per wait: an agent already waiting on you is
-- not toasted again until it has been busy. On a machine without `ai`, the
-- plugin stays quiet.
--
-- ranma's plugin API: https://github.com/masshirodev/ranma/blob/main/doc/CONFIG.md.

ranma.option("agents.poll", {
  type = "int", min = 2, max = 30, default = 3, slider = false,
  name = "Look every", desc = "Seconds between two looks at the agents (ai peers).",
})
ranma.option("agents.notify", {
  type = "bool", default = true,
  name = "Toast when done", desc = "A toast when an agent finishes in a pane you are not looking at.",
})
ranma.option("agents.badges", {
  type = "bool", default = true,
  name = "Badges", desc = "Mark agent panes' borders: ● working, ? needs you.",
})
ranma.option("agents.ask", {
  type = "string", default = [[(?i)(proceed\?|\(y/n\)|\[y/n\]|allow .*\?|approve .*\?|permission required)]],
  name = "Asking looks like",
  desc = "A regex for an agent asking something on its screen, for agents that tell ai nothing of their state (not Claude).",
})

local OWNER = "agents"

-- id -> { peer = the last ai peers entry, state = "busy" | "idle" | "running",
--         needs = true while it waits for you, since = os.time() of the change }
local agents = {}
local order = {}
local screen = nil
local broken = false
local timer = nil

local function ago(t)
  local s = os.time() - t
  if s < 60 then return s .. "s" end
  if s < 3600 then return (s // 60) .. "m" end
  return (s // 3600) .. "h"
end

local function pane_of(a)
  return a.peer.pane and ranma.pane(tonumber(a.peer.pane)) or nil
end

local function badge(a)
  local p = pane_of(a)
  if not p then return end
  if not ranma.get("agents.badges") then return p:badge(OWNER) end
  if a.needs then
    p:badge(OWNER, "?", "needs you", "urgent")
  elseif a.state == "busy" then
    p:badge(OWNER, "●", "working", "accent")
  else
    p:badge(OWNER)
  end
end

-- The last lines an agent printed, blank ones dropped.
local function tail(p, n)
  if not p then return { "(its pane is gone)" } end
  local top, bottom = p:range()
  local out = {}
  for _, l in ipairs(p:lines(math.max(top, bottom - 40), bottom)) do
    if l:match("%S") then out[#out + 1] = l end
  end
  local from = math.max(1, #out - n + 1)
  return table.move(out, from, #out, 1, {})
end

local function focus(p)
  if p then
    p:focus()
    if screen then screen:close(); screen = nil end
  end
end

local function jump(id)
  local a = agents[id]
  focus(a and pane_of(a))
end

-- Only Claude Code tells ai busy or idle; every other agent is watched.
local function reports_state(peer)
  return peer.provider == "claude"
end

-- Which agent: its session name (kumiko-87) and profile.
local function who(peer, id)
  local name = peer.name or peer.repo or (peer.folder or ""):match("[^/]+$") or id
  local profile = peer.profile or peer.provider
  return profile and (name .. " (" .. profile .. ")") or name
end

-- Where its pane is: the session when it is not the one shown, the
-- workspace, the pane.
local function where(peer)
  local p = peer.pane and ranma.pane(tonumber(peer.pane))
  if not p then return "" end
  local bits = {}
  if p.session ~= ranma.state().session then bits[#bits + 1] = p.session end
  bits[#bits + 1] = p.workspace == 0 and "scratchpad" or ("ws " .. p.workspace)
  bits[#bits + 1] = "pane " .. p.id
  return " · " .. table.concat(bits, " · ")
end

-- A toast that jumps to the agent's pane when clicked, where ranma can.
local clickable = ranma.has and ranma.has("toast.on_click")
local function toast(peer, text)
  local opts = { urgent = true }
  local pane = tonumber(peer.pane)
  if clickable and pane then
    opts.on_click = function() focus(ranma.pane(pane)) end
  end
  ranma.toast(text .. where(peer), opts)
end

local function body()
  local groups = { { "Needs you", {} }, { "Working", {} }, { "Idle", {} } }
  for _, id in ipairs(order) do
    local a = agents[id]
    local g = a.needs and 1 or (a.state == "busy" or a.state == "running") and 2 or 3
    table.insert(groups[g][2], a)
  end
  local out = {}
  for _, g in ipairs(groups) do
    if #g[2] > 0 then
      out[#out + 1] = { "heading", g[1], count = #g[2] }
      for _, a in ipairs(g[2]) do
        local peer, p = a.peer, pane_of(a)
        local value
        if a.needs then value = { "? " .. ago(a.since), "urgent" }
        elseif a.state == "busy" then value = { "● " .. ago(a.since), "accent" }
        elseif a.state == "running" then value = { "running", "dim" }
        else value = { "✓ " .. ago(a.since) .. " ago", "dim" } end
        local where = p and ((p.workspace == 0 and "S" or tostring(p.workspace)) .. "  ") or ""
        local folder = (peer.folder or ""):gsub("^" .. (os.getenv("HOME") or "~"), "~")
        local keys = { { "enter", "jump", jump } }
        if peer.provider == "claude" or peer.provider == "codex" or peer.provider == "opencode" then
          keys[#keys + 1] = { "m", "message", function(rid)
            ranma.input { title = "message " .. rid, on_submit = function(text)
              if text == "" then return end
              ranma.spawn({ "ai", "send", rid, text }, { on_exit = function(r)
                ranma.notify(r.code == 0 and ("sent to " .. rid) or ("ai send: " .. (r.stderr ~= "" and r.stderr or tostring(r.error))))
              end })
            end }
          end }
        end
        if a.state == "busy" then
          keys[#keys + 1] = { "x", "stop", function(rid)
            local q = agents[rid] and pane_of(agents[rid])
            if q then q:keys("escape"); ranma.notify("sent esc to " .. rid) end
          end }
        end
        local lines = {}
        for _, l in ipairs(tail(p, 6)) do lines[#lines + 1] = l end
        out[#out + 1] = {
          "row", id = peer.id,
          name = (peer.repo or "?") .. " · " .. (peer.profile or peer.provider or "?"),
          note = where .. folder,
          value = value,
          keys = keys,
          detail = {
            { "log", lines = lines },
            { "facts", { "pane", peer.pane or "-" }, { "", peer.branch or "" },
              { "", peer.title or "" },
              peer.unread and { "mail", tostring(peer.unread), role = "accent" } or nil },
          },
        }
      end
    end
  end
  return out
end

local function status()
  local needs, busy = 0, 0
  for _, a in pairs(agents) do
    if a.needs then needs = needs + 1 elseif a.state == "busy" then busy = busy + 1 end
  end
  if needs > 0 then return { needs .. (needs == 1 and " needs you" or " need you"), "urgent" } end
  if busy > 0 then return { busy .. " working", "accent" } end
  return { "all idle", "dim" }
end

local function refresh_screen()
  if not screen then return end
  screen:set { body = body(), status = status(), count = #order .. (#order == 1 and " agent" or " agents") }
end

-- An agent that reports no state asked something on its screen: out of
-- sight, that is "needs you", as Claude going idle is.
local function asked(id, e)
  local a = agents[id]
  local p = a and pane_of(a)
  -- Already waiting: the question redrawn is not a second one.
  if not a or not p or p.visible or a.needs then return end
  a.needs, a.since = true, os.time()
  if ranma.get("agents.notify") then
    toast(a.peer, who(a.peer, id) .. " asks: " .. e.row:gsub("^%s+", ""):gsub("%s+$", ""))
  end
  badge(a)
  refresh_screen()
end


local function update(peers)
  local seen, now = {}, os.time()
  local focused = ranma.state().focused
  order = {}
  for _, peer in ipairs(peers) do
    if not peer.self then
      local id = peer.id
      seen[id] = true
      order[#order + 1] = id
      local a = agents[id]
      -- A Claude agent without a state is one ai could not ask this time,
      -- not one that reports none: it keeps the last state it had.
      local state = peer.state
        or (reports_state(peer) and a and a.state)
        or "running"
      if not a then
        a = { since = now }
        agents[id] = a
      elseif a.state ~= state then
        a.since = now
        -- Busy to idle: it finished or stopped to ask. Out of sight, that
        -- is news; in sight, you saw it.
        if a.state == "busy" and state == "idle" then
          local p = peer.pane and ranma.pane(tonumber(peer.pane))
          local visible = p and p.visible
          if not visible and not a.needs then
            a.needs = true
            if ranma.get("agents.notify") then
              local title = peer.title and peer.title ~= "" and (": " .. peer.title) or ""
              toast(peer, who(peer, id) .. " is done" .. title)
            end
          end
        end
        if state == "busy" then a.needs = false end
      end
      a.peer, a.state = peer, state
      -- No state from ai: watch its screen for a question instead.
      if state == "running" and not reports_state(peer) and not a.watch and peer.pane then
        local p = ranma.pane(tonumber(peer.pane))
        if p then
          local ok, w = pcall(p.watch, p, ranma.get("agents.ask"), function(e) asked(id, e) end)
          if ok then a.watch = w else a.watch = false; ranma.notify("agents.ask: " .. tostring(w)) end
        end
      end
      -- Looking at its pane answers "needs you".
      if a.needs and peer.pane and focused == tonumber(peer.pane) then a.needs = false end
      badge(a)
    end
  end
  for id, a in pairs(agents) do
    if not seen[id] then
      local p = pane_of(a)
      if p then p:badge(OWNER) end
      if a.watch then ranma.unwatch(a.watch) end
      agents[id] = nil
    end
  end
  refresh_screen()
end

local function poll()
  if broken then return end
  ranma.spawn({ "ai", "peers", "--json" }, { timeout = 10, on_exit = function(r)
    if r.error and r.error:match("could not run") then
      broken = true
      if timer then ranma.cancel(timer) end
      return
    end
    if r.code ~= 0 or not r.stdout then return end
    local ok, peers = pcall(ranma.json.decode, r.stdout)
    if ok and type(peers) == "table" then update(peers) end
  end })
end

timer = ranma.every(ranma.get("agents.poll") * 1000, poll)
ranma.defer(0, poll)

-- Looking at an agent's pane answers it at once, not at the next poll.
ranma.on("focus_change", function(e)
  for _, a in pairs(agents) do
    if a.needs and a.peer.pane and tonumber(a.peer.pane) == e.pane then
      a.needs = false
      badge(a)
      refresh_screen()
    end
  end
end)

local function open()
  screen = ranma.screen {
    title = "agents", filter = "names", detail = 6, options = true,
    status = status(),
    count = #order .. (#order == 1 and " agent" or " agents"),
    empty = broken and "ai is not installed here" or "no agents running",
    body = body(),
    card = {
      { "enter", "jump to its pane" },
      { "m", "message it (ai send)" },
      { "x", "stop it: esc", "working" },
      { "o", "the agents plugin's options" },
    },
    on_close = function() screen = nil end,
  }
end

-- WM mode ends as the screen opens: it has the keyboard from there.
ranma.bind("i", open, { desc = "agents", exit = true })
