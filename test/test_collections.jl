# TODO: add some stub data
test_assetcollection() = @testset "AssetCollection" begin
    @test begin
        if !isdefined(@__MODULE__, :prs)
            @eval prs = getpairs()
        end
        @eval using PingPong.Engine.Collections
        @eval coll = AssetCollection(prs)
        size(coll.data)[1] == length(prs)
    end
    # @test !isnothing(coll[q=:USDT])
    # @test !isnothing(coll[b=:BTC])
    # @test !isnothing(coll[e=:kucoin])
    # @test !isnothing(coll[b=:BTC, q=:USDT])
    # @test !isnothing(coll[b=:BTC, q=:USDT, e=:kucoin])
end
