using Pbar.Term.Progress: @track, ProgressJob, Progress
using Pbar: pbar!, @withpbar!, @pbupdate!
using SimMode.Instruments: compactnum as cnum, Instruments
using SimMode.Lang.Logging: SimpleLogger, with_logger, current_logger
using SimMode.Lang: splitkws
using Stats.Data: Cache as ca, nrow, groupby, combine, DataFrame, DATA_PATH
using SimMode.Misc: attr
using Random: shuffle!

using Printf: @sprintf
using Base.Sys: free_memory
import .Progress: AbstractColumn, get_columns
import Pbar.Term.Segments: Segment
import Pbar.Term.Measures: Measure

function _tostring(_, s::String)
    s[begin:min(displaysize()[2], length(s))]
end

@doc """ Converts the provided parameters into a string representation.

$(TYPEDSIGNATURES)

The function takes a prefix and a set of parameters as input.
It joins the prefix and the parameters into a single string, with each parameter converted to a compact number representation.
The resulting string is then truncated to fit the display size.
"""
function _tostring(prefix, params)
    s = join(("[", prefix, (cnum(p) for p in params)..., "]"), " ")
    s[begin:min(displaysize()[2], length(s))]
end

@doc """ A column in the progress bar representing parameters.

$(FIELDS)

This struct represents a column in the progress bar that displays the parameters of the optimization job.
It contains a `ProgressJob`, a vector of `Segment` objects, a `Measure` object, and a reference to the parameters.
The constructor creates a `Segment` with a string representation of the parameters and sets the width of the measure to 15.
"""
struct ParamsColumn <: AbstractColumn
    job::ProgressJob
    segments::Vector{Segment}
    measure::Measure
    params::Ref

    function ParamsColumn(job::ProgressJob; params)
        txt = Segment(_tostring("params: ", params[]), "cyan")
        txt.measure.w = 15
        return new(job, [txt], txt.measure, params)
    end
end

function Progress.update!(col::ParamsColumn, args...)::String
    seg = Segment(_tostring("params: ", col.params[]), "cyan")
    return seg.text
end

@doc """ A column in the progress bar representing the best optimization result.

$(FIELDS)

This struct represents a column in the progress bar that displays the best result of the optimization job.
It contains a `ProgressJob`, a vector of `Segment` objects, a `Measure` object, and a reference to the best result.
The constructor creates a `Segment` with a string representation of the best result and sets the width of the measure to 15.
"""
struct BestColumn <: AbstractColumn
    job::ProgressJob
    segments::Vector{Segment}
    measure::Measure
    best::Ref

    function BestColumn(job::ProgressJob; best)
        s = _tostring("best: ", best[])
        txt = Segment(s, "green")
        txt.measure.w = 15
        return new(job, [txt], txt.measure, best)
    end
end

function Progress.update!(col::BestColumn, args...)::String
    seg = Segment(_tostring("best: ", col.best[]), "green")
    return seg.text
end

@doc """ Initializes a progress bar for grid optimization.

$(TYPEDSIGNATURES)

This function sets up a progress bar for the grid optimization process.
It creates a `ParamsColumn` and a `BestColumn` and adds them to the default columns.
The function returns a reference to the current parameters.
"""
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

@doc """ Generates a grid from the provided parameters.

$(TYPEDSIGNATURES)

The function takes a set of parameters as input.
It generates a grid by taking the product of the parameters and reshaping it to the length of the parameters.
"""
function gridfromparams(params)
    mat = Iterators.product(params...) |> collect
    reshape(mat, length(mat))
end

@doc """ Generates a grid from the optimization results.

$(TYPEDSIGNATURES)

The function takes an optimization session and results as input.
It generates a grid by extracting the parameters from each row of the results.
"""
function gridfromresults(sess::OptSession, results; kwargs...)
    params = keys(sess.params)
    [((getproperty(row, p) for p in params)...,) for row in eachrow(results)]
end

@doc """ Resumes the optimization session from saved state.

$(TYPEDSIGNATURES)

The function attempts to load a saved session and resumes it.
If the saved session does not match the current session in terms of strategy, context, parameters, or attributes, an error is thrown.
If the session is successfully resumed, the results from the saved session are appended to the current session's results.
"""
function resume!(sess; zi=zinstance())
    saved_sess = try
        load_session(sess; zi)
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
    elseif saved_sess.attrs != sess.attrs
        "attrs"
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
    splits = attr(sess, :splits)
    completed = DataFrame(filter(g -> nrow(g) == splits, gd))
    empty!(sess.results)
    append!(sess.results, completed)
end

@doc """ Removes results that don't have all the `repeat`ed evaluation.

$(TYPEDSIGNATURES)

The function groups the results by session parameters and removes those groups that don't have a complete set of evaluations, as defined by the `splits` attribute of the session.
"""
function optsession(s::Strategy; seed=1, splits=1, offset=0)
    ctx, params, grid = ping!(s, OptSetup())
    OptSession(s; ctx, params, offset, attrs=Dict(pairs((; seed, splits))))
end

@doc """Backtests the strategy across combination of parameters.

$(TYPEDSIGNATURES)

- `seed`: random seed set before each backtest run.
- `splits`: the number segments into which the context is split.
- `save_freq`: how frequently (`Period`) to save results, when `nothing` (default) saving is skipped.
- `logging`: enabled logging
- `random_search`: shuffle parameters combinations before iterations

One parameter combination runs `splits` times, where each run uses a period
that is a segment of the full period of the given `Context` given.
(The `Context` comes from the strategy `ping!(s, params, OptRun())`
"""
function gridsearch(
    s::Strategy{Sim};
    seed=1,
    splits=1,
    save_freq=nothing,
    resume=true,
    logging=true,
    random_search=false,
    zi=zinstance(),
    grid_itr=nothing,
    offset=0,
)
    running!()
    sess = optsession(s; seed, splits, offset)
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
        # SimpleLogger(io)
        current_logger()
    else
        io = NullLogger()
        IOBuffer()
    end
    try
        backtest_func = define_backtest_func(sess, ctxsteps(ctx, splits)...)
        obj_type, n_obj = objectives(s)
        sess.best[] = if isone(n_obj)
            zero(eltype(obj_type))
        else
            ((zero(eltype(obj_type)) for _ in 1:n_obj)...,)
        end
        ismulti = n_obj > 1
        opt_func = define_opt_func(
            s; backtest_func, ismulti, splits, obj_type, isthreaded=false
        )
        current_params = gridpbar!(sess, first(grid))
        best = sess.best
        if isnothing(grid_itr)
            grid_itr = if isempty(sess.results)
                collect(grid)
            else
                remove_incomplete!(sess)
                done_params = Set(
                    values(result_params(sess, idx)) for idx in 1:nrow(sess.results)
                )
                filter(params -> params ∉ done_params, grid)
            end
        else
            grid_itr = collect(grid_itr)
            grid = grid_itr
        end
        if random_search
            shuffle!(grid_itr)
        end
        from = Ref(nrow(sess.results) + 1)
        saved_last = Ref(now())
        grid_lock = ReentrantLock()
        with_logger(logger) do
            @withpbar! grid begin
                if !isempty(sess.results)
                    @pbupdate! sum(divrem(nrow(sess.results), splits))
                end
                function runner(cell)
                    @lock grid_lock Random.seed!(seed)
                    obj = opt_func(cell)
                    @lock grid_lock begin
                        current_params[] = cell
                        @pbupdate!
                        if obj > best[]
                            best[] = obj
                        end
                    end
                    should_save && @lock sess.lock begin
                        if now() - saved_last[] > save_freq
                            save_session(sess; from=from[], zi)
                            from[] = nrow(sess.results) + 1
                            saved_last[] = now()
                        end
                    end
                end
                # TODO: use @nogc for other optimization methods
                @nogc Threads.@threads for cell in grid_itr
                    if isrunning()
                        try
                            runner(cell)
                        catch
                            @error "" exception = (first(Base.catch_stack())...,)
                            stopping!()
                            logging && @lock grid_lock @debug_backtrace
                        end
                    end
                end
                save_session(sess; from=from[], zi)
            end
        end
    catch e
        logging && @error e
        save_session(sess; from=from[], zi)
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

@doc """ Filters the optimization results based on certain criteria.

$(TYPEDSIGNATURES)

The function takes a strategy and a session as input, along with optional parameters for cut and minimum results.
It filters the results based on the cut value and the minimum number of results.
"""
function filter_results(::Strategy, sess; cut=0.8, min_results=100)
    df = agg(sess)
    if nrow(df) > 1
        initial_cash = sess.s.initial_cash
        filter!([:cash] => (x) -> x > initial_cash, df)
        if nrow(df) > min_results
            sort!(df, [:cash, :obj, :trades])
            from_idx = trunc(Int, nrow(df) * (cut / 3))
            best_cash = @view df[(end - from_idx):end, :]
            sort!(df, [:trades, :obj, :cash])
            best_trades = @view df[(end - from_idx):end, :]
            sort!(df, [:obj, :cash, :trades])
            best_obj = @view df[(end - from_idx):end, :]
            vcat(best_cash, best_trades, best_obj)
        else
            df
        end
    else
        return df
    end
end

@doc "A progressive search performs multiple grid searches with only 1 repetition per parameters combination.

$(TYPEDSIGNATURES)

After each search is completed, the results are filtered according to custom rules. The parameters from the results
that match the filtering will be backtested again with a different `offset` which modifies the backtesting period.
`rounds`: how many iterations (of grid searches) to perform
`sess`: If a `Ref{<:OptSession}` is provided, search will resume from the session previous results
`halve`: At each iteration

Additional kwargs are forwarded to the grid search.
"
function progsearch(
    s; sess::Option{Ref{<:OptSession}}=nothing, rounds=:auto, cut=1.0, kwargs...
)
    rcount = rounds == :auto ? round(Int, period(s.timeframe) / Minute(1)) : rounds
    @assert rcount isa Integer
    _, fw_kwargs = splitkws(:offset, :splits, :grid_itr; kwargs)
    init_offset = isnothing(sess) ? 0 : sess[].attrs[:offset] + 1
    let offset = init_offset,
        grid_itr = if isnothing(sess)
            nothing
        else
            gridfromresults(sess[], filter_results(s, sess[]; cut))
        end

        this_sess = gridsearch(s; offset, grid_itr, splits=1, fw_kwargs...)
        if isnothing(sess)
            sess = Ref(this_sess)
        else
            sess[] = this_sess
        end
    end
    for offset in (init_offset + 1):rcount
        results = filter_results(s, sess[]; cut)
        grid_itr = gridfromresults(sess[], results)
        if length(grid_itr) < 3
            @info "Search stopped because no results were left to filter."
            break
        end
        sess[] = gridsearch(s; offset, splits=1, grid_itr, fw_kwargs...)
    end
    sess[]
end

@doc "Backtests by sliding over the backtesting period, by the smallest timeframe (the strategy timeframe).

$(TYPEDSIGNATURES)

Until a full range of timeframes is reached between the strategy timeframe and backtesting context timeframe.

- `multiplier`: the steps count (total stepps will be `multiplier * context_timeframe / s.timeframe` )
"
function slidesearch(s::Strategy; multiplier=1)
    ctx, _, _ = ping!(s, OptSetup())
    inc = period(s.timeframe)
    steps = multiplier * max(1, trunc(Int, ctx.range.step / period(s.timeframe)))
    wp = ping!(s, WarmupPeriod())
    results = DataFrame()
    initial_cash = s.initial_cash
    rlock = ReentrantLock()
    n_threads = Threads.nthreads()
    s_clones = tuple(((ReentrantLock(), similar(s)) for _ in 1:n_threads)...)
    ctx_clones = tuple((similar(ctx) for _ in 1:n_threads)...)

    @withpbar! 1:steps begin
        Threads.@threads for n in 1:steps
            let id = Threads.threadid(), (l, s) = s_clones[id], ctx = ctx_clones[id]
                lock(l) do
                    st.reset!(s, true)
                    current!(ctx.range, ctx.range.start + wp + n * inc)
                    start!(s, ctx; doreset=false)
                end
                lock(rlock) do
                    push!(results, (; step=n, metrics_func(s; initial_cash)...))
                    @pbupdate!
                end
            end
        end
    end
    results
end

export gridsearch, progsearch, slidesearch
