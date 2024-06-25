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
using ..Lang:
    @ifdebug, @lget!, filterkws, splitkws, withoutkws, @argstovec, @acquire, @except
using ..TimeTicks
using ..DocStringExtensions

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

@doc """ Checks if the input symbol is one of the kline types.

$TYPEDSIGNATURES)

This function checks if the input symbol `s` is one of the following: `:index`, `:klines`, `:mark`, `:premium`. It returns `true` if `s` is one of these, and `false` otherwise.

"""
isklines(s) = s ∈ (:index, :klines, :mark, :premium)

@doc """ Updates the CDN_URL with the URL from the Binance data vision page.

$TYPEDSIGNATURES)

The function checks if the CDN_URL is empty. If it is, it sends a GET request to the Binance data vision page, parses the HTML response to find the CDN URL, and updates the CDN_URL with the found URL.

"""
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

@doc """ Constructs a URL for accessing Binance data.

$TYPEDSIGNATURES)

The function first calls `cdn!` to ensure the CDN_URL is updated. It then constructs a path using the provided keyword arguments and appends it to the CDN_URL. The "/" at the end of the URL is important as it ensures the query returns more than one element.

"""
function make_url(; kwargs...)
    cdn!()
    p = make_path(; kwargs...)
    # NOTE: the "/" at the end is important otherwise the query returns only 1 element
    URI(CDN_URL[]; query=("delimiter=/&" * "prefix=data/" * p * '/'))
end

@doc """ Constructs a URL for a specific symbol.

$TYPEDSIGNATURES)

This function first calls `make_url` with the provided keyword arguments to construct a base URL. It then appends the symbol and the current timeframe to the path of the URL, creating a URL specific to the symbol.

"""
function make_sym_url(sym; marker="", kwargs...)
    url = make_url(; kwargs...)
    sym_path = join((rstrip(url.query, '/'), sym, string(TF[])), '/')
    marker_query = !isempty(marker) ? "&marker=" * marker : ""
    URI(url; query=sym_path * '/' * marker_query)
end

@doc """ Retrieves a list of links for a specific symbol.

$TYPEDSIGNATURES)

This function first calls `make_sym_url` with the provided keyword arguments to construct a URL specific to the symbol. It then sends a GET request to this URL, parses the XML response, and extracts the links related to the symbol.

"""
function symlinkslist(s; kwargs...)
    url = make_sym_url(s; kwargs...)
    html = ez.parsexml(HTTP.get(url).body)
    links = ez.Node[]
    function chunk_url(el)
        e = ez.elements(el)[1]
        if e.name == "Key" && !endswith(e.content, "CHECKSUM")
            push!(links, e)
        end
    end
    for el in ez.elements(ez.elements(html.node)[1])
        el.name == "Contents" && chunk_url(el)
    end
    return links
end

@doc """ Retrieves a list of all symbols available for Binance.

$TYPEDSIGNATURES)

The function first checks if the symbols are cached. If not, it sends a GET request to the Binance URL, parses the XML response, and extracts all the symbols. The symbols are then cached for future use.

"""
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

@doc """ Fetches OHLCV data for a given file.

$TYPEDSIGNATURES)

The function constructs a URL for the file, fetches the data, and converts it into a DataFrame. It then renames the columns, adds a timestamp column, cleans up the data, and stores it in the output.

"""
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
@doc """ Fetches data for a specific symbol.

$TYPEDSIGNATURES)

The function first checks if the data for the symbol is cached. If not, it retrieves a list of links for the symbol and fetches the data for each link. The data is then processed and returned along with the last file fetched.

"""
function fetchsym(sym; reset, path_kws...)
    from = if reset
        ""
    else
        @something ca.load_cache(key_path(sym; path_kws...); raise=false) ca.load_cache(
            key_path(sym; freq=:monthly, withoutkws(:freq; kwargs=path_kws)...);
            raise=false,
        ) ""
    end
    if occursin("monthly", from) && path_kws[:freq] == :daily
        from = replace(from, "monthly" => "daily")
    end
    files = String[]
    while true
        # TODO: these lists should be cached (except the last)
        links = symlinkslist(sym; marker=from, path_kws...)
        this = scr.symfiles(links; by=x -> x.content, from)
        if isnothing(this) || isempty(this)
            break
        end
        append!(files, this)
        from = files[end]
    end
    isempty(files) && return (nothing, nothing)
    out = dofetchfiles(sym, files; func=fetch_ohlcv)
    (mergechunks(files, out), last(files))
end

@doc """ Generates a key for a given symbol.

$TYPEDSIGNATURES)

This function generates a key for a given symbol `sym` by combining it with the market type and kind of data. The market type and kind of data are obtained from the keyword arguments `:market` and `:kind`, respectively.

"""
key(sym; path_kws...) = begin
    mkt = get(path_kws, :market, "um")
    kind = get(path_kws, :kind, "klines")
    "$(sym)_$(mkt)_$(kind)"
end
key_path(sym; path_kws...) = joinpath(NAME, key(sym; path_kws...))
@doc """ Saves symbol data to disk.

$(TYPEDSIGNATURES)

`binancesave` persists the OHLCV data for a given symbol to disk. It uses the `save_ohlcv` function internally to achieve this. The `reset` parameter controls whether existing data should be overwritten.

"""
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

@doc """ Downloads and saves symbol data from Binance.

$(TYPEDSIGNATURES)

`binancedownload` gets symbol data from Binance and saves it to disk. It uses `fetchsym` to get the data and `binancesave` to persist it. If no symbols match the selection, the function throws an error.

!!! warning "Don't switch from `daily` to `monthly` freq"
    when switching from `daily` freq back to `monthly` freq it will re-download all `monthly` archives

"""
function binancedownload(syms; zi=zi[], quote_currency="usdt", reset=false, kwargs...)
    cdn!()
    path_kws = let kws = NamedTuple(filterkws(:market, :freq, :kind; kwargs))
        if !haskey(kws, :freq)
            (; kws..., freq=:monthly)
        else
            kws
        end
    end
    all_syms = binancesyms(; path_kws...)
    selected = selectsyms(syms, all_syms; quote_currency)
    if isempty(selected)
        throw(ArgumentError("No symbols found matching $syms"))
    end
    quit = Ref(false)
    @withpbar! selected desc = "Symbols" begin
        fetchandsave(s) = @except if !quit[]
            ohlcv, last_file = fetchsym(s; reset, path_kws...)
            if !(isnothing(ohlcv) || isnothing(last_file))
                binancesave(s, ohlcv; reset, path_kws...)
                ca.save_cache(key_path(s; path_kws...), last_file)
            else
                @debug "binance: download failed (or up to date)" sym = s last_file
            end
            @pbupdate!
        end "binance scraper" (quit[] = true)
        @acquire SEM asyncmap(fetchandsave, (s for s in selected), ntasks=WORKERS[])
    end
    nothing
end
@fromassets binancedownload

@argstovec binancedownload AbstractString

@doc """ Loads saved Binance symbol data.

$(TYPEDSIGNATURES)

`binanceload` retrieves saved OHLCV data for specified symbols. It uses `load_ohlcv` to load the data from disk. The symbols are selected using `selectsyms`, which matches against all available symbols.

"""
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
