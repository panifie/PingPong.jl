using Base: is_function_def
function functionname(ex)
    if ex isa Expr
        if ex.head == :function
            # Long form function definition
            if ex.args[1] isa Symbol
                return ex.args[1]
            elseif ex.args[1] isa Expr && ex.args[1].head == :call
                return ex.args[1].args[1]
            end
        elseif ex.head == :(=) && ex.args[1] isa Expr && ex.args[1].head == :call
            # Short form function definition
            return ex.args[1].args[1]
        elseif ex.head == :->
            # Closure syntax
            if ex.args[1] isa Symbol
                return ex.args[1]
            elseif ex.args[1] isa Expr && ex.args[1].head == :tuple
                return :closure # no function name for closures with multiple arguments
            end
        end
    end
    return nothing
end

function functionsig(ex)
    @assert ex.head == :function
    v = ex.args[1]
    @assert v.head == :call
    v
end

function functionbody(ex)
    @assert is_function_def(ex) && !is_short_function_def(ex)
    @assert ex.args[1].head == :call
    v = ex.args[2]
    @assert v.head == :block
    v
end

function functionbody!(ex, body)
    @assert is_function_def(ex) && !Base.is_short_function_def(ex)
    @assert ex.args[1].head == :call
    ex.args[2] = body
end

macro expr(e)
    esc(quote
        $(e,)[1]
    end)
end

@doc """ Overloads functions.

`expr`: A vector of expressions that define the overlayed functions
`code`: the expression to evaluate in the scope of the overlayed functions.

The function to be overlayed must have the original body as a redirect call to a function of similar name but prefixed with an underscore (`ThisModule.myfunc(args...) _myfunc(args...) end`)
"""
macro pass(expr, code)
    originals = []
    e = quote
        @assert $expr isa Vector{Expr}
        originals = []
        for e in $expr
            orig_e = deepcopy(e)
            redirect_body = let
                func_full_name = deepcopy(functionname(orig_e))
                func_name = func_full_name.args[end]
                @assert func_name isa QuoteNode "Make sure the replacement function definition is in the form `function \$MODULES.\$NAME(...) ... end"
                name_str = "_" * string(func_name.value)
                func_full_name.args[end] = QuoteNode(Symbol(name_str))
                params = orig_e.args[1].args[2:end]
                body = :($func_full_name($(params...)))
                Main.body = body
                functionbody!(orig_e, body)
                push!(originals, orig_e)
            end
            eval(:(@overlay nothing $(e)))
        end
        try
            this_func() = $code
            invokelatest(this_func)
        finally
            for e in originals
                eval(:(@overlay nothing $(e)))
            end
        end
    end
    esc(e)
end
