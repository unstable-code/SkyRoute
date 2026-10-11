local wow = require("tests.wow")
local fixtures = require("tests.fixtures")

local ORGRIMMAR_KEY = "10:0.500:0.300"
local CROSSROADS_KEY = "10:0.500:0.500"
local THUNDER_BLUFF_KEY = "10:0.500:0.900"

-- 비행 지도에서 목적지를 고르고 지도를 닫는다 (이륙은 하지 않음)
local function chooseDestination(game, dest)
    game:openTaxiMap(fixtures.kalimdor())
    game:call("TakeTaxiNode", dest)
    game:closeTaxiMap()
end

-- 목적지를 골라 이륙하고 seconds 동안 비행한 뒤 추적 중인 비행을 돌려준다 (착륙하지 않음)
local function takeOff(game, dest, seconds)
    chooseDestination(game, dest)
    game.onTaxi = true
    game:advance(seconds)
    return game.ns.GetFlight()
end

-- 목적지를 골라 이륙하고 seconds 동안 비행한 뒤 착륙.
-- during 이 있으면 이륙 후 at 초에 실행한다 (조기 착륙·소환 등)
local function fly(game, dest, seconds, at, during)
    chooseDestination(game, dest)
    game:advance(0.5)
    game.onTaxi = true
    if during then
        game:advance(at)
        during()
        game:advance(seconds - at)
    else
        game:advance(seconds)
    end
    game.onTaxi = false
    game:advance(0.5)
end

describe("비행 추적", function()
    local game, ns

    before_each(function()
        game = wow.load()
        ns = game.ns
    end)

    it("정상 비행을 기록", function()
        fly(game, fixtures.THUNDER_BLUFF, 95)
        assert.equal(95, ns.GetDuration(ORGRIMMAR_KEY, THUNDER_BLUFF_KEY))
        assert.is_nil(ns.GetFlight())
    end)

    it("처음 가는 경로는 측정 안내 후 기록 안내", function()
        fly(game, fixtures.THUNDER_BLUFF, 95)
        local chat = game:plainChat()
        assert.equal("SkyRoute 처음 비행하는 경로입니다. 오그리마 → 썬더 블러프 소요 시간을 측정합니다.", chat[1])
        assert.equal("SkyRoute 오그리마 → 썬더 블러프 경로를 기록했습니다: 1분 35초", chat[2])
    end)

    it("기존 기록과 2초 이상 차이 나면 갱신 안내", function()
        fly(game, fixtures.THUNDER_BLUFF, 95)
        fly(game, fixtures.THUNDER_BLUFF, 100)
        assert.equal(100, ns.GetDuration(ORGRIMMAR_KEY, THUNDER_BLUFF_KEY))
        assert.equal("SkyRoute 썬더 블러프 도착 시간을 1분 35초에서 1분 40초로 갱신했습니다.", game:plainChat()[3])
    end)

    it("기존 기록과 비슷하면 도착 안내만", function()
        fly(game, fixtures.THUNDER_BLUFF, 95)
        fly(game, fixtures.THUNDER_BLUFF, 96)
        assert.equal(96, ns.GetDuration(ORGRIMMAR_KEY, THUNDER_BLUFF_KEY))
        assert.equal("SkyRoute 썬더 블러프 도착 (1분 36초)", game:plainChat()[3])
    end)

    it("이륙하지 못하면 10초 뒤 추적을 포기하고 기록하지 않음", function()
        chooseDestination(game, fixtures.THUNDER_BLUFF)
        game:advance(9)
        assert.equal("pending", ns.GetFlight().state)
        game:advance(2)
        assert.is_nil(ns.GetFlight())

        -- 나중에 다른 이유로 비행 상태가 되어도 기록하지 않음
        game.onTaxi = true
        game:advance(30)
        game.onTaxi = false
        game:advance(1)
        assert.same({}, ns.db.routes)
    end)

    it("현재 위치를 모르면 추적하지 않음", function()
        local taxi = fixtures.kalimdor()
        taxi.nodes[1].type = "REACHABLE"
        game:openTaxiMap(taxi)
        game:call("TakeTaxiNode", fixtures.THUNDER_BLUFF)
        assert.is_nil(ns.GetFlight())
    end)

    describe("중단", function()
        -- 이륙 후 20초에 interrupt 를 실행하고 30초에 착륙
        local function interruptedFlight(interrupt)
            fly(game, fixtures.THUNDER_BLUFF, 30, 20, interrupt)
        end

        local function earlyLanding()
            game:call("TaxiRequestEarlyLanding")
        end

        it("소환을 수락하면 기록하지 않음", function()
            interruptedFlight(function() game.env.C_SummonInfo.ConfirmSummon() end)
            assert.same({}, ns.db.routes)
            assert.equal("SkyRoute 소환을 수락해 비행 기록을 중단합니다.", game:plainChat()[2])
        end)

        it("전장에 입장하면 기록하지 않음", function()
            interruptedFlight(function() game:call("AcceptBattlefieldPort", 1, true) end)
            assert.same({}, ns.db.routes)
        end)

        it("전장 입장을 거절하면 그대로 기록", function()
            interruptedFlight(function() game:call("AcceptBattlefieldPort", 1, false) end)
            assert.equal(30, ns.GetDuration(ORGRIMMAR_KEY, THUNDER_BLUFF_KEY))
        end)

        it("조기 착륙하면 기록하지 않고 내릴 정류장을 안내", function()
            interruptedFlight(earlyLanding)
            assert.same({}, ns.db.routes)
            assert.equal("SkyRoute 조기 착륙을 요청해 비행 기록을 중단합니다.", game:plainChat()[2])
        end)

        it("기록이 있으면 조기 착륙 시 다음 정류장을 안내", function()
            ns.SetDuration(ORGRIMMAR_KEY, THUNDER_BLUFF_KEY, 120)
            interruptedFlight(earlyLanding)
            assert.equal(120, ns.GetDuration(ORGRIMMAR_KEY, THUNDER_BLUFF_KEY))
            assert.equal("SkyRoute 조기 착륙을 요청해 비행 기록을 중단합니다. 크로스로드에 내릴 예정입니다.",
                game:plainChat()[1])
        end)

        it("비행 중이 아닐 때의 조기 착륙 요청은 무시", function()
            chooseDestination(game, fixtures.THUNDER_BLUFF)
            earlyLanding()
            assert.is_nil(ns.GetFlight().interrupted)
            assert.is_nil(ns.GetFlight().landing)
        end)

        describe("내릴 정류장이 최종 목적지면 그대로 기록", function()
            it("마지막 구간에서 누름", function()
                ns.SetDuration(ORGRIMMAR_KEY, THUNDER_BLUFF_KEY, 120)
                fly(game, fixtures.THUNDER_BLUFF, 118, 60, earlyLanding)
                assert.equal(118, ns.GetDuration(ORGRIMMAR_KEY, THUNDER_BLUFF_KEY))
                assert.equal("SkyRoute 썬더 블러프에 그대로 내리므로 비행 기록을 계속합니다.", game:plainChat()[1])
            end)

            it("도착 15초 전 이후에 누름", function()
                ns.SetDuration(ORGRIMMAR_KEY, THUNDER_BLUFF_KEY, 120)
                fly(game, fixtures.THUNDER_BLUFF, 121, 110, earlyLanding)
                assert.equal(121, ns.GetDuration(ORGRIMMAR_KEY, THUNDER_BLUFF_KEY))
            end)

            it("직항은 기록이 없어도", function()
                fly(game, fixtures.CROSSROADS, 30, 5, earlyLanding)
                assert.equal(30, ns.GetDuration(ORGRIMMAR_KEY, CROSSROADS_KEY))
            end)

            it("기록이 없어도 지역 변경으로 마지막 구간임을 알면", function()
                fly(game, fixtures.THUNDER_BLUFF, 90, 40, function()
                    game.zone = "불모의 땅"
                    game:fire("ZONE_CHANGED_NEW_AREA")
                    earlyLanding()
                end)
                assert.equal(90, ns.GetDuration(ORGRIMMAR_KEY, THUNDER_BLUFF_KEY))
            end)
        end)

        it("다시 눌러도 처음 요청한 착륙 지점과 안내를 유지", function()
            ns.SetDuration(ORGRIMMAR_KEY, THUNDER_BLUFF_KEY, 120)
            takeOff(game, fixtures.THUNDER_BLUFF, 20)
            earlyLanding()
            game:advance(40)
            earlyLanding()

            assert.equal(fixtures.CROSSROADS, ns.GetFlight().landing)
            assert.equal(1, #game.chat)
        end)
    end)

    describe("LandingStop", function()
        it("직항은 현재 정류장을 몰라도 목적지", function()
            assert.equal(2, ns.LandingStop(takeOff(game, fixtures.CROSSROADS, 1)))
        end)

        it("경유 경로에서 현재 정류장을 모르면 nil", function()
            assert.is_nil(ns.LandingStop(takeOff(game, fixtures.THUNDER_BLUFF, 1)))
        end)

        it("경유 경로의 첫 구간이면 다음 정류장", function()
            ns.SetDuration(ORGRIMMAR_KEY, THUNDER_BLUFF_KEY, 120)
            assert.equal(2, ns.LandingStop(takeOff(game, fixtures.THUNDER_BLUFF, 20)))
        end)

        it("마지막 구간이나 도착 직전이면 목적지", function()
            ns.SetDuration(ORGRIMMAR_KEY, THUNDER_BLUFF_KEY, 120)
            local flight = takeOff(game, fixtures.THUNDER_BLUFF, 60)
            assert.equal(3, ns.LandingStop(flight))
            game:advance(50)
            assert.equal(3, ns.LandingStop(flight))
        end)
    end)

    describe("지역 변경", function()
        it("앞으로 남은 정류장의 지역에 들어서면 기준점을 옮김", function()
            chooseDestination(game, fixtures.THUNDER_BLUFF)
            game.onTaxi = true
            game:advance(1)

            game.zone = "불모의 땅"
            game:fire("ZONE_CHANGED_NEW_AREA")
            assert.equal(2, ns.GetFlight().anchor)
            assert.equal(2, ns.CurrentStop(ns.GetFlight()))
        end)

        it("이미 지난 정류장의 지역으로 돌아가도 기준점은 그대로", function()
            chooseDestination(game, fixtures.THUNDER_BLUFF)
            game.onTaxi = true
            game:advance(1)

            game.zone = "불모의 땅"
            game:fire("ZONE_CHANGED_NEW_AREA")
            game.zone = "듀로타"
            game:fire("ZONE_CHANGED_NEW_AREA")
            assert.equal(2, ns.GetFlight().anchor)
        end)
    end)

    describe("파티 알림", function()
        before_each(function()
            ns.db.settings.party = true
        end)

        it("파티 중이면 이륙할 때 목적지를 알림", function()
            game.group = "party"
            fly(game, fixtures.THUNDER_BLUFF, 10)
            assert.same({ { message = "썬더 블러프로 비행합니다.", channel = "PARTY" } }, game.sent)
        end)

        it("공격대나 솔로면 알리지 않음", function()
            game.group = "raid"
            fly(game, fixtures.THUNDER_BLUFF, 10)
            game.group = nil
            fly(game, fixtures.THUNDER_BLUFF, 10)
            assert.same({}, game.sent)
        end)
    end)
end)

describe("타이머 창", function()
    local game, ns

    before_each(function()
        game = wow.load()
        ns = game.ns
    end)

    it("이륙하면 표시하고 착륙하면 숨김", function()
        chooseDestination(game, fixtures.THUNDER_BLUFF)
        assert.is_false(ns.IsTimerShown())
        game.onTaxi = true
        game:advance(1)
        assert.is_true(ns.IsTimerShown())
        game.onTaxi = false
        game:advance(1)
        assert.is_false(ns.IsTimerShown())
    end)

    it("비행 지도 목적지 툴팁에 기록된 비행 시간을 표시", function()
        ns.SetDuration(ORGRIMMAR_KEY, THUNDER_BLUFF_KEY, 95)
        game:openTaxiMap(fixtures.kalimdor())
        game:call("TaxiNodeOnButtonEnter", { GetID = function() return fixtures.THUNDER_BLUFF end })
        assert.same({ "비행 시간\t1분 35초" }, game.tooltip.lines)
    end)

    it("기록이 없으면 '기록 없음'", function()
        game:openTaxiMap(fixtures.kalimdor())
        game:call("TaxiNodeOnButtonEnter", { GetID = function() return fixtures.CROSSROADS end })
        assert.same({ "비행 시간\t기록 없음" }, game.tooltip.lines)
    end)

    it("갈 수 없는 노드는 툴팁을 건드리지 않음", function()
        game:openTaxiMap(fixtures.kalimdor())
        game:call("TaxiNodeOnButtonEnter", { GetID = function() return fixtures.RATCHET end })
        assert.same({}, game.tooltip.lines)
    end)
end)

describe("슬래시 명령", function()
    local game, ns

    before_each(function()
        game = wow.load()
        ns = game.ns
    end)

    it("/skyroute 와 /skr 를 등록", function()
        assert.equal("/skyroute", game.env.SLASH_SKYROUTE1)
        assert.equal("/skr", game.env.SLASH_SKYROUTE2)
    end)

    it("설정을 켜고 끔", function()
        game:slash("party")
        assert.is_true(ns.db.settings.party)
        game:slash(" PARTY ")
        assert.is_false(ns.db.settings.party)
    end)

    it("show / hide 로 타이머 창 표시", function()
        game:slash("show")
        assert.is_true(ns.IsTimerShown())
        game:slash("hide")
        assert.is_false(ns.IsTimerShown())
    end)

    it("알 수 없는 명령이면 안내 후 도움말", function()
        game:slash("foo")
        local chat = game:plainChat()
        assert.equal("SkyRoute 알 수 없는 명령: foo", chat[1])
        assert.equal("SkyRoute 명령어 (/skyroute 또는 /skr):", chat[2])
    end)
end)
