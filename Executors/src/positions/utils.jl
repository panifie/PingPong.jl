using Instances: ispos

function orders(s::Strategy, ai, pos::PositionSide, os::Type{<:OrderSide})
    ((k, v) for (k, v) in orders(s, ai, os) if ispos(pos, v))
end
function orders(s::Strategy, ai, pos::PositionSide)
    ((k, v) for bs in (Buy, Sell) for (k, v) in orders(s, ai, pos, bs))
end
shortorders(s::Strategy, ai, os::Type{<:OrderSide}) = orders(s, ai, Short(), os)
longorders(s::Strategy, ai, os::Type{<:OrderSide}) = orders(s, ai, Long(), os)
function shortorder(s::Strategy, ai)
    (orders(s, ai, Short(), Sell)..., order(s, ai, Short(), Buy)...)
end
function longorders(s::Strategy, ai)
    (orders(s, ai, Long(), Buy)..., order(s, ai, Long(), Sell)...)
end

function _hasorders(s::MarginStrategy, ai, ps::PositionSide, os::Type{<:OrderSide})
    for o in values(orders(s, ai, os))
        if orderpos(o)() == ps
            return true
        end
    end
    return false
end
function hasorders(s::MarginStrategy, ai, ps::PositionSide)
    _hasorders(s, ai, ps, Buy) || _hasorders(s, ai, ps, Sell)
end
function hasorders(s::MarginStrategy, ai, ::Long, ::Type{Sell})
    !iszero(committed(ai, Long())) || _hasorders(s, ai, Long(), Sell)
end
function hasorders(s::MarginStrategy, ai, ::Short, ::Type{Buy})
    !iszero(committed(ai, Short())) || _hasorders(s, ai, Short(), Buy)
end

function hasorders(s::MarginStrategy, ai, ::Type{Long})
    hasorders(s, ai, Long(), Buy) || hasorders(s, ai, Long(), Sell)
end
function hasorders(s::MarginStrategy, ai, ::Type{Short})
    !iszero(committed(ai, Short())) ||
        _hasorders(s, ai, Short(), Buy) ||
        _hasorders(s, ai, Short(), Sell)
end
