# using BasicBSpline
# function _smooth(arr)
#     # Linear open B-spline space
#     xs = 1:size(arr, 1)
#     fs = arr
#     p = 1
#     k = KnotVector(xs) + KnotVector([xs[1], xs[end]])
#     P = BSplineSpace{p}(k)
#     # Compute the interpolant function (1-dim B-spline manifold)
#     xs, BSplineManifold(fs, P).controlpoints
# end

function _check_size(subject, to)
    @assert subject == to "Indicator ($subject) should Match ohlcv data length ($to)."
end
_ncandles(fig) = length(plots(fig.content[1])[1][1][])
_candle_str(::Nothing, n) = ""
_candle_str(df, n) = candle_str(df[n, :])

@doc """ Adds line indicators to a given figure.

$(TYPEDSIGNATURES)

The function `line_indicator!` takes a `Figure` object and one or more line data arrays as arguments.
It first checks if the size of each line matches the number of candles in the figure.
Then, it creates a new axis in the figure and links it with the price axis.
For each line, it generates a random color and adds a line plot to the axis with a tooltip showing the value of the line at each point.
"""
function line_indicator!(fig::Figure, lines...; df=nothing)
    for l in lines
        _check_size(size(l, 1), _ncandles(fig))
    end
    ax = axis!(fig)
    deregister_interactions!(ax, ())
    linkaxes!(_price_ax(fig), ax)
    function drawline!(n, line)
        str_func(n) = """Value: $(cn(line[n]))\n$(_candle_str(df, n))"""
        lines!(
            ax,
            line;
            color=RGBf(rand(seed!(n), 3)...),
            inspector_hover=make_tooltip_func(line, str_func),
        )
    end
    for (n, line) in enumerate(lines)
        drawline!(n, line)
    end
end

@doc """ Creates a figure with line indicators from a DataFrame.

$(TYPEDSIGNATURES)

The function `line_indicator` takes an `AbstractDataFrame` and one or more line data arrays as arguments.
It first creates a figure using the `ohlcv` function with the DataFrame.
Then, it calls the `line_indicator!` function to add line indicators to the figure.
The function returns the figure with the added line indicators.
"""
function line_indicator(df::AbstractDataFrame, lines...)
    fig = ohlcv(df)
    line_indicator!(fig, lines...; df)
    fig
end

@doc """ Adds channel indicators to a given figure.

$(TYPEDSIGNATURES)

The function `channel_indicator!` takes a `Figure` object and one or more line data arrays as arguments.
It first checks if the size of each line matches the number of candles in the figure.
Then, it creates a new axis in the figure and links it with the price axis.
For each pair of lines, it generates a random color and adds a band plot to the axis with a tooltip showing the values of the upper and lower bounds at each point.
The opacity of the band can be adjusted with the `opacity` keyword argument.
"""
function channel_indicator!(fig::Figure, lines...; df=nothing, opacity=0.25)
    for l in lines
        _check_size(size(l, 1), _ncandles(fig))
    end
    ax = axis!(fig)
    deregister_interactions!(ax, ())
    linkaxes!(_price_ax(fig), ax)

    function drawband!(lower, upper, n, ylower, yupper)
        str_func(n) = """Upper: $(cn(yupper[n]))
        Lower: $(cn(ylower[n]))
        $(_candle_str(df, n))"""
        band!(
            ax,
            lower,
            upper;
            color=RGBAf(rand(seed!(n), 3)..., opacity),
            inspector_hover=make_tooltip_func(ylower, str_func),
        )
    end
    points(line) = [Point2f(x, y) for (x, y) in enumerate(line)]
    lower, upper = points.(first(lines, 2))
    n = 0
    drawband!(lower, upper, n, first(lines, 2)...)
    if length(lines) > 2
        n += 1
        prevline = lines[2]
        for line in lines[3:end]
            lower = upper
            upper = points(line)
            drawband!(lower, upper, n, prevline, line)
            prevline = line
        end
    end
end

@doc """ Adds channel indicators to a given figure.

$(TYPEDSIGNATURES)

The function `channel_indicator!` takes a `Figure` object and one or more line data arrays as arguments.
It first checks if the size of each line matches the number of candles in the figure.
Then, it creates a new axis in the figure and links it with the price axis.
For each pair of lines, it generates a random color and adds a band plot to the axis with a tooltip showing the values of the upper and lower bounds at each point.
The opacity of the band can be adjusted with the `opacity` keyword argument.
"""
function channel_indicator(df::AbstractDataFrame, lines...; opacity=0.25)
    fig = ohlcv(df)
    channel_indicator!(fig, lines...; opacity, df)
    fig
end

channel_indicator(df, lines::AbstractVector) = channel_indicator(df, lines...)
channel_indicator!(fig, lines::AbstractVector) = channel_indicator!(fig, lines...)

export line_indicator, line_indicator!, channel_indicator, channel_indicator!
