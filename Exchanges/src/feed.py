from cryptofeed import FeedHandler
from cryptofeed.defines import CANDLES
from cryptofeed.exchanges import KuCoin
from time import sleep
from multiprocessing.managers import SyncManager
from multiprocessing import Process
from datetime import datetime as dt
# import sys
# sys.stderr = open('/dev/null', 'w')

mg = SyncManager()
mg.start()
DATA = mg.dict()
START = dt.now()
TIMEOUT = 0

F = FeedHandler()


async def ohlcv(data, ts):
    global START
    DATA[ts] = data
    exit()

def cf(symbols, timeframe):
    print("Fetching timeframe: ", timeframe, " for: ", len(symbols), " pairs.")
    fe = KuCoin(
        symbols=symbols,
        channels=[CANDLES],
        callbacks={CANDLES: ohlcv},
        candle_interval=timeframe,
        )
    F.add_feed(fe)

    F.run()

def run(timeout=3, timeframe="1h", symbols=[]):
    global TIMEOUT; TIMEOUT = timeout
    p = Process(target=cf, kwargs={"symbols": symbols, "timeframe": timeframe})
    p.start()
    p.join()
    return dict(DATA)
