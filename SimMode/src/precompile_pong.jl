macro compile_pong()
    expr = quote
        @eval begin
            using .OrderTypes: OrderTypes as ot
            using .OrderTypes: Buy, Sell
            using .Lang: @ignore, @precomp
            using .Executors: pong!, Executors as ect
        end

        ai = first(s.universe)
        amount = ai.limits.amount.min
        prc = min(ai.limits.price.min * 10, ai.limits.price.max)
        date = now()
        function dispatched_orders()
            out = Type{<:Order}[]
            for name in names(ot; all=true)
                name == :Order && continue
                otp = getproperty(ot, name)
                if otp isa Type && otp <: ot.Order
                    if applicable(ot.ordertype, otp{Buy})
                        push!(out, otp{Buy})
                        push!(out, otp{Sell})
                    end
                end
            end
            out
        end
        @precomp @ignore begin
            for otp in dispatched_orders()
                pong!(s, ai, otp; amount, date, prc)
            end
            pong!(Returns(nothing), s, ect.InitData(); cols=(:abc,), timeframe=tf"1d")
            pong!(Returns(nothing), s, ect.UpdateData(); cols=(:abc,), timeframe=tf"1d")
            pong!(s, ect.WatchOHLCV())
            pong!(s, ai, 1.0, ect.UpdateLeverage(); pos=Long())
            pong!(s, ai, Short(), date, ect.PositionClose())
            pong!(s, ai, ect.CancelOrders())
        end
    end
    esc(expr)
end
