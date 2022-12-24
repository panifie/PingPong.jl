module Kucoin

using Misc
import JSON

const kucoin_config = joinpath(ENV["HOME"], "dev", "JuBot.jl", "cfg", "kucoin.json")

function kucoin_keys()
    cfg = Dict()
    open(kucoin_config) do f
        cfg = JSON.parse(f)
    end
    key = cfg["apiKey"]
    secret = cfg["secret"]
    password = cfg["password"]
    Dict("key" => key, "secret" => secret, "pass" => password)
end

end
