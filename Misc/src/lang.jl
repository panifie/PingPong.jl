using Distributed: @distributed
using Logging: with_logger, NullLogger

macro evalmod(files...)
    quote
        with_logger(NullLogger()) do
            for f in $files
                eval(:(include(joinpath(@__DIR__, $f))))
            end
        end
    end
end

macro parallel(flag, body)
    b = esc(body)
    db = esc(:(@distributed $body))
    quote
        if $(esc(flag))
            $db
        else
            $b
        end
    end
end

