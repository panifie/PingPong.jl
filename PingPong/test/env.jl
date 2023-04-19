using PingPong
@environment!
# setexchange!(:bybit)
# cfg = Config(nameof(exc.id))

function loadbtc()
    @eval begin
        s = strategy!(:Example, cfg)
        fill!(s.universe, config.timeframes[(begin + 1):end]...)
        btc = s.universe[d"BTC/USDT:USDT"].instance[1]
    end
end

function dostub!(pairs=["eth", "btc", "xmr"])
    @eval using Scrapers: Scrapers as scr
    GC.gc()
    qc = string(nameof(s.cash))
    data = invokelatest(scr.BinanceData.binanceload, pairs; quote_currency=qc)
    egn.stub!(s.universe, data)
end
