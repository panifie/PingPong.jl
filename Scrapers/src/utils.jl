@doc """ Selects symbols from a list based on given criteria

$(TYPEDSIGNATURES)

The `selectsyms` function takes in a list of symbols and a list of all symbols. It also accepts optional parameters `quote_currency` and `perps_only`.
The function filters the symbols based on the `quote_currency` and whether they are perpetual contracts (`perps_only`).
The function returns a set of selected symbols.

"""
function selectsyms(syms, all_syms; quote_currency="usdt", perps_only=true)
    mysyms = Set{String}()
    all_syms_set = Set(all_syms)
    for s in syms
        if s in all_syms_set
            push!(mysyms, s)
        else
            @debug "scrapers: symbol not found" s
        end
    end
    qc = uppercase(quote_currency)
    selected = Set(uppercase.(syms))
    all = isempty(selected)
    rgx = Regex("(.*?)($qc)")
    for s in all_syms
        m = match(rgx, s)
        isnothing(m) && continue
        sym = ifelse(perps_only, split(s, '_')[1], s)
        (all || m[1] ∈ selected) && push!(mysyms, sym)
    end
    mysyms
end

@doc """ Adjusts the number of workers in the Scrapers module """
function workers!(n)
    prev = WORKERS[]
    WORKERS[] = n
    SEM[] = Base.Semaphore(n)
    @info "Workers count set from $prev to $n"
end
@doc """ Sets the time frame in the TimeTicks module """
function TimeTicks.timeframe!(s)
    prev = TF[]
    TF[] = timeframe(s)
    @info "TimeFrame set from $prev to $(TF[])"
end

gzipdecode(v) = zlib.transcode(zlib.GzipDecompressor, v)
zipdecode(v) = begin
    buf = IOBuffer(v)
    try
        r = zip.Reader(buf)
        try
            return read(r.files[1])
        finally
            close(r)
        end
    finally
        close(buf)
    end
end

@doc """ Fetches a file from a given URL and decodes it

$(TYPEDSIGNATURES)

The `fetchfile` function takes in a URL and an optional decoding function `dec`.
It fetches the file from the URL and decodes the file content using the `dec` function.
The function returns the decoded file content.

"""
function fetchfile(url; dec=gzipdecode)
    resp = HTTP.get(url)
    dec(resp.body)
end

@doc """ Returns a subset of links based on a given condition

$(TYPEDSIGNATURES)

The `symfiles` function takes in a list of links and optional parameters `by` and `from`.
It applies the `by` function to each link and returns a subset of links starting from the link that matches the `from` condition.

"""
function symfiles(links; by=identity, from=nothing)
    download_from = 1
    if !isnothing(from)
        for (n, l) in enumerate(links)
            if by(l) == from
                download_from = n + 1
                break
            end
        end
    end
    download_from > length(links) && return nothing
    map(by, @view(links[download_from:end]))
end

@doc """ Converts a CSV file to a DataFrame

$(TYPEDSIGNATURES)

The `csvtodf` function takes in a CSV file `v` and an optional list of columns `cols`.
It reads the CSV file and selects the specified columns, returning the result as a DataFrame.

"""
csvtodf(v, cols=nothing) = CSV.read(v, DataFrame; select=cols)

@doc """ Converts the timestamp column of a DataFrame

$(TYPEDSIGNATURES)

The `timestamp!` function takes in a DataFrame `df` and an optional conversion function `conv`.
It applies the conversion function to the timestamp column of the DataFrame and updates the timestamp column with the converted values.
The function returns the updated DataFrame.

"""
function timestamp!(df::DataFrame, conv=unix2datetime)
    df[!, :timestamp] = apply.(TF[], conv.(df.timestamp))
    df
end

@doc """ Converts trade data to OHLCV format

$(TYPEDSIGNATURES)

The `trades_to_ohlcv` function takes in a DataFrame `df` and an optional conversion function `conv`.
It first converts the timestamp column of the DataFrame using the `conv` function.
Then, it converts the trade data to OHLCV (Open, High, Low, Close, Volume) format.
Finally, it cleans up the OHLCV data based on the time frame.

"""
trades_to_ohlcv(df, conv=unix2datetime) = begin
    timestamp!(df, conv)
    ohlcv = tra.to_ohlcv(df)
    cleanup_ohlcv_data(ohlcv, TF[])
end

@doc """ Ensures continuity of OHLCV data across multiple DataFrames

$(TYPEDSIGNATURES)

The `glue_ohlcv` function takes in a dictionary `out` of DataFrames.
It iterates over the DataFrames in `out` and ensures that the timestamps are continuous across DataFrames.
If a gap is found, it fills the gap with trailing data from the previous DataFrame.

"""
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

@doc """ Returns the appropriate temporary directory path based on the operating system """
_tempdir() = Base.Sys.isunix() ? "/tmp" : tempdir()

@doc """ Merges chunks of data from multiple files

$(TYPEDSIGNATURES)

The `mergechunks` function takes in a list of files and a dictionary `out` of DataFrames.
It checks if all chunks have been downloaded, logs an error if not, and returns `nothing`.
If all chunks are present, it sorts the DataFrames in `out`, ensures their timestamps are continuous, and merges them into a single DataFrame.

"""
function mergechunks(files, out; strict=false)
    if strict && length(out) == length(files)
        @error "Couldn't download all chunks! $(length(out)) < $(length(files))"
        return nothing
    end
    sorted = sort(out)
    glue_ohlcv(sorted)
    merged = vcat(values(sorted)...)
    @ifdebug _contiguous_ts(merged.timestamp, timefloat(TF[]))
    merged
end

@doc """ Fetches files asynchronously and applies a function to each file

$(TYPEDSIGNATURES)

The `dofetchfiles` function takes in a symbol `sym`, a list of files, a function `func`, and optional keyword arguments.
It fetches the files asynchronously and applies the function `func` to each file.
The function returns a dictionary of DataFrames.

"""
function dofetchfiles(sym, files; func, kwargs...)
    out = Dict{DateTime,DataFrame}()
    @withpbar! files desc = sym begin
        quit = Ref(false)
        @acquire SEM begin
            # NOTE: func must accept a kw arg `out`
            dofetch(file) =
                if !quit[]
                    @except begin
                        func(sym, file; out, kwargs...)
                        @pbupdate!
                    end "chunk error for $file" (quit[] = true)
                end
            asyncmap(dofetch, files; ntasks=WORKERS[])
        end
    end
    return out
end

@doc """ Extracts symbols and quote currency from a list of assets

$(TYPEDSIGNATURES)

The `fromassets` function takes in a list of assets and extracts the symbols and quote currency from each asset.
It returns a dictionary with the symbols and quote currency.

"""
function fromassets(aa::AbstractVector{<:AbstractAsset})
    syms = string.(bc.(aa))
    quote_currency = let qsyms = qc.(aa)
        @assert length(Set(qsyms)) == 1 "All assets should have the same quote currency"
        string(first(qsyms))
    end
    (; syms, quote_currency)
end

@doc """ Swaps the function name in an expression

$(TYPEDSIGNATURES)

The `swapfname!` function takes in an expression `ex`, an index `idx`, and a function name `fname`.
If `ex` is a symbol, it replaces the symbol at `idx` in `ex` with `fname`.
If `ex` is not a symbol, it replaces the last argument of `ex` at `idx` with a quoted `fname`.

"""
function swapfname!(ex, idx, fname)
    if ex isa Symbol
        ex[idx] = fname
    else
        ex[idx].args[end] = QuoteNode(fname)
    end
end

@doc """ Extracts symbols and quote currency from a list of assets

$(TYPEDSIGNATURES)

The `fromassets` function takes in a list of assets and extracts the symbols and quote currency from each asset.
It returns a dictionary with the symbols and quote currency.

"""
macro fromassets(fname)
    mod = __module__
    this = @__MODULE__
    ex = quote
        function $mod.func(aa::AbstractVector{<:AbstractAsset}; kwargs...)
            _, kwargs = $this.splitkws(:quote_currency; kwargs)
            syms, quote_currency = $this.fromassets(aa)
            $mod.func(syms; quote_currency, kwargs...)
        end
    end
    swapfname!(ex.args[2].args[1].args, 1, fname)
    swapfname!(ex.args[2].args[2].args[7].args, 1, fname)
    ex
end
