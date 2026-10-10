-- 실측 비행 시간 데이터로 검증
--
-- 데이터는 저장소에 넣지 않고 환경 변수 SKR_DATA 로 경로를 받는다. 없으면 건너뛴다.
--   SKR_DATA=/path/to/data.lua busted
--
-- 데이터 파일은 전역 테이블 하나를 정의하는 Lua 파일이며 형식은 다음과 같다.
--   { [진영] = { ["XXXXYYYY"] = { ["XXXXYYYY"] = 초, ... }, ... }, ... }
-- 키는 대륙 지도 기준 좌표를 1만 배 한 네 자리 x, y 를 이어 붙인 것이다.
-- 대륙 정보는 없으므로 경로로 연결된 노드끼리 같은 대륙으로 묶는다.
-- 경유 정보도 없으므로 모든 경로를 직항으로 흉내 낸다.

local wow = require("tests.wow")
local format = string.format

local DATA_PATH = os.getenv("SKR_DATA")

if not DATA_PATH or DATA_PATH == "" then
    describe("실측 데이터", function()
        pending("SKR_DATA 가 설정되지 않아 건너뜀")
    end)
    return
end

local function loadData(path)
    local chunk = assert(loadfile(path))
    local env = {}
    setfenv(chunk, env)
    chunk()

    local found
    for name, value in pairs(env) do
        if type(value) == "table" then
            assert(not found, "데이터 파일에 전역 테이블이 둘 이상 있음: " .. tostring(name))
            found = value
        end
    end
    return assert(found, "데이터 파일에 전역 테이블이 없음")
end

-- "XXXXYYYY" → 정규화 좌표
local function coords(key)
    return tonumber(key:sub(1, 4)) / 10000, tonumber(key:sub(5, 8)) / 10000
end

-- 경로로 연결된 노드끼리 묶어 대륙 목록을 만든다 (정렬해 실행마다 같은 순서)
local function continents(routes)
    local parent = {}
    local function find(k)
        if parent[k] == nil then parent[k] = k end
        while parent[k] ~= k do k = parent[k] end
        return k
    end
    for from, dests in pairs(routes) do
        for to in pairs(dests) do
            parent[find(from)] = find(to)
        end
    end

    local groups, list = {}, {}
    for k in pairs(parent) do
        local root = find(k)
        if not groups[root] then
            groups[root] = {}
            list[#list + 1] = groups[root]
        end
        table.insert(groups[root], k)
    end
    for _, keys in ipairs(list) do table.sort(keys) end
    table.sort(list, function(a, b) return a[1] < b[1] end)
    return list
end

-- 대륙 하나의 비행 지도. origin 이 현재 위치이고 모든 목적지는 직항
local function taxiMap(keys, origin)
    local taxi = { nodes = {}, routes = {}, slot = {} }
    for i, key in ipairs(keys) do
        local x, y = coords(key)
        taxi.nodes[i] = {
            name = "N" .. key .. " (Z" .. key .. ")",
            x = x, y = y,
            type = key == origin and "CURRENT" or "REACHABLE",
        }
        taxi.slot[key] = i
    end
    for i, key in ipairs(keys) do
        if key ~= origin then
            taxi.routes[i] = { taxi.slot[origin], i }
        end
    end
    return taxi
end

local DATA = loadData(DATA_PATH)

local factions = {}
for faction in pairs(DATA) do factions[#factions + 1] = faction end
table.sort(factions)

for _, faction in ipairs(factions) do
    local routes = DATA[faction]
    local groups = continents(routes)

    describe("실측 데이터 " .. faction, function()
        it(format("노드 키가 겹치지 않음 (대륙 %d개)", #groups), function()
            local collisions = {}
            for index, keys in ipairs(groups) do
                local game = wow.load()
                game.continent = 100 + index
                game:openTaxiMap(taxiMap(keys, keys[1]))

                local seen = {}
                for slot, key in ipairs(keys) do
                    local nodeKey = game.ns.NodeKey(slot)
                    if seen[nodeKey] then
                        collisions[#collisions + 1] = seen[nodeKey] .. " = " .. key .. " → " .. nodeKey
                    end
                    seen[nodeKey] = key
                end
            end
            assert.same({}, collisions)
        end)

        it("모든 경로를 비행하면 같은 시간으로 기록", function()
            local mismatches = {}
            for index, keys in ipairs(groups) do
                local game = wow.load()
                game.continent = 100 + index
                local ns = game.ns

                for _, from in ipairs(keys) do
                    for to, seconds in pairs(routes[from] or {}) do
                        local taxi = taxiMap(keys, from)
                        game:openTaxiMap(taxi)
                        local fromKey, toKey = ns.NodeKey(taxi.slot[from]), ns.NodeKey(taxi.slot[to])
                        game:call("TakeTaxiNode", taxi.slot[to])
                        game:closeTaxiMap()

                        game:advance(0.3, 0.1)
                        game.onTaxi = true
                        game:advance(seconds, 0.1)
                        game.onTaxi = false
                        game:advance(0.3, 0.1)

                        local recorded = ns.GetDuration(fromKey, toKey)
                        if recorded ~= seconds then
                            mismatches[#mismatches + 1] =
                                format("%s→%s 기대 %d 기록 %s", from, to, seconds, tostring(recorded))
                        end
                        assert.is_nil(ns.GetFlight())
                    end
                end
            end
            assert.same({}, mismatches)
        end)

        it("비행 지도 툴팁에 모든 경로의 기록 시간을 표시", function()
            local wrong = {}
            for index, keys in ipairs(groups) do
                local game = wow.load()
                game.continent = 100 + index
                local ns = game.ns

                for _, from in ipairs(keys) do
                    local taxi = taxiMap(keys, from)
                    game:openTaxiMap(taxi)
                    for to, seconds in pairs(routes[from] or {}) do
                        ns.SetDuration(ns.NodeKey(taxi.slot[from]), ns.NodeKey(taxi.slot[to]), seconds)
                        game.tooltip:ClearLines()
                        game:call("TaxiNodeOnButtonEnter", { GetID = function() return taxi.slot[to] end })
                        local expected = "비행 시간\t" .. ns.FormatDuration(seconds)
                        if game.tooltip.lines[1] ~= expected then
                            wrong[#wrong + 1] = format("%s→%s %s", from, to, tostring(game.tooltip.lines[1]))
                        end
                    end
                end
            end
            assert.same({}, wrong)
        end)

        it("시간 표기를 다시 숫자로 바꾸면 원래 값", function()
            local ns = wow.load().ns
            local wrong = {}
            for from, dests in pairs(routes) do
                for to, seconds in pairs(dests) do
                    local text = ns.FormatDuration(seconds)
                    local m = tonumber(text:match("(%d+)분")) or 0
                    local s = tonumber(text:match("(%d+)초")) or 0
                    if m * 60 + s ~= seconds then
                        wrong[#wrong + 1] = format("%s→%s %d → %s", from, to, seconds, text)
                    end
                end
            end
            assert.same({}, wrong)
        end)
    end)
end
