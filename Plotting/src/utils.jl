using .egn.Instruments: compactnum as cn

makefig() = begin
    Figure(; resolution=(1900, 900))
end

function deregister_interactions!(ax, except=(:dragpan, :scrollzoom))
    for i in keys(interactions(ax))
        i ∈ except && continue
        deregister_interaction!(ax, i)
    end
end

function tooltip_position!(
    inspector,
    plot,
    idx;
    vertices=4,
    pos_func1=((pos) -> ((pos[1] + pos[2]) / 2)),
    pos_func2=((a, b) -> b),
)
    # Get the scene BarPlot lives in
    scene = parent_scene(plot)
    true_idx = div(idx - 1, vertices) + 1
    # fetch the position of the candle mesh
    pos = plot[1][][true_idx]
    proj_pos = shift_project(scene, plot, pos_func1(pos))
    update_tooltip_alignment!(inspector, pos_func2(pos, proj_pos))
    true_idx
end

function tooltip_text!(inspector, text; size=10.0)
    # Set the tooltip content
    tt = inspector.plot
    tt.text[] = text
    tt.triangle_size = size
    # Show the tooltip
    tt.visible[] = true
end

@doc "Formats the timestamps for the X axis"
function makexticks(start_date, tf)
    (t) -> [string(start_date + tf.period * round(Int, tt)) for tt in t]
end

@doc "Formats the Y axis values"
ytickscompact(t) = cn.(t)

# @doc "Formats the Y axis values"
# function makeyticks()
#     (t) -> cn.(t)
# end

_price_ax(fig::Figure) = fig.attributes[:price_ax][]
function makepriceax(fig; xticksargs, title="OHLC", ylabel="Price")
    ax = Axis(
        fig[1, 1];
        xtickformat=makexticks(xticksargs...),
        ytickformat=ytickscompact,
        title,
        xlabel="Time",
        xaxisposition=:top,
        ylabel,
    )
    fig.attributes[:price_ax] = ax
end

function axis!(fig, idx=(1, 1))
    ax = Axis(fig[idx...];)
    hidespines!(ax)
    hidedecorations!(ax)
    deregister_interactions!(ax)
    ax
end
