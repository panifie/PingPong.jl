@doc "Downloads bybit trading data archives converts it to ohlcv and stores it locally."
module BybitData

using URIs
using HTTP
using Ccxt: ccxt_exchange
using CodecZlib: CodecZlib as zlib
using EzXML
using CSV
using Data: DataFrame, DataFramesMeta, zi, _contiguous_ts
using Data: save_ohlcv, Cache as ca, load_ohlcv
using Data.DFUtils: lastdate, firstdate
using .DataFramesMeta
using TimeTicks
using Processing: TradesOHLCV as tra, cleanup_ohlcv_data, trail!
using Pbar
using Lang

const NAME = "Bybit"
const BASE_URL = URI("https://public.bybit.com/")
# NOTE:
# - metatrade_kline is low res (15m)
# - premium_index and spot_index have NO VOLUME data
# Which means the only source that reconstructs OHLCV is /trading
const PATHS = (; premium_index="premium_index", spot_index="spot_index", trading="trading")
const TRADING_SYMS = String[]
const WORKERS = Ref(10)
const TF = Ref(tf"1m")
const MAX_CHUNK_SIZE = 50_000 # Limit the chunk size to not exceed lmdb memmaped page size

function __init__()
    zi[] = zilmdb()
end

function workers!(n)
    prev = WORKERS[]
    WORKERS[] = n
    @info "Workers count set from $prev to $n"
end
function timeframe!(s)
    prev = TF[]
    TF[] = timeframe(s)
    @info "TimeFrame set from $prev to $(TF[])"
end

function bybit_exchange()
    ccxt_exchange(:bybit)
end

function currencies()
    exc = ccxt_exchange(:bybit)
    exc.currencies
end

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

function fetchfile(url)
    resp = HTTP.get(url)
    zlib.transcode(zlib.GzipDecompressor, resp.body)
end
csvtodf(v) = begin
    df = CSV.read(v, DataFrame; select=[:symbol, :timestamp, :price, :size])
    rename!(df, :size => :amount)
    df
end
dftoohlcv(df) = begin
    df[!, :timestamp] = apply.(TF[], unix2datetime.(df.timestamp))
    ohlcv = tra.to_ohlcv(df)
    cleanup_ohlcv_data(ohlcv, TF[])
end

function fetch_ohlcv(sym, file; out, path=PATHS.trading)
    url = symurl(sym, file; path)
    data = fetchfile(url)
    df = csvtodf(data)
    ohlcv = dftoohlcv(df)
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
function symfiles(links, from=nothing)
    download_from = 1
    if !isnothing(from)
        for (n, l) in enumerate(links)
            file = l.content
            if file == from
                download_from = n + 1
            end
        end
    end
    download_from > length(links) && return nothing
    map(l -> l.content, @view(links[download_from:end]))
end

function dofetchfiles(sym, files; path=PATHS.trading)
    out = Dict{DateTime,DataFrame}()
    @pbar! files sym
    try
        dofetch(file) = begin
            fetch_ohlcv(sym, file; out, path)
            @pbupdate!
        end
        asyncmap(dofetch, files; ntasks=WORKERS[])
    finally
        @pbclose
    end
    return out
end

function mergechunks(files, out)
    @assert length(out) == length(files) "Couldn't download all chunks!"
    sorted = sort(out)
    glue_ohlcv(sorted)
    merged = vcat(values(sorted)...)
    @ifdebug _contiguous_ts(merged.timestamp, timefloat(TF[]))
    merged
end

symurl(args...; path=PATHS.trading) = joinpath(BASE_URL, path, args...)
function fetchsym(sym; reset=false, path=PATHS.trading)
    from = reset ? nothing : ca.load_cache(cache_key(sym; path); raise=false)
    files = let links = symlinkslist(sym; path)
        symfiles(links, from)
    end
    isnothing(files) && return (nothing, nothing)
    out = dofetchfiles(sym, files; path)
    (mergechunks(files, out), last(files))
end

function glue_ohlcv(out)
    prev_df = first(out).second
    prev_ts = lastdate(prev_df)
    for (first_ts, df) in Iterators.drop(out, 1)
        if prev_ts + TF[] != first_ts
            trail!(prev_df, TF[]; to=firstdate(df))
        end
        @assert lastdate(prev_df) + TF[] == firstdate(df)
        prev_ts = lastdate(df)
        prev_df = df
    end
    out
end

function bybitsave(sym, data, zi=zi[])
    idx = 1
    sz = size(data, 1)
    while idx <= sz
        chunk = view(data, idx:idx+MAX_CHUNK_SIZE, :)
        save_ohlcv(zi, NAME, sym, string(TF[]), chunk; check=@ifdebug(check_all_flag, :none))
        idx += MAX_CHUNK_SIZE
    end
end

function bybitdownload(syms=String[]; reset=false, path=PATHS.trading)
    selected = symsvec(syms; path)
    if isempty(selected)
        throw(ArgumentError("No symbols found matching $syms"))
    end
    for s in selected
        ohlcv, last_file = fetchsym(s; reset, path)
        if !(isnothing(ohlcv) || isnothing(last_file))
            save(s, ohlcv)
            ca.save_cache(cache_key(s; path), last_file)
        end
    end
end

bybitdownload(args::AbstractString...) = bybitdownload([args...])
bybitload(syms; zi=zi[]) = load_ohlcv(zi, NAME, syms, string(TF[]))
bybitload(syms...) = bybitload([syms...])

export bybitdownload, bybitload, bybitallsyms
end
