--[[
  RecipeSync - /recipes window: one clickable icon per profession, plus slash commands.
]]

local RS = RecipeSync
local M = {}
RS.Main = M

local getn, tinsert = table.getn, table.insert
local strfind, strlower, strsub = string.find, string.lower, string.sub

local COLS, CELL_W, CELL_H = 4, 86, 74

local function Dialog(name, w, h, title)
  local f = CreateFrame("Frame", name, UIParent)
  f:SetWidth(w); f:SetHeight(h)
  f:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
  f:SetFrameStrata("DIALOG")
  f:EnableMouse(true)
  f:SetMovable(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function() this:StartMoving() end)
  f:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)
  f:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 },
  })
  f:Hide()
  tinsert(UISpecialFrames, name)
  local header = f:CreateTexture(nil, "ARTWORK")
  header:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
  header:SetWidth(300); header:SetHeight(64)
  header:SetPoint("TOP", f, "TOP", 0, 12)
  local t = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  t:SetPoint("TOP", header, "TOP", 0, -14)
  t:SetText(title)
  local close = CreateFrame("Button", name .. "Close", f, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -6)
  return f
end
RS.Dialog = Dialog

function M:Create()
  if self.frame then return end
  local profs = RS:ProfList()
  local rows = math.ceil(getn(profs) / COLS)
  local f = Dialog("RecipeSyncFrame", COLS * CELL_W + 40, rows * CELL_H + 170, "Guild Professions")
  self.frame = f
  self.buttons = {}

  for i = 1, getn(profs) do
    local p = profs[i]
    local col, row = math.mod(i - 1, COLS), math.floor((i - 1) / COLS)
    local b = CreateFrame("Button", "RecipeSyncProf" .. i, f, "ItemButtonTemplate")
    b:SetPoint("TOP", f, "TOPLEFT", 20 + CELL_W / 2 + col * CELL_W, -40 - row * CELL_H)
    SetItemButtonTexture(b, "Interface\\Icons\\" .. p.icon)
    b.prof = p.name
    local name = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    name:SetPoint("TOP", b, "BOTTOM", 0, -2)
    name:SetText(p.name)
    local sub = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    sub:SetPoint("TOP", name, "BOTTOM", 0, -1)
    sub:SetTextColor(0.7, 0.7, 0.7)
    b.sub = sub
    b:RegisterForClicks("LeftButtonUp")
    b:SetScript("OnClick", function() RS.View:Open(this.prof) end)
    b:SetScript("OnEnter", function() M:ShowTip(this) end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    self.buttons[i] = b
  end

  local cb = CreateFrame("CheckButton", "RecipeSyncFrameUnconfirmed", f, "UICheckButtonTemplate")
  cb:SetWidth(24); cb:SetHeight(24)
  cb:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 18, 84)
  RecipeSyncFrameUnconfirmedText:SetText("Show unconfirmed names")
  cb:SetScript("OnClick", function()
    RS.db.settings.showUnconfirmed = this:GetChecked() and true or false
    M:Refresh()
    if RS.View.active then RS.View:Refresh() end
  end)
  cb:SetScript("OnEnter", function()
    GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
    GameTooltip:SetText("Unconfirmed names", 1, 1, 1)
    GameTooltip:AddLine("Names added by hand for players who don't use RecipeSync. They show with a (?) and a yellow recipe colour.", nil, nil, nil, 1)
    GameTooltip:Show()
  end)
  cb:SetScript("OnLeave", function() GameTooltip:Hide() end)
  self.cbUnconf = cb

  local status = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  status:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 22, 64)
  status:SetWidth(COLS * CELL_W)
  status:SetJustifyH("LEFT")
  self.status = status

  local sync = CreateFrame("Button", "RecipeSyncFrameSync", f, "UIPanelButtonTemplate")
  sync:SetWidth(84); sync:SetHeight(22)
  sync:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 18, 20)
  sync:SetText("Sync Now")
  sync:SetScript("OnClick", function() M:SyncNow() end)

  -- guild to sync with: defaults to your own guild; type another guild's name to join theirs
  local eb = CreateFrame("EditBox", "RecipeSyncFrameGuild", f, "InputBoxTemplate")
  eb:SetWidth(120); eb:SetHeight(20)
  eb:SetPoint("LEFT", sync, "RIGHT", 14, 0)
  eb:SetAutoFocus(false)
  eb:SetMaxLetters(40)
  local lbl = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  lbl:SetPoint("BOTTOMLEFT", eb, "TOPLEFT", -4, 2)
  lbl:SetText("Sync with guild:")
  local hint = eb:CreateFontString(nil, "ARTWORK", "GameFontDisable")
  hint:SetPoint("LEFT", eb, "LEFT", 2, 0)
  eb.hint = hint
  eb:SetScript("OnEnterPressed", function()
    RS:SetSyncGroup(this:GetText())
    this:ClearFocus()
    this.focused = false
    M:UpdateGuildBox()
    M:UpdateStatus()
  end)
  eb:SetScript("OnEscapePressed", function() this:ClearFocus(); this.focused = false; M:UpdateGuildBox() end)
  eb:SetScript("OnEditFocusGained", function() this.focused = true end)
  eb:SetScript("OnEditFocusLost", function() this.focused = false; M:UpdateGuildBox() end)
  eb:SetScript("OnTextChanged", function()
    if (this:GetText() or "") == "" then this.hint:Show() else this.hint:Hide() end
  end)
  eb:SetScript("OnEnter", function()
    GameTooltip:SetOwner(this, "ANCHOR_TOP")
    GameTooltip:SetText("Sync with guild", 1, 1, 1)
    GameTooltip:AddLine("Leave empty to sync with your own guild. To share recipes with a guild you're not in, type its exact name and press Enter. Everyone who types the same name shares recipes with each other (same faction only).", nil, nil, nil, 1)
    GameTooltip:Show()
  end)
  eb:SetScript("OnLeave", function() GameTooltip:Hide() end)
  self.guildBox = eb

  local export = CreateFrame("Button", "RecipeSyncFrameExport", f, "UIPanelButtonTemplate")
  export:SetWidth(116); export:SetHeight(22)
  export:SetPoint("LEFT", eb, "RIGHT", 10, 0)
  export:SetText("Export to Sheets")
  export:SetScript("OnClick", function() RS.Export:Show() end)
  export:SetScript("OnEnter", function()
    GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
    GameTooltip:SetText("Export to Google Sheets", 1, 1, 1)
    GameTooltip:AddLine("Makes a table of every known recipe and who can make it, ready to paste into a spreadsheet for people without the addon.", nil, nil, nil, 1)
    GameTooltip:Show()
  end)
  export:SetScript("OnLeave", function() GameTooltip:Hide() end)

  f:SetScript("OnShow", function()
    if IsInGuild() then GuildRoster() end
    M:UpdateGuildBox()
    M:Refresh()
  end)
end

local function Stats(prof)
  local sp = RS:Static(prof)
  local c = RS:Crafters(prof)
  local show = RS.db.settings.showUnconfirmed
  local people, known = {}, 0
  local n = 0
  for spell, list in pairs(c.bySpell) do
    local any
    for i = 1, getn(list) do
      if list[i].ok or show then people[list[i].name] = true; any = true end
    end
    if any and sp.bySpell[spell] then known = known + 1 end
  end
  for _ in pairs(people) do n = n + 1 end
  return n, known, sp and getn(sp.recipes) or 0
end

function M:UpdateGuildBox()
  if not self.guildBox or self.guildBox.focused then return end
  local custom = RS.db.settings.syncGuild
  self.guildBox:SetText(custom or "")
  local own = GetGuildInfo("player")
  self.guildBox.hint:SetText(own or "guild name")
  if custom == "" then self.guildBox.hint:Show() else self.guildBox.hint:Hide() end
end

function M:Refresh()
  if not self.frame or not self.frame:IsVisible() then return end
  for i = 1, getn(self.buttons) do
    local b = self.buttons[i]
    local n = Stats(b.prof)
    if n == 0 then
      b.sub:SetText("nobody yet")
      SetItemButtonDesaturated(b, 1)
    else
      b.sub:SetText(n == 1 and "1 crafter" or (n .. " crafters"))
      SetItemButtonDesaturated(b, nil)
    end
  end
  self.cbUnconf:SetChecked(RS.db.settings.showUnconfirmed)
  self:UpdateStatus()
end

function M:ShowTip(b)
  local n, known, total = Stats(b.prof)
  GameTooltip:SetOwner(b, "ANCHOR_RIGHT")
  GameTooltip:SetText(b.prof, 1, 1, 1)
  GameTooltip:AddLine(known .. " of " .. total .. " recipes known in your guild", 1, 0.82, 0)
  GameTooltip:AddLine(n .. (n == 1 and " crafter" or " crafters"), 0.8, 0.8, 0.8)
  -- list a few crafters with their skill
  local names = {}
  for name, pl in pairs(RS.players) do
    local p = pl.profs[b.prof]
    if p and p.data and RS:Fresh(name) then tinsert(names, { name = name, rank = p.rank or 0 }) end
  end
  table.sort(names, function(x, y) return x.rank > y.rank end)
  for i = 1, getn(names) do
    if i > 10 then GameTooltip:AddLine("...", 0.6, 0.6, 0.6); break end
    GameTooltip:AddDoubleLine(RS:ColorName(names[i].name), names[i].rank > 0 and names[i].rank or "", 1, 1, 1, 0.8, 0.8, 0.8)
  end
  GameTooltip:AddLine("Click to open", 0.5, 0.8, 1)
  GameTooltip:Show()
end

function M:UpdateStatus()
  if not self.frame or not self.frame:IsVisible() then return end
  local parts = {}
  if not IsInGuild() and not RS:GroupDist() then
    tinsert(parts, "|cffff6060Not in a guild or group: nothing to sync with.|r")
  end
  local recv = 0
  for _ in pairs(RS.inbound) do recv = recv + 1 end
  if recv > 0 then tinsert(parts, "Receiving " .. recv .. (recv == 1 and " list" or " lists") .. "...") end
  if getn(RS.bulkQ) > 0 then tinsert(parts, "Sending...") end
  if getn(parts) == 0 then
    local users = 0
    for name, pl in pairs(RS.players) do
      for _, p in pairs(pl.profs) do
        if p.data and RS:Fresh(name) then users = users + 1; break end
      end
    end
    local group = RS:SyncGroup()
    local chan = ""
    if group then
      chan = "Guild: |cffffd100" .. group .. "|r" .. (RS.chanId and "" or " |cff888888(joining...)|r") .. "  "
    end
    tinsert(parts, chan .. users .. " crafters saved.")
  end
  self.status:SetText(table.concat(parts, "  "))
end

function M:SyncNow()
  if IsInGuild() then GuildRoster() end
  if not RS.chanId then RS:UpdateChannel() end
  RS:Announce()
  local d = RS:Dists()
  for i = 1, table.getn(d) do RS:RequestDirectory(d[i]) end
  -- fetch missing/outdated lists; offline crafters' lists are passed along by whoever has a copy
  local n = 0
  for name, pl in pairs(RS.players) do
    if name ~= RS:MyName() and RS:Fresh(name) then
      for prof, p in pairs(pl.profs) do
        if n < RS.LIMIT.syncNowRequests and (not p.data or p.hash ~= p.latest) and RS:RequestProf(name, prof) then n = n + 1 end
      end
    end
  end
  RS:Print(n > 0 and ("Requested " .. n .. " recipe list(s).") or "Announced. Everything looks up to date.")
end

function M:Toggle()
  self:Create()
  if self.frame:IsVisible() then self.frame:Hide() else self.frame:Show() end
end

-------------------------------------------------------------------------------
-- Slash commands
-------------------------------------------------------------------------------
local function FindProf(q)
  q = strlower(q or "")
  if q == "" then return nil end
  local list = RS:ProfList()
  for i = 1, getn(list) do
    if strsub(strlower(list[i].name), 1, string.len(q)) == q then return list[i].name end
  end
end

local function OnOff(v, cur)
  if v == "on" then return true elseif v == "off" then return false end
  return not cur
end

local HELP = {
  "/recipes - open the guild professions window",
  "/recipes <profession> - open one directly, e.g. /recipes tail",
  "/recipes sync - announce yourself and fetch anything missing",
  "/recipes guild <name> - sync with another guild (empty = your own guild)",
  "/recipes export - open the spreadsheet export",
  "/recipes auto on|off - download lists automatically when they change (now: %s)",
  "/recipes unsafe on|off - tooltips for items not in your cache (now: %s)",
  "/recipes forget <player> - delete a player's saved recipes",
}

SLASH_RECIPESYNC1 = "/recipes"
SLASH_RECIPESYNC2 = "/rsync"
SlashCmdList["RECIPESYNC"] = function(msg)
  if not RS.db then return end
  local _, _, cmd, rest = strfind(msg or "", "^%s*(%S*)%s*(.-)%s*$")
  cmd = strlower(cmd or "")
  rest = rest or ""
  local s = RS.db.settings
  if cmd == "" then
    M:Toggle()
  elseif cmd == "help" or cmd == "?" then
    for i = 1, getn(HELP) do
      RS:Print(string.format(HELP[i], s.autoFetch and "on" or "off", s.unsafeTooltips and "on" or "off"))
    end
  elseif cmd == "sync" then
    M:SyncNow()
  elseif cmd == "guild" then
    RS:SetSyncGroup(rest)
    M:UpdateGuildBox()
  elseif cmd == "export" then
    RS.Export:Show()
  elseif cmd == "auto" then
    s.autoFetch = OnOff(strlower(rest), s.autoFetch)
    RS:Print("Automatic download " .. (s.autoFetch and "on" or "off"))
  elseif cmd == "unsafe" then
    s.unsafeTooltips = OnOff(strlower(rest), s.unsafeTooltips)
    RS:Print("Tooltips for uncached items " .. (s.unsafeTooltips and "on" or "off"))
  elseif cmd == "debug" then
    s.debug = not s.debug
    RS:Print("Debug " .. (s.debug and "on" or "off"))
  elseif cmd == "forget" and rest ~= "" then
    local name = RS:CapName(rest)
    if RS.players[name] then
      RS.players[name] = nil
      RS:Changed()
      RS:Print("Forgot " .. name .. ".")
    else
      RS:Print("No saved data for " .. name .. ".")
    end
  else
    local prof = FindProf(cmd .. (rest ~= "" and (" " .. rest) or ""))
    if prof then RS.View:Open(prof) else RS:Print("Unknown command. Type /recipes help") end
  end
end
