-- TaxiTimer: 슬래시 명령

local _, ns = ...

local function toggle(setting, onText, offText)
    local settings = ns.db.settings
    settings[setting] = not settings[setting]
    ns.Print(settings[setting] and onText or offText, true)
end

local commands = {}
local order = {}

local function command(name, usage, handler)
    commands[name] = handler
    order[#order + 1] = { name = name, usage = usage }
end

command("show", "타이머 창을 표시합니다 (위치 조정용).", function()
    ns.ShowTimer()
    ns.Print("타이머 창을 표시했습니다. 드래그해서 옮기세요.", true)
end)

command("hide", "타이머 창을 숨깁니다.", function()
    ns.HideTimer()
end)

command("reset", "타이머 창 위치를 기본값으로 되돌립니다.", function()
    ns.ResetTimerPosition()
    ns.Print("타이머 창 위치를 초기화했습니다.", true)
end)

command("chat", "채팅창 안내 출력을 켜고 끕니다.", function()
    toggle("chat", "채팅창 안내를 켰습니다.", "채팅창 안내를 껐습니다.")
end)

command("party", "이륙 시 파티 채널 목적지 알림을 켜고 끕니다.", function()
    toggle("party", "파티 채널 목적지 알림을 켰습니다.", "파티 채널 목적지 알림을 껐습니다.")
end)

command("debug", "디버그 출력을 켜고 끕니다.", function()
    toggle("debug", "디버그 출력을 켰습니다.", "디버그 출력을 껐습니다.")
end)

command("help", "이 도움말을 표시합니다.", function()
    ns.Print("명령어 (/taxitimer 또는 /taxi):", true)
    for _, entry in ipairs(order) do
        ns.Print(format("  %s – %s", ns.Em(entry.name), entry.usage), true)
    end
end)

SLASH_TAXITIMER1 = "/taxitimer"
SLASH_TAXITIMER2 = "/taxi"

SlashCmdList.TAXITIMER = function(input)
    local name = strlower(strtrim(input or ""))
    local handler = commands[name]

    if handler then
        handler()
    else
        if name ~= "" then
            ns.Print(format("알 수 없는 명령: %s", ns.Em(name)), true)
        end
        commands.help()
    end
end
