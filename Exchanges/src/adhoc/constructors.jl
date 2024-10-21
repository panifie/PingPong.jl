using .ExchangeTypes: HOOKS
using .Python: pycopy!, pyexec, pyimport

_load_time_diff(exc) = pyfetch(exc.load_time_difference)

_doinit() = begin
    # bybit time tends to drift
    HOOKS[:bybit] = [_load_time_diff]
    HOOKS[:phemex] = [_override_phemex]
end

_authenticate!(exc::Exchange{ExchangeID{:phemex}}) = nothing # pyfetch(exc.authenticate)

function _override_phemex(exc::Exchange{ExchangeID{:phemex}})
    code = """
       import ccxt
       from juliacall import Main
       push = getattr(Main, 'push!')
       class phemex_override(ccxt.pro.phemex):
           def handle_message(self, client, message):
               if 'positions_p' in message:
                   push(self._positions_messages, message['positions_p'])
               super().handle_message(client, message)
       """
    globs = pydict()
    cls = pyexec(NamedTuple{(:phemex_override,),Tuple{Py}}, code, globs).phemex_override
    this_py = cls(exc.params)
    cls._positions_messages = Any[]
    pycopy!(exc.py, this_py)
end
