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


function passkwargs(args...)
    return [Expr(:kw, a.args[1], a.args[2]) for a in args]
end

macro passkwargs(args...)
    kwargs = [Expr(:kw, a.args[1], a.args[2]) for a in args]
    return esc( :( $(kwargs...) ) )
end

export passkwargs, @passkwargs

macro lget!(dict, k, expr)
    quote
        try
            $dict[$k]
        catch error
            v = expr
            $dict[$k] = v
            v
        end
    end
end


@doc "Define a new symbol with given value if it is not already defined."
macro ifundef(name, val, mod = __module__)

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
