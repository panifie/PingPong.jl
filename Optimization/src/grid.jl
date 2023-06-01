using Pbar.Term.Progress: @track, ProgressJob, Progress
using Pbar: pbar!, @withpbar!, @pbupdate!
using SimMode.Instruments: compactnum as cnum, Instruments
using Stats.Data: Cache as ca, nrow, groupby, combine, DataFrame

using Printf: @sprintf
using Base.Sys: free_memory
import .Progress: AbstractColumn, get_columns
import Pbar.Term.Segments: Segment
import Pbar.Term.Measures: Measure

function _tostring(_, s::String)
    s[begin:min(displaysize()[2], length(s))]
end
function _tostring(prefix, params)
    s = join(("[", prefix, (cnum(p) for p in params)..., "]"), " ")
    s[begin:min(displaysize()[2], length(s))]
end

struct ParamsColumn <: AbstractColumn
    job::ProgressJob
    segments::Vector{Segment}
    measure::Measure
    params::Ref

    function ParamsColumn(job::ProgressJob; params)
        txt = Segment(_tostring("params: ", params[]), "cyan")
        txt.measure.w += 2
        return new(job, [txt], txt.measure, params)
    end
end

function Progress.update!(col::ParamsColumn, args...)::String
    seg = Segment(_tostring("params: ", col.params[]), "cyan")
    return seg.text
end

struct BestColumn <: AbstractColumn
    job::ProgressJob
    segments::Vector{Segment}
    measure::Measure
    best::Ref

    function BestColumn(job::ProgressJob; best)
        txt = Segment(_tostring("best: ", best[]), "green")
        txt.measure.w += 2
        return new(job, [txt], txt.measure, best)
    end
end

function Progress.update!(col::BestColumn, args...)::String
    seg = Segment(_tostring("best: ", col.best[]), "green")
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

function resume!(sess)
    saved_sess = try
        load_session(values(session_key(sess)[2])...)
    catch e
        e isa KeyError && return false
        rethrow(e)
    end
    what = if nameof(saved_sess.s) != nameof(sess.s)
        "strategy"
    elseif let r1 = saved_sess.ctx.range, r2 = sess.ctx.range
        !(r1.start == r2.start && r1.stop == r2.stop)
    end
        "context"
    elseif saved_sess.params != sess.params
        "params"
    elseif saved_sess.opt_config != sess.opt_config
        "opt_config"
    else
        ""
    end
    if what != ""
        error("Can't resume session, mismatching $what")
    end
    append!(sess.results, saved_sess.results)
    return true
end

@doc "Backtests the strategy across combination of parameters.
`s`: The strategy.
`seed`: random seed set before each backtest run.
`repeats`: the amount of repetitions for each combination.
`save_freq`: how frequently (`Period`) to save results, when `nothing` (default) saving is skipped."
function gridsearch(
    s::Strategy{Sim}; seed=1, repeats=1, save_freq=nothing, resume=true, zi=zilmdb()
)
    running!()
    ctx, params, grid = ping!(s, OptSetup())
    grid = gridfromparams(params)
    sess = OptSession(s; ctx, params, opt_config=(; seed, repeats))
    resume && resume!(sess)
    should_save = if !isnothing(save_freq)
        resume || save_session(sess; zi)
        true
    else
        false
    end
    try
        backtest_func = define_backtest_func(sess, ctxsteps(ctx, repeats)...)
        obj_type, n_obj = objectives(s)
        sess.best[] = ((zero(eltype(obj_type)) for _ in 1:n_obj)...,)
        ismulti = n_obj > 1
        opt_func = define_opt_func(
            s; backtest_func, ismulti, repeats, obj_type, isthreaded=false
        )
        current_params = gridpbar!(sess, first(grid))
        best = sess.best
        grid_itr = if isempty(sess.results)
            grid
        else
            let gd = groupby(sess.results, [keys(sess.params)...])
                completed = DataFrame(filter(g -> nrow(g) == repeats, gd))
                empty!(sess.results)
                append!(sess.results, completed)
                done_params = Set(values(result_params(sess, idx)) for idx in 1:nrow(sess.results))
                filter(params -> params ∉ done_params, grid)
            end
        end
        from = Ref(nrow(sess.results) + 1)
        saved_last = Ref(now())
        grid_lock = ReentrantLock()
        @withpbar! grid begin
            if !isempty(sess.results)
                @pbupdate! sum(divrem(nrow(sess.results), repeats))
            end
            gridrun(cell) = begin
                lock(grid_lock) do
                    Random.seed!(seed)
                end
                obj = opt_func(cell)
                lock(grid_lock) do
                    current_params[] = cell
                    @pbupdate!
                    if obj > best[]
                        best[] = obj
                    end
                end
                should_save && lock(sess.lock) do
                    if now() - saved_last[] > save_freq
                        # prev_best = lock(grid_lock) do
                        #     prev_best = best[]
                        #     best[] = "saving..."
                        #     @pbupdate! 0
                        #     prev_best
                        # end
                        save_session(sess; from=from[])
                        from[] = nrow(sess.results) + 1
                        saved_last[] = now()
                        # lock(grid_lock) do
                        #     best[] = prev_best
                        #     @pbupdate! 0
                        # end
                    end
                end
            end
            Threads.@threads for cell in grid_itr
                if isrunning()
                    gridrun(cell)
                end
            end
            save_session(sess; from=from[])
        end
    catch e
        if !(e isa InterruptException)
            rethrow(e)
        end
    finally
        stopping!()
    end
    sess
end

export gridsearch
