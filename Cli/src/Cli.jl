module Cli

using Base.Iterators: flatten
using Comonicon
using Data: load_ohlcv
using Exchanges
using Exchanges: get_pairlist
using Fetch
using Misc: Exchange, config
using Processing: resample

macro choosepairs()
    pairs = esc(:pairs)
    qc = esc(:qc)
    vol = esc(:vol)
    ev = esc(:exchanges_vec)
    quote
        if length($pairs) === 0
            if $qc === ""
                $qc = config.qc
                @info "Using default quote currency $($qc)."
            end
            $pairs = [e => get_pairlist(e, $qc, $vol; as_vec=true) for e in $ev]
        else
            $qc !== "" && @warn "Ignoring quote: " * $qc " since pairs were supplied."
            pl = eltype($pairs) <: AbstractVector ? flatten(p for p in $pairs) : collect($pairs)
            $pairs = [e => pl for e in $ev]
        end
    end
end

# macro setexchange!()
#     exchange = esc(:exchange)
#     quote
#         @info "Setting Exchange"
#         JuBot.setexchange!(Symbol($exchange))
#     end
# end

macro splitexchanges!(keep=false)
    exchanges = esc(:exchanges)
    ev = esc(:exchanges_vec)
    conv = keep ? Symbol : x -> getexchange(Symbol(x))
    quote
        $ev = map($conv, split($exchanges, ','; keepempty=false))
        @info "Executing command on $(length($ev)) exchanges..."
    end
end

"""
Fetch pairs from exchanges.

# Arguments

- `pairs`: pairs to fetch.

# Options

- `-e, --exchanges`: Exchange name, e.g. 'Binance'.
- `-t, --timeframe`: Target timeframe, e.g. '1h'.
- `-q, --qc`: Choose pairs with base currencies matching specified quote.
- `-v, --vol`: Minimum volume for pairs.
- `--from`: Start downloading from this date (string) or last X candles (Integer).
- `--to`: Download up to this date or relative candle.

# Flags

- `-n, --noupdate`: If set data will be downloaded starting from the last stored timestamp up to now.
- `-p, --progress`: Show progress.
- `-m, --multiprocess`: Fetch from multiple exchanges using one process per exchange. (High memory usage)
- `-r, --reset`: Reset saved data.

"""
@cast function fetch(pairs...; timeframe::AbstractString="1h",
               exchanges::AbstractString="kucoin", from="", to="", vol::Float64=1e4,
                     noupdate::Bool=false, qc::AbstractString="", progress::Bool=false,
                     multiprocess::Bool=false, reset::Bool=false)
    @debug "Activating python env..."

    # NOTE: don't create exchange classes since multiple exchanges uses @distributed
    # and the (python) class is create on the worker process
    @splitexchanges!

    @choosepairs

    fetch_ohlcv(pairs, timeframe; parallel=multiprocess, wait_task=true,
                         from, to, update=(!noupdate), progress, reset)
end

"""
Downsamples ohlcv data from a timeframe to another.

# Arguments

- `pairs`: pairs to fetch.

# Options

- `-e, --exchanges`: Exchange name(s), e.g. 'Binance'.
- `-f, --from-timeframe`: Source timeframe to downsample.
- `-t, --target-timeframe`: Timeframe in which data will be converted to and saved.
- `-q, --qc`: Choose pairs with base currencies matching specified quote.

# Flags
- `-p, --progress`: Show Progress

"""
@cast function resample_data(pairs...; from_timeframe::AbstractString="1h",
                        target_timeframe::AbstractString="1d",
                        exchanges::AbstractString="kucoin",
                        qc::AbstractString="", progress::Bool=false)
    @splitexchanges!

    vol = config.vol_min
    @choosepairs

    for (exc, prs) in pairs
        @info "Loading pairs with $from_timeframe candles from $(exc.name)..."
        data = load_ohlcv(exc, prs, from_timeframe)
        @info "Resampling $(length(data)) pairs to $target_timeframe..."
        resample(exc, data, target_timeframe;)
    end
    @info "Resampling successful."
end

"""
JuBot CLI
"""
@main

include("precompile_includer.jl")
end
