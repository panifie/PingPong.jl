@doc "Downloads bybit trading data archives converts it to ohlcv and stores it locally."
module BybitData

using URIs
using HTTP
using EzXML
using Data: DataFrame, zi
using Data: save_ohlcv, Cache as ca, load_ohlcv
using TimeTicks
using Pbar
using Lang
using ..Scrapers:
    selectsyms,
    timeframe!,
    workers!,
    WORKERS,
    TF,
    fetchfile,
    zlib,
    csvtodf,
    trades_to_ohlcv,
    mergechunks,
    glue_ohlcv,
    dofetchfiles

const NAME = "Bybit"
const BASE_URL = URI("https://public.bybit.com/")
# NOTE:
# - metatrade_kline is low res (15m)
# - premium_index and spot_index have NO VOLUME data
# Which means the only source that reconstructs OHLCV is /trading
const PATHS = (; premium_index="premium_index", spot_index="spot_index", trading="trading")
const TRADING_SYMS = String[]
const COLS = [:symbol, :timestamp, :price, :size]

function links_list(doc)
    elements(elements(elements(elements(doc.node)[1])[2])[3])
end

function bybitallsyms(path=PATHS.trading)
    if isempty(TRADING_SYMS)
        url = joinpath(BASE_URL, path)
        all_syms = let resp = HTTP.get(url)
            doc = parsehtml(resp.body)
            els = links_list(doc)
            map(x -> rstrip(x.content, '/'), els)
        end
        append!(TRADING_SYMS, all_syms)
    else
        TRADING_SYMS
    end
end

function symsvec(syms; path=PATHS.trading, quote_currency="usdt")
    all_syms = bybitallsyms(path)
    qc = uppercase(quote_currency)
    selected = Set(uppercase.(syms))
    mysyms = String[]
    all = isempty(selected)
    rgx = Regex("(.*?)($qc)")
    for s in all_syms
        m = match(rgx, s)
        isnothing(m) && continue
        (all || m[1] ∈ selected) && push!(mysyms, s)
    end
    mysyms
end

function fetch_ohlcv(sym, file; out, path=PATHS.trading)
    url = symurl(sym, file; path)
    data = fetchfile(url)
    df = csvtodf(data, COLS)
    rename!(df, :size => :amount)
    ohlcv = trades_to_ohlcv(df)
    out[first(ohlcv.timestamp)] = ohlcv
    @debug "Downloaded chunk $file"
    nothing
end

symlinkslist(sym; path=PATHS.trading) = begin
    resp = HTTP.get(symurl(sym; path))
    doc = EzXML.parsehtml(resp.body)
    links_list(doc)
end
cache_key(sym; path=PATHS.trading) = "$(NAME)/_$(sym)_$(path)"
# function symfiles(links, from=nothing)
#     download_from = 1
#     if !isnothing(from)
#         for (n, l) in enumerate(links)
#             file = l.content
#             if file == from
#                 download_from = n + 1
#                 break
#             end
#         end
#     end
#     download_from > length(links) && return nothing
#     map(l -> l.content, @view(links[download_from:end]))
# end

# function dofetchfiles(sym, files; path=PATHS.trading)
#     out = Dict{DateTime,DataFrame}()
#     @pbar! files sym
#     try
#         dofetch(file) = begin
#             fetch_ohlcv(sym, file; out, path)
#             @pbupdate!
#         end
#         asyncmap(dofetch, files; ntasks=WORKERS[])
#     finally
#         @pbclose
#     end
#     return out
# end

symurl(args...; path=PATHS.trading) = joinpath(BASE_URL, path, args...)
function fetchsym(sym; reset=false, path=PATHS.trading)
    from = reset ? nothing : ca.load_cache(cache_key(sym; path); raise=false)
    files = let links = symlinkslist(sym; path)
        symfiles(links; by=l -> l.content, from)
    end
    isnothing(files) && return (nothing, nothing)
    out = dofetchfiles(sym, files; func=fetch_ohlcv, path)
    (mergechunks(files, out), last(files))
end

function bybitsave(sym, data, zi=zi[])
    save_ohlcv(zi, NAME, sym, string(TF[]), data; check=@ifdebug(check_all_flag, :none))
end

@doc "Download data for symbols `syms` from bybit.
`reset`: if `true` start from scratch.
"
function bybitdownload(
    syms=String[]; reset=false, path=PATHS.trading, quote_currency="usdt"
)
    all_syms = bybitallsyms(path)
    selected = selectsyms(syms, all_syms; quote_currency)
    if isempty(selected)
        throw(ArgumentError("No symbols found matching $syms"))
    end
    for s in selected
        ohlcv, last_file = fetchsym(s; reset, path)
        if !(isnothing(ohlcv) || isnothing(last_file))
            bybitsave(s, ohlcv)
            ca.save_cache(cache_key(s; path), last_file)
        end
    end
end
@argstovec bybitdownload AbstractString

@doc "Load previously downloaded data from bybit."
function bybitload(syms::AbstractVector; zi=zi[], kwargs...)
    load_ohlcv(zi, NAME, syms, string(TF[]); kwargs...)
end
@argstovec bybitload AbstractString

export bybitdownload, bybitload, bybitallsyms
end
