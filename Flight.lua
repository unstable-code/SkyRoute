-- TaxiTimer: 비행 추적
--
-- 상태 흐름: (없음) → pending → flying → (없음)
--   pending: 비행 지도에서 목적지를 골랐지만 아직 이륙하지 않음
--   flying : UnitOnTaxi 가 참이 된 순간부터 거짓이 될 때까지
-- 소요 시간은 flying 구간만 잰다. 골드 부족 등으로 이륙하지 못하면 pending 이
-- 시간 초과로 버려지므로 잘못된 기록이 남지 않는다.

local _, ns = ...

local POLL_INTERVAL = 0.1
local TAKEOFF_TIMEOUT = 10 -- 목적지 선택 후 이 시간(초) 안에 이륙하지 않으면 포기
local NOTABLE_DIFF = 2     -- 기존 기록과 이 이상(초) 차이 나면 갱신 안내
local ARRIVAL_LEAD = 15    -- 도착 이만큼(초) 전부터 목적지를 현재 정류장으로 표시

local flight

function ns.GetFlight()
    return flight
end

local watcher = CreateFrame("Frame")
watcher:Hide()

local function finish()
    flight = nil
    watcher:Hide()
    ns.HideTimer()
end


--[[ 정류장 진행도 ]]

-- 비행 중 현재 지나고 있는 정류장 번호. 경과 시간 비율 추정과 지역 변경 기준점 중
-- 더 앞선 쪽을 쓴다. 둘 다 없으면(처음 가는 경로이고 지역도 안 바뀜) nil.
function ns.CurrentStop(f)
    local path = f.path
    if not path then return nil end

    local stops = path.stops
    local reached = f.anchor

    if f.expected and f.expected > 0 then
        local elapsed = GetTime() - f.started
        if f.expected - elapsed <= ARRIVAL_LEAD then
            return #stops
        end

        local covered = min(elapsed / f.expected, 1) * path.length
        local byTime = 1
        for i = 2, #stops do
            if stops[i].at > covered then break end
            byTime = i
        end
        if not reached or byTime > reached then
            reached = byTime
        end
    end

    return reached
end

-- 지역이 바뀌면 앞으로 남은 정류장 중 그 지역에 속한 첫 정류장까지 기준점을 옮긴다.
-- 뒤로는 움직이지 않으므로 경계를 오가며 지역이 번갈아 바뀌어도 흔들리지 않는다.
ns.On("ZONE_CHANGED_NEW_AREA", function()
    if not (flight and flight.state == "flying" and flight.path) then return end

    local zone = GetRealZoneText()
    local stops = flight.path.stops
    ns.Debug("지역 변경: %s", tostring(zone))

    for i = (flight.anchor or 1) + 1, #stops do
        if stops[i].zone == zone then
            flight.anchor = i
            ns.Debug("기준 정류장 → %d/%d %s", i, #stops, stops[i].name)
            return
        end
    end
end)


--[[ 이륙 / 착륙 ]]

local function takeOff()
    flight.state = "flying"
    flight.started = GetTime()

    if not flight.expected then
        ns.Print(format("처음 비행하는 경로입니다. %s → %s 소요 시간을 측정합니다.",
            ns.Em(flight.fromName), ns.Em(flight.toName)))
    end

    if ns.db.settings.party and IsInGroup() and not IsInRaid() then
        SendChatMessage(flight.toName .. ns.JosaRo(flight.toName) .. " 비행합니다.", "PARTY")
    end

    ns.ShowTimer()
end

local function land()
    if flight.interrupted then
        ns.Debug("중단된 비행이라 기록하지 않음 (%s)", flight.interrupted)
        return finish()
    end

    local seconds = floor(GetTime() - flight.started + 0.5)
    local previous = flight.expected
    local toName = ns.Em(flight.toName)

    if not previous then
        ns.Print(format("%s → %s 경로를 기록했습니다: %s",
            ns.Em(flight.fromName), toName, ns.Em(ns.FormatDuration(seconds))))
    elseif abs(seconds - previous) >= NOTABLE_DIFF then
        local now = ns.FormatDuration(seconds)
        ns.Print(format("%s 도착 시간을 %s에서 %s%s 갱신했습니다.",
            toName, ns.FormatDuration(previous), ns.Em(now), ns.JosaRo(now)))
    else
        ns.Print(format("%s 도착 (%s)", toName, ns.FormatDuration(seconds)))
    end

    ns.SetDuration(flight.fromKey, flight.toKey, seconds)
    finish()
end

watcher:SetScript("OnUpdate", function(self, elapsed)
    self.wait = (self.wait or 0) - elapsed
    if self.wait > 0 then return end
    self.wait = POLL_INTERVAL

    if not flight then
        return self:Hide()
    end

    local onTaxi = UnitOnTaxi("player")

    if flight.state == "pending" then
        if onTaxi then
            takeOff()
        elseif GetTime() - flight.requested > TAKEOFF_TIMEOUT then
            ns.Debug("이륙하지 않아 비행 추적을 취소함")
            finish()
        end
    elseif not onTaxi then
        land()
    end
end)

hooksecurefunc("TakeTaxiNode", function(dest)
    local origin = ns.FindCurrentSlot()
    if not origin then return end

    local fromKey, toKey = ns.NodeKey(origin), ns.NodeKey(dest)

    flight = {
        state = "pending",
        requested = GetTime(),
        fromKey = fromKey,
        toKey = toKey,
        fromName = (ns.NodeLabel(origin)),
        toName = (ns.NodeLabel(dest)),
        expected = ns.GetDuration(fromKey, toKey),
        -- 경유 경로는 비행 지도가 열려 있는 지금만 조회할 수 있다
        path = ns.BuildPath(dest),
    }
    ns.Debug("목적지 선택: %s → %s", fromKey, toKey)

    watcher.wait = 0
    watcher:Show()
end)


--[[ 중단 ]]

local function interrupt(reason, message)
    if not flight or flight.interrupted then return end

    flight.interrupted = reason
    if message then
        ns.Print(message)
    end
end

if C_SummonInfo and C_SummonInfo.ConfirmSummon then
    hooksecurefunc(C_SummonInfo, "ConfirmSummon", function()
        interrupt("소환 수락", "소환을 수락해 비행 기록을 중단합니다.")
    end)
end

hooksecurefunc("AcceptBattlefieldPort", function(_, accept)
    if accept then
        interrupt("전장 입장", "전장에 입장해 비행 기록을 중단합니다.")
    end
end)

if TaxiRequestEarlyLanding then
    hooksecurefunc("TaxiRequestEarlyLanding", function()
        if not flight or flight.state ~= "flying" then return end

        local message = "조기 착륙을 요청해 비행 기록을 중단합니다."
        local current = ns.CurrentStop(flight)
        local nextStop = current and flight.path.stops[current + 1]
        if nextStop then
            message = format("조기 착륙을 요청해 비행 기록을 중단합니다. %s에 내릴 예정입니다.", ns.Em(nextStop.name))
        end

        interrupt("조기 착륙", message)
        flight.landingAt = nextStop and nextStop.name
    end)
end
