_pricebyside(::AnyBuyOrder, date, ai) = st.lowat(ai, date)
_pricebyside(::AnySellOrder, date, ai) = st.highat(ai, date)

_simmode_defaults!(s, attrs) = begin
    attrs[:timeframe] = s.timeframe
    attrs[:throttle] = Second(5)
    attrs[:sim_update_mode] = UpdateOrders()
    attrs[:sim_base_slippage] = Val(:spread)
    attrs[:sim_market_slippage] = Val(:skew)
    attrs[:sim_last_orders_update] = DateTime(0)
    reset!(s)
end

function st.default!(s::Strategy{Sim})
    _simmode_defaults!(s, s.attrs)
end

function construct_order_func(t::Type{<:Union{<:Order{<:LimitOrderType},<:LimitOrderType}})
    create_sim_limit_order
end
construct_order_func(t) = begin
    @warn "Order type $t unknown, defaulting to sim limit order"
    create_sim_limit_order
end
function construct_order_func(t::Type{<:Union{<:Order{<:MarketOrderType},<:MarketOrderType}})
    create_sim_market_order
end
