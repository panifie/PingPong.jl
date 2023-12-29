using Data.DFUtils
using Makie: parent_scene, shift_project, update_tooltip_alignment!
using Instruments: compactnum as cn

using GLMakie
using Makie.KernelDensity
using Random
using Makie.Colors

function domakie()
    fig = Figure()
    ax = Axis(fig[1, 1])
    function datashader(limits, pixelarea)
        # return your heatmap data
        # here, I just calculate a sine field as a demo
        xpixels, ypixels = widths(pixelarea)
        xmin, ymin = minimum(limits)
        xmax, ymax = maximum(limits)
        [
            cos(x) * sin(y) for x in LinRange(xmin, xmax, xpixels),
            y in LinRange(ymin, ymax, ypixels)
        ]
    end
    xrange = lift(x -> minimum(x)[1] .. maximum(x)[1], ax.finallimits)
    yrange = lift(x -> minimum(x)[2] .. maximum(x)[2], ax.finallimits)
    pixels = lift(datashader, ax.finallimits, ax.scene.px_area)
    heatmap!(ax, xrange, yrange, pixels; xautolimits=false, yautolimits=false)
    display(fig)
end
