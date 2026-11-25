--[[
  RecipeSync - minimap button (enchanting icon).
  Left-click: open/close the guild professions window. Right-click: open the export.
  Drag to move it around the minimap. /recipes minimap hides or shows it.
]]

local RS = RecipeSync
local MB = {}
RS.MinimapButton = MB

local RADIUS = 80

function MB:Position()
  local a = math.rad(RS.db.settings.minimapAngle or 215)
  self.button:ClearAllPoints()
  self.button:SetPoint("CENTER", Minimap, "CENTER", RADIUS * math.cos(a), RADIUS * math.sin(a))
end

function MB:Create()
  if self.button or not Minimap then return end
  local b = CreateFrame("Button", "RecipeSyncMinimapButton", Minimap)
  b:SetWidth(31); b:SetHeight(31)
  b:SetFrameStrata("MEDIUM")
  b:SetFrameLevel(8)
  if b.SetToplevel then b:SetToplevel(true) end
  b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

  local bg = b:CreateTexture(nil, "BACKGROUND")
  bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
  bg:SetWidth(20); bg:SetHeight(20)
  bg:SetPoint("TOPLEFT", b, "TOPLEFT", 7, -5)

  local icon = b:CreateTexture(nil, "ARTWORK")
  icon:SetTexture("Interface\\Icons\\Trade_Engraving") -- the Enchanting icon
  icon:SetWidth(20); icon:SetHeight(20)
  icon:SetPoint("TOPLEFT", b, "TOPLEFT", 7, -5)
  icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
  b.icon = icon

  local border = b:CreateTexture(nil, "OVERLAY")
  border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  border:SetWidth(53); border:SetHeight(53)
  border:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0)

  b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  b:RegisterForDrag("LeftButton")
  b:SetScript("OnClick", function()
    if arg1 == "RightButton" then
      RS.Export:Show()
    else
      RS.Main:Toggle()
    end
  end)
  b:SetScript("OnDragStart", function()
    this:LockHighlight()
    this:SetScript("OnUpdate", function() MB:Drag() end)
  end)
  b:SetScript("OnDragStop", function()
    this:UnlockHighlight()
    this:SetScript("OnUpdate", nil)
  end)
  b:SetScript("OnEnter", function()
    GameTooltip:SetOwner(this, "ANCHOR_LEFT")
    GameTooltip:SetText("RecipeSync", 1, 1, 1)
    GameTooltip:AddLine("Left-click: guild professions", 0.8, 0.8, 0.8)
    GameTooltip:AddLine("Right-click: export to Google Sheets", 0.8, 0.8, 0.8)
    GameTooltip:AddLine("Drag: move this button", 0.8, 0.8, 0.8)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  self.button = b
  self:Position()
end

function MB:Drag()
  local mx, my = Minimap:GetCenter()
  local px, py = GetCursorPosition()
  local scale = Minimap:GetEffectiveScale()
  if not mx or not scale or scale == 0 then return end
  px, py = px / scale, py / scale
  RS.db.settings.minimapAngle = math.deg(math.atan2(py - my, px - mx))
  self:Position()
end

function MB:Update()
  if not RS.db then return end
  if RS.db.settings.minimap then
    self:Create()
    if self.button then self.button:Show() end
  elseif self.button then
    self.button:Hide()
  end
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:SetScript("OnEvent", function()
  this:UnregisterEvent("PLAYER_ENTERING_WORLD")
  RS:Safe(MB.Update, MB)
end)
