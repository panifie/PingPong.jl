using Lang: Option
using Instruments.Derivatives

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

@doc """ Create a `Watcher` instance that tracks all the derivatives from an exchange.

"""
function cg_derivatives_watcher(exc_name)
    cg.check_drv_exchange(exc_name)
    fetcher() = begin
        mkts = cg.derivatives_from(exc_name)
        result = Dict{Derivative,CgSymDerivative}()
        for (k, m) in mkts
            result[k] = @fromdict(CgSymDerivative, String, m)
            result
        end
        result
    end

    name = "cg_$(exc_name)_derivatives"
    watcher_type = Dict{Derivative, CgSymDerivative}
    watcher(watcher_type, name, fetcher; flusher=true, interval=Second(360))
end
