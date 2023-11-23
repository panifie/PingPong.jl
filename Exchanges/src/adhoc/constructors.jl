using .ExchangeTypes: HOOKS

_load_time_diff(exc) = pyfetch(exc.load_time_difference)

__init__() = begin
    # bybit time tends to drift
    HOOKS[:bybit] = [_load_time_diff]
end
