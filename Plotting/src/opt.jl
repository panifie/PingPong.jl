using Optimization: OptSession
using Stats: mean
using .egn.Data: Not

_allfinite(v) = all(isfinite.(v))

@doc """ Plot results from an optimization session.

`sess`: the optimization session
`xy_col`: a `Vector{Symbol}` of length 2, the columns from the results to use as x and y axes. (Default the first 2 parameters.)
`z_col`: the column to use as the z axis. (Default as the `obj` column.)
`col_color`: which column to use as source for color gradients (`:cash`).
`col_filter`: function to filter the results by, compatible with the `DataFrames` conventions, e.g. `[:columns...] => my_function`
`group_repetition`: how to combine repeated parameters combinations, should also be compatible with `DataFrames` (defaults to `mean`)
`plot_func`: what kind of plot to use. (`scatter`)

Additional kwargs are passed to the plotting function call.
"""
function plot_results(
    sess::OptSession;
    xy_col=first(keys(sess.params), 2),
    z_col=:obj,
    col_color=:cash,
    colormap=[:red, :yellow, :green],
    col_filter=nothing,
    group_repetitions=Not(:repeat) .=> mean,
    plot_func=scatter,
    x_func=identity,
    y_func=identity,
    z_func=identity,
    kwargs...,
)
    results = let results = sess.results
        results = @view results[_allfinite.(sess.results.obj), :]
        if !isnothing(col_filter)
            results = filter(col_filter, results)
        end
        if !isnothing(group_repetitions)
            gd = groupby(results, [keys(sess.params)...])
            results = combine(gd, group_repetitions; renamecols=false)
        end
        results
    end
    @assert nrow(results) > 0 "No data to plot, session results dataframe is empty."
    @assert 0 < length(xy_col) < 3 "Can only plot between 1 or 2 parameters."
    col_color = @something col_color if length(sess.params) > 2
        keys(sess.params)[3]
    else
        nothing
    end
    params_df = select(results, xy_col)
    x = getproperty(params_df, xy_col[1]) |> normalize
    axes = Any[x_func(x)]
    @info "x: param $(xy_col[1])"
    next_col = "y"
    if length(xy_col) > 1
        y = getproperty(params_df, xy_col[2]) |> normalize
        @info "$next_col: param $(xy_col[2])"
        next_col = "z"
        push!(axes, y_func(y, x))
    end
    let z = getproperty(results, z_col), n_z = length(first(z))
        @info "$next_col: Objective"
        obj_norm_separate = [normalize(float.(getindex.(z, i))) for i in 1:n_z]
        norm = hcat(obj_norm_separate...)
        z_ax = reshape(sum(norm; dims=2), size(norm, 1))
        push!(axes, z_func(z_ax, y, x))
    end
    color_args = if !isnothing(col_color)
        colorrange = getproperty(results, col_color) |> normalize
        (; color=colorrange, something((; colormap), (;))...)
    else
        ()
    end
    function label_func(insp, i, p)
        buf = IOBuffer()
        try
            row = results[i, :]
            println(buf, "idx: $i")
            for k in propertynames(row)
                println(buf, "$k: $(getproperty(row, k))")
            end
            s = String(take!(buf))
            s
        catch
            close(buf)
            ""
        end
    end
    fig = plot_func(axes...; color_args..., inspector_label=label_func, kwargs...)
    DataInspector(fig)
    fig
end

function uniqueidx(x::AbstractArray{T}) where {T}
    uniqueset = Set{T}()
    ex = eachindex(x)
    idxs = Vector{eltype(ex)}()
    for i in ex
        xi = x[i]
        if !(xi in uniqueset)
            push!(idxs, i)
            push!(uniqueset, xi)
        end
    end
    idxs
end

# tolinrange(arr, args...) = LinRange(minimum(arr), maximum(arr), length(arr))
# _surface_height(z, y, x) = begin
#     mat = [x y z]
# end

# @doc """ Helper kwargs for surface plotting
# """
# function surface_kwargs(results::DataFrame)
#     (;
#         plot_func=surface,
#         x_func=x -> unique(x) |> sort!,
#         y_func=(y, _) -> unique(y) |> sort!,
#         z_func=(z, y, x) -> view(z, sortperm()),
#     )
# end
