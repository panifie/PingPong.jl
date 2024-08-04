using .Instances: ispos
using .OrderTypes: ByPos
using .Lang: @caller

@doc """ Returns a generator for orders matching a given position side and order side

$(TYPEDSIGNATURES)

This function iterates over the orders of a strategy, returning only those that match the provided position side and order side.

"""
orders(s::Strategy, ai, pos::PositionSide, os::Type{<:OrderSide})
function orders(s::Strategy, ai, pos::PositionSide, os::Type{<:OrderSide})
    (tup for tup in orders(s, ai, os) if ispos(pos, tup.second))
end
function orders(s::Strategy, ai, pos::PositionSide)
    (tup for bs in (Buy, Sell) for tup in orders(s, ai, pos, bs))
end
@doc """ Returns a generator for orders matching a given position side

$(TYPEDSIGNATURES)

This function iterates over the orders of a strategy for both Buy and Sell sides, returning those that match the provided position side.

"""
orders(s::Strategy, ai, pos::PositionSide)
@doc """ Returns a generator for short orders matching a given order side

$(TYPEDSIGNATURES)

This function utilizes the orders function to generate orders for the Short position side that match the provided order side.

"""
shortorders(s::Strategy, ai, os::Type{<:OrderSide}) = orders(s, ai, Short(), os)
@doc """ Returns a generator for long orders matching a given order side

$(TYPEDSIGNATURES)

This function utilizes the orders function to generate orders for the Long position side that match the provided order side.

"""
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
@doc """ Checks if there are any orders for a given position side

$(TYPEDSIGNATURES)

This function checks both Buy and Sell sides for any orders that match the provided position side in the Margin Strategy.

"""
function hasorders(s::MarginStrategy, ai, ps::PositionSide)
    _hasorders(s, ai, ps, Buy) || _hasorders(s, ai, ps, Sell)
end
function hasorders(s::MarginStrategy, ai, ::Long, t::Type{<:OrderSide})
    hasorders(s, ai, t)
end
function hasorders(s::MarginStrategy, ai, ::Long, ::Type{Sell})
    _hasorders(s, ai, Long(), Sell)
end
function hasorders(s::MarginStrategy, ai, ::Short, ::Type{Buy})
    _hasorders(s, ai, Short(), Buy)
end

# NOTE: ByPos has higher priority than BySide for dispatching
@assert !hasmethod(hasorders, Tuple{MarginStrategy, AssetInstance, BySide})
function hasorders(s::MarginStrategy, ai, ::ByPos{Long})
    hasorders(s, ai, Long(), Buy) || hasorders(s, ai, Long(), Sell)
end
function hasorders(s::MarginStrategy, ai, ::ByPos{Short})
    _hasorders(s, ai, Short(), Buy) || _hasorders(s, ai, Short(), Sell)
end

function hasorders(s::MarginStrategy, ::ByPos{P}) where {P<:PositionSide}
    for ai in s.holdings
        _hasorders(s, ai, P(), Buy) && return true
        _hasorders(s, ai, P(), Sell) && return true
    end
    return false
end

function hasorders(s::MarginStrategy, ::ByPos{P}, ::Val{:universe}) where {P<:PositionSide}
    for ai in universe(s)
        _hasorders(s, ai, P(), Buy) && return true
        _hasorders(s, ai, P(), Sell) && return true
    end
    return false
end
@doc """ Updates the position of the isolated strategy to the given position side at the specified date

$(TYPEDSIGNATURES)

This function updates the position of the strategy for the asset in question at the given date to the provided position side.

"""
function position!(s::IsolatedStrategy, ai, date::DateTime, p::PositionSide)
    position!(s, ai, date, position(ai, p))
end
position!(::IsolatedStrategy, ai, ::DateTime, ::Nothing) = nothing

position!(s::Strategy, args...) = @warn "`position!` not implemented for $(typeof(s))" @caller

@doc "Non margin strategies don't have positions."
position!(s::NoMarginStrategy, args...; kwargs...) = nothing
positions!(s::NoMarginStrategy, args...; kwargs...) = nothing

_commitside(::Long) = Sell
_commitside(::Short) = Buy
@doc """ Calculates the committed amount for a given position

$(TYPEDSIGNATURES)

This function sums the amounts of all the orders that match the given position in the Margin Strategy.

"""
function committed(s::MarginStrategy, ai::MarginInstance, ::ByPos{P}) where {P}
    ans = zero(DFT)
    for o in values(s, ai, P(), _commitside(P()))
        ans += o.amount
    end
    ans
end
