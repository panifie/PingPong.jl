## How should the backtest perform?

## Goals

- The backtest should be able to be executed given a custom start and end date.
- The strategy has to have access to the OHLCV and all past trade history.
- It must be able to run during live trading.

## Main loop

- for each `timestamp`:
  - while true:
    - process(`strategy`, `timestamp`, `orders`)
    - if `orders.size` == 0:
      break
    - execute(`orders`)
            
## Notes
- The strategy holds all the state, the engine is just a timestamp feeder.
- Because we use the `TimeFrames` abstraction, the step can be arbitrary, the strategy will just index into ohlcv data according to the last candle compatible with the given timestamp.
- For simplicity, trades happen as market orders, not limit orders.
- Also for simplicity, orders never fail (instead we model failure as a larger loss over the holdings, i.e. sell with higher spread)
- The engine is adversarial to the strategy, it is the job of the engine to decide __how much__ loss a trade has incurred.

## Strategy General Considerations

- The strategy must account for a  tie breaker to choose which trades to perform on the same candle since we don't know which pair we observed first.
- we could make the backtest randomize the order of the universe at each step, but if the strategy applies some kind of internal sorting, it would be useless.
- The signal itself is a value between -1 and 1, multiplied by a base amount configured in the strategy.
- We should write ancillary functions for stop-loss and take-profit that are reusable across strategies.

## What does executing an order mean?
When the engine executes an order, it does the following for every order:
- Calculate the spread of the order asset based on the ohlcv data 
- check that the balance is positive and above the minimum order size if not mark the order as failed
- Choose the open or close rate according to the signal type and open/close the order accordingly
- return the failed order to the strategy and repeat until the strategy gives no new orders.
