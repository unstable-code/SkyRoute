-- SkyRoute: 비행 지도 조회 (노드 식별, 이름 해석, 경유 경로 계산)
-- 여기의 함수들은 비행 지도가 열려 있을 때만 의미 있는 값을 돌려준다.

local _, ns = ...

local CONTINENT_MAP_TYPE = Enum and Enum.UIMapType and Enum.UIMapType.Continent or 2

local mapContinent = 0

-- 플레이어가 있는 대륙의 uiMapID. 노드 좌표는 대륙 지도 기준으로 정규화되어 있어
-- 대륙이 다르면 좌표가 겹칠 수 있으므로 노드 키에 함께 넣는다.
local function findContinent()
    local mapID = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")

    while mapID and mapID > 0 do
        local info = C_Map.GetMapInfo(mapID)
        if not info then break end
        if info.mapType == CONTINENT_MAP_TYPE then
            return mapID
        end
        mapID = info.parentMapID
    end
    return 0
end

ns.On("TAXIMAP_OPENED", function()
    mapContinent = findContinent()
    ns.Debug("비행 지도 열림: 대륙 %d, 노드 %d개", mapContinent, NumTaxiNodes())
end)

-- 노드를 세션·캐릭터와 무관하게 식별하는 문자열 ("대륙:x:y")
function ns.NodeKey(slot)
    local x, y = TaxiNodePosition(slot)
    return format("%d:%.3f:%.3f", mapContinent, x, y)
end

-- 노드 표시명과 소속 지역명. 클라이언트에 따라 "이름 (지역)" 또는 "이름, 지역" 형식이며,
-- 지역이 따로 없으면 이름 자체가 지역명이다 (GetRealZoneText 와 비교하는 데 쓴다).
function ns.NodeLabel(slot)
    local full = TaxiNodeName(slot)

    local name, zone = strmatch(full, "^(.-)%s*%((.+)%)%s*$")
    if not name then
        name, zone = strmatch(full, "^(.-),%s*(.+)$")
    end
    if not name or name == "" then
        return full, full
    end
    return name, zone
end

function ns.FindCurrentSlot()
    for slot = 1, NumTaxiNodes() do
        if TaxiNodeGetType(slot) == "CURRENT" then
            return slot
        end
    end
end


--[[ 경유 경로 ]]

local function isSlot(slot, count)
    return slot and slot >= 1 and slot <= count
end

-- 현재 위치에서 dest 까지 거쳐 가는 정류장 목록.
-- 각 정류장의 at 은 출발점부터의 누적 직선 거리이며, 비행 속도가 일정하다고 보고
-- 경과 시간 비율로 현재 구간을 추정하는 데 쓴다.
-- 비행 지도가 경로선을 그릴 때 쓰는 API 가 없거나 값이 이상하면 nil.
function ns.BuildPath(dest)
    if not (GetNumRoutes and TaxiGetNodeSlot) then return nil end

    local hops = GetNumRoutes(dest)
    if not hops or hops < 1 then return nil end

    local count = NumTaxiNodes()
    local slots = {}

    for hop = 1, hops do
        local from = TaxiGetNodeSlot(dest, hop, true)
        local to = TaxiGetNodeSlot(dest, hop, false)
        if not (isSlot(from, count) and isSlot(to, count)) then
            return nil
        end
        if hop == 1 then
            slots[1] = from
        end
        slots[#slots + 1] = to
    end

    local stops, length = {}, 0
    local lastX, lastY

    for i, slot in ipairs(slots) do
        local x, y = TaxiNodePosition(slot)
        if lastX then
            length = length + sqrt((x - lastX) ^ 2 + (y - lastY) ^ 2)
        end
        lastX, lastY = x, y

        local name, zone = ns.NodeLabel(slot)
        stops[i] = { name = name, zone = zone, at = length }
    end

    return { stops = stops, length = length }
end
