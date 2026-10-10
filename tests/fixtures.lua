-- 테스트용 비행 지도
--
-- 오그리마(현재 위치) → 크로스로드 → 썬더 블러프 경유 경로와 오그리마 → 크로스로드 직항.
-- 좌표는 대륙 지도 기준 정규화 값이며, 구간 길이는 0.2 와 0.4 (총 0.6).

local fixtures = {}

fixtures.ORGRIMMAR, fixtures.CROSSROADS, fixtures.THUNDER_BLUFF, fixtures.RATCHET = 1, 2, 3, 4

function fixtures.kalimdor()
    return {
        nodes = {
            { name = "오그리마 (듀로타)", x = 0.5, y = 0.3, type = "CURRENT" },
            { name = "크로스로드 (불모의 땅)", x = 0.5, y = 0.5, type = "REACHABLE" },
            { name = "썬더 블러프 (멀고어)", x = 0.5, y = 0.9, type = "REACHABLE" },
            { name = "톱니항 (불모의 땅)", x = 0.6, y = 0.5, type = "NONE" },
        },
        routes = {
            [2] = { 1, 2 },
            [3] = { 1, 2, 3 },
        },
    }
end

return fixtures
