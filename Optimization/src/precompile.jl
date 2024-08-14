using SimMode.Misc.Lang: @precomp, @preset, @ignore
using Stats: sharpe

function _precomp_strat(mod=Optimization)
    @eval mod begin
        using .SimMode: Executors as ect, sml
        using .SimMode.Misc: ZERO

        s = st.strategy(st.BareStrat)
        for ai in s.universe
            append!(
                st.Instances.ohlcv_dict(ai)[s.timeframe],
                sml.Processing.Data.to_ohlcv(sml.synthohlcv());
                cols=:union,
            )
        end
        s
    end
end

@preset begin
    st.Instances.Exchanges.Python.py_start_loop()
    s = _precomp_strat()
    function st.ping!(::typeof(s), ::ect.OptSetup)
        (;
            ctx=Context(Sim(), tf"1d", dt"2020-", now()),
            params=(x=1:2, y=0.0:0.5:1.0),
            space=(kind=:MixedPrecisionRectSearchSpace, precision=Int[0, 1]),
        )
    end
    function st.ping!(s::typeof(s), params, ::OptRun)
        attrs = s.attrs
        attrs[:param_x] = round(Int, params[1])
        attrs[:param_y] = params[2]
    end
    function st.ping!(s::typeof(s), ts::DateTime, ctx)
        attrs = s.attrs
        x = attrs[:param_x]
        y = attrs[:param_y]
        side = ifelse(rand(1:x) < 2, st.Buy, st.Sell)
        for ai in s.universe
            amount = if side == st.Buy
                st.cash(s)
            else
                @something st.cash(ai) 0.0
            end / st.closeat(ai, ts) / 3
            ect.pong!(s, ai, st.OrderTypes.MarketOrder{side}; amount, date=ts)
        end
    end

    function st.ping!(s::typeof(s), ::OptScore)::Vector
        [sharpe(s)]
    end
    @precomp @ignore begin
        gridsearch(s; resume=false)
        gridsearch(s; resume=true)
        progsearch(s)
        slidesearch(s)
        bboptimize(s; MaxSteps=2)
    end

    st.Instances.Exchanges.Python.py_stop_loop()
end
