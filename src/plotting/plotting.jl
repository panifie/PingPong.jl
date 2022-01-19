module Plotting

using PythonCall: pyimport, pynew, pycopy!
using DataFramesMeta
using DataFrames: AbstractDataFrame
using Backtest.Misc: PairData, infer_tf, tf_win, options, @pymodule
using Backtest: Analysis

const pyec = pynew()
const opts = pynew()

const echarts_ohlc_cols = (:open, :close, :low, :high)
const cplot = pynew()

function init_pyecharts(reload=false)
    pyec != pynull && !reload && return
    @pymodule pyec pyecharts
    pycopy!(opts, pyec.options)

    reload && begin
        ppwd = pwd()
        cd(dirname(@__FILE__))
        pypath = ENV["PYTHONPATH"]
        if isnothing(match(r".*:?\.:.*", pypath))
	        ENV["PYTHONPATH"] = ".:" * pypath
        end
        pycopy!(cplot, pyimport("src.plotting.plot"))
        pyimport("importlib").reload(cplot)
        cd(ppwd)
    end
end

function passkwargs(args...)
    return [Expr(:kw, a.args[1], a.args[2]) for a in args]
end

macro passkwargs(args...)
    kwargs = [Expr(:kw, a.args[1], a.args[2]) for a in args]
    return esc( :( $(kwargs...) ) )
end

@doc "Initializes pyechart chart class."
macro chart(name, args...)
    kwargs = passkwargs(args...)
    quote
        pyec[].charts.$name($(kwargs...))
    end
end

@doc "Set dates and ohlc data from dataframe columns."
macro df_dates_data()
    dates = esc(:dates)
    data = esc(:data)
    tail = esc(:tail)
    e_df = esc(:df)
    quote
        $dates = $e_df.timestamp[end-$tail:end]
        $data = Matrix{Float64}(@view($e_df[end-$tail:end, collect(c for c in echarts_ohlc_cols)]))
    end
end

macro autotail(df)
    tail = esc(:tail)
    df = esc(df)
    quote
	    if $tail == -1
            $tail = size($df, 1) - 1
        end
    end
end

const chartinds = Dict()
const charttypes = Set()
const bar_inds = Set()
const line_inds = Set()

bar_inds!() = (empty!(bar_inds); union!(bar_inds, ["maxima", "minima", "volume", "renko"]))
line_inds!() = (empty!(line_inds); union!(line_inds, ["sup", "res", "mlr", "mlr_lb", "mlr_ub", "alma"]))
const default_chart_type = "line"

macro charttypes!(type)
    quote
        global chartinds
	    for ind in getproperty(Plotting, Symbol($type, :_inds))
            chartinds[ind] = $type
        end
    end
end

macro chartinds!()
    quote
        empty!(charttypes)
        union!(charttypes, ["bar", "line"])
        bar_inds!()
        line_inds!()
	    for tp in charttypes
            @charttypes! tp
        end
    end
end

@chartinds!

function plotgrid(df, tail=20; name="OHLCV", view=false, inds=[], inds2=[], reload=true)
    init_pyecharts(reload)

    @autotail df
    @df_dates_data

    inds = Dict(ind => (get(chartinds, ind, default_chart_type), getproperty(df, ind)) for ind in inds)
    "volume" ∉ keys(inds) && begin
	    inds[:volume] = ("bar", df.volume)
    end

    cplot.grid(dates, data; inds, name)
end

plotgrid(pairdata::PairData, args...; kwargs...) = plotgrid(pairdata.data, args...; name=pairdata.name, kwargs...)

function plotscatter3d(df; x=:x, y=:y, z=:z, name="", tail=50, reload=true)
    init_pyecharts(reload)

    @autotail df
    local data
    cols = [x, y, z]
    @info "Preparing data..."
    @with df begin
	    data = [[df[n, cols]..., n] for n in 1:size(df, 1)]
    end
    @info "Generating plot..."
	cplot.scatter3d(data; name, x, y, z)
end

function showhere(data::AbstractDataFrame, pred::Function, target::Symbol)
    out = Dict()
    @with data begin
        for row in eachrow(data)
            if pred(row)
                v = row[target]
                out[v] = get(out, v, 0) + 1
            end
        end
    end
    out
end

function countdf(data::AbstractDataFrame)
    local bins
    @with data begin
        bins = Dict(col => Dict() for col in names(data))
	    for col in keys(bins)
            for v in data[:, col]
                pv = get(bins[col], v, 0)
                pv += 1
                bins[col][v] = pv
            end
        end
    end
    bins
end

function heatmap(x, y, v, y_name="", y_labels="", reload=true)
    init_pyecharts(reload)
    x_col = @view df[:, x]
    y_col = @view df[:, y]

    x_axis = collect(minimum(x_col):maximum(x_col))
    y_axis = collect(minimum(y_col):maximum(y_col))
    data = DataFrame(Symbol(x_v) => y_axis for x_v in x_axis)
    @eachrow df begin
        _DF[row, x]
    end
    return
    cplot.heatmap(x_axis, y_axis; y_name, y_labels)
end

@doc "OHLCV plot with bbands and alma indicators."
function plotone(df::AbstractDataFrame, name="")
    _, tfname = infer_tf(df)
    n = tf_win[tfname]
    Analysis.bbands!(df; n)
    df[!, :alma] = Analysis.ind.alma(df.close; n)
    plotgrid(df, -1; name=name, inds=[:alma, :bb_low, :bb_mid, :bb_high])
end

macro plotone(name)
    mrkts = esc(:mrkts)
    name_str = uppercase(string(name))
    v = esc(name)
    quote
        pair = "$($name_str)/$(options["quote"])"
        $v = $(mrkts)[pair].data
        plotone($v, $name_str)
    end
end

export plotscatter3d, plotgrid, heatmap, plotone, @plotone

end
