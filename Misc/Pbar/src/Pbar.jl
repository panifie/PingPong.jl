@doc "Progress bar wrapper."
module Pbar

using Term.Progress
using TimeTicks: now, Millisecond, Second
using Lang: toggle!

const min_delta = Ref(Millisecond(0))
const queued_counter = Ref(0)
const pbar = Ref{Union{Nothing,ProgressBar}}(nothing)

function clearpbar(pb)
    if !pb.paused
        stop!(pb)
    end
    for j in pb.jobs
        stop!(j)
    end
    empty!(pb.jobs)
end

function __init__()
    if isnothing(pbar[])
        pbar[] = ProgressBar(; transient=true, columns=:detailed)
    end
    clearpbar(pbar[])
    @debug "Pbar: Loaded."
end

const plu = esc(:pb_last_update)
const pbj = esc(:pb_job)

@doc "Toggles pbar transient flag"
transient!(pb=pbar[]) = toggle!(pb, :transient)

@doc "Instantiate a progress bar:
- `data`: `length(data)` determines the bar total
- `unit`: what unit the display
- `desc`: description will appear over the progressbar
"
macro pbar!(data, desc="", unit="", delta=Millisecond(10)) # use_finalizer=false)
    data = esc(data)
    desc = esc(desc)
    unit = esc(unit)
    pbar = Pbar.pbar[]
    quote
        @pbinit!
        start!($pbar)
        $queued_counter[] = 1
        $min_delta[] = $(esc(delta))
        $pbj = addjob!($pbar; description=$desc, N=length($data), transient=true)
        $plu = $now()
        render($pbar)
        yield()
    end
end

@doc "Single update to the progressbar with the new value."
macro pbupdate!(n=1, args...)
    n = esc(n)
    pbar = Pbar.pbar[]
    quote
        let t = $now()
            if t - $plu > $(min_delta[]) # min_delta should not mutate
            Main.display!("Pbar.jl:65")
                update!($pbj; i=$queued_counter[])
                $queued_counter[] = 1
                $plu = t
                render($pbar)
                yield()
            else
                $queued_counter[] += 1
            end
        end
    end
end

@doc "Terminates the progress bar."
function pbclose(pb, complete=true)
    if complete
        for j in pb.jobs
            if !isnothing(j.N)
                update!(j; i=j.N - j.i)
                render(pb)
            end
        end
    end
    stop!(pb)
end

macro pbclose()
    pbar = Pbar.pbar[]
    quote
        $pbclose($pbar)
    end
end

macro pbstop()
    # FIXME: kwarg clear=true doesn't seem to work
    quote
        $stop!($(pbar[]))
    end
end

macro pbinit!()
    :($(__init__)())
end

export @pbar!, @pbupdate!, @pbclose, @pbstop, @pbinit!, transient!

end
