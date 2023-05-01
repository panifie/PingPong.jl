__revise_mode__ = :eval

const CACHE = Dict{Symbol,Any}()

marketsid(::S) = marketsid(S)

function buy!(s::S, ai, ats, ts)
    st.pop!(s, ai, Sell)
    @deassert ai.asset.qc == nameof(s.cash)
    price = closeat(ai.ohlcv, ats)
    amount = st.freecash(s) / 10.0 / price
    if amount > 0.0
        # t = pong!(s, GTCOrder{Buy}, ai; amount, date=ts, price=1.02price)
        # t = pong!(s, FOKOrder{Buy}, ai; amount, date=ts)
        # t = pong!(s, IOCOrder{Buy}, ai; amount, date=ts)
        t = pong!(s, MarketOrder{Buy}, ai; amount, date=ts)
    end
end

function sell!(s::S, ai, ats, ts)
    st.pop!(s, ai, Buy)
    amount = max(inv(closeat(ai, ats)), inst.freecash(ai))
    price = closeat(ai.ohlcv, ats)
    if amount > 0.0
        # t = pong!(s, GTCOrder{Sell}, ai; amount, date=ts, price=0.99price)
        # t = pong!(s, FOKOrder{Sell}, ai; amount, date=ts)
        # t = pong!(s, IOCOrder{Sell}, ai; amount, date=ts)
        t = pong!(s, MarketOrder{Sell}, ai; amount, date=ts)
    end
end

function isbuy(s::S, ai, ats)
    if s.cash > s.config.min_size
        closepair(ai, ats)
        isnothing(this_close[]) && return false
        this_close[] / prev_close[] > s.attrs[:buydiff]
    else
        false
    end
end

function issell(s::S, ai, ats)
    if ai.cash > 0.0
        closepair(ai, ats)
        isnothing(this_close[]) && return false
        prev_close[] / this_close[] > s.attrs[:selldiff]
    else
        false
    end
end

const this_close = Ref{Option{Float64}}(nothing)
const prev_close = Ref{Option{Float64}}(nothing)

function closepair(ai, ats, tf=tf"1m")
    data = ai.data[tf]
    prev_date = ats - tf
    if data.timestamp[begin] > prev_date
        this_close[] = nothing
        return nothing
    end
    this_close[] = closeat(data, ats)
    prev_close[] = closeat(data, prev_date)
    nothing
end
