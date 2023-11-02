
@doc """ LiveMode runs PingPong strategies against an exchange with real cash or in sandbox mode.

Disambiguation:
- Functions which mimicks Ccxt (private) api are just wrappers around the omonimous functions.
  The jobs of these wrappers are:
  1. We choose one function depending on support provided by the exchange, preferring WS functions over REST functions.
     TODO: Because WS function are supposed to spawn background tasks, handle a cache,
           and do cache lookups when calling the wrapper, more testing is needed.
  2. We unify "single" and "plural" functions into just plural ones (where Ccxt offers both single and plural versions).
     When the exchange doesn't support a plural function, the single function is used in an async loop over the input sequence.
     If the exchange doesn't support neither version, an error should be expected.
- Functions that start with `live_*` use the wrappers mentioned above, and perform the actual queries over Ccxt.
  The jobs of these functions are:
  1. Take PingPong native types and values, and convert them into (python) Ccxt arguments.
  2. Handle potential errors thrown during quering Ccxt (and log them). Values returned by these functions are either
     - Valid Ccxt responses (can be in python)
     - `nothing` in case of errors.
     - They can throw julia exceptions, but should not throw Ccxt exceptions.
- Other functions should instead conform to PingPong naming conventions (as used in Paper and Sim modes),
  and should deal with PingPong native types, and values.
"""
module LiveMode

let entry_path = joinpath(@__DIR__, "livemode.jl")
    if get(ENV, "JULIA_NOPRECOMP", "") == "all"
        __init__() = begin
            include(entry_path)
        end
    else
        occursin(string(@__MODULE__), get(ENV, "JULIA_NOPRECOMP", "")) &&
            __precompile__(false)
        include(entry_path)
        include("precompile.jl")
    end
end

end # module LiveMode
