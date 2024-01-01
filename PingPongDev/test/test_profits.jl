using Test

_highfirst_1() = begin
    @test sml.ishighfirst(100, 50) == true
    @test sml.ishighfirst(100, 100) == true
    @test sml.ishighfirst(50, 100) == false
end

_profitat() = begin
    open = 100
    close = 90
    fee = 0.01
    digits = 4
    p = sml.profitat(open, close, fee; digits)
    @test p ≈ -0.1178
    spl = string(p)
    parts = split(spl, ".", limit=2)
    @test length(parts[2]) == digits
end

test_profits() = @testset "profits" begin
    @eval begin
        using TimeTicks
        using .PingPong.Engine.Simulations: Simulations as sml
        using Data: Data as da
    end
    _highfirst_1()
    _profitat()
end
