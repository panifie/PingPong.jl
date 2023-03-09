
# TYPENUM
struct Stoploss2{T}
    loss::T
    loss_target::T
    trailing_loss::T
    trailing_loss_target::T
    trailing_offset::T
    function Stoploss2(loss, trailing_loss=NaN, trailing_offset=0.0)
        @assert loss > 0 "Stoploss below 0? How much do you plan to loose?"
        @assert loss < 1 "Stoploss must be within (0, 1) percentage range."
        new{eltype(loss)}(loss, 1 - loss, trailing_loss, 1 - trailing_loss, trailing_offset)
    end
end
Stoploss = Stoploss2

stopat(open , stop::Stoploss) = open * stop.target
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
