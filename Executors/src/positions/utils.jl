using .Instances: ispos
using .OrderTypes: ByPos

function orders(s::Strategy, ai, pos::PositionSide, os::Type{<:OrderSide})
    ((k, v) for (k, v) in orders(s, ai, os) if ispos(pos, v))
end
function orders(s::Strategy, ai, pos::PositionSide)
    ((k, v) for bs in (Buy, Sell) for (k, v) in orders(s, ai, pos, bs))
end
shortorders(s::Strategy, ai, os::Type{<:OrderSide}) = orders(s, ai, Short(), os)
longorders(s::Strategy, ai, os::Type{<:OrderSide}) = orders(s, ai, Long(), os)
function shortorders(s::Strategy, ai)
    (orders(s, ai, Short(), Sell)..., orders(s, ai, Short(), Buy)...)
end
function longorders(s::Strategy, ai)
    (orders(s, ai, Long(), Buy)..., orders(s, ai, Long(), Sell)...)
end

function _hasorders(s::MarginStrategy, ai, ps::PositionSide, os::Type{<:OrderSide})
    for o in values(orders(s, ai, os))
        if positionside(o)() == ps
            return true
        end
    end
    return false
end
function hasorders(s::MarginStrategy, ai, ps::PositionSide)
    _hasorders(s, ai, ps, Buy) || _hasorders(s, ai, ps, Sell)
end
function hasorders(s::MarginStrategy, ai, ::Long, t::Type{<:OrderSide})
    hasorders(s, ai, t)
end
function hasorders(s::MarginStrategy, ai, ::Long, ::Type{Sell})
    !iszero(committed(ai, Long())) || _hasorders(s, ai, Long(), Sell)
end
function hasorders(s::MarginStrategy, ai, ::Short, ::Type{Buy})
    !iszero(committed(ai, Short())) || _hasorders(s, ai, Short(), Buy)
end

function hasorders(s::MarginStrategy, ai, ::ByPos{Long})
    hasorders(s, ai, Long(), Buy) || hasorders(s, ai, Long(), Sell)
end
function hasorders(s::MarginStrategy, ai, ::ByPos{Short})
    !iszero(committed(ai, Short())) ||
        _hasorders(s, ai, Short(), Buy) ||
        _hasorders(s, ai, Short(), Sell)
end

function hasorders(s::MarginStrategy, ::ByPos{P}) where {P<:PositionSide}
    for ai in s.holdings
        _hasorders(s, ai, P(), Buy) && return true
        _hasorders(s, ai, P(), Sell) && return true
    end
    return false
end

function position!(s::IsolatedStrategy, ai, date::DateTime, p::PositionSide)
    position!(s, ai, date, position(ai, p))
end
position!(::IsolatedStrategy, ai, ::DateTime, ::Nothing) = nothing

@doc "Non margin strategies don't have positions."
position!(s::NoMarginStrategy, args...; kwargs...) = nothing
positions!(s::NoMarginStrategy, args...; kwargs...) = nothing

_commitside(::Long) = Sell
_commitside(::Short) = Buy
function committed(s::MarginStrategy, ai::MarginInstance, ::ByPos{P}) where {P}
    ans = zero(DFT)
    for o in values(s, ai, P(), _commitside(P()))
        ans += o.amount
    end
    ans
end
