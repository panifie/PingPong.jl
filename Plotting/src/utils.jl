using Instruments: compactnum as cn

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
    inspector, plot, idx; vertices=4, shift_func=(pos) -> ((pos[1] + pos[2]) / 2)
)
    # Get the scene BarPlot lives in
    scene = parent_scene(plot)
    candle_idx_middle, rem = divrem(idx, vertices)
    # A candle is made of 4 points, if hover is not on the last poly, we have to shift forward
    true_idx = rem == 0 ? candle_idx_middle : candle_idx_middle + 1
    # fetch the position of the candle mesh
    pos = plot[1][][true_idx]
    proj_pos = shift_project(scene, plot, shift_func(pos))
    update_tooltip_alignment!(inspector, proj_pos)
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
