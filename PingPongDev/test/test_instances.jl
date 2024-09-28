macro asset_constructor(asset=a"BTC/USDT", margin=NoMargin)
    e = quote
        a = $asset
        e = getexchange!(:binance)
        eid = e.id
        M = $margin()
        ai = AssetInstance(a, Dict(tf"1m" => da.DataFrame()), e, M; inst.DEFAULT_FIELDS...)
    end
    e = esc(e)
end

macro order_constructor()
    e = quote
    o = ect.basicorder(
        ai,
        100,
        1,
        Ref(100),
        ect.SanitizeOff();
        type=MarketOrder{Buy},
        date=DateTime(2020, 1, 1),
    )
    end
    e = esc(e)
end

function test_asset_instance()
    @asset_constructor()
    @test ai.asset == a"BTC/USDT"
    @test ai.data isa SortedDict{TimeFrame,DataFrame,Base.Order.ForwardOrdering}
    @test ai.history isa SortedArray{AnyTrade{typeof(a),typeof(eid)},1}
    @test isempty(ai.history)
    @test ai.lock isa SafeLock
    @test ai.cash isa CCash{typeof(eid)}
    @test ai.cash_committed isa CCash{typeof(eid)}
    @test ai.exchange == getexchange!(:binance)
    @test ai.longpos == nothing
    @test ai.shortpos == nothing
    @test ai.lastpos[] == nothing
    @test inst.marginmode(ai) == NoMargin()
    @test inst.ishedged(ai) == false

    @test_throws MethodError @asset_constructor(a"BTC/USDT", Cross)
    @asset_constructor(d"BTC/USDT:USDT", Cross)
    @test inst.marginmode(ai) == Cross()
    @test inst.ishedged(ai) == false
    @test_throws AssertionError @asset_constructor(d"BTC/USDT:USDT", CrossHedged)
    @asset_constructor(d"BTC/USDT:USDT", Isolated)
    @test inst.marginmode(ai) == Isolated()
    @test inst.ishedged(ai) == false
end

function test_positions_function()
    M = NoMargin
    a = a"BTC/USDT"
    limits = (;
        leverage=(; min=1.0, max=1.0),
        amount=(min=2.0, max=2.0),
        price=(min=3.0, max=3.0),
        cost=(min=4.0, max=4.0),
    )
    e = getexchange!(:binance)
    @test positions(M, a, limits, e) == (nothing, nothing)

    M = Cross
    @test_throws MethodError positions(M, a, limits, e)
    a = d"BTC/USDT:USDT"
    pos_long, pos_short = positions(M, a, limits, e)
    @test pos_long isa inst.LongPosition
    @test pos_short isa inst.ShortPosition
end

function test_hash_function()
    a = a"BTC/USDT"
    e = getexchange!(:binance)
    M = NoMargin()
    ai = AssetInstance(a, Dict(), e, M; inst.DEFAULT_FIELDS...)
    @test inst._hashtuple(ai) == (Instruments._hashtuple(a)..., e.id)
    @test hash(ai) == hash(inst._hashtuple(ai))
    @test hash(ai, UInt(123)) == hash(inst._hashtuple(ai), UInt(123))
end

function test_lock_function()
    @asset_constructor()

    @test lock(ai) === nothing
    @test islocked(ai) === true
    @test unlock(ai) === nothing
    @test islocked(ai) === false
end

function test_broadcastable_function()
    @asset_constructor()

    @test Broadcast.broadcastable(ai) isa Ref
    @test Broadcast.broadcastable(ai).x === ai
end

function test_propertynames_function()
    @asset_constructor()

    @test propertynames(ai) == (fieldnames(AssetInstance)..., :ohlcv, :funding)
    @test fieldnames(AssetInstance) == (
        :attrs,
        :asset,
        :data,
        :history,
        :lock,
        :_internal_lock,
        :cash,
        :cash_committed,
        :exchange,
        :longpos,
        :shortpos,
        :lastpos,
        :limits,
        :precision,
        :fees,
    )
end

function test_makerfees_function()
    @asset_constructor()
    @test makerfees(ai) == ai.fees.maker
end

function test_minfees_function()
    @asset_constructor()
    @test minfees(ai) == ai.fees.min
end

function test_maxfees_function()
    @asset_constructor()
    @test maxfees(ai) == ai.fees.max
end

function test_exchangeid_function()
    @asset_constructor()
    @test exchangeid(ai) == ExchangeID{:binance}
end

function test_exchange_function()
    @asset_constructor()
    @test exchange(ai) == getexchange!(:binance)
end

function test_position_function()
    @asset_constructor()
    @test_throws MethodError position(ai, Long())
    @test_throws MethodError position(ai, Short())
    @test_throws MethodError position(ai)
    @asset_constructor(d"BTC/USDT:USDT", Isolated)
    @test position(ai, Long()) isa inst.LongPosition
    @test position(ai, Short()) isa inst.ShortPosition
    @test position(ai) === nothing
    @test position(ai, Long()) == ai.longpos
    @test position(ai, Short()) == ai.shortpos
    @test position(ai) == ai.lastpos[]
end

function test_trades_function()
    @asset_constructor()
    @test trades(ai) === ai.history
    @test trades(ai) isa SortedArray{AnyTrade{typeof(a),typeof(eid)},1}
    @test isempty(trades(ai))
end

function test_timestamp_function()
    @asset_constructor()
    @test inst.timestamp(ai) == inst._history_timestamp(ai)
    @test_throws MethodError inst.timestamp(ai, Long())
    @asset_constructor(d"BTC/USDT:USDT", Isolated)
    @test inst.timestamp(ai, Long()) == inst.timestamp(position(ai, Long()))
    @test inst.timestamp(ai, Short()) == inst.timestamp(position(ai, Short()))
    @test inst.timestamp(ai) == DateTime(0)
end

function test_leverage_function()
    @asset_constructor()
    @test leverage(ai) == 1.0
    @test leverage(ai, Long()) == 1.0
    @test leverage(ai, Short()) == 1.0
    @asset_constructor(d"BTC/USDT:USDT", Isolated)
    @test leverage(ai, Long()) == leverage(position(ai, Long())) == 1.0
    @test leverage(ai, Short()) == leverage(position(ai, Short())) == 1.0
end

function test_marginmode_function()
    @asset_constructor()
    @test marginmode(ai) == NoMargin()
    @test marginmode(ai) == typeof(ai).parameters[3]()
    @test marginmode(ai, Long()) == typeof(ai).parameters[3]()
    @test marginmode(ai, Short()) == typeof(ai).parameters[3]()
    ai = @asset_constructor(d"BTC/USDT:USDT", Isolated)
    @test marginmode(ai, Long()) == marginmode(position(ai, Long()))
    @test marginmode(ai, Short()) == marginmode(position(ai, Short()))
end

function test_ishedged_function()
    @asset_constructor()
    @test inst.ishedged(ai) == false
    @test_throws AssertionError @asset_constructor(d"BTC/USDT:USDT", CrossHedged) # 
end

function test_tier_function()
    @asset_constructor()
    @test_throws MethodError inst.tier(ai)
    @asset_constructor(d"BTC/USDT:USDT", Isolated)
    @test_throws MethodError inst.tier(ai, Long())
    @test_throws MethodError inst.tier(ai, Short())
    @test inst.tier(ai, 1, Long())[1] == 1
    @test inst.tier(ai, 1e8, Short())[1] == nothing
end

function test_posside_function()
    @asset_constructor()
    @test inst.posside(ai) == Long()
    @asset_constructor(d"BTC/USDT:USDT", Isolated)
    @test inst.posside(ai) == nothing
    @test inst.posside(position(ai, Long)) == Long()
    @test inst.posside(position(ai, Short)) == Short()
end

function test_position_field_accessors()
    @asset_constructor(d"BTC/USDT:USDT", Isolated)
    @test inst.entryprice(ai, 0, Long()) == 0.0
    @test inst.entryprice(ai, 0, Short()) == 0.0
    @test inst.notional(ai, Long()) == 0.0
    @test inst.notional(ai, Short()) == 0.0
    @test inst.margin(ai, Long()) == 0.0
    @test inst.margin(ai, Short()) == 0.0
    @test inst.cash(ai, Long()) == 0.0
    @test inst.cash(ai, Short()) == 0.0
    @test inst.committed(ai, Long()) == 0.0
    @test inst.committed(ai, Short()) == 0.0
    @test_throws MethodError inst.pnl(ai, Long()) == 0.0
    @test_throws MethodError inst.pnl(ai, Short()) == 0.0
    @test inst.pnl(ai, Long(), 0) == 0.0
    @test inst.pnl(ai, Short(), 0) == 0.0
    @test inst.pnl(ai, Long(), 100) == 0.0
    @test inst.pnl(ai, Short(), 100) == 0.0
    cash!(cash(ai, Long()), 100.0)
    @test cash(ai, Long()) == 100.0
    cash!(cash(ai, Short()), 2.0)
    @test cash(ai, Short()) == 2.0
    p = position(ai, Long())
    entryprice!(p, 80.0)
    ai.longpos.status[] = PositionOpen()
    p = position(ai, Short())
    entryprice!(p, 60.0)
    ai.shortpos.status[] = PositionOpen()
    @test entryprice(ai, 10.0, Long()) == 80.0
    @test entryprice(ai, 10.0, Short()) == 60.0
    @test inst.pnl(ai, Long(), 80.0) == 0.0
    @test inst.pnl(ai, Long(), 60.0) == -2000.0
    @test inst.pnl(ai, Long(), 100.0) == 2000.0
    @test inst.pnlpct(ai, Long(), 0.0) == -1.0
    @test inst.pnlpct(ai, Long(), 81.0) == 0.0125
    @test inst.pnlpct(ai, Short(), 0.0) == 1.0
    @test inst.pnlpct(ai, Short(), 40.0) == 1 / 3
    @test inst.pnlpct(ai, Long(), 100.0) == 0.25
    @test inst.pnlpct(ai, Short(), 100.0) == -2 / 3
    @test inst.liqprice(ai, Long()) == 0.0
    @test inst.liqprice(ai, Short()) == 0.0
end

function test_bankruptcy_function()
    @asset_constructor()
    @test_throws MethodError inst.bankruptcy(ai, nothing)
    @asset_constructor(d"BTC/USDT:USDT", Isolated)
    @test inst.bankruptcy(ai, 100.0, Long()) == 0.0
    @test inst.bankruptcy(ai, 100.0, Short()) == 200.0
    cash!(cash(ai, Long()), 100.0)
    leverage!(ai, 10.0, Long())
    @test leverage(ai, Long()) == 10.0
    @test ai.longpos.leverage[] == 10.0
    @test inst.bankruptcy(ai, 100.0, Long()) == 90.0
    leverage!(ai, 10.0, Short())
    @test inst.leverage(ai, Short()) == 10.0
    @test ai.shortpos.leverage[] == 10.0
    @test inst.bankruptcy(ai, 100.0, Short()) == 110.0
end

function test_asset_instance_functions1()
    ai = @asset_constructor()

    # Test asset, raw, ohlcv, ohlcv_dict, bc, qc functions
    @test asset(ai) == ai.asset
    @test raw(ai) == raw(ai.asset)
    @test ohlcv(ai) == first(values(ai.data))
    @test ohlcv_dict(ai) == ai.data
    @test bc(ai) == ai.asset.bc
    @test qc(ai) == ai.asset.qc

    # Test takerfees, makerfees, maxfees, minfees functions
    @test takerfees(ai) == ai.fees.taker
    @test makerfees(ai) == ai.fees.maker
    @test maxfees(ai) == ai.fees.max
    @test minfees(ai) == ai.fees.min

    # Test exchangeid, exchange functions
    @test exchangeid(ai) == typeof(ai).parameters[2]
    @test exchange(ai) == ai.exchange

    # Test position, posside, cash, committed functions
    @test_throws MethodError position(ai, Long())
    @test_throws MethodError position(ai, Short())
    @test_throws MethodError position(ai)

    # Test liqprice, leverage, bankruptcy, entryprice, price functions
    @test_throws MethodError liqprice(ai, Long())
    @test_throws MethodError liqprice(ai, Short())
    @test_throws MethodError bankruptcy(ai, 100.0, Long())
    @test_throws MethodError bankruptcy(ai, 100.0, Short())
    @test_throws MethodError entryprice(ai, 100.0, Long())
    @test_throws MethodError entryprice(ai, 100.0, Short())

    # Test additional, margin, maintenance functions
    @test_throws MethodError additional(ai, Long())
    @test_throws MethodError additional(ai, Short())
    @test_throws MethodError margin(ai, Long())
    @test_throws MethodError margin(ai, Short())
    @test_throws MethodError maintenance(ai, Long())
    @test_throws MethodError maintenance(ai, Short())

    # Test leverage, mmr, status! functions
    @test_throws MethodError mmr(ai, 1000.0, Long())
    @test_throws MethodError mmr(ai, 1000.0, Short())
    @test_throws MethodError status!(ai, Long(), PositionOpen())
    @test_throws MethodError status!(ai, Short(), PositionOpen())

    # Test value functions
    @test value(ai) == ai.cash.value
    @test_throws MethodError value(ai, Long())
    @test_throws MethodError value(ai, Short())

    # Test pnl functions
    @test_throws MethodError pnl(ai, Long(), 100.0)
    @test_throws MethodError pnl(ai, Short(), 100.0)

    # Test pnlpct functions
    @test_throws MethodError inst.pnlpct(ai, Long(), 100.0)
    @test_throws MethodError inst.pnlpct(ai, Short(), 100.0)

    # Test lastprice functions
    price = 100.0
    amount = 100.0
    committed = Ref(100.0 * 100.0)
    o = ect.basicorder(
        ai,
        price,
        amount,
        committed,
        ect.SanitizeOff();
        type=MarketOrder{Buy},
        date=DateTime(2020, 1, 1),
    )
    size = committed[]
    fees = committed[] * ai.fees.taker
    fees_base = ZERO
    t = Trade(o; date=DateTime(2020, 1, 2), amount, price, size, fees, fees_base)
    push!(ai.history, t)
    @test lastprice(ai, Val(:history)) == last(ai.history).price
    @test lastprice(ai, DateTime(2020, 1, 1)) == lastprice(ai)

    # Test timeframe function
    @test timeframe(ai) == first(keys(ai.data))

    # Test instance and load! functions
    @test instance(ai.exchange, ai.asset) isa AssetInstance
    @test load!(ai) === nothing

    # Test similar function
    sim_ai = similar(ai)
    @test sim_ai isa AssetInstance
    @test sim_ai.asset == ai.asset
    @test sim_ai.exchange == ai.exchange
    @test marginmode(sim_ai) == marginmode(ai)
    @test ishedged(sim_ai) == ishedged(ai)

    # Test stub! function
    df = da.empty_ohlcv()
    push!(df, Lang.fromstruct(da.default_value(da.Candle)))
    push!(df, Lang.fromstruct(da.default_value(da.Candle)))
    @test ohlcv(ai) |> isempty
    @test stub!(ai, df) === df
    @test ohlcv(ai) |> !isempty
    @test NamedTuple(first(ohlcv(ai))) == Lang.fromstruct(da.default_value(da.Candle))

end
function test_asset_instance_functions2()
    @asset_constructor(d"BTC/USDT:USDT", Isolated)
    # Test freecash functions
    cash!(cash(inst.position(ai, Long())), 100.0)
    cash!(cash(inst.position(ai, Short())), -200.0)
    cash!(committed(ai, Long()), 10.0)
    cash!(committed(ai, Short()), -20.0)
    @test_throws ErrorException freecash(ai)
    @test freecash(ai, Long()) == cash(ai, Long()) - committed(ai, Long())
    @test freecash(ai, Short()) == cash(ai, Short()) - committed(ai, Short())

    # Test reset! functions
    @test reset!(ai) === nothing
    @test reset!(ai, Long()) === nothing
    @test reset!(ai, Short()) === nothing

    # Test isdust functions
    @asset_constructor()
    @test isdust(ai, 100.0) == (ai.cash.value * 100.0 < ai.limits.cost.min)
    @test_throws MethodError isdust(ai, 100.0, Long())
    @test_throws MethodError isdust(ai, 100.0, Short())

    # Test nondust functions
    @asset_constructor(d"BTC/USDT:USDT", Isolated)
    pos = position(ai, Long())
    cash!(pos, 100.0)
    ai.lastpos[] = pos
    @test nondust(ai, 100.0) ==
        (cash(ai).value * 100.0 >= ai.limits.cost.min ? cash(ai).value : 0.0)
    @test nondust(ai, MarketOrder{Buy}, 101) == 100.0
    @test nondust(ai, MarketOrder{Sell}, 101) == 100.0

    # Test iszero functions
    @asset_constructor()
    @test iszero(ai, ai.cash.value) ==
        (abs(ai.cash.value) < ai.limits.amount.min - eps(DFT))
    @test iszero(ai, Long()) == (abs(ai.cash.value) < ai.limits.amount.min - eps(DFT))
    @test iszero(ai, Short()) == (abs(ai.cash.value) < ai.limits.amount.min - eps(DFT))
    @test iszero(ai) == (iszero(ai, Long()) && iszero(ai, Short()))

    # Test approxzero functions
    @test approxzero(ai, ai.cash.value) == iszero(ai, ai.cash.value)

    # Test gtxzero, ltxzero functions
    cash!(cash(ai), 100.0)
    @test gtxzero(ai, ai.cash.value, Val(:amount)) ==
        (ai.cash.value > ai.limits.amount.min + eps())
    @test ltxzero(ai, ai.cash.value, Val(:amount)) ==
        (ai.cash.value < ai.limits.amount.min + eps())
    cash!(cash(ai), -2ai.limits.amount.min)
    @test gtxzero(ai, ai.cash.value, Val(:amount)) == false
    @test ltxzero(ai, ai.cash.value, Val(:amount)) == true
    v = 2ai.limits.price.min
    @test gtxzero(ai, v, Val(:price)) == (v > ai.limits.price.min + eps())
    @test ltxzero(ai, v, Val(:price)) == (v < ai.limits.price.min + eps())
    v = 2ai.limits.cost.min
    @test gtxzero(ai, v, Val(:cost)) == (v > ai.limits.cost.min + eps())
    @test ltxzero(ai, v, Val(:cost)) == (v < ai.limits.cost.min + eps())
    v = -2ai.limits.price.min
    @test gtxzero(ai, v, Val(:price)) == (v > ai.limits.price.min + eps())
    @test ltxzero(ai, v, Val(:price)) == (v < ai.limits.price.min + eps())
    v = -2ai.limits.cost.min
    @test gtxzero(ai, v, Val(:cost)) == (v > ai.limits.cost.min + eps())
    @test ltxzero(ai, v, Val(:cost)) == (v < ai.limits.cost.min + eps())

    # Test isapprox functions
    @test isapprox(ai, ai.cash.value, ai.cash.value, Val(:amount)) == true
    @test isapprox(ai, 100.0, 100.0, Val(:price)) == true

    # Test isequal functions
    @test isequal(ai, ai.cash.value, ai.cash.value, Val(:amount)) == true
    @test isequal(ai, 100.0, 100.0, Val(:price)) == true

    # Test @_round, @rprice, @ramount macros
    @test (@rprice 100.0) == mi.toprecision(100.0, ai.precision.price)
    @test (@ramount 100.0) == mi.toprecision(100.0, ai.precision.amount)

    # Test candlelast functions
    df = da.empty_ohlcv()
    push!(df, Lang.fromstruct(da.default_value(da.Candle)))
    ai.data[tf"1m"] = df
    @test candlelast(ai, first(keys(ai.data)), DateTime(2020, 1, 1)) ==
        da.Candle(last(ai.data[first(keys(ai.data))])...)
    @test candlelast(ai) == da.Candle(last(ai.data[first(keys(ai.data))])...)

    # Test Order function
    @test_throws UndefKeywordError Order(ai, MarketOrder{Buy})
    @test Order(ai, MarketOrder{Buy}, date=DateTime(2020, 1, 1), price=10.0, amount=1.0) isa Order

    # Test print and show functions
    io = IOBuffer()
    print(io, ai)
    @test String(take!(io)) == "BTC/USDT~[-0.2(μ)]{Binance}"
    show(io, "text/plain", ai)
    @test !isempty(String(take!(io)))
    show(io, ai)
    @test !isempty(String(take!(io)))
end

function test_instances()
    @eval begin
        using PingPongDev
        @environment!
        using Lang
        using .inst
        using .inst:
            Limits,
            positions,
            SortedDict,
            SortedArray,
            AnyTrade,
            ExchangeID,
            Exchange,
            CCash,
            CrossHedged,
            IsolatedHedged,
            trades,
            freecash,
            entryprice!
        using .Instruments
        using .Instruments: cash!
        using .inst.Data: DataFrame, candlelast
        using .im
        using .ect: SanitizeOff
    end
    prev = get(ENV, "JULIA_TEST_FAILFAST", false)
    ENV["JULIA_TEST_FAILFAST"] = true
    @testset "instances" begin
        try
            test_asset_instance()
            test_positions_function()
            test_hash_function()
            test_lock_function()
            test_broadcastable_function()
            test_propertynames_function()
            test_makerfees_function()
            test_minfees_function()
            test_maxfees_function()
            test_exchangeid_function()
            test_exchange_function()
            test_position_function()
            test_trades_function()
            test_leverage_function()
            test_marginmode_function()
            test_timestamp_function()
            test_ishedged_function()
            test_tier_function()
            test_posside_function()
            test_position_field_accessors()
            test_bankruptcy_function()
            test_asset_instance_functions1()
            test_asset_instance_functions2()
        finally
            ENV["JULIA_TEST_FAILFAST"] = prev
        end
    end
end
