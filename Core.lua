-- TaxiTimer: 공용 기반 (이벤트 디스패치, 저장 데이터, 출력, 문자열 헬퍼)

local ADDON, ns = ...

local DEFAULTS = {
    settings = {
        chat = true,   -- 채팅창 안내 출력
        party = false, -- 이륙 시 파티 채널에 목적지 알림
        debug = false,
    },
    -- 경로 키("출발>도착") → 마지막으로 측정된 소요 시간(초)
    routes = {},
}

local function fillDefaults(target, defaults)
    for key, value in pairs(defaults) do
        if type(value) == "table" then
            if type(target[key]) ~= "table" then
                target[key] = {}
            end
            fillDefaults(target[key], value)
        elseif target[key] == nil then
            target[key] = value
        end
    end
end


--[[ 이벤트 ]]

local handlers = {}
local eventFrame = CreateFrame("Frame")

eventFrame:SetScript("OnEvent", function(_, event, ...)
    for _, handler in ipairs(handlers[event]) do
        handler(...)
    end
end)

function ns.On(event, handler)
    if not handlers[event] then
        handlers[event] = {}
        eventFrame:RegisterEvent(event)
    end
    tinsert(handlers[event], handler)
end

ns.On("ADDON_LOADED", function(name)
    if name ~= ADDON then return end

    TaxiTimerDB = TaxiTimerDB or {}
    fillDefaults(TaxiTimerDB, DEFAULTS)
    ns.db = TaxiTimerDB
end)


--[[ 경로 기록 ]]

local function routeKey(fromKey, toKey)
    return fromKey .. ">" .. toKey
end

function ns.GetDuration(fromKey, toKey)
    return ns.db.routes[routeKey(fromKey, toKey)]
end

function ns.SetDuration(fromKey, toKey, seconds)
    ns.db.routes[routeKey(fromKey, toKey)] = seconds
end


--[[ 출력 ]]

local PREFIX = "|cff4fc3f7TaxiTimer|r "

-- force: 채팅 출력을 꺼 두었어도 표시 (명령 응답 등)
function ns.Print(message, force)
    if force or ns.db.settings.chat then
        DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. message)
    end
end

function ns.Debug(pattern, ...)
    if ns.db and ns.db.settings.debug then
        DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. "|cff888888" .. format(pattern, ...) .. "|r")
    end
end

function ns.Em(text)
    return "|cffffd100" .. tostring(text) .. "|r"
end


--[[ 시간 표기 ]]

-- 채팅·툴팁용: "3분 5초", "3분", "42초"
function ns.FormatDuration(seconds)
    seconds = floor(seconds + 0.5)
    local minutes, rest = floor(seconds / 60), seconds % 60

    if minutes == 0 then
        return format("%d초", rest)
    elseif rest == 0 then
        return format("%d분", minutes)
    end
    return format("%d분 %d초", minutes, rest)
end

-- 타이머 창용: "3:05"
function ns.FormatClock(seconds)
    seconds = floor(seconds)
    return format("%d:%02d", floor(seconds / 60), seconds % 60)
end


--[[ 한국어 조사 ]]

-- 마지막 글자가 한글 음절이면 종성 번호(0 = 받침 없음, 8 = ㄹ)를, 아니면 nil 을 돌려준다.
-- 한글 음절은 UTF-8 에서 항상 3바이트(0xE0~0xEF 로 시작)이다.
local function finalConsonant(word)
    local length = #word
    if length < 3 then return nil end

    local b1, b2, b3 = strbyte(word, length - 2, length)
    if b1 < 0xE0 or b1 > 0xEF then return nil end

    local code = (b1 % 16) * 4096 + (b2 % 64) * 64 + (b3 % 64)
    if code < 0xAC00 or code > 0xD7A3 then return nil end

    return (code - 0xAC00) % 28
end

-- "로" / "으로": 받침이 없거나 ㄹ 받침이면 "로"
function ns.JosaRo(word)
    local jong = finalConsonant(word)
    if jong == nil or jong == 0 or jong == 8 then
        return "로"
    end
    return "으로"
end
