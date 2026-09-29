std = "lua51"
max_line_length = false

globals = {
    -- 저장 데이터
    "TaxiTimerDB",
    -- 슬래시 명령 등록
    "SLASH_TAXITIMER1", "SLASH_TAXITIMER2", "SlashCmdList",
}

read_globals = {
    -- WoW Lua 확장 함수
    "format", "floor", "ceil", "abs", "min", "sqrt",
    "strbyte", "strmatch", "strlower", "strtrim", "tinsert",
    -- 프레임·UI
    "CreateFrame", "UIParent", "GameTooltip", "DEFAULT_CHAT_FRAME", "BackdropTemplateMixin",
    "hooksecurefunc", "Enum", "C_Map", "C_SummonInfo",
    -- 유닛·그룹·채팅
    "GetTime", "UnitOnTaxi", "GetRealZoneText", "IsInGroup", "IsInRaid", "SendChatMessage",
    -- 비행 지도
    "NumTaxiNodes", "TaxiNodeName", "TaxiNodePosition", "TaxiNodeGetType",
    "GetNumRoutes", "TaxiGetNodeSlot", "TakeTaxiNode", "TaxiRequestEarlyLanding",
    "TaxiNodeOnButtonEnter", "AcceptBattlefieldPort",
}
