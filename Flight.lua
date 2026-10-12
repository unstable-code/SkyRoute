-- SkyRoute: 비행 추적
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
--
-- path.stops 는 비행 지도에서 얻은 정류장(내릴 수 있는 곳)과 그 사이에 내리지 않고 지나가는
-- 지역(pass = true)을 비행 순서대로 담는다. 비행 지도는 발견한 비행 지점만으로 경로를 보여 주므로,
-- 실제로 지나가는 곳은 비행 중 지역 변경으로 알아내 구간별로 학습한다.

local MIN_PASS_DWELL = 5 -- 지나가는 지역에 이만큼(초) 이상 머물러야 학습 (경계를 스친 지역 제외)

local function passStop(name, at, learned)
    return { name = name, zone = name, at = at, pass = true, learned = learned }
end

-- 학습해 둔 지나가는 지역을 정류장 사이에 끼워 넣는다. 위치(at)는 구간 안에 고르게 나눈다.
function ns.AddPasses(path)
    if not path then return nil end

    local stops, merged = path.stops, {}
    for i, stop in ipairs(stops) do
        merged[#merged + 1] = stop
        local nextStop = stops[i + 1]
        local names = nextStop and ns.GetPasses(stop.key, nextStop.key)
        if names then
            local gap = (nextStop.at - stop.at) / (#names + 1)
            for k, name in ipairs(names) do
                merged[#merged + 1] = passStop(name, stop.at + gap * k, true)
            end
        end
    end

    path.stops = merged
    return path
end

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

-- 지금 조기 착륙을 요청하면 내릴 정류장 번호. #stops 면 목적지, 알 수 없으면 nil.
-- 지나가는 지역에는 내릴 수 없으므로 다음 정류장을 찾을 때 건너뛴다.
-- 내릴 수 있는 정류장이 둘뿐인 직항은 추정 없이도 목적지에 내린다.
function ns.LandingStop(f)
    local stops = f.path and f.path.stops
    if not stops then return nil end

    local current = ns.CurrentStop(f)
    if current == #stops then return current end

    local landing = (current or 1) + 1
    while stops[landing].pass do
        landing = landing + 1
    end
    if current or landing == #stops then
        return landing
    end
end

-- 도시 위를 날 때는 지역 이름 대신 정류장(도시) 이름이 나오기도 한다
local function matches(stop, zone)
    return stop.zone == zone or stop.name == zone
end

-- 지나가는 지역 index 를 둘러싼 구간의 앞뒤 정류장 번호
local function hopAround(stops, index)
    local from, to = index - 1, index + 1
    while stops[from].pass do from = from - 1 end
    while stops[to].pass do to = to + 1 end
    return from, to
end

-- 한 구간에서 학습한 지나가는 지역을 비행 순서대로 저장
local function savePasses(stops, from, to)
    local names = {}
    for i = from + 1, to - 1 do
        if stops[i].learned then
            names[#names + 1] = stops[i].name
        end
    end
    ns.SetPasses(stops[from].key, stops[to].key, names)
end

local function watchPass(index)
    local stop = flight.path.stops[index]
    if stop.pass and not stop.learned then
        flight.pendingPass = { index = index, since = GetTime() }
    end
end

-- 지역이 바뀌면
--   1. 앞으로 남은 정류장·지나가는 지역 중 그 지역의 첫 곳까지 기준점을 옮긴다.
--   2. 이미 지난 곳이면 무시한다. 기준점은 뒤로 움직이지 않으므로 경계를 오가도 흔들리지 않는다.
--   3. 처음 보는 지역이면 지금 구간의 기준점 바로 뒤에 지나가는 지역으로 끼워 넣는다.
-- 지나가는 지역을 벗어날 때 MIN_PASS_DWELL 이상 머물렀으면 그 구간의 학습 목록에 저장한다.
ns.On("ZONE_CHANGED_NEW_AREA", function()
    if not (flight and flight.state == "flying" and flight.path) then return end

    local zone = GetRealZoneText()
    local stops = flight.path.stops
    ns.Debug("지역 변경: %s", tostring(zone))

    local pending = flight.pendingPass
    flight.pendingPass = nil
    if pending and GetTime() - pending.since >= MIN_PASS_DWELL then
        stops[pending.index].learned = true
        savePasses(stops, hopAround(stops, pending.index))
        ns.Debug("지나가는 지역 학습: %s", stops[pending.index].name)
    end

    if not zone or zone == "" then return end

    local anchor = flight.anchor or 1
    for i = anchor + 1, #stops do
        if matches(stops[i], zone) then
            flight.anchor = i
            watchPass(i)
            ns.Debug("기준 정류장 → %d/%d %s", i, #stops, stops[i].name)
            return
        end
    end

    for i = anchor, 1, -1 do
        if matches(stops[i], zone) then
            if i == anchor then watchPass(i) end
            return
        end
    end

    -- 목적지에 들어선 뒤에는 끼워 넣을 구간이 없다
    if anchor == #stops then return end
    tinsert(stops, anchor + 1, passStop(zone, (stops[anchor].at + stops[anchor + 1].at) / 2))
    flight.anchor = anchor + 1
    watchPass(anchor + 1)
    ns.Debug("지나가는 지역 → %d/%d %s", anchor + 1, #stops, zone)
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
        path = ns.AddPasses(ns.BuildPath(dest)),
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
        -- 착륙 지점은 처음 요청할 때 정해지므로 다시 눌러도 바꾸지 않는다
        -- landing: 내릴 정류장 번호, 알 수 없으면 false
        if flight.landing ~= nil then return end
        local landing = ns.LandingStop(flight)
        flight.landing = landing or false

        -- 목적지에 내리면 끝까지 같은 경로를 비행하므로 중단이 아니다
        if landing and landing == #flight.path.stops then
            ns.Print(format("%s에 그대로 내리므로 비행 기록을 계속합니다.", ns.Em(flight.toName)))
            return
        end

        local message = "조기 착륙을 요청해 비행 기록을 중단합니다."
        if landing then
            message = format("조기 착륙을 요청해 비행 기록을 중단합니다. %s에 내릴 예정입니다.",
                ns.Em(flight.path.stops[landing].name))
        end
        interrupt("조기 착륙", message)
    end)
end


--[[ 대화 비행 진단 (#3) ]]
-- 드루이드 히포그리프처럼 비행 지도 없이 대화 선택지로 출발하는 비행을 구현하기 전에,
-- 디버그 모드에서 대화 선택과 그 뒤의 이륙·착륙을 출력해 실제 동작을 확인한다.

local gossipWatcher = CreateFrame("Frame")
gossipWatcher:Hide()

-- "Creature-0-1234-1-56-11798-0000ABCD" → "11798"
local function npcID()
    local guid = UnitGUID("npc")
    return guid and strmatch(guid, "^%a+%-%d+%-%d+%-%d+%-%d+%-(%d+)") or "?"
end

local function optionName(index)
    for _, option in ipairs(C_GossipInfo.GetOptions() or {}) do
        if option.orderIndex == index then
            return option.name, option.gossipOptionID
        end
    end
end

-- index 또는 optionID 중 하나로 고른 선택지. 조회는 디버그 모드에서만 한다.
local function gossipSelected(index, optionID)
    if not ns.IsDebug() then return end

    local name
    if index then
        name, optionID = optionName(index)
    end
    ns.Debug("대화 선택: NPC %s, 선택지 \"%s\" (id %s)", npcID(), name or "?", tostring(optionID))

    gossipWatcher.selected = GetTime()
    gossipWatcher.started = nil
    gossipWatcher.wait = 0
    gossipWatcher:Show()
end

-- 임시 진단이라 기존 watcher 와 상태를 섞지 않고 따로 폴링한다.
-- #3 을 구현할 때 대화 비행도 flight(pending) 로 만들어 watcher 에 합친다.
gossipWatcher:SetScript("OnUpdate", function(self, elapsed)
    self.wait = self.wait - elapsed
    if self.wait > 0 then return end
    self.wait = POLL_INTERVAL

    local onTaxi = UnitOnTaxi("player")

    if not self.started then
        if onTaxi then
            -- 비행 지도로 출발했으면 이미 추적 중이므로 대화 비행이 아니다
            if flight then return self:Hide() end
            self.started = GetTime()
            ns.Debug("비행 지도 없이 이륙: 대화 선택 %.1f초 후, 지역 %s",
                self.started - self.selected, tostring(GetRealZoneText()))
        elseif GetTime() - self.selected > TAKEOFF_TIMEOUT then
            self:Hide()
        end
    elseif not onTaxi then
        ns.Debug("비행 지도 없이 착륙: %s, 지역 %s",
            ns.FormatDuration(GetTime() - self.started), tostring(GetRealZoneText()))
        self:Hide()
    end
end)

if C_GossipInfo then
    if C_GossipInfo.SelectOptionByIndex then
        hooksecurefunc(C_GossipInfo, "SelectOptionByIndex", function(index)
            gossipSelected(index)
        end)
    end
    -- 대화창 애드온은 선택지 ID 로 고르기도 한다
    if C_GossipInfo.SelectOption then
        hooksecurefunc(C_GossipInfo, "SelectOption", function(optionID)
            gossipSelected(nil, optionID)
        end)
    end
end
