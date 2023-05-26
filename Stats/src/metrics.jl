using Statistics: std
using Base: negate

const DAYS_IN_YEAR = 365
const METRICS = Set((:sharpe, :sortino, :calmar, :expectancy, :cagr))

_returns_arr(arr) = begin
    n_series = length(arr)
    diff(arr) ./ view(arr, 1:(n_series - 1))
end

_annualize(v, tf) = v * sqrt(DAYS_IN_YEAR * period(tf) / period(tf"1d"))

function _rawsharpe(returns; rfr=0.0, tf=tf"1d")
    avg_returns = mean(returns)
    ratio = (avg_returns - rfr) / std(returns)
    _annualize(ratio, tf)
end

function sharpe(s::Strategy, tf=tf"1d", rfr=0.0)
    balance = trades_balance(s, tf).cum_total
    returns = _returns_arr(balance)
    _rawsharpe(returns; rfr, tf)
end

function _rawsortino(returns; rfr=0.0, tf=tf"1d")
    avg_returns = mean(returns)
    downside_idx = returns .< 0.0
    ratio = (avg_returns - rfr) / std(view(returns, downside_idx))
    _annualize(ratio, tf)
end

function sortino(s::Strategy, tf=tf"1d", rfr=0.0)
    balance = trades_balance(s, tf).cum_total
    returns = _returns_arr(balance)
    _rawsortino(returns; rfr, tf)
end

function _rawcalmar(returns; tf=tf"1d")
    max_drawdown = maxdd(returns)
    annual_returns = mean(returns) * DAYS_IN_YEAR
    negate(annual_returns) / max_drawdown
end

function maxdd(returns)
    cum_returns = cumprod(1.0 .+ returns)
    minimum(diff(cum_returns) ./ @view(cum_returns[1:(end - 1)]))
end

function calmar(s::Strategy, tf=tf"1d")
    balance = trades_balance(s, tf).cum_total
    returns = _returns_arr(balance)
    _rawcalmar(returns; tf)
end

function _rawexpectancy(returns)
    isempty(returns) && return 0.0

    ups_idx = returns .> 0.0
    ups = view(returns, ups_idx)
    isempty(ups) && return 0.0

    downs = view(returns, xor.(ups_idx, true))
    avg_up = mean(ups)
    avg_down = mean(abs.(downs))

    risk_reward_ratio = avg_up / avg_down
    up_rate = length(ups) / length(returns)

    return ((1.0 + risk_reward_ratio) * up_rate) - 1.0
end

function expectancy(s::Strategy, tf=tf"1d")
    _rawexpectancy(returns)
end

function cagr(
    s::Strategy,
    prd::Period=st.tradesperiod(s),
    initial=s.initial_cash,
    price_func=st.lasttrade_price_func,
)
    final = st.current_total(s, price_func)
    (final / initial)^inv(prd / Day(DAYS_IN_YEAR)) - 1.0
end

@doc "Returns a dict of the calculated `metrics` see `METRICS` for what's available."
function multi(s::Strategy, metrics::Vararg{Symbol}; tf=tf"1d")
    balance = trades_balance(s, tf).cum_total
    returns = _returns_arr(balance)
    Dict((m => if m == :sharpe
        _rawsharpe(returns)
    elseif m == :sortino
        _rawsortino(returns)
    elseif m == :calmar
        _rawcalmar(returns)
    elseif m == :expectancy
        _rawexpectancy(returns)
    elseif m == :cagr
        cagr(s)
    else
        error("$m is not a valid metric")
    end for m in metrics)...)
end

export sharpe, sortino, calmar, expectancy, cagr, multi
