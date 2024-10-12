@doc "The price at a particular date for a buy order (default to low)."
_pricebyside(::AnyBuyOrder, date, ai) = st.lowat(ai, date)
@doc "The price at a particular date for a sell order (default to high)."
_pricebyside(::AnySellOrder, date, ai) = st.highat(ai, date)

@doc """ Sets default attributes for simulation mode.

$(TYPEDSIGNATURES)

This function sets default attributes for simulation mode in the strategy `s`. These attributes include timeframe, throttle, update mode, base slippage, market slippage, and last orders update.

"""
_simmode_defaults!(s, attrs) = begin
    attrs[:timeframe] = s.timeframe
    attrs[:throttle] = Second(5)
    attrs[:log_level] = Logging.Info
    attrs[:log_to_stdout] = true
    attrs[:sim_update_mode] = UpdateOrders()
    attrs[:sim_base_slippage] = Val(:spread)
    attrs[:sim_market_slippage] = Val(:skew)
    attrs[:sim_last_orders_update] = DateTime(0)
    attrs[:sim_debug] = false
end

@doc "Sets default attributes for simulation mode."
function st.default!(s::Strategy{Sim})
    _simmode_defaults!(s, s.attrs)
end

@doc """ Constructs a function for creating limit orders.

$(TYPEDSIGNATURES)

Given a type `t` that is a subtype of `Order` with `LimitOrderType`, this function returns a function for creating limit orders.
"""
function construct_order_func(t::Type{<:Union{<:Order{<:LimitOrderType},<:LimitOrderType}})
    create_sim_limit_order
end
construct_order_func(t) = begin
    @warn "Order type $t unknown, defaulting to sim limit order"
    create_sim_limit_order
end
@doc """ Constructs a function for creating market orders.

$(TYPEDSIGNATURES)

Given a type `t` that is a subtype of `Order` with `MarketOrderType`, this function returns a function for creating market orders.
"""
function construct_order_func(t::Type{<:Union{<:Order{<:MarketOrderType},<:MarketOrderType}})
    create_sim_market_order
end
