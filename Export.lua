--[[
  RecipeSync - export to Google Sheets.
  The 1.12 client can't write files or reach the internet, so the export is a read-only text box:
  Select All -> Ctrl+C -> click cell A1 in Google Sheets -> Ctrl+V. Tab-separated text pastes
  straight into columns. Big guilds get several pages (the game's text boxes have a size limit).
]]

local RS = RecipeSync
local X = {}
RS.Export = X

local getn, tinsert, tconcat = table.getn, table.insert, table.concat
local gsub, strlen, strfind = string.gsub, string.len, string.find

local PAGE_CHARS = 12000
local COLUMNS = { "Profession", "Category", "Recipe", "Crafters", "Unconfirmed (added by hand)", "Reagents" }

local function Cell(v, tabs)
  v = gsub(tostring(v or ""), "[\t\r\n]", " ")
  if tabs then return v end
  if strfind(v, "[,\"]") then v = "\"" .. gsub(v, "\"", "\"\"") .. "\"" end
  return v
end

local function Line(cells, tabs)
  local out = {}
  for i = 1, getn(cells) do out[i] = Cell(cells[i], tabs) end
  return tconcat(out, tabs and "\t" or ",")
end

local function Names(list, confirmed)
  local t = {}
  for i = 1, getn(list) do
    if (list[i].ok and confirmed) or (not list[i].ok and not confirmed) then tinsert(t, list[i].name) end
  end
  table.sort(t)
  return tconcat(t, ", ")
end

-- returns a list of pages (strings) and the number of recipe rows
function X:Build(tabs)
  local lines = {}
  local profs = RS:ProfList()
  for p = 1, getn(profs) do
    local prof = profs[p].name
    local sp = RS:Static(prof)
    local c = RS:Crafters(prof)
    for i = 1, getn(sp.recipes) do
      local rec = sp.recipes[i]
      local list = c.bySpell[rec.spell]
      if list and getn(list) > 0 then
        local reag = {}
        for k = 1, getn(rec.reagents) do
          local x = rec.reagents[k]
          tinsert(reag, x.count .. " x " .. RS:ItemInfo(x.id))
        end
        tinsert(lines, Line({ prof, rec.header and rec.header.name or "", rec.name,
          Names(list, true), Names(list, false), tconcat(reag, ", ") }, tabs))
      end
    end
    local extras = {}
    for name in pairs(c.extras) do tinsert(extras, name) end
    table.sort(extras)
    for i = 1, getn(extras) do
      local list = c.extras[extras[i]]
      tinsert(lines, Line({ prof, "Not in database", extras[i], Names(list, true), "", "" }, tabs))
    end
  end

  local pages, cur, size = {}, { Line(COLUMNS, tabs) }, 0
  for i = 1, getn(lines) do
    if size + strlen(lines[i]) > PAGE_CHARS and getn(cur) > 0 then
      tinsert(pages, tconcat(cur, "\n"))
      cur, size = {}, 0
    end
    tinsert(cur, lines[i])
    size = size + strlen(lines[i]) + 1
  end
  if getn(cur) > 0 then tinsert(pages, tconcat(cur, "\n")) end
  return pages, getn(lines)
end

function X:Create()
  if self.frame then return end
  local f = RS.Dialog("RecipeSyncExportFrame", 540, 440, "Export to Google Sheets")
  f:SetFrameStrata("FULLSCREEN_DIALOG")
  self.frame = f

  local help = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  help:SetPoint("TOPLEFT", f, "TOPLEFT", 22, -32)
  help:SetWidth(496)
  help:SetJustifyH("LEFT")
  help:SetText("1. Click |cffffd100Select All|r, then press |cffffd100Ctrl+C|r.\n"
    .. "2. In a new Google Sheet, click cell |cffffd100A1|r and press |cffffd100Ctrl+V|r.\n"
    .. "3. More pages? Paste each one into the first empty row below the last.\n"
    .. "Tip: in Sheets use View > Freeze > 1 row, and Data > Create a filter.")
  self.help = help

  local sf = CreateFrame("ScrollFrame", "RecipeSyncExportScroll", f, "UIPanelScrollFrameTemplate")
  sf:SetPoint("TOPLEFT", f, "TOPLEFT", 22, -94)
  sf:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -42, 56)
  local bg = f:CreateTexture(nil, "BACKGROUND")
  bg:SetTexture(0, 0, 0, 0.5)
  bg:SetPoint("TOPLEFT", sf, "TOPLEFT", -4, 4)
  bg:SetPoint("BOTTOMRIGHT", sf, "BOTTOMRIGHT", 4, -4)

  local eb = CreateFrame("EditBox", "RecipeSyncExportEdit", sf)
  eb:SetMultiLine(true)
  eb:SetAutoFocus(false)
  eb:SetMaxLetters(0)
  eb:SetFontObject(GameFontHighlightSmall)
  eb:SetWidth(470)
  eb:SetHeight(300)
  eb:SetScript("OnEscapePressed", function() this:ClearFocus() end)
  eb:SetScript("OnTextChanged", function()
    -- read only: put the export text back if someone types into it
    if this.locked and this:GetText() ~= this.locked then this:SetText(this.locked) end
    RecipeSyncExportScroll:UpdateScrollChildRect()
  end)
  sf:SetScrollChild(eb)
  self.edit = eb

  local sel = CreateFrame("Button", "RecipeSyncExportSelect", f, "UIPanelButtonTemplate")
  sel:SetWidth(100); sel:SetHeight(22)
  sel:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 18, 20)
  sel:SetText("Select All")
  sel:SetScript("OnClick", function()
    X.edit:SetFocus()
    X.edit:HighlightText()
  end)

  local prev = CreateFrame("Button", "RecipeSyncExportPrev", f, "UIPanelButtonTemplate")
  prev:SetWidth(60); prev:SetHeight(22)
  prev:SetPoint("LEFT", sel, "RIGHT", 8, 0)
  prev:SetText("< Prev")
  prev:SetScript("OnClick", function() X:ShowPage(X.page - 1) end)
  self.prev = prev

  local pageText = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  pageText:SetPoint("LEFT", prev, "RIGHT", 6, 0)
  pageText:SetWidth(70)
  self.pageText = pageText

  local nxt = CreateFrame("Button", "RecipeSyncExportNext", f, "UIPanelButtonTemplate")
  nxt:SetWidth(60); nxt:SetHeight(22)
  nxt:SetPoint("LEFT", pageText, "RIGHT", 6, 0)
  nxt:SetText("Next >")
  nxt:SetScript("OnClick", function() X:ShowPage(X.page + 1) end)
  self.next = nxt

  local fmt = CreateFrame("Button", "RecipeSyncExportFormat", f, "UIPanelButtonTemplate")
  fmt:SetWidth(110); fmt:SetHeight(22)
  fmt:SetPoint("LEFT", nxt, "RIGHT", 8, 0)
  fmt:SetScript("OnClick", function()
    RS.db.settings.exportTabs = not RS.db.settings.exportTabs
    X:Rebuild()
  end)
  fmt:SetScript("OnEnter", function()
    GameTooltip:SetOwner(this, "ANCHOR_TOP")
    GameTooltip:SetText("Format", 1, 1, 1)
    GameTooltip:AddLine("Tabs: paste straight into Google Sheets.\nCommas (CSV): if your paste lands in one column, use Data > Split text to columns.", nil, nil, nil, 1)
    GameTooltip:Show()
  end)
  fmt:SetScript("OnLeave", function() GameTooltip:Hide() end)
  self.fmt = fmt

  local close = CreateFrame("Button", "RecipeSyncExportCloseBtn", f, "UIPanelButtonTemplate")
  close:SetWidth(70); close:SetHeight(22)
  close:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -18, 20)
  close:SetText(CLOSE or "Close")
  close:SetScript("OnClick", function() RecipeSyncExportFrame:Hide() end)
end

function X:Rebuild()
  local tabs = RS.db.settings.exportTabs
  self.pages, self.rows = self:Build(tabs)
  self.fmt:SetText(tabs and "Format: Tabs" or "Format: Commas")
  self:ShowPage(1)
end

function X:ShowPage(n)
  local total = getn(self.pages)
  if n < 1 then n = 1 end
  if n > total then n = total end
  self.page = n
  local text = self.pages[n] or ""
  if self.rows == 0 then
    text = "Nothing to export yet - nobody's recipes have been synced."
  end
  self.edit.locked = nil
  self.edit:SetText(text)
  self.edit.locked = text
  if self.edit.SetCursorPosition then self.edit:SetCursorPosition(0) end
  RecipeSyncExportScroll:SetVerticalScroll(0)
  self.pageText:SetText("Page " .. n .. "/" .. total)
  if n > 1 then self.prev:Enable() else self.prev:Disable() end
  if n < total then self.next:Enable() else self.next:Disable() end
end

function X:Show()
  self:Create()
  self.frame:Show()
  self:Rebuild()
end
