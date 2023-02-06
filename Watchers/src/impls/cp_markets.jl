const CpTick = @NamedTuple begin
    base_currency_id::String
    base_currency_name::String
    quote_currency_id::String
    last_updated::DateTime
    reported_volume_24h_share::Float64
    quotes::Dict{String,Dict{String, Float64}}
end


@doc """ Create a `Watcher` instance that tracks all markets for an exchange (coinpaprika).

"""
function cp_markets_watcher(exc_name::AbstractString)
    cp.check_exc_id(exc_name)
    fetcher() = begin
        mkts = cp.markets(exc_name)
        result = Dict{String,CpTick}()
        for (d, m) in mkts
            result[SubString(m["pair"])] = Lang.fromdict(CpTick, String, m)
        end
        result
    end
    name = "cp_$(exc_name)_markets"
    watcher_type = Dict{String, CpTick}
    watcher(watcher_type, name, fetcher; flusher=true, interval=Minute(3))
end
