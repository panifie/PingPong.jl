# FIXME: `pairs` and `timeframe` should swap place to be consistent with `load_ohlcv` func
function fetch_ohlcv(exc::Exchange, timeframe::TimeFrame, pairs::Iterable; kwargs...)
    fetch_ohlcv(exc, string(timeframe), pairs; kwargs...)
end
function fetch_ohlcv(exc, timeframe, pair::AbstractString; kwargs...)
    fetch_ohlcv(exc, string(timeframe), [pair]; kwargs...)
end
function fetch_ohlcv(exc, timeframe; qc=config.qc, kwargs...)
    pairs = tickers(exc, qc; as_vec=true)
    fetch_ohlcv(exc, string(timeframe), pairs; kwargs...)
end

@doc """Fetches OHLCV data for multiple exchanges on the same timeframe.

$(TYPEDSIGNATURES)

This function fetches OHLCV data for multiple exchanges over the same timeframe. It accepts:
- A vector of exchange instances `excs`.
- The desired timeframe `timeframe`.

The function can run in parallel if `parallel` is set to true. If `wait_task` is set to true, the function will wait for all tasks to complete before returning.

You can provide additional parameters using `kwargs`.
"""
function fetch_ohlcv(
    excs::Vector{Exchange},
    timeframe;
    sandbox=true,
    parallel=false,
    wait_task=false,
    kwargs...,
)
    # out_file = joinpath(DATA_PATH, "out.log")
    # err_file = joinpath(DATA_PATH, "err.log")
    # FIXME: find out how io redirection interacts with distributed
    # t = redirect_stdio(; stdout=out_file, stderr=err_file) do
    parallel && _instantiate_workers(:PingPong; num=length(excs))
    # NOTE: The python classes have to be instantiated inside the worker processes
    if eltype(excs) === Symbol
        e_pl = s -> (ex = getexchange!(s; sandbox); (ex, tickers(ex; as_vec=true)))
    else
        e_pl = s -> (getexchange!(Symbol(lowercase(s[1].name)); sandbox), s[2])
    end
    t = @parallel parallel for s in excs
        ex, pl = e_pl(s)
        fetch_ohlcv(ex, timeframe, pl; kwargs...)
    end
    # end
    parallel && wait_task && wait(t)
    t
end

@doc """Prompts user for confirmation before fetching OHLCV data.

$(TYPEDSIGNATURES)

This function prompts the user for confirmation before fetching OHLCV data for the specified arguments `args` and keyword arguments `kwargs`. If the user inputs 'Y', 'y', or simply presses Enter, it proceeds with the `fetch_ohlcv` function. If any other input is given, the function returns `nothing`.
"""
function fetch_ohlcv(::Val{:ask}, args...; kwargs...)
    Base.display("fetch? Y/n")
    ans = String(read(stdin, 1))
    ans ∉ ("\n", "y", "Y") && return nothing
    fetch_ohlcv(args...; qc=config.qc, zi, kwargs...)
end

function fetch_candles(exc::Exchange, tf::TimeFrame, args...; kwargs...)
    fetch_candles(exc, string(tf), args...; kwargs...)
end
