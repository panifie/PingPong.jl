using Test

_test_cmc_1() = begin
    @eval using PingPong.Watchers.CoinMarketCap
    cmc = CoinMarketCap
    cmc.setapikey!()
    data = cmc.listings(; sort=cmc.volume_24h)
    vol1 = cmc.usdvol(data[1])
    vol2 = cmc.usdvol(data[2])
    @assert vol1 > vol2
    data = cmc.listings(; sort=cmc.percent_change_7d)
    pc1 = Float64(cmc.usdquote(data[1])["percent_change_7d"])
    pc2 = Float64(cmc.usdquote(data[2])["percent_change_7d"])
    @assert pc1 > pc2
    true
end

test_cmc() = @testset "coinmarketcap" begin
    @test begin
        _test_cmc_1()
    end
end
