module BacktestCLI

using Comonicon
using Backtest
using Base.Iterators: flatten

macro choosepairs()
    pairs = esc(:pairs)
    qc = esc(:qc)
    quote
        if length($pairs) === 0
            if $qc === ""
                $qc = Backtest.options["quote"]
                @info "Using default quote currency $($qc)."
            end
            $pairs = Backtest.Exchanges.get_pairlist($qc) |> keys |> collect
        else
            $qc !== "" && @warn "Ignoring quote: $qc since pairs were supplied."
            $pairs = eltype($pairs) <: AbstractVector ? flatten(p for p in $pairs) : collect($pairs)
        end
    end
end

macro setexchange!()
    exchange = esc(:exchange)
    quote
        @info "Setting Exchange"
        Backtest.setexchange!(Symbol($exchange))
    end
end

"""
Fetch pairs from exchange.

# Arguments

- `p`: pairs to fetch.

# Options

- `-e, --exchange`: Exchange name, e.g. 'Binance'.
- `-t, --timeframe`: Target timeframe, e.g. '1h'.
- `-q, --qc`: Choose pairs with base currencies matching specified quote..
- `--from`: Start downloading from this date (string) or last X candles (Integer).
- `--to`: Download up to this date or relative candle.

# Flags

- `-u, --update`: If set data will be downloaded starting from the last stored timestamp up to now.

"""
@cast function fetch(pairs...; timeframe::AbstractString="1h",
               exchange::AbstractString="kucoin", from="", to="", update=true, qc::AbstractString="")
    @debug "Activating python env..."

    @setexchange!

    @choosepairs

    Backtest.fetch_pairs(timeframe, pairs; from, to, update)
end

"""
Fetch pairs from exchange.

# Arguments

- `p`: pairs to fetch.

# Options

- `-e, --exchange`: Exchange name, e.g. 'Binance'.
- `-f, --from-trimeframe`: Source timeframe to downsample.
- `-t, --target-timeframe`: Timeframe in which data will be converted to and saved.
- `-q, --qc`: Choose pairs with base currencies matching specified quote.

# Flags

"""
@cast function resample(pairs...; from_timeframe::AbstractString="1h",
                        target_timeframe::AbstractString="1d",
                        exchange::AbstractString="kucoin",
                        qc::AbstractString="")
    @setexchange!

    @choosepairs

    @info "Loading pairs with $from_timeframe candles..."
    data = Backtest.Data.load_pairs(pairs, from_timeframe)
    @info "Resampling $(length(data)) pairs to $target_timeframe..."
    Backtest.Analysis.resample(data, target_timeframe)
    @info "Resampling successful."
end

"""
Backtest CLI
"""
@main

"SNOOP_COMPILER" ∉ keys(ENV) && include("../deps/precompiles/precompile_$(@__MODULE__).jl")

end
