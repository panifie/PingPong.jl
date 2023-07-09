using .Lang: @preset, @precomp


@preset let
    using Stubs
    @precomp let
        s = Stubs.stub_strategy()
        Engine.SimMode.backtest!(s)
        ai = first(s.universe)
    end
end
