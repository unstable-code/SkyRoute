local wow = require("tests.wow")

describe("Core", function()
    local game, ns

    before_each(function()
        game = wow.load()
        ns = game.ns
    end)

    describe("FormatDuration", function()
        it("1분 미만은 초만 표시", function()
            assert.equal("0초", ns.FormatDuration(0))
            assert.equal("42초", ns.FormatDuration(42))
        end)

        it("나누어떨어지는 분은 분만 표시", function()
            assert.equal("1분", ns.FormatDuration(60))
            assert.equal("10분", ns.FormatDuration(600))
        end)

        it("분과 초를 함께 표시", function()
            assert.equal("3분 5초", ns.FormatDuration(185))
        end)

        it("소수점은 반올림", function()
            assert.equal("1분", ns.FormatDuration(59.5))
            assert.equal("59초", ns.FormatDuration(59.4))
        end)
    end)

    describe("FormatClock", function()
        it("분:초 두 자리로 표시", function()
            assert.equal("0:00", ns.FormatClock(0))
            assert.equal("1:05", ns.FormatClock(65))
            assert.equal("12:30", ns.FormatClock(750))
        end)

        it("소수점은 내림", function()
            assert.equal("1:05", ns.FormatClock(65.9))
        end)
    end)

    describe("JosaRo", function()
        it("받침이 없으면 '로'", function()
            assert.equal("로", ns.JosaRo("썬더 블러프"))
            assert.equal("로", ns.JosaRo("오그리마"))
        end)

        it("ㄹ 받침이면 '로'", function()
            assert.equal("로", ns.JosaRo("하늘"))
            assert.equal("로", ns.JosaRo("루테란 마을"))
        end)

        it("그 외 받침이면 '으로'", function()
            assert.equal("으로", ns.JosaRo("달의 숲"))
            assert.equal("으로", ns.JosaRo("실버문"))
        end)

        it("한글로 끝나지 않으면 '로'", function()
            assert.equal("로", ns.JosaRo("Orgrimmar"))
            assert.equal("로", ns.JosaRo("3"))
            assert.equal("로", ns.JosaRo(""))
            assert.equal("로", ns.JosaRo("오그리마 (Durotar)"))
        end)
    end)

    describe("저장 데이터", function()
        it("처음 불러오면 기본값을 채움", function()
            assert.same({ chat = true, party = false, debug = false }, ns.db.settings)
            assert.same({}, ns.db.routes)
            assert.equal(game.env.SkyRouteDB, ns.db)
        end)

        it("기존 값은 유지하고 빠진 값만 채움", function()
            game = wow.load({ settings = { party = true }, routes = { ["a>b"] = 30 } })
            ns = game.ns
            assert.same({ chat = true, party = true, debug = false }, ns.db.settings)
            assert.equal(30, ns.GetDuration("a", "b"))
        end)

        it("다른 애드온의 ADDON_LOADED 는 무시", function()
            local db = ns.db
            game:fire("ADDON_LOADED", "OtherAddon")
            assert.equal(db, ns.db)
        end)

        it("경로별 소요 시간을 기록하고 조회", function()
            assert.is_nil(ns.GetDuration("a", "b"))
            ns.SetDuration("a", "b", 95)
            assert.equal(95, ns.GetDuration("a", "b"))
            assert.is_nil(ns.GetDuration("b", "a"))
        end)
    end)

    describe("출력", function()
        it("채팅 안내를 끄면 일반 출력은 숨기고 강제 출력만 표시", function()
            ns.db.settings.chat = false
            ns.Print("일반")
            ns.Print("강제", true)
            assert.same({ "SkyRoute 강제" }, game:plainChat())
        end)

        it("디버그 출력은 debug 설정이 켜져 있을 때만", function()
            ns.Debug("숨김 %d", 1)
            ns.db.settings.debug = true
            ns.Debug("표시 %d", 2)
            assert.same({ "SkyRoute 표시 2" }, game:plainChat())
        end)
    end)
end)
