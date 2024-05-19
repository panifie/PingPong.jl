@doc """
Override attributes in a strategy with values from a given parameters dictionary.

overrides!(s::AbstractStrategy, params::Dict, pidx::Dict) -> AbstractStrategy

Override attributes in `s` with values from the `params` dictionary using the parameter index `pidx`.
This is useful for updating strategy attributes during an optimization run.

"""
setparams!(s, sess, params) = begin
    attrs = s.attrs
    for (n, pname) in enumerate(keys(sess.params))
        attrs[pname] = params[n]
    end
    s
end
