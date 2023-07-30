import .Data: propagate_ohlcv!
using .Data.DFUtils: copysubs!

@doc """[`Main.Engine.Instances.fill!`](@ref Main.Engine.Instances.fill!) all the instances with given timeframes data..."""
function Base.fill!(ac::AssetCollection, tfs...; kwargs...)
    @eachrow ac.data fill!(:instance, tfs...; kwargs...)
end

@doc "Replaces the data of the asset instances with `src` which should be a mapping. Used for backtesting.

`src`: The mapping, should be a pair `TimeFrame => Dict{String, PairData}`.

Example:
```julia
using Scrapers.BinanceData as bn
using Strategies
using Exchanges
setexchange!(:binanceusdm)
cfg = Config(nameof(exc.id))
strat = strategy!(:Example, cfg)
data = bn.binanceload()
stub!(strat.universe, data)
```
"
function stub!(ac::AssetCollection, src; fromfiat=true)
    parse_args = fromfiat ? (fiatnames,) : ()
    src_dict = swapkeys(
        src, NTuple{2,Symbol}, k -> let a = parse(AbstractAsset, k, parse_args...)
            (a.bc, a.qc)
        end
    )
    for inst in ac.data.instance
        for tf in keys(inst.data)
            pd = get(src_dict, (inst.asset.bc, inst.asset.qc), nothing)
            isnothing(pd) && continue
            new_data = resample(pd, tf)
            try
                empty!(inst.data[tf])
                append!(inst.data[tf], new_data)
            catch
                inst.data[tf] = new_data
            end
        end
    end
end

function _check_timeframes(tfs, from_tf)
    s_tfs = sort([t for t in tfs])
    sort!(s_tfs)
    if tfs[begin] < from_tf
        throw(
            ArgumentError("Timeframe $(tfs[begin]) is shorter than the shortest available.")
        )
    end
end

# Check if we have available data
function _load_smallest!(i, tfs, from_data, from_tf, exc, force=false)
    if size(from_data)[1] == 0 || force
        force && begin
            copysubs!(from_data, empty)
            empty!(from_data)
        end
        copysubs!(from_data)
        append!(from_data, load(zi, exc.name, i.asset.raw, string(from_tf)))
        if size(from_data)[1] == 0 || force
            for to_tf in tfs
                to_tf == from_tf && continue
                if force
                    data = i.data[to_tf]
                    copysubs!(data, empty)
                    empty!(data)
                else
                    i.data[to_tf] = empty_ohlcv()
                end
            end
            return force
        end
        true
    else
        true
    end
end

function _load_rest!(
    ai, tfs, from_tf, from_data, exc=ai.exchange, force=false; from=nothing
)
    exc_name = exc.name
    name = ai.asset.raw
    dr = daterange(from_data)
    ai_tfs = Set(keys(ai.data))
    from = @something from dr.start
    for to_tf in tfs
        if to_tf ∉ ai_tfs || force # current tfs
            from_sto = load(zi, exc_name, ai.asset.raw, string(to_tf); from, to=dr.stop)
            ai.data[to_tf] =
                if size(from_sto)[1] > 0 && let dr_sto = daterange(from_sto)
                    dr_sto.start >= apply(to_tf, from) &&
                        dr_sto.stop <= apply(to_tf, dr.stop)
                end
                    from_sto
                else
                    # NOTE: resample fails if `from_data` is corrupted (not contiguous)
                    resample(from_data, from_tf, to_tf; exc_name, name)
                end
        end
    end
end

@doc "Pulls data from storage, or resample from the shortest timeframe available."
function Base.fill!(ai::AssetInstance, tfs...; exc=ai.exchange, force=false, from=nothing)
    # asset timeframes dict is sorted
    (from_tf, from_data) = first(ai.data)
    _check_timeframes(tfs, from_tf)
    _load_smallest!(ai, tfs, from_data, from_tf, exc, force) || return nothing
    _load_rest!(ai, tfs, from_tf, from_data, exc, force; from)
end

function propagate_ohlcv!(ai::AssetInstance)
    # from `Fetch` module
    propagate_ohlcv!(ai.data, ai.asset.raw, ai.exchange)
end

propagate_ohlcv!(s::Strategy) = foreach(propagate_ohlcv!, universe(s))
