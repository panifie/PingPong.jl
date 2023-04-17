function selectsyms(syms, all_syms; quote_currency="usdt", perps_only=true)
    qc = uppercase(quote_currency)
    selected = Set(uppercase.(syms))
    mysyms = Set{String}()
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

function workers!(n)
    prev = WORKERS[]
    WORKERS[] = n
    SEM[] = Base.Semaphore(n)
    @info "Workers count set from $prev to $n"
end
function timeframe!(s)
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

function fetchfile(url; dec=gzipdecode)
    resp = HTTP.get(url)
    dec(resp.body)
end

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

csvtodf(v, cols=nothing) = CSV.read(v, DataFrame; select=cols)

function timestamp!(df::DataFrame, conv=unix2datetime)
    df[!, :timestamp] = apply.(TF[], conv.(df.timestamp))
    df
end

trades_to_ohlcv(df, conv=unix2datetime) = begin
    timestamp!(df, conv)
    ohlcv = tra.to_ohlcv(df)
    cleanup_ohlcv_data(ohlcv, TF[])
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

_tempdir() = Base.Sys.isunix() ? "/tmp" : tempdir()

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

function dofetchfiles(sym, files; func, kwargs...)
    out = Dict{DateTime,DataFrame}()
    @withpbar! files desc = sym begin
        @acquire SEM begin
            # NOTE: func must accept a kw arg `out`
            dofetch(file) = begin
                try
                    func(sym, file; out, kwargs...)
                catch e
                    @ifdebug begin
                        @warn "chunk $file couldn't be parsed."
                        @warn e
                    end
                end
                @pbupdate!
            end
            asyncmap(dofetch, files; ntasks=WORKERS[])
        end
    end
    return out
end

function fromassets(aa::AbstractVector{<:AbstractAsset})
    syms = string.(bc.(aa))
    quote_currency = let qsyms = qc.(aa)
        @assert length(Set(qsyms)) == 1 "All assets should have the same quote currency"
        string(first(qsyms))
    end
    (; syms, quote_currency)
end

function swapfname!(ex, idx, fname)
    if ex isa Symbol
        ex[idx] = fname
    else
        ex[idx].args[end] = QuoteNode(fname)
    end
end

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
