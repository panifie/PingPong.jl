# Strategy combo

The types considered for possible combinations are:

- `NoMargin,Isolated,Cross`: if the strategy trades on derivatives markets
- `Hedged,NotHedged`: if positions management is one-way or both

|          | Hedged | NotHedged |
| -------- | ------ | --------- |
| NoMargin |        | X         |
| Isolated | -      | X         |
| Cross    | -      | -         |

Therefore the bot currently supports trading on spot markets, or derivatives markets with isolated margin. There _should_ be errors (or at least warnings) already implemented to check that the strategy universe respects the strategy combo. 

There isn't any stopper as to why a strategy should only be allowed to have only one type of market, since most of the logic is handled _per asset instance_, however supporting `Cross` margin might require further constraints. 
More over since it is possible to create and run as many strategies as you want in parallel, having the strategy type to retain simplicity enables more composability.

## Minor limitations
These limitations mostly mean not implemented features:
- Inverse contracts: logic doesn't take into account if an asset is a contract margined and settled in the _quote currency_. Strategies will throw an error if the assets universe contain inverse contracts.
- Fixed fees: all fees are considered to be a percentage of trades, I haven't found markets that do trades with fixed fees, they are usually used only for withdrawals and the bot doesn't do that.
- Funding fees: despite all the pieces being implemented to emulate funding fees, the backtester doesn't pay funding fees when time comes, and for liquidations it simply uses a 2x trading fee.
- Leverage can only be updated when a position is closed and without any open orders
