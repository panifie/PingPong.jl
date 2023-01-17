using Test
example = "ETH/USDT:USDT-210625-5000-C"

_test_1() = begin
    @eval using JuBot.Engine.Collections.Pairs.Derivatives
    d = Derivative(example)
    @assert d.bc == :ETH &&
        d.qc == :USDT &&
        d.sc == :USDT &&
        d.id == "210625" &&
        d.strike == 5000. &&
        d.kind == Derivatives.Call string(d)
end

test_derivatives() = @testset "Derivative" begin
    @test begin _test1() end
end
