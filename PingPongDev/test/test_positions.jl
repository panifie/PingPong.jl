using Test

macro position_constructor(side=Long, mm=Isolated)
    e = quote
        eid = :binance
        exc = getexchange!(eid)
        asset = d"BTC/USDT:USDT"
        pos_cash = exs.CurrencyCash(exc, "BTC")
        pos_cash_committed = exs.CurrencyCash(exc, "BTC")
        tiers = leverage_tiers(exc, asset.raw)
        pos = inst.Position{$side,ExchangeID{eid},$mm}(;
            asset,
            min_size=0.0,
            tiers=[tiers],
            this_tier=[first(values(tiers))],
            cash=pos_cash,
            cash_committed=pos_cash_committed,
        )
    end
    esc(e)
end

function test_position_constructor()
    @position_constructor()
    @test pos.status == [PositionClose()]
    @test pos.asset isa Derivative
    @test pos.timestamp == [DateTime(0)]
    @test pos.liquidation_price == [0.0]
    @test pos.entryprice == [0.0]
    @test pos.maintenance_margin == [0.0]
    @test pos.initial_margin == [0.0]
    @test pos.additional_margin == [0.0]
    @test pos.notional == [0.0]
    @test pos.cash isa CCash{ExchangeID{eid}}{:BTC}
    @test pos.cash_committed isa CCash{ExchangeID{eid}}{:BTC}
    @test pos.leverage == [1.0]
    @test pos.min_size isa Real
    @test pos.hedged == false
    @test pos.tiers isa Vector{LeverageTiersDict} && !isempty(pos.tiers[])
    @test pos.this_tier isa Vector{LeverageTier}

    # Test with custom values
    pos = inst.Position{Long,ExchangeID{eid},Isolated}(;
        status=[PositionOpen()],
        asset=asset,
        timestamp=[DateTime(1)],
        liquidation_price=[100.0],
        entryprice=[50.0],
        maintenance_margin=[20.0],
        initial_margin=[10.0],
        additional_margin=[5.0],
        notional=[1000.0],
        cash=pos_cash,
        cash_committed=pos_cash_committed,
        leverage=[2.0],
        min_size=0.01,
        hedged=true,
        tiers=[tiers],
        this_tier=[first(values(tiers))],
    )
    @test pos.status == [PositionOpen()]
    @test pos.asset == asset
    @test pos.timestamp == [DateTime(1)]
    @test pos.liquidation_price == [100.0]
    @test pos.entryprice == [50.0]
    @test pos.maintenance_margin == [20.0]
    @test pos.initial_margin == [10.0]
    @test pos.additional_margin == [5.0]
    @test pos.notional == [1000.0]
    @test pos.cash == pos_cash
    @test pos.cash_committed == pos_cash_committed
    @test pos.leverage == [2.0]
    @test pos.min_size == 0.01
    @test pos.hedged == true
    @test pos.tiers == [tiers]
    @test pos.this_tier == [first(values(tiers))]
    @test exchangeid(pos) == ExchangeID{eid}
end

function test_reset_function()
    @position_constructor()
    reset!(pos, Val(:full))
    @test pos.status == [PositionClose()]
    @test pos.timestamp == [DateTime(0)]
    @test pos.notional == [0.0]
    @test pos.leverage == [1.0]
    @test pos.liquidation_price == [0.0]
    @test pos.entryprice == [0.0]
    @test pos.maintenance_margin == [0.0]
    @test pos.initial_margin == [0.0]
    @test pos.additional_margin == [0.0]
    @test inst.cash(pos).value == 0.0
    @test committed(pos).value == 0.0

    reset!(pos)
    @test pos.status == [PositionClose()]
    @test pos.notional == [0.0]
    @test pos.liquidation_price == [0.0]
    @test pos.entryprice == [0.0]
    @test pos.maintenance_margin == [0.0]
    @test pos.initial_margin == [0.0]
    @test pos.additional_margin == [0.0]
    @test cash(pos) == 0.0
    @test committed(pos) == 0.0
end

function test_leverage_function()
    @position_constructor
    leverage!(pos, 2.0)
    @test pos.leverage == [2.0]
end

function test_maxleverage_function()
    @position_constructor()
    @test inst.maxleverage(pos) == pos.this_tier[].max_leverage
    @test inst.maxleverage(pos, 1000.0) == inst.tier(pos, 1000.0)[2].max_leverage
end

function test_status_function()
    @position_constructor()
    @test_throws AssertionError inst._status!(pos, PositionClose())
    @test pos.status == [PositionClose()]
    inst._status!(pos, PositionOpen())
    @test pos.status == [PositionOpen()]
end

function test_isopen_function()
    @position_constructor()
    @test !isopen(pos)
    inst._status!(pos, PositionOpen())
    @test isopen(pos)
end

function test_islong_and_isshort_functions()
    @test islong(@position_constructor(Long))
    @test !isshort(@position_constructor(Long))
    @test !islong(@position_constructor(Short))
    @test isshort(@position_constructor(Short))
end

function test_marginmode_function()
    @test marginmode(@position_constructor(Long, Isolated)) == Isolated()
    @test marginmode(@position_constructor(Long, Cross)) == Cross()
    @test_throws ErrorException @position_constructor(Long, NoMargin)
end

function test_ishedged_function()
    @position_constructor()
    @test ishedged(pos) == ishedged(Cross())
end

function test_tier_function()
    @position_constructor()
    @test tier(pos, 1000.0) == tier(pos.tiers[], 1000.0)
end

function test_posside_function()
    @test posside(@position_constructor(Long)) == Long()
    @test posside(@position_constructor(Short)) == Short()
end

function test_position_field_accessors()
    @position_constructor()
    @test price(pos) == pos.entryprice[]
    @test entryprice(pos) == pos.entryprice[]
    @test liqprice(pos) == pos.liquidation_price[]
    @test leverage(pos) == pos.leverage[]
    @test inst.status(pos) == pos.status[]
    @test maintenance(pos) == pos.maintenance_margin[]
    @test margin(pos) == pos.initial_margin[]
    @test additional(pos) == pos.additional_margin[]
    @test mmr(pos) == pos.this_tier[].mmr
    @test notional(pos) == pos.notional[]
    @test inst.cash(pos) == pos.cash
    @test committed(pos) == pos.cash_committed
    @test collateral(pos) == margin(pos) + additional(pos)
    @test inst.timestamp(pos) == pos.timestamp[]
end

function test_bankruptcy_function()
    @position_constructor()
    @test bankruptcy(100.0, 2.0) == 50.0
    @test bankruptcy(pos, 100.0) == bankruptcy(100.0, leverage(pos))
end

function test_timestamp_function()
    @position_constructor()
    timestamp!(pos, DateTime(1))
    @test inst.timestamp(pos) == DateTime(1)
end

function test_tier_bang_function()
    @position_constructor()
    tier!(pos, 1000.0)
    @test pos.this_tier[] == tier(pos, 1000.0)[2]
end

function test_entryprice_bang_function()
    @position_constructor()
    inst.entryprice!(pos, 50.0)
    @test entryprice(pos) == 50.0
end

function test_notional_function()
    @position_constructor()
    notional!(pos, 1000.0)
    @test notional(pos) == 1000.0
end

function test_margin_and_related_functions()
    @position_constructor()
    inst.margin!(pos; ntl=1000.0, lev=2.0)
    @test margin(pos) == 500.0
    inst.initial!(pos, 500.0)
    @test margin(pos) == 500.0
    inst.additional!(pos, 100.0)
    @test additional(pos) == 100.0
    inst.addmargin!(pos, 50.0)
    @test additional(pos) == 150.0
end

function test_maintenance_function()
    @position_constructor()
    maintenance!(pos, 200.0)
    @test maintenance(pos) == 200.0
end

function test_cash_and_commit_functions()
    @position_constructor()
    cash!(pos, 1000.0)
    @test inst.cash(pos) == 1000.0
    commit!(pos, 500.0)
    @test committed(pos) == 500.0
end

function test_pnl_functions()
    @position_constructor()
    entryprice!(pos, 50.0)
    cash!(pos, 1.0)
    inst._status!(pos, PositionOpen())
    @test pnl(pos, 60.0) == 10.0 * cash(pos)
    @test pnl(pos, 40.0) == -10.0 * cash(pos)
    @test pnlpct(pos, 60.0) == 0.2
    @test pnlpct(pos, 40.0) == -0.2
    @position_constructor(Short)
    entryprice!(pos, 50.0)
    cash!(pos, 2.0)
    inst._status!(pos, PositionOpen())
    @test pnl(pos, 60.0, 2.0) == -10.0 * 2.0
    @test pnl(pos, 40.0, 2.0) == 10.0 * 2.0
end

function test_updated_functions()
    @position_constructor()
    update = PositionUpdated("tag", "group", pos)
    @test update isa PositionUpdated
    margin_update = MarginUpdated("tag", "group", pos)
    @test margin_update isa MarginUpdated
    leverage_update = LeverageUpdated("tag", "group", pos)
    @test leverage_update isa LeverageUpdated
end

function test_pnl_long_function()
    @position_constructor(Long)
    entryprice!(pos, 50.0)
    cash!(pos, 2.0)
    inst._status!(pos, PositionOpen())
    @test pnl(pos, 60.0) == 10.0 * cash(pos)
    @test pnl(pos, 40.0) == -10.0 * cash(pos)
end

function test_pnl_short_function()
    @position_constructor(Short)
    entryprice!(pos, 50.0)
    cash!(pos, 2.0)
    inst._status!(pos, PositionOpen())
    @test pnl(pos, 60.0) == -10.0 * cash(pos)
    @test pnl(pos, 40.0) == 10.0 * cash(pos)
end

function test_pnl_calculation_functions()
    @test pnl(50.0, 60.0, 1.0, Long()) == 10.0
    @test pnl(50.0, 40.0, 1.0, Long()) == -10.0
    @test pnl(50.0, 60.0, 1.0, Short()) == -10.0
    @test pnl(50.0, 40.0, 1.0, Short()) == 10.0
end

function test_liqprice_functions()
    @position_constructor()
    liqprice!(pos, 40.0)
    @test liqprice(pos) == 40.0
end

function test_liqprice_long_function()
    @position_constructor(Long)
    liqprice!(pos, 40.0)
    @test liqprice(pos) == 40.0
end

function test_liqprice_short_function()
    @position_constructor(Short)
    liqprice!(pos, 60.0)
    @test liqprice(pos) == 60.0
end

function test_position_updated_function()
    @position_constructor()
    update = PositionUpdated("tag", "group", pos)
    @test update isa PositionUpdated
end

function test_margin_updated_function()
    @position_constructor()
    margin_update = MarginUpdated("tag", "group", pos)
    @test margin_update isa MarginUpdated
end

function test_leverage_updated_function()
    @position_constructor()
    leverage_update = LeverageUpdated("tag", "group", pos)
    @test leverage_update isa LeverageUpdated
end

function test_print_function()
    @position_constructor()
    io = IOBuffer()
    print(io, pos)
    @test !isempty(String(take!(io)))
end

function test_show_function()
    @position_constructor()
    io = IOBuffer()
    show(io, "text/plain", pos)
    @test !isempty(String(take!(io)))
end
function test_positions()
    @eval begin
        using PingPongDev
        using PingPongDev.PingPong
        PingPongDev.PingPong.@environment!
        using .im.Derivatives: Derivative
        using .exs: LeverageTier, LeverageTiersDict, leverage_tiers, tier
        using .mi.Lang: @ifdebug
        using Base: negate
        using .ot: isshort, islong, commit!, PositionUpdated, LeverageUpdated, MarginUpdated
        using .mi: marginmode, CrossMargin
        using .im: cash!
        using .inst
        using .inst: CCash, entryprice!, pnlpct, cash
    end
    prev = get(ENV, "JULIA_TEST_FAILFAST", false)
    ENV["JULIA_TEST_FAILFAST"] = true
    @testset "positions" begin
        try
            test_position_constructor()
            test_reset_function()
            test_leverage_function()
            test_maxleverage_function()
            test_status_function()
            test_isopen_function()
            test_islong_and_isshort_functions()
            test_marginmode_function()
            test_ishedged_function()
            test_tier_function()
            test_posside_function()
            test_position_field_accessors()
            test_bankruptcy_function()
            test_timestamp_function()
            test_tier_bang_function()
            test_entryprice_bang_function()
            test_notional_function()
            test_margin_and_related_functions()
            test_maintenance_function()
            test_cash_and_commit_functions()
            test_pnl_functions()
            test_updated_functions()
            test_pnl_long_function()
            test_pnl_short_function()
            test_pnl_calculation_functions()
            test_liqprice_functions()
            test_liqprice_long_function()
            test_liqprice_short_function()
            test_position_updated_function()
            test_margin_updated_function()
            test_leverage_updated_function()
            test_print_function()
            test_show_function()
        finally
            ENV["JULIA_TEST_FAILFAST"] = prev
        end
    end
end
