module Lang

using Distributed: @distributed
using Logging: with_logger, NullLogger

macro evalmod(files...)
    quote
        with_logger(NullLogger()) do
            for f in $files
                eval(:(include(joinpath(@__DIR__, $f))))
            end
        end
    end
end

macro parallel(flag, body)
    b = esc(body)
    db = esc(:(@distributed $body))
    quote
        if $(esc(flag))
            $db
        else
            $b
        end
    end
end

passkwargs(args...) = [Expr(:kw, a.args[1], a.args[2]) for a in args]

macro passkwargs(args...)
    kwargs = [Expr(:kw, a.args[1], a.args[2]) for a in args]
    return esc(:($(kwargs...)))
end

export passkwargs, @passkwargs

macro lget!(dict, k, expr)
    dict = esc(dict)
    expr = esc(expr)
    k = esc(k)
    quote
        try
            $dict[$k]
        catch e
            if e isa KeyError
                v = $expr
                $dict[$k] = v
                v
            else
                rethrow(error)
            end
        end
    end
end

@doc "Define a new symbol with given value if it is not already defined."
macro ifundef(name, val, mod=__module__)
    name_var = esc(name)
    name_sym = esc(:(Symbol($(string(name)))))
    quote
        if isdefined($mod, $name_sym)
            $name_var = getproperty($mod, $name_sym)
        else
            $name_var = $val
        end
    end
end

@doc "Export all instances of an enum type."
macro exportenum(enums...)
    expr = quote end
    for enum in enums
        push!(
            expr.args,
            :(Core.eval(
                $__module__,
                Expr(:export, map(Symbol, instances($(esc(enum))))...),
            )),
        )
    end
    expr
end

@doc "Import all instances of an enum type."
macro importenum(T)
    ex = quote end
    mod = T.args[1]
    for val in instances(Core.eval(__module__, T))
        str = Meta.parse("import $mod.$val")
        ex = quote
            Core.eval($__module__, $str)
            $ex
        end
    end
    return ex
end

macro as(sym, val)
    s = esc(sym)
    v = esc(val)
    quote
        $s = $v
        true
    end
end

export @lget!, passkwargs, @exportenum, @as

end
