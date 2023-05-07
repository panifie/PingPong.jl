using Lang: @ifdebug

const CACHE = Dict{Symbol,Any}()

_reset!(s) = begin
    s.attrs[:buydiff] = 1.01
    s.attrs[:selldiff] = 1.005
    s.attrs[:ordertype] = :fok
    for (k, v) in pairs(get(s.attrs, :overrides, ()))
        s.attrs[k] = v
    end
    s
end

select_ordertype(s::S, os::Type{<:OrderSide}) = begin
    let t = s.attrs[:ordertype]
        if t == :market
            MarketOrder{os}, t
        elseif t == :ioc
            IOCOrder{os}, t
        elseif t == :fok
            FOKOrder{os}, t
        elseif t == :gtc
            GTCOrder{os}, t
        else
            error("Wrong order type $t")
        end
    end
end

function select_orderkwargs(otsym::Symbol, ::Type{Buy}, ai, ats)
    if otsym == :gtc
        (; price=1.02 * closeat(ai.ohlcv, ats))
    else
        ()
    end
end

function select_orderkwargs(otsym::Symbol, ::Type{Sell}, ai, ats)
    if otsym == :gtc
        (; price=0.99 * closeat(ai.ohlcv, ats))
    else
        ()
    end
end

marketsid(::S) = marketsid(S)

function buy!(s::S, ai, ats, ts)
    pong!(s, CancelOrders(), ai, Sell)
    @deassert ai.asset.qc == nameof(s.cash)
    price = closeat(ai.ohlcv, ats)
    amount = st.freecash(s) / 10.0 / price
    if amount > 0.0
        ot, otsym = select_ordertype(s, Buy)
        kwargs = select_orderkwargs(otsym, Buy, ai, ats)
        t = pong!(s, ot, ai; amount, date=ts, kwargs...)
    end
end

function sell!(s::S, ai, ats, ts)
    pong!(s, CancelOrders(), ai, Buy)
    amount = max(inv(closeat(ai, ats)), inst.freecash(ai))
    if amount > 0.0
        ot, otsym = select_ordertype(s, Sell)
        kwargs = select_orderkwargs(otsym, Sell, ai, ats)
        t = pong!(s, ot, ai; amount, date=ts, kwargs...)
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
