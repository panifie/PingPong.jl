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
