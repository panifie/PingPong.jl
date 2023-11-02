module Forward
using MacroTools

@doc """Takes as input a strategy type and replaces the type parameters with the ones `kwargs...`
`M`,`N`,`E`,`R`,`C` for respectively execmode, name, exchangeid, marginmode, cash."""
function strategytype(stp; kwargs...)
    if hasproperty(stp, :body)
        strategytype(stp.body; kwargs...)
    else
        params = [getparameters(stp)...]
        tp = Strategy
        for (n, p) in enumerate((:M, :N, :E, :R, :C))
            par = get(params, n, p)
            tp = if haskey(kwargs, p)
                tp{kwargs[p]}
            elseif par == p
                tp{p} where {p}
            else
                tp{par}
            end
        end
        tp
    end
end

function topmodule(expr)
    @capture expr P_.C_
    if P isa Symbol
        P, C
    else
        topmodule(P), C
    end
end

function getparameters(expr)
    if hasproperty(expr, :parameters)
        expr.parameters
    elseif hasproperty(expr, :ub)
        getparameters(expr.ub)
    else
        getparameters(expr.body)
    end
end

function getname(expr)
    if hasproperty(expr, :ub)
        getname(expr.ub)
    elseif hasproperty(expr, :body)
        getname(expr.body)
    else
        nameof(expr)
    end
end

function replacestrat!(func, params, supertp=missing)
    for (n, p) in enumerate(params)
        name = getname(p)
        if name == :Strategy
            if ismissing(supertp)
                params[n] = func(p)
            else
                return n, func(p)
            end
        elseif name in (:Type, :Union)
            type_params = [getparameters(p)...]
            n_tp, newtp = replacestrat!(func, type_params, p)
            if !isnothing(newtp)
                this_tp = type_params[n_tp]
                if this_tp isa TypeVar
                    type_params[n_tp] = TypeVar(this_tp.name, this_tp.lb, newtp)
                else
                    type_params[n_tp] = newtp
                end
                params[n] = eval(name){type_params...}
            end
        end
    end
    nothing, nothing
end

@doc """ Defines `ping!` functions in the strategy module `to_strat` (calling the macro) forwarding to
the `ping!` functions defined in the strategy module `from_strat`.
"""
macro forwardstrategy(from_strat, to_strat=__module__)
    if from_strat isa Symbol
        top_mod = from_s_name = from_strat
    elseif from_strat isa Expr
        top_mod, from_s_name = topmodule(from_strat)
        @assert from_strat.head == :(.) "argument is not a valid module"
        pushfirst!(from_strat.args, :(.))
        from_strat.args[end] = from_strat.args[end].value
    end
    to_s_name = to_strat isa Module ? nameof(to_strat) : Symbol(to_strat)
    to_s_mod = to_strat isa Module ? to_strat : Module(to_strat)
    quote
        isdefined($(__module__), $(QuoteNode(top_mod))) || $(Expr(:using, top_mod))
        $(Expr(:using, from_strat))
        for met in methods(ping!, $(from_s_name))
            params = [getparameters(met.sig)...]
            replacestrat!(params) do tp
                strategytype(tp; N=$(QuoteNode(to_s_name)))
            end
            @eval to_s_mod function ping!(Tuple{params...}; kwargs...)
                invoke(ping!, met.sig...; kwargs...)
            end
        end
    end
end
end
