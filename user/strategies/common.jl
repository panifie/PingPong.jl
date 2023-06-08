using Lang: @ifdebug

const CACHE = Dict{Symbol,Any}()
const THREADSAFE = Ref(true)
const TradeResult = Union{Missing,Nothing,<:Trade,<:OrderError}

_timeframe(s) = s.attrs[:timeframe]
_reset!(s) = begin
    s.attrs[:buydiff] = 1.01
    s.attrs[:selldiff] = 1.005
    s.attrs[:ordertype] = :fok
    s.attrs[:verbose] = false
    s.attrs[:this_close] = nothing
    s.attrs[:prev_close] = nothing
    s.attrs[:timeframe] = s.timeframe
    s.attrs[:params_index] = Dict{Symbol,Int}()
    delete!(s.attrs, :this_close)
    delete!(s.attrs, :prev_close)
    s
end

_overrides!(s) = begin
    for (k, v) in pairs(get(s.attrs, :overrides, ()))
        s.attrs[k] = v
    end
    s
end

getparam(s, params, sym) = params[attr(s, :params_index)[sym]]

_thisclose(s) = s.attrs[:this_close]::Option{Float64}
_prevclose(s) = s.attrs[:prev_close]::Option{Float64}
_thisclose!(s, v) = s.attrs[:this_close] = v
_prevclose!(s, v) = s.attrs[:prev_close] = v

function select_ordertype(s::S, os::Type{<:OrderSide}, p::PositionSide=Long())
    let t = s.attrs[:ordertype]
        if p == Long()
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
        else
            if t == :market
                ShortMarketOrder{os}, t
            elseif t == :ioc
                ShortIOCOrder{os}, t
            elseif t == :fok
                ShortFOKOrder{os}, t
            elseif t == :gtc
                ShortGTCOrder{os}, t
            else
                error("Wrong order type $t")
            end
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

function closepair(s, ai, ats, tf=_timeframe(s))
    data = ai.data[tf]
    prev_date = ats - tf
    if data.timestamp[begin] > prev_date
        _thisclose!(s, nothing)
        return nothing
    end
    _thisclose!(s, closeat(data, ats))
    _prevclose!(s, closeat(data, prev_date))
    nothing
end
