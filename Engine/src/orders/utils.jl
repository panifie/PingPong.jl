_takevol!(s) = @lget! s.config.attrs :max_take_vol 0.05
_takevol(s) = s.config.attrs[:max_take_vol]
Orders.ordersdefault!(s::Strategy{Sim}) = begin
    @assert 0 < _takevol!(s) <= 1
end
