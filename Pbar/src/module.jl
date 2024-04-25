using Term.Progress
using Term: Term
using TimeTicks: now, Millisecond, Second, DateTime, Lang
using .Lang: toggle!, @preset, @precomp
using .Lang.DocStringExtensions

@doc "Stores the timestamp of the last render in the progress bar."
const last_render = Ref(DateTime(0))
@doc "Stores the minimum time difference required between two render updates."
const min_delta = Ref(Millisecond(0))
@doc "Holds a reference to the current progress bar or `nothing` if no progress bar is active."
const pbar = Ref{Union{Nothing,ProgressBar}}(nothing)
@doc "Holds a lock to avoid flickering when updating the progress bar."
const pbar_lock = ReentrantLock()

@doc """ Represents a job that is currently running in the progress bar.

$(FIELDS)

The `RunningJob` struct holds a `ProgressJob`, a counter, and a timestamp of when it was last updated.
The `job` field is of type `ProgressJob` which represents the job that is currently running.
The `counter` field is an integer that defaults to 1 and is used to keep track of the progress of the job.
The `updated_at` field is a `DateTime` object that stores the timestamp of when the job was last updated.
"""
@kwdef mutable struct RunningJob
    job::ProgressJob
    counter::Int = 1
    updated_at::DateTime = now()
end

@doc """ Clears the current progress bar.

$(TYPEDSIGNATURES)

The `clearpbar` function stops all jobs in the current progress bar, empties the job list, and then stops the progress bar itself. It uses a lock to ensure thread safety during these operations.
"""
function clearpbar(pb=pbar[])
    !isnothing(pb) && @lock pbar_lock begin
        for j in pb.jobs
            stop!(j)
        end
        empty!(pb.jobs)
        stop!(pb)
    end
end

@doc """ Initializes a new progress bar.

$(TYPEDSIGNATURES)

The `pbar!` function first clears any existing progress bar, then creates a new `ProgressBar` with the provided arguments. The `transient` argument defaults to `true`, and `columns` defaults to `:default`.
"""
function pbar!(; transient=true, columns=:default, kwargs...)
    clearpbar()
    pbar[] = ProgressBar(; transient, columns, kwargs...)
end

function _doinit()
    pbar!()
    @debug "Pbar: Loaded."
end

@doc "Initializes the progress bar."
macro pbinit!()
    :($(_doinit)())
end

@doc "The last update timestamp."
const plu = esc(:pb_last_update)
@doc "The current job being rendered."
const pbj = esc(:pb_job)

@doc "Toggles pbar transient flag"
transient!(pb=pbar[]) = @lock pbar_lock toggle!(pb, :transient)

@doc "Set the update frequency globally."
frequency!(v) = @lock pbar_lock min_delta[] = v

# This prevents flickering when we render too frequently
@doc "Renders the progress bar if enough time has passed since the last render."
function dorender(pb, t=now())
    @lock pbar_lock if t - last_render[] > min_delta[]
        render(pb)
        last_render[] = t
        yield()
        true
    end
    false
end

@doc "Starts a new job in the progress bar."
function startjob!(pb, desc="", N=nothing)
    @lock pbar_lock begin
        job = let j = addjob!(pb; description=desc, N, transient=true)
            RunningJob(; job=j)
        end
        pb.running || begin
            start!(pb)
            dorender(pb)
        end
        yield()
        job
    end
end

@doc "Instantiate a progress bar:

$(TYPEDSIGNATURES)

- `data`: `length(data)` determines the bar total
- `unit`: what unit the display
- `desc`: description will appear over the progressbar
"
macro pbar!(data, desc="", unit="") # use_finalizer=false)
    @pbinit!
    data = esc(data)
    desc = esc(desc)
    unit = esc(unit)
    quote
        $pbj = startjob!($pbar[], $desc, length($data))
    end
end

@doc "Complete a job."
function complete!(pb, j, force=true)
    if !isnothing(j.N)
        if j.finished || j.N != j.i
            update!(j; i=j.N - j.i)
            dorender(pb)
        end
        if force || !j.transient
            if j in pb.jobs
                removejob!(pb, j)
            end
        end
    end
    nothing
end

@doc "Stops the progress bar."
macro pbstop!()
    quote
        @lock pbar_lock isempty($pbar[].jobs) && $stop!($pbar[])
        nothing
    end
end

@doc "Same as `@pbar!` but with implicit closing.

$(TYPEDSIGNATURES)

The first argument should be the collection to iterate over.
Optional kw arguments:
- `desc`: description
"
macro withpbar!(data, args...)
    @pbinit!
    data = esc(data)
    desc = unit = ""
    code = nothing
    for a in args
        if a.head == :(=)
            if a.args[1] == :desc
                desc = esc(a.args[2])
            elseif a.args[1] == :unit
                unit = esc(a.args[2])
            end
        else
            code = esc(a)
        end
    end
    quote
        local $pbj = startjob!($pbar[], $desc, length($data))
        local iserror = false
        try
            $code
        catch e
            if e isa InterruptException
                rethrow(e)
            else
                iserror = true
            end
        finally
            pbclose!($pbj.job, $pbar[])
        end
    end
end

@doc "Single update to the progressbar with the new value."
macro pbupdate!(n=1, args...)
    n = esc(n)
    quote
        $pbar[].running && let t = $now()
            if t - $last_render[] > $(min_delta[]) # min_delta should not mutate
                update!($pbj.job; i=$pbj.counter)
                dorender($pbar[], t)
                $pbj.counter = $n
            else
                $pbj.counter += $n
            end
        end
        nothing
    end
end

@doc """ Terminates the progress bar.

$(TYPEDSIGNATURES)

The `pbclose!` function completes all jobs in the progress bar and then stops the progress bar itself.
"""
function pbclose!(pb::ProgressBar=pbar[], all=true)
    all && foreach(j -> complete!(pb, j), pb.jobs)
    stop!(pb)
    nothing
end

@doc "Stops the progress bar after completing the job."
function pbclose!(job, pb=pbar[])
    complete!(pb, job)
    @pbstop!
    nothing
end

@doc "Calls `pbclose!` on the global progress bar."
macro pbclose!()
    quote
        $pbclose!($pbj.job, $pbar[])
    end
end


export @pbar!, @pbupdate!, @pbclose!, @pbstop!, @pbinit!, transient!, @withpbar!, @track
