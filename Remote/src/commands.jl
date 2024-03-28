using LiveMode.PaperMode: header
using LiveMode.Dates: format
using LiveMode.TimeTicks
using LiveMode: trades, raw, posside
using LiveMode.Instances: MarginInstance, NoMarginInstance, HedgedInstance
using LiveMode.Instances: DataFrame, committed, cash
using LiveMode.Instances.Data: Not
using .Misc.Lang: MatchString
using PrettyTables: pretty_table, tf_markdown
import Base: get

@doc """ Updates the short description of a strategy

$(TYPEDSIGNATURES)

This function updates the short description of a strategy based on its current status and the current date.
It checks if the strategy is running and sets the status accordingly.
The date is formatted in the "yy-mm-ddTH:M" format.
The updated description is then set as the short description of the strategy.

"""
function _set_info(cl, s)
    name = nameof(s)
    sts, k = if isrunning(s)
        "started", :is_start
    else
        "stopped", :is_stop
    end
    date = format(attr(s, k, now()), "yy-mm-ddTH:M")
    setMyShortDescription(cl; short_description="$(name) ($sts) $(date)")
end

function _init(cl, s)
    _set_info(cl, s)
end

@doc """ Starts a strategy

$(TYPEDSIGNATURES)

This function starts a strategy if it's not already running.
It sends a message indicating the start of the strategy and updates the strategy's total balance.
The function also updates the short description of the strategy.

"""
function start(cl::TelegramClient, s; text, chat_id, kwargs...)
    name = nameof(s)
    if isrunning(s)
        sendMessage(cl; text="""
        $YC Strategy already started: *$(name)*
        """, chat_id, parse_mode="markdown")
    else
        sendMessage(
            cl; text="$YC Starting strategy *$(name)* ...", chat_id, parse_mode="markdown"
        )
        start!(s)
        tot = st.current_total(s) |> cnum
        @sync begin
            @async sendMessage(
                cl; text="""$GC Strategy started: *$(name)*
                _balance: $(tot)_""", chat_id, parse_mode="markdown"
            )
            @async _set_info(cl, s)
        end
    end
    true
end

@doc """ Builds a keyboard layout

$(TYPEDSIGNATURES)

This function builds a keyboard layout with specified rows.
The keyboard layout is a `LittleDict` with keys `:keyboard`, `:one_time_keyboard`, and `:resize_keyboard`.

"""
function build_keyboard(rows=[["now", "1h", "1d"]])
    LittleDict(:keyboard => rows, :one_time_keyboard => true, :resize_keyboard => true)
end

@doc """ Stops a strategy

$(TYPEDSIGNATURES)

This function stops a strategy if it's currently running.
It sends a message indicating the stop of the strategy and updates the strategy's total balance.
The function also updates the short description of the strategy.

"""
function stop(cl::TelegramClient, s; text, chat_id, kwargs...)
    if !isrunning(s)
        sendMessage(cl; text="""
        $YC Strategy already stopped: *$(nameof(s))*
        """, chat_id, parse_mode="markdown")
    else
        delay = if text == "1h"
            Hour(1)
        elseif text == "1d"
            Day(1)
        elseif text == "now"
            Second(0)
        else
            sendMessage(cl; text="Choose delay", reply_markup=build_keyboard(), chat_id)
            return false
        end
        function dostop()
            sendMessage(
                cl;
                text="$YC stopping strategy *$(nameof(s))* ...",
                chat_id,
                parse_mode="markdown",
            )
            stop!(s)
            tot = st.current_total(s) |> cnum
            @sync begin
                @async sendMessage(
                    cl;
                    text="""$RC Strategy stopped: *$(nameof(s))*
                _balance: $(tot)_""",
                    chat_id,
                    parse_mode="markdown",
                )
                @async _set_info(cl, s)
            end
        end
        @async (sleep(delay); dostop())
    end
    true
end

@doc """ Provides the status of a strategy

$(TYPEDSIGNATURES)

This function retrieves the status of a strategy, including the throttle, number of assets, and a detailed status report.
The status report is generated by calling the `show` function on the strategy with a custom `price_func`.

"""
function status(cl::TelegramClient, s; text, chat_id, kwargs...)
    thr = throttle(s)
    n_assets = length(s.universe)
    first_a = first(s.universe).asset.raw
    last_a = last(s.universe).asset.raw
    sts = let buf = IOBuffer()
        try
            show(buf, s; price_func=lm.lastprice)
            String(take!(buf))
        finally
            Base.close(buf)
        end
    end
    text = """$BC Strategy
    $sts
    throttle: $thr
    assets: *$(n_assets)* (`$(first_a)`..`$(last_a)`)
    """
    sendMessage(cl; text, chat_id, parse_mode="markdown")
    true
end

@doc """ Provides rolling statistics for a strategy

$(TYPEDSIGNATURES)

This function generates rolling statistics for a strategy over a specified period.
It calculates the number of trades and the balance for each asset in the strategy's universe within the period.

"""
function _rolling(cl::TelegramClient, s; period, text, chat_id)
    io = IOBuffer()
    try
        cur = nameof(s.cash)
        for ai in s.universe
            asset_trades = trades(ai)
            idx = findfirst(t -> t.date >= now() - period, asset_trades)
            n_trades, balance = if idx isa Number
                (length(asset_trades) - (length(asset_trades) - idx)),
                sum(t.size for t in @view(asset_trades[idx:end]))
            else
                0, 0.0
            end
            write(
                io,
                if balance > ZERO
                    UA
                elseif balance == ZERO
                    LRA
                else
                    DA
                end,
                " ",
                "*",
                raw(ai),
                "*",
                "\n",
                "_",
                string(n_trades),
                " trades ",
                "(",
                cnum(balance),
                " ",
                cur,
                ")",
                "_",
                "\n",
            )
        end
        sendMessage(cl; text=String(take!(io)), chat_id, parse_mode="markdown")
    finally
        Base.close(io)
    end
    true
end

function daily(cl::TelegramClient, s; text, chat_id, kwargs...)
    _rolling(cl, s; period=Day(1), text, chat_id)
end
function weekly(cl::TelegramClient, s; text, chat_id, kwargs...)
    _rolling(cl, s; period=Day(7), text, chat_id)
end
function monthly(cl::TelegramClient, s; text, chat_id, kwargs...)
    _rolling(cl, s; period=Day(30), text, chat_id)
end

_ai_cash(ai, func) = abs(something(func(ai), ZERO))
function _ai_cash(ai::HedgedInstance, func)
    abs(something(func(ai, Long()), ZERO)) + abs(something(func(ai, Short()), ZERO))
end
total_cash(ai) = _ai_cash(ai, cash)
comm_cash(ai) = _ai_cash(ai, committed)
@doc """ Provides the balance of a strategy

$(TYPEDSIGNATURES)

This function retrieves the balance of a strategy, including the total and used balance for each asset in the strategy's universe.
The balances are presented in a DataFrame.

"""
function balance(cl::TelegramClient, s; text, chat_id, kwargs...)
    df = DataFrame()
    for ai in s.universe
        total = total_cash(ai)
        used = comm_cash(ai)
        push!(df, (; asset=raw(ai), total, used))
    end
    push!(df, (; asset=string(nameof(cash(s))), total=cash(s), used=committed(s)))
    io = IOBuffer()
    try
        write(io, "```")
        pretty_table(io, df; tf=tf_markdown)
        write(io, "```")
        sendMessage(cl; text=String(take!(io)), chat_id, parse_mode="markdown")
    finally
        Base.close(io)
    end
    true
end

@doc """ Builds a grid layout

$(TYPEDSIGNATURES)

This function builds a grid layout with specified rows and columns.
The grid layout is a list of lists, where each list represents a row in the grid.

"""
function build_grid(arr; by=identity, ncols=3)
    urow, rem = divrem(length(arr), ncols)
    nrows = urow + ifelse(rem > 0, 1, 0)
    type = typeof(by(first(arr)))
    out = [type[] for _ in 1:nrows]
    iter = Iterators.Stateful(arr)
    for n in 1:nrows
        col = out[n]
        for _ in (1:ncols)
            v = iterate(iter)
            isnothing(v) && break
            push!(col, by(v[1]))
        end
    end
    out
end

@doc """ Provides information about the assets of a strategy

$(TYPEDSIGNATURES)

This function retrieves information about the assets of a strategy.
If the function is called without input, it prompts the user to choose an asset.
If an asset is chosen, it provides detailed information about the asset, including recent trades and positions.

"""
function assets(cl::TelegramClient, s; text, chat_id, isinput, kwargs...)
    if !isinput
        sendMessage(
            cl;
            text="Choose asset",
            reply_markup=build_keyboard(build_grid(s.universe; by=raw)),
            chat_id,
        )
        return false
    else
        sym = text
        ai = s[MatchString(sym)]
        ai_trades = trades(ai)
        n_trades = length(ai_trades)
        io = IOBuffer()
        try
            if n_trades > 0
                df = DataFrame(t for t in @view(ai_trades[(end-min(n_trades, 3)):end]))
                df[!, :side] = posside.(df.order)
                df[!, :date] = [string(compact(now() - date), " ago") for date in df.date]
                @debug "tg asset: " df
                write(io, "```")
                pretty_table(
                    io,
                    @view df[:, [:amount, :price, :size, :side, :date]];
                    tf=tf_markdown,
                )
                write(io, "```\n")
            end
            if ai isa MarginInstance
                anyopen = false
                for pos in (Long, Short)
                    if isopen(ai, pos)
                        anyopen = true
                        show(io, position(ai, pos))
                    end
                end
                if !anyopen
                    write(io, "No positions open for ", sym)
                end
            else
                show(io, cnum(cash(ai)))
            end
            sendMessage(cl; text=String(take!(io)), chat_id, parse_mode="markdown")
        finally
            Base.close(io)
        end
    end
    true
end

_issecret(v) = occursin(r"token|secret|pass|psw|key|auth|private"i, v)

function _redact(arr::T) where {T<:AbstractArray}
    for n in 1:length(arr)
        el = arr[n]
        if _issecret(el)
            arr[n] = "[redacted]"
        end
    end
    arr
end
@doc """ Redacts sensitive information from an array or dictionary

$(TYPEDSIGNATURES)

This function redacts sensitive information from an array or dictionary.
It replaces any element or value that matches a set of predefined sensitive keywords with the string "[redacted]".

"""
function _redact(dict::T) where {T<:AbstractDict}
    for k in keys(dict)
        v = dict[k]
        if _issecret(k)
            dict[k] = "[redacted]"
            try
                _redact(pairs(v))
            catch
            end
        elseif v isa Union{AbstractDict,AbstractArray}
            _redact(v)
        end
    end
    dict
end

@doc """ Provides the configuration of a strategy

$(TYPEDSIGNATURES)

This function retrieves the configuration of a strategy.
It redacts sensitive information from the configuration before presenting it.

"""
function config(cl::TelegramClient, s; text, chat_id, isinput, kwargs...)
    io = IOBuffer()
    try
        JSON3.pretty(
            io,
            _redact(copy(s.config.toml)),
            JSON3.AlignmentContext(; alignment=:Colon, indent=2),
        )
        sendMessage(cl; text=String(take!(io)), chat_id)
    finally
        Base.close(io)
    end
    true
end

@doc """ Provides the logs of a strategy

$(TYPEDSIGNATURES)

This function retrieves the logs of a strategy.
If the strategy has a valid logfile path, it sends the last 1000 lines of the logfile to the user.

"""
function logs(cl::TelegramClient, s; text, chat_id, isinput, kwargs...)
    io = IOBuffer()
    try
        file = attr(s, :logfile, nothing)
        if isnothing(file) || !(file isa String) || !ispath(file)
            sendMessage(cl; text="can't find logfile", chat_id)
            return true
        end
        n = 1
        for line in readlines(file)
            write(io, line, "\n")
            n += 1
            n >= 1000 && break
        end
        name = "$(nameof(s))[$(nameof(exchange(s)))]@$(now()).log"
        sendDocument(cl; document=name => io, chat_id)
    finally
        Base.close(io)
    end
    true
end

@doc """ Retrieves a message from the user

$(TYPEDSIGNATURES)

This function retrieves a message from the user.
It waits for a specified timeout and returns the message if one is received within the timeout period.

"""
function _get_msg(cl, subj; chat_id, offset)
    failed(what) = sendMessage(cl; text="$(RC) $what (resend request)", chat_id)
    messages = getUpdates(cl; offset=offset[], timeout=10)
    if isempty(messages)
        failed("input timedout ($subj)")
        return nothing
    end
    msg_idx = findfirst(messages) do msg
        get(msg, :update_id, -1) >= offset[]
    end
    msg = if isnothing(msg_idx)
        failed("no $subj submitted")
        return nothing
    else
        messages[msg_idx]
    end
    k = try
        msg[:message][:text]
    catch
    end
    if isnothing(k)
        failed("invalid $subj")
        return nothing
    end
    update_offset!(offset, msg)
    return k
end

remove_keyboard() = JSON3.write(LittleDict(:remove_keyboard => true))
@doc """ Prompts the user to insert a key

$(TYPEDSIGNATURES)

This function prompts the user to insert a key for a strategy.
It sends a message to the user with a list of suggested keys.

"""
function _ask_key(cl, s; chat_id)
    sugg = [string(k) for k in keys(s.attrs)]
    sendMessage(
        cl; text="Insert key", chat_id, reply_markup=build_keyboard(build_grid(sugg))
    )
end

@doc """ Updates a key-value pair in a strategy's configuration

$(TYPEDSIGNATURES)

This function prompts the user to insert a key and a value.
It then updates the strategy's configuration with the provided key-value pair.
If the value's type doesn't match the existing value's type, it sends a failure message.

"""
function set(cl::TelegramClient, s; text, chat_id, kwargs...)
    _ask_key(cl, s; chat_id)
    offset = _get_state(s).offset
    offset[] += 1
    k = _get_msg(cl, "key"; chat_id, offset)
    isnothing(k) && return true
    sendMessage(cl; text="Insert value", chat_id, reply_markup=remove_keyboard())
    v = _get_msg(cl, "value"; chat_id, offset)
    isnothing(v) && return true
    prev_v = attr(s, k, nothing)
    sendMessage(cl; text="""$YC Updating key:
    key: $k
    from: $prev_v
    to $v""")
    s[k] = let parsed = tryparse(typeof(prev_v), v)
        if isnothing(parsed) && !isnothing(prev_v)
            sendMessage(cl; text="$RC update failed type conversion")
            return true
        end
    end
    sendMessage(cl; text="$GC update successful")
    true
end

@doc """ Retrieves a key's value from a strategy's configuration

$(TYPEDSIGNATURES)

This function prompts the user to insert a key for a strategy.
It then retrieves the value of the provided key from the strategy's configuration.

"""
function get(cl::TelegramClient, s; text, chat_id, kwargs...)
    _ask_key(cl, s; chat_id)
    offset = _get_state(s).offset
    offset[] += 1
    k = _get_msg(cl, "key"; chat_id, offset)
    isnothing(k) && return true
    symk = Symbol(k)
    if haskey(s.attrs, symk)
        sendMessage(cl; text=s[symk], chat_id)
    elseif haskey(s.attrs, k)
        sendMessage(cl; text=s[k], chat_id)
    else
        sendMessage(cl; text="Key $k not found", chat_id)
    end
end