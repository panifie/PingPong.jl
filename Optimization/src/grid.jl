using Pbar.Term.Progress: @track, ProgressJob, Progress
using Pbar: pbar!, @withpbar!, @pbupdate!
using SimMode.Instruments: compactnum as cnum, Instruments
using SimMode.Lang.Logging: SimpleLogger, with_logger, current_logger
using SimMode.Lang: splitkws
using Stats.Data: Cache as ca, nrow, groupby, combine, DataFrame, DATA_PATH
using Random: shuffle!

using Printf: @sprintf
using Base.Sys: free_memory
import .Progress: AbstractColumn, get_columns
import Pbar.Term.Segments: Segment
import Pbar.Term.Measures: Measure

function _tostring(_, s::String)
    s[begin:min(displaysize()[2], length(s))]
end
Instruments.compactnum(v) = v
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
        txt.measure.w = 15
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

function gridfromresults(sess::OptSession, results; kwargs...)
    params = keys(sess.params)
    [((getproperty(row, p) for p in params)...,) for row in eachrow(results)]
end

function resume!(sess; zi=zilmdb())
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
    repeats = sess.opt_config.repeats
    completed = DataFrame(filter(g -> nrow(g) == repeats, gd))
    empty!(sess.results)
    append!(sess.results, completed)
end

function optsession(s::Strategy; seed=1, repeats=1, offset=0)
    ctx, params, grid = ping!(s, OptSetup())
    OptSession(s; ctx, params, offset, attrs=Dict(pairs((; seed, repeats))))
end

@doc "Backtests the strategy across combination of parameters.
`s`: The strategy.
`seed`: random seed set before each backtest run.
`repeats`: the amount of repetitions for each combination.
`save_freq`: how frequently (`Period`) to save results, when `nothing` (default) saving is skipped.
`logging`: enabled logging
`doshuffle`: shuffle parameters combinations before iterations (random search)
"
function gridsearch(
    s::Strategy{Sim};
    seed=1,
    repeats=1,
    save_freq=nothing,
    resume=true,
    logging=true,
    random_search=false,
    zi=zilmdb(),
    grid_itr=nothing,
    offset=0,
)
    running!()
    sess = optsession(s; seed, repeats, offset)
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
        sess.best[] = if isone(n_obj)
            zero(eltype(obj_type))
        else
            ((zero(eltype(obj_type)) for _ in 1:n_obj)...,)
        end
        ismulti = n_obj > 1
        opt_func = define_opt_func(
            s; backtest_func, ismulti, repeats, obj_type, isthreaded=false
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
                                save_session(sess; from=from[], zi)
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
    _, fw_kwargs = splitkws(:offset, :repeats, :grid_itr; kwargs)
    init_offset = isnothing(sess) ? 0 : sess[].attrs[:offset] + 1
    sess[] =
        let offset = init_offset,
            grid_itr = if isnothing(sess)
                nothing
            else
                gridfromresults(sess[], filter_results(s, sess[]; cut))
            end

            gridsearch(s; offset, grid_itr, repeats=1, fw_kwargs...)
        end
    for offset in (init_offset + 1):rcount
        results = filter_results(s, sess[]; cut)
        grid_itr = gridfromresults(sess[], results)
        if length(grid_itr) < 3
            @info "Search stopped because no results were left to filter."
            break
        end
        sess[] = gridsearch(s; offset, repeats=1, grid_itr, fw_kwargs...)
    end
    sess[]
end

@doc "Backtests by sliding over the backtesting period, by the smallest timeframe (the strategy timeframe). Until
a full range of timeframes is reached between the strategy timeframe and backtesting context timeframe.
`multiplier`: the steps count (total stepps will be `multiplier * context_timeframe / s.timeframe` )
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
                    backtest!(s, ctx; doreset=false)
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
