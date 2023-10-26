using .Lang: @preset, @precomp

@preset let
    @precomp begin
        __init__()
        @withpbar! [1, 2, 3] desc = "asd" begin
            @pbupdate!
            @pbupdate!
            @pbupdate!
        end
    end
end
