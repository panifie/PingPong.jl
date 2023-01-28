
function calcprofits(openrate::{<:Real}, closerate, amount, fee; decimals=8)
    round((((amount / openrate) * closerate) - ((amount / openrate) * closerate) * fee) /
    (((amount / openrate) * openrate) + ((amount / openrate) * openrate) * fee) - 1.0)
end
