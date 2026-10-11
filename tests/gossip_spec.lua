local wow = require("tests.wow")
local fixtures = require("tests.fixtures")

-- 달의 숲 드루이드 히포그리프 (NPC ID 는 게임 안에서 확인 전의 가정값)
local HIPPOGRYPH = {
    guid = "Creature-0-4170-1-25-11798-00001A2B3C",
    options = {
        { name = "썬더 블러프로 가고 싶습니다.", gossipOptionID = 4321, orderIndex = 1 },
    },
}

describe("대화 비행 진단", function()
    local game, ns

    before_each(function()
        game = wow.load()
        ns = game.ns
        ns.db.settings.debug = true
    end)

    it("대화 선택 시 NPC ID 와 선택지를 출력", function()
        game:selectGossip(HIPPOGRYPH, 1)
        assert.same({ '대화 선택: NPC 11798, 선택지 "썬더 블러프로 가고 싶습니다." (id 4321)' }, game:debugChat())
    end)

    it("선택지 ID 로 고르면 ID 만 출력", function()
        game.gossip = HIPPOGRYPH
        game.env.C_GossipInfo.SelectOption(4321)
        assert.same({ '대화 선택: NPC 11798, 선택지 "?" (id 4321)' }, game:debugChat())
    end)

    it("대화 선택 뒤 비행 지도 없이 이륙·착륙하면 지역과 소요 시간을 출력", function()
        game.zone = "달의 숲"
        game:selectGossip(HIPPOGRYPH, 1)
        game:advance(1)
        game.onTaxi = true
        game:advance(0.5)
        game.zone = "멀고어"
        game:advance(120)
        game.onTaxi = false
        game:advance(0.5)

        local lines = game:debugChat()
        assert.equal(3, #lines)
        assert.matches("^비행 지도 없이 이륙: 대화 선택 1%.%d초 후, 지역 달의 숲$", lines[2])
        assert.equal("비행 지도 없이 착륙: 2분, 지역 멀고어", lines[3])
        assert.is_nil(ns.GetFlight())
    end)

    it("대화 선택 뒤 10초 안에 이륙하지 않으면 지켜보기를 그만둠", function()
        game:selectGossip(HIPPOGRYPH, 1)
        game:advance(11)
        game.onTaxi = true
        game:advance(5)
        assert.equal(1, #game:debugChat())
    end)

    it("비행 지도로 출발한 비행은 대화 비행으로 보지 않음", function()
        game:selectGossip(HIPPOGRYPH, 1)
        game:openTaxiMap(fixtures.kalimdor())
        game:call("TakeTaxiNode", fixtures.THUNDER_BLUFF)
        game:closeTaxiMap()
        game.onTaxi = true
        game:advance(5)

        for _, line in ipairs(game:debugChat()) do
            assert.is_nil(line:find("비행 지도 없이", 1, true))
        end
        assert.equal("flying", ns.GetFlight().state)
    end)

    it("디버그 출력이 꺼져 있으면 아무것도 출력하지 않음", function()
        ns.db.settings.debug = false
        game:selectGossip(HIPPOGRYPH, 1)
        game.onTaxi = true
        game:advance(5)
        game.onTaxi = false
        game:advance(0.5)
        assert.same({}, game.chat)
    end)
end)
