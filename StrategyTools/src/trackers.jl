## PNL

function getpnl(s, ai)
    attr(s, :pnl)[ai]
end

@doc """
Records the profit and loss (PnL) for a given asset instance at a specific timestamp.

$(TYPEDSIGNATURES)

The PnL is calculated based on the position side and the closing price at the given timestamp.
"""
function trackpnl!(s, ai, ats, ts; interval=10s.timeframe, pnl_func=inst.pnlpct)
    pside = posside(ai)
    pnl = s[:pnl][ai]
    pnl_ts = pnl[1][]
    if pnl_ts < ats
        if !isnothing(pside)
            @deassert isopen(ai)
            close = closeat(ai, ats)
            pnl[1][] = ats
            oti.fit!(pnl[2], pnl_func(ai, pside, close))
        elseif pnl_ts < ats - interval
            pnl[1][] = ats
            oti.fit!(pnl[2], 0.0)
        end
    end
end

@doc """
Initializes the PnL tracking structure for each asset in the universe.

$(TYPEDSIGNATURES)

Sets up a `LittleDict` with a circular buffer to store PnL data, defaulting to 100 entries.
"""
function initpnl!(s, uni=s.universe; n=100, ma=oti.SMA{DFT})
    s[:pnl] = LittleDict(ai => (Ref(DateTime(0)), ma(period=n)) for ai in uni)
end

@doc """
Copies simulated PnL data to the main strategy instance.

$(TYPEDSIGNATURES)

Transfers PnL data from a simulation instance to the corresponding asset in the main strategy and marks the asset as warmed up.
"""
function copypnl!(s, ai, s_sim, ai_sim)
    sim_pnl = get(s_sim[:pnl], ai_sim, missing)
    if !ismissing(sim_pnl)
        this_pnl = s[:pnl][ai]
        this_pnl[1][] = sim_pnl[1][]
        oti.fit!(this_pnl[2], sim_pnl[2].input_values.value)
        s[:warmup][ai] = true
    end
end

## LEV

function initlev!(s)
    lev = get!(s.attrs, :def_lev, 1.0)
    s[:lev] = LittleDict(
        ai => (time=DateTime(0), raw_val=lev, value=lev) for ai in s.universe
    )
end

levtuple(s, ai) = s[:lev][ai]
getlev(s, ai) = levtuple(s, ai).value
function iszerolev(s, ai, ts; timeout=Day(1))
    tup = levtuple(s, ai)
    iszero(tup.value) && ts < tup.time + timeout
end

function default_dampener(v)
    if zero(v) <= v <= 2.0one(v)
        v
    elseif v > 2.0one(v)
        log2(v) + one(v)
    else
        zero(v)
    end
end

@doc """
Adjusts the leverage for an asset based on the Kelly criterion.

$(TYPEDSIGNATURES)

Applies a damping function to the raw Kelly leverage to ensure it remains within practical limits.
"""
function tracklev!(s, ai, ats; dampener=default_dampener)
    pnl_ats, pnl = getpnl(s, ai)
    this_lev = levtuple(s, ai)
    if this_lev.time < ats
        μ = @coalesce pnl.value 0.0
        vals = pnl.input_values.value
        s2 = ((vals .- μ) .^ 2 |> sum) / (length(vals) - 1)
        k = μ / s2
        raw_val, value = if isnan(k)
            def = s[:def_lev]
            def, def
        elseif k <= 0.0
            0.0, 0.0
        else
            k, clamp(dampener(k), 1.0, 100.0)
        end
        s[:lev][ai] = (; time=pnl_ats[], raw_val, value)
    end
end

## QT

function _normat(s, ai, ats; mn, mx, f=volumeat)
    (f(s, ai, ats) - mn) / (mx - mn)
end

function _volumeat(_, ai, ats)
    data = ohlcv(ai)
    idx = dateindex(data, ats)
    if idx > 0
        data.volume[idx]
    else
        0.0
    end
end

function _qtvolumeat(_, ai, ats)
    data = ohlcv(ai)
    idx = dateindex(data, ats)
    if idx > 0
        data.volume[idx] * data.close[idx]
    else
        0.0
    end
end

function initqt!(s)
    attrs = s.attrs
    let v = inv(length(marketsid(s)))
        attrs[:qt] = LittleDict(ai => v for ai in s.universe)
    end
    n_markets = length(marketsid(s))
    attrs[:qt_ext] = [now(), 0.0, 0.0]
    attrs[:qt_base] = inv(n_markets)
    attrs[:qt_multi] = 1.96
end

@doc """
Tracks the target quantity of an asset over time for trading strategy `s`.

$(TYPEDSIGNATURES)

The quantity is determined by the function `f` and is adjusted based on the asset `ai` and timestamp `ats`.
"""
function trackqt!(s, ai, ats; f=_qtvolumeat)
    local mn, mx
    ex = s[:qt_ext]
    if ex[1] == ats
        mn, mx = ex[2], ex[3]
    else
        ex[1] = ats
        mn, mx = extrema(f(s, ai, ats) for ai in s.universe)
        ex[2] = mn
        ex[3] = mx
    end
    v = _normat(s, ai, ats; mn, mx, f)
    s[:qt][ai] = if isfinite(v)
        v
    else
        max(0.0, s[:qt_base])
    end
end

## EXPECTANCY

@doc """
Calculates the win rate and profit/loss thresholds for a trading strategy.

$(TYPEDSIGNATURES)

Updates `s[:profit_thresh]` and `s[:loss_thresh]` based on the trading results.

"""
function track_expectancy!(s, ai)
    _, pnl = getpnl(s, ai)
    n_wins = 0
    tot_wins = 0.0
    n_losses = 0
    tot_losses = 0.0
    foreach(pnl) do v
        if v > 0.0
            n_wins += 1
            tot_wins += v
        else
            n_losses += 1
            tot_losses += v
        end
    end
    if n_wins > 0
        wr = n_wins / length(pnl)
        profit_thresh = wr * (tot_wins / n_wins)
        s[:profit_thresh] = profit_thresh
    end
    if n_losses > 0
        lr = n_losses / length(pnl)
        loss_thresh = lr * (tot_losses / n_losses)
        s[:loss_thresh] = loss_thresh
    end
end

function initcd!(s)
    s.attrs[:cooldown_unit] = Minute(1)
    s.attrs[:cooldown_max] = Minute(1440)
    s.attrs[:cooldown_base] = 0.006
    s.attrs[:cd] = LittleDict(ai => DateTime(0) for ai in s.universe)
end

## CD

@doc """
Calculates the cooldown period based on the profit and loss values.

$(TYPEDSIGNATURES)

This function calculates the cooldown period (`cd`) using the profit and loss (`pnl`) values, the cooldown unit (`cdu`), and the strategy's `cooldown_base`.

"""
function cdfrompnl(s, pnl, cdu::T=s[:cooldown_unit]) where {T}
    iszero(pnl) && return T(0)
    cd = round(UInt, cdu.value * s[:cooldown_base] / abs(pnl))
    cd_val = convert(Int, min(cd, typemax(Int)))
    min(Minute(cd_val), s[:cooldown_max]::Period)
end

@doc """
Updates the cooldown period for an asset instance in the strategy.

$(TYPEDSIGNATURES)

The function calculates the cooldown period for the asset instance `ai` in the strategy `s` at the current timestamp `ts`.
"""
function trackcd!(s, ai, ats, ts)
    _, pnl = getpnl(s, ai)
    mean_pnl = mean(pnl)
    s[:cd][ai] = ts + s.self.cdfrompnl(s, mean_pnl)
end

function isidle(s, ai, ats, ts)
    ts < s[:cd][ai]
end

## TRENDS

struct Trend{T} end
const Up = Trend{:Up}()
const Down = Trend{:Down}()
const Stationary = Trend{:Stationary}()
const MissingTrend = Trend{missing}()

function inittrends!(s, trends)
    attrs = s.attrs
    for k in trends
        @lget! attrs k LittleDict{AssetInstance,Trend}(
            ai => MissingTrend for ai in s.universe
        )
    end
end

isuptrend(s, ai, sig_name) = signal_trend(s, ai, sig_name) === Up
isdowntrend(s, ai, sig_name) = signal_trend(s, ai, sig_name) === Down
ismissing_trend(s, ai, sig_name) = signal_trend(s, ai, sig_name) === MissingTrend
isstationary(s, ai, sig_name) = signal_trend(s, ai, sig_name) === MissingTrend
cmptrend(::Any; sig, idx, ov) = begin
    if iszero(idx) || ismissing(sig.state.value)
        sig.trend = MissingTrend
        false
    else
        close = ov.close[idx]
        ans = false
        sig.trend = if close > sig.state.value
            ans = true
            Up
        elseif close == sig.state.value
            ans = false
            Stationary
        else
            ans = true
            Down
        end
        ans
    end
end
@doc """
Compares two properties of a signal state.

$(TYPEDSIGNATURES)
"""
cmpab(sig, a, b) = begin
    val = sig.state.value
    if ismissing(val)
        false
    else
        a_val = getproperty(val, a)
        b_val = getproperty(val, b)
        if ismissing(a_val) || ismissing(b_val)
            false
        else
            sig.trend = if a_val > b_val
                Up
            elseif a_val < b_val
                Down
            else
                Stationary
            end
            true
        end
    end
end

@doc """
Calculates the rate of change of a property of a signal state.

$(TYPEDSIGNATURES)
"""
rateab(sig, a, b) = begin
    val = sig.state.value
    if ismissing(val)
        1.0, 1.0
    else
        a = getproperty(val, a)
        b = getproperty(val, b)
        if ismissing(a) || ismissing(b)
            1.0, 1.0
        else
            a / b, b / a
        end
    end
end

@doc """
Check if an asset is trending for a given signal

$(TYPEDSIGNATURES)

Checks if the asset `ai` is trending at time `ats` for the signal `sig_name` in the strategy `s`.
The trending condition is determined by the provided `func::Function` which has the signature:

    func(::SignalState, ::Int, ::DataFrame)::Bool
"""
function istrending!(s::Strategy, ai::AssetInstance, ats::DateTime, sig_name; func=cmptrend)
    ov = ohlcv(ai, signal_timeframe(s, sig_name))
    sig = strategy_signal(s, ai, sig_name)
    idx = dateindex(ov, ats)
    func(sig.state; sig, idx, ov)
end

## SLOPE
#
# function initslope!(s)
#     s[:slope] = LittleDict(ai => (; time=Ref(DateTime(0)),
#         value=LinReg()) for ai in s.universe)
# end
# slope!(attrs, ai, ats) = begin
#     data = ohlcv(ai)
#     date, os = attrs[:slope][ai]
#     tf = attrs[:timeframe]
#     window = attrs[:slope_window]
#     from_date = max(ats - tf * (window - 1), firstdate(data))

#     idx_start = dateindex(data, from_date)
#     idx_stop = dateindex(data, ats)
#     close = @view data.close[idx_start:idx_stop]

#     @deassert length(close) <= attrs[:slope_window] (length(close), idx_start, idx_stop, date[])
#     if length(close) > 0
#         fill!(os.A, zero(eltype(os.A))) # reset
#         oti.fit!(os, ((((v,), n) for (n, v) in enumerate(close))...,))
#         date[] = ats
#     end
# end
