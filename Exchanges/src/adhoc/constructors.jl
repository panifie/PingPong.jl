using .ExchangeTypes: HOOKS

_load_time_diff(exc) = pyfetch(exc.load_time_difference)

__init__() = begin
    HOOKS[:bybit] = [_load_time_diff]
end
