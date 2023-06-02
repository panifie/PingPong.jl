using Optimization: OptSession
using Stats: mean
using .egn.Data: Not

_allfinite(v) = all(isfinite.(v))

@doc """ Plot results from an optimization session.

`sess`: the optimization session
`x/y_col`: a `Vector{Symbol}` of length 2, the columns from the results to use as x and y axes. (Default the first 2 parameters.)
`z_col`: the column to use as the z axis. (Default as the `obj` column.)
`col_color`: which column to use as source for color gradients (`:cash`).
`col_filter`: function to filter the results by, compatible with the `DataFrames` conventions, e.g. `[:columns...] => my_function`
`group_repetition`: how to combine repeated parameters combinations, should also be compatible with `DataFrames` (defaults to `mean`)
`plot_func`: what kind of plot to use. (`scatter`)
`norm_func`: normalization function for axes (default `normalize`)

Additional kwargs are passed to the plotting function call.
Most common plots useful for analyzing strategies:
- (mesh)scatter
- surface/heatmap/tricontourf
- spy (assets X dates)
"""
function plot_results(
    sess::OptSession;
    x_col=keys(sess.params)[1],
    y_col=keys(sess.params)[2],
    z_col=:obj,
    col_color=:cash,
    colormap=[:red, :yellow, :green],
    col_filter=nothing,
    group_repetitions=Not(:repeat) .=> mean,
    plot_func=scatter,
    norm_func=normalize,
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
    col_color = @something col_color if length(sess.params) > 2
        keys(sess.params)[3]
    else
        nothing
    end
    if has_custom_coords(plot_func)
        x_col, y_col, z_col = by_plot_coords(plot_func, results, x_col, y_col, z_col)
    end
    x = if x_col isa Symbol
        getproperty(results, x_col) |> norm_func
    else
        @assert x_col isa AbstractArray
        x_col
    end
    axes = Any[x]
    symorlen(v) = v isa Symbol ? v : length(v)
    @info "x: param $(symorlen(x_col))"
    next_col = "y"
    y = if y_col isa Symbol
        getproperty(results, y_col) |> norm_func
    elseif y_col isa AbstractArray
        y_col
    elseif !isnothing(y_col)
        error("y_col of type $(typeof(y_col)) is not supported")
    end
    @info "$next_col: param $(symorlen(y_col))"
    next_col = "z"
    push!(axes, y)
    z = if z_col isa Symbol
        let z_vals = getproperty(results, z_col), n_z = length(first(z_vals))
            obj_separate = [norm_func(float.(getindex.(z_vals, i))) for i in 1:n_z]
            mat = hcat(obj_separate...)
            reshape(sum(mat; dims=2), size(mat, 1))
        end
    elseif z_col isa AbstractArray
        z_col
    elseif !isnothing(z_col)
        error("y_col of type $(typeof(y_col)) is not supported")
    end
    @info "$next_col: $(symorlen(z_col))"
    push!(axes, z)
    # FIXME
    color_args = if !isnothing(col_color)
        # colorrange = getproperty(results, col_color) |> normalize
        # (; color=colorrange, something((; colormap), (;))...)
        ()
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
        catch e
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

tolinrange(arr, args...) = LinRange(minimum(arr), maximum(arr), length(arr))
function _surface_height(results, x_col, y_col, z_col, x, y)
    z_type = eltype(getproperty(results, z_col))
    z = Matrix{z_type}(undef, length(x), length(y))
    for (x_i, X) in enumerate(x), (y_i, Y) in enumerate(y)
        df = filter(
            row -> getproperty(row, x_col) == X && getproperty(row, y_col) == Y, results
        )
        z[x_i, y_i] = isempty(df) ? zero(z_type) : mean(getproperty(df, z_col))
    end
    normalize!(z)
end

@doc """ Helper kwargs for surface plotting
"""
function surface_coords(results::DataFrame, x_col, y_col, z_col)
    x = unique(getproperty(results, x_col)) |> sort!
    y = unique(getproperty(results, y_col)) |> sort!
    (;
        x_col=normalize(x),
        y_col=normalize(y),
        z_col=_surface_height(results, x_col, y_col, z_col, x, y),
    )
end

function has_custom_coords(f)
    typeof(f) ∈ (surface,)
end

function by_plot_coords(f, args...; kwargs...)
    if typeof(f) == typeof(surface)
        surface_coords(args...; kwargs...)
    else
        ()
    end
end
