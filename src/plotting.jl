using PyCall
using Conda

const pyo = py"object"
const pyec = Ref(pyo)
const opts = Ref(pyo)
const pyec_loaded = Ref(false)
const echarts_ohlc_cols = (:open, :close, :low, :high)
const cplot = Ref(pyo)

function init_pyecharts(reload=false)
    pyec_loaded[] && !reload && return
    try
        pyec[] = pyimport("pyecharts")
    catch
        Conda.pip("install", "pyecharts")
        pyec[] = pyimport("pyecharts")
    finally
        pyec_loaded[] = true
        opts[] = pyec[].options
    end
    reload && begin
        ppwd = pwd()
        cd(dirname(@__FILE__))
        pypath = ENV["PYTHONPATH"]
        if isnothing(match(r".*:?\.:.*", pypath))
	        ENV["PYTHONPATH"] = ".:" * pypath
        end
        cplot[] = pyimport("src.plot")
        pyimport("importlib").reload(cplot[])
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
line_inds!() = (empty!(line_inds); union!(line_inds, ["sup", "res", "mlr", "mlr_lb", "mlr_ub"]))

macro charttypes!(type)
    quote
        global chartinds
	    for ind in getproperty(Backtest, Symbol($type, :_inds))
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

    inds = Dict(ind => (chartinds[ind], getproperty(df, ind)) for ind in inds)
    "volume" ∉ keys(inds) && begin
	    inds["volume"] = ("bar", df.volume)
    end

    cplot[].grid(dates, data; inds, name)
end

plotgrid(pairdata::PairData, args...; kwargs...) = plotgrid(pairdata.data, args...; name=pairdata.name, kwargs...)
