const CpTwitterVal = Val{:cp_twitter}
const CpTweet = @NamedTuple begin
    date::DateTime
    status::String
    retweet_count::Int
    like_count::Int
end

@doc """ Create a `Watcher` instance that tracks all markets for an exchange (coinpaprika).

"""
function cp_twitter_watcher(syms::AbstractVector, interval=Minute(5))
    attrs = Dict{Symbol, Any}()
    attrs[:ids] = cp.idbysym.(syms)
    attrs[:key] = "cp_twitter_$(join(string.(syms), "-"))"
    watcher_type = Dict{String,Vector{CpTweet}}
    wid = string(CpTwitterVal.parameters[1], "-", hash(syms))
    watcher(watcher_type, wid, CpTwitterVal(); flush=true, fetch_interval=interval, attrs)
end
cp_twitter_watcher(syms...) = cp_twitter_watcher([syms...])

function _fetch!(w::Watcher, ::CpTwitterVal)
    tweets = Dict(s => cp.twitter(s) for s in attr(w, :ids))
    if length(tweets) > 0
        result = Dict{String,Vector{CpTweet}}()
        temp = Dict{String,Any}()
        for (s, tws) in tweets
            tweets = CpTweet[]
            for t in tws
                empty!(temp)
                merge!(temp, t)
                temp["status"] = replace(temp["status"], r"(?:http[^ ]*)" => "")
                push!(tweets, fromdict(CpTweet, String, temp))
            end
            result[s] = tweets
        end
        pushnew!(w, result)
        true
    else
        false
    end
end

_init!(w::Watcher, ::CpTwitterVal) = default_init(w, nothing)
_get!(w::Watcher, ::CpTwitterVal) = w.buffer
