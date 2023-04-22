# Backtesting overview

## Goals

- The backtest should be able to be executed given a custom start and end date.
- The strategy has to have access to the OHLCV and all past trade history.
- It must be able to run during live trading.

## Main loop

- for each `timestamp`:
  - while true:
    - process(`strategy`, `timestamp`, `context`)
    
The loop is just a timestamp feeder!, and the strategy holds all the state.

- Because we use the `TimeFrames` abstraction, the step can be arbitrary, the strategy will just index into ohlcv data according to the last candle compatible with the given timestamp. This is a performance trade-off, we prefer to always index with dates, and never with integers, because it reduces the assumptions to _the row data must match its timestamp_ (its not corrupted!) compared to spurious bugs that might arise by integer indexing.
- The simulation is adversarial to the strategy, it is the job of the simulation to decide __how much__ loss a trade has incurred.

## Strategy General Considerations

- The strategy must account for a  tie breaker to choose which trades to perform on the same candle since we don't know which pair we observed first. In general this is a good use case for MC.

## What does executing an order mean?
When the engine executes an order, it does the following for every order:
- Decide if order should be honored or fail
- Perform simulations, like spread, slippage, market impact.
- Signal to the strategy about failed (canceled) orders.
