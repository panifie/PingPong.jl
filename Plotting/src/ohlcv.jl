using .ect.TimeTicks
using .ect.Strategies.Data
using .Data.DataFrames
using .Data.DFUtils
using .Data: AbstractDataFrame
using .Data.DataFramesMeta
using Processing: resample

maybe_asset(a) = isnothing(a) ? "" : "Asset: $(a)\n"
function candle_str(row, asset=nothing)
    """$(maybe_asset(asset))O: $(cn(row.open))
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

@doc """
$(TYPEDSIGNATURES)
Plots ohlcv data from dataframe `df`, resampling to `tf`.
"""
ohlcv(df::AbstractDataFrame, tf=tf"1d"; kwargs...) = ohlcv!(makefig(), df, tf; kwargs...)

# function definescaler(f; limits=(0.0, 100.0), interval=-Inf .. Inf)
#     @eval begin
#         Makie.defaultlimits(::typeof($f)) = $limits
#         Makie.defined_interval(::typeof($f)) = $interval
#     end
# end

@doc """
$(TYPEDSIGNATURES)
Same as `ohlcv` but over input `Figure`
"""
function ohlcv!(fig::Figure, df::AbstractDataFrame, tf=tf"1d")
    isnothing(tf) || (df = resample(df, timeframe!(df), tf))
    # Axis creation (Order is important)
    vol_ax = Axis(fig[1, 1]; ytickformat=ytickscompact, ylabel="Volume", yaxisposition=:right)
    price_ax = makepriceax(fig; xticksargs=(df.timestamp[begin], timeframe!(df)))
    # OHLCV doesn't need spines
    hidespines!(price_ax)
    hidespines!(vol_ax)
    # We already have X from the price axis
    hidexdecorations!(vol_ax)
    # Disable volume interactions since it is in the background
    deregister_interactions!(vol_ax, (:scrollzoom, ))

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
    # FIXME: Can't seem able to escape symbols using ^() syntax in the macro
    let n = 1, red = :red, green = :green
        @eachrow df begin
            date = n
            colors[n] = :open < :close ? green : red
            oc_points[n] = ohlcv_point(width, date, :open, :close)
            hl_points[n] = ohlcv_point(width / 10.0, date, :high, :low)
            vol_points[n] = vol_point(width, date, :volume)
            n += 1
        end
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
    # But only link x axes to keep vol always in the background when zooming
    linkxaxes!(price_ax, vol_ax)

    # Reduce the size of the volume axis which will appear
    # smaller at the bottom
    # rowsize!(fig.layout, 2, Aspect(1, 0.05))
    # Make sure the volume and price axis are close together
    # rowgap!(fig.layout, 1, 0.0)
    # Enables the tooltip function on the figure
    di = DataInspector(price_ax; priority=-1)
    fig.attributes[:inspector] = di
    fig
end

export ohlcv, ohlcv!
