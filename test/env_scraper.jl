using Data
const da = Data
using Pkg
Pkg.activate("./Scrapers")
using Scrapers: Scrapers as scr
Revise.track(scr)
const bb = scr.BybitData
const bn = scr.BinanceData
