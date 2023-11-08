_issupported(has::Py, k) = k in has && Bool(has[k])
issupported(exc, k) = _issupported(exc.py.has, k)

_lazypy(ref, mod) = begin
    if isassigned(ref)
        r = ref[]
        if isnothing(r)
            ref[] = pyimport(mod)
        elseif pyisnull(r)
            pycopy!(r, pyimport(mod))
            r
        else
            r
        end
    else
        ref[] = pyimport(mod)
    end
end

ccxtws() = _lazypy(ccxt_ws, "ccxt.pro")
ccxtasync() = _lazypy(ccxt, "ccxt.async_support")

@doc "Instantiate a ccxt exchange class matching name."
function ccxt_exchange(name::Symbol, params=nothing; kwargs...)
    @debug "Instantiating Exchange $name..."
    ws = ccxtws()
    exc_cls = if hasproperty(ws, name)
        getproperty(ws, name)
    else
        async = ccxtasync()
        getproperty(async, name)
    end
    isnothing(params) ? exc_cls() : exc_cls(params)
end

ccxt_exchange_names() = ccxtasync().exchanges

export ccxt_exchange_names
