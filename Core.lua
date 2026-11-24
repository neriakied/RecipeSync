--[[
  RecipeSync - Core (data, scanning, sync)
  Vanilla 1.12 client = Lua 5.0: no '#', no '%' operator, no select(), varargs via 'arg'.

  What is shared between players:
    * which recipes (spell ids from the OctoWoW database) each RecipeSync user knows
    * "unconfirmed" names typed in by hand for players who don't use the addon
    * a small directory (who has which profession, when they were last seen) so lists
      can be passed along by anyone, even while the crafter is offline

  Where: GUILD, PARTY/RAID, and a hidden chat channel named after the "sync guild"
  (so players outside the guild can join by typing the guild's name).

  Every message from other players is untrusted: sizes, rates and values are checked.
]]

RecipeSync = {}
local RS = RecipeSync

RS.VERSION  = "1.0.0"
RS.PREFIX   = "RcSync"
RS.PROTO    = "3"
RS.CHANTAG  = "RcS:"     -- marks our lines in the hidden sync channel
RS.CPS      = 700        -- bytes/second we allow ourselves to send
RS.BURST    = 1500
RS.OVERHEAD = 40
RS.CHUNK    = 200
RS.CHANNEL_GAP = 1.1     -- seconds between lines in the chat channel (stay well under any spam limit)
RS.STALE    = 15 * 86400 -- players not seen for 15 days are removed

RS.LIMIT = {
  msgsPer10s     = 120,   -- per sender, before they are ignored for 'mute' seconds
  mute           = 120,
  chunksPerXfer  = 140,
  inbound        = 16,
  bulkQueue      = 500,
  idsPerList     = 1500,
  manualTotal    = 5000,
  manualPerMin   = 40,
  autoRequests   = 25,    -- automatic downloads per 5 minutes
  syncNowRequests = 40,   -- requests per "Sync Now" click
  indexEntries   = 12,
  dirEntries     = 600,
}

local getn, tinsert, tremove, tsort, tconcat = table.getn, table.insert, table.remove, table.sort, table.concat
local strfind, strsub, strlen, strlower, strupper, strbyte = string.find, string.sub, string.len, string.lower, string.upper, string.byte
local gsub, format, floor, mod = string.gsub, string.format, math.floor, math.mod

-------------------------------------------------------------------------------
-- Real API captured before View.lua wraps it
-------------------------------------------------------------------------------
local REAL = {}
RS.REAL = REAL
for _, n in ipairs({ "GetTradeSkillLine", "GetNumTradeSkills", "GetTradeSkillInfo", "GetTradeSkillItemLink",
  "ExpandTradeSkillSubClass", "GetTradeSkillSubClassFilter", "GetTradeSkillInvSlotFilter",
  "GetCraftDisplaySkillLine", "GetNumCrafts", "GetCraftInfo", "GetCraftItemLink" }) do
  REAL[n] = getglobal(n)
end

-------------------------------------------------------------------------------
-- Utilities
-------------------------------------------------------------------------------
function RS:Print(msg)
  if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99RecipeSync|r: " .. tostring(msg)) end
end

function RS:Debug(msg)
  if self.db and self.db.settings.debug then self:Print("|cff888888" .. tostring(msg) .. "|r") end
end

local reported = {}
function RS:Safe(fn, ...)
  local ok, err = pcall(fn, unpack(arg))
  if not ok then
    err = tostring(err)
    if not reported[err] then
      reported[err] = true
      self:Print("|cffff6060internal error (reported once):|r " .. err)
    end
  end
  return ok
end

local function Split(s, sep, max)
  local t, start, n = {}, 1, 0
  while true do
    n = n + 1
    local i = strfind(s, sep, start, true)
    if not i or (max and n >= max) then
      tinsert(t, strsub(s, start))
      return t
    end
    tinsert(t, strsub(s, start, i - 1))
    start = i + 1
  end
end
RS.Split = Split

local function San(s)
  if not s then return "" end
  s = gsub(tostring(s), "[`~|%^,;:]", "")
  return s
end
RS.San = San

-- ids are sent as plain digits (letters could be mangled by the chat profanity filter)
local function ParseId(s)
  if not s or s == "" or strlen(s) > 7 or strfind(s, "[^0-9]") then return nil end
  return tonumber(s)
end
RS.ParseId = ParseId

function RS:Hash(s)
  local h = 5381
  for i = 1, strlen(s) do
    h = mod(h * 33 + strbyte(s, i), 2147483629)
  end
  return format("%08x", h)
end

function RS:Chunk(s, size)
  local out, pos, len = {}, 1, strlen(s)
  while pos <= len do
    local e = pos + size - 1
    if e < len then
      while e > pos do
        local b = strbyte(s, e + 1)
        if b >= 128 and b < 192 then e = e - 1 else break end
      end
    else
      e = len
    end
    tinsert(out, strsub(s, pos, e))
    pos = e + 1
  end
  return out
end

function RS:VersionNewer(a, b)
  local x, y = Split(a or "0", "."), Split(b or "0", ".")
  for i = 1, 3 do
    local p, q = tonumber(x[i]) or 0, tonumber(y[i]) or 0
    if p ~= q then return p > q end
  end
  return false
end

function RS:Ago(t)
  if not t then return "never" end
  local d = time() - t
  if d < 120 then return "just now" end
  if d < 7200 then return floor(d / 60) .. "m ago" end
  if d < 172800 then return floor(d / 3600) .. "h ago" end
  return floor(d / 86400) .. "d ago"
end

function RS:ValidName(n)
  if type(n) ~= "string" then return false end
  local len = strlen(n)
  if len < 2 or len > 24 then return false end
  return not strfind(n, "[^%a\128-\255]")
end

function RS:CapName(n)
  n = gsub(n or "", "^%s+", "")
  n = gsub(n, "%s+$", "")
  if strbyte(n, 1) and strbyte(n, 1) < 128 then
    n = strupper(strsub(n, 1, 1)) .. strlower(strsub(n, 2))
  end
  return n
end

-------------------------------------------------------------------------------
-- Timers (keyed; scheduling a key again replaces it)
-------------------------------------------------------------------------------
RS.timers = {}
function RS:After(key, delay, fn) self.timers[key] = { t = GetTime() + delay, fn = fn } end
function RS:Cancel(key) self.timers[key] = nil end

-------------------------------------------------------------------------------
-- Saved data
-------------------------------------------------------------------------------
function RS:MyName() return UnitName("player") end

function RS:InitDB()
  if type(RecipeSyncDB) ~= "table" then RecipeSyncDB = {} end
  local db = RecipeSyncDB
  if db.schema ~= 3 then
    db.realms = nil -- earlier test builds stored data differently; start clean
    db.schema = 3
  end
  db.settings = db.settings or {}
  local s = db.settings
  if s.autoFetch == nil then s.autoFetch = true end
  if s.unsafeTooltips == nil then s.unsafeTooltips = false end
  if s.showUnconfirmed == nil then s.showUnconfirmed = true end
  if s.knownOnly == nil then s.knownOnly = false end
  if s.exportTabs == nil then s.exportTabs = true end
  if type(s.syncGuild) ~= "string" then s.syncGuild = "" end
  db.realms = db.realms or {}
  self.realm = GetRealmName() or "Unknown"
  local r = db.realms[self.realm]
  if not r then r = {}; db.realms[self.realm] = r end
  r.players = r.players or {}
  r.manual = r.manual or {}
  self.db = db
  self.players = r.players
  self.manual = r.manual
  local now = time()
  for _, pl in pairs(self.players) do
    if type(pl.seen) ~= "number" then pl.seen = now end -- unknown: give them the full 15 days
  end
  self:PruneManual()
  self.rev = (self.rev or 0) + 1
end

-- create: when true, a new record counts as seen now; a number sets that last-seen time instead
function RS:GetPlayer(name, create)
  if not name or not self.players then return nil end
  local p = self.players[name]
  if not p and create then
    p = { profs = {}, seen = (type(create) == "number" and create) or time() }
    self.players[name] = p
  end
  return p
end

function RS:GetProf(name, prof)
  local p = self:GetPlayer(name)
  if p then return p.profs[prof] end
end

function RS:Seen(name, t)
  local pl = self:GetPlayer(name, true)
  t = t or time()
  if t > time() + 3600 then return end
  if not pl.seen or t > pl.seen then pl.seen = t end
end

-- seen within the last 15 days?
function RS:Fresh(name)
  if name == self:MyName() then return true end
  local pl = self.players and self.players[name]
  local t = pl and pl.seen
  local r = self.rosterSeen[name]
  if r and (not t or r > t) then t = r end
  return t and (time() - t) < self.STALE
end

function RS:PruneStale()
  local removed = 0
  for name, pl in pairs(self.players) do
    if name ~= self:MyName() then
      if self.rosterSeen[name] and self.rosterSeen[name] > (pl.seen or 0) then pl.seen = self.rosterSeen[name] end
      if not pl.seen or time() - pl.seen >= self.STALE then
        self.players[name] = nil
        removed = removed + 1
      end
    end
  end
  if removed > 0 then
    self:Debug("Removed " .. removed .. " player(s) not seen for 15+ days.")
    self:Changed()
  end
end

function RS:Changed()
  self.rev = (self.rev or 0) + 1
  self:After("notify", 0.4, function()
    if RS.Main and RS.Main.Refresh then RS:Safe(RS.Main.Refresh, RS.Main) end
    if RS.View and RS.View.OnDataChanged then RS:Safe(RS.View.OnDataChanged, RS.View) end
  end)
end

-------------------------------------------------------------------------------
-- Static recipe database (Data.lua), prepared lazily per profession
-------------------------------------------------------------------------------
local QCOLOR = { [0] = "ff9d9d9d", [1] = "ffffffff", [2] = "ff1eff00", [3] = "ff0070dd", [4] = "ffa335ee", [5] = "ffff8000" }
RS.QCOLOR = QCOLOR

local function Icon(s)
  if not s or s == "" then return "Interface\\Icons\\INV_Misc_QuestionMark" end
  return "Interface\\Icons\\" .. s
end

function RS:ItemInfo(id)
  local it = RecipeSyncData and RecipeSyncData.items[id]
  if it then return it[1], it[2], Icon(it[3]) end
  local name, _, q, _, _, _, _, _, tex = GetItemInfo(id)
  if name then return name, q or 1, tex or Icon(nil) end
  return "Item #" .. id, 1, Icon(nil)
end

function RS:ItemLink(id)
  local name, q = self:ItemInfo(id)
  return "|c" .. (QCOLOR[q] or "ffffffff") .. "|Hitem:" .. id .. ":0:0:0|h[" .. name .. "]|h|r"
end

RS.statics = {}
function RS:ProfList()
  return (RecipeSyncData and RecipeSyncData.profs) or {}
end

function RS:Static(prof)
  if self.statics[prof] then return self.statics[prof] end
  local raw
  local list = self:ProfList()
  for i = 1, getn(list) do
    if list[i].name == prof then raw = list[i] end
  end
  if not raw then return nil end
  local sp = { name = raw.name, icon = Icon(raw.icon), headers = {}, loose = {}, recipes = {},
               bySpell = {}, byCreated = {}, byName = {} }
  for h = 1, getn(raw.headers) do
    tinsert(sp.headers, { name = raw.headers[h], recipes = {}, idx = h })
  end
  for i = 1, getn(raw.r) do
    local x = raw.r[i]
    local rec = { spell = x[1], name = x[2], created = x[4], min = x[5], max = x[6],
                  yellow = x[7], grey = x[8], reagents = {}, tools = x[11] or {} }
    if x[3] then
      rec.icon = Icon(x[3])
    elseif rec.created > 0 then
      local _, _, tex = self:ItemInfo(rec.created)
      rec.icon = tex
    else
      rec.icon = Icon(nil)
    end
    local rg = x[10]
    for k = 1, getn(rg) - 1, 2 do
      tinsert(rec.reagents, { id = rg[k], count = rg[k + 1] })
    end
    local h = sp.headers[x[9]]
    rec.header = h
    if h then tinsert(h.recipes, rec) else tinsert(sp.loose, rec) end
    tinsert(sp.recipes, rec)
    sp.bySpell[rec.spell] = rec
    if rec.created > 0 then
      sp.byCreated[rec.created] = sp.byCreated[rec.created] or {}
      tinsert(sp.byCreated[rec.created], rec)
    end
    local ln = strlower(rec.name)
    if not sp.byName[ln] then sp.byName[ln] = rec end
  end
  self.statics[prof] = sp
  return sp
end

function RS:RecipeLink(rec)
  if rec.created and rec.created > 0 and RecipeSyncData.items[rec.created] then
    return self:ItemLink(rec.created)
  end
  return "|cffffd000|Henchant:" .. rec.spell .. "|h[" .. rec.name .. "]|h|r"
end

-------------------------------------------------------------------------------
-- Class colours
-------------------------------------------------------------------------------
RS.CLASS_COLORS = {
  WARRIOR = "ffc79c6e", MAGE = "ff69ccf0", ROGUE = "fffff569", DRUID = "ffff7d0a", HUNTER = "ffabd473",
  SHAMAN = "ff0070de", PRIEST = "ffffffff", WARLOCK = "ff9482c9", PALADIN = "fff58cba",
}
RS.rosterClass, RS.rosterSeen = {}, {}

local function ClassToken(localized)
  if not localized then return nil end
  local t = strupper(gsub(localized, "%s", ""))
  if RS.CLASS_COLORS[t] then return t end
end

function RS:ClassOf(name)
  local pl = self.players and self.players[name]
  if pl and pl.class and self.CLASS_COLORS[pl.class] then return pl.class end
  if self.rosterClass[name] then return self.rosterClass[name] end
  if name == self:MyName() then
    local _, t = UnitClass("player")
    return t
  end
  for i = 1, GetNumRaidMembers() do
    if UnitName("raid" .. i) == name then local _, t = UnitClass("raid" .. i); return t end
  end
  for i = 1, GetNumPartyMembers() do
    if UnitName("party" .. i) == name then local _, t = UnitClass("party" .. i); return t end
  end
end

function RS:ColorName(name)
  local c = self.CLASS_COLORS[self:ClassOf(name) or ""] or "ffd0d0d0"
  return "|c" .. c .. name .. "|r"
end

-------------------------------------------------------------------------------
-- Known recipe lists:  "3~<spell ids, comma separated>~<names not in the database, ` separated>"
-------------------------------------------------------------------------------
RS.knownCache = {}
function RS:ParseKnown(data, hash)
  local key = hash or data
  local c = self.knownCache[key]
  if c then return c end
  local parts = Split(data, "~", 3)
  if parts[1] ~= "3" then return nil end
  self.knownCacheN = (self.knownCacheN or 0) + 1
  if self.knownCacheN > 400 then self.knownCache = {}; self.knownCacheN = 1 end
  c = { ids = {}, extras = {}, n = 0 }
  if parts[2] and parts[2] ~= "" then
    local ids = Split(parts[2], ",")
    for i = 1, getn(ids) do
      if i > self.LIMIT.idsPerList then break end
      local id = ParseId(ids[i])
      if id then c.ids[id] = true; c.n = c.n + 1 end
    end
  end
  if parts[3] and parts[3] ~= "" then
    local ex = Split(parts[3], "`")
    for i = 1, getn(ex) do
      if i > 200 then break end
      if ex[i] ~= "" and strlen(ex[i]) <= 80 then tinsert(c.extras, ex[i]); c.n = c.n + 1 end
    end
  end
  self.knownCache[key] = c
  return c
end

-- who knows what, for one profession (cached until data changes)
RS.craftCache = {}
local function AddCrafter(t, key, name, confirmed, by)
  local list = t[key]
  if not list then list = {}; t[key] = list end
  for i = 1, getn(list) do
    if list[i].name == name then
      if confirmed then list[i].ok = true end
      return
    end
  end
  tinsert(list, { name = name, ok = confirmed, by = by })
end

function RS:Crafters(prof)
  local c = self.craftCache[prof]
  if c and c.rev == self.rev then return c end
  c = { rev = self.rev, bySpell = {}, extras = {}, people = 0 }
  for name, pl in pairs(self.players or {}) do
    local p = pl.profs[prof]
    if p and p.data and self:Fresh(name) then
      local k = self:ParseKnown(p.data, p.hash)
      if k then
        c.people = c.people + 1
        for spell in pairs(k.ids) do AddCrafter(c.bySpell, spell, name, true) end
        for i = 1, getn(k.extras) do AddCrafter(c.extras, k.extras[i], name, true) end
      end
    end
  end
  for _, m in pairs(self.manual or {}) do
    -- hand-added names: hidden when the guild roster says they've been away 15+ days
    local r = self.rosterSeen[m.c]
    local away = r and (time() - r) >= self.STALE
    if not m.d and m.p == prof and not away then AddCrafter(c.bySpell, m.s, m.c, false, m.b) end
  end
  self.craftCache[prof] = c
  return c
end

-------------------------------------------------------------------------------
-- Scanning your own professions
-------------------------------------------------------------------------------
local TS = {
  line = function() return REAL.GetTradeSkillLine() end,
  num  = function() return REAL.GetNumTradeSkills() end,
  info = function(i) local n, t = REAL.GetTradeSkillInfo(i); return n, t end,
  link = function(i) return REAL.GetTradeSkillItemLink(i) end,
}
local CR = {
  line = function() if REAL.GetCraftDisplaySkillLine then return REAL.GetCraftDisplaySkillLine() end end,
  num  = function() return REAL.GetNumCrafts() end,
  info = function(i) local n, _, t = REAL.GetCraftInfo(i); return n, t end,
  link = function(i) if REAL.GetCraftItemLink then return REAL.GetCraftItemLink(i) end end,
}
RS.TS, RS.CR = TS, CR

function RS:Serialize(api)
  local prof, rank, maxRank = api.line()
  if not prof or prof == "" or prof == "UNKNOWN" then return nil end
  prof = San(prof)
  local n = api.num() or 0
  if n == 0 or n > 1000 then return nil end
  local sp = self:Static(prof)
  local ids, extras, count = {}, {}, 0
  local seen = {}
  for i = 1, n do
    local name, stype = api.info(i)
    if not name then return nil, true end
    if stype ~= "header" then
      local rec
      local link = api.link(i)
      if sp and link then
        local _, _, eid = strfind(link, "enchant:(%d+)")
        if eid then rec = sp.bySpell[tonumber(eid)] end
        if not rec then
          local _, _, iid = strfind(link, "item:(%d+)")
          local list = iid and sp.byCreated[tonumber(iid)]
          if list then
            rec = list[1]
            for k = 1, getn(list) do
              if list[k].name == name then rec = list[k] end
            end
          end
        end
      end
      if sp and not rec then rec = sp.byName[strlower(name)] end
      if rec then
        if not seen[rec.spell] then
          seen[rec.spell] = true
          tinsert(ids, rec.spell)
          count = count + 1
        end
      else
        local clean = San(name)
        if clean ~= "" and not seen[clean] then
          seen[clean] = true
          tinsert(extras, clean)
          count = count + 1
        end
      end
    end
  end
  tsort(ids)
  tsort(extras)
  local payload = "3~" .. tconcat(ids, ",") .. "~" .. tconcat(extras, "`")
  return prof, rank or 0, maxRank or 0, payload, count
end

RS.scanState = {}
function RS:ScheduleScan(kind, delay)
  self:After("scan" .. kind, delay or 0.7, function() RS:ScanNow(kind) end)
end

function RS:ScanNow(kind)
  local st = self.scanState[kind]
  if not st then st = { expands = 0, retries = 0 }; self.scanState[kind] = st end
  if kind == "trade" then
    if not self.tradeOpen then return end
    if REAL.GetTradeSkillSubClassFilter and not REAL.GetTradeSkillSubClassFilter(0) then return end
    if REAL.GetTradeSkillInvSlotFilter and not REAL.GetTradeSkillInvSlotFilter(0) then return end
    local n = REAL.GetNumTradeSkills() or 0
    if n > 1000 then return end
    for i = n, 1, -1 do
      local _, stype, _, expanded = REAL.GetTradeSkillInfo(i)
      if stype == "header" and not expanded then
        st.expands = st.expands + 1
        if st.expands > 30 then return end
        REAL.ExpandTradeSkillSubClass(i)
        self:ScheduleScan(kind, 0.5)
        return
      end
    end
    self:StoreScan(TS, kind)
  elseif kind == "craft" then
    if not self.craftOpen then return end
    self:StoreScan(CR, kind)
  end
end

function RS:StoreScan(api, kind)
  local prof, rank, maxRank, payload, count = self:Serialize(api)
  local st = self.scanState[kind]
  if not prof then
    if rank == true and st.retries < 5 then
      st.retries = st.retries + 1
      self:ScheduleScan(kind, 2)
    end
    return
  end
  st.retries = 0
  local me = self:GetPlayer(self:MyName(), true)
  me.seen = time()
  me.class = self:MyClass()
  local p = me.profs[prof]
  if not p then p = {}; me.profs[prof] = p end
  local hash = self:Hash(payload)
  local changed = p.hash ~= hash
  local rankChanged = p.rank ~= rank or p.max ~= maxRank
  p.rank, p.max, p.count, p.data, p.hash, p.latest = rank, maxRank, count, payload, hash, hash
  if changed then
    p.updated = time()
    self:Debug("Read " .. prof .. ": " .. count .. " recipes")
  end
  if changed or rankChanged then
    self:IndexChanged()
    self:Changed()
  end
end

local KNOWN_PROFS = {
  "Alchemy", "Blacksmithing", "Enchanting", "Engineering", "Leatherworking", "Tailoring",
  "Mining", "Cooking", "First Aid", "Jewelcrafting", "Poisons", "Survival",
}
function RS:PruneOwn()
  local num = GetNumSkillLines and GetNumSkillLines() or 0
  if num == 0 then return end
  local have = {}
  for i = 1, num do
    local name = GetSkillLineInfo(i)
    if name then have[name] = true end
  end
  local me = self:GetPlayer(self:MyName())
  if not me then return end
  local removed
  for _, prof in ipairs(KNOWN_PROFS) do
    if me.profs[prof] and not have[prof] then me.profs[prof] = nil; removed = true end
  end
  if removed then self:IndexChanged(); self:Changed() end
end

-------------------------------------------------------------------------------
-- Unconfirmed (hand-entered) crafters
--   manual[key] = { c = crafter, p = prof, s = spell, b = added/removed by, t = time, d = deleted }
-------------------------------------------------------------------------------
function RS:PruneManual()
  local cutoff = time() - 90 * 86400
  for k, m in pairs(self.manual) do
    if type(m) ~= "table" or (m.d and (m.t or 0) < cutoff) then self.manual[k] = nil end
  end
end

function RS:ManualCount()
  local n = 0
  for _ in pairs(self.manual) do n = n + 1 end
  return n
end

function RS:ManualDigest()
  if self.mdRev == self.rev and self.md then return self.md, self.mdCount end
  local keys = {}
  for k in pairs(self.manual) do tinsert(keys, k) end
  tsort(keys)
  local parts = {}
  for i = 1, getn(keys) do
    local m = self.manual[keys[i]]
    tinsert(parts, keys[i] .. ":" .. m.t .. ":" .. (m.d and 1 or 0))
  end
  self.md, self.mdCount, self.mdRev = self:Hash(tconcat(parts, ";")), getn(keys), self.rev
  return self.md, self.mdCount
end

function RS:MergeManual(c, prof, spell, t, d, by)
  if not self:ValidName(c) or not self:ValidName(by) then return false end
  local sp = self:Static(prof)
  if not sp or not sp.bySpell[spell] then return false end
  t = tonumber(t)
  if not t or t < 1000000000 or t > time() + 86400 then return false end
  local key = c .. "/" .. spell
  local old = self.manual[key]
  if old and (old.t > t or (old.t == t and (old.d or not d))) then return false end
  if not old and self:ManualCount() >= self.LIMIT.manualTotal then return false end
  self.manual[key] = { c = c, p = prof, s = spell, t = t, d = d and 1 or nil, b = by }
  return true
end

function RS:SetManual(crafter, prof, spell, deleted)
  crafter = self:CapName(crafter)
  if not self:ValidName(crafter) then
    self:Print("'" .. tostring(crafter) .. "' doesn't look like a character name.")
    return false
  end
  local t = time()
  local old = self.manual[crafter .. "/" .. spell]
  if old and old.t >= t then t = old.t + 1 end
  if not self:MergeManual(crafter, prof, spell, t, deleted, self:MyName()) then return false end
  self:Broadcast("M^" .. crafter .. "^" .. prof .. "^" .. spell .. "^" .. t .. "^" .. (deleted and 1 or 0) .. "^" .. self:MyName())
  self:Changed()
  return true
end

-------------------------------------------------------------------------------
-- Directory: who has which profession list (lets lists travel while crafters are offline)
--   entries "owner,class,prof,rank,max,count,hash,lastSeen"
-------------------------------------------------------------------------------
function RS:DirEntries()
  local out = {}
  for name, pl in pairs(self.players) do
    if self:Fresh(name) and self:ValidName(name) then
      for prof, p in pairs(pl.profs) do
        local h = p.latest or p.hash
        if h then
          tinsert(out, name .. "," .. (pl.class or "") .. "," .. prof .. "," .. (p.rank or 0) .. "," .. (p.max or 0)
            .. "," .. (p.count or 0) .. "," .. h .. "," .. (pl.seen or time()))
        end
      end
    end
  end
  tsort(out)
  while getn(out) > self.LIMIT.dirEntries do tremove(out) end
  return out
end

function RS:DirDigest()
  if self.ddRev == self.rev and self.dd then return self.dd end
  local keys = {}
  for name, pl in pairs(self.players) do
    if self:Fresh(name) then
      for prof, p in pairs(pl.profs) do tinsert(keys, name .. ":" .. prof .. ":" .. (p.latest or p.hash or "")) end
    end
  end
  tsort(keys)
  self.dd, self.ddRev = self:Hash(tconcat(keys, ";")), self.rev
  return self.dd
end

function RS:RequestDirectory(dist)
  if not dist then return end
  self:Send("D^" .. self:DirDigest(), dist)
end

function RS:SendDirectory(dist)
  local key = "dir/" .. dist
  local last = self.lastDump[key]
  if last and GetTime() - last < 120 then return end
  if getn(self.bulkQ) > self.LIMIT.bulkQueue then return end
  local entries = self:DirEntries()
  if getn(entries) == 0 then return end
  local chunks = self:Chunk(tconcat(entries, ";"), self.CHUNK)
  if getn(chunks) > self.LIMIT.chunksPerXfer then return end
  self.lastDump[key] = GetTime()
  local digest = self:DirDigest()
  self:Send("S^D^*^" .. digest .. "^" .. getn(chunks) .. "^" .. getn(entries), dist, true)
  for i = 1, getn(chunks) do self:Send("C^" .. chunks[i] .. ".", dist, true) end
  self:Send("E^D^*^" .. digest, dist, true)
end

function RS:MergeDirectory(data, dist)
  local recs = Split(data, ";")
  local now = time()
  local changed = false
  for i = 1, getn(recs) do
    if i > self.LIMIT.dirEntries then break end
    local x = Split(recs[i], ",")
    local owner, class, prof, hash, seen = x[1], x[2], x[3], x[7], tonumber(x[8])
    if owner ~= self:MyName() and self:ValidName(owner) and prof and prof ~= "" and strlen(prof) <= 30
       and hash and strlen(hash) <= 10 and seen and seen <= now + 3600 and now - seen < self.STALE then
      local pl = self:GetPlayer(owner, seen)
      if not pl.dist then pl.dist = dist end
      if self.CLASS_COLORS[class] and not pl.class then pl.class = class end
      local p = pl.profs[prof]
      if not p then p = {}; pl.profs[prof] = p end
      if seen >= (p.metaSeen or 0) then
        if p.latest ~= hash then changed = true end
        p.latest, p.metaSeen = hash, seen
        p.rank, p.max, p.count = tonumber(x[4]), tonumber(x[5]), tonumber(x[6])
      end
      if seen > (pl.seen or 0) then pl.seen = seen end
      if p.hash ~= p.latest and self.db.settings.autoFetch then self:ScheduleAutoFetch(owner, prof) end
    end
  end
  if changed then self:Changed() end
end

-------------------------------------------------------------------------------
-- Hidden sync channel (lets players outside the guild join by typing the guild's name)
-------------------------------------------------------------------------------
function RS:SyncGroup()
  local s = self.db and self.db.settings.syncGuild
  if s and s ~= "" then return s, true end
  local g = GetGuildInfo("player")
  return g, false
end

function RS:ChannelFor(group)
  if not group or group == "" then return nil end
  local k = gsub(strlower(group), "[^a-z0-9]", "")
  if k == "" then k = self:Hash(group) end
  return "RcSync" .. strsub(k, 1, 18)
end

function RS:UpdateChannel()
  local want = self:ChannelFor(self:SyncGroup())
  if self.chanName and self.chanName ~= want then
    pcall(LeaveChannelByName, self.chanName)
    self.chanName, self.chanId = nil, nil
  end
  if not want then return end
  self.chanName = want
  local id = GetChannelName(want)
  if id and id > 0 then
    self.chanId = id
    self:HideChannel()
    return
  end
  pcall(JoinChannelByName, want)
  self.chanTries = 0
  self:After("chanpoll", 2, function() RS:PollChannel() end)
end

function RS:PollChannel()
  if not self.chanName then return end
  local id = GetChannelName(self.chanName)
  if id and id > 0 then
    self.chanId = id
    self:HideChannel()
    self:Announce("CHANNEL")
    self:After("dirreq/CHANNEL", 5, function() RS:RequestDirectory("CHANNEL") end)
    if RS.Main and RS.Main.UpdateStatus then RS:Safe(RS.Main.UpdateStatus, RS.Main) end
    return
  end
  self.chanTries = (self.chanTries or 0) + 1
  if self.chanTries < 8 then
    self:After("chanpoll", 2, function() RS:PollChannel() end)
  else
    self:Print("Couldn't join the sync channel (the game allows 10 channels; leave one and click Sync Now).")
  end
end

-- keep the channel out of every chat window
function RS:HideChannel()
  if not self.chanName then return end
  for i = 1, (NUM_CHAT_WINDOWS or 7) do
    local f = getglobal("ChatFrame" .. i)
    if f and f.channelList then pcall(ChatFrame_RemoveChannel, f, self.chanName) end
  end
end

function RS:ChannelId()
  if not self.chanName then return nil end
  local id = GetChannelName(self.chanName)
  if id and id > 0 then self.chanId = id; return id end
  self.chanId = nil
end

function RS:SetSyncGroup(text)
  text = gsub(text or "", "^%s+", "")
  text = gsub(text, "%s+$", "")
  if strlen(text) > 40 then text = strsub(text, 1, 40) end
  local g = GetGuildInfo("player")
  if g and strlower(text) == strlower(g) then text = "" end -- same as default
  if text == self.db.settings.syncGuild then return end
  self.db.settings.syncGuild = text
  self:UpdateChannel()
  local name = self:SyncGroup()
  if name then
    self:Print("Syncing with guild |cffffd100" .. name .. "|r" .. (text == "" and " (your guild)" or "") .. ".")
  else
    self:Print("Not syncing with any guild channel.")
  end
end

-- swallow our channel's traffic before any chat window sees it
do
  local orig = ChatFrame_OnEvent
  if orig then
    ChatFrame_OnEvent = function(e)
      if RS.chanName and arg9 and type(e) == "string" and strsub(e, 1, 16) == "CHAT_MSG_CHANNEL"
         and type(arg9) == "string" and strlower(arg9) == strlower(RS.chanName) then
        return
      end
      return orig(e)
    end
  end
end

-------------------------------------------------------------------------------
-- Communication
-------------------------------------------------------------------------------
RS.ctrlQ, RS.bulkQ = {}, {}
RS.avail = RS.BURST
RS.inbound, RS.requested, RS.served, RS.live, RS.online = {}, {}, {}, {}, {}
RS.lastDump, RS.rate, RS.muted, RS.manualRate, RS.seenXfer = {}, {}, {}, {}, {}
RS.autoLog = {}
RS.lastChannelSend = 0

function RS:Send(msg, dist, bulk, onSent)
  if not dist or strlen(msg) > 240 then return end
  if dist == "GUILD" and not IsInGuild() then return end
  if dist == "CHANNEL" and not self.chanName then return end
  local q = bulk and self.bulkQ or self.ctrlQ
  if getn(q) > 1000 then return end
  tinsert(q, { msg = msg, dist = dist, onSent = onSent })
end

function RS:GroupDist()
  if GetNumRaidMembers() > 0 then return "RAID" end
  if GetNumPartyMembers() > 0 then return "PARTY" end
end

function RS:Dists()
  local t = {}
  if IsInGuild() then tinsert(t, "GUILD") end
  if self.chanId then tinsert(t, "CHANNEL") end
  local g = self:GroupDist()
  if g then tinsert(t, g) end
  return t
end

function RS:Broadcast(msg)
  local d = self:Dists()
  for i = 1, getn(d) do self:Send(msg, d[i]) end
end

function RS:PumpQueue(elapsed)
  self.avail = self.avail + elapsed * self.CPS
  if self.avail > self.BURST then self.avail = self.BURST end
  local sent = 0
  while sent < 10 do
    local q
    if self.ctrlQ[1] then q = self.ctrlQ
    elseif self.bulkQ[1] and not UnitAffectingCombat("player") then q = self.bulkQ end
    if not q then return end
    local m = q[1]
    local cost = strlen(m.msg) + strlen(self.PREFIX) + self.OVERHEAD
    if self.avail < cost then return end
    if m.dist == "CHANNEL" then
      if GetTime() - self.lastChannelSend < self.CHANNEL_GAP then return end
      local id = self:ChannelId()
      tremove(q, 1)
      if id then
        self.lastChannelSend = GetTime()
        pcall(SendChatMessage, self.CHANTAG .. m.msg, "CHANNEL", nil, id)
      end
    else
      tremove(q, 1)
      pcall(SendAddonMessage, self.PREFIX, m.msg, m.dist)
    end
    self.avail = self.avail - cost
    sent = sent + 1
    if m.onSent then self:Safe(m.onSent) end
  end
end

function RS:MyClass()
  local _, t = UnitClass("player")
  return t or ""
end

function RS:BuildIndex()
  local me = self:GetPlayer(self:MyName())
  local parts = {}
  if me then
    for prof, p in pairs(me.profs) do
      if p.data and p.hash then
        tinsert(parts, prof .. ":" .. (p.rank or 0) .. ":" .. (p.max or 0) .. ":" .. (p.count or 0) .. ":" .. p.hash)
      end
    end
  end
  tsort(parts)
  local md, mc = self:ManualDigest()
  local function build()
    return "I^" .. self.PROTO .. "^" .. self.VERSION .. "^" .. self:MyClass() .. "^" .. tconcat(parts, ";") .. "^" .. mc .. ":" .. md
  end
  local s = build()
  while strlen(s) > 235 and getn(parts) > 0 do
    tremove(parts)
    s = build()
  end
  return s
end

function RS:Announce(dist)
  local hello = "H^" .. self.PROTO .. "^" .. self.VERSION .. "^" .. self:MyClass()
  if dist then
    self:Send(hello, dist); self:Send(self:BuildIndex(), dist)
  else
    self:Broadcast(hello); self:Broadcast(self:BuildIndex())
  end
  self.lastIndex = GetTime()
end

function RS:IndexChanged()
  local wait = 5
  if self.lastIndex then
    local since = GetTime() - self.lastIndex
    if since < 60 then wait = 60 - since end
  end
  self:After("indexchanged", wait, function()
    RS.lastIndex = GetTime()
    RS:Broadcast(RS:BuildIndex())
  end)
end

function RS:CheckVersion(v)
  if v and not self.newerWarned and self:VersionNewer(v, self.VERSION) then
    self.newerWarned = true
    self:Print("Someone you sync with has a newer version (" .. v .. ").")
  end
end

function RS:RequestProf(owner, prof, force)
  local key = owner .. "/" .. prof
  local last = self.requested[key]
  if not force and last and GetTime() - last < 60 then return false end
  local pl = self:GetPlayer(owner)
  local dist = pl and pl.dist
  if dist == "CHANNEL" and not self.chanId then dist = nil end
  if (dist == "PARTY" or dist == "RAID") and self:GroupDist() ~= dist then dist = nil end
  dist = dist or (IsInGuild() and "GUILD") or (self.chanId and "CHANNEL") or self:GroupDist()
  if not dist then return false end
  self.requested[key] = GetTime()
  self:Send("Q^" .. owner .. "^" .. prof, dist)
  return true
end

-- send owner's list (our own, or a copy we hold for someone who is offline)
function RS:ServeList(owner, prof, dist)
  local pl = self:GetPlayer(owner)
  local p = pl and pl.profs[prof]
  if not p or not p.data or not p.hash then return end
  local key = owner .. "/" .. prof .. "/" .. dist
  local last = self.served[key]
  if last and GetTime() - last < 30 then return end
  if getn(self.bulkQ) > self.LIMIT.bulkQueue then return end
  local chunks = self:Chunk(p.data, self.CHUNK)
  if getn(chunks) > self.LIMIT.chunksPerXfer then return end
  self.served[key] = GetTime() + 3600 -- in flight until the end marker is sent
  self:Send("S^R^" .. prof .. "^" .. p.hash .. "^" .. getn(chunks) .. "^" .. (p.rank or 0) .. ":" .. (p.max or 0) .. ":" .. (p.count or 0)
    .. "^" .. owner .. "^" .. (pl.seen or time()), dist, true)
  for i = 1, getn(chunks) do self:Send("C^" .. chunks[i] .. ".", dist, true) end
  self:Send("E^R^" .. prof .. "^" .. p.hash, dist, true, function() RS.served[key] = GetTime() end)
end

function RS:ScheduleAutoFetch(owner, prof)
  self:After("af/" .. owner .. "/" .. prof, 3 + math.random() * 12, function()
    local p = RS:GetProf(owner, prof)
    if not p or p.hash == p.latest then return end
    local now, n = GetTime(), 0
    for i = getn(RS.autoLog), 1, -1 do
      if now - RS.autoLog[i] > 300 then tremove(RS.autoLog, i) else n = n + 1 end
    end
    if n >= RS.LIMIT.autoRequests then return end
    if RS:RequestProf(owner, prof) then tinsert(RS.autoLog, now) end
  end)
end

function RS:DumpManual(dist)
  local key = "mdump/" .. dist
  local last = self.lastDump[key]
  if last and GetTime() - last < 120 then return end
  if getn(self.bulkQ) > self.LIMIT.bulkQueue then return end
  local recs = {}
  for _, m in pairs(self.manual) do
    tinsert(recs, m.c .. "," .. m.p .. "," .. m.s .. "," .. m.t .. "," .. (m.d and 1 or 0) .. "," .. m.b)
  end
  if getn(recs) == 0 then return end
  tsort(recs)
  local digest = self:ManualDigest()
  local chunks = self:Chunk(tconcat(recs, ";"), self.CHUNK)
  if getn(chunks) > self.LIMIT.chunksPerXfer then return end
  self.lastDump[key] = GetTime()
  self:Send("S^M^*^" .. digest .. "^" .. getn(chunks) .. "^" .. getn(recs), dist, true)
  for i = 1, getn(chunks) do self:Send("C^" .. chunks[i] .. ".", dist, true) end
  self:Send("E^M^*^" .. digest, dist, true)
end

-- counter = we just merged someone's list and still have entries they lack
function RS:ScheduleManualDump(dist, counter)
  local seen = self.lastDump["seenM/" .. dist]
  if not counter and seen and GetTime() - seen < 60 then return end
  if self:ManualCount() == 0 then return end
  self:After("mdump/" .. dist, (counter and 8 or 4) + math.random() * 16, function()
    local s = RS.lastDump["seenM/" .. dist]
    if not counter and s and GetTime() - s < 60 then return end
    RS:DumpManual(dist)
  end)
end

function RS:ScheduleDirectory(dist)
  local seen = self.lastDump["seenD/" .. dist]
  if seen and GetTime() - seen < 60 then return end
  self:After("dir/" .. dist, 2 + math.random() * 10, function()
    local s = RS.lastDump["seenD/" .. dist]
    if s and GetTime() - s < 60 then return end -- someone already answered
    RS:SendDirectory(dist)
  end)
end

function RS:RateOK(sender)
  local now = GetTime()
  local m = self.muted[sender]
  if m then
    if now < m then return false end
    self.muted[sender] = nil
  end
  local r = self.rate[sender]
  if not r or now - r.t > 10 then
    r = { t = now, n = 0 }
    self.rate[sender] = r
  end
  r.n = r.n + 1
  if r.n > self.LIMIT.msgsPer10s then
    self.muted[sender] = now + self.LIMIT.mute
    for k, tr in pairs(self.inbound) do
      if tr.sender == sender then self.inbound[k] = nil end
    end
    self:Debug("Ignoring " .. sender .. " for a while (too many messages).")
    return false
  end
  return true
end

local DISTS = { GUILD = true, PARTY = true, RAID = true, BATTLEGROUND = true, CHANNEL = true }

function RS:OnComm(prefix, msg, dist, sender)
  if prefix ~= self.PREFIX or type(msg) ~= "string" or type(sender) ~= "string" then return end
  if not self.players or sender == self:MyName() or not DISTS[dist] then return end
  if strlen(msg) > 250 or strlen(msg) < 2 or strsub(msg, 2, 2) ~= "^" then return end
  if not self:RateOK(sender) then return end
  self:Safe(self.HandleMessage, self, strsub(msg, 1, 1), strsub(msg, 3), dist, sender)
end

function RS:HandleMessage(t, body, dist, sender)
  local now = GetTime()
  self.live[sender] = now

  if t == "H" then
    local f = Split(body, "^")
    if f[1] ~= self.PROTO then self:CheckVersion(f[2]); return end
    local pl = self:GetPlayer(sender, true)
    pl.dist = dist
    self:Seen(sender)
    if self.CLASS_COLORS[f[3] or ""] then pl.class = f[3] end
    self:After("reply/" .. dist, 1 + math.random() * 5, function() RS:Send(RS:BuildIndex(), dist) end)

  elseif t == "I" then
    local f = Split(body, "^")
    if f[1] ~= self.PROTO then self:CheckVersion(f[2]); return end
    self:CheckVersion(f[2])
    local pl = self:GetPlayer(sender, true)
    pl.dist = dist
    self:Seen(sender)
    if self.CLASS_COLORS[f[3] or ""] then pl.class = f[3] end
    local listed, any = {}, false
    if f[4] and f[4] ~= "" then
      local entries = Split(f[4], ";")
      for i = 1, getn(entries) do
        if i > self.LIMIT.indexEntries then break end
        local x = Split(entries[i], ":")
        local prof, hash = x[1], x[5]
        if prof and prof ~= "" and strlen(prof) <= 30 and hash and strlen(hash) <= 10 then
          listed[prof] = true
          any = true
          local p = pl.profs[prof]
          if not p then p = {}; pl.profs[prof] = p end
          p.rank, p.max, p.count, p.latest, p.metaSeen = tonumber(x[2]), tonumber(x[3]), tonumber(x[4]), hash, time()
          if p.hash ~= p.latest and self.db.settings.autoFetch then self:ScheduleAutoFetch(sender, prof) end
        end
      end
    end
    if any then
      for prof in pairs(pl.profs) do
        if not listed[prof] then pl.profs[prof] = nil end
      end
    end
    local md = Split(f[5] or "", ":")
    if md[2] and md[2] ~= self:ManualDigest() then self:ScheduleManualDump(dist) end
    self:Changed()

  elseif t == "D" then
    -- someone asks for the directory; answer only if ours differs (one answer per minute per channel)
    if body ~= self:DirDigest() then self:ScheduleDirectory(dist) end

  elseif t == "Q" then
    local f = Split(body, "^")
    local target, prof = f[1], f[2]
    if not target or not prof or not self:ValidName(target) then return end
    self.requested[target .. "/" .. prof] = now
    if target == self:MyName() then
      self:ServeList(target, prof, dist)
    elseif not self:IsOnline(target) and self:Fresh(target) then
      -- crafter is offline: one of the people holding a copy passes it along
      local p = self:GetProf(target, prof)
      if p and p.data and (not p.latest or p.latest == p.hash) then
        self:After("relay/" .. target .. "/" .. prof .. "/" .. dist, 1.5 + math.random() * 5, function()
          local s = RS.seenXfer[target .. "/" .. prof .. "/" .. dist]
          if s and GetTime() - s < 30 then return end
          RS:ServeList(target, prof, dist)
        end)
      end
    end

  elseif t == "M" then
    local f = Split(body, "^")
    local r = self.manualRate[sender]
    if not r or now - r.t > 60 then r = { t = now, n = 0 }; self.manualRate[sender] = r end
    r.n = r.n + 1
    if r.n > self.LIMIT.manualPerMin then return end
    local spell = ParseId(f[3])
    if spell and self:MergeManual(f[1], f[2], spell, f[4], f[5] == "1", f[6]) then self:Changed() end

  elseif t == "S" then
    local f = Split(body, "^")
    local kind, key, hash, n = f[1], f[2], f[3], tonumber(f[4])
    if (kind ~= "R" and kind ~= "M" and kind ~= "D") or not key or not hash or strlen(hash) > 10
       or not n or n < 0 or n > self.LIMIT.chunksPerXfer then return end
    local count = 0
    for _ in pairs(self.inbound) do count = count + 1 end
    local ikey = sender .. "/" .. dist
    if count >= self.LIMIT.inbound and not self.inbound[ikey] then return end
    local tr = { kind = kind, key = key, hash = hash, n = n, parts = {}, sender = sender, last = now }
    if kind == "R" then
      local m = Split(f[5] or "", ":")
      tr.rank, tr.max, tr.count = tonumber(m[1]), tonumber(m[2]), tonumber(m[3])
      tr.owner = f[6] or sender
      if not self:ValidName(tr.owner) then return end
      tr.seen = tonumber(f[7])
      self.requested[tr.owner .. "/" .. key] = now
      self.seenXfer[tr.owner .. "/" .. key .. "/" .. dist] = now
      self:Cancel("relay/" .. tr.owner .. "/" .. key .. "/" .. dist)
    elseif kind == "M" then
      self.lastDump["seenM/" .. dist] = now
      self:Cancel("mdump/" .. dist)
    else
      self.lastDump["seenD/" .. dist] = now
      self:Cancel("dir/" .. dist)
    end
    self.inbound[ikey] = tr
    self:NotifyProgress()

  elseif t == "C" then
    local tr = self.inbound[sender .. "/" .. dist]
    if tr then
      if getn(tr.parts) >= tr.n then self.inbound[sender .. "/" .. dist] = nil; return end
      tinsert(tr.parts, strsub(body, 1, -2))
      tr.last = now
      self:NotifyProgress()
    end

  elseif t == "E" then
    local ikey = sender .. "/" .. dist
    local tr = self.inbound[ikey]
    self.inbound[ikey] = nil
    local f = Split(body, "^")
    if not tr or tr.kind ~= f[1] or tr.key ~= f[2] or tr.hash ~= f[3] or getn(tr.parts) ~= tr.n then return end
    local data = tconcat(tr.parts)
    if tr.kind == "R" then
      self:ReceiveList(tr, data)
    elseif tr.kind == "M" then
      local recs = Split(data, ";")
      local changed = false
      for i = 1, getn(recs) do
        if i > self.LIMIT.manualTotal then break end
        local x = Split(recs[i], ",")
        local spell = ParseId(x[3])
        if spell and self:MergeManual(x[1], x[2], spell, x[4], x[5] == "1", x[6]) then changed = true end
      end
      if changed then self:Changed() end
      if self:ManualDigest() ~= tr.hash then self:ScheduleManualDump(dist, true) end
    else
      self:MergeDirectory(data, dist)
    end
    self:NotifyProgress()
  end
end

function RS:ReceiveList(tr, data)
  local owner = tr.owner
  self.requested[owner .. "/" .. tr.key] = nil
  if owner == self:MyName() then return end -- nobody else gets to tell us what we know
  if self:Hash(data) ~= tr.hash or not self:ParseKnown(data, tr.hash) then return end
  local relayed = owner ~= tr.sender
  local seen = relayed and tr.seen and tr.seen <= time() + 3600 and tr.seen or time()
  if relayed and time() - seen >= self.STALE then return end
  local pl = self:GetPlayer(owner, seen)
  local p = pl.profs[tr.key]
  -- a passed-along copy is only accepted if it matches what the owner last announced
  if relayed and p and p.latest and p.latest ~= tr.hash then return end
  if not p then p = {}; pl.profs[tr.key] = p end
  p.data, p.hash = data, tr.hash
  if not p.latest or not relayed then p.latest = tr.hash end
  p.rank, p.max, p.count, p.updated = tr.rank, tr.max, tr.count, time()
  if relayed then
    if tr.seen then self:Seen(owner, tr.seen) end
  else
    self:Seen(owner)
  end
  self:Changed()
  if self.View and self.View.OnDataReceived then self.View:OnDataReceived(owner, tr.key) end
end

function RS:SweepInbound()
  local now = GetTime()
  for k, tr in pairs(self.inbound) do
    if now - tr.last > 60 then self.inbound[k] = nil end
  end
  for k, r in pairs(self.rate) do
    if now - r.t > 60 then self.rate[k] = nil end
  end
  for k, t in pairs(self.seenXfer) do
    if now - t > 120 then self.seenXfer[k] = nil end
  end
end

function RS:Progress(owner, prof)
  for _, tr in pairs(self.inbound) do
    if tr.kind == "R" and tr.owner == owner and tr.key == prof then return getn(tr.parts), tr.n end
  end
end

function RS:NotifyProgress()
  self:After("progress", 0.3, function()
    if RS.Main and RS.Main.UpdateStatus then RS:Safe(RS.Main.UpdateStatus, RS.Main) end
  end)
end

-------------------------------------------------------------------------------
-- Online state / guild roster
-------------------------------------------------------------------------------
function RS:UpdateRoster()
  self.online = {}
  if not IsInGuild() then return end
  local n = GetNumGuildMembers(true) or 0
  if n > 1000 then n = 1000 end
  local now = time()
  for i = 1, n do
    local name, _, _, _, class, _, _, _, online = GetGuildRosterInfo(i)
    if name then
      local tok = ClassToken(class)
      if tok then self.rosterClass[name] = tok end
      if online then
        self.online[name] = true
        self.rosterSeen[name] = now
      elseif GetGuildRosterLastOnline then
        local y, m, d, h = GetGuildRosterLastOnline(i)
        if y or m or d or h then
          local away = ((y or 0) * 365 + (m or 0) * 30 + (d or 0)) * 86400 + (h or 0) * 3600
          self.rosterSeen[name] = now - away
        end
      end
      local pl = self.players[name]
      if pl and self.rosterSeen[name] and self.rosterSeen[name] > (pl.seen or 0) then pl.seen = self.rosterSeen[name] end
    end
  end
  self:Changed()
end

function RS:IsOnline(name)
  if name == self:MyName() then return true end
  if self.online[name] then return true end
  for i = 1, GetNumPartyMembers() do
    if UnitName("party" .. i) == name then return true end
  end
  for i = 1, GetNumRaidMembers() do
    if UnitName("raid" .. i) == name then return true end
  end
  local l = self.live[name]
  return l and (GetTime() - l) < 300
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------
local frame = CreateFrame("Frame", "RecipeSyncCoreFrame")
RS.frame = frame
for _, e in ipairs({ "ADDON_LOADED", "PLAYER_ENTERING_WORLD", "TRADE_SKILL_SHOW", "TRADE_SKILL_UPDATE",
  "TRADE_SKILL_CLOSE", "CRAFT_SHOW", "CRAFT_UPDATE", "CRAFT_CLOSE", "CHAT_MSG_ADDON", "CHAT_MSG_CHANNEL",
  "GUILD_ROSTER_UPDATE", "PLAYER_GUILD_UPDATE", "SKILL_LINES_CHANGED", "PARTY_MEMBERS_CHANGED",
  "RAID_ROSTER_UPDATE", "UPDATE_CHAT_WINDOWS" }) do
  frame:RegisterEvent(e)
end

function RS:OnEvent(event, a1, a2, a3, a4, a9)
  if event == "ADDON_LOADED" then
    if a1 == "RecipeSync" then self:InitDB() end
    return
  end
  if not self.players then return end

  if event == "CHAT_MSG_CHANNEL" then
    if self.chanName and type(a9) == "string" and strlower(a9) == strlower(self.chanName)
       and type(a1) == "string" and strsub(a1, 1, 4) == self.CHANTAG then
      self:OnComm(self.PREFIX, strsub(a1, 5), "CHANNEL", a2)
    end
  elseif event == "CHAT_MSG_ADDON" then
    self:OnComm(a1, a2, a3, a4)
  elseif event == "PLAYER_ENTERING_WORLD" then
    if not self.loggedIn then
      self.loggedIn = true
      self:Print("loaded. Type |cffffff00/recipes|r to see your guild's professions.")
      if IsInGuild() then GuildRoster() end
      self:After("login", 8, function()
        RS:Announce()
        if IsInGuild() then RS:RequestDirectory("GUILD") end
      end)
      self:After("channel", 6, function() RS:UpdateChannel() end)
      self:After("prune", 20, function() RS:PruneOwn(); RS:PruneStale() end)
    end
  elseif event == "TRADE_SKILL_SHOW" then
    self.tradeOpen = true
    self.scanState.trade = { expands = 0, retries = 0 }
    self:ScheduleScan("trade", 0.7)
  elseif event == "TRADE_SKILL_UPDATE" then
    if self.tradeOpen then self:ScheduleScan("trade", 0.7) end
  elseif event == "TRADE_SKILL_CLOSE" then
    self.tradeOpen = nil
  elseif event == "CRAFT_SHOW" then
    self.craftOpen = true
    self.scanState.craft = { expands = 0, retries = 0 }
    self:ScheduleScan("craft", 0.7)
  elseif event == "CRAFT_UPDATE" then
    if self.craftOpen then self:ScheduleScan("craft", 0.7) end
  elseif event == "CRAFT_CLOSE" then
    self.craftOpen = nil
  elseif event == "GUILD_ROSTER_UPDATE" then
    self:After("roster", 1, function() RS:UpdateRoster() end)
  elseif event == "PLAYER_GUILD_UPDATE" then
    if self.loggedIn then self:After("channel", 3, function() RS:UpdateChannel() end) end
  elseif event == "UPDATE_CHAT_WINDOWS" then
    if self.chanName then self:After("hidechan", 1, function() RS:HideChannel() end) end
  elseif event == "SKILL_LINES_CHANGED" then
    if self.loggedIn then self:After("pruneown", 3, function() RS:PruneOwn() end) end
  elseif event == "PARTY_MEMBERS_CHANGED" or event == "RAID_ROSTER_UPDATE" then
    if not self.loggedIn then return end
    local size = GetNumRaidMembers()
    if size == 0 then size = GetNumPartyMembers() end
    local grew = size > (self.groupSize or 0)
    self.groupSize = size
    if grew then
      self:After("group", 8, function()
        local d = RS:GroupDist()
        if d and (not RS.lastGroupAnnounce or GetTime() - RS.lastGroupAnnounce > 60) then
          RS.lastGroupAnnounce = GetTime()
          RS:Announce(d)
        end
      end)
    end
  end
end

frame:SetScript("OnEvent", function()
  RS:Safe(RS.OnEvent, RS, event, arg1, arg2, arg3, arg4, arg9)
end)

local acc, sweep, hourly = 0, 0, 0
frame:SetScript("OnUpdate", function()
  acc = acc + (arg1 or 0)
  if acc < 0.1 then return end
  local elapsed = acc
  acc = 0
  local now = GetTime()
  local due
  for k, t in pairs(RS.timers) do
    if now >= t.t then
      due = due or {}
      tinsert(due, k)
    end
  end
  if due then
    for i = 1, getn(due) do
      local t = RS.timers[due[i]]
      if t and now >= t.t then
        RS.timers[due[i]] = nil
        RS:Safe(t.fn)
      end
    end
  end
  RS:PumpQueue(elapsed)
  sweep = sweep + elapsed
  if sweep > 10 then
    sweep = 0
    RS:SweepInbound()
  end
  hourly = hourly + elapsed
  if hourly > 3600 and RS.players then
    hourly = 0
    RS:Safe(RS.PruneStale, RS)
  end
end)
