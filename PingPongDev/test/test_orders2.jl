using Test
using PingPongDev.PingPong.Engine.Lang: @m_str
using PingPongDev.PingPong.Engine.TimeTicks
using PingPongDev.PingPong.Engine.Exchanges.Python
using PingPongDev.PingPong.Engine.Simulations.Random
using PingPongDev.PingPong.Engine.Instances: NoMarginInstance, MarginInstance

function test_committment(s, s_nomg)
    @testset "committment Tests" begin
        # Mock instances for testing

        # Ensure the correct types are used for instance creation
        ai_no_margin = s_nomg."btc"
        ai_margin = s."btc"

        # Mock data for testing
        price = 100.0
        amount = 10.0
        ntl = price * amount
        fees = ntl * 0.01
        lev = 2.0

        # Test committment for NoMarginInstance
        @test committment(IncreaseOrder, ai_no_margin, price, amount) ==
            withfees(ntl, maxfees(ai_no_margin), IncreaseOrder)

        # Test committment for MarginInstance
        @test committment(
            IncreaseOrder, ai_margin, price, amount; ntl=ntl, fees=fees, lev=lev
        ) == (ntl / lev) + fees

        # Test committment for SellOrder
        @test committment(SellOrder, ai_no_margin, price, amount) ==
            amount_with_fees(amount, 0.0)

        # Test committment for ShortBuyOrder
        @test committment(ShortBuyOrder, ai_no_margin, price, amount) ==
            amount_with_fees(negate(amount), 0.0)
    end
end

function test_buysell(s)
    @testset "orders Tests" begin
        # Mock strategy and asset instance for testing
        ai = s."btc"
        # Mock orders for testing
        date = DateTime(2022, 1, 1)
        buy_order = basicorder(
            ai, 100.0, 10.0, Ref(10.0), SanitizeOff(); type=GTCOrder{Buy}, date
        )
        sell_order = basicorder(
            ai, 100.0, 10.0, Ref(10.0), SanitizeOff(); type=GTCOrder{Sell}, date
        )

        # Add orders to the strategy
        push!(s, ai, buy_order)
        push!(s, ai, sell_order)

        # Test orders function
        @test length(orders(s, ai)) == 2
        @test buyorders(s, ai) == s.buyorders[ai]
        @test sellorders(s, ai) == s.sellorders[ai]
        @test buy_order in values(buyorders(s, ai))
        @test sell_order in values(sellorders(s, ai))
    end
end
function test_hasorders(s)
    @testset "hasorders Tests" begin
        # Mock asset instance for testing
        ai = s."btc"

        # Mock orders for testing
        date = DateTime(2022, 1, 1)
        buy_order = basicorder(
            ai, 100.0, 10.0, Ref(10.0), SanitizeOff(); type=GTCOrder{Buy}, date
        )
        sell_order = basicorder(
            ai, 100.0, 10.0, Ref(10.0), SanitizeOff(); type=GTCOrder{Sell}, date
        )

        @test hasorders(s) == false
        @test hasorders(s, ai) == false
        @test hasorders(s, ai, Buy) == false
        @test hasorders(s, ai, Sell) == false

        if s isa MarginStrategy
            # Test hasorders with position side
            @test hasorders(s, ai, Long()) == false
            @test hasorders(s, ai, Short()) == false

            # Test hasorders with ByPos
            @test hasorders(s, ai, buy_order) == false

            # Test hasorders with strategy and position side
            @test hasorders(s, Long()) == false
            @test hasorders(s, Short()) == false

            @test hasorders(s, Long()) == false
            @test hasorders(s, Short()) == false

            # Test hasorders with strategy, position side, and universe
            @test hasorders(s, Long(), Val(:universe)) == false
            @test hasorders(s, Short(), Val(:universe)) == false
        end

        # Add orders to the strategy
        push!(s, ai, buy_order)
        push!(s, ai, sell_order)

        # Test hasorders function
        @test hasorders(s) == true
        @test hasorders(s, ai) == true
        @test hasorders(s, ai, Buy) == true
        @test hasorders(s, ai, Sell) == true

        if s isa MarginStrategy
            # Test hasorders with position side
            @test hasorders(s, ai, Long()) == true
            @test hasorders(s, ai, Short()) == false

            short_order = basicorder(
                ai, 100.0, 10.0, Ref(10.0), SanitizeOff(); type=ShortGTCOrder{Buy}, date
            )
            # Test hasorders with ByPos
            @test hasorders(s, ai, buy_order) == true
            @test hasorders(s, ai, short_order) == false

            # Test hasorders with strategy and position side
            @test hasorders(s, Long()) == false
            @test hasorders(s, Short()) == false
            push!(s.holdings, ai)
            @test hasorders(s, Long()) == true
            @test hasorders(s, Short()) == false

            # Test hasorders with strategy, position side, and universe
            @test hasorders(s, Long(), Val(:universe)) == true
            @test hasorders(s, Short(), Val(:universe)) == false
        end
    end
end

function test_orderiterator(s)
    @testset "OrderIterator Tests" begin
        # Mock asset instance for testing
        ai = s."btc"

        # Mock orders for testing
        date = DateTime(2022, 1, 1)
        buy_order1 = basicorder(
            ai,
            100.0,
            10.0,
            Ref(10.0),
            SanitizeOff();
            type=GTCOrder{Buy},
            date=DateTime(2022, 1, 1),
        )
        buy_order2 = basicorder(
            ai,
            101.0,
            10.0,
            Ref(10.0),
            SanitizeOff();
            type=GTCOrder{Buy},
            date=DateTime(2022, 1, 2),
        )
        sell_order1 = basicorder(
            ai,
            102.0,
            10.0,
            Ref(10.0),
            SanitizeOff();
            type=GTCOrder{Sell},
            date=DateTime(2022, 1, 3),
        )
        sell_order2 = basicorder(
            ai,
            103.0,
            10.0,
            Ref(10.0),
            SanitizeOff();
            type=GTCOrder{Sell},
            date=DateTime(2022, 1, 4),
        )

        # Add orders to the strategy
        push!(s, ai, buy_order1)
        push!(s, ai, buy_order2)
        push!(s, ai, sell_order1)
        push!(s, ai, sell_order2)

        # Get order generators
        buy_orders_gen = orders(s, ai, Buy)
        sell_orders_gen = orders(s, ai, Sell)

        # Create OrderIterator instance
        oi = OrderIterator(buy_orders_gen, sell_orders_gen)

        # Test OrderIterator constructor
        @test length(oi.iters) == 2
        # Test Base.length
        @test length(oi) == 4

        # Test Base.iterate
        result = iterate(oi)
        # NOTE: price time ordering iterates first by price (buy/sell >/<), then (tiebreaker) by date
        @test result !== nothing && result[1] == Pair(pricetime(buy_order2), buy_order2)
        result = iterate(oi, result[2])
        @test result !== nothing && result[1] == Pair(pricetime(buy_order1), buy_order1)
        result = iterate(oi, result[2])
        @test result !== nothing && result[1] == Pair(pricetime(sell_order1), sell_order1)
        result = iterate(oi, result[2])
        @test result !== nothing && result[1] == Pair(pricetime(sell_order2), sell_order2)
        @test iterate(oi, result[2]) == nothing

        # Test Base.isdone
        @test Base.isdone(oi) == true

        # Test Base.eltype
        @test eltype(oi) == Pair{PriceTime,<:Order}

        # Test Base.collect
        collected = collect(OrderIterator(buy_orders_gen, sell_orders_gen))
        @test length(collected) == 4
        @test collected == [
            Pair(pricetime(buy_order2), buy_order2),
            Pair(pricetime(buy_order1), buy_order1),
            Pair(pricetime(sell_order1), sell_order1),
            Pair(pricetime(sell_order2), sell_order2),
        ]

        # Test Base.last
        @test last(OrderIterator(buy_orders_gen, sell_orders_gen)) ==
            Pair(pricetime(sell_order2), sell_order2)

        # Test Base.count
        @test count(OrderIterator(buy_orders_gen, sell_orders_gen)) == 4

        # Test with empty iterators
        empty_oi = OrderIterator(Iterators.Stateful([]), Iterators.Stateful([]))
        @test length(empty_oi) == 0
        @test Base.isdone(empty_oi) == true
        @test collect(empty_oi) == []
        @test_throws ArgumentError last(empty_oi)
        @test count(empty_oi) == 0
    end
end

function test_unfillment(s)
    @testset "unfillment Tests" begin
        # Mock asset instance for testing
        ai = s."btc"

        # Mock orders for testing
        date = DateTime(2022, 1, 1)
        buy_order = basicorder(
            ai, 100.0, 10.0, Ref(10.0), SanitizeOff(); type=GTCOrder{Buy}, date
        )
        sell_order = basicorder(
            ai, 100.0, 10.0, Ref(10.0), SanitizeOff(); type=GTCOrder{Sell}, date
        )

        # Test unfillment for BuyOrder
        @test unfillment(buy_order) == -10.0

        # Test unfillment for SellOrder
        @test unfillment(sell_order) == 10.0

        # Test unfillment with type directly
        @test unfillment(typeof(buy_order), 10.0) == -10.0
        @test unfillment(typeof(buy_order), -10.0) == -10.0
        @test unfillment(typeof(sell_order), 10.0) == 10.0
        @test unfillment(typeof(sell_order), -10.0) == -10.0

        # Test unfillment with zero amount
        @test unfillment(typeof(buy_order), 0.0) == 0.0
        @test unfillment(typeof(sell_order), 0.0) == 0.0
    end
end

function test_iscommittable(s)
    @testset "iscommittable Tests" begin
        # Mock asset instance for testing
        ai = s."btc"

        # Mock orders for testing
        date = DateTime(2022, 1, 1)
        increase_order = basicorder(
            ai, 100.0, 10.0, Ref(10.0), SanitizeOff(); type=GTCOrder{Buy}, date
        )
        sell_order = basicorder(
            ai, 100.0, 10.0, Ref(10.0), SanitizeOff(); type=GTCOrder{Sell}, date
        )
        short_buy_order = basicorder(
            ai, 100.0, 10.0, Ref(10.0), SanitizeOff(); type=ShortGTCOrder{Buy}, date
        )

        # Mock commitment values
        commit_increase = Ref(committment(typeof(increase_order), ai, 100.0, 10.0))
        commit_sell = Ref(committment(typeof(sell_order), ai, 100.0, 10.0))
        commit_short_buy = Ref(committment(typeof(short_buy_order), ai, 100.0, 10.0))

        cash!(s.cash, 1e4)
        @test s.cash == 1e4
        # Test iscommittable for IncreaseOrder
        @info "TEST: iscommittable for IncreaseOrder" commit_increase
        @test iscommittable(s, typeof(increase_order), commit_increase, ai) == true

        # Test iscommittable for SellOrder
        @info "TEST: iscommittable for SellOrder" commit_sell
        @test iszero(ai, Long())
        cash!(ai, 1e4, Long())
        @test iscommittable(s, typeof(sell_order), commit_sell, ai)

        @test iszero(ai, Short())
        cash!(ai, 1e4, Short())
        # NOTE: short positions cash is always held negative so this should be false (also should never be the case)
        @test iscommittable(s, typeof(short_buy_order), commit_short_buy, ai) == false
        cash!(ai, -1e4, Short())
        @test iscommittable(s, typeof(short_buy_order), commit_short_buy, ai)

        # Test iscommittable with insufficient funds (edge case)
        cash!(s.cash, 0.0)
        @test iscommittable(s, typeof(increase_order), commit_increase, ai) == false
        cash!(ai, 0.0, Long())
        @test iscommittable(s, typeof(sell_order), commit_sell, ai) == false
        cash!(ai, 0.0, Short())
        @test iscommittable(s, typeof(short_buy_order), commit_short_buy, ai) == false
    end
end

function test_orderscount(s)
    @testset "orderscount Tests" begin
        # Mock asset instance for testing
        ai = s."btc"
        if s isa MarginStrategy
            @test ai isa MarginInstance
        else
            @test ai isa NoMarginInstance
        end

        # Mock orders for testing
        date = DateTime(2022, 1, 1)
        buy_order = basicorder(
            ai,
            100.0,
            10.0,
            Ref(10.0),
            SanitizeOff();
            type=GTCOrder{Buy},
            date=DateTime(2022, 1, 1),
        )
        sell_order = basicorder(
            ai,
            100.0,
            10.0,
            Ref(10.0),
            SanitizeOff();
            type=GTCOrder{Sell},
            date=DateTime(2022, 2, 1),
        )
        if s isa MarginStrategy
            increase_order = basicorder(
                ai,
                100.0,
                10.0,
                Ref(10.0),
                SanitizeOff();
                type=ShortGTCOrder{Sell},
                date=DateTime(2022, 3, 1),
            )
            reduce_order = basicorder(
                ai,
                100.0,
                10.0,
                Ref(10.0),
                SanitizeOff();
                type=ShortGTCOrder{Buy},
                date=DateTime(2022, 4, 1),
            )
            push!(s, ai, increase_order)
            push!(s, ai, reduce_order)
        end

        # Add orders to the strategy
        push!(s, ai, buy_order)
        push!(s, ai, sell_order)
        push!(s.holdings, ai)

        # Test orderscount for all orders
        @test orderscount(s) == (s isa MarginStrategy ? 4 : 2)

        # Test orderscount for Buy orders
        @test orderscount(s, Buy) == (s isa MarginStrategy ? 2 : 1)

        # Test orderscount for Sell orders
        @test orderscount(s, Sell) == (s isa MarginStrategy ? 2 : 1)

        # Test orderscount for Increase orders
        @test orderscount(s, Val(:increase)) == (s isa MarginStrategy ? 2 : 1)

        # Test orderscount for Reduce orders
        @test orderscount(s, Val(:reduce)) == (s isa MarginStrategy ? 2 : 1)

        # Test orderscount for Increase and Reduce orders
        @test orderscount(s, Val(:inc_red)) == (s isa MarginStrategy ? (2, 2) : (1, 1))

        # Test orderscount for an asset instance
        @test orderscount(s, ai) == (s isa MarginStrategy ? 4 : 2)

        # Test orderscount for an asset instance and Buy orders
        @test orderscount(s, ai, Buy) == (s isa MarginStrategy ? 2 : 1)

        # Test orderscount for an asset instance and Sell orders
        @test orderscount(s, ai, Sell) == (s isa MarginStrategy ? 2 : 1)

        # Test orderscount for an asset instance and BuyOrSell orders
        @test orderscount(s, ai, BuyOrSell) == (s isa MarginStrategy ? 4 : 2)

        # Test orderscount for empty strategy (edge case)
        reset!(s)
        @test orderscount(s) == 0
        @test orderscount(s, Buy) == 0
        @test orderscount(s, Sell) == 0
        @test orderscount(s, Val(:increase)) == 0
        @test orderscount(s, Val(:reduce)) == 0
        @test orderscount(s, Val(:inc_red)) == (0, 0)
    end
end

function test_hascash(s)
    @testset "hascash Tests" begin
        # Mock asset instance for testing
        ai = s."btc"

        # Add orders to the strategy
        push!(s.holdings, ai)

        # Test hascash with non-zero cash
        @test hascash(s) == false

        # Test hascash with zero cash (edge case)
        cash!(s.cash, 0.0)
        @test hascash(s) == false
        cash!(s.cash, 1e4)
        @test hascash(s) == false
        cash!(ai, 1e4, Long())
        @test hascash(s) == true
        cash!(ai, 0.0, Long())
        @test hascash(s) == false
        cash!(ai, 1e4, Short())
        @test hascash(s) == true
        cash!(ai, 0.0, Short())
        @test hascash(s) == false
    end
end

function test_buyorders_sellorders(s)
    @testset "buyorders and sellorders Tests" begin
        # Mock asset instance for testing
        ai = s."btc"
        
        # Mock orders for testing
        date = DateTime(2022, 1, 1)
        buy_order1 = basicorder(ai, 100.0, 10.0, Ref(10.0), SanitizeOff(); type=GTCOrder{Buy}, date=DateTime(2022, 5, 1))
        buy_order2 = basicorder(ai, 101.0, 10.0, Ref(10.0), SanitizeOff(); type=GTCOrder{Buy}, date=DateTime(2022, 6, 1))
        sell_order1 = basicorder(ai, 102.0, 10.0, Ref(10.0), SanitizeOff(); type=GTCOrder{Sell}, date=DateTime(2022, 7, 1))
        sell_order2 = basicorder(ai, 103.0, 10.0, Ref(10.0), SanitizeOff(); type=GTCOrder{Sell}, date=DateTime(2022, 8, 1))
        
        # Add orders to the strategy
        push!(s, ai, buy_order1)
        push!(s, ai, buy_order2)
        push!(s, ai, sell_order1)
        push!(s, ai, sell_order2)
        
        # Test buyorders function
        buy_orders = buyorders(s, ai)
        @test length(buy_orders) == 2
        @test buy_order1 in values(buy_orders)
        @test buy_order2 in values(buy_orders)
        
        # Test sellorders function
        sell_orders = sellorders(s, ai)
        @test length(sell_orders) == 2
        @test sell_order1 in values(sell_orders)
        @test sell_order2 in values(sell_orders)
        
        # Test buyorders and sellorders with empty strategy (edge case)
        reset!(s)
        @test length(buyorders(s, ai)) == 0
        @test length(sellorders(s, ai)) == 0
    end
end


function test_orders2()
    @testset "orders" begin
        @eval begin
            using PingPongDev
            using PingPongDev.PingPong
            PingPongDev.PingPong.@environment!
            using PingPongDev.PingPong.Engine.Simulations.Random
            using .Misc: roundfloat
            using .PingPong.Engine.Instances: NoMarginInstance, MarginInstance
            using .PingPong.Engine.Strategies: MarginStrategy, Strategy
            using .ect:
                committment,
                withfees,
                amount_with_fees,
                negate,
                basicorder,
                SanitizeOff,
                orders,
                buyorders,
                sellorders,
                hasorders,
                OrderIterator,
                PriceTime,
                unfillment,
                iscommittable,
                orderscount,
                hascash,
                cash!
        end
        @info "TEST: committment"
        s_nomg = backtest_strat(:Example)
        s = backtest_strat(:ExampleMargin)
        doreset() = (reset!(s); reset!(s_nomg))
        @testset failfast = FAILFAST test_committment(s, s_nomg)
        doreset()
        @testset failfast = FAILFAST test_buysell(s)
        doreset()
        @testset failfast = FAILFAST test_buysell(s_nomg)
        doreset()
        @testset failfast = FAILFAST test_hasorders(s)
        doreset()
        @testset failfast = FAILFAST test_hasorders(s_nomg)
        doreset()
        @testset failfast = FAILFAST test_orderiterator(s)
        doreset()
        @testset failfast = FAILFAST test_orderiterator(s_nomg)
        doreset()
        @testset failfast = FAILFAST test_unfillment(s)
        doreset()
        @testset failfast = FAILFAST test_unfillment(s_nomg)
        doreset()
        @testset failfast = FAILFAST test_iscommittable(s)
        doreset()
        @testset failfast = FAILFAST test_iscommittable(s_nomg)
        doreset()
        @testset failfast = FAILFAST test_orderscount(s)
        doreset()
        @testset failfast = FAILFAST test_orderscount(s_nomg)
        doreset()
        @testset failfast = FAILFAST test_hascash(s)
        doreset()
        @testset failfast = FAILFAST test_hascash(s_nomg)
        doreset()
        @testset failfast = FAILFAST test_buyorders_sellorders(s)
        doreset()
        @testset failfast = FAILFAST test_buyorders_sellorders(s_nomg)
    end
end
