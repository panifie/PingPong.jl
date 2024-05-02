@doc """
Initialize parameters for a strategy during optimization.

$(TYPEDSIGNATURES)

This function initializes the parameters for a strategy during optimization. If no parameters are provided, it uses the default parameters.
"""
function initparams!(s, params)
    attrs = s.attrs
    let params_index = @lget! attrs :params_index Dict{Symbol, Any}()
        empty!(params_index)
        for (n, k) in enumerate(keys(params))
            params_index[k] = n
        end
    end
end

@doc """
Override attributes in a strategy with values from a dict for optimization.

overrides!(s::AbstractStrategy) -> AbstractStrategy

Override attributes in `s` with values from its `overrides` attribute.
This is useful for passing in parameters during an optimization run.

"""
overrides!(s) = begin
    attrs = s.attrs
    for (k, v) in pairs(get(attrs, :overrides, ()))
        attrs[k] = v
    end
    s
end

@doc """ Retrieves a parameter value from a strategy based on a symbol index

$(TYPEDSIGNATURES)

Retrieves a parameter value `sym` from `params` using the symbol index in `s[:params_index]`.
"""
getparam(s, params, sym) = params[s[:params_index][sym]]
