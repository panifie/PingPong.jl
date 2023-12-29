isdefined(Main, :da) || using Data: Data as da
using Pkg
Pkg.activate("./Scrapers")
using Scrapers: Scrapers as scr
Revise.track(scr)
const bb = scr.BybitData
const bn = scr.BinanceData
