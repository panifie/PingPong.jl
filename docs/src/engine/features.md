# Strategy Combination

The types considered for possible combinations are:

- `NoMargin,Isolated,Cross`: These types are considered if the strategy trades on derivatives markets.
- `Hedged,NotHedged`: These types are considered for positions management, determining whether it is one-way or both.

|          | Hedged | NotHedged |
| -------- | ------ | --------- |
| NoMargin |        | X         |
| Isolated | -      | X         |
| Cross    | -      | -         |

Currently, the bot supports trading on spot markets, or derivatives markets with isolated margin. There should be errors (or at least warnings) already implemented to check that the strategy universe respects the strategy combination. 

There isn't any restriction as to why a strategy should only be allowed to have only one type of market, since most of the logic is handled per asset instance. However, supporting `Cross` margin might require further constraints. Moreover, since it is possible to create and run as many strategies as you want in parallel, having the strategy type to retain simplicity enables more composability.

## Minor Limitations
These limitations mostly mean not implemented features:
- Inverse contracts: The logic doesn't take into account if an asset is a contract margined and settled in the quote currency. Strategies will throw an error if the assets universe contain inverse contracts.
- Fixed fees: All fees are considered to be a percentage of trades. Markets that do trades with fixed fees have not been found, they are usually used only for withdrawals and the bot doesn't do that.
- Funding fees: Despite all the pieces being implemented to emulate funding fees, the backtester doesn't pay funding fees when time comes, and for liquidations it simply uses a 2x trading fee.
- Leverage can only be updated when a position is closed and without any open orders.
