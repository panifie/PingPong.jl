@doc "Downloads bybit trading data archives converts it to ohlcv and stores it locally."
module BybitData

using ..Data.DataFrames
using ..Pbar
using EzXML
using URIs
using HTTP
using ..Data: DataFrame, zi
using ..Data: save_ohlcv, Cache as ca, load_ohlcv
using ..TimeTicks
using ..Lang
using ..Scrapers:
    selectsyms,
    timeframe!,
    workers!,
    WORKERS,
    TF,
    SEM,
    HTTP_PARAMS,
    fetchfile,
    zlib,
    csvtodf,
    trades_to_ohlcv,
    mergechunks,
    glue_ohlcv,
    dofetchfiles,
    symfiles,
    @acquire,
    @fromassets

const NAME = "Bybit"
const BASE_URL = URI("https://public.bybit.com/")
# NOTE:
# - metatrade_kline is low res (15m)
# - premium_index and spot_index have NO VOLUME data
# Which means the only source that reconstructs OHLCV is /trading
const PATHS = (;
    premium_index="premium_index", spot_index="spot_index", trading="trading", spot="spot"
)
const TRADING_SYMS = String[]
const TRADES_COLS = [:symbol, :timestamp, :price, :size]
const SPOT_COLS = [:timestamp, :price, :volume]

function links_list(doc)
    elements(elements(elements(elements(doc.node)[1])[2])[3])
end

function bybitallsyms(path=PATHS.trading)
    if isempty(TRADING_SYMS)
        url = joinpath(BASE_URL, path)
        all_syms = let resp = HTTP.get(url; HTTP_PARAMS...)
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

function colvec(path=PATHS.trading)
    if path == PATHS.trading
        TRADES_COLS
    else
        SPOT_COLS
    end
end
function colrename(path=PATHS.trading)
    if path == PATHS.trading
        (:size => :amount,)
    else
        (:volume => :amount,)
    end
end

function fetch_ohlcv(sym, file; out, path=PATHS.trading)
    url = symurl(sym, file; path)
    data = fetchfile(url)
    # spot uses :volume col
    df = csvtodf(data, colvec(path))
    rename!(df, colrename(path)...)
    # spot uses ms timestamps
    conv = path == PATHS.trading ? unix2datetime : dt
    ohlcv = trades_to_ohlcv(df, conv)
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

symurl(args...; path=PATHS.trading) = joinpath(BASE_URL, path, args...)
function fetchsym(sym; reset=false, path=PATHS.trading)
    from = reset ? nothing : ca.load_cache(cache_key(sym; path); raise=false)
    files = let links = symlinkslist(sym; path)
        symfiles(links; by=l -> l.content, from)
    end
    isnothing(files) && return (nothing, nothing)
    out = dofetchfiles(sym, files; func=fetch_ohlcv, path)
    (mergechunks(files, out), last(files), out)
end

key(sym, args...) = join((sym, args...), '_')
function bybitsave(sym, data; path=PATHS.trading, zi=zi[])
    save_ohlcv(
        zi, NAME, key(sym, path), string(TF[]), data; check=@ifdebug(check_all_flag, :none)
    )
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
    @withpbar! selected desc = "Symbols" begin
        for s in selected
            @acquire SEM begin
                function fetchandsave(s)
                    ohlcv, last_file, tmpdata = fetchsym(s; reset, path)
                    if !(isnothing(ohlcv) || isnothing(last_file))
                        bybitsave(s, ohlcv; path)
                        ca.save_cache(cache_key(s; path), last_file)
                    else
                        tmppath = joinpath(_tempdir(), "pingpong")
                        mkpath(tmppath)
                        name = basename(tempname())
                        ca.save_cache(name; cache_path=tmppath)
                        @info "Saving temp data to $(joinpath(tmppath, name))"
                    end
                    @pbupdate!
                end
                asyncmap(fetchandsave, (s for s in selected); ntasks=WORKERS[])
            end
        end
    end
end
@fromassets bybitdownload
@argstovec bybitdownload AbstractString

@doc "Load previously downloaded data from bybit."
function bybitload(
    syms::AbstractVector; quote_currency="usdt", path=PATHS.trading, zi=zi[], kwargs...
)
    selected = let all_syms = bybitallsyms(path)
        selectsyms(syms, all_syms; quote_currency)
    end
    load_ohlcv(zi, NAME, key.(selected, path), string(TF[]); kwargs...)
end
@fromassets bybitload
@argstovec bybitload AbstractString x -> first(x).second

export bybitdownload, bybitload, bybitallsyms
end
