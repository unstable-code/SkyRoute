local wow = require("tests.wow")
local fixtures = require("tests.fixtures")

describe("Taxi", function()
    local game, ns

    before_each(function()
        game = wow.load()
        ns = game.ns
        game:openTaxiMap(fixtures.kalimdor())
    end)

    describe("NodeLabel", function()
        local function label(full)
            game.taxi.nodes[1].name = full
            return { ns.NodeLabel(1) }
        end

        it("'이름 (지역)' 형식", function()
            assert.same({ "오그리마", "듀로타" }, label("오그리마 (듀로타)"))
        end)

        it("'이름, 지역' 형식", function()
            assert.same({ "Orgrimmar", "Durotar" }, label("Orgrimmar, Durotar"))
        end)

        it("지역이 없으면 이름이 곧 지역", function()
            assert.same({ "달의 숲", "달의 숲" }, label("달의 숲"))
        end)
    end)

    describe("NodeKey", function()
        it("대륙과 좌표로 노드를 식별", function()
            assert.equal("10:0.500:0.300", ns.NodeKey(fixtures.ORGRIMMAR))
        end)

        it("대륙이 다르면 같은 좌표라도 다른 키", function()
            local kalimdor = ns.NodeKey(fixtures.ORGRIMMAR)
            game.continent = 11
            game:openTaxiMap(fixtures.kalimdor())
            assert.are_not.equal(kalimdor, ns.NodeKey(fixtures.ORGRIMMAR))
        end)
    end)

    describe("FindCurrentSlot", function()
        it("현재 위치 노드를 찾음", function()
            assert.equal(fixtures.ORGRIMMAR, ns.FindCurrentSlot())
        end)

        it("현재 위치가 없으면 nil", function()
            game.taxi.nodes[1].type = "REACHABLE"
            assert.is_nil(ns.FindCurrentSlot())
        end)
    end)

    describe("BuildPath", function()
        it("경유 정류장과 누적 거리를 계산", function()
            local path = ns.BuildPath(fixtures.THUNDER_BLUFF)
            assert.equal(3, #path.stops)
            assert.same({ "오그리마", "크로스로드", "썬더 블러프" },
                { path.stops[1].name, path.stops[2].name, path.stops[3].name })
            assert.equal("불모의 땅", path.stops[2].zone)
            assert.near(0, path.stops[1].at, 1e-9)
            assert.near(0.2, path.stops[2].at, 1e-9)
            assert.near(0.6, path.stops[3].at, 1e-9)
            assert.near(0.6, path.length, 1e-9)
        end)

        it("경로가 없으면 nil", function()
            assert.is_nil(ns.BuildPath(fixtures.RATCHET))
        end)

        it("슬롯 번호가 범위를 벗어나면 nil", function()
            game.taxi.routes[3] = { 1, 99 }
            assert.is_nil(ns.BuildPath(fixtures.THUNDER_BLUFF))
        end)

        it("경로 API 가 없는 클라이언트면 nil", function()
            game.env.GetNumRoutes = nil
            assert.is_nil(ns.BuildPath(fixtures.THUNDER_BLUFF))
        end)
    end)
end)

describe("CurrentStop", function()
    local game, ns
    local path

    before_each(function()
        game = wow.load()
        ns = game.ns
        path = {
            length = 30,
            stops = {
                { name = "A", zone = "a", at = 0 },
                { name = "B", zone = "b", at = 10 },
                { name = "C", zone = "c", at = 30 },
            },
        }
    end)

    local function flightAt(elapsed, expected, anchor)
        return { path = path, started = game.now - elapsed, expected = expected, anchor = anchor }
    end

    it("경로 정보가 없으면 nil", function()
        assert.is_nil(ns.CurrentStop({ started = game.now, expected = 60 }))
    end)

    it("기록도 기준점도 없으면 nil", function()
        assert.is_nil(ns.CurrentStop(flightAt(10, nil, nil)))
    end)

    it("경과 시간 비율로 구간을 추정", function()
        assert.equal(1, ns.CurrentStop(flightAt(0, 60)))
        assert.equal(1, ns.CurrentStop(flightAt(19, 60)))  -- 9.5 / 30
        assert.equal(2, ns.CurrentStop(flightAt(20, 60)))  -- 10 / 30
    end)

    it("도착 15초 전부터는 목적지", function()
        assert.equal(2, ns.CurrentStop(flightAt(44, 60)))
        assert.equal(3, ns.CurrentStop(flightAt(45, 60)))
    end)

    it("기록보다 오래 걸려도 목적지", function()
        assert.equal(3, ns.CurrentStop(flightAt(120, 60)))
    end)

    it("지역 변경 기준점이 시간 추정보다 앞서면 기준점", function()
        assert.equal(2, ns.CurrentStop(flightAt(0, 60, 2)))
        assert.equal(2, ns.CurrentStop(flightAt(5, nil, 2)))
    end)
end)
