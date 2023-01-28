# using PythonCall: pyimport, pynew, pycopy!, pyisnull, PyDict, @py, Py, pystr, PyList
using DataFramesMeta
using DataFrames: AbstractDataFrame
using TimeTicks: TimeTicks, tf_win, @infertf
using Misc: config
using Data: PairData
using Python
using Python.PythonCall: pyisnull, pynew
using Analysis

const pyec = pynew()
const opts = pynew()
const np = pynew()

const echarts_ohlc_cols = (:open, :close, :low, :high)
const cplot = pynew()

# function __init__()
#     init_pyecharts()
# end

@doc "Loads pyecharts python module."
function init_pyecharts(reload=false)
    !pyisnull(pyec) && !reload && return nothing
    @pymodule pyec pyecharts
    @pymodule np numpy
    pycopy!(opts, pyec.options)

    ppwd = pwd()
    reload && try
        cd(dirname(@__FILE__))
        pypath = ENV["PYTHONPATH"]
        if isnothing(match(r".*:?\.:.*", pypath))
            ENV["PYTHONPATH"] = ".:" * pypath
        end
        pycopy!(cplot, pyimport("src.plotting.plot"))
        pyimport("importlib").reload(cplot)
    finally
        cd(ppwd)
    end
end

function passkwargs(args...)
    return [Expr(:kw, a.args[1], a.args[2]) for a in args]
end

macro passkwargs(args...)
    kwargs = [Expr(:kw, a.args[1], a.args[2]) for a in args]
    return esc(:($(kwargs...)))
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
        $dates = $e_df.timestamp[(end - $tail):end]
        $data = Matrix{Float64}(
            @view($e_df[(end - $tail):end, collect(c for c in echarts_ohlc_cols)])
        )
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
function line_inds!()
    (empty!(line_inds);
    union!(line_inds, ["sup", "res", "mlr", "mlr_lb", "mlr_ub", "alma"]))
end
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

@doc "Plots ohlcv data overlaying indicators `inds` and `inds2`."
function plotgrid(df, tail=20; name="OHLCV", view=false, inds=[], inds2=[], reload=true)
    init_pyecharts(reload)

    @autotail df
    @df_dates_data

    inds = PyDict(
        pystr(ind) =>
            (get(chartinds, ind, default_chart_type), PyList(getproperty(df, ind))) for
        ind in inds
    )
    "volume" ∉ keys(inds) && begin
        @py inds["volume"] = ("bar", PyList(df.volume))
    end

    @info "Plotting..."
    data = PyList(PyList(@view(data[n, :])) for n in 1:size(data, 1))
    cplot.grid(PyList(dates), data; inds, name)
    nothing
end

function plotgrid(pairdata::PairData, args...; timeframe="15m", kwargs...)
    data = Analysis.resample(pairdata, timeframe)
    plotgrid(data, args...; name=pairdata.name, kwargs...)
end

@doc "Scatter plot only the end of a dataframe given from `tail`."
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

@doc "Bincount dataframe"
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

@doc "Heatmap of between two series."
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
    return nothing
    cplot.heatmap(x_axis, y_axis; y_name, y_labels)
end

plotone(args...; kwargs...) = begin
    isdefined(Analysis, :bbands!) || Analysis.explore!()
    _plotone(args...; kwargs...)
end

@doc "OHLCV plot with bbands and alma indicators."
function _plotone(pair::PairData; timeframe="15m", n_bb=nothing, n_mul=100)
    df = Analysis.resample(pair, timeframe)
    # FIXME
    tf = @infertf(df)
    n = isnothing(n_bb) ? tf_win[td_tf[tf.period]] : n_bb
    @info "Bbands with window $n..."
    Analysis.bbands!(df; n)
    df[!, :alma] = Analysis.ind.alma(df.close; n)
    plotgrid(df, size(df, 1) - 1; name=pair.name, inds=[:alma, :bb_low, :bb_mid, :bb_high])
end

macro plotone(name, bb_args...)
    mrkts = esc(:mrkts)
    name_str = uppercase(string(name))
    kwargs = passkwargs(bb_args...)
    quote
        pair = "$($name_str)/$(config.qc)"
        plotone($(mrkts)[pair]; $(kwargs...))
    end
end

export plotscatter3d, plotgrid, heatmap, plotone, @plotone
