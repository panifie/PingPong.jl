using PaperMode.SimMode: _lev_value, leverage!, leverage
using .Executors: hasorders
using .st: exchange
using Instances: raw
import Executors: pong!

function Executors.pong!(
    s::MarginStrategy{Live}, ai::MarginInstance, lev, ::UpdateLeverage; pos::PositionSide
)
    if isopen(ai, pos) || hasorders(s, ai, pos)
        false
    else
        val = _lev_value(lev)
        # First update on exchange, then update local struct
        leverage!(exchange(ai), val, raw(ai)) && leverage!(ai, val, pos)
        @deassert isapprox(leverage(ai, pos), val, atol=1e-1) (leverage(ai, pos), lev)
        true
    end
end
