using Statistics: std
using Base: negate
using .st: trades_count

const DAYS_IN_YEAR = 365
const METRICS = Set((:total, :sharpe, :sortino, :calmar, :drawdown, :expectancy, :cagr, :trades))

macro balance_arr()
    s = esc(:s)
    tf = esc(:tf)
    quote
        $(esc(:balance)) = let balance_df = trades_balance($s, $tf)
            isnothing(balance_df) && return -Inf
            balance_df.cum_total
        end
    end
end

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
    @balance_arr
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
    @balance_arr
    returns = _returns_arr(balance)
    _rawsortino(returns; rfr, tf)
end

function _rawcalmar(returns; tf=tf"1d")
    max_drawdown = maxdd(returns)
    annual_returns = mean(returns) * DAYS_IN_YEAR
    negate(annual_returns) / max_drawdown
end

function maxdd(returns)
    length(returns) == 1 && return zero(DFT)
    cum_returns = cumprod(1.0 .+ returns)
    minimum(diff(cum_returns) ./ @view(cum_returns[1:(end - 1)]))
end

function calmar(s::Strategy, tf=tf"1d")
    @balance_arr
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
function multi(
    s::Strategy, metrics::Vararg{Symbol}; tf=tf"1d", normalize=false, norm_max=(;)
)
    balance = let df = trades_balance(s, tf)
        isnothing(df) &&
            return Dict(m => ifelse(normalize, 0.0, typemin(DFT)) for m in metrics)
        df.cum_total
    end
    returns = _returns_arr(balance)
    if isempty(returns)
        return [zero(DFT) for _ in metrics]
    end
    maybenorm = normalize ? normalize_metric : (x, _...) -> x
    Dict((m => let v = if m == :sharpe
            _rawsharpe(returns)
        elseif m == :sortino
            _rawsortino(returns)
        elseif m == :calmar
            _rawcalmar(returns)
        elseif m == :drawdown
            maxdd(returns)
        elseif m == :expectancy
            _rawexpectancy(returns)
        elseif m == :cagr
            cagr(s)
        elseif m == :total
            balance[end]
        elseif m == :trades
            trades_count(s, Val(:liquidations))[1]
        else
            error("$m is not a valid metric")
        end
        norm_args = if m in norm_max
            (norm_max[m],)
        else
            ()
        end
        maybenorm(v, Val(m), norm_args...)
    end for m in metrics)...)
end

_zeronan(v) = ifelse(isnan(v), 0.0, v)
_clamp_metric(v, max) = clamp(_zeronan(v / max), zero(v), one(v))
normalize_metric(v, ::Val{:total}, max=1e6) = _clamp_metric(v, max)
normalize_metric(v, ::Val{:drawdown}, max=1e6) = _clamp_metric(v, max)
normalize_metric(v, ::Val{:sharpe}, max=1e1) = _clamp_metric(v, max)
normalize_metric(v, ::Val{:sortino}, max=1e1) = _clamp_metric(v, max)
normalize_metric(v, ::Val{:calmar}, max=1e1) = _clamp_metric(v, max)
normalize_metric(v, ::Val{:expectancy}) = v
normalize_metric(v, ::Val{:cagr}, max=1e2) = _clamp_metric(v, max)
normalize_metric(v, ::Val{:trades}, max=1e6) = _clamp_metric(v, max)

export sharpe, sortino, calmar, expectancy, cagr, multi
