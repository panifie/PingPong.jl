using Engine: Strategies as st
using Engine.Strategies: Strategy
using Engine.Types.Orders
using Instruments
using Data.DFUtils
using Data.DataFrames
using Lang: Option
using Processing: normalize, normalize!

function trade_str(trade)
    """Trade Date: $(trade.date)
    Trade Size: $(cn(trade.size)) """ *
    begin
        pct = trade.amount / trade.order.amount
        pct < 1.0 ? "Trade Pct.: $(cn(pct))\n" : "\n"
    end *
    """Order Price: $(cn(trade.order.price))
    Order Date: $(trade.order.date)"""
end

function triangle_middle(pos)
    pos[1][2] == pos[3][2] ? (pos[1] + pos[end]) / 2 : (pos[1] + pos[2]) / 2
end

function trades_tooltip_func(trades)
    function f(inspector, plot, idx, _)
        try
            true_idx = tooltip_position!(
                inspector, plot, idx; vertices=3, shift_func=triangle_middle
            )
            tooltip_text!(inspector, trade_str(trades[true_idx]))
        catch
        end
        return true
    end
end

function triangle(t::SellTrade, x, y, flags, height)
    p = Point2f[(x, y), (x + 0.5, y - height), (x + 1.0, y)]
    push!(flags.sells.trades, t)
    push!(flags.sells.points, p)
end

function triangle(t::BuyTrade, x, y, flags, height)
    p = Point2f[(x, y), (x + 0.5, y + height), (x + 1.0, y)]
    push!(flags.buys.trades, t)
    push!(flags.buys.points, p)
end

function trades_ohlcv(tf, ai, from, to)
    @assert length(ai.history) >= from "Trades history is shorter than $from."
    to = @something to lastindex(ai.history)
    @assert length(ai.history) >= to "Trades history is shorter than $to."
    trade_date = first(ai.history).date
    @assert apply(tf, trade_date) == trade_date "Trades date accuracy not matching strategy timeframe."
    from_date = ai.history[from].date
    to_date = ai.history[to].date
    df = ai.ohlcv[DateRange(from_date, to_date), :]
    df, to
end

function check_df(df, force=false)
    if !force && nrow(df) > 100_000
        throw(
            ArgumentError(
                "Refusing to plot a timeframe with ($(nrow(df))) candles, it is too large"
            ),
        )
    end
end

function trades_fig(df, fig=makefig())
    fig, price_ax = plot_ohlcv(df, nothing; fig)
    trades_ax = Axis(fig[1, 1]; ypanlock=true, yzoomlock=true, yrectzoom=false)
    hidespines!(trades_ax)
    hidedecorations!(trades_ax)
    deregister_interaction!(trades_ax, :rectanglezoom)
    @deassert price_ax.title == "OHLC"
    fig, trades_ax, price_ax
end

@doc "Plots a subset of trades history of an asset instance.
- `from`: the first index in the trade history to plot [`1`]
- `to`: the last index in the trade history to plot [`lastindex`]
- `force`: plots very large dataframes [`false`]
"
function plot_trades_range(s::Strategy, aa; from=1, to=nothing, force=false)
    ai = s.universe[aa, :instance, 1]
    df, to = trades_ohlcv(s.timeframe, ai, from, to)
    check_df(df, force)
    fig, trades_ax, price_ax = trades_fig(df)
    linkaxes!(trades_ax, price_ax)
    function makevec(side)
        NamedTuple{(:trades, :points),Tuple{Vector{side},Vector{Vector{Point2f}}}}(([], []))
    end
    flags = (buys=makevec(BuyTrade), sells=makevec(SellTrade))
    low = df.low
    high = df.high
    gety(::BuyTrade, idx) = low[idx]
    gety(::SellTrade, idx) = high[idx]
    triangleofs(::BuyTrade, y) = y - 0.01y
    triangleofs(::SellTrade, y) = y + 0.01y
    ld = lastdate(df)
    for t in @view ai.history[from:to]
        t.date > ld && break
        x = dateindex(df, t.date)
        y = gety(t, x)
        y = triangleofs(t, y)
        triangle(t, x - 0.5, y, flags, 1.0)
    end
    poly!(
        trades_ax,
        flags.buys.points;
        color=:cyan,
        strokecolor=:black,
        strokewidth=0.5,
        inspector_hover=trades_tooltip_func(flags.buys.trades),
    )
    poly!(
        trades_ax,
        flags.sells.points;
        color=:deeppink,
        strokecolor=:black,
        strokewidth=0.5,
        inspector_hover=trades_tooltip_func(flags.sells.trades),
    )
    fig
end

function getellipsepoints(cx, cy, rx, ry, θ)
    t = range(0, 2 * pi; length=100)
    ellipse_x_r = @. rx * cos(t)
    ellipse_y_r = @. ry * sin(t)
    R = [cos(θ) sin(θ); -sin(θ) cos(θ)]
    r_ellipse = [ellipse_x_r ellipse_y_r] * R
    x = @. cx + r_ellipse[:, 1]
    y = @. cy + r_ellipse[:, 2]
    (x, y)
end

ellipsis(cx, cy, rx, ry) = begin
    θ = 0.0
    Point2f.(zip(getellipsepoints(cx, cy, rx, ry, θ)...))
end

aggtrades_str(row) = begin
    """Trades Count: $(cn(row.trades_count, 1))
    Buy/Sell: $(cn(row.buys, 1))/$(cn(row.sells, 1))
    Quote Balance: $(cn(row.quote_balance))
    Base Balance: $(cn(row.base_balance))
    Base Volume: $(cn(row.base_volume))
    Quote Volume: $(cn(row.quote_volume))
    T: $(row.timestamp)
    """
end

ellipsis_middle(pos) = begin
    (pos[1] + pos[50]) / 2.0
end

function aggtrades_tooltip_func(trades_df)
    function f(inspector, plot, idx, _)
        try
            true_idx = tooltip_position!(
                inspector, plot, idx; vertices=100, shift_func=ellipsis_middle
            )
            tooltip_text!(inspector, aggtrades_str(trades_df[true_idx, :]);)
        catch
        end
        return true
    end
end

@doc "Plots all trades aggregating data to the provided timeframe [`1d`]."
function plot_aggtrades(s::Strategy, aa, tf=tf"1d"; force=false)
    ai = s.universe[aa, :instance, 1]
    df = resample(ai.ohlcv, s.timeframe, tf)
    check_df(df, force)
    fig, trades_ax, price_ax = trades_fig(df)
    trades_df = resample_trades(ai, tf)
    mm = maximum(df.close)
    trades_df[!, :norm_qv] = normalize(trades_df.quote_volume; unit=true)
    trades_df[!, :norm_tc] = normalize(Float32.(trades_df.trades_count); unit=true)
    anchor(::Val{:pos}, x, n) = ellipsis(x, df[x, :high] + 36n, n / 16, 32n)
    anchor(::Val{:neg}, x, n) = ellipsis(x, df[x, :low] - 36n, n / 16, 32n)
    makevec() = (points=Vector{Point2f}[], trades=DataFrame())
    posanchors = makevec()
    poscolors = Tuple{Symbol,Float32}[]
    neganchors = makevec()
    negcolors = Tuple{Symbol,Float32}[]
    for row in eachrow(trades_df)
        idx = dateindex(df, row.timestamp)
        if row.quote_balance < 0.0
            push!(neganchors.points, anchor(Val(:neg), idx, row.norm_qv * mm * 0.01))
            push!(neganchors.trades, row)
            push!(negcolors, (:cyan, max(0.1, row.norm_tc)))
        else
            push!(posanchors.points, anchor(Val(:pos), idx, row.norm_qv * mm * 0.01))
            push!(posanchors.trades, row)
            push!(poscolors, (:deeppink, max(0.1, row.norm_tc)))
        end
    end
    poly!(
        trades_ax,
        neganchors.points;
        color=negcolors,
        strokecolor=:black,
        strokewidth=0.33,
        inspector_hover=aggtrades_tooltip_func(neganchors.trades),
    )
    poly!(
        trades_ax,
        posanchors.points;
        color=poscolors,
        strokecolor=:black,
        strokewidth=0.33,
        inspector_hover=aggtrades_tooltip_func(posanchors.trades),
    )
    linkaxes!(trades_ax, price_ax)
    fig
end

export plot_trades_range, plot_aggtrades
