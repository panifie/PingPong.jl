const CgTick = @NamedTuple begin
    symbol::Symbol
    id::String
    last_updated::DateTime
    current_price::Float64
    high_24h::Float64
    low_24h::Float64
    price_change_24h::Float64
    price_change_percentage_24h::Float64
    fully_diluted_valuation::Option{Float64}
end
const CgTickerVal = Val{:cg_ticker}

@doc """ Create a `Watcher` instance that tracks the price of some currencies on an exchange (coingecko).

"""
function cg_ticker_watcher(syms::AbstractVector; byid=false, interval=Second(360))
    attrs = Dict{Symbol,Any}()
    sort!(syms)
    attrs[:ids] = if byid
        syms
    else
        cg.idbysym.(syms)
    end
    attrs[:key] = join(("cg_ticker", string.(syms)...), "_")
    attrs[:names] = Symbol.(syms)
    watcher_type = NamedTuple{tuple(attrs[:names]...),NTuple{length(syms),CgTick}}
    wid = string(CgTickerVal.parameters[1], "-", hash(syms))
    watcher(
        watcher_type,
        wid,
        CgTickerVal();
        process=true,
        flush=true,
        fetch_interval=interval,
        attrs,
    )
end
cg_ticker_watcher(syms::Vararg; kwargs...) = cg_ticker_watcher([syms...]; kwargs...)

_fetch!(w::Watcher, ::CgTickerVal) = begin
    ids = w[:ids]
    mkts = cg.coinsmarkets(; ids)
    order = Dict(value => index for (index, value) in enumerate(ids))
    ordered = sort(mkts, by=m -> order[m["id"]])
    if length(mkts) > 0
        value = try
            @parsedata CgTick ordered "id"
        catch e
            @error "cg_ticker: failed parsing" exception = e
            rethrow(e)
        end

        pushnew!(w, value)
        true
    else
        false
    end
end
function _cg_ticker_append_buffer(dict, buf, maxlen)
    data = @collect_buffer_data buf Symbol CgTick
    @append_dict_data dict data maxlen
end
_init!(w::Watcher, ::CgTickerVal) = default_init(w, Dict{Symbol,DataFrame}())
_process!(w::Watcher, ::CgTickerVal) = default_process(w, _cg_ticker_append_buffer)
