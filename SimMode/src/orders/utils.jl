_pricebyside(::BuyOrder, date, ai) = st.lowat(ai, date)
_pricebyside(::SellOrder, date, ai) = st.highat(ai, date)

OrderTypes.ordersdefault!(s::Strategy{Sim}) = begin
    s.attrs[:sim_update_mode] = UpdateOrders()
    s.attrs[:sim_base_slippage] = Val(:spread)
    s.attrs[:sim_market_slippage] = Val(:skew)
    s.attrs[:sim_last_orders_update] = DateTime(0)
end
