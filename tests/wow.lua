-- 테스트용 가짜 WoW 환경
--
-- wow.load() 는 SkyRoute.toc 에 적힌 순서대로 애드온 파일을 격리된 전역 환경에 불러오고,
-- 게임 상태(시간, 비행 여부, 비행 지도, 출력)를 조작하는 핸들을 돌려준다.
-- 매 테스트마다 새로 불러오므로 파일 수준의 지역 상태도 테스트 간에 섞이지 않는다.

local wow = {}

local ADDON = "SkyRoute"
local ROOT = (debug.getinfo(1, "S").source:match("^@(.*)tests/wow%.lua$") or "./")


--[[ 프레임 ]]

local function noop() end

-- 정의하지 않은 메서드는 아무것도 하지 않는 함수로 돌려준다 (화면 배치·색상 등).
-- WoW 메서드는 대문자로 시작하므로, 소문자로 시작하는 키는 일반 필드로 보고 nil.
local frameMeta = {
    __index = function(_, key)
        if type(key) == "string" and key:match("^%u") then
            return noop
        end
    end,
}

local function newFontString()
    local fs = setmetatable({}, frameMeta)
    function fs:SetText(text) self.text = text end
    function fs:GetText() return self.text end
    return fs
end

local function newFrame(game)
    local frame = setmetatable({ scripts = {}, events = {}, shown = true }, frameMeta)

    function frame:SetScript(name, fn) self.scripts[name] = fn end
    function frame:GetScript(name) return self.scripts[name] end
    function frame:RegisterEvent(event) self.events[event] = true end
    function frame:Show() self.shown = true end
    function frame:Hide() self.shown = false end
    function frame:IsShown() return self.shown end
    frame.CreateFontString = newFontString
    frame.GetPoint = function() return "TOP", nil, "TOP", 0, -160 end

    game.frames[#game.frames + 1] = frame
    return frame
end


--[[ 툴팁 ]]

local function newTooltip()
    local tip = setmetatable({ lines = {} }, frameMeta)
    function tip:ClearLines() self.lines = {} end
    function tip:AddLine(text) self.lines[#self.lines + 1] = text end
    function tip:AddDoubleLine(left, right) self.lines[#self.lines + 1] = left .. "\t" .. right end
    function tip:Show() self.shown = true end
    function tip:Hide() self.shown = false end
    return tip
end


--[[ 전역 환경 ]]

local function strtrim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- hooksecurefunc(name, hook) 또는 hooksecurefunc(table, name, hook)
local function makeHook(env)
    return function(a, b, c)
        local target, name, hook = env, a, b
        if type(a) == "table" then
            target, name, hook = a, b, c
        end
        local original = target[name]
        assert(type(original) == "function", "hooksecurefunc: " .. tostring(name) .. " 가 함수가 아님")
        target[name] = function(...)
            local results = { original(...) }
            hook(...)
            return unpack(results)
        end
    end
end

local function buildEnv(game)
    local env = {
        -- Lua 표준
        pairs = pairs, ipairs = ipairs, type = type, tostring = tostring, tonumber = tonumber,
        select = select, unpack = unpack, next = next, error = error, assert = assert,
        setmetatable = setmetatable, getmetatable = getmetatable, rawget = rawget,
        string = string, table = table, math = math,

        -- WoW Lua 확장
        format = string.format, floor = math.floor, ceil = math.ceil, abs = math.abs,
        min = math.min, max = math.max, sqrt = math.sqrt,
        strbyte = string.byte, strmatch = string.match, strlower = string.lower,
        strtrim = strtrim, tinsert = table.insert,

        Enum = { UIMapType = { Continent = 2, Zone = 3 } },
        SlashCmdList = {},
    }

    -- 프레임·UI
    env.CreateFrame = function() return newFrame(game) end
    env.UIParent = newFrame(game)
    env.GameTooltip = game.tooltip
    env.DEFAULT_CHAT_FRAME = {
        AddMessage = function(_, message) game.chat[#game.chat + 1] = message end,
    }
    env.hooksecurefunc = makeHook(env)

    -- 유닛·그룹·채팅
    env.GetTime = function() return game.now end
    env.UnitOnTaxi = function(unit) return unit == "player" and game.onTaxi end
    env.GetRealZoneText = function() return game.zone end
    env.IsInGroup = function() return game.group ~= nil end
    env.IsInRaid = function() return game.group == "raid" end
    env.SendChatMessage = function(message, channel)
        game.sent[#game.sent + 1] = { message = message, channel = channel }
    end

    -- 지도: 플레이어 지역(1) → 대륙(10)
    env.C_Map = {
        GetBestMapForUnit = function() return 1 end,
        GetMapInfo = function(mapID)
            if mapID == 1 then return { mapType = 3, parentMapID = game.continent } end
            if mapID == game.continent then return { mapType = 2, parentMapID = 0 } end
        end,
    }

    -- 비행 지도: game.taxi = { nodes = { {name, x, y, type}, ... }, routes = { [dest] = {slot, ...} } }
    local function node(slot)
        return game.taxi and game.taxi.nodes[slot]
    end
    env.NumTaxiNodes = function() return game.taxi and #game.taxi.nodes or 0 end
    env.TaxiNodeName = function(slot) return node(slot).name end
    env.TaxiNodePosition = function(slot) return node(slot).x, node(slot).y end
    env.TaxiNodeGetType = function(slot) return node(slot) and node(slot).type or "NONE" end
    env.GetNumRoutes = function(dest)
        local route = game.taxi.routes[dest]
        return route and #route - 1 or 0
    end
    env.TaxiGetNodeSlot = function(dest, hop, isSource)
        local route = game.taxi.routes[dest]
        return route[isSource and hop or hop + 1]
    end

    -- 훅 대상 (원본은 아무것도 하지 않음)
    env.TakeTaxiNode = noop
    env.TaxiRequestEarlyLanding = noop
    env.AcceptBattlefieldPort = noop
    env.TaxiNodeOnButtonEnter = noop
    env.C_SummonInfo = { ConfirmSummon = noop }

    -- 대화창: game.gossip = { guid = "Creature-...", options = { {name, gossipOptionID, orderIndex}, ... } }
    env.UnitGUID = function(unit)
        return unit == "npc" and game.gossip and game.gossip.guid or nil
    end
    env.C_GossipInfo = {
        GetOptions = function() return game.gossip and game.gossip.options or {} end,
        SelectOptionByIndex = noop,
        SelectOption = noop,
    }

    return env
end


--[[ 불러오기 ]]

local function tocFiles()
    local files = {}
    for line in io.lines(ROOT .. ADDON .. ".toc") do
        line = strtrim(line)
        if line ~= "" and not line:match("^#") then
            files[#files + 1] = line
        end
    end
    return files
end

-- 핸들 메서드
local Game = {}
Game.__index = Game

function Game:fire(event, ...)
    for _, frame in ipairs(self.frames) do
        local handler = frame.events[event] and frame.scripts.OnEvent
        if handler then
            handler(frame, event, ...)
        end
    end
end

-- 시간을 흘리며 보이는 프레임의 OnUpdate 를 step 간격으로 호출
function Game:advance(seconds, step)
    step = step or 0.05
    local remaining = seconds
    while remaining > 1e-9 do
        local dt = math.min(step, remaining)
        self.now = self.now + dt
        remaining = remaining - dt
        for _, frame in ipairs({ unpack(self.frames) }) do
            local update = frame.shown and frame.scripts.OnUpdate
            if update then
                update(frame, dt)
            end
        end
    end
end

-- 비행 지도를 연다. current 는 현재 위치 슬롯
function Game:openTaxiMap(taxi)
    self.taxi = taxi
    self:fire("TAXIMAP_OPENED")
end

function Game:closeTaxiMap()
    self.taxi = nil
end

-- 대화창을 열고 선택지를 고른다 (Blizzard 대화창처럼 orderIndex 로 선택)
function Game:selectGossip(gossip, index)
    self.gossip = gossip
    self.env.C_GossipInfo.SelectOptionByIndex(index)
end

function Game:call(name, ...)
    return self.env[name](...)
end

function Game:slash(input)
    return self.env.SlashCmdList.SKYROUTE(input)
end

function Game:lastChat()
    return self.chat[#self.chat]
end

-- 색상 코드를 걷어낸 채팅 기록
function Game:plainChat()
    local lines = {}
    for i, message in ipairs(self.chat) do
        lines[i] = message:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    end
    return lines
end

-- 디버그 출력(ns.Debug 의 회색 줄)만 접두어를 떼고 색상 코드를 걷어낸 기록
function Game:debugChat()
    local plain, lines = self:plainChat(), {}
    for i, message in ipairs(self.chat) do
        if message:find("|cff888888", 1, true) then
            lines[#lines + 1] = (plain[i]:gsub("^SkyRoute ", ""))
        end
    end
    return lines
end

-- savedVariables: 이전 세션에서 저장된 SkyRouteDB (없으면 nil)
function wow.load(savedVariables)
    local game = setmetatable({
        frames = {},
        chat = {},
        sent = {},
        tooltip = newTooltip(),
        now = 1000,
        onTaxi = false,
        zone = "듀로타",
        continent = 10,
        group = nil,
    }, Game)

    local env = buildEnv(game)
    env.SkyRouteDB = savedVariables
    game.env = env

    local ns = {}
    game.ns = ns
    for _, file in ipairs(tocFiles()) do
        local chunk = assert(loadfile(ROOT .. file))
        setfenv(chunk, env)
        chunk(ADDON, ns)
    end

    game:fire("ADDON_LOADED", ADDON)
    game:fire("PLAYER_LOGIN")
    return game
end

return wow
