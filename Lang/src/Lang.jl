module Lang

using Distributed: @distributed
using Logging: with_logger, NullLogger

const Option{T} = Union{Nothing,T} where {T}

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

@doc "Use hits for *initialization* type of key misses, that only happen once, otherwise use `@kget!`."
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
                rethrow(e)
            end
        end
    end
end

@doc "Use this in loops instead of `@lget!`"
macro kget!(dict, k, expr)
    dict = esc(dict)
    expr = esc(expr)
    k = esc(k)
    quote
        if haskey($dict, $k)
            $dict[$k]
        else
            v = $expr
            $dict[$k] = v
            v
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
                $__module__, Expr(:export, map(Symbol, instances($(esc(enum))))...)
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

# FIXME: untested
@doc "Unroll expression `exp` for every element in `fields` assign each element to symbol defined by `asn`.

`exp` must use the name defined by `asn`(default to `el`) as the variable name of the loop."
macro unroll(exp, fields, asn=:el)
    ex = esc(exp)
    Expr(:block, (:($(esc(asn)) = $el; $ex) for el in fields.args)...)
end

macro evalarg(arg)
    # s = eval(arg)
    @show @eval $__module__.$arg
    quote
        # mod = $__module__
        # eval($mod,  Base.Meta.parse("$mod." * $(string(esc(arg)))))
    end
end

@doc "Define `@fromdict` locally, to avoid precompilation side effects."
macro define_fromdict!(force=false)
    quote
        (isdefined($(__module__), Symbol("@fromdict")) && !$force) || @eval begin
            @doc "This macro tries to fill a _known_ `NamedTuple` from an _unknown_ `Dict`."
            macro fromdict(nt_type, key_type, dict_var)
                ttype = eval( Base.Meta.parse("$__module__.$nt_type"))
                ktype = eval( Base.Meta.parse("$__module__.$key_type"))
                @assert ttype <: NamedTuple "First arg must be a namedtuple type."
                @assert ktype isa Type "Second arg must be the type of the dict keys."
                @assert applicable(ktype, Symbol()) "Can't convert symbols to $ktype."
                params = Expr(:parameters)
                ex = Expr(:tuple, params)
                for (fi, ty) in zip(fieldnames(ttype), fieldtypes(ttype))
                    p = Expr(:kw, fi, :(convert($(ty), $(esc(dict_var))[$(convert(ktype, fi))])))
                    push!(params.args, p)
                end
                ex
            end
        end
    end
end

@doc "Same as `@fromdict` but as a generated function."
@generated fromdict(tuple, key, di, kconvfunc=convert, convfunc=convert) = begin
    params = Expr(:parameters)
    ex = Expr(:tuple, params)
    ttype = first(tuple.parameters)
    ktype = isempty(key.parameters) ? key : first(key.parameters)
    for (fi, ty) in zip(fieldnames(ttype), fieldtypes(ttype))
        p = Expr(:kw, fi, :(convfunc($ty, (di[kconvfunc($ktype, $(QuoteNode(fi)))]))))
        push!(params.args, p)
    end
    ex
end

macro sym_str(s)
    :(Symbol($s))
end

export @lget!, passkwargs, @exportenum, @as, Option, @sym_str

end
