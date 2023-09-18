const CpMarketsVal = Val{:cp_markets}
const CpTick = @NamedTuple begin
    base_currency_id::String
    base_currency_name::String
    quote_currency_id::String
    last_updated::DateTime
    reported_volume_24h_share::Float64
    quotes::Dict{String,Dict{String,Float64}}
end

@doc """ Create a `Watcher` instance that tracks all markets for an exchange (coinpaprika).

"""
function cp_markets_watcher(exc_name::AbstractString, interval=Minute(3))
    cp.check_exc_id(exc_name)
    attrs = Dict{Symbol,Any}()
    attrs[:exc] = exc_name
    attrs[:key] = "cp_$(exc_name)_markets"
    watcher_type = Dict{String,CpTick}
    wid = string(CpMarketsVal.parameters[1], "-", hash(exc_name))
    watcher(watcher_type, wid, CpMarketsVal(); flush=true, process=true, fetch_interval=interval, attrs)
end

function _fetch!(w::Watcher, ::CpMarketsVal)
    mkts = cp.markets(attr(w, :exc))
    if length(mkts) > 0
        result = Dict{String,CpTick}()
        for (_, m) in mkts
            result[SubString(m["pair"])] = fromdict(CpTick, String, m)
        end
        pushnew!(w, result)
        true
    else
        false
    end
end

function _cp_market_append_buffer(dict, buf, maxlen)
    data = @collect_buffer_data buf SubString CpTick
    @append_dict_data dict data maxlen
end
_init!(w::Watcher, ::CpMarketsVal) = default_init(w, Dict{SubString,DataFrame}())
_process!(w::Watcher, ::CpMarketsVal) = default_process(w, _cp_market_append_buffer)
