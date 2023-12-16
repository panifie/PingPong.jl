# TYPENUM
@doc """ A mutable struct representing a stop loss strategy in trading.

$(FIELDS)

It contains fields for minimum loss, maximum loss, current loss, loss target, trailing loss, trailing loss target, and trailing offset.
The struct is parameterized by a type `T` which is the type of these fields.
The `Stoploss3` constructor ensures that the loss, trailing loss, and trailing offset are clamped between the minimum and maximum loss values.
"""
Stoploss3
mutable struct Stoploss3{T}
    const minloss::T
    const maxloss::T
    loss::T
    loss_target::T
    trailing_loss::T
    trailing_loss_target::T
    trailing_offset::T
    @doc """A mutable struct representing a stop loss strategy in trading.

    $(TYPEDSIGNATURES)

    Contains fields for minimum loss, maximum loss, current loss, loss target, trailing loss, trailing loss target, and trailing offset.

    """
    function Stoploss3(
        loss::T, trailing_loss=NaN, trailing_offset=0.0; min=0.001, max=0.99
    ) where {T}
        loss = clamp(loss, min, max)
        trailing_loss = clamp(trailing_loss, min, max)
        trailing_offset = clamp(trailing_offset, min, max)
        new{T}(min, max, loss, 1 - loss, trailing_loss, 1 - trailing_loss, trailing_offset)
    end
end
Stoploss = Stoploss3

@doc """ Updates the loss and loss target of a `Stoploss` instance.

$(TYPEDSIGNATURES)

The `stoploss!` function takes a `Stoploss` instance and a loss value as arguments.
It clamps the loss value between the minimum and maximum loss of the `Stoploss` instance.
Then, it updates the loss and loss target of the `Stoploss` instance with the clamped loss and its complement to 1, respectively.
"""
stoploss!(stop::Stoploss, loss) = begin
    loss = clamp(loss, stop.minloss, stop.maxloss)
    stop.loss = loss
    stop.loss_target = 1 - loss
end
@doc """A function that applies a trailing stop loss strategy to a given `Stoploss` object.

$(TYPEDSIGNATURES)

The function clamps the `loss` value between the `minloss` and `maxloss` values of the `Stoploss` object. 
Then it updates the `trailing_loss` and `trailing_loss_target` fields accordingly.

"""
trailing!(stop::Stoploss, loss) = begin
    loss = clamp(loss, stop.minloss, stop.maxloss)
    stop.trailing_loss = loss
    stop.trailing_loss_target = 1 - loss
end
@doc """ Adjusts the trailing offset of a `Stoploss` instance.

$(TYPEDSIGNATURES)

The `offset!` function takes a `Stoploss` instance and an offset value as arguments.
It clamps the offset value between the minimum and maximum loss of the `Stoploss` instance.
Then, it updates the trailing offset of the `Stoploss` instance with the clamped offset value.
"""
function offset!(stop::Stoploss, ofs)
    stop.trailing_offset = clamp(ofs, stop.minloss, stop.maxloss)
end
@doc """Computes the stop price based on the given `open` price and `Stoploss` instance target.

$(TYPEDSIGNATURES)

"""
stopat(open, stop::Stoploss) = open * stop.loss_target
@doc """Computes the stop price based on the given `Candle` open price and `Stoploss` instance.

$(TYPEDSIGNATURES)

"""
stopat(cdl::Candle, stop::Stoploss) = stopat(cdl.open, stop)

@doc """For stoploss to trigger, the low must be lower or equal the target price.

$(TYPEDSIGNATURES)
"""
triggered(::Stoploss, cdl::Candle, price) = cdl.low <= price
triggered(cdl::Candle, price) = cdl.low <= price

@doc """Computes the stop price based on the given `Stoploss` instance and other parameters.

$(TYPEDSIGNATURES)

This function calculates the stop price based on the provided `Stoploss` instance, `stop_price`, `high_price`, and `high_profit`. It first checks if `stop.trailing_loss` is true. If it is, it further checks if `stop.trailing_offset` is finite and `high_profit` is less than `stop.trailing_offset`. If this condition is true, it returns the maximum value between `stop_price` and the product of `high_price` and `stop.trailing_loss_target`. Otherwise, it returns the product of `high_price` and `stop.loss_target`. If `stop.trailing_loss` is false, it simply returns `stop_price`.

"""
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
