-- TaxiTimer: 화면 표시 (타이머 창, 타이머 창 툴팁, 비행 지도 노드 툴팁)

local _, ns = ...

local REFRESH_INTERVAL = 0.1
local TOOLTIP_INTERVAL = 0.25
local DEFAULT_POSITION = { "TOP", "TOP", 0, -160 }

local LABEL_R, LABEL_G, LABEL_B = 1, 0.82, 0
local DIM_R, DIM_G, DIM_B = 0.6, 0.6, 0.6


--[[ 타이머 창 ]]

local timer = CreateFrame("Frame", nil, UIParent, BackdropTemplateMixin and "BackdropTemplate")
timer:SetSize(170, 46)
timer:SetFrameStrata("MEDIUM")
timer:SetClampedToScreen(true)
timer:SetMovable(true)
timer:EnableMouse(true)
timer:RegisterForDrag("LeftButton")
timer:Hide()

timer:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 14,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
})
timer:SetBackdropColor(0, 0, 0, 0.75)
timer:SetBackdropBorderColor(0.4, 0.4, 0.4)

timer.title = timer:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
timer.title:SetPoint("TOPLEFT", 8, -7)
timer.title:SetPoint("TOPRIGHT", -8, -7)
timer.title:SetWordWrap(false)

timer.clock = timer:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
timer.clock:SetPoint("BOTTOM", 0, 7)

local function placeTimer()
    local p = ns.db.position or DEFAULT_POSITION
    timer:ClearAllPoints()
    timer:SetPoint(p[1], UIParent, p[2], p[3], p[4])
end

timer:SetScript("OnDragStart", timer.StartMoving)
timer:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relativePoint, x, y = self:GetPoint()
    ns.db.position = { point, relativePoint, x, y }
end)

ns.On("PLAYER_LOGIN", placeTimer)

function ns.ResetTimerPosition()
    ns.db.position = nil
    placeTimer()
end

local function updateClock()
    local f = ns.GetFlight()

    if not f or f.state ~= "flying" then
        timer.clock:SetText("0:00")
        timer.clock:SetTextColor(DIM_R, DIM_G, DIM_B)
        return
    end

    local elapsed = GetTime() - f.started

    if not f.expected then
        -- 처음 가는 경로: 경과 시간
        timer.clock:SetText(ns.FormatClock(elapsed))
        timer.clock:SetTextColor(0.55, 0.8, 1)
    elseif elapsed <= f.expected then
        timer.clock:SetText(ns.FormatClock(ceil(f.expected - elapsed)))
        timer.clock:SetTextColor(1, 1, 1)
    else
        -- 기록보다 오래 걸리는 중
        timer.clock:SetText("+" .. ns.FormatClock(elapsed - f.expected))
        timer.clock:SetTextColor(1, 0.5, 0.25)
    end
end


--[[ 타이머 창 툴팁 ]]

local function addRow(label, value, dim)
    if dim then
        GameTooltip:AddDoubleLine(label, value, LABEL_R, LABEL_G, LABEL_B, DIM_R, DIM_G, DIM_B)
    else
        GameTooltip:AddDoubleLine(label, value, LABEL_R, LABEL_G, LABEL_B, 1, 1, 1)
    end
end

local function addStops(f)
    local stops = f.path and f.path.stops
    -- 정류장이 둘뿐이면 직항이라 경유지 표시가 의미 없다
    if not stops or #stops <= 2 then return end

    local count = #stops
    local current = ns.CurrentStop(f)

    GameTooltip:AddLine(" ")

    if current then
        addRow("경유지", format("%d / %d", current, count))
        GameTooltip:AddLine(format("%s  →  |cffffffff%s|r  →  %s",
            current > 1 and stops[current - 1].name or "출발",
            stops[current].name,
            current < count and stops[current + 1].name or "도착"),
            DIM_R, DIM_G, DIM_B)
    else
        addRow("경유지", format("? / %d", count), true)
        local names = {}
        for i, stop in ipairs(stops) do
            names[i] = stop.name
        end
        GameTooltip:AddLine(table.concat(names, " → "), DIM_R, DIM_G, DIM_B, true)
    end
end

local function fillTooltip()
    local f = ns.GetFlight()

    GameTooltip:ClearLines()
    GameTooltip:AddLine("TaxiTimer")

    if not f or f.state ~= "flying" then
        GameTooltip:AddLine("드래그해서 위치를 옮길 수 있습니다.", 1, 1, 1)
        GameTooltip:AddLine("/taxitimer hide 로 숨깁니다.", DIM_R, DIM_G, DIM_B)
        GameTooltip:Show()
        return
    end

    addRow("출발", f.fromName)
    addRow("도착", f.toName)
    if f.expected then
        addRow("기록", ns.FormatDuration(f.expected))
    else
        addRow("기록", "없음 (측정 중)", true)
    end
    -- 타이머 창(FormatClock)과 같은 초를 보이도록 내림
    addRow("경과", ns.FormatDuration(floor(GetTime() - f.started)))

    if f.interrupted then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(f.interrupted .. " — 이번 비행은 기록하지 않습니다.", 1, 0.5, 0.25)
        if f.landingAt then
            addRow("착륙 예정", f.landingAt)
        end
    end

    addStops(f)
    GameTooltip:Show()
end

timer:SetScript("OnEnter", function(self)
    self.hovered = true
    self.tooltipWait = TOOLTIP_INTERVAL
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    fillTooltip()
end)

timer:SetScript("OnLeave", function(self)
    self.hovered = false
    GameTooltip:Hide()
end)

timer:SetScript("OnUpdate", function(self, elapsed)
    self.clockWait = (self.clockWait or 0) - elapsed
    if self.clockWait <= 0 then
        self.clockWait = REFRESH_INTERVAL
        updateClock()
    end

    if self.hovered then
        self.tooltipWait = self.tooltipWait - elapsed
        if self.tooltipWait <= 0 then
            self.tooltipWait = TOOLTIP_INTERVAL
            fillTooltip()
        end
    end
end)

-- 비행 중이면 비행 정보, 아니면 위치 조정용 미리보기로 표시
function ns.ShowTimer()
    local f = ns.GetFlight()

    if f and f.state == "flying" then
        timer.title:SetText(f.toName)
    else
        timer.title:SetText("위치 조정 중")
    end

    timer.clockWait = 0
    timer:Show()
end

function ns.HideTimer()
    timer:Hide()
end

function ns.IsTimerShown()
    return timer:IsShown()
end


--[[ 비행 지도 노드 툴팁 ]]

hooksecurefunc("TaxiNodeOnButtonEnter", function(button)
    local dest = button:GetID()
    if TaxiNodeGetType(dest) ~= "REACHABLE" then return end

    local origin = ns.FindCurrentSlot()
    if not origin then return end

    local seconds = ns.GetDuration(ns.NodeKey(origin), ns.NodeKey(dest))
    if seconds then
        addRow("비행 시간", ns.FormatDuration(seconds))
    else
        addRow("비행 시간", "기록 없음", true)
    end
    GameTooltip:Show()
end)
