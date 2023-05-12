function orders(s::Strategy, ai, pos::PositionSide, os::Type{<:OrderSide})
    ((pt, o) for (pt, o) in orders(s, ai, os) if ispos(o, pos))
end
function orders(s::Strategy, ai, pos::PositionSide)
    ords = (orders(s, ai, pos, Buy), (orders(s, ai, pos, Sell)))
    (o for s in ords for o in s)
end
shortorders(s::Strategy, ai, os::Type{<:OrderSide}) = orders(s, ai, Short(), os)
longorders(s::Strategy, ai, os::Type{<:OrderSide}) = orders(s, ai, Long(), os)
function shortorder(s::Strategy, ai)
    (orders(s, ai, Short(), Sell)..., order(s, ai, Short(), Buy)...)
end
function longorders(s::Strategy, ai)
    (orders(s, ai, Long(), Buy)..., order(s, ai, Long(), Sell)...)
end

function hasorders(s::MarginStrategy, ai, ps::PositionSide, os::Type{<:OrderSide})
    for o in orders(s, ai, os)
        if orderpos(o) == ps
            return true
        end
    end
    return false
end
function hasorders(s::MarginStrategy, ai, ps::PositionSide)
    hasorders(s, ai, ps, Buy) || hasorders(s, ai, ps, Sell)
end
function hasorders(::MarginStrategy, ai, ::Long, ::Type{Sell})
    !iszero(committed(ai, Long()))
end
function hasorders(::MarginStrategy, ai, ::Short, ::Type{Buy})
    !iszero(committed(ai, Short()))
end

hasorders(s::Strategy, ai, p::Type{Long}) = !isempty(orders(s, ai, t))
hasorders(::Strategy, ai, ::Type{Short}) = committed(ai) != 0.0
hasorders(s::Strategy, ai) = hasorders(s, ai, Sell) || hasorders(s, ai, Buy)
