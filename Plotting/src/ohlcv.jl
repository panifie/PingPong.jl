using TimeTicks
using Data.DataFrames
using Data.DFUtils
using Data: AbstractDataFrame
using Processing: resample

function candle_str(row)
    """O: $(cn(row.open))
    H: $(cn(row.high))
    L: $(cn(row.low))
    C: $(cn(row.close))
    V: $(cn(row.volume))
    T: $(row.timestamp)"""
end

function candle_tooltip_func(df)
    function f(inspector, plot, idx, _)
        try
            idx = tooltip_position!(inspector, plot, idx; vertices=4)
            tooltip_text!(inspector, candle_str(df[idx, :]); size=3.0)
        catch
        end
        return true
    end
end

function vol_point(width, x, y)
    Point2f[(x - width, 0.0), (x + width, 0.0), (x + width, y), (x - width, y)]
end
function ohlcv_point(width, x, y1, y2)
    y1 == y2 && (y1 += y1 * 0.01)
    Point2f[(x - width, y1), (x + width, y1), (x + width, y2), (x - width, y2)]
end

function plot_ohlcv(df::AbstractDataFrame, tf=tf"1d"; fig=makefig())
    isnothing(tf) || (df = resample(df, timeframe(df), tf))
    firstdate = df.timestamp[begin]
    # Formats the timestamps for the X axis
    xidxtodate(t) = [string(firstdate + timeframe(df).period * round(Int, tt)) for tt in t]
    # Formates the Y axis values
    yidxcompact(t) = cn.(t)
    # Axis creation (Order is important)
    vol_ax = Axis(
        fig[1, 1];
        ytickformat=yidxcompact,
        ylabel="Volume",
        ypanlock=true,
        yzoomlock=true,
        yaxisposition=:right,
    )
    price_ax = Axis(
        fig[1, 1];
        xtickformat=xidxtodate,
        ytickformat=yidxcompact,
        title="OHLC",
        xlabel="Time",
        xaxisposition=:top,
        ylabel="Price",
        # Only scroll and zoom horizontally
        ypanlock=true,
        yzoomlock=true,
        yrectzoom=false,
    )
    # OHLCV doesn't need spines
    hidespines!(price_ax)
    hidespines!(vol_ax)
    # We already have X from the price axis
    hidexdecorations!(vol_ax)
    # This volume interactions since it is in the background
    deregister_interaction!(vol_ax, :rectanglezoom)

    # Now we iterate over the dataframe, to construct
    # candles polygons from their values
    # we use a wider one for open/close
    # and a thinner rectangle for high/low
    width = 0.4 # candle width
    makevec(type) = Vector{type}(undef, nrow(df))
    oc_points = makevec(Vector{Point2f})
    hl_points = makevec(Vector{Point2f})
    vol_points = makevec(Vector{Point2f})
    colors = makevec(Symbol)
    for (n, row) in enumerate(eachrow(df))
        date = n
        open = row.open
        close = row.close
        colors[n] = open < close ? :green : :red
        oc_points[n] = ohlcv_point(width, date, open, close)
        hl_points[n] = ohlcv_point(width / 10.0, date, row.high, row.low)
        vol_points[n] = vol_point(width, date, row.volume)
    end
    # get the candle tooltip function, for the DF we are plotting
    candle_tooltip = candle_tooltip_func(df)
    poly_kwargs = (; inspector_hover=candle_tooltip) # inspector_clear=candle_tooltip_clear)
    # Constructs all the polygons from the candles Points (order is important)
    poly!(vol_ax, vol_points; color=(:grey, 0.5), inspectable=false, poly_kwargs...)
    poly!(price_ax, hl_points; color=colors, inspectable=false, poly_kwargs...)
    poly!(price_ax, oc_points; color=colors, poly_kwargs...)
    # Ansure that volume and price axies are linked
    # such that when we zoom/pan they move together
    linkxaxes!(price_ax, vol_ax)


    # Reduce the size of the volume axis which will appear
    # smaller at the bottom
    # rowsize!(fig.layout, 2, Aspect(1, 0.05))
    # Make sure the volume and price axis are close together
    # rowgap!(fig.layout, 1, 0.0)
    # Enables the tooltip function on the figure
    DataInspector(price_ax; priority=-1)
    fig, price_ax
end

export plot_ohlcv
