using Core: LineInfoNode
# using .Misc: config_path
using Engine.Strategies: strategy!, SortedDict
using Engine.Misc: config_path, TOML, user_dir
using Engine.Misc.Lang: @lget!
using MacroTools
using MacroTools: postwalk
using REPL.TerminalMenus

@doc "Ask for a strategy name."
ask_name(name=nothing) = begin
    name = @something name Base.prompt("Strategy name: ")
    string(name) |> uppercasefirst
end

@doc """ Path of `to` relative to `path`. """
function relative_path(to, path, offset=2)
    to_dir = dirname(to) |> basename
    splits = splitpath(path)
    for (n, c) in enumerate(Iterators.reverse(splits))
        if c == to_dir
            return joinpath(splits[(end - n + offset):end]...)
        end
    end
    path
end

_menu(arr) =
    let idx = request(RadioMenu(arr; pagesize=5))
        arr[idx]
    end
@doc """ Interactively asks the user to configure a strategy.

$(TYPEDSIGNATURES)

This function prompts the user to select options for the timeframe, exchange, quote currency, and margin mode.
It then creates and returns a configuration object based on the user's selections.
"""
function _askconfig(; kwargs...)
    println("\nTimeframe:")
    min_timeframe = _menu(["1m", "5m", "15m", "1h", "1d"])
    println("\nSelect exchange by:")
    excby = _menu(["volume", "markets", "nokyc"])
    exs = if excby == "volume"
        ["binance", "bitforex", "okx", "xt", "coinbase"]
    elseif excby == "markets"
        ["yobit", "gateio", "binance", "hitbtc", "kucoin"]
    else
        ["bitrue", "phemex", "hitbtc", "coinex", "latoken"]
    end
    println()
    exchange = _menu(exs)
    println("\nQuote currency:")
    qc = _menu(["USDT", "USDC", "BTC", "ETH", "DOGE"]) |> Symbol
    println("\nMargin mode:")
    mm = _menu(["NoMargin", "Isolated"]) |> Symbol
    margin = eval(:($mm))()
    Config(; min_timeframe, exchange, qc, margin, kwargs...)
end

@doc """ Checks if `name` is a valid strategy name. """
function isvalidname(name)
    occursin(r"^([a-zA-Z_][a-zA-Z0-9_]*(\.[a-zA-Z_][a-zA-Z0-9_]*)*)$", string(name))
end
@doc """ Generates a new strategy with a given name and configuration.

$(TYPEDSIGNATURES)

This function creates a new strategy with a given name and configuration.
It prompts the user for necessary information, creates a new project, and sets up the environment for the strategy.
It also updates the user's configuration file with the new strategy's information.
"""
function _generate_strategy(
    name=nothing,
    cfg=nothing;
    user_config_path=config_path(),
    ask=true,
    load=true,
    deps=String[],
    kwargs...,
)
    user_path = realpath(user_config_path) |> dirname
    if !isfile(user_config_path)
        if Base.prompt(
            "User config file at $user_config_path not found, create new one? [y]/n"
        ) != "n"
            mkpath(user_path)
            touch(user_config_path)
        end
    end
    strategies_path = joinpath(user_path, "strategies")
    mkpath(strategies_path)
    local strat_name, strat_dir
    while true
        strat_name = ask_name(name)
        if !isvalidname(strat_name)
            @error "Strategy name should not have special chars"
            continue
        end
        strat_dir = joinpath(strategies_path, strat_name)
        if isdir(strat_dir) || isfile(joinpath(strategies_path, string(strat_name, ".jl")))
            @error "Strategy with name $strat_name already exists"
            continue
        end
        break
    end
    cfg = @something cfg ask ? _askconfig(; kwargs...) : Config(; kwargs...)
    strat_sym = Symbol(strat_name)
    Pkg.generate(strat_dir; io=devnull)
    if ask && Base.prompt("\nActivate strategy project at $(strat_dir)? [y]/n") != "n"
        Pkg.activate(strat_dir; io=devnull)
    end
    if ask
        deps_list = Base.prompt("\nAdd project dependencies (comma separated)")
        append!(deps, split(deps_list, ","; keepempty=false))
    end
    if !isempty(deps)
        prev = Base.active_project()
        try
            Pkg.activate(strat_dir; io=devnull)
            Pkg.add(deps)
        catch e
            @error e
        end
        Pkg.activate(prev)
        println()
    end
    strat_file = copy_template!(strat_name, strat_dir, strategies_path; cfg)
    user_config = TOML.parsefile(user_config_path)
    if haskey(user_config, strat_name)
        @warn "Deleting conflicting config entry for $strat_name"
        delete!(user_config, strat_name)
    end
    let sources = @lget! user_config "sources" Dict{String,Any}()
        strat_cfg = Dict(
            "include_file" => relative_path(strat_dir, strat_file, 3),
            "margin" => repr(typeof(cfg.margin)),
            "mode" => "Sim",
        )
        strat_project_file = joinpath(strat_dir, "Project.toml")
        strat_project_toml = TOML.parsefile(strat_project_file)
        strat_project_toml["strategy"] = strat_cfg
        open(strat_project_file, "w") do f
            TOML.print(f, strat_project_toml)
        end
        if strat_name in keys(sources)
            @warn "Overwriting source entry for $strat_name"
        end
        sources[strat_name] = relative_path(user_config_path, strat_project_file)
        cfg.sources = SortedDict(Symbol(k) => v for (k, v) in sources)
        cfg.path = realpath(strat_project_file)
        open(user_config_path, "w") do f
            TOML.print(f, SortedDict(user_config))
        end
        @info "Config file updated"
    end
    if (ask && Base.prompt("\nLoad strategy? [y]/n") != "n") || (!ask && load)
        if !isdefined(Main, :Revise)
            if Base.prompt("\n Load revise before loading the strategy? [y]/n") != "n"
                @eval Main using Revise
            end
        end
        config!("strategy"; cfg, cfg.path)
        strategy!(strat_sym, cfg)
    end
end

function generate_strategy(args...; kwargs...)
    try
        _generate_strategy(args...; kwargs...)
    catch e
        if e isa InterruptException
            print("CTRL-C Interrupted")
        else
            rethrow(e)
        end
    end
end

@doc """ Copies a template to create a new strategy file

$(TYPEDSIGNATURES)

This function takes a strategy name, directory, and path along with a configuration object.
It reads a template file and modifies it according to the provided configuration.
The modified template is then written to a new strategy file in the specified directory.
The function returns the path to the newly created strategy file.

"""
function copy_template!(strat_name, strat_dir, strat_path; cfg)
    tpl_file = joinpath(strat_path, "Template.jl")
    @assert isfile(tpl_file) "Template file not found at $strat_path"

    tpl_expr = Meta.parse(read(tpl_file, String))
    @info "New Strategy" name = strat_name exchange = cfg.exchange timeframe = string(
        cfg.min_timeframe
    )
    tpl_expr = postwalk(
        x -> @capture(x, module name_
        body__
        end) ? :(module $(Symbol(strat_name))
        $(body...)
        end) : x, tpl_expr
    )
    tpl_expr = postwalk(
        x -> @capture(x, DESCRIPTION = v_) ? :(DESCRIPTION = $(strat_name)) : x, tpl_expr
    )
    tpl_expr = postwalk(x -> if @capture(x, EXC = v_)
        :(EXC = $(QuoteNode(cfg.exchange)))
    else
        x
    end, tpl_expr)
    tpl_expr = postwalk(
        x -> @capture(x, MARGIN = v_) ? :(MARGIN = $(typeof(cfg.margin))) : x, tpl_expr
    )
    tpl_expr = postwalk(
        x -> @capture(x, TF = v_) ? :(TF = @tf_str($(string(cfg.min_timeframe)))) : x,
        tpl_expr,
    )

    rmlinums!(tpl_expr)
    strat_file = joinpath(strat_dir, "src", string(strat_name, ".jl"))
    open(strat_file, "w") do f
        src = string(tpl_expr)
        src = replace(src, r"#=.*=#\s*" => "")
        print(f, src)
    end
    return strat_file
end

@doc """ Removes line numbers from an expression

$(TYPEDSIGNATURES)

This function traverses an expression and removes any `LineNumberNode` or `LineInfoNode` instances it encounters.
It also skips any macro calls to prevent unwanted side effects.
The function modifies the expression in-place and returns the modified expression.

"""
function rmlinums!(expr)
    if expr isa LineNumberNode || expr isa LineInfoNode
        return missing
    end
    if hasproperty(expr, :head) && expr.head == :macrocall
        return expr
    end
    if hasproperty(expr, :args)
        args = expr.args
        n = 1
        while n <= length(args)
            if ismissing(rmlinums!(args[n]))
                deleteat!(args, n)
            else
                n += 1
            end
        end
    end
    expr
end

function _confirm_del(where)
    Base.prompt("Really delete strategy located at $(where)? [n]/y") == "y"
end

@doc """ Removes a strategy based on the provided name or path

$(TYPEDSIGNATURES)

This function takes a strategy name or path as input.
If the input is a valid path, it deletes the strategy located at that path.
If the input is a valid strategy name, it deletes the strategy with that name.
The function also prompts the user for confirmation before deleting a strategy.

"""
function remove_strategy(subj=nothing)
    where = @something subj Base.prompt("Strategy name (or project path): ")
    strat_name = ""
    if ispath(where)
        rp = if endswith(where, ".toml")
            dirname(where)
        else
            where
        end |> realpath
        if _confirm_del(rp)
            rm(rp; recursive=true)
            strat_name = if endswith(where, ".toml")
                basename(dirname(rp))
            else
                splitext(basename(where))[1]
            end
            @info "Strategy removed"
        else
            @info "Removal canceled"
        end
    else
        udir = user_dir()
        file_strat = joinpath(udir, string(where, ".jl"))
        if isfile(file_strat)
            if _confirm_del(file_strat)
                rm(file_strat)
                strat_name = where
                @info "Strategy removed"
            else
                @info "Removal canceled"
            end
        else
            proj_strat = joinpath(udir, "strategies", string(where))
            if isdir(proj_strat)
                if _confirm_del(proj_strat)
                    rm(proj_strat; recursive=true)
                    strat_name = where
                    @info "Strategy removed"
                else
                    @info "Removal canceled"
                end
            else
                @error "Input is neither a project path nor a strategy name" input = where
            end
        end
    end
    _delete_strat_entry(strat_name)
end

@doc """ Deletes a strategy entry from the user configuration

$(TYPEDSIGNATURES)

This function takes a strategy name as input.
If the name is not empty, it prompts the user for confirmation to remove the corresponding entry from the user configuration.
If confirmed, it deletes the strategy entry from the user configuration and the sources dictionary, if it exists.
The updated configuration is then written back to the configuration file.

"""
function _delete_strat_entry(name)
    if !isempty(name)
        if Base.prompt("Remove user config entry $name? [n]/y") == "y"
            cp = config_path()
            user_config = TOML.parsefile(cp)
            delete!(user_config, name)
            sources = get(user_config, "sources", (;))
            if sources isa AbstractDict
                delete!(sources, name)
            end
            open(cp, "w") do f
                TOML.print(f, SortedDict(user_config))
            end
        end
    end
end
