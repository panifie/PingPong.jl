using Test

function _test_time()
    @eval begin
        d = dtr"2020-01-..2020-03"
        @test d.start == DateTime(Year(2020), Month(1), Day(1))
        @test d.stop == DateTime(Year(2020), Month(3), Day(1))
        @test isnothing(d.step)
        d = dtr"2020-01-02T23:12:..2021-02-03T00:00:05"
        @test d.start == DateTime(Year(2020), Month(1), Day(2), Hour(23), Minute(12))
        @test d.stop ==
            DateTime(Year(2021), Month(2), Day(3), Hour(0), Minute(0), Second(5))
        d = dtr"2020-..2021-;1d"
        @test d.step == Day(1)
        d = dtr"2020-..2021-;15m"
        @test d.step == Minute(15)
    end
end

test_time() = @testset "time" begin
    @eval using PingPong.Engine.TimeTicks
    @eval _test_time()
end
