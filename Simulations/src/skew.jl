
function skewed_spread(high, low, close, volume, wnd, ofs)
    spread = spread(high, low, close)
    # min max liquidity statistics over a rolling window to use for interpolation
    liq = calc_liquidity(volume, close, high, low)
    lix_norm = rolling_norm(liq, wnd, ofs)
end
