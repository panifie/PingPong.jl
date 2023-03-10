@doc "Progress bar wrapper."
module Pbar

using Term.Progress
using TimeTicks: now, Millisecond, Second, DateTime
using Lang: toggle!

const last_render = Ref(DateTime(0))
const min_delta = Ref(Millisecond(0))
const pbar = Ref{Union{Nothing,ProgressBar}}(nothing)
const pbar_lock = ReentrantLock()
@kwdef mutable struct RunningJob
    job::ProgressJob
    counter::Int = 1
    updated_at::DateTime = now()
end

function clearpbar(pb=pbar[])
    !isnothing(pb) && @lock pbar_lock begin
        for j in pb.jobs
            stop!(j)
        end
        empty!(pb.jobs)
        stop!(pb)
    end
end

function pbar!(; transient=true, columns=:default, kwargs...)
    clearpbar()
    pbar[] = ProgressBar(; transient, columns, kwargs...)
end

function __init__()
    pbar!()
    @debug "Pbar: Loaded."
end

macro pbinit!()
    :($(__init__)())
end

const plu = esc(:pb_last_update)
const pbj = esc(:pb_job)

@doc "Toggles pbar transient flag"
transient!(pb=pbar[]) = @lock pbar_lock toggle!(pb, :transient)

@doc "Set the update frequency globally."
frequency!(v) = @lock pbar_lock min_delta[] = v

# This prevents flickering when we render too frequently
function dorender(pb, t=now())
    @lock pbar_lock if t - last_render[] > min_delta[]
        render(pb)
        last_render[] = t
        yield()
        true
    end
    false
end

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

function complete!(pb, j)
    if !isnothing(j.N)
        (j.finished || j.N != j.i) && begin
            update!(j; i=j.N - j.i)
            dorender(pb)
        end
        (!j.transient) && removejob!(pb, j)
    end
    nothing
end

macro pbstop!()
    quote
        @lock pbar_lock isempty($pbar[].jobs) && $stop!($pbar[])
        nothing
    end
end

@doc "Same as `@pbar!` but with implicit closing."
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
        catch
            iserror = true
            pbclose!($pbar[])
            clearpbar($pbar[])
        finally
            iserror || pbclose!($pbj.job, $pbar[])
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
                $pbj.counter = 1
            else
                $pbj.counter += 1
            end
        end
        nothing
    end
end

@doc "Terminates the progress bar."
function pbclose!(pb::ProgressBar=pbar[], all=true)
    all && foreach(j -> complete!(pb, j), pb.jobs)
    stop!(pb)
    nothing
end

function pbclose!(job, pb=pbar[])
    complete!(pb, job)
    @pbstop!
    nothing
end

macro pbclose!()
    quote
        $pbclose!($pbj.job, $pbar[])
    end
end

export @pbar!, @pbupdate!, @pbclose!, @pbstop!, @pbinit!, transient!, @withpbar!, @track

end
