module OptimizationExt

using Plotting
using .Plotting: normalize, normalize!, scatter, surface, DataInspector
using Optimization: OptSession, Optimization
using Metrics: mean
using Makie
using Metrics.Data: Not, DataFrame, groupby, combine, nrow
using Metrics.ect.Instruments: compactnum as cnum
using Metrics: DFT

_allfinite(v) = all(isfinite.(v))
_repetitions_grouping(sess) = Not([keys(sess.params)..., :repeat]) .=> mean
base_indexer_func(i, p; results, cols, indexes) = results[i, :]
maybereduce(v::AbstractVector, f::Function) = f(v)
maybereduce(v, _) = v
normfloat(arr) = normalize(arr)
normfloat!(arr) = normalize!(arr)
normfloat(arr::AbstractVector{<:Integer}) = normalize(convert(Vector{DFT}, arr))
normfloat!(arr::AbstractVector{<:Integer}) = normalize!(convert(Vector{DFT}, arr))

@doc """ Plot results from an optimization session.

`sess`: the optimization session
`x/y_col`: a `Vector{Symbol}` of length 2, the columns from the results to use as x and y axes. (Default the first 2 parameters.)
`z_col`: the column to use as the z axis. (Default as the `obj` column.)
`col_color`: which column to use as source for color gradients (`:cash`).
`col_filter`: function to filter the results by, compatible with the `DataFrames` conventions, e.g. `[:columns...] => my_function`
`group_repetition`: how to combine repeated parameters combinations, should also be compatible with `DataFrames` (defaults to `mean`)
`plot_func`: what kind of plot to use. (`scatter`)
`norm_func`: normalization function for axes (default `normfloat`)
`tooltip_reduce_func`: (`k, v -> mean(v)`) the reduce function to use if a point in the plot references more than one results point (row). The function is called for each (relevant) column in the results dataframe.

Additional kwargs are passed to the plotting function call.
Most common plots useful for analyzing strategies:
- (mesh)scatter
- surface/heatmap/tricontourf
- spy (assets X dates)

Example: Plotting a surface (Assuming you have an `OptSession`)
```julia
using Plotting
fig, res = Plotting.plot_results(
    sess,
    z_col=:cash,
    x_col=:long_k,
    y_col=:short_k,
    col_color=:trades,
    plot_func=surface
)
```
"""
function Plotting.plot_results(
    sess::OptSession;
    x_col=keys(sess.params)[1],
    y_col=keys(sess.params)[2],
    z_col=:obj,
    col_color=:cash,
    colormap=[:red, :yellow, :green],
    col_filter=nothing,
    group_repetitions=_repetitions_grouping(sess),
    plot_func=scatter,
    norm_func=normfloat,
    tooltip_reduce_func=(k, v) -> mean(v),
    kwargs...,
)
    results = let results = sess.results
        results = @view results[_allfinite.(sess.results.obj), :]
        if !isempty(results)
            if !isnothing(col_filter)
                results = filter(col_filter, results)
            end
            if !isnothing(group_repetitions)
                gd = groupby(results, [keys(sess.params)...])
                results = combine(gd, group_repetitions; renamecols=false)
            end
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
        ((x_col, y_col, z_col), indexes), indexer_func = by_plot_coords(
            plot_func, results, x_col, y_col, z_col
        )
    else
        col_range = 1:nrow(results)
        indexes = (; x_idx=col_range, y_idx=col_range, z_idx=col_range)
        indexer_func = base_indexer_func
    end
    cols = (; x_col, y_col, z_col)
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
    z =
        if z_col isa Symbol
            let z_vals = getproperty(results, z_col), n_z = length(first(z_vals))
                obj_separate = [norm_func(float.(getindex.(z_vals, i))) for i in 1:n_z]
                mat = hcat(obj_separate...)
                reshape(sum(mat; dims=2), size(mat, 1))
            end
        elseif z_col isa AbstractArray
            z_col
        elseif !isnothing(z_col)
            error("y_col of type $(typeof(y_col)) is not supported")
        end |> v -> map(x -> isnan(x) ? zero(x) : x, v)
    @info "$next_col: $(symorlen(z_col))"
    push!(axes, z)
    color_args = let color = get_colorarg(plot_func, col_color; results, cols, indexes)
        if col_color isa Symbol
            getproperty(results, col_color)
        elseif col_color isa Function
            col_color(results; cols=(; x_col, y_col, z_col), indexes)
        else
            col_color
        end |> norm_func
        (; something((; color), (;))..., something((; colormap), (;))...)
    end
    function label_func(insp, i, p)
        buf = IOBuffer()
        try
            rows = indexer_func(i, p; results, cols=(; x_col, y_col, z_col), indexes)
            println(buf, "idx: $i")
            for k in propertynames(rows)
                v = maybereduce(getproperty(rows, k), (v) -> tooltip_reduce_func(k, v))
                if v isa Number
                    v = cnum(v)
                end
                println(buf, "$k: $v")
            end
            s = String(take!(buf))
            s
        catch e
            display(e)
            close(buf)
            ""
        end
    end
    fig = plot_func(axes...; color_args..., inspector_label=label_func, kwargs...)
    DataInspector(fig)
    fig, results
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
function surface_height(results, x_col, y_col, z_col, x, y; reduce_func=mean)
    z_type = eltype(getproperty(results, z_col))
    z = Matrix{z_type}(undef, length(x), length(y))
    z_idx = similar(z, Vector{Bool})
    for (x_i, X) in enumerate(x), (y_i, Y) in enumerate(y)
        flt_idx = getproperty(results, x_col) .== X .&& getproperty(results, y_col) .== Y
        z_rows = @view results[flt_idx, z_col]
        z[x_i, y_i] = isempty(z_rows) ? zero(z_type) : reduce_func(z_rows)
        z_idx[x_i, y_i] = flt_idx
    end
    normfloat!(z), z_idx
end

@doc """ Helper kwargs for surface plotting
"""
function surface_coords(results::DataFrame, x_col, y_col, z_col)
    x_results = getproperty(results, x_col)
    y_results = getproperty(results, y_col)
    x_idx = uniqueidx(x_results)
    y_idx = uniqueidx(y_results)
    x = unique(view(x_results, x_idx)) |> sort!
    y = unique(view(y_results, y_idx)) |> sort!
    z, z_idx = surface_height(results, x_col, y_col, z_col, x, y)
    (; x_col=normfloat(x), y_col=normfloat(y), z_col=z), (; x_idx, y_idx, z_idx)
end

function fromindexes(source, idx, reduce_func=mean)
    [reduce_func(source[i]) for i in idx]
end

function surface_indexer_func(i, p; results, cols, indexes)
    x_i = searchsortedfirst(cols.x_col, p[1])
    y_i = searchsortedfirst(cols.y_col, p[2])
    @view results[indexes.z_idx[x_i, y_i], :]
end

function has_custom_coords(f)
    f ∈ (surface,)
end

by_plot_color(plot_func, raw_col; kwargs...) = raw_col
function by_plot_color(::typeof(surface), raw_col; results, cols, indexes)
    fromindexes(raw_col, indexes.z_idx)
end

function get_colorarg(plot_func::Function, col_color; results, cols, indexes)
    if col_color isa Symbol
        raw_col = getproperty(results, col_color)
        by_plot_color(plot_func, raw_col; results, cols, indexes)
    elseif col_color isa Function
        col_color(results; cols, indexes)
    else
        col_color
    end
end

function by_plot_coords(f, args...; kwargs...)
    if typeof(f) == typeof(surface)
        surface_coords(args...; kwargs...), surface_indexer_func
    else
        (), base_indexer_func
    end
end

using .Plotting.Misc.Lang: @preset, @precomp
using Optimization: Optimization as opt, SimMode, st
if occursin("Plotting", get(ENV, "JULIA_PRECOMP", ""))
    @preset begin
        py = opt.st.Instances.Exchanges.Python
        if py.pyisnull(py.gpa.pyaio)
            py._async_init(py.PythonAsync())
        else
            py.py_start_loop()
        end
        s = opt._precomp_strat(OptimizationExt)
        sess = opt.gridsearch(s; resume=false)
        # because BareStrat (in `user/strategies/BareStrat.jl`) does has opt functions commented out
        # avoids assertion in plot_results after filtering
        for obj in sess.results.obj
            obj[1] = 1.0
        end
        try
            @precomp Plotting.plot_results(sess)
        catch exception
            @error "plotting: opt extension precompile failed" exception
        end
        py.py_stop_loop()
    end
end
end
