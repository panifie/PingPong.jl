## How should the backtest perform?

## Goals

- The backtest should be able to be executed given a custom start and end date.
- The strategy has to have access to the OHLCV and all past trade history.
- It must be able to run during live trading.

## Main loop

- for each candle:
  - for Each pair:
    - process signals
      - include `take_profit` and `stop_loss` triggers with the signal
    - if pair is`trade_able`:
      - if `signal != 0`:
        - if `signal < 0`:
          - call sell function 
        - if `signal > 0`:
          - call buy function
            
### Notes
- The strategy determines the trade-ability of a pair.
- The buy and sell functions simply receive the current candle. 
- ...Which means that the strategy effectively holds all the state, the engine is just a candle feeder.
- For simplicity, trades are all market orders, not limit orders.
- Also for simplicity, orders never fail (instead we model failure as a larger loss over the holdings, i.e. sell with higher spread)
- The engine is adversarial to the strategy, it is the job of the engine to decide __how much__ loss a trade has incurred.

## Strategy Features

- The strategy must account for a  tie breaker to choose which trades to perform on the same candle
- The signal itself is a value between -1 and 1, multiplied by a base amount configured in the strategy.
- We should write ancillary functions for stop-loss and take-profit that are reusable across strategies.
