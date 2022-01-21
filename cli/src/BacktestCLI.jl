module BacktestCLI

using Comonicon
using Backtest
using Base.Iterators: flatten

"""
Fetch pairs from exchange.

# Arguments

- `p`: pairs to fetch.

# Options

- `-e, --exchange`: Exchange name, e.g. 'Binance'.
- `-t, --timeframe`: Target timeframe, e.g. '1h'.
- `-q, --qc`: Will download all the base currencies matching specified quote.
- `--from`: Start downloading from this date (string) or last X candles (Integer).
- `--to`: Download up to this date or relative candle.

# Flags

- `-u, --update`: If set data will be downloaded starting from the last stored timestamp up to now.

"""
@cast function fetch(pairs...; timeframe::AbstractString="1h",
               exchange::AbstractString="kucoin", from="", to="", update=true, qc::AbstractString="")
    @debug "Activateing python env..."

    @info "Setting Exchange"
    Backtest.setexchange!(Symbol(exchange))
    if length(pairs) === 0
        if qc === ""
            qc = Backtest.options["quote"]
            @info "Using default quote currency $qc."
        end
        Backtest.fetch_pairs(timeframe; qc, from, to, update)
    else
        qc !== "" && @warn "Ignoring quote: $qc since pairs were supplied."
        pairs = eltype(pairs) <: AbstractVector ? flatten(p for p in pairs) : collect(pairs)
        Backtest.fetch_pairs(timeframe, pairs; from, to, update)
    end
end

"""
Backtest CLI
"""
@main

"SNOOP_COMPILER" ∉ keys(ENV) && include("../deps/precompiles/precompile_$(@__MODULE__).jl")

end
