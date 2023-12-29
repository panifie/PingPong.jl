using Test

_test_cmc_1() = begin
    cmc = CoinMarketCap
    cmc.setapikey!()
    data = cmc.listings(; sort=cmc.volume_24h)
    @test data isa Vector{Dict{String, Any}}
    vol1 = cmc.usdvol(data[1])
    vol2 = cmc.usdvol(data[2])
    @test vol1 > vol2
    data = cmc.listings(; sort=cmc.percent_change_7d)
    @test data isa Vector{Dict{String, Any}}
    pc1 = Float64(cmc.usdquote(data[1])["percent_change_7d"])
    pc2 = Float64(cmc.usdquote(data[2])["percent_change_7d"])
    @test pc1 > pc2
end

test_cmc() = @testset "coinmarketcap" begin
    @eval using PingPong.Engine.LiveMode.Watchers.CoinMarketCap
    _test_cmc_1()
end
