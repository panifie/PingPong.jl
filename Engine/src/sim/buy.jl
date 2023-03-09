
# """ Should only be called when cash is available """
# function buyat(i, c, ctx, trades::Dict{Symbol, Trade})
#     if trades[c].status == 1
#         # buys and sell must not conflict
#         if ctx.buys[i, c] && (!ctx.sells[i, c])
#             # index of bought, which is at start of next candle
#             bi = i + 1
#             # create trade for column
#             ctx.cash_now -= trades[c].open(
#                 open_idx=bi,
#                 # price is open of next candle
#                 open_price=ctx.open[bi, c],
#                 # respect the minimum order size, buy if min_bv > cash_now, the order will fail
#                 cash=ctx.amount[i, c],
#                 cash_now=ctx.cash_now,
#                 min_cash=ctx.min_bv,
#                 fees=ctx.fees,
#                 slp=slippage(bi, c, ctx.slippage, ctx.slp_window),
#                 prob=ctx.probs[0],
#                 stoploss=ctx.stop_config.stoploss,
#             )
#             # if trades[c].status == 0:
#             #     print("created trade: ", i, ctx.pairs[c])
#         # always return true even if trade fails, because:
#         # don't need to check sells if trade is closed (== there was no trade)
#         # the trade is opened on the next candle, not the one with the signal
#         return true
#         end
#     return false
#     end
# end
