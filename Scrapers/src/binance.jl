module BinanceData
using URIs
using HTTP
using CodecZlib: CodecZlib as zlib
using EzXML: EzXML as ez
using Lang: @ifdebug, @lget!, filterkws, @argstovec
using TimeTicks
using Data: OHLCV_COLUMNS, Cache as ca, zi, save_ohlcv, load_ohlcv
using Data.DataFrames
using ..Scrapers:
    selectsyms,
    WORKERS,
    TF,
    timeframe!,
    workers!,
    fetchfile,
    symfiles,
    dofetchfiles,
    csvtodf,
    zipdecode,
    timestamp!,
    cleanup_ohlcv_data,
    mergechunks

const BASE_URL = URI("https://data.binance.vision")

const NAME = "Binance"
const MARKET = (; data="spot", um="futures/um", cm="futures/cm")
const FREQ = (; daily="daily", monthly="monthly")
const KIND = (;
    trades="trades",
    agg="aggTrades",
    index="indexPriceKlines",
    klines="klines",
    mark="markPriceKlines",
    premium="premiumIndexKlines",
)
# syms availble for each path
const QUERY_SYMS = IdDict{URI,Vector{String}}()
const CDN_URL = Ref(URI())
const COLS = [1, 2, 3, 4, 5, 6]

function cdn!()
    if CDN_URL[] === URI()
        html = HTTP.get(BASE_URL).body |> ez.parsehtml
        m = match(r"BUCKET_URL\s+=\s+'(.*)'", html.node.content)
        @assert !isnothing(m) "Could not find cdn url, script might be broken, or endpoint is down"
        CDN_URL[] = URI(m[1])
    end
end

function make_path(; market=:um, freq=:monthly, kind=:klines)
    join(
        (getproperty(MARKET, market), getproperty(FREQ, freq), getproperty(KIND, kind)), '/'
    )
end

function make_url(; kwargs...)
    cdn!()
    p = make_path(; kwargs...)
    # NOTE: the "/" at the end is important otherwise the query returns only 1 element
    URI(CDN_URL[]; query=("delimiter=/&" * "prefix=data/" * p * '/'))
end

function make_sym_url(sym; kwargs...)
    url = make_url(; kwargs...)
    sym_path = join((rstrip(url.query, '/'), sym, string(TF[])), '/')
    URI(url; query=sym_path * '/')
end
function symlinkslist(s; kwargs...)
    url = make_sym_url(s; kwargs...)
    html = ez.parsexml(HTTP.get(url).body)
    links = ez.Node[]
    function chunk_url(el)
        e = elements(el)[1]
        e.name == "Key" && !endswith(e.content, "CHECKSUM") && push!(links, e)
    end
    for el in elements(ez.elements(html.node)[1])
        el.name == "Contents" && chunk_url(el)
    end
    return links
end

function binancesyms(; kwargs...)
    url = make_url(; kwargs...)
    @lget! QUERY_SYMS url begin
        body = HTTP.get(url).body
        html = ez.parsexml(body)
        els = ez.elements(ez.elements(html.node)[1])
        symname(el) = begin
            sp = split(el.content, '/')
            isempty(sp[end]) ? sp[end - 1] : sp[end]
        end
        [symname(el) for el in els if el.name == "CommonPrefixes"]
    end
end

function fetch_ohlcv(::Any, file; out)
    url = URI(BASE_URL; path=('/' * file))
    data = fetchfile(url; dec=zipdecode)
    df = csvtodf(data, COLS)
    rename!(df, (n => col for (n, col) in enumerate(OHLCV_COLUMNS))...)
    df = timestamp!(df, dt)
    df = cleanup_ohlcv_data(df, TF[])
    out[first(df.timestamp)] = df
    @debug "Downloaded chunk $file"
    nothing
end

using ..Scrapers: Scrapers as scr
function fetchsym(sym; reset, path_kws...)
    from = reset ? nothing : ca.load_cache(cache_key(sym; path_kws...); raise=false)
    files = let links = symlinkslist(sym; path_kws...)
        scr.symfiles(links; by=x -> x.content, from)
    end
    isnothing(files) && return (nothing, nothing)
    out = dofetchfiles(sym, files; func=fetch_ohlcv, path_kws...)
    (mergechunks(files, out), last(files))
end

cache_key(sym; path_kws...) = begin
    mkt = get(path_kws, :market, "um")
    kind = get(path_kws, :kind, "klines")
    "$(NAME)/_$(sym)_$(mkt)_$(kind)"
end
function binancesave(sym, ohlcv; zi=zi[])
    save_ohlcv(zi, NAME, sym, string(TF[]), ohlcv; check=@ifdebug(check_all_flag, :none))
end
function binancedownload(syms; zi=zi[], quote_currency="usdt", reset=false, kwargs...)
    path_kws = filterkws(:market, :freq, :kind; kwargs)
    all_syms = binancesyms(; path_kws...)
    selected = selectsyms(syms, all_syms; quote_currency)
    if isempty(selected)
        throw(ArgumentError("No symbols found matching $syms"))
    end
    for s in selected
        ohlcv, last_file = fetchsym(s; reset, path_kws...)
        if !(isnothing(ohlcv) || isnothing(last_file))
            binancesave(s, ohlcv)
            ca.save_cache(cache_key(s; path_kws...), last_file)
        end
    end
end
@argstovec binancedownload AbstractString

@doc "Load previously downloaded data from binance."
function binanceload(syms::AbstractVector; zi=zi[], kwargs...)
    load_ohlcv(zi, NAME, syms, string(TF[]); kwargs...)
end
@argstovec binanceload AbstractString

export binancedownload, binanceload, binancesyms
end
