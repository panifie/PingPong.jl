module Forward
using MacroTools
using ..Strategies: ping!
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
        Any
    end
@doc """Takes as input a strategy type and replaces the type parameters with the ones `kwargs...`
`M`,`N`,`E`,`R`,`C` for respectively execmode, name, exchangeid, marginmode, cash."""
function strategytype(stp; mod=Strategies, ex=Expr(:a), wh=Any[], kwargs...)
    if hasproperty(stp, :body)
        strategytype(stp.body; mod, ex, kwargs...)
    else
        params = [typeparameters(stp)...]
        tp = Strategy
        tp_params = []
        for (n, p) in enumerate((:M, :N, :E, :R, :C))
            par = get(params, n, nothing)
            newp = if haskey(kwargs, p)
                if p == :N
                    :($(QuoteNode(kwargs[p])))
                else
                    :($(kwargs[p]))
                end
            elseif isnothing(par) || par isa TypeVar
                push!(wh, :($p <: $(strategy_param_type(p))))
                :($p)
            elseif p == :N
                :($(QuoteNode(par)))
            else
                super = Meta.parse("$(mod).$(par)")
                push!(wh, :($p <: $super))
                :($p)
            end
            push!(tp_params, newp)
        end
        ex.head = :where
        push!(ex.args, Expr(:curly, tp, tp_params...))
        push!(ex.args, wh...)
        ex
    end
end

function topmodule(expr)
    @capture expr P_.C_
    if P isa Symbol
        P, C
    else
        topmodule(P)[1], C
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

function replacestrat!(func, params, supertp=missing; out=Any[])
    for (n, p) in enumerate(params)
        name = getname(p)
        if name == :Strategy
            if ismissing(supertp)
                # params[n] = func(p)
                push!(out, func(p))
            else
                return n, func(p)
            end
        elseif name in (:Type, :Union)
            type_params = Any[typeparameters(p)...]
            n_tp, newtp = replacestrat!(func, type_params, p; out)
            if !isnothing(newtp)
                type_params_exprs = Any[Meta.parse(string(tp)) for tp in type_params]
                type_params_exprs[n_tp] = newtp
                if type_params[n_tp] isa TypeVar
                    insert!(type_params_exprs, n_tp, :(<:))
                end
                push!(out, "$name{$(type_params_exprs...)}")
            end
        else
            push!(out, p)
        end
    end
    nothing, nothing
end

function function_args_expr(pnames, params)
    arg_sig = []
    arg_names = Symbol[]
    for (n, tp) in zip(pnames, params)
        tp = replace(string(tp), r"var\"\#.*\"" => "") |> Meta.parse
        name = if n != ""
            Symbol(replace(n, "..." => ""))
        else
            gensym()
        end
        push!(arg_names, name)
        push!(arg_sig, :($name::$(tp)))
    end
    arg_sig, arg_names
end

function typename(tp)
    if hasproperty(tp, :name)
        tp.name
    else
        tp
    end
end

_mod_syms(expr, syms=[]) = begin
    if expr isa Symbol
        pushfirst!(syms, expr)
    elseif expr.head == :.
        pushfirst!(syms, expr.args[2].value)
        _mod_syms(expr.args[1], syms)
    end
    syms
end

@doc """ Defines `ping!` functions in the strategy module `to_strat` (calling the macro) forwarding to
the `ping!` functions defined in the strategy module `from_strat`.
"""
macro forwardstrategy(from_mod, to_mod=__module__, exc=nothing, margin=nothing)
    if from_mod isa Symbol
        top_mod = tail_mod = from_mod
    elseif from_mod isa Expr
        top_mod, tail_mod = topmodule(from_mod)
    end
    use_expr = Expr(:using, Expr(:., :., _mod_syms(from_mod)...))
    @info "" from_mod top_mod tail_mod
    quote
        if isdefined($__module__, $(QuoteNode(top_mod)))
            $use_expr
        else
            using $top_mod
            $use_expr
        end
        let
            to_s_mod = @eval $__module__ $to_mod
            to_params = typeparameters(
                getproperty(to_s_mod, hasproperty(to_s_mod, :S) ? :S : :SC)
            )
            to_kwargs = NamedTuple(
                p => to_params[n] for
                (n, p) in enumerate((:M, :N, :E, :R, :C)) if typename(to_params[n]) != p
            )
            from_mod = getproperty($__module__, $(QuoteNode(tail_mod)))
            for met in methods(ping!, from_mod)
                pnames = String[x[1] for x in Base.arg_decl_parts(met)[2][2:end]]
                params = [typeparameters(met.sig)[2:end]...]
                params_exprs = Any[]
                replacestrat!(params; out=params_exprs) do tp
                    expr = strategytype(tp; mod=$(QuoteNode(from_mod)), to_kwargs...)
                    str = string(expr)
                    Meta.parse(str)
                end
                args, argnames = function_args_expr(pnames, params_exprs)
                tuple_types = Tuple{met.sig.parameters[2:end]...}
                @assert length(tuple_types.parameters) == length(args) == length(argnames)
                fdef = :(
                    function ping!($(args...); kwargs...)
                        @info "params types" $(Tuple{met.sig.parameters[2:end]...})
                        @info "params names" $(argnames)
                        @info "params args" $(args)
                        invoke(
                            ping!,
                            $(tuple_types),
                            $(argnames)...;
                            kwargs...,
                        )
                    end
                )
                Core.eval($__module__, fdef)
            end
        end
    end
end

export @forwardstrategy

end
