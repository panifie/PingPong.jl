@doc "Python enlighten progressbar wrapper."
module Pbar

using Python
using Python.PythonCall: pynew, keys, pyisnull, pycopy!
using TimeTicks: now, Millisecond, Second

const min_delta = Ref(Millisecond(0))
const queued_counter = Ref(0)
const enlighten = pynew()
const emn = pynew()
const pbar = pynew()
const six = pynew()

mutable struct PbarInstance
    pbar::Py
    fin::Bool
end

function clearpbar(pb)
    pb.pbar ∈ emn.counters.keys() && pbclose(pb)
end

function __init__()
    # Misc.__init__()
    @pymodule six
    @pymodule enlighten
    # pycopy!(enlighten, pyimport("enlighten"))
    pyisnull(emn) || emn.stop()
    pycopy!(emn, enlighten.get_manager())
    @debug @info "Pbar: Loaded enlighten."
end

@doc "Instantiate a progress bar:
- `data`: `length(data)` determines the bar total
- `unit`: what unit the display
- `desc`: description will appear over the progressbar
"
macro pbar!(data, desc="", unit="", use_finalizer=false)
    data = esc(data)
    desc = esc(desc)
    unit = esc(unit)
    plu = esc(:pb_last_update)
    pb = esc(:pb)
    uf = esc(use_finalizer)
    quote
        @pbinit!
        !$pyisnull($pbar) && try
            $pbar.close(; clear=true)
        catch
        end
        pycopy!(
            $pbar, $emn.counter(; total=length($data), desc=$desc, unit=$unit, leave=false)
        )
        local $pb
        if $uf
            $pb = let $pb = PbarInstance($pbar, true)
                finalizer($clearpbar, $pb)
            end
        else
            $pb = PbarInstance($pbar, false)
        end
        $min_delta[] = Millisecond($pyconvert(Float64, $pbar.min_delta) * 1e3)
        $pbar.refresh()
        local $plu = $now()
        $pb
    end
end

@doc "Single update to the progressbar with the new value."
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

@doc "Terminates the progress bar."
function pbclose(pb)
    pb.pbar.close(; clear=true)
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
        $pbar.close(; clear=true)
        $emn.stop()
    end
end

macro pbinit!()
    :($(__init__)())
end

export @pbar!, @pbupdate!, @pbclose!, @pbstop, @pbinit!

end
