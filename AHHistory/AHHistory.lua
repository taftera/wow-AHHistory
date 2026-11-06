-- AH History: records auction house prices per day and rates the current price.
--
-- Data layout (SavedVariables AHHistoryDB):
--   AHHistoryDB.realms["Realm-Faction"] = {
--     lastScan = <time>,
--     items = { [itemID] = { cur = <copper>, seen = <time>, days = { [dayNumber] = { low, median, quantity } } } },
--   }
-- All prices are per unit, in copper, buyout only.

local ADDON = ...

local DAYS_KEPT = 180      -- history older than this is pruned on login
local VERDICT_DAYS = 30    -- window used to judge "good price"
local MIN_DAYS_FOR_VERDICT = 3
local CHUNK = 500          -- auctions processed per frame, keeps the game from freezing

local db, realmDB
local scanning = false
local f = CreateFrame("Frame")

local function Print(msg)
  print("|cff33ccffAH History:|r " .. msg)
end

local function DayNumber(t)
  return math.floor((t or time()) / 86400)
end

-- Own formatter: GetCoinTextureString is not a global on every client.
local function Money(copper)
  copper = math.floor((tonumber(copper) or 0) + 0.5)
  local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
  if g > 0 then
    return string.format("|cffffd700%dg|r |cffc7c7cf%ds|r |cffeda55f%dc|r", g, s, c)
  elseif s > 0 then
    return string.format("|cffc7c7cf%ds|r |cffeda55f%dc|r", s, c)
  end
  return string.format("|cffeda55f%dc|r", c)
end

local function Median(sorted)
  local n = #sorted
  if n == 0 then return nil end
  if n % 2 == 1 then return sorted[(n + 1) / 2] end
  return (sorted[n / 2] + sorted[n / 2 + 1]) / 2
end

---------------------------------------------------------------------------
-- Saved data
---------------------------------------------------------------------------

local function InitDB()
  AHHistoryDB = AHHistoryDB or {}
  db = AHHistoryDB
  db.realms = db.realms or {}
  if db.autoScan == nil then db.autoScan = false end

  local key = GetRealmName() .. "-" .. (UnitFactionGroup("player") or "Neutral")
  db.realms[key] = db.realms[key] or { items = {} }
  realmDB = db.realms[key]

  local cutoff = DayNumber() - DAYS_KEPT
  for itemID, item in pairs(realmDB.items) do
    for d in pairs(item.days) do
      if d < cutoff then item.days[d] = nil end
    end
    if next(item.days) == nil then realmDB.items[itemID] = nil end
  end
end

-- Returns a table of summary numbers for an item, or nil if never seen.
local function GetStats(itemID)
  local item = realmDB and realmDB.items[itemID]
  if not item then return nil end

  local today = DayNumber()
  local lows30, lows7 = {}, {}
  local allTimeLow, days = nil, 0
  for d, rec in pairs(item.days) do
    days = days + 1
    if not allTimeLow or rec[1] < allTimeLow then allTimeLow = rec[1] end
    if d > today - VERDICT_DAYS then lows30[#lows30 + 1] = rec[1] end
    if d > today - 7 then lows7[#lows7 + 1] = rec[1] end
  end
  table.sort(lows30)
  table.sort(lows7)

  return {
    cur = item.cur,
    listedNow = realmDB.lastScan and item.seen >= realmDB.lastScan,
    seen = item.seen,
    median7 = Median(lows7),
    median30 = Median(lows30),
    days30 = #lows30,
    allTimeLow = allTimeLow,
    days = days,
  }
end

-- Compares the latest lowest price against the 30-day median of daily lows.
local function Verdict(s)
  if not s.listedNow or s.days30 < MIN_DAYS_FOR_VERDICT then return nil end
  local diff = (s.cur - s.median30) / s.median30
  local pct = string.format("%+d%%", math.floor(diff * 100 + 0.5))
  if s.cur <= s.allTimeLow then return "|cff00ff00All-time low! (" .. pct .. ")|r" end
  if diff <= -0.15 then return "|cff00ff00Great price (" .. pct .. ")|r" end
  if diff <= -0.05 then return "|cff80ff80Good price (" .. pct .. ")|r" end
  if diff < 0.10 then return "|cffffff00Normal price (" .. pct .. ")|r" end
  return "|cffff4040Expensive (" .. pct .. ")|r"
end

---------------------------------------------------------------------------
-- Scan button state and progress bar
---------------------------------------------------------------------------

local button, bar
local barToken = 0   -- bumped on every update so a pending auto-hide is cancelled

local function ShowProgress(done, total, text)
  if not bar then return end
  barToken = barToken + 1
  bar:SetMinMaxValues(0, math.max(total, 1))
  bar:SetValue(done)
  bar.text:SetText(text)
  bar:Show()
end

-- Shows a final message on a full bar, then hides it after a few seconds.
local function FinishProgress(text)
  ShowProgress(1, 1, text)
  local token = barToken
  C_Timer.After(5, function()
    if bar and token == barToken then bar:Hide() end
  end)
end

local function SetScanning(state)
  scanning = state
  if button then
    if state then button:Disable() else button:Enable() end
  end
end

---------------------------------------------------------------------------
-- Scanning
---------------------------------------------------------------------------

-- Both the legacy and the newer AH API return auction info in the same order:
-- name, texture, count, quality, canUse, level, levelType, minBid, minIncrement,
-- buyout, bidAmount, highBidder, bidder, owner, ownerFull, saleStatus, itemID
local function ProcessScan(total, getInfo)
  local prices, qty = {}, {}
  local i = 1

  local function Finish()
    local now, today = time(), DayNumber()
    local count = 0
    for itemID, list in pairs(prices) do
      table.sort(list)
      local low, med = list[1], Median(list)
      local item = realmDB.items[itemID]
      if not item then
        item = { days = {} }
        realmDB.items[itemID] = item
      end
      item.cur, item.seen = low, now
      local rec = item.days[today]
      if rec then
        rec[1] = math.min(rec[1], low)
        rec[2], rec[3] = med, qty[itemID]
      else
        item.days[today] = { low, med, qty[itemID] }
      end
      count = count + 1
    end
    realmDB.lastScan = now
    SetScanning(false)
    FinishProgress(string.format("Done: %d items recorded", count))
    Print(string.format("Scan complete: %d auctions, %d different items recorded.", total, count))
  end

  local function Step()
    local last = math.min(i + CHUNK - 1, total)
    for idx = i, last do
      local _, _, count, _, _, _, _, _, _, buyout, _, _, _, _, _, _, itemID = getInfo(idx)
      if itemID and buyout and buyout > 0 and count and count > 0 then
        local list = prices[itemID]
        if not list then
          list = {}
          prices[itemID] = list
          qty[itemID] = 0
        end
        list[#list + 1] = buyout / count
        qty[itemID] = qty[itemID] + count
      end
    end
    i = last + 1
    ShowProgress(last, total, string.format("Processing %d / %d", last, total))
    if i <= total then
      C_Timer.After(0, Step)
    else
      Finish()
    end
  end

  Print(string.format("Processing %d auctions...", total))
  Step()
end

local function StartScan()
  if scanning then
    Print("A scan is already running.")
    return
  end
  if not (AuctionFrame and AuctionFrame:IsShown()) and not (AuctionHouseFrame and AuctionHouseFrame:IsShown()) then
    Print("Open the auction house first.")
    return
  end

  if QueryAuctionItems then
    local _, canQueryAll = CanSendAuctionQuery()
    if not canQueryAll then
      Print("Full scan is on cooldown (the server allows one roughly every 15 minutes).")
      return
    end
    SetScanning(true)
    f:RegisterEvent("AUCTION_ITEM_LIST_UPDATE")
    QueryAuctionItems("", nil, nil, 0, false, 0, true)
  elseif C_AuctionHouse and C_AuctionHouse.ReplicateItems then
    SetScanning(true)
    f:RegisterEvent("REPLICATE_ITEM_LIST_UPDATE")
    C_AuctionHouse.ReplicateItems()
  else
    Print("No supported auction house scan API found on this client.")
    return
  end

  ShowProgress(0, 1, "Waiting for server...")
  Print("Scanning the whole auction house, this can take a few seconds...")
  -- Safety net in case the server never answers.
  C_Timer.After(90, function()
    if scanning then
      SetScanning(false)
      f:UnregisterEvent("AUCTION_ITEM_LIST_UPDATE")
      f:UnregisterEvent("REPLICATE_ITEM_LIST_UPDATE")
      FinishProgress("Scan timed out")
      Print("Scan timed out. Try again later.")
    end
  end)
end

---------------------------------------------------------------------------
-- Tooltip
---------------------------------------------------------------------------

local function AddTooltipLines(tt, itemID)
  if not itemID then return end
  local s = GetStats(itemID)
  tt:AddLine(" ")
  tt:AddLine("|cff33ccffAH History|r")
  if not s then
    tt:AddLine("No auction data yet", 0.6, 0.6, 0.6)
    return
  end

  if s.listedNow then
    tt:AddDoubleLine("Lowest now", Money(s.cur), 1, 1, 1, 1, 1, 1)
  else
    tt:AddDoubleLine("Lowest now", "not listed in last scan", 1, 1, 1, 0.6, 0.6, 0.6)
  end
  if s.median7 then tt:AddDoubleLine("7-day typical low", Money(s.median7), 1, 1, 1, 1, 1, 1) end
  if s.median30 then tt:AddDoubleLine("30-day typical low", Money(s.median30), 1, 1, 1, 1, 1, 1) end
  tt:AddDoubleLine("All-time low", Money(s.allTimeLow), 1, 1, 1, 1, 1, 1)

  local verdict = Verdict(s)
  if verdict then
    tt:AddLine(verdict)
  elseif s.days30 < MIN_DAYS_FOR_VERDICT then
    tt:AddLine(string.format("Building history (%d/%d days)", s.days30, MIN_DAYS_FOR_VERDICT), 0.6, 0.6, 0.6)
  end
end

-- Shows any error inside the tooltip instead of silently cutting it short.
local function SafeAddTooltipLines(tt, itemID)
  local ok, err = pcall(AddTooltipLines, tt, itemID)
  if not ok then tt:AddLine("AH History error: " .. tostring(err), 1, 0.2, 0.2, true) end
end

local function HookTooltips()
  if TooltipDataProcessor and Enum and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tt, data)
      if tt == GameTooltip or tt == ItemRefTooltip then
        SafeAddTooltipLines(tt, data and data.id)
      end
    end)
  else
    local function OnSetItem(tt)
      local _, link = tt:GetItem()
      if link then SafeAddTooltipLines(tt, tonumber(link:match("item:(%d+)"))) end
    end
    GameTooltip:HookScript("OnTooltipSetItem", OnSetItem)
    ItemRefTooltip:HookScript("OnTooltipSetItem", OnSetItem)
  end
end

---------------------------------------------------------------------------
-- Auction house button
---------------------------------------------------------------------------

-- Scan button in the bottom-right corner of the auction house window,
-- with the progress bar just to its left.
local function EnsureButton()
  if button then return end
  local parent = AuctionFrame or AuctionHouseFrame
  if not parent then return end

  button = CreateFrame("Button", "AHHistoryScanButton", parent, "UIPanelButtonTemplate")
  button:SetSize(110, 22)
  button:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -8, 4)
  button:SetText("Scan prices")
  button:SetScript("OnClick", StartScan)
  if scanning then button:Disable() end

  bar = CreateFrame("StatusBar", "AHHistoryProgressBar", parent)
  bar:SetSize(220, 18)
  bar:SetPoint("RIGHT", button, "LEFT", -8, 0)
  bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
  bar:SetStatusBarColor(0.2, 0.7, 1)
  bar.bg = bar:CreateTexture(nil, "BACKGROUND")
  bar.bg:SetAllPoints()
  bar.bg:SetColorTexture(0, 0, 0, 0.6)
  bar.text = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  bar.text:SetPoint("CENTER")
  bar:Hide()
end

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------

local function PrintItemHistory(link)
  local itemID = tonumber(link:match("item:(%d+)"))
  local item = itemID and realmDB.items[itemID]
  if not item then
    Print("No data for " .. link)
    return
  end
  local days = {}
  for d in pairs(item.days) do days[#days + 1] = d end
  table.sort(days, function(a, b) return a > b end)
  Print("History for " .. link .. " (most recent first):")
  for n = 1, math.min(14, #days) do
    local rec = item.days[days[n]]
    local ok, line = pcall(string.format, "  %s  low %s  median %s  qty %s",
      date("%Y-%m-%d", days[n] * 86400), Money(rec[1]), Money(rec[2]), tostring(rec[3] or 0))
    print(ok and line or ("  error: " .. tostring(line)))
  end
end

SLASH_AHHISTORY1 = "/ahh"
SlashCmdList.AHHISTORY = function(msg)
  msg = strtrim(msg or "")
  local cmd = msg:lower()
  if cmd == "scan" then
    StartScan()
  elseif cmd == "auto" then
    db.autoScan = not db.autoScan
    Print("Auto-scan when opening the auction house: " .. (db.autoScan and "ON" or "OFF"))
  elseif cmd == "stats" then
    local n = 0
    for _ in pairs(realmDB.items) do n = n + 1 end
    local last = realmDB.lastScan and date("%Y-%m-%d %H:%M", realmDB.lastScan) or "never"
    Print(string.format("%d items tracked on this realm/faction. Last scan: %s.", n, last))
  elseif msg:find("item:%d+") then
    PrintItemHistory(msg)
  else
    Print("Commands:")
    print("  /ahh scan - full scan (auction house must be open)")
    print("  /ahh auto - toggle automatic scan when you open the auction house")
    print("  /ahh stats - how much data you have")
    print("  /ahh [item link] - print the last 14 days for an item")
  end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("AUCTION_HOUSE_SHOW")
f:SetScript("OnEvent", function(self, event, arg1)
  if event == "ADDON_LOADED" and arg1 == ADDON then
    InitDB()
    HookTooltips()
    self:UnregisterEvent("ADDON_LOADED")
  elseif event == "AUCTION_HOUSE_SHOW" then
    EnsureButton()
    if db.autoScan then C_Timer.After(1, StartScan) end
  elseif event == "AUCTION_ITEM_LIST_UPDATE" then
    self:UnregisterEvent(event)
    -- Give the client a moment to finish receiving the full list.
    C_Timer.After(1, function()
      local count = GetNumAuctionItems("list")
      ProcessScan(count, function(i) return GetAuctionItemInfo("list", i) end)
    end)
  elseif event == "REPLICATE_ITEM_LIST_UPDATE" then
    self:UnregisterEvent(event)
    C_Timer.After(1, function()
      local count = C_AuctionHouse.GetNumReplicateItems()
      -- Replicate indices are 0-based.
      ProcessScan(count, function(i) return C_AuctionHouse.GetReplicateItemInfo(i - 1) end)
    end)
  end
end)
