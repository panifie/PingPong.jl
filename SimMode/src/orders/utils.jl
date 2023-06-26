_pricebyside(::AnyBuyOrder, date, ai) = st.lowat(ai, date)
_pricebyside(::AnySellOrder, date, ai) = st.highat(ai, date)

_simmode_defaults!(s, attrs) = begin
    attrs[:timeframe] = s.timeframe
    attrs[:sim_update_mode] = UpdateOrders()
    attrs[:sim_base_slippage] = Val(:spread)
    attrs[:sim_market_slippage] = Val(:skew)
    attrs[:sim_last_orders_update] = DateTime(0)
end

function OrderTypes.ordersdefault!(s::Strategy{Sim})
    _simmode_defaults!(s, s.attrs)
end
