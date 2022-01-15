module Pbar

using PyCall: PyNULL, PyObject, @pyimport, ispynull
using Dates: now, Millisecond, Second

const enlighten = PyNULL()
const emn = PyNULL()
const pbar = PyNULL()
const min_delta = Ref(Millisecond(0))

mutable struct PbarInstance
    pbar::PyObject
end

function clearpbar(pb)
    pb.pbar.close(;clear=true)
end

function __init__()
    @eval @pyimport enlighten
    ispynull(emn) || emn.stop()
    copy!(emn, enlighten.get_manager())
    @info "Pbar: Loaded enlighten."
end

macro pbar!(data, desc="", unit="")
    data = esc(data)
    desc = esc(desc)
    unit = esc(unit)
    plu = esc(:pb_last_update)
    pb = esc(:pb)
    quote
        @pbinit!
        !$ispynull($pbar) && try $pbar.close(;clear=true) catch end
        copy!($pbar, $emn.counter(;total=length($data), desc=$desc, unit=$unit, leave=false))
        $pb = PbarInstance($pbar)
        finalizer($clearpbar, $pb)
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
            t - $plu > $min_delta[] && $pb.pbar.update($n, $args...)
            $plu = t
        end
    end
end

macro pbclose()
    :(pb.pbar.close(;clear=true))
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
