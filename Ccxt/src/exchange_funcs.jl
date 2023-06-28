@doc "Track all exchanges finalizers."
const exc_finalizers = Set{Task}()
const exc_finalizers_lock = ReentrantLock()

function close_exc(e::Py)
    t = @async if !pyisnull(e) && pyhasattr(e, "close")
        co = e.close()
        if !pyisnull(co) && pyisinstance(co, Python.gpa.pycoro_type)
            wait(pytask(co, Val(:coro)))
        end
    end
    @async lock(exc_finalizers_lock) do
        push!(exc_finalizers, t)
        wait(t)
        pop!(exc_finalizers, t)
    end
end

_issupported(has::Py, k) = k in has && Bool(has[k])
issupported(exc, k) = _issupported(exc.py.has, k)

@doc "Instantiate a ccxt exchange class matching name."
function ccxt_exchange(name::Symbol, params=nothing; kwargs...)
    @debug "Instantiating Exchange $name..."
    exc_cls = if hasproperty(ccxt_ws[], name)
        getproperty(ccxt_ws[], name)
    else
        getproperty(ccxt[], name)
    end
    finalizer(close_exc, isnothing(params) ? exc_cls() : exc_cls(params))
end
