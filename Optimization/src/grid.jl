using Pbar.Term.Progress: @track, ProgressJob, Progress
using Pbar: pbar!, @withpbar!, @pbupdate!
using SimMode.Instruments: compactnum as cnum

using Printf: @sprintf
import .Progress: AbstractColumn, get_columns
import Pbar.Term.Segments: Segment
import Pbar.Term.Measures: Measure

function _tostring(prefix, params)
    s = join(("[", prefix, (cnum(p) for p in params[])..., "]"), " ")
    s[begin:min(displaysize()[2], length(s))]
end

struct ParamsColumn <: AbstractColumn
    job::ProgressJob
    segments::Vector{Segment}
    measure::Measure
    params::Ref

    function ParamsColumn(job::ProgressJob; params)
        txt = Segment(_tostring("params: ", params), "cyan")
        txt.measure.w += 2
        return new(job, [txt], txt.measure, params)
    end
end

function Progress.update!(col::ParamsColumn, args...)::String
    seg = Segment(_tostring("params: ", col.params), "cyan")
    return seg.text
end

struct BestColumn <: AbstractColumn
    job::ProgressJob
    segments::Vector{Segment}
    measure::Measure
    best::Ref

    function BestColumn(job::ProgressJob; best)
        txt = Segment(_tostring("best: ", best), "green")
        txt.measure.w += 2
        return new(job, [txt], txt.measure, best)
    end
end

function Progress.update!(col::BestColumn, args...)::String
    seg = Segment(_tostring("best: ", col.best), "green")
    return seg.text
end

function gridpbar!(sess, first_params)
    columns = get_columns(:default)
    push!(columns, ParamsColumn)
    push!(columns, BestColumn)
    current_params = Ref(first_params)
    pbar!(;
        columns,
        columns_kwargs=Dict(
            :ParamsColumn => Dict(:params => current_params),
            :BestColumn => Dict(:best => sess.best),
        ),
    )
    current_params
end

function gridfromparams(params)
    mat = Iterators.product(params...) |> collect
    reshape(mat, length(mat))
end

function gridsearch(s::Strategy{Sim}; seed=1, repeats=1)
    Random.seed!(seed)
    ctx, params, grid = ping!(s, OptSetup())
    grid = gridfromparams(params)
    sess = OptSession(s; ctx, params)
    try
        backtest_func = define_backtest_func(sess, ctxsteps(ctx, repeats)...)
        obj_type, n_obj = objectives(s)
        sess.best[] = ((zero(eltype(obj_type)) for _ in 1:n_obj)...,)
        ismulti = n_obj > 1
        opt_func = define_opt_func(s; backtest_func, ismulti, repeats, obj_type)
        grid_lock = ReentrantLock()
        current_params = gridpbar!(sess, first(grid))
        @withpbar! grid Threads.@threads for cell in grid
            @lock grid_lock begin
                current_params[] = cell
                @pbupdate!
            end
            obj = opt_func(cell)
            @lock grid_lock let best = sess.best[]
                if obj > best
                    sess.best[] = obj
                end
            end
        end
    catch e
        e isa InterruptException || rethrow(e)
    end
    sess
end

export gridsearch
