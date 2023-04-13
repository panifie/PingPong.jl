function close_exc(e::Py)
    @async if !pyisnull(e) && pyhasattr(e, "close")
        co = e.close()
        if !pyisnull(co) && pyisinstance(co, pycoro_type)
            wait(pytask(co, Val(:coro)))
        end
    end
end

_issupported(has::Py, k) = k in has && Bool(has[k])
issupported(exc, k) = _issupported(exc.py.has, k)

@doc "Instantiate a ccxt exchange class matching name."
function ccxt_exchange(
    name::Symbol, params=nothing; kwargs...
)
    @debug "Instantiating Exchange $name..."
    exc_cls = if hasproperty(ccxt_ws[], name)
        getproperty(ccxt_ws[], name)
    else
        getproperty(ccxt[], name)
    end
    finalizer(close_exc, isnothing(params) ? exc_cls() : exc_cls(params))
end
