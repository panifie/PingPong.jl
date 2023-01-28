using Test

_test_time() = begin
    @eval using PingPong.Engine.TimeTicks
    d = dtr"2020-01-..2020-03"
    @assert d.start == DateTime(Year(2020), Month(1), Day(1))
    @assert d.stop == DateTime(Year(2020), Month(3), Day(1))
    @assert isnothing(d.step)
    d = dtr"2020-01-02T23:12:..2021-02-03T00:00:05"
    @assert d.start == DateTime(Year(2020), Month(1), Day(2), Hour(23), Minute(12))
    @assert d.stop == DateTime(Year(2021), Month(2), Day(3), Hour(0), Minute(0), Second(5))
    d = dtr"2020-..2021-;1d"
    @assert d.step == Day(1)
    d = dtr"2020-..2021-;15m"
    @assert d.step == Minute(15)
end

test_time() = @testset "time" begin
    @test begin _test_time() end
end
