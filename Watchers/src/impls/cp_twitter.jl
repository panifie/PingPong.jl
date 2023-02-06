const CpTweet = @NamedTuple begin
    date::DateTime
    status::String
    retweet_count::Int
    like_count::Int
end


@doc """ Create a `Watcher` instance that tracks all markets for an exchange (coinpaprika).

"""
function cp_twitter_watcher(syms::AbstractVector)
    for s in syms
        cp.check_coin_id(s)
    end
    fetcher() = begin
        tweets = Dict(s => cp.twitter(s) for s in syms)
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
        result
    end
    name = "cp_$(join(syms, "-"))-tweets"
    watcher_type = Dict{Symbol,Vector{CpTweet}}
    watcher(watcher_type, name, fetcher; flusher=true, interval=Minute(5))
end
cp_twitter_watcher(syms...) = cp_twitter_watcher([syms...])
