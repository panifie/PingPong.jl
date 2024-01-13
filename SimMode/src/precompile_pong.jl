macro compile_pong()
    expr = quote
        @eval begin
            isdefined(@__MODULE__, :OrderTypes) || using .OrderTypes: OrderTypes as ot
            using .OrderTypes: Buy, Sell
            using .Lang: @ignore, @precomp
            isdefined(@__MODULE__, :Executors) ||
                using .Executors: pong!, Executors as ect
        end

        let
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
            @precomp @ignore @sync begin
                for otp in dispatched_orders()
                    @async pong!(s, ai, otp; amount, date, prc, synced=false)
                end
                @async pong!(
                    Returns(nothing),
                    s,
                    ect.InitData();
                    cols=(:abc,),
                    timeframe=tf"1d",
                    synced=false,
                )
                @async pong!(
                    Returns(nothing),
                    s,
                    ect.UpdateData();
                    cols=(:abc,),
                    timeframe=tf"1d",
                    synced=false,
                )
                @async pong!(s, ect.WatchOHLCV(), synced=false)
                @async pong!(s, ai, 1.0, ect.UpdateLeverage(); pos=Long(), synced=false)
                @async pong!(s, ai, Short(), date, ect.PositionClose(), synced=false)
                @async pong!(s, ai, ect.CancelOrders(), synced=false)
            end
        end
    end
    esc(expr)
end
