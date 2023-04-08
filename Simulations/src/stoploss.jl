
# TYPENUM
mutable struct Stoploss3{T}
    const minloss::T
    const maxloss::T
    loss::T
    loss_target::T
    trailing_loss::T
    trailing_loss_target::T
    trailing_offset::T
    function Stoploss3(
        loss::T, trailing_loss=NaN, trailing_offset=0.0; min=0.01, max=0.99
    ) where {T}
        loss = clamp(loss, min, max)
        trailing_loss = clamp(trailing_loss, min, max)
        trailing_offset = clamp(trailing_offset, min, max)
        new{T}(min, max, loss, 1 - loss, trailing_loss, 1 - trailing_loss, trailing_offset)
    end
end
Stoploss = Stoploss3

stop!(stop::Stoploss, loss) = begin
    loss = clamp(loss, stop.minloss, stop.maxloss)
    stop.loss = loss
    stop.loss_target = 1 - loss
end
trailing!(stop::Stoploss, loss) = begin
    loss = clamp(loss, stop.minloss, stop.maxloss)
    stop.trailing_loss = loss
    stop.trailing_loss_target = 1 - loss
end
function offset!(stop::Stoploss, ofs)
    stop.trailing_offset = clamp(ofs, stop.minloss, stop.maxloss)
end
stopat(open, stop::Stoploss) = open * stop.target
stopat(cdl::Candle, stop::Stoploss) = stoplossat(cdl.open, stop)

@doc "For stoploss to trigger, the low must be lower or equal the target price."
triggered(::Stoploss, cdl::Candle, price) = cdl.low <= price

function trailing_stop(stop::Stoploss, stop_price, high_price, high_profit)
    if stop.trailing_loss
        if !(isfinite(stop.trailing_offset) && high_profit < stop.trailing_offset)
            return max(
                # trailing only increases
                stop_price,
                # use positive ratio if above positive trailing_offset (default > 0) NOTE: strict > 0
                if isfinite(stop.trailing_loss) && high_profit > stop.trailing_offset
                    high_price * stop.trailing_loss_target
                    # otherwise trailing with stoploss ratio
                else
                    high_price * stop.loss_target
                end,
            )
        end
        return stop_price
    end
    return stop_price
end
