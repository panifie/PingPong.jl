using .ExchangeTypes: HOOKS

_load_time_diff(exc) = pyfetch(exc.load_time_difference)
_authenticate(exc) = pyfetch(exc.authenticate)

_doinit() = begin
    # bybit time tends to drift
    HOOKS[:bybit] = [_load_time_diff]
    HOOKS[:phemex] = [_authenticate]
end
