using Test
example = "ETH/USDT:USDT-210625-5000-C"

function _test_derivatives_1()
        d = parse(Derivative, example)
        @test d.bc == :ETH
        @test d.qc == :USDT
        @test d.sc == :USDT
        @test d.id == "210625"
        @test d.strike == 5000.0
        @test d.kind == Derivatives.Call
end

test_derivatives() = @testset "derivative" begin
    @eval using PingPong.Engine.Collections.Instruments.Derivatives
    _test_derivatives_1()
end
