using ..Fetch.Instruments.Derivatives

CgSymDerivative = @NamedTuple begin
    symbol::Symbol
    index::Float64
    contract_type::String
    h24_percentage_change::Float64
    last_traded::DateTime
    bid_ask_spread::Float64
    index_basis_percentage::Float64
    last::Float64
    open_interest_usd::Float64
    expired_at::Option{DateTime}
    funding_rate::Float64
end
const CgDerivativesVal = Val{:cg_derivatives}

@doc """ Create a `Watcher` instance that tracks all the derivatives from an exchange.

"""
function cg_derivatives_watcher(exc_name)
    cg.check_drv_exchange(exc_name)
    attrs = Dict{Symbol,Any}()
    attrs[:exc] = exc_name
    attrs[:key] = "cg_$(exc_name)_derivatives"
    watcher_type = Dict{Derivative,CgSymDerivative}
    wid = string(CgDerivativesVal.parameters[1], "-", hash(exc_name))
    watcher(
        watcher_type,
        wid,
        CgDerivativesVal();
        flush=true,
        process=true,
        fetch_interval=Second(360),
        attrs,
    )
end

function _fetch!(w::Watcher, ::CgDerivativesVal)
    mkts = try
        cg.derivatives_from(attr(w, :exc))
    catch e
        @error "cg_derivatives: fetch" exception = e
        rethrow(e)
    end
    if length(mkts) > 0
        result = Dict{Derivative,CgSymDerivative}()
        for (k, m) in mkts
            result[k] = fromdict(CgSymDerivative, String, m)
        end
        pushnew!(w, result)
        true
    else
        false
    end
end

function _cg_drv_append_buffer(dict, buf, maxlen)
    data = @collect_buffer_data buf Derivative CgSymDerivative
    @append_dict_data dict data maxlen
end

_init!(w::Watcher, ::CgDerivativesVal) = default_init(w, Dict{Derivative,DataFrame}())
_process!(w::Watcher, ::CgDerivativesVal) = default_process(w, _cg_drv_append_buffer)
