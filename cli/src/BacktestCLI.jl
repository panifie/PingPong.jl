module BacktestCLI

using Comonicon
using Backtest
using Base.Iterators: flatten

macro choosepairs()
    pairs = esc(:pairs)
    qc = esc(:qc)
    ev = esc(:exchanges_vec)
    quote
        if length($pairs) === 0
            if $qc === ""
                $qc = Backtest.options["quote"]
                @info "Using default quote currency $($qc)."
            end
            $pairs = Dict(e => Backtest.Exchanges.get_pairlist(e, $qc) |> keys |> collect
                          for e in $ev)
        else
            $qc !== "" && @warn "Ignoring quote: $qc since pairs were supplied."
            pl = eltype($pairs) <: AbstractVector ? flatten(p for p in $pairs) : collect($pairs)
            $pairs = Dict(e => pl for e in $ev)
        end
    end
end

# macro setexchange!()
#     exchange = esc(:exchange)
#     quote
#         @info "Setting Exchange"
#         Backtest.setexchange!(Symbol($exchange))
#     end
# end

macro splitexchanges!()
    exchanges = esc(:exchanges)
    ev = esc(:exchanges_vec)
    quote
        $ev = map(x -> Backtest.Exchanges.Exchange(Symbol(x)), split($exchanges, ','; keepempty=false))
        @info "Executing command on $(length($ev)) exchanges..."
    end
end

"""
Fetch pairs from exchange.

# Arguments

- `pairs`: pairs to fetch.

# Options

- `-e, --exchanges`: Exchange name, e.g. 'Binance'.
- `-t, --timeframe`: Target timeframe, e.g. '1h'.
- `-q, --qc`: Choose pairs with base currencies matching specified quote..
- `--from`: Start downloading from this date (string) or last X candles (Integer).
- `--to`: Download up to this date or relative candle.

# Flags

- `--update`: If set data will be downloaded starting from the last stored timestamp up to now.
- `--progress`: Show progress.

"""
@cast function fetch(pairs...; timeframe::AbstractString="1h",
               exchanges::AbstractString="kucoin", from="", to="", update::Bool=true, qc::AbstractString="", progress::Bool=false)
    @debug "Activating python env..."

    @show exchanges, split(exchanges, ','; keepempty=false)
    @splitexchanges!

    @choosepairs

    Backtest.fetch_pairs(pairs, timeframe; from, to, update, progress)
end

"""
Fetch pairs from exchange.

# Arguments

- `pairs`: pairs to fetch.

# Options

- `-e, --exchanges`: Exchange name(s), e.g. 'Binance'.
- `-f, --from-trimeframe`: Source timeframe to downsample.
- `-t, --target-timeframe`: Timeframe in which data will be converted to and saved.
- `-q, --qc`: Choose pairs with base currencies matching specified quote.

# Flags

"""
@cast function resample(pairs...; from_timeframe::AbstractString="1h",
                        target_timeframe::AbstractString="1d",
                        exchanges::AbstractString="kucoin",
                        qc::AbstractString="")
    @splitexchanges!

    @choosepairs

    for e in exchanges_vec
        @info "Loading pairs with $from_timeframe candles from $(e.name)..."
        data = Backtest.Data.load_pairs(e, pairs, from_timeframe)
        @info "Resampling $(length(data)) pairs to $target_timeframe..."
        Backtest.Analysis.resample(e, data, target_timeframe;)
    end
    @info "Resampling successful."
end

"""
Backtest CLI
"""
@main

"SNOOP_COMPILER" ∉ keys(ENV) && include("../deps/precompiles/precompile_$(@__MODULE__).jl")

end
