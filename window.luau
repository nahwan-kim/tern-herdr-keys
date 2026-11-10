--!strict
-- herdr-style spaces for Tern. A herdr space is a Tern session:
--   ⌘⇧1…⌘⇧9  shows the Nth session in the tab list's order;
--   ⌘W        closes the focused block (Tern's close_pane, taken over here); a tab's last block
--             takes the tab with it (Tern does that) and a session's last block leaves it empty;
--             on an empty session it closes the session, unless blocks are parked there or it
--             is its host's only session;
--   ⌘⇧W       closes the current session, never a default one;
--   pinning   each host's default session (kept in tern.kv by name and id, so a rename keeps
--             it) stays first among that host's sessions, and neither close ends it.
-- ⌘N is a Tern default, which plugin keys cannot take: settings.json `keybinds` maps it to
-- `new_session`.

local MOBILE = tern.runtime.os == "ios" or tern.runtime.os == "android"

-- Ids can exceed 2^31 (remote ones carry the host in high bits); %.0f keeps them exact.
local function sid(n: number): string
	return string.format("%.0f", n)
end

-- Host name → that host's default session: its name and id. 0.1.0 kept only the name.
type Default = { name: string, id: string? }

local function defaults(): { [string]: Default }
	local d = tern.kv.get("defaults")
	local out: { [string]: Default } = {}
	if type(d) == "table" then
		for host, v in d :: { [string]: any } do
			if type(v) == "string" then
				out[host] = { name = v }
			elseif type(v) == "table" and type(v.name) == "string" then
				out[host] = { name = v.name, id = if type(v.id) == "string" then v.id else nil }
			end
		end
	end
	return out
end

-- Host id → host, for every attached host.
local function hosts_by_id(cx: WindowCx): { [number]: ManagedHost }
	local map: { [number]: ManagedHost } = {}
	for _, h in cx.hosts:list() do
		map[h.id] = h
	end
	return map
end

-- The host's default session among its sessions (in Tern's order), and its position: by id first,
-- so a renamed default is still found, else by name, so one recreated under its name is too.
local function find_default(list: { ManagedSession }, want: Default): (number?, ManagedSession?)
	if want.id then
		for i, s in list do
			if sid(s.id) == want.id then
				return i, s
			end
		end
	end
	for i, s in list do
		if s.name == want.name then
			return i, s
		end
	end
	return nil, nil
end

local function sessions_on(cx: WindowCx, host: number): { ManagedSession }
	local out: { ManagedSession } = {}
	for _, s in cx.sessions:list() do
		if s.host == host then
			table.insert(out, s)
		end
	end
	return out
end

local function is_default(cx: WindowCx, session: ManagedSession): boolean
	local h = hosts_by_id(cx)[session.host]
	local want = if h then defaults()[h.name] else nil
	if not want then
		return false
	end
	local _, s = find_default(sessions_on(cx, session.host), want)
	return s ~= nil and s.id == session.id
end

-- A move Tern ignores would leave the same moves to do, and each switch below fires `focus`,
-- which schedules pinning again: the same moves within PIN_RETRY_MS run once.
local PIN_RETRY_MS = 5000
local last_pin: { key: string, at: number }? = nil

-- Moves each connected host's default session to the top of that host's sessions, and follows a
-- rename of it. Tern reorders only the shown session, so this shows the default, moves it up and
-- shows the original session again; all of it runs before the window draws.
local function pin(cx: WindowCx)
	if MOBILE then
		return
	end
	local hosts = hosts_by_id(cx)
	local d = defaults()
	local renamed = false
	local by_host: { [number]: { ManagedSession } } = {}
	for _, s in cx.sessions:list() do
		local list = by_host[s.host] or {}
		by_host[s.host] = list
		table.insert(list, s)
	end
	local moves: { { id: number, by: number } } = {}
	for host, list in by_host do
		local h = hosts[host]
		local want = if h then d[h.name] else nil
		if h and want and (h.kind == "local" or h.state == "connected") then
			local pos, s = find_default(list, want)
			if pos and s then
				if s.name ~= want.name or sid(s.id) ~= want.id then
					d[h.name] = { name = s.name, id = sid(s.id) }
					renamed = true
				end
				if pos > 1 then
					table.insert(moves, { id = s.id, by = pos - 1 })
				end
			end
		end
	end
	if renamed then
		tern.kv.set("defaults", d)
	end
	if #moves == 0 then
		return
	end
	local parts: { string } = {}
	for _, m in moves do
		table.insert(parts, sid(m.id) .. "^" .. m.by)
	end
	local key = table.concat(parts, ",")
	local now = tern.now()
	if last_pin and last_pin.key == key and now - last_pin.at < PIN_RETRY_MS then
		return
	end
	last_pin = { key = key, at = now }
	local back = cx.sessions:current().id
	local ok, err = pcall(function()
		for _, m in moves do
			cx.sessions:switch(m.id)
			for _ = 1, m.by do
				cx:command("move_session_up")
			end
		end
	end)
	cx.sessions:switch(back)
	if not ok then
		tern.log.warn("pin failed:", err)
	end
end

local scheduled = false
local function schedule()
	if scheduled or MOBILE then
		return
	end
	scheduled = true
	tern.timer(40, function(cx: WindowCx?)
		scheduled = false
		if cx then
			local ok, err = pcall(pin, cx)
			if not ok then
				tern.log.warn("pin failed:", err)
			end
		end
	end)
end

-- Sessions in the vertical tab list's order: grouped by host in host order, each host's
-- sessions in Tern's order. `cx.sessions:list()` alone keeps a new session after every remote
-- host's sessions.
local function ordered(cx: WindowCx): { ManagedSession }
	local slot: { [number]: number } = {}
	local count = 0
	for _, h in cx.hosts:list() do
		count += 1
		slot[h.id] = count
	end
	local by_slot: { [number]: { ManagedSession } } = {}
	for _, s in cx.sessions:list() do
		local i = slot[s.host] or (count + 1)
		local list = by_slot[i] or {}
		by_slot[i] = list
		table.insert(list, s)
	end
	local out: { ManagedSession } = {}
	for i = 1, count + 1 do
		for _, s in by_slot[i] or {} do
			table.insert(out, s)
		end
	end
	return out
end

for n = 1, 9 do
	tern.command({
		id = "space_" .. n,
		title = "스페이스 " .. n .. "번으로 이동",
		icon = "terminal",
		group = "Herdr Keys",
		keys = { "cmd+shift+" .. n },
		run = function(cx)
			local s = ordered(cx)[n]
			if not s then
				cx:toast("info", "스페이스 " .. n .. "번이 없어요")
			elseif not s.current then
				cx.sessions:switch(s.id)
			end
		end,
	})
end

-- ⌘W, the palette's Close block and a block's close button: on a session with no blocks left it
-- ends the session instead, through Tern's own command so the close confirmation and session
-- locks still apply. The session's last block only empties it, so a second ⌘W is what ends it.
-- An empty session stays when it has parked blocks (a parked pane has no tab, so any parked
-- block on this host counts), when it is the host's only session, or when it is the host's
-- default.
tern.override("close_pane", function(cx: WindowCx): boolean?
	if MOBILE then
		return false
	end
	local cur = cx.sessions:current()
	local host = hosts_by_id(cx)[cur.host]
	local on_host: { [number]: boolean } = {}
	for _, p in if host then host.panes else {} do
		on_host[p] = true
	end
	local tab_session: { [number]: number } = {}
	for _, t in cx.session:tabs() do
		tab_session[t.id] = t.session
	end
	local blocks, parked = 0, false
	for _, p in cx.session:panes() do
		if p.tab and tab_session[p.tab] == cur.id then
			blocks += 1
		elseif p.parked and on_host[p.pane] then
			parked = true
		end
	end
	local default = is_default(cx, cur)
	if blocks == 0 and not parked and #sessions_on(cx, cur.host) > 1 and not default then
		cx:command("close_session")
	elseif cx.session:focused() then
		cx:command("close_pane")
	elseif default then
		cx:toast("info", "기본 스페이스는 닫지 않아요", cur.name)
	end
	return true
end)

tern.command({
	id = "close_space",
	title = "스페이스 닫기",
	icon = "x-circle",
	group = "Herdr Keys",
	keys = { "cmd+shift+w" },
	run = function(cx)
		local cur = cx.sessions:current()
		if is_default(cx, cur) then
			cx:toast("info", "기본 스페이스는 닫지 않아요", cur.name)
			return
		end
		cx:command("close_session")
	end,
})

tern.command({
	id = "set_default",
	title = "스페이스: 지금 스페이스를 이 기기의 기본으로 고정",
	icon = "check",
	group = "Herdr Keys",
	run = function(cx)
		local cur = cx.sessions:current()
		local host = hosts_by_id(cx)[cur.host]
		if not host then
			cx:toast("error", "이 스페이스의 기기를 찾지 못했어요")
			return
		end
		local d = defaults()
		d[host.name] = { name = cur.name, id = sid(cur.id) }
		tern.kv.set("defaults", d)
		last_pin = nil
		pin(cx)
		cx:toast("success", "기본 스페이스로 고정했어요", host.name .. " · " .. cur.name)
	end,
})

-- ⌘R and ⇧⌘C only have view chords by default (SQLite, canvas), and a typed chord whose
-- defaults are view chords goes to the focused program before Tern's keymap, so no keybind can
-- take them. Karabiner turns them into these free chords while Tern is frontmost
-- (~/.config/karabiner/karabiner.json, rule "Tern: ⌘R/⌘L/⇧⌘C …"; ⌘L goes to Agent Tabs' ⌘⌥⇧L).
-- In a terminal or agent block they rename the tab and open the block note; elsewhere the key
-- keeps doing what it does there: ⌘R reloads a browser page, and a code view, SQLite or canvas
-- block runs its own actions for the key, read from the keymap in effect.
local VIEW_PREFIX: { [string]: string } = {
	file = "editor.", database = "sqlite.", notebook = "notebook.", canvas = "canvas.", board = "board.", git = "git.",
}

local function view_actions(cx: WindowCx, kind: string?, chord: string): boolean
	local prefix = if kind then VIEW_PREFIX[kind] else nil
	if not prefix then
		return false
	end
	local ran = false
	for _, name in cx.actions:keys()[chord] or {} do
		if string.sub(name, 1, #prefix) == prefix then
			ran = true
			local ok, err = pcall(function()
				cx:action(name)
			end)
			if not ok then
				tern.log.warn("view action failed:", name, err)
			end
		end
	end
	return ran
end

-- A remapped key can arrive several times for one press; presses this close together count once.
local REMAP_DEBOUNCE_MS = 400
local last_press: { [string]: number } = {}

local function remapped(chord: string, original: string, browser: ((WindowCx, number) -> ())?, own: (WindowCx) -> ())
	tern.bind(chord, function(cx: WindowCx)
		local now = tern.now()
		if now - (last_press[chord] or -math.huge) < REMAP_DEBOUNCE_MS then
			return
		end
		last_press[chord] = now
		local focused = cx.session:focused()
		local info = if focused then cx.session:pane(focused) else nil
		local kind = info and info.kind
		if focused and kind == "browser" and browser then
			browser(cx, focused)
		elseif not view_actions(cx, kind, original) then
			own(cx)
		end
	end)
end

remapped("ctrl+alt+shift+r", "cmd+r", function(cx: WindowCx, pane: number)
	cx.browser:call({ op = "nav", block = pane, go = "reload" }):next(function(res: any, err: any)
		local failure = err or (type(res) == "table" and res.error)
		if failure then
			tern.log.warn("browser reload failed:", failure)
		end
	end)
end, function(cx: WindowCx)
	cx:command("rename_tab")
end)

remapped("ctrl+alt+shift+c", "shift+cmd+c", nil, function(cx: WindowCx)
	cx:command("pane_note")
end)

-- Moving a session by hand must not lift another above a default; run Tern's move, then pin.
for _, id in { "move_session_up", "move_session_down" } do
	tern.override(id, function(cx: WindowCx): boolean?
		cx:command(id)
		last_pin = nil
		pin(cx)
		return true
	end)
end

for _, name in { "window_start", "focus", "tab_created", "session_ended" } do
	tern.on(name, function(...)
		schedule()
	end)
end
