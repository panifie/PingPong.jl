using Lang: @preset, @precomp
@preset let
    tf = tf"1m"
    m = Minute(1)
    s = "1m"
    @precomp begin
        string(tf)
        timeframe(s)
        compact(m)
        available(tf"1m", dt"2020-01-01")
        from_to_dt(Day(1), 1000, 2000)
        let timeframe = "1m"
            @as_td
        end
    end
end
