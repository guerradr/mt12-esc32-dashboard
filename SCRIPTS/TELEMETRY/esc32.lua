-- Repository: https://github.com/guerradr/mt12-esc32-dashboard
-- Author:     guerradr (with AI code assistance)
-- License:    MIT
-- ============================================================================
-- ESCape32 Car-Style Automotive Telemetry Dashboard for RadioMaster MT12
-- Firmware: EdgeTX v2.11.3 (128x64 Monochrome LCD)
-- Link:     FrSky D16v2 (S.Port / F.Port) -> ESCape32 ESC Telemetry
-- File:     /SCRIPTS/TELEMETRY/esc32.lua
-- ============================================================================

local CFG_FILE = "/SCRIPTS/TELEMETRY/esc32.cfg"

-- Gauge definitions & default ESCape32 FrSky D16v2 sensor mappings
local gauges = {
  {
    key   = "RPM",
    label = "RPM",
    unit  = "",
    src   = "RPM",
    min   = 0,
    max   = 30000,
    step  = 500,
    prec  = 0,     -- integer display
    val   = 0
  },
  {
    key   = "CURR",
    label = "AMP",
    unit  = "A",
    src   = "Curr",
    min   = 0,
    max   = 80,
    step  = 5,
    prec  = 1,     -- 1 decimal place (e.g. 42.5)
    val   = 0
  },
  {
    key   = "VOLT",
    label = "VOLT",
    unit  = "V",
    src   = "VFAS",
    min   = 9.6,   -- 3S LiPo low threshold (3.2V/cell)
    max   = 12.6,  -- 3S LiPo full charge (4.2V/cell)
    step  = 0.2,
    prec  = 1,     -- 1 decimal place (e.g. 11.8)
    val   = 0
  },
  {
    key   = "TEMP",
    label = "TEMP",
    unit  = "C",
    src   = "Tmp1",
    min   = 20,
    max   = 95,
    step  = 5,
    prec  = 0,     -- integer degrees (e.g. 64)
    val   = 0
  }
}

-- UI & Setup State
local mode = "DASH"       -- "DASH" or "SETUP"
local dashFocus = false   -- false = normal view, true = [SET] badge highlighted
local setupRow = 1        -- 1..14 rows in setup list
local setupEdit = false   -- true when editing selected row value
local setupScroll = 0     -- top visible row index (1-based)
local demoMode = false    -- built-in ESCape32 telemetry simulator toggle
local demoTick = 0
local sensorList = {}     -- discovered telemetry sensors on radio
local sensorIds = {}      -- cached EdgeTX field IDs per gauge

local function degToRad(deg)
  return deg * 0.017453292519943295
end

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function roundVal(v, prec)
  if prec == 1 then
    return math.floor(v * 10 + 0.5) / 10
  end
  return math.floor(v + 0.5)
end

-- ============================================================================
-- Sensor Discovery & Persistence
-- ============================================================================

local function refreshSensors()
  sensorList = { "None" }
  local seen = { ["None"] = true }

  local preferred = { "RPM", "Curr", "VFAS", "Tmp1", "Tmp2", "Temp", "RxBt", "A2", "EscT", "BECV" }
  for i = 1, #preferred do
    local name = preferred[i]
    local info = getFieldInfo(name)
    if info and not seen[name] then
      sensorList[#sensorList + 1] = name
      seen[name] = true
    end
  end

  for id = 0, 63 do
    local info = getFieldInfo(id)
    if info and info.name and info.name ~= "" then
      if not seen[info.name] and (id >= 150 or (info.unit and info.unit > 0)) then
        sensorList[#sensorList + 1] = info.name
        seen[info.name] = true
      end
    end
  end

  for g = 1, 4 do
    local s = gauges[g].src
    if s and s ~= "" and not seen[s] then
      sensorList[#sensorList + 1] = s
      seen[s] = true
    end
  end
end

local function resolveSensorIds()
  for g = 1, 4 do
    local src = gauges[g].src
    if src and src ~= "None" and src ~= "" then
      local info = getFieldInfo(src)
      sensorIds[g] = info and info.id or nil
    else
      sensorIds[g] = nil
    end
  end
end

local function saveConfig()
  local f = io.open(CFG_FILE, "w")
  if not f then return end
  for g = 1, 4 do
    local item = gauges[g]
    io.write(f, item.key .. "=" .. tostring(item.src) .. "," .. tostring(item.min) .. "," .. tostring(item.max) .. "\n")
  end
  io.close(f)
end

local function loadConfig()
  local f = io.open(CFG_FILE, "r")
  if not f then return end
  local data = io.read(f, 512)
  io.close(f)
  if not data then return end

  for line in string.gmatch(data, "[^\r\n]+") do
    local k, src, mn, mx = string.match(line, "^(%u+)=([^,]+),([%-%d%.]+),([%-%d%.]+)$")
    if k and src and mn and mx then
      for g = 1, 4 do
        if gauges[g].key == k then
          gauges[g].src = src
          gauges[g].min = tonumber(mn) or gauges[g].min
          gauges[g].max = tonumber(mx) or gauges[g].max
        end
      end
    end
  end
end

local function resetDefaults()
  gauges[1].src, gauges[1].min, gauges[1].max = "RPM",  0,   30000
  gauges[2].src, gauges[2].min, gauges[2].max = "Curr", 0,   80
  gauges[3].src, gauges[3].min, gauges[3].max = "VFAS", 9.6, 12.6
  gauges[4].src, gauges[4].min, gauges[4].max = "Tmp1", 20,  95
  resolveSensorIds()
end

-- ============================================================================
-- Telemetry Sampling
-- ============================================================================

local function updateTelemetry()
  if demoMode then
    demoTick = (demoTick + 1) % 360
    local phase = degToRad(demoTick * 3)
    local wave = 0.5 + 0.5 * math.sin(phase)
    gauges[1].val = math.floor(2400 + wave * 24100)
    gauges[2].val = roundVal(3.2 + wave * 61.8, 1)
    gauges[3].val = roundVal(12.4 - wave * 1.6, 1)
    gauges[4].val = math.floor(34 + wave * 48)
    return
  end

  for g = 1, 4 do
    local id = sensorIds[g]
    if id then
      local raw = getValue(id)
      if type(raw) == "number" then
        gauges[g].val = roundVal(raw, gauges[g].prec)
      end
    else
      local src = gauges[g].src
      if src and src ~= "None" then
        local info = getFieldInfo(src)
        if info then
          sensorIds[g] = info.id
          local raw = getValue(info.id)
          if type(raw) == "number" then
            gauges[g].val = roundVal(raw, gauges[g].prec)
          end
        end
      end
    end
  end
end

-- ============================================================================
-- Custom Automotive HMI Drawing Primitives (128x64 Monochrome)
-- ============================================================================

local function drawArc(cx, cy, r, startDeg, endDeg, stepDeg)
  local prevX, prevY = nil, nil
  for deg = startDeg, endDeg, stepDeg do
    local rad = degToRad(deg)
    local x = math.floor(cx + r * math.cos(rad) + 0.5)
    local y = math.floor(cy + r * math.sin(rad) + 0.5)
    if prevX then
      lcd.drawLine(prevX, prevY, x, y, SOLID, FORCE)
    else
      lcd.drawPoint(x, y)
    end
    prevX, prevY = x, y
  end
  local endRad = degToRad(endDeg)
  local ex = math.floor(cx + r * math.cos(endRad) + 0.5)
  local ey = math.floor(cy + r * math.sin(endRad) + 0.5)
  if prevX then
    lcd.drawLine(prevX, prevY, ex, ey, SOLID, FORCE)
  end
end

local function formatDialValue(g)
  local v = g.val
  if g.key == "RPM" then
    if v >= 10000 then
      local k = math.floor(v / 100 + 0.5) / 10
      return string.format("%.1fk", k)
    else
      return string.format("%d", math.floor(v + 0.5))
    end
  else
    if g.prec == 1 then
      return string.format("%.1f", v)
    else
      return string.format("%d", math.floor(v + 0.5))
    end
  end
end

local function drawCircularGauge(cx, cy, r, g, warnHigh)
  local startDeg = 150
  local sweepDeg = 240
  local endDeg   = startDeg + sweepDeg

  local span = g.max - g.min
  local ratio = 0
  if span > 0 then
    ratio = clamp((g.val - g.min) / span, 0, 1)
  end

  drawArc(cx, cy, r, startDeg, endDeg, 10)

  if ratio > 0.01 then
    local activeEnd = startDeg + math.floor(ratio * sweepDeg + 0.5)
    drawArc(cx, cy, r - 1, startDeg, activeEnd, 10)
  end

  local numTicks = 8
  for i = 0, numTicks do
    local tDeg = startDeg + (i * sweepDeg) / numTicks
    local rad = degToRad(tDeg)
    local cosA = math.cos(rad)
    local sinA = math.sin(rad)
    local tickLen = (i >= numTicks - 1) and 4 or 3
    local x1 = math.floor(cx + (r - 1) * cosA + 0.5)
    local y1 = math.floor(cy + (r - 1) * sinA + 0.5)
    local x2 = math.floor(cx + (r - 1 - tickLen) * cosA + 0.5)
    local y2 = math.floor(cy + (r - 1 - tickLen) * sinA + 0.5)
    lcd.drawLine(x1, y1, x2, y2, SOLID, FORCE)
  end

  local needleDeg = startDeg + ratio * sweepDeg
  local nRad = degToRad(needleDeg)
  local nCos = math.cos(nRad)
  local nSin = math.sin(nRad)
  local nx1 = math.floor(cx + 9 * nCos + 0.5)
  local ny1 = math.floor(cy + 9 * nSin + 0.5)
  local nx2 = math.floor(cx + (r - 4) * nCos + 0.5)
  local ny2 = math.floor(cy + (r - 4) * nSin + 0.5)
  lcd.drawLine(nx1, ny1, nx2, ny2, SOLID, FORCE)
  local px = math.floor(-nSin + 0.5)
  local py = math.floor(nCos + 0.5)
  lcd.drawLine(nx1 + px, ny1 + py, math.floor(cx + (r - 8) * nCos + 0.5), math.floor(cy + (r - 8) * nSin + 0.5), SOLID, FORCE)

  local txt = formatDialValue(g)
  local boxW = (#txt * 5) + 4
  if boxW < 22 then boxW = 22 end
  if boxW > 32 then boxW = 32 end
  local boxH = 9
  local bx = cx - math.floor(boxW / 2)
  local by = cy - 4

  lcd.drawFilledRectangle(bx, by, boxW, boxH, ERASE)
  lcd.drawRectangle(bx, by, boxW, boxH, SOLID)

  local textFlags = SMLSIZE
  if warnHigh and g.val >= g.max then
    lcd.drawFilledRectangle(bx + 1, by + 1, boxW - 2, boxH - 2, FORCE)
    textFlags = SMLSIZE + INVERS
  end
  local tx = cx - math.floor((#txt * 5) / 2) + 1
  lcd.drawText(tx, by + 2, txt, textFlags)

  local lbl = g.label
  local lx = cx - math.floor((#lbl * 5) / 2) + 1
  lcd.drawText(lx, cy + r - 8, lbl, SMLSIZE)
end

local function drawSideBarCard(x, y, w, h, g, warnLow, warnHigh)
  lcd.drawRectangle(x, y, w, h, SOLID)

  local isAlert = (warnLow and g.val <= g.min) or (warnHigh and g.val >= g.max)
  if isAlert then
    lcd.drawFilledRectangle(x + 1, y + 1, w - 2, 7, FORCE)
    lcd.drawText(x + 2, y + 2, g.label, SMLSIZE + INVERS)
  else
    lcd.drawText(x + 2, y + 2, g.label, SMLSIZE)
    lcd.drawLine(x + 1, y + 8, x + w - 2, y + 8, DOTTED, FORCE)
  end

  local valStr
  if g.prec == 1 then
    valStr = string.format("%.1f%s", g.val, g.unit)
  else
    valStr = string.format("%d%s", math.floor(g.val + 0.5), g.unit)
  end
  lcd.drawText(x + 2, y + 11, valStr, SMLSIZE)

  local barX = x + 2
  local barY = y + h - 8
  local barW = w - 4
  local barH = 6
  lcd.drawRectangle(barX, barY, barW, barH, SOLID)

  local span = g.max - g.min
  local ratio = 0
  if span > 0 then
    ratio = clamp((g.val - g.min) / span, 0, 1)
  end

  local innerW = barW - 2
  local fillW = math.floor(ratio * innerW + 0.5)
  if fillW > 0 then
    lcd.drawFilledRectangle(barX + 1, barY + 1, fillW, barH - 2, FORCE)
  end

  for sx = barX + 4, barX + barW - 3, 4 do
    lcd.drawLine(sx, barY + 1, sx, barY + barH - 2, SOLID, ERASE)
  end
end

-- ============================================================================
-- Screen 1: Main Car Dashboard View
-- ============================================================================

local function drawDashboard()
  lcd.clear()

  if dashFocus then
    lcd.drawFilledRectangle(0, 0, 22, 7, FORCE)
    lcd.drawText(2, 1, "SET", SMLSIZE + INVERS)
  else
    lcd.drawText(1, 1, demoMode and "DEMO" or "ESC32", SMLSIZE)
  end

  drawCircularGauge(26, 33, 25, gauges[1], true)
  drawCircularGauge(76, 33, 24, gauges[2], true)

  drawSideBarCard(102, 0,  26, 31, gauges[3], true, false)
  drawSideBarCard(102, 33, 26, 31, gauges[4], false, true)
end

-- ============================================================================
-- Screen 2: Telemetry Source & Min/Max Setup Screen
-- ============================================================================

local TOTAL_ROWS = 14
local VISIBLE_ROWS = 6

local function getRowInfo(row)
  if row <= 12 then
    local gIdx = math.floor((row - 1) / 3) + 1
    local field = ((row - 1) % 3) + 1
    local g = gauges[gIdx]
    if field == 1 then
      local live = ""
      if sensorIds[gIdx] or demoMode then
        live = " (" .. formatDialValue(g) .. ")"
      end
      return g.key .. " Sensor", g.src .. live, gIdx, field
    elseif field == 2 then
      local vStr = (g.prec == 1) and string.format("%.1f", g.min) or tostring(g.min)
      return g.key .. " Min", vStr .. g.unit, gIdx, field
    else
      local vStr = (g.prec == 1) and string.format("%.1f", g.max) or tostring(g.max)
      return g.key .. " Max", vStr .. g.unit, gIdx, field
    end
  elseif row == 13 then
    return "Test Sim", demoMode and "ON" or "OFF", 0, 0
  else
    return "Save & Exit", "[OK]", 0, 0
  end
end

local function cycleSensor(gIdx, dir)
  local cur = gauges[gIdx].src
  local idx = 1
  for i = 1, #sensorList do
    if sensorList[i] == cur then
      idx = i
      break
    end
  end
  idx = idx + dir
  if idx < 1 then idx = #sensorList end
  if idx > #sensorList then idx = 1 end
  gauges[gIdx].src = sensorList[idx]
  resolveSensorIds()
end

local function adjustRowValue(row, dir)
  if row <= 12 then
    local _, _, gIdx, field = getRowInfo(row)
    local g = gauges[gIdx]
    if field == 1 then
      cycleSensor(gIdx, dir)
    elseif field == 2 then
      g.min = roundVal(g.min + dir * g.step, g.prec)
      if g.min >= g.max then
        g.min = roundVal(g.max - g.step, g.prec)
      end
    elseif field == 3 then
      g.max = roundVal(g.max + dir * g.step, g.prec)
      if g.max <= g.min then
        g.max = roundVal(g.min + g.step, g.prec)
      end
    end
  elseif row == 13 then
    demoMode = not demoMode
  end
end

local function drawSetup()
  lcd.clear()

  lcd.drawFilledRectangle(0, 0, 128, 9, FORCE)
  lcd.drawText(2, 1, "ESC32 DASH SETUP", SMLSIZE + INVERS)
  lcd.drawText(104, 1, string.format("%02d/%02d", setupRow, TOTAL_ROWS), SMLSIZE + INVERS)

  if setupRow < setupScroll + 1 then
    setupScroll = setupRow - 1
  elseif setupRow > setupScroll + VISIBLE_ROWS then
    setupScroll = setupRow - VISIBLE_ROWS
  end

  for i = 1, VISIBLE_ROWS do
    local r = setupScroll + i
    if r <= TOTAL_ROWS then
      local y = 10 + (i - 1) * 9
      local label, valStr = getRowInfo(r)
      local isSel = (r == setupRow)

      if isSel then
        lcd.drawFilledRectangle(0, y, 124, 8, FORCE)
        lcd.drawText(2, y + 1, label, SMLSIZE + INVERS)
        local valFlags = SMLSIZE + INVERS + RIGHT
        if setupEdit then
          valFlags = valFlags + BLINK
        end
        lcd.drawText(122, y + 1, valStr, valFlags)
      else
        lcd.drawText(2, y + 1, label, SMLSIZE)
        lcd.drawText(122, y + 1, valStr, SMLSIZE + RIGHT)
      end
    end
  end

  lcd.drawLine(126, 10, 126, 63, DOTTED, FORCE)
  local thumbH = math.max(6, math.floor((VISIBLE_ROWS / TOTAL_ROWS) * 53))
  local thumbY = 10 + math.floor(((setupRow - 1) / (TOTAL_ROWS - 1)) * (53 - thumbH))
  lcd.drawFilledRectangle(125, thumbY, 3, thumbH, FORCE)
end

-- ============================================================================
-- EdgeTX Lifecycle Callbacks: init / background / run
-- ============================================================================

local function init()
  loadConfig()
  refreshSensors()
  resolveSensorIds()
end

local function background()
  updateTelemetry()
end

local function run(event)
  updateTelemetry()

  if mode == "DASH" then
    if event == EVT_VIRTUAL_ENTER_LONG or event == EVT_VIRTUAL_MENU then
      refreshSensors()
      mode = "SETUP"
      setupEdit = false
    elseif event == EVT_VIRTUAL_NEXT or event == EVT_VIRTUAL_PREV then
      dashFocus = not dashFocus
    elseif event == EVT_VIRTUAL_ENTER and dashFocus then
      refreshSensors()
      mode = "SETUP"
      setupEdit = false
      dashFocus = false
    elseif event == EVT_VIRTUAL_EXIT then
      dashFocus = false
    end

    drawDashboard()

  elseif mode == "SETUP" then
    if setupEdit then
      if event == EVT_VIRTUAL_NEXT or event == EVT_VIRTUAL_NEXT_REPT then
        adjustRowValue(setupRow, 1)
      elseif event == EVT_VIRTUAL_PREV or event == EVT_VIRTUAL_PREV_REPT then
        adjustRowValue(setupRow, -1)
      elseif event == EVT_VIRTUAL_ENTER or event == EVT_VIRTUAL_EXIT then
        setupEdit = false
        saveConfig()
      end
    else
      if event == EVT_VIRTUAL_NEXT or event == EVT_VIRTUAL_NEXT_REPT then
        setupRow = setupRow + 1
        if setupRow > TOTAL_ROWS then setupRow = 1 end
      elseif event == EVT_VIRTUAL_PREV or event == EVT_VIRTUAL_PREV_REPT then
        setupRow = setupRow - 1
        if setupRow < 1 then setupRow = TOTAL_ROWS end
      elseif event == EVT_VIRTUAL_ENTER then
        if setupRow == 13 then
          demoMode = not demoMode
        elseif setupRow == 14 then
          saveConfig()
          mode = "DASH"
        else
          setupEdit = true
        end
      elseif event == EVT_VIRTUAL_EXIT then
        saveConfig()
        mode = "DASH"
      end
    end

    drawSetup()
  end

  return 0
end

return { init = init, background = background, run = run }
