using Test

function _test_watchers_1()
    @eval using Watchers
end

test_watchers() = @testset "watchers" begin
    @test begin _test_watchers_1() end
end
