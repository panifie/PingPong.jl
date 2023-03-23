using Engine: Strategies as st
using Instruments

@doc "Plots the trades history of an asset instance, and its profits."
function plot_trades(s::Strategy, aa)
    ai = s.universe[aa, :instance, 1]
    fig = plot_ohlcv(ai.ohlcv)
end


export plot_trades
