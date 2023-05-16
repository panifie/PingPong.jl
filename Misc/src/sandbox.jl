module Sandbox
@doc "A more restrictive eval."
safereval(s::String) = eval(
    let s = split(s) |> first, p = Meta.parse(s)
        if p isa Symbol
            p
        elseif p isa Number
            p
        elseif p.head == :(.)
            p
        else
            error("Expression not allowed. $s")
        end
    end,
)
export safereval
end
