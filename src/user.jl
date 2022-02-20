@doc "User functions."

using DataFrames
using DataFrames: index
using DataFramesMeta
using Backtest.Misc: @margin!, @lev!
using Statistics: mean
export @margin!, @lev!

if !isdefined(@__MODULE__, :an)
    const an = Backtest.Analysis
end

function kucoin_keys()
    cfg = Dict()
    open(joinpath(ENV["HOME"], "dev", "Backtest.jl", "cfg", "kucoin.json")) do f
        cfg = JSON.parse(f)
    end
        key = cfg["apiKey"]
    secret = cfg["secret"]
    password = cfg["password"]
    Dict("key" => key, "secret" => secret, "pass" => password)
end

const pranges_risky=(0.9, 0.95, 0.955, 1.045, 1.05, 1.1)
const pranges_bal=(0.94, 0.95, 0.955, 1.045, 1.05, 1.06)
const pranges_tight=(0.94, 0.98, 0.985, 1.025, 1.02, 1.06)
const pranges_expa=(0.7, 0.8, 0.9, 0.98, 0.985, 1.025, 1.02, 1.1, 1.2, 1.3)

@doc "Given a price, output price at given ratios."
function price_ranges(price::Number, ranges=:expa)
    if ranges === :bal
        p = pranges_bal
    elseif ranges === :risky
        p = pranges_risky
    elseif ranges === :tight
        p = pranges_tight
    elseif ranges === :expa
        p = pranges_expa
    else
        p = ranges
    end
    DataFrame(Dict(:price => price,
                   [Symbol(r) => price * r for r in p]...))
    # (price, -price * ranges[1], -price * ranges[2], -price * ranges[3], price * ranges[4])
end

function price_ranges(mrkts::AbstractDict, args...; kwargs...)
    r = []
    for p in values(mrkts)
        push!(r, (p.name, price_ranges(p.data.close[end], args...; kwargs...)))
    end
    r
end

function price_ranges(pass::AbstractVector, mrkts::AbstractDict; kwargs...)
    r = []
    for (name, _) in pass
        push!(r, (name, price_ranges(mrkts[name].data.close[end]; kwargs...)))
    end
    r
end

function price_ranges(pair::AbstractString, args...; kwargs...)
    tkrs = Backtest.Exchanges.@tickers true
    price_ranges(tkrs[pair]["last"], args...; kwargs...)
end

macro bbranges(pair, timeframe="8h")
    mrkts = esc(:mrkts)
    !isdefined(an, :bbands!) && an.explore!()
    quote
        df =
        bb =  an.resample($mrkts[$pair], $timeframe) |> an.bbands
        ranges = bb[end, :]
        [name => bb[end, n] for (n, name) in enumerate((:low, :mid, :high))] |>
            DataFrame
    end
end

@doc "Total profit of a ladder of trades"
function gprofit(peak=0.2, grids=10)
    collect(peak/grids:peak/grids:peak) .* inv(grids) |> sum
end


macro excfilter(exc_name)
    @eval begin
        using Backtest.Analysis
        explore!()
    end
    bt = Backtest
    quote
        local trg
        @info "timeframe: $(config.timeframe), window: $(config.window), quote: $(config.qc), min_vol: $(config.vol_min)"
	    @exchange! $exc_name
        pred = x -> $bt.Analysis.slopeangle(x; window=config.window)
        data = ($bt.Exchanges.get_pairlist($exc_name, config.qc) |> (x -> $bt.load_pairs($bt.Data.zi, $exc_name, x, config.timeframe)))
        flt = $bt.filter(pred, data, config.slope_min, config.slope_max)
        trg = DataFrame([(p[2].name, p[1], price_ranges(p[2].close[end])) for p in flt])
        results[lowercase($(exc_name).name)] = (;trg, flt, data)
        $(esc(:res)) = results[lowercase($(exc_name).name)]
        trg
    end
end

function vcons(data, tfs = []; cargs = (), vargs = (), sargs = (), onevi = false)
    !isdefined(Main, :an) && @eval begin
        @info "Loading Analysis..."
        using Backtest.Analysis
        Analysis.@pairtraits!
    end
    an = @eval Backtest.Analysis
    datargs = isempty(tfs) ? (data,) : (data, tfs)
    @info "Considerations..."
    c_t = @async an.Considerations.considerations(datargs...; cargs..., sorted = false)
    @info "Stage 2..."
    s_t = @async an.Considerations.stage2(datargs...; sargs..., sorted = false)
    @info "Violations..."
    onevi && (datargs = isempty(tfs) ? (data, ) : (data, tfs[end:end]))
    v_t = @async an.Violations.violations(datargs...; vargs..., sorted = false)

    c = (wait(c_t); c_t.result)
    s = (wait(s_t); s_t.result)
    v = (wait(v_t); v_t.result)

    @info "Merging..."
    sk = length(datargs) > 1 ? :score_sum : :score
    t = vcat(c, s, v)
    gb = groupby(t, :pair)
    res = combine(gb, sk => sum; renamecols = false)
    sort!(res, sk)
    edges = vcat((@views res[1:10, :], res[end-10:end, :])...)
    display(edges)
    edges, res
end

@doc "Filter pairs in `hs` that are bottomed longs."
function cbot(hs::AbstractDataFrame, mrkts; n::StepRange=30:-3:3, min_n=5, sort_col=:score_sum)
    bottomed = []
    for r in n
        append!(bottomed, an.find_bottomed(mrkts; n=r) |> keys)
        length(bottomed) < min_n || break
    end
    mask = [p ∈ bottomed for p in hs.pair]
    sort(@view(hs[mask, :]), sort_col)
end

@doc "Filter pairs in `hs` that are peaked shorts."
function cpek(hs::AbstractDataFrame, mrkts; n::StepRange=30:-3:3, min_n=5, sort_col=:score_sum)
    peaked = []
    for r in n
        append!(peaked, an.find_peaked(mrkts; n=r) |> keys)
        length(peaked) < min_n || break
    end
    mask = [p ∈ peaked for p in hs.pair]
    sort(@view(hs[mask, :]), sort_col)
end

@doc "Sorted MVP."
function smvp(mrkts)
    mrkts = an.resample(mrkts, "1d"; save=false)
    mvp = an.MVP.discrete_mvp(mrkts)[1] |> DataFrame
    mvp[!, :score_sum] = mvp.m .+ mvp.v .+ mvp.p
    sort!(mvp, :score_sum)
end

@doc "The average rate of change for a universe of markets."
function average_roc(mrkts)
    positive = Float64[]
    negative = Float64[]
    for pair in values(mrkts)
        roc = pair.data.close[end] / pair.data.close[end-1] - 1.
        if roc > 0.
            push!(positive, roc)
        else
            push!(negative, roc)
        end
    end
    mpos = mean(positive)
    mneg = mean(negative)
    DataFrame(:positive => mpos, :negative => mneg, :ratio => mpos / abs(mneg))
end

macro setup(exc)
    a = esc(:an)
    m = esc(:mrkts)
    mr = esc(:mrkts_r)
    quote
        $a = an
        Backtest.setexchange!($exc)
        $m = load_pairs("15m")
        $mr = an.resample($m, "1d"; save=false)
    end
end

macro otime()
    m = esc(:mrkts)
    quote
        first($m).second.data[end, :timestamp]
    end
end

export @excfilter, price_ranges, @bbranges, vcons, gprofit, smvp, cbot, cpek, @otime, @setup
