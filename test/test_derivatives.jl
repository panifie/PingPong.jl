using Test
example = "ETH/USDT:USDT-210625-5000-C"

function _test_derivatives_1()
    begin
        @eval using PingPong.Engine.Collections.Instruments.Derivatives
        d = Derivative(example)
        @assert d.bc == :ETH &&
            d.qc == :USDT &&
            d.sc == :USDT &&
            d.id == "210625" &&
            d.strike == 5000.0 &&
            d.kind == Derivatives.Call string(d)
    end
end

test_derivatives() = @testset "derivative" begin
    @test begin
        _test_derivatives_1()
    end
end
