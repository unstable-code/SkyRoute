-- 퍼즈 (시드를 고정한 무작위 테스트)
--
-- 실패하면 시드와 마지막 이벤트들을 출력하므로 같은 상황을 그대로 재현할 수 있다.
--   SKR_FUZZ_SEED=<시드> SKR_FUZZ_RUNS=<횟수> busted tests/fuzz_spec.lua
--
-- 비행 추적은 애드온 코드를 베끼지 않고 규칙만 따로 구현한 모델과 비교한다.
--   - 목적지를 고른 뒤 10초 안에 이륙해야 추적한다
--   - 소환·전장 입장·조기 착륙으로 중단된 비행은 기록하지 않는다
--   - 단, 조기 착륙 지점이 최종 목적지면(직항, 마지막 구간) 중단이 아니다
--   - 기록 시간은 이륙부터 착륙까지의 시간이다
--   - 정류장 사이에 처음 보는 지역에 들어서면 지나가는 지역으로 끼워 넣고, 5초 이상 머문 뒤
--     벗어나면 그 구간에 학습한다. 조기 착륙은 지나가는 지역을 건너뛴 다음 정류장에 내린다
-- 애드온은 0.1초마다 상태를 확인하므로 경계 근처 결과는 양쪽 다 허용한다.

local wow = require("tests.wow")
local fixtures = require("tests.fixtures")
local format = string.format

local SEED = tonumber(os.getenv("SKR_FUZZ_SEED")) or 20261011
local RUNS = tonumber(os.getenv("SKR_FUZZ_RUNS")) or 300
local EVENTS_PER_RUN = 40

local TAKEOFF_TIMEOUT = 10
local POLL_SLACK = 0.25     -- 상태 확인 주기(0.1초)와 시간 진행 간격에서 오는 오차 허용 범위
local SETTLE = 0.3          -- 상태가 바뀐 뒤 애드온이 알아차릴 때까지 기다리는 시간
local STEP = 0.1

-- 정류장 지역, 정류장 밖 지역, 도시 이름(정류장 이름과 같음)
local ZONES = { "듀로타", "불모의 땅", "멀고어", "잿빛 골짜기", "버섯구름 봉우리", "썬더 블러프" }
local MIN_PASS_DWELL = 5

-- 모델이 쓰는 경로 정보: 테스트용 비행 지도에서 목적지별 정류장(이름, 지역, 슬롯)과 누적 거리를 만든다
local PATHS = {}
do
    local taxi = fixtures.kalimdor()
    for dest, route in pairs(taxi.routes) do
        local path, distance, last = { stops = {}, at = {} }, 0, nil
        for i, slot in ipairs(route) do
            local node = taxi.nodes[slot]
            if last then
                distance = distance + math.sqrt((node.x - last.x) ^ 2 + (node.y - last.y) ^ 2)
            end
            local name, zone = node.name:match("^(.-) %((.+)%)$")
            path.stops[i] = { name = name, zone = zone, slot = slot }
            path.at[i] = distance
            last = node
        end
        PATHS[dest] = path
    end
end
local ARRIVAL_LEAD = 15     -- 도착 이만큼 전부터는 목적지 구간으로 본다
local COMMANDS = { "show", "hide", "reset", "chat", "party", "debug", "help", "", "unknown" }
local DESTS = { fixtures.CROSSROADS, fixtures.THUNDER_BLUFF }

local function pick(list)
    return list[math.random(#list)]
end

-- 한 번의 무작위 실행. 위반이 있으면 error 로 알린다
local function runOnce(seed)
    math.randomseed(seed)
    local game = wow.load()
    local ns = game.ns
    local log = {}

    local function note(fmt, ...)
        log[#log + 1] = format("%8.2f  " .. fmt, game.now, ...)
    end

    local function fail(message)
        local tail = {}
        for i = math.max(1, #log - 25), #log do
            tail[#tail + 1] = log[i]
        end
        error(format("시드 %d: %s\n%s", seed, message, table.concat(tail, "\n")), 0)
    end

    local taxi = fixtures.kalimdor()
    local nodeKeys = {}
    game:openTaxiMap(taxi)
    for slot in ipairs(taxi.nodes) do
        nodeKeys[slot] = ns.NodeKey(slot)
    end
    game:closeTaxiMap()

    local routes = {}
    for _, dest in ipairs(DESTS) do
        routes[dest] = nodeKeys[fixtures.ORGRIMMAR] .. ">" .. nodeKeys[dest]
    end

    -- 모델: nil / { state = "pending" | "flying", dest, at, takeoff, expected, anchor, landing, interrupted, ambiguous,
    --               points, pending }
    --   expected: 목적지를 고를 때의 기존 기록, anchor: 지역 변경 기준점 (points 번호)
    --   landing : 처음 조기 착륙을 요청했을 때 내릴 정류장 (PATHS 정류장 번호, 알 수 없으면 false)
    --   points  : 정류장과 지나가는 지역을 비행 순서대로. 정류장은 stop(정류장 번호), 지나가는 지역은
    --             hop(구간 시작 정류장 번호)과 learned 를 가진다
    --   pending : 지금 머무는 아직 학습하지 않은 지나가는 지역 { point, since }
    local model
    local lastStop
    -- 구간 키("정류장 노드 키>다음 정류장 노드 키") → 학습한 지나가는 지역 이름 목록
    local learned = {}

    local function hopKey(path, h)
        return nodeKeys[path.stops[h].slot] .. ">" .. nodeKeys[path.stops[h + 1].slot]
    end

    local function buildPoints(dest)
        local path, points = PATHS[dest], {}
        for h, stop in ipairs(path.stops) do
            points[#points + 1] = { name = stop.name, zone = stop.zone, stop = h }
            if path.stops[h + 1] then
                for _, name in ipairs(learned[hopKey(path, h)] or {}) do
                    points[#points + 1] = { name = name, zone = name, hop = h, learned = true }
                end
            end
        end
        return points
    end

    -- 노드 키 → 정류장 (이름, 지역)
    local stopByKey = {}
    for _, path in pairs(PATHS) do
        for _, stop in ipairs(path.stops) do
            stopByKey[nodeKeys[stop.slot]] = stop
        end
    end

    -- 구간 키 → 이름 목록 표를 키 순서대로 문자열로
    local function serialize(passes)
        local lines = {}
        for key, names in pairs(passes) do
            lines[#lines + 1] = key .. " = " .. table.concat(names, ", ")
        end
        table.sort(lines)
        return table.concat(lines, "; ")
    end

    -- 애드온 상태를 모델로 다시 맞춘다 (추적 여부가 경계에 걸려 학습 여부를 알 수 없을 때만)
    local function resyncLearned()
        learned = {}
        for key, names in pairs(ns.db.passes) do
            learned[key] = { unpack(names) }
        end
    end

    local function expire()
        if model and model.state == "pending" then
            local waited = game.now - model.at
            if waited > TAKEOFF_TIMEOUT + POLL_SLACK then
                model = nil
            end
        end
    end

    local function wait(seconds)
        game:advance(seconds, STEP)
        expire()
    end

    local function checkFlightState()
        local flight = ns.GetFlight()
        if model and model.state == "flying" and not model.ambiguous then
            if not flight or flight.state ~= "flying" then
                fail("모델은 비행 중인데 애드온은 추적하지 않음")
            end
            local stop = ns.CurrentStop(flight)
            if stop then
                local count = #flight.path.stops
                if stop < 1 or stop > count then
                    fail(format("CurrentStop 범위 벗어남: %d / %d", stop, count))
                end
                if lastStop and stop < lastStop then
                    fail(format("CurrentStop 이 뒤로 감: %d → %d", lastStop, stop))
                end
                lastStop = stop
            end
        elseif not (model and model.ambiguous) and flight and flight.state == "flying" then
            fail("모델은 추적하지 않는데 애드온은 비행으로 추적함")
        end

        -- 경유지 목록(정류장 + 지나가는 지역)이 모델과 같아야 한다
        if model and model.state == "flying" and not model.ambiguous and flight and flight.path then
            local got, want = {}, {}
            for i, stop in ipairs(flight.path.stops) do got[i] = stop.name .. (stop.pass and "*" or "") end
            for i, point in ipairs(model.points) do want[i] = point.name .. (point.hop and "*" or "") end
            got, want = table.concat(got, " → "), table.concat(want, " → ")
            if got ~= want then
                fail(format("경유지 목록 불일치:\n  모델   %s\n  애드온 %s", want, got))
            end
        end

        -- 학습한 지나가는 지역은 모델과 같고, 구간마다 중복이 없고, 정류장 지역·이름은 들어가지 않는다
        if not (model and model.ambiguous) then
            local want, got = serialize(learned), serialize(ns.db.passes)
            if want ~= got then
                fail(format("학습 불일치:\n  모델   %s\n  애드온 %s", want, got))
            end
        end
        for key, names in pairs(ns.db.passes) do
            local from, to = key:match("^(.-)>(.*)$")
            local seen = {}
            for _, name in ipairs(names) do
                if seen[name] then fail(format("학습 목록에 중복: %s %s", key, name)) end
                seen[name] = true
                for _, stop in ipairs({ stopByKey[from], stopByKey[to] }) do
                    if stop.zone == name or stop.name == name then
                        fail(format("구간 정류장의 지역이 학습됨: %s %s", key, name))
                    end
                end
            end
        end
    end

    local function snapshot()
        local copy = {}
        for key, value in pairs(ns.db.routes) do copy[key] = value end
        return copy
    end

    local actions = {}

    function actions.choose()
        local dest = pick(DESTS)
        note("목적지 선택 %d", dest)
        game:openTaxiMap(fixtures.kalimdor())
        game:call("TakeTaxiNode", dest)
        game:closeTaxiMap()
        model = { state = "pending", dest = dest, at = game.now, expected = ns.db.routes[routes[dest]],
            points = buildPoints(dest) }
        lastStop = nil
    end

    -- 경과 시간 비율로 추정한 정류장 (경과 시간 elapsed 기준)
    -- 지나가는 지역은 구간 안쪽에 있으므로 시간 추정은 정류장만으로 해도 같은 구간이 나온다
    local function stopByTime(path, elapsed)
        if model.expected - elapsed <= ARRIVAL_LEAD then
            return #path.at
        end
        local covered = elapsed / model.expected * path.at[#path.at]
        local stop = 1
        for i = 2, #path.at do
            if path.at[i] <= covered then stop = i end
        end
        return stop
    end

    -- 지금 조기 착륙하면 내릴 정류장 (알 수 없으면 false). 판단이 경계에 걸리면 nil
    local function landingStop()
        local path = PATHS[model.dest]
        local count = #path.at

        local function at(elapsed)
            -- 기준점이 지나가는 지역이면 그 구간의 시작 정류장에 있는 셈이다
            local point = model.anchor and model.points[model.anchor]
            local current = point and (point.stop or point.hop)
            if model.expected and model.expected > 0 then
                current = math.max(current or 1, stopByTime(path, elapsed))
            end
            if not current then
                -- 비행 중 현재 정류장은 1 ~ count-1 이므로 직항은 목적지에 내린다
                return count == 2 and count or false
            end
            return math.min(current + 1, count)
        end

        -- 애드온은 이륙을 최대 한 번의 확인 주기 늦게 알아차리므로 경과 시간에 그만큼 폭이 있다
        local elapsed = game.now - model.takeoff
        local now, early = at(elapsed), at(elapsed - POLL_SLACK)
        if now ~= early then return nil end
        return now
    end

    function actions.takeoff()
        note("이륙")
        game.onTaxi = true
        if model and model.state == "pending" then
            local waited = game.now - model.at
            if waited <= TAKEOFF_TIMEOUT - POLL_SLACK then
                model.state, model.takeoff = "flying", game.now
            elseif waited <= TAKEOFF_TIMEOUT + POLL_SLACK then
                -- 시간 초과 경계: 추적될 수도 아닐 수도 있음
                model.state, model.takeoff, model.ambiguous = "flying", game.now, true
            else
                model = nil
            end
        end
        wait(SETTLE)
    end

    function actions.land()
        note("착륙")
        local all = snapshot()
        local before = ns.db.routes[model and routes[model.dest] or ""]
        game.onTaxi = false
        wait(SETTLE)

        if not (model and model.state == "flying") then
            local after = snapshot()
            for key in pairs(routes) do
                key = routes[key]
                if all[key] ~= after[key] then
                    fail(format("추적하지 않은 착륙인데 기록이 바뀜: %s %s → %s", key, tostring(all[key]), tostring(after[key])))
                end
            end
        else
            local key = routes[model.dest]
            local recorded = ns.db.routes[key]
            local duration = (game.now - SETTLE) - model.takeoff

            if model.ambiguous then
                note("경계 상황이라 기록 여부는 검사하지 않음")
            elseif model.interrupted then
                if recorded ~= before then
                    fail(format("중단된 비행(%s)이 기록됨: %s → %s", model.interrupted, tostring(before), tostring(recorded)))
                end
            else
                if not recorded or math.abs(recorded - duration) > 1 then
                    fail(format("기록 시간 불일치: 실제 %.2f초, 기록 %s", duration, tostring(recorded)))
                end
            end
        end

        if ns.GetFlight() then
            fail("착륙 후에도 추적 상태가 남음")
        end
        if model and model.ambiguous then
            resyncLearned()
        end
        model = nil
        lastStop = nil
    end

    -- 소환·전장 입장은 실제로는 비행을 끝내므로 비행 중이었다면 곧바로 착륙
    function actions.summon()
        note("소환 수락")
        game.env.C_SummonInfo.ConfirmSummon()
        if model then model.interrupted = model.interrupted or "소환" end
        if game.onTaxi then actions.land() end
    end

    function actions.battleground()
        local accept = math.random() < 0.5
        note("전장 입장 %s", accept and "수락" or "거절")
        game:call("AcceptBattlefieldPort", 1, accept)
        if accept then
            if model then model.interrupted = model.interrupted or "전장" end
            if game.onTaxi then actions.land() end
        end
    end

    function actions.earlyLanding()
        note("조기 착륙 요청")
        local flight = ns.GetFlight()
        local chatBefore, landingBefore = #game.chat, flight and flight.landing
        game:call("TaxiRequestEarlyLanding")

        if not (model and model.state == "flying") then return end

        -- 다시 누르면 착륙 지점도 안내도 바뀌지 않는다
        if model.landing ~= nil then
            if flight and flight.landing ~= landingBefore then
                fail(format("다시 누르자 착륙 지점이 바뀜: %s → %s", tostring(landingBefore), tostring(flight.landing)))
            end
            if #game.chat ~= chatBefore then
                fail("다시 누르자 안내가 또 나옴: " .. game.chat[#game.chat])
            end
            return
        end

        -- 착륙 지점은 처음 요청할 때 정해진다
        local landing = landingStop()
        model.landing = landing
        if landing == nil then
            note("조기 착륙 지점 판단이 경계에 걸려 기록 여부는 검사하지 않음")
            model.ambiguous = true
            return
        end
        if flight and not model.ambiguous then
            local stop = flight.landing and flight.path.stops[flight.landing]
            if stop and stop.pass then
                fail("지나가는 지역에 착륙 예정: " .. stop.name)
            end
            local name = stop and stop.name or nil
            local expected = landing and PATHS[model.dest].stops[landing].name or nil
            if name ~= expected then
                fail(format("착륙 지점 불일치: 모델 %s, 애드온 %s", tostring(expected), tostring(name)))
            end
        end
        if landing ~= #PATHS[model.dest].at then
            model.interrupted = model.interrupted or "조기 착륙"
        end
    end

    function actions.zone()
        local zone = pick(ZONES)
        note("지역 변경 %s", zone)
        game:enterZone(zone)

        if not (model and model.state == "flying") then return end
        local points = model.points

        -- 지나가는 지역을 5초 이상 머문 뒤 벗어나면 그 구간에 학습한다 (구간 안 순서대로)
        local pending = model.pending
        model.pending = nil
        if pending and game.now - pending.since >= MIN_PASS_DWELL then
            pending.point.learned = true
            local path, names = PATHS[model.dest], {}
            for _, point in ipairs(points) do
                if point.hop == pending.point.hop and point.learned then
                    names[#names + 1] = point.name
                end
            end
            learned[hopKey(path, pending.point.hop)] = #names > 0 and names or nil
        end

        local function isZone(point)
            return point.zone == zone or point.name == zone
        end
        local function stay(index)
            local point = points[index]
            if point.hop and not point.learned then
                model.pending = { point = point, since = game.now }
            end
        end

        -- 앞으로 남은 곳이면 기준점을 옮기고, 이미 지난 곳이면 무시 (뒤로는 안 감)
        local anchor = model.anchor or 1
        for i = anchor + 1, #points do
            if isZone(points[i]) then
                model.anchor = i
                stay(i)
                return
            end
        end
        for i = anchor, 1, -1 do
            if isZone(points[i]) then
                if i == anchor then stay(i) end
                return
            end
        end

        -- 처음 보는 지역: 목적지가 아니면 기준점 바로 뒤에 지나가는 지역으로 끼워 넣는다
        local here = points[anchor]
        if here.stop == #PATHS[model.dest].stops then return end
        table.insert(points, anchor + 1, { name = zone, zone = zone, hop = here.stop or here.hop })
        model.anchor = anchor + 1
        stay(anchor + 1)
    end

    function actions.slash()
        local input = pick(COMMANDS)
        note("명령 /skr %s", input)
        game:slash(input)
    end

    function actions.hoverNode()
        local slot = math.random(#fixtures.kalimdor().nodes)
        note("비행 지도 노드 %d 툴팁", slot)
        game.tooltip:ClearLines()
        game:openTaxiMap(fixtures.kalimdor())
        game:call("TaxiNodeOnButtonEnter", { GetID = function() return slot end })
        game:closeTaxiMap()

        local seconds = routes[slot] and ns.db.routes[routes[slot]]
        local lines = game.tooltip.lines
        if routes[slot] then
            local expected = "비행 시간\t" .. (seconds and ns.FormatDuration(seconds) or "기록 없음")
            if lines[1] ~= expected then
                fail(format("노드 툴팁 불일치: %s / 기대 %s", tostring(lines[1]), expected))
            end
        elseif #lines > 0 then
            fail("갈 수 없는 노드에 툴팁이 추가됨")
        end
    end

    function actions.hoverTimer()
        note("타이머 창 툴팁")
        local frame = game:timerFrame()
        frame.scripts.OnEnter(frame)
        game:advance(0.6, STEP)
        frame.scripts.OnLeave(frame)
        expire()
    end

    function actions.wait()
        local seconds = pick({ 0.1, 0.5, 1, 3, 4, 5, 9, 10, 11, 30, 90 }) + math.random()
        note("대기 %.2f초", seconds)
        wait(seconds)
    end

    -- 지금 가능한 행동만 고른다 (비행 중에는 비행 지도를 열 수 없음)
    local grounded = { "choose", "choose", "takeoff", "wait", "wait", "zone", "slash", "hoverNode", "hoverTimer", "summon", "battleground" }
    local flying = { "land", "land", "wait", "wait", "wait", "zone", "zone", "slash", "hoverTimer", "earlyLanding", "summon", "battleground" }

    for _ = 1, EVENTS_PER_RUN do
        local name = pick(game.onTaxi and flying or grounded)
        local ok, err = pcall(actions[name])
        if not ok then
            if type(err) == "string" and err:match("^시드 ") then
                error(err, 0)
            end
            fail("Lua 오류: " .. tostring(err))
        end
        checkFlightState()
    end
end

describe("퍼즈", function()
    it(format("비행 추적 무작위 시나리오 %d회 (시드 %d)", RUNS, SEED), function()
        for run = 0, RUNS - 1 do
            runOnce(SEED + run)
        end
    end)

    it("FormatDuration / FormatClock 은 0 이상 모든 값에서 형식을 지키고 값이 보존됨", function()
        local ns = wow.load().ns
        math.randomseed(SEED)
        for _ = 1, 20000 do
            local seconds = math.random() < 0.5 and math.random(0, 100000) or math.random() * 100000

            local text = ns.FormatDuration(seconds)
            local m = tonumber(text:match("^(%d+)분")) or 0
            local s = tonumber(text:match("(%d+)초$")) or 0
            assert(text:match("^%d+초$") or text:match("^%d+분$") or text:match("^%d+분 %d+초$"),
                format("FormatDuration(%s) = %s", seconds, text))
            assert(s < 60, format("FormatDuration(%s) 초가 60 이상: %s", seconds, text))
            assert.equal(math.floor(seconds + 0.5), m * 60 + s)

            local clock = ns.FormatClock(seconds)
            local cm, cs = clock:match("^(%d+):(%d%d)$")
            assert(cm, format("FormatClock(%s) = %s", seconds, clock))
            assert.equal(math.floor(seconds), tonumber(cm) * 60 + tonumber(cs))
        end
    end)

    it("JosaRo 는 어떤 문자열에도 '로' 또는 '으로'를 돌려주고 한글 받침 규칙을 지킴", function()
        local ns = wow.load().ns
        math.randomseed(SEED)

        local function utf8(code)
            if code < 0x80 then return string.char(code) end
            if code < 0x800 then
                return string.char(0xC0 + math.floor(code / 64), 0x80 + code % 64)
            end
            if code < 0x10000 then
                return string.char(0xE0 + math.floor(code / 4096), 0x80 + math.floor(code / 64) % 64, 0x80 + code % 64)
            end
            return string.char(0xF0 + math.floor(code / 262144), 0x80 + math.floor(code / 4096) % 64,
                0x80 + math.floor(code / 64) % 64, 0x80 + code % 64)
        end

        local ranges = {
            { 0x20, 0x7E },       -- ASCII
            { 0xAC00, 0xD7A3 },   -- 한글 음절
            { 0x3131, 0x318E },   -- 한글 호환 자모
            { 0x4E00, 0x9FFF },   -- 한자
            { 0x1F300, 0x1F5FF }, -- 이모지
        }

        for _ = 1, 20000 do
            local parts, last = {}, nil
            for i = 1, math.random(0, 6) do
                local range = pick(ranges)
                last = math.random(range[1], range[2])
                parts[i] = utf8(last)
            end
            local word = table.concat(parts)
            -- 가끔 바이트를 잘라 깨진 UTF-8 도 넣는다
            if #word > 0 and math.random() < 0.1 then
                word = word:sub(1, #word - 1)
                last = nil
            end

            local josa = ns.JosaRo(word)
            assert(josa == "로" or josa == "으로", format("JosaRo(%q) = %s", word, tostring(josa)))

            if last and last >= 0xAC00 and last <= 0xD7A3 then
                local jong = (last - 0xAC00) % 28
                local expected = (jong == 0 or jong == 8) and "로" or "으로"
                assert.equal(expected, josa, format("JosaRo(%q)", word))
            end
        end
    end)
end)
