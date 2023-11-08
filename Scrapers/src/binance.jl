module BinanceData
using ..Scrapers:
    selectsyms,
    HTTP_PARAMS,
    WORKERS,
    SEM,
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
    mergechunks,
    @fromassets
using ..Data: OHLCV_COLUMNS, Cache as ca, zi, save_ohlcv, load_ohlcv
using ..Data.DataFrames
using ..Pbar
using Instruments
using ..Lang: @ifdebug, @lget!, filterkws, splitkws, @argstovec, @acquire
using ..TimeTicks

using EzXML: EzXML as ez
using URIs
using HTTP
using CodecZlib: CodecZlib as zlib

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
const QUERY_SYMS = IdDict{Any,Vector{String}}()
const CDN_URL = Ref(URI())
const COLS = [1, 2, 3, 4, 5, 6]

isklines(s) = s ∈ (:index, :klines, :mark, :premium)

function cdn!()
    if CDN_URL[] === URI()
        html = HTTP.get(BASE_URL; HTTP_PARAMS...).body |> ez.parsehtml
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
        e = ez.elements(el)[1]
        e.name == "Key" && !endswith(e.content, "CHECKSUM") && push!(links, e)
    end
    for el in ez.elements(ez.elements(html.node)[1])
        el.name == "Contents" && chunk_url(el)
    end
    return links
end

function binancesyms(; kwargs...)
    @lget! QUERY_SYMS kwargs begin
        key = key_path("allsyms"; kwargs...)
        cached = ca.load_cache(key; raise=false, agemax=Week(1))
        if isnothing(cached)
            url = make_url(; kwargs...)
            body = HTTP.get(url; HTTP_PARAMS...).body
            html = ez.parsexml(body)
            els = ez.elements(ez.elements(html.node)[1])
            symname(el) = begin
                sp = split(el.content, '/')
                isempty(sp[end]) ? sp[end - 1] : sp[end]
            end
            allsyms = [symname(el) for el in els if el.name == "CommonPrefixes"]
            ca.save_cache(key, allsyms)
            allsyms
        else
            cached
        end
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
    from = reset ? nothing : ca.load_cache(key_path(sym; path_kws...); raise=false)
    files = let links = symlinkslist(sym; path_kws...)
        scr.symfiles(links; by=x -> x.content, from)
    end
    isnothing(files) && return (nothing, nothing)
    out = dofetchfiles(sym, files; func=fetch_ohlcv)
    (mergechunks(files, out), last(files))
end

key(sym; path_kws...) = begin
    mkt = get(path_kws, :market, "um")
    kind = get(path_kws, :kind, "klines")
    "$(sym)_$(mkt)_$(kind)"
end
key_path(sym; path_kws...) = joinpath(NAME, key(sym; path_kws...))
function binancesave(sym, ohlcv; reset=false, zi=zi[], path_kws...)
    save_ohlcv(
        zi,
        NAME,
        key(sym; path_kws...),
        string(TF[]),
        ohlcv;
        reset,
        check=@ifdebug(check_all_flag, :none)
    )
end

function binancedownload(syms; zi=zi[], quote_currency="usdt", reset=false, kwargs...)
    cdn!()
    path_kws = filterkws(:market, :freq, :kind; kwargs)
    all_syms = binancesyms(; path_kws...)
    selected = selectsyms(syms, all_syms; quote_currency)
    if isempty(selected)
        throw(ArgumentError("No symbols found matching $syms"))
    end
    @withpbar! selected desc = "Symbols" begin
        fetchandsave(s) = begin
            ohlcv, last_file = fetchsym(s; reset, path_kws...)
            if !(isnothing(ohlcv) || isnothing(last_file))
                binancesave(s, ohlcv; reset)
                ca.save_cache(key_path(s; path_kws...), last_file)
            end
            @pbupdate!
        end
        @acquire SEM asyncmap(fetchandsave, (s for s in selected), ntasks=WORKERS[])
    end
    nothing
end
@fromassets binancedownload

@argstovec binancedownload AbstractString

@doc "Load previously downloaded data from binance."
function binanceload(syms::AbstractVector; zi=zi[], quote_currency="usdt", kwargs...)
    path_kws, rest_kws = splitkws(:market, :freq, :kind; kwargs)
    selected = let all_syms = binancesyms(; path_kws...)
        selectsyms(syms, all_syms; quote_currency)
    end
    load_ohlcv(zi, NAME, key.(selected; path_kws...), string(TF[]); rest_kws...)
end
@fromassets binanceload
@argstovec binanceload AbstractString x -> first(x).second

export binancedownload, binanceload, binancesyms
end
