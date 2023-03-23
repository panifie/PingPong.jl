macro evalmod(files...)
    quote
        with_logger(NullLogger()) do
            for f in $files
                eval(:(include(joinpath(@__DIR__, $f))))
            end
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
function firsthead(expr::Expr, sym::Symbol)
    if sym == expr.head
        return expr
    end
    for arg in expr.args
        if isa(arg, Expr)
            e = firsthead(arg, sym)
            isnothing(e) || return e
        end
    end
    return nothing
end

@doc "Import all instances of an enum type."
macro importenum(stmt)
    ex = quote
        $stmt
    end
    @assert stmt.head ∈ (:import, :using)
    enums = firsthead(stmt, :(:))
    for e in enums.args
        push!(
            ex.args,
            quote
                for i in instances($e)
                    using i: i
                end
            end,
        )
    end
    # for val in instances(Core.eval(__module__, T))
    #     str = Meta.parse("import .$mod.$val")
    #     ex = quote
    #         Core.eval($__module__, $str)
    #         $ex
    #     end
    # end
    return stmt
end

# FIXME: untested
@doc "Unroll expression `exp` for every element in `fields` assign each element to symbol defined by `asn`.

`exp` must use the name defined by `asn`(default to `el`) as the variable name of the loop."
macro unroll(exp, fields, asn=:el)
    ex = esc(exp)
    Expr(:block, (:($(esc(asn)) = $el; $ex) for el in fields.args)...)
end
