using Pbar.Term.Progress: @track, ProgressJob, Progress
using Pbar: pbar!, @withpbar!, @pbupdate!
using SimMode.Instruments: compactnum as cnum, Instruments
using SimMode.Lang.Logging: SimpleLogger, with_logger, current_logger
using Stats.Data: Cache as ca, nrow, groupby, combine, DataFrame, DATA_PATH

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
        load_session(sess)
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

@doc "Remove results that don't have all the `repeat`ed evalutaion."
function remove_incomplete!(sess::OptSession)
    gd = groupby(sess.results, [keys(sess.params)...])
    repeats = sess.opt_config.repeats
    completed = DataFrame(filter(g -> nrow(g) == repeats, gd))
    empty!(sess.results)
    append!(sess.results, completed)
end

function optsession(s::Strategy; seed=1, repeats=1)
    ctx, params, grid = ping!(s, OptSetup())
    OptSession(s; ctx, params, opt_config=(; seed, repeats))
end

@doc "Backtests the strategy across combination of parameters.
`s`: The strategy.
`seed`: random seed set before each backtest run.
`repeats`: the amount of repetitions for each combination.
`save_freq`: how frequently (`Period`) to save results, when `nothing` (default) saving is skipped.
`logging`: enabled logging
"
function gridsearch(
    s::Strategy{Sim};
    seed=1,
    repeats=1,
    save_freq=nothing,
    resume=true,
    logging=true,
    zi=zilmdb(),
)
    running!()
    sess = optsession(s; seed, repeats)
    ctx = sess.ctx
    grid = gridfromparams(sess.params)
    resume && resume!(sess)
    should_save = if !isnothing(save_freq)
        resume || save_session(sess; zi)
        true
    else
        false
    end
    logger = if logging
        io = open(log_path(s)[1], "w+")
        SimpleLogger(io)
    else
        io = NullLogger()
        IOBuffer()
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
            remove_incomplete!(sess)
            done_params = Set(
                values(result_params(sess, idx)) for idx in 1:nrow(sess.results)
            )
            filter(params -> params ∉ done_params, grid)
        end
        from = Ref(nrow(sess.results) + 1)
        saved_last = Ref(now())
        grid_lock = ReentrantLock()
        with_logger(logger) do
            @withpbar! grid begin
                if !isempty(sess.results)
                    @pbupdate! sum(divrem(nrow(sess.results), repeats))
                end
                function gridrun(cell)
                    try
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
                                save_session(sess; from=from[])
                                from[] = nrow(sess.results) + 1
                                saved_last[] = now()
                            end
                        end
                    catch e
                        stopping!()
                        logging && lock(grid_lock) do
                            let io = current_logger().stream
                                println(io, "")
                                Base.showerror(io, e)
                                Base.show_backtrace(io, catch_backtrace())
                            end
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
        end
    catch e
        logging && @error e
        if !(e isa InterruptException)
            rethrow(e)
        end
    finally
        stopping!()
        if logging
            flush(io)
            close(io)
        end
    end
    sess
end

export gridsearch
