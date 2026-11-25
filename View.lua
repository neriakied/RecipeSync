--[[
  RecipeSync - guild profession view inside the default Blizzard TradeSkillFrame.

  While "view mode" is on, the trade skill API (GetNumTradeSkills, GetTradeSkillInfo, ...) answers
  from the recipe database + synced data, so Blizzard's own code draws the window: headers,
  category dropdown, reagents, tooltips, Shift-click links. Crafting is blocked.

    list colour  green  = known by a RecipeSync user
                 yellow = only unconfirmed (hand-entered) names
                 grey   = nobody known
    [n]          = number of crafters
]]

local RS = RecipeSync
local V = {}
RS.View = V

local getn, tinsert = table.getn, table.insert
local strfind, strlower = string.find, string.lower

V.active = false
V.display = {}
V.filter = 0
V.search = ""
V.counts = {}

local EXTRA_HEADER = "Not in database"

local function Entry(i) if i then return V.display[i] end end
local function Sel(i) local e = Entry(i); if e and not e.h then return e end end

local function Settings() return RS.db.settings end

-------------------------------------------------------------------------------
-- Crafters for a list entry
-------------------------------------------------------------------------------
local function CraftersOf(e)
  if not V.crafters then return nil end
  if e.r then return V.crafters.bySpell[e.r.spell] end
  if e.x then return V.crafters.extras[e.x] end
end

-- confirmed, unconfirmed(shown) counts
local function Counts(e)
  local list = CraftersOf(e)
  local ok, un = 0, 0
  if list then
    local show = Settings().showUnconfirmed
    for i = 1, getn(list) do
      if list[i].ok then ok = ok + 1 elseif show then un = un + 1 end
    end
  end
  return ok, un
end

-------------------------------------------------------------------------------
-- Display list
-------------------------------------------------------------------------------
local function Matches(e, s)
  if s == "" then return true end
  local name = e.r and e.r.name or e.x
  if strfind(strlower(name), s, 1, true) then return true end
  if e.r then
    for i = 1, getn(e.r.reagents) do
      local n = RS:ItemInfo(e.r.reagents[i].id)
      if strfind(strlower(n), s, 1, true) then return true end
    end
  end
  local list = CraftersOf(e)
  if list then
    for i = 1, getn(list) do
      if (list[i].ok or Settings().showUnconfirmed) and strfind(strlower(list[i].name), s, 1, true) then return true end
    end
  end
  return false
end

local function Keep(e, s)
  e.ok, e.un = Counts(e)
  if Settings().knownOnly and e.ok + e.un == 0 then return false end
  return Matches(e, s)
end

function V:Rebuild()
  local d = {}
  local sp = self.sp
  if not sp then self.display = d; return end
  self.crafters = RS:Crafters(self.prof)
  local s = self.search or ""
  if not self.looseHeadered then
    for i = 1, getn(sp.loose) do
      local e = { r = sp.loose[i] }
      if Keep(e, s) then tinsert(d, e) end
    end
  end
  local headers = self.headers
  for h = 1, getn(headers) do
    local hdr = headers[h]
    if self.filter == 0 or self.filter == h then
      local list = {}
      local src = hdr.recipes
      for i = 1, getn(src) do
        local e = hdr.extra and { x = src[i] } or { r = src[i] }
        if Keep(e, s) then tinsert(list, e) end
      end
      if getn(list) > 0 then
        tinsert(d, { h = hdr })
        if hdr.expanded or s ~= "" then
          for i = 1, getn(list) do tinsert(d, list[i]) end
        end
      end
    end
  end
  self.display = d
  self.selIdx = nil
  -- recipes known by anyone (for the rank bar)
  local known = 0
  for i = 1, getn(sp.recipes) do
    local ok, un = Counts({ r = sp.recipes[i] })
    if ok + un > 0 then known = known + 1 end
  end
  self.known = known
end

-- headers = database headers + one for synced recipes that aren't in the database
function V:BuildHeaders()
  local hs = {}
  for i = 1, getn(self.sp.headers) do
    local h = self.sp.headers[i]
    h.expanded = true
    tinsert(hs, h)
  end
  local extras = {}
  for name in pairs(RS:Crafters(self.prof).extras) do tinsert(extras, name) end
  table.sort(extras)
  if getn(extras) > 0 then
    tinsert(hs, { name = EXTRA_HEADER, recipes = extras, expanded = true, extra = true })
  end
  -- no database headers but some extras: still group the database recipes
  if getn(self.sp.headers) == 0 and getn(extras) > 0 then
    tinsert(hs, 1, { name = self.prof, recipes = self.sp.loose, expanded = true })
    self.looseHeadered = true
  else
    self.looseHeadered = nil
  end
  self.headers = hs
end

function V:CountBags()
  local c = {}
  for bag = 0, 4 do
    local slots = GetContainerNumSlots(bag) or 0
    for slot = 1, slots do
      local link = GetContainerItemLink(bag, slot)
      if link then
        local _, _, id = strfind(link, "item:(%d+)")
        id = tonumber(id)
        if id then
          local _, cnt = GetContainerItemInfo(bag, slot)
          c[id] = (c[id] or 0) + (cnt or 1)
        end
      end
    end
  end
  self.counts = c
end

-------------------------------------------------------------------------------
-- Fake trade skill API (only used while V.active)
-------------------------------------------------------------------------------
local F = {}

F.GetNumTradeSkills = function() return getn(V.display) end

F.GetTradeSkillInfo = function(i)
  local e = Entry(i)
  if not e then return nil end
  if e.h then return e.h.name, "header", 0, (e.h.expanded or V.search ~= "") and 1 or nil end
  local ok, un = e.ok or 0, e.un or 0
  local t = "rs_none"
  if ok > 0 then t = "rs_known" elseif un > 0 then t = "rs_unconf" end
  return e.r and e.r.name or e.x, t, ok + un, nil
end

F.GetTradeSkillLine = function()
  return V.prof or "", V.known or 0, V.sp and getn(V.sp.recipes) or 0
end

-- Blizzard calls this once per list row on every redraw, so remember the answer
F.GetTradeSkillSelectionIndex = function()
  if not V.sel then return 0 end
  if V.selIdx then return V.selIdx end
  local idx = 0
  for i = 1, getn(V.display) do
    local e = V.display[i]
    if (e.r and e.r == V.sel.r) or (e.x and e.x == V.sel.x) then idx = i; break end
  end
  V.selIdx = idx
  return idx
end

F.SelectTradeSkill = function(i)
  local e = Sel(i)
  if e then V.sel = e; V.selIdx = nil end
end

F.GetFirstTradeSkill = function()
  for i = 1, getn(V.display) do
    if not V.display[i].h then return i end
  end
  return 0
end

F.GetTradeSkillCooldown = function() return nil end

F.GetTradeSkillIcon = function(i)
  local e = Sel(i)
  if not e then return nil end
  if e.r then return e.r.icon end
  return "Interface\\Icons\\INV_Misc_QuestionMark"
end

F.GetTradeSkillNumMade = function(i)
  local e = Sel(i)
  if e and e.r then return e.r.min, e.r.max end
  return 1, 1
end

F.GetTradeSkillNumReagents = function(i)
  local e = Sel(i)
  if e and e.r then return getn(e.r.reagents) end
  return 0
end

F.GetTradeSkillReagentInfo = function(i, j)
  local e = Sel(i)
  local x = e and e.r and e.r.reagents[j]
  if not x then return nil end
  local name, _, icon = RS:ItemInfo(x.id)
  return name, icon, x.count, V.counts[x.id] or 0
end

F.GetTradeSkillReagentItemLink = function(i, j)
  local e = Sel(i)
  local x = e and e.r and e.r.reagents[j]
  if x then return RS:ItemLink(x.id) end
  return ""
end

F.GetTradeSkillItemLink = function(i)
  local e = Sel(i)
  if not e then return "" end
  if e.r then return RS:RecipeLink(e.r) end
  return e.x
end

F.GetTradeSkillTools = function(i)
  local e = Sel(i)
  if not e or not e.r or getn(e.r.tools) == 0 then return end
  local t = {}
  for k = 1, getn(e.r.tools) do
    local name = RS:ItemInfo(e.r.tools[k])
    tinsert(t, name); tinsert(t, 1)
  end
  return unpack(t)
end

local function AfterToggle()
  V:Rebuild()
  if TradeSkillFrame and TradeSkillFrame:IsVisible() then TradeSkillFrame_Update() end
end

F.ExpandTradeSkillSubClass = function(i)
  if i == 0 then
    for h = 1, getn(V.headers or {}) do V.headers[h].expanded = true end
  else
    local e = Entry(i)
    if e and e.h then e.h.expanded = true end
  end
  AfterToggle()
end

F.CollapseTradeSkillSubClass = function(i)
  if i == 0 then
    for h = 1, getn(V.headers or {}) do V.headers[h].expanded = false end
  else
    local e = Entry(i)
    if e and e.h then e.h.expanded = false end
  end
  AfterToggle()
end

-- the "subclass" dropdown filters by header
F.GetTradeSkillSubClasses = function()
  local t = {}
  for h = 1, getn(V.headers or {}) do
    if h > 30 then break end -- dropdown has 32 lines
    tinsert(t, V.headers[h].name)
  end
  return unpack(t)
end

F.GetTradeSkillSubClassFilter = function(i)
  if V.filter == i then return 1 end
  return nil
end

F.SetTradeSkillSubClassFilter = function(i)
  V.filter = i or 0
  V:Refresh()
end

F.GetTradeSkillInvSlots = function() return end
F.GetTradeSkillInvSlotFilter = function(i) if i == 0 then return 1 end return nil end
F.SetTradeSkillInvSlotFilter = function() end
F.DoTradeSkill = function() end
F.CloseTradeSkill = function() end

local function Wrap(name, fake)
  local orig = getglobal(name)
  setglobal(name, function(...)
    if V.active then return fake(unpack(arg)) end
    if orig then return orig(unpack(arg)) end
  end)
end
for name, fn in pairs(F) do Wrap(name, fn) end

-------------------------------------------------------------------------------
-- Tooltips
-------------------------------------------------------------------------------
local function HexColor(hex)
  if not hex or string.len(hex) < 8 then return 1, 1, 1 end
  return (tonumber(string.sub(hex, 3, 4), 16) or 255) / 255,
         (tonumber(string.sub(hex, 5, 6), 16) or 255) / 255,
         (tonumber(string.sub(hex, 7, 8), 16) or 255) / 255
end

local function CachedItem(id)
  if RS.db.settings.unsafeTooltips then return true end
  -- an item the client hasn't seen can disconnect a 1.12 client when its tooltip is shown
  return GetItemInfo(id) ~= nil
end

function V:ShowTooltip(tt, i, j)
  local e = Sel(i)
  if not e then return end
  if e.x then
    tt:AddLine(e.x, 1, 1, 1)
    tt:AddLine("Not in the recipe database", 0.6, 0.6, 0.6)
    tt:Show()
    return
  end
  local id, body, name, q
  if j then
    local x = e.r.reagents[j]
    if not x then return end
    id = x.id
  elseif e.r.created > 0 and RecipeSyncData.items[e.r.created] then
    id = e.r.created
  end
  if id then
    body = "item:" .. id .. ":0:0:0"
    name, q = RS:ItemInfo(id)
    if CachedItem(id) and pcall(tt.SetHyperlink, tt, body) and tt:NumLines() > 0 then return end
  else
    if pcall(tt.SetHyperlink, tt, "enchant:" .. e.r.spell) and tt:NumLines() > 0 then return end
    name, q = e.r.name, 1
  end
  tt:ClearLines()
  tt:AddLine(name, HexColor(RS.QCOLOR[q]))
  if not j then
    for k = 1, getn(e.r.reagents) do
      local x = e.r.reagents[k]
      tt:AddLine(x.count .. " x " .. RS:ItemInfo(x.id), 1, 1, 1)
    end
  end
  tt:AddLine("(not in your item cache)", 0.6, 0.6, 0.6)
  tt:Show()
end

do
  local orig = GameTooltip.SetTradeSkillItem
  GameTooltip.SetTradeSkillItem = function(self, i, j)
    if V.active then return RS:Safe(V.ShowTooltip, V, self, i, j) end
    if j then return orig(self, i, j) end
    return orig(self, i)
  end
end

-------------------------------------------------------------------------------
-- Hooks into Blizzard_TradeSkillUI (load on demand)
-------------------------------------------------------------------------------
function V:HookFrame()
  if self.hooked or not TradeSkillFrame then return end
  self.hooked = true

  TradeSkillTypeColor["rs_known"]  = { r = 0.25, g = 0.75, b = 0.25 }
  TradeSkillTypeColor["rs_unconf"] = { r = 1.00, g = 1.00, b = 0.00 }
  TradeSkillTypeColor["rs_none"]   = { r = 0.50, g = 0.50, b = 0.50 }

  local origShow = TradeSkillFrame_Show
  TradeSkillFrame_Show = function()
    -- your real profession window is opening while the guild view is up: step aside
    if V.active and not V.opening then V:Deactivate() end
    origShow()
    RS:Safe(V.Decorate, V)
  end

  local origHide = TradeSkillFrame_Hide
  TradeSkillFrame_Hide = function()
    -- TRADE_SKILL_CLOSE from the real window we just closed must not close the guild view
    if V.active and event ~= "PLAYER_ENTERING_WORLD" then return end
    origHide()
  end

  local origUpdate = TradeSkillFrame_Update
  TradeSkillFrame_Update = function()
    origUpdate()
    if V.active then RS:Safe(V.Decorate, V) end
  end

  local origSel = TradeSkillFrame_SetSelection
  TradeSkillFrame_SetSelection = function(id)
    origSel(id)
    if V.active then RS:Safe(V.Decorate, V) end
  end

  local origOnHide = TradeSkillFrame:GetScript("OnHide")
  TradeSkillFrame:SetScript("OnHide", function()
    if origOnHide then origOnHide() end
    if V.active then V:Deactivate() end
  end)

  self:CreateWidgets()
end

local function CheckBox(name, label, x, tip, onClick)
  local cb = CreateFrame("CheckButton", name, TradeSkillFrame, "UICheckButtonTemplate")
  cb:SetWidth(24); cb:SetHeight(24)
  cb:SetPoint("LEFT", TradeSkillFrame, "TOPLEFT", x, -422)
  getglobal(name .. "Text"):SetText(label)
  cb:SetScript("OnClick", onClick)
  cb:SetScript("OnEnter", function()
    GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
    GameTooltip:SetText(label, 1, 1, 1)
    GameTooltip:AddLine(tip, nil, nil, nil, 1)
    GameTooltip:Show()
  end)
  cb:SetScript("OnLeave", function() GameTooltip:Hide() end)
  cb:Hide()
  return cb
end

function V:CreateWidgets()
  -- search box where the inventory-slot dropdown normally is
  local eb = CreateFrame("EditBox", "RecipeSyncViewSearch", TradeSkillFrame, "InputBoxTemplate")
  eb:SetWidth(108); eb:SetHeight(20)
  eb:SetPoint("LEFT", TradeSkillInvSlotDropDown, "LEFT", 30, 2) -- right next to the category dropdown
  eb:SetAutoFocus(false)
  eb:SetMaxLetters(40)
  eb:Hide()
  local hint = eb:CreateFontString(nil, "ARTWORK", "GameFontDisable")
  hint:SetPoint("LEFT", eb, "LEFT", 2, 0)
  hint:SetText(SEARCH or "Search")
  eb.hint = hint
  eb:SetScript("OnTextChanged", function()
    local txt = this:GetText() or ""
    if txt == "" then this.hint:Show() else this.hint:Hide() end
    local s = strlower(txt)
    if s ~= V.search then
      V.search = s
      RS:After("viewsearch", 0.2, function() V:Refresh() end)
    end
  end)
  eb:SetScript("OnEscapePressed", function() this:ClearFocus() end)
  eb:SetScript("OnEnterPressed", function() this:ClearFocus() end)
  eb:SetScript("OnEnter", function()
    GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
    GameTooltip:SetText("Search", 1, 1, 1)
    GameTooltip:AddLine("Recipe, reagent or player name.", nil, nil, nil, 1)
    GameTooltip:Show()
  end)
  eb:SetScript("OnLeave", function() GameTooltip:Hide() end)
  self.searchBox = eb

  self.cbUnconf = CheckBox("RecipeSyncViewUnconfirmed", "Unconfirmed", 18,
    "Show names that were added by hand for players who don't use RecipeSync (marked with ?).",
    function()
      RS.db.settings.showUnconfirmed = this:GetChecked() and true or false
      V:Refresh()
      if RS.Main then RS:Safe(RS.Main.Refresh, RS.Main) end
    end)
  self.cbKnown = CheckBox("RecipeSyncViewKnownOnly", "Known only", 130,
    "Only list recipes that somebody can make.",
    function()
      RS.db.settings.knownOnly = this:GetChecked() and true or false
      V:Refresh()
    end)

  -- crafters section in the detail pane, under the reagents
  local child = TradeSkillDetailScrollChildFrame
  self.origChildHeight = child:GetHeight()
  local label = child:CreateFontString("RecipeSyncCraftersLabel", "BACKGROUND", "GameFontNormalSmall")
  label:SetText("Crafters:")
  label:Hide()
  local text = child:CreateFontString("RecipeSyncCraftersText", "BACKGROUND", "GameFontHighlightSmall")
  text:SetWidth(275)
  text:SetJustifyH("LEFT")
  text:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -3)
  text:Hide()
  self.cLabel, self.cText = label, text

  local add = CreateFrame("Button", "RecipeSyncAddName", child, "UIPanelButtonTemplate")
  add:SetWidth(96); add:SetHeight(20)
  add:SetText("Add Name")
  add:SetPoint("TOPLEFT", text, "BOTTOMLEFT", -2, -6)
  add:SetScript("OnClick", function() V:AskName(false) end)
  add:SetScript("OnEnter", function()
    GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
    GameTooltip:SetText("Add Name", 1, 1, 1)
    GameTooltip:AddLine("Add a player who knows this recipe but doesn't use RecipeSync. Shared with your guild as unconfirmed. Only the top 3 guild ranks can do this.", nil, nil, nil, 1)
    GameTooltip:Show()
  end)
  add:SetScript("OnLeave", function() GameTooltip:Hide() end)
  add:Hide()
  local rem = CreateFrame("Button", "RecipeSyncRemoveName", child, "UIPanelButtonTemplate")
  rem:SetWidth(96); rem:SetHeight(20)
  rem:SetText("Remove Name")
  rem:SetPoint("LEFT", add, "RIGHT", 4, 0)
  rem:SetScript("OnClick", function() V:AskName(true) end)
  rem:Hide()
  self.btnAdd, self.btnRemove = add, rem
end

-- Some clients add their own search box to the trade skill window. It filters the real list (not ours)
-- and sits on top of our checkboxes, so hide any edit box we didn't create while the guild view is up.
local OURS = { RecipeSyncViewSearch = true, TradeSkillInputBox = true }
V.hiddenForeign = {}

local function HideForeign(parent, depth)
  if not parent or depth > 2 or not parent.GetChildren then return end
  local kids = { parent:GetChildren() }
  for i = 1, getn(kids) do
    local k = kids[i]
    local ok, t = pcall(k.GetObjectType, k)
    local name = k.GetName and k:GetName()
    if ok and t == "EditBox" and not OURS[name or ""] then
      if k:IsShown() then
        k:Hide()
        tinsert(V.hiddenForeign, k)
      end
    elseif ok and t == "Frame" then
      HideForeign(k, depth + 1)
    end
  end
end

function V:HideForeignSearch()
  if TradeSkillFrame then HideForeign(TradeSkillFrame, 1) end
end

function V:RestoreForeignSearch()
  for i = 1, getn(self.hiddenForeign) do
    local k = self.hiddenForeign[i]
    if k and k.Show then k:Show() end
  end
  self.hiddenForeign = {}
end

local CRAFT_CONTROLS = {
  "TradeSkillCreateButton", "TradeSkillCreateAllButton", "TradeSkillDecrementButton",
  "TradeSkillInputBox", "TradeSkillIncrementButton",
}

function V:Decorate()
  if not TradeSkillFrame or not self.searchBox then return end
  if not self.active then
    self.searchBox:Hide(); self.cbUnconf:Hide(); self.cbKnown:Hide()
    self.cLabel:Hide(); self.cText:Hide(); self.btnAdd:Hide(); self.btnRemove:Hide()
    return
  end
  TradeSkillFrameTitleText:SetText(self.prof .. " (Guild)")
  for i = 1, getn(CRAFT_CONTROLS) do
    local w = getglobal(CRAFT_CONTROLS[i])
    if w then w:Hide() end
  end
  TradeSkillInvSlotDropDown:Hide()
  if getn(self.headers or {}) < 2 then TradeSkillSubClassDropDown:Hide() end
  RS:Safe(V.HideForeignSearch, V)
  if not self.searchBox:IsShown() then self.searchBox:Show() end
  self.cbUnconf:Show(); self.cbUnconf:SetChecked(Settings().showUnconfirmed)
  self.cbKnown:Show(); self.cbKnown:SetChecked(Settings().knownOnly)
  self:UpdateDetail()
end

-- crafter names under the reagents
function V:UpdateDetail()
  local e = self.sel
  local idx = F.GetTradeSkillSelectionIndex()
  if not e or idx == 0 then
    self.cLabel:Hide(); self.cText:Hide(); self.btnAdd:Hide(); self.btnRemove:Hide()
    return
  end
  local n = e.r and getn(e.r.reagents) or 0
  self.cLabel:ClearAllPoints()
  if n == 0 then
    self.cLabel:SetPoint("TOPLEFT", TradeSkillReagentLabel, "TOPLEFT", 0, 0)
    TradeSkillReagentLabel:Hide()
  else
    TradeSkillReagentLabel:Show()
    local row = n
    if math.mod(n, 2) == 0 then row = n - 1 end
    self.cLabel:SetPoint("TOPLEFT", getglobal("TradeSkillReagent" .. row), "BOTTOMLEFT", 0, -6)
  end

  local list = CraftersOf(e) or {}
  local show = Settings().showUnconfirmed
  local confirmed, unconf = {}, {}
  for i = 1, getn(list) do
    if list[i].ok then tinsert(confirmed, list[i]) elseif show then tinsert(unconf, list[i]) end
  end
  local function sorter(a, b)
    local oa, ob = RS:IsOnline(a.name) and 1 or 0, RS:IsOnline(b.name) and 1 or 0
    if oa ~= ob then return oa > ob end
    return a.name < b.name
  end
  table.sort(confirmed, sorter)
  table.sort(unconf, sorter)
  local parts = {}
  for i = 1, getn(confirmed) do tinsert(parts, RS:ColorName(confirmed[i].name)) end
  for i = 1, getn(unconf) do tinsert(parts, RS:ColorName(unconf[i].name) .. "|cff888888(?)|r") end
  local more = 0
  if getn(parts) > 30 then
    more = getn(parts) - 30
    for i = getn(parts), 31, -1 do table.remove(parts, i) end
  end
  local txt = table.concat(parts, ", ")
  if more > 0 then txt = txt .. " |cff888888and " .. more .. " more|r" end
  if txt == "" then txt = "|cff888888Nobody yet.|r" end
  if not show then
    local hidden = 0
    for i = 1, getn(list) do if not list[i].ok then hidden = hidden + 1 end end
    if hidden > 0 then txt = txt .. " |cff888888(+" .. hidden .. " unconfirmed hidden)|r" end
  end
  local canEdit = RS:CanEditNames()
  if e.r and not canEdit then
    txt = txt .. "\n|cff888888Only the top 3 guild ranks can add or remove names.|r"
  end
  self.cText:SetText(txt)
  self.cLabel:Show(); self.cText:Show()
  if e.r and canEdit then self.btnAdd:Show(); self.btnRemove:Show() else self.btnAdd:Hide(); self.btnRemove:Hide() end

  -- make the detail pane scroll far enough to show everything
  local rows = math.floor((n + 1) / 2)
  local h = 47 + 14 + rows * 43 + 20 + (self.cText:GetHeight() or 12) + 34
  if h < self.origChildHeight then h = self.origChildHeight end
  TradeSkillDetailScrollChildFrame:SetHeight(h)
  TradeSkillDetailScrollFrame:UpdateScrollChildRect()
end

-------------------------------------------------------------------------------
-- Add / remove unconfirmed names
-------------------------------------------------------------------------------
StaticPopupDialogs["RECIPESYNC_ADD_NAME"] = {
  text = "Who else can make %s?\n(character name, shared with everyone as unconfirmed)",
  button1 = ACCEPT or "Accept", button2 = CANCEL or "Cancel",
  hasEditBox = 1, maxLetters = 12, timeout = 0, whileDead = 1, hideOnEscape = 1,
  OnAccept = function(data)
    V:ApplyName(getglobal(this:GetParent():GetName() .. "EditBox"):GetText(), data)
  end,
  EditBoxOnEnterPressed = function()
    local p = this:GetParent()
    V:ApplyName(this:GetText(), p.data)
    p:Hide()
  end,
  EditBoxOnEscapePressed = function() this:GetParent():Hide() end,
  OnShow = function() getglobal(this:GetName() .. "EditBox"):SetFocus() end,
  OnHide = function() getglobal(this:GetName() .. "EditBox"):SetText("") end,
}
StaticPopupDialogs["RECIPESYNC_REMOVE_NAME"] = {
  text = "Remove an unconfirmed crafter from %s:\n(names confirmed by RecipeSync can't be removed)",
  button1 = REMOVE or "Remove", button2 = CANCEL or "Cancel",
  hasEditBox = 1, maxLetters = 12, timeout = 0, whileDead = 1, hideOnEscape = 1,
  OnAccept = StaticPopupDialogs["RECIPESYNC_ADD_NAME"].OnAccept,
  EditBoxOnEnterPressed = StaticPopupDialogs["RECIPESYNC_ADD_NAME"].EditBoxOnEnterPressed,
  EditBoxOnEscapePressed = StaticPopupDialogs["RECIPESYNC_ADD_NAME"].EditBoxOnEscapePressed,
  OnShow = StaticPopupDialogs["RECIPESYNC_ADD_NAME"].OnShow,
  OnHide = StaticPopupDialogs["RECIPESYNC_ADD_NAME"].OnHide,
}

function V:AskName(remove)
  local e = self.sel
  if not e or not e.r or not RS:CanEditNames() then return end
  local dlg = StaticPopup_Show(remove and "RECIPESYNC_REMOVE_NAME" or "RECIPESYNC_ADD_NAME", e.r.name)
  if dlg then dlg.data = { prof = self.prof, spell = e.r.spell, remove = remove } end
end

function V:ApplyName(name, data)
  if not data or not name or name == "" then return end
  name = RS:CapName(name)
  local list = RS:Crafters(data.prof).bySpell[data.spell] or {}
  for i = 1, getn(list) do
    if list[i].name == name and list[i].ok then
      if data.remove then
        RS:Print(name .. " is confirmed by RecipeSync and can't be removed by hand.")
      else
        RS:Print(name .. " already has this recipe (confirmed).")
      end
      return
    end
  end
  if data.remove then
    local found
    for i = 1, getn(list) do if list[i].name == name then found = true end end
    if not found then RS:Print(name .. " isn't listed for this recipe."); return end
  end
  if RS:SetManual(name, data.prof, data.spell, data.remove) then
    RS:Print((data.remove and "Removed " or "Added ") .. name .. (data.remove and " from " or " to ") .. (RS:Static(data.prof).bySpell[data.spell].name) .. ".")
  end
end

-------------------------------------------------------------------------------
-- Open / close
-------------------------------------------------------------------------------
function V:Refresh()
  if not self.active or self.refreshing or not TradeSkillFrame or not TradeSkillFrame:IsVisible() then return end
  self.refreshing = true
  RS:Safe(function()
    V:Rebuild()
    local sel = F.GetTradeSkillSelectionIndex()
    if sel > 0 then
      TradeSkillFrame_SetSelection(sel)
    else
      local first = F.GetFirstTradeSkill()
      if first > 0 then TradeSkillFrame_SetSelection(first) else V.sel = nil; V.selIdx = nil end
      FauxScrollFrame_SetOffset(TradeSkillListScrollFrame, 0)
      TradeSkillListScrollFrameScrollBar:SetValue(0)
    end
    TradeSkillFrame_Update()
  end)
  self.refreshing = false
end

function V:Open(prof, selectSpell)
  local sp = RS:Static(prof)
  if not sp then return false end
  if not self.active then
    if TradeSkillFrame and TradeSkillFrame:IsVisible() then HideUIPanel(TradeSkillFrame) end
    if CraftFrame and CraftFrame:IsVisible() then HideUIPanel(CraftFrame) end
  end
  TradeSkillFrame_LoadUI()
  if not TradeSkillFrame then
    RS:Print("Couldn't load the trade skill window.")
    return false
  end
  self:HookFrame()

  local same = self.active and self.prof == prof
  self.active = true
  self.prof, self.sp = prof, sp
  if not same then
    self.filter = 0
    self.search = ""
    self.sel = nil
  end
  self:BuildHeaders()
  if self.filter > getn(self.headers) then self.filter = 0 end
  if selectSpell and sp.bySpell[selectSpell] then self.sel = { r = sp.bySpell[selectSpell] } end
  self.selIdx = nil
  self:CountBags()
  self:Rebuild()

  self.opening = true
  local ok = RS:Safe(TradeSkillFrame_Show)
  self.opening = false
  if not ok then self.active = false; return false end

  if self.searchBox then self.searchBox:SetText(self.search or "") end
  local idx = F.GetTradeSkillSelectionIndex()
  if idx > TRADE_SKILLS_DISPLAYED then
    FauxScrollFrame_SetOffset(TradeSkillListScrollFrame, idx - 1)
    TradeSkillListScrollFrameScrollBar:SetValue((idx - 1) * TRADE_SKILL_HEIGHT)
    TradeSkillFrame_Update()
  end
  RS:Safe(V.Decorate, V)
  return true
end

function V:Deactivate()
  self.active = false
  self.prof, self.sp, self.sel, self.crafters = nil, nil, nil, nil
  self.display = {}
  self.search = ""
  if self.searchBox then self.searchBox:SetText(""); self.searchBox:ClearFocus() end
  RS:Safe(V.Decorate, V)
  if self.origChildHeight then TradeSkillDetailScrollChildFrame:SetHeight(self.origChildHeight) end
  if TradeSkillReagentLabel then TradeSkillReagentLabel:Show() end
  RS:Safe(V.RestoreForeignSearch, V)
  for i = 1, getn(CRAFT_CONTROLS) do
    local w = getglobal(CRAFT_CONTROLS[i])
    if w then w:Show() end
  end
end

function V:Close()
  if self.active and TradeSkillFrame then HideUIPanel(TradeSkillFrame) end
end

function V:OnDataChanged()
  if not self.active then return end
  self:BuildHeaders()
  self:Refresh()
end

function V:OnDataReceived(owner, prof)
  if self.active and self.prof == prof then
    RS:After("viewdata", 0.5, function() V:OnDataChanged() end)
  end
end

-- keep reagent counts current while viewing
local bagFrame = CreateFrame("Frame")
bagFrame:RegisterEvent("BAG_UPDATE")
bagFrame:SetScript("OnEvent", function()
  if V.active then
    RS:After("viewbags", 0.5, function()
      if V.active then V:CountBags(); V:Refresh() end
    end)
  end
end)
