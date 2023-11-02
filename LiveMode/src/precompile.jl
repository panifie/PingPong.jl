using .Misc.Lang: Lang, @preset, @precomp, @m_str, @ignore

# macro compile_pong()
#     expr = quote
#         @eval begin
#             isdefined(@__MODULE__, :OrderTypes) || using .OrderTypes: OrderTypes as ot
#             using .OrderTypes: Buy, Sell
#             using .Lang: @ignore, @precomp
#             isdefined(@__MODULE__, :Executors) || using .Executors: pong!, Executors as ect
#         end

#         ai = first(s.universe)
#         amount = ai.limits.amount.min
#         prc = min(ai.limits.price.min * 10, ai.limits.price.max)
#         date = now()
#         function dispatched_orders()
#             out = Type{<:Order}[]
#             for name in names(ot; all=true)
#                 name == :Order && continue
#                 otp = getproperty(ot, name)
#                 if otp isa Type && otp <: ot.Order
#                     if applicable(ot.ordertype, otp{Buy})
#                         push!(out, otp{Buy})
#                         push!(out, otp{Sell})
#                     end
#                 end
#             end
#             out
#         end
#         @precomp @ignore begin
#             for otp in dispatched_orders()
#                 pong!(s, ai, otp; amount, date, prc)
#             end
#             pong!(Returns(nothing), s, ect.InitData(); cols=(:abc,), timeframe=tf"1d")
#             pong!(Returns(nothing), s, ect.UpdateData(); cols=(:abc,), timeframe=tf"1d")
#             pong!(s, ect.WatchOHLCV())
#             pong!(s, ai, 1.0, ect.UpdateLeverage(); pos=Long())
#             pong!(s, ai, Short(), date, ect.PositionClose())
#             pong!(s, ai, ect.CancelOrders())
#         end
#     end
#     esc(expr)
# end

@preset let
    st.Instances.Exchanges.Python.py_start_loop()
    s = st.strategy(st.BareStrat; mode=Live())
    sim = SimMode.sim
    for ai in s.universe
        append!(
            ohlcv_dict(ai)[s.timeframe],
            sim.Processing.Data.to_ohlcv(sim.synthohlcv());
            cols=:union,
        )
    end
    sim.Random.seed!(1)
    ai = first(s.universe)
    amount = ai.limits.amount.min
    date = now()
    price = ai.limits.price.min * 2
    @precomp @ignore begin
        start!(s)
        stop!(s)
    end
    ot = OrderTypes
    start!(s)
    SimMode.@compile_pong
    @precomp @ignore begin
        stop!(s)
        reset!(s)
    end
    st.Instances.Exchanges.Python.py_stop_loop()
end
