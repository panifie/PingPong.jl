module Pbar

using PyCall: PyNULL, PyObject, ispynull, pyimport
using Dates: now, Millisecond, Second

const enlighten = PyNULL()
const emn = PyNULL()
const pbar = PyNULL()
const min_delta = Ref(Millisecond(0))
const queued_counter = Ref(0)

mutable struct PbarInstance
    pbar::PyObject
    fin::Bool
end

function clearpbar(pb)
    pb.pbar ∈ keys(emn.counters) && pbclose(pb)
end

function __init__()
    copy!(enlighten, pyimport("enlighten"))
    ispynull(emn) || emn.stop()
    copy!(emn, enlighten.get_manager())
    @debug @info "Pbar: Loaded enlighten."
end

macro pbar!(data, desc="", unit="", use_finalizer=false)
    data = esc(data)
    desc = esc(desc)
    unit = esc(unit)
    plu = esc(:pb_last_update)
    pb = esc(:pb)
    uf = esc(use_finalizer)
    quote
        @pbinit!
        !$ispynull($pbar) && try $pbar.close(;clear=true) catch end
        copy!($pbar, $emn.counter(;total=length($data), desc=$desc, unit=$unit, leave=false))
        local $pb
        if $uf
            $pb = PbarInstance($pbar, true)
            finalizer($clearpbar, $pb)
        else
            $pb = PbarInstance($pbar, false)
        end
        $min_delta[] = Millisecond($pbar.min_delta * 1e3)
        $pbar.refresh()
        local $plu = $now()
        $pb
    end
end

macro pbupdate!(n=1, args...)
    n = esc(n)
    plu = esc(:pb_last_update)
    pb = esc(:pb)
    quote
        let t = $now()
            if t - $plu > $min_delta[]
                $pb.pbar.update($queued_counter[] + $n, $args...)
                $plu = t
                $queued_counter[] = 0
            else
                $queued_counter[] += 1
            end
        end
    end
end

function pbclose(pb)
    pb.pbar.close(;clear=true)
end

macro pbclose()
    pb = esc(:pb)
    quote
        $pbclose($pb)
    end
end

macro pbstop()
    # FIXME: kwarg clear=true doesn't seem to work
    quote
        $pbar.close(;clear=true)
        $emn.stop()
    end
end

macro pbinit!()
    :($(__init__)())
end

export @pbar!, @pbupdate!, @pbclose, @pbstop, @pbinit!

end
