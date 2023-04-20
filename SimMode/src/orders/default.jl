OrderTypes.ordersdefault!(s::Strategy{Sim}) = begin
    s.attrs[:sim_base_slippage] = Val(:spread)
    s.attrs[:sim_last_orders_update] = DateTime(0)
end
