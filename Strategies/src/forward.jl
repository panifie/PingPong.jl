module Forward
using MacroTools
# using ..Strategies: ping!
using ..Strategies
using ..Strategies: ExecMode, ExchangeID, MarginMode

strategy_param_type(v) =
    if v == :M
        ExecMode
    elseif v == :N
        Symbol
    elseif v == :E
        ExchangeID
    elseif v == :R
        MarginMode
    else
        Symbol
    end
@doc """Takes as input a strategy type and replaces the type parameters with the ones `kwargs...`
`M`,`N`,`E`,`R`,`C` for respectively execmode, name, exchangeid, marginmode, cash."""
function strategytype(stp; kwargs...)
    if hasproperty(stp, :body)
        strategytype(stp.body; kwargs...)
    else
        params = [typeparameters(stp)...]
        tp = Strategy
        tp_params = :()
        for (n, p) in enumerate((:M, :N, :E, :R, :C))
            par = get(params, n, nothing)
            newp = if haskey(kwargs, p)
                if p == :N
                    :($(QuoteNode(kwargs[p])))
                else
                    :($(kwargs[p]))
                end
            elseif isnothing(par) || par isa TypeVar
                :($p where {$p<:$(strategy_param_type(p))})
            elseif p == :N
                :($(QuoteNode(par)))
            else
                :($p where {$p<:$par})
            end
            push!(tp_params.args, newp)
        end
        :($(tp){$(tp_params)...})
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

function typeparameters(expr)
    if hasproperty(expr, :parameters)
        expr.parameters
    elseif hasproperty(expr, :ub)
        typeparameters(expr.ub)
    else
        typeparameters(expr.body)
    end
end

getname(v::Symbol) = v
function getname(expr)
    if hasproperty(expr, :ub)
        getname(expr.ub)
    elseif hasproperty(expr, :body)
        getname(expr.body)
    else
        expr.name.name
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
            type_params = Any[typeparameters(p)...]
            n_tp, newtp = replacestrat!(func, type_params, p)
            if !isnothing(newtp)
                type_params[n_tp] = newtp
                params[n] = eval(name){type_params...}
            end
        end
    end
    nothing, nothing
end

function function_args_expr(pnames, params)
    out = []
    vars = []
    for (n, p) in zip(pnames, params)
        for tp in typeparameters(p)
            if tp isa TypeVar
                push!(vars, typename(tp))
            end
        end
        tp = Meta.parse(string(p))
        push!(
            out,
            if n != ""
                if isempty(vars)
                    :($(Symbol(n))::$tp)
                else
                    :($(Symbol(n))::$tp where {$(vars...)})
                end
            else
                if isempty(vars)
                    :(::$tp)
                else
                    :(::$tp where {$(vars...)})
                end
            end,
        )
        empty!(vars)
    end
    out
end

function typename(tp)
    if hasproperty(tp, :name)
        tp.name
    else
        tp
    end
end

@doc """ Defines `ping!` functions in the strategy module `to_strat` (calling the macro) forwarding to
the `ping!` functions defined in the strategy module `from_strat`.
"""
macro forwardstrategy(from_strat, to_strat=__module__, exc=nothing, margin=nothing)
    ping_func = @__MODULE__().ping!
    if from_strat isa Symbol
        from_mod = top_mod = from_s_name = from_strat
    elseif from_strat isa Expr
        top_mod, from_s_name = topmodule(from_strat)
        from_mod = deepcopy(from_strat)
        @assert from_strat.head == :(.) "argument is not a valid module"
        pushfirst!(from_strat.args, :(.))
        from_strat.args[end] = from_strat.args[end].value
    end
    to_s_name = to_strat isa Module ? nameof(to_strat) : Symbol(to_strat)
    to_s_mod = to_strat isa Module ? to_strat : @eval __module__ $to_strat
    quote
        isdefined($(__module__), $(QuoteNode(top_mod))) || using .$top_mod
        $(Expr(:using, from_strat))
        let
            to_s_mod = $to_s_mod
            to_params = typeparameters(
                getproperty(to_s_mod, hasproperty($to_s_mod, :S) ? :S : :SC)
            )
            to_kwargs = NamedTuple(
                p => to_params[n] for
                (n, p) in enumerate((:M, :N, :E, :R, :C)) if typename(to_params[n]) != p
            )
            from_mod = getproperty($__module__, $(QuoteNode(from_s_name)))
            for met in methods($ping_func, from_mod)
                pnames = String[x[1] for x in Base.arg_decl_parts(met)[2][2:end]]
                params = [typeparameters(met.sig)[2:end]...]
                replacestrat!(params) do tp
                    expr = strategytype(tp; to_kwargs...)
                    Core.eval($__module__, expr)
                end
                args = function_args_expr(pnames, params)
                fdef = :(function ping!($(args...); kwargs...)
                    # invoke(ping!, $(met.sig), $(pnames)...; kwargs...)
                end)
                @info fdef
                Core.eval($__module__, fdef)
            end
        end
    end
end
end
