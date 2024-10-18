using LiveMode
using LiveMode.st
using LiveMode: st
using LiveMode.Misc
using Telegram, Telegram.API, Telegram.JSON3, Telegram.HTTP
const lm = LiveMode
const ect = lm.Executors
using .Misc.Lang: @lget!, @debug_backtrace, Option, @ifdebug
using .Misc: LittleDict
using .ect: cnum

@doc """ The `TaskState` type is used to store the state of a task. """
const TaskState = NamedTuple{(:task, :offset, :running),Tuple{Task,Ref{Int},Ref{Bool}}}
@doc "Holds the Telegram clients for each strategy."
const CLIENTS = LittleDict{UInt64,Any}()
@doc "Holds the task states for each strategy."
const TASK_STATE = IdDict{Strategy,TaskState}()
@doc "The timeout in seconds for the Telegram API requests."
const TIMEOUT = Ref(20)
@doc "Active clients"
const RUNNING = LittleDict{TelegramClient, Task}()

include("emojis.jl")
include("commands.jl")

@doc """ Creates or retrieves a Telegram client for a given strategy.

$(TYPEDSIGNATURES)

This function checks if a Telegram client for the provided strategy already exists. If it does, the function retrieves it. If it doesn't, the function creates a new Telegram client. The Telegram token and chat_id are retrieved from the strategy attributes or from environment variables. If these are not found, an error is thrown.
"""
function tgclient(token, args...; kwargs...)
    @lget! CLIENTS hash(token) TelegramClient(token, args...; kwargs...)
end

@doc """ Transforms a given key into a Telegram environment variable.

$(TYPEDSIGNATURES)

This function takes a key as input and transforms it into a corresponding Telegram environment variable. If the key starts with "tg", it removes the "tg" prefix before transforming it into an uppercase string prefixed with "TELEGRAM_BOT_".
"""
_envvar(k) = begin
    v = string(k)
    if startswith(v, "tg")
        v = split(v, "tg")[2]
    end
    "TELEGRAM_BOT_$(uppercase(v))"
end

function _getoption(s, k)
    @something attr(s, Symbol(k), nothing) attr(s, string(k), nothing) get(
        ENV, _envvar(k), nothing
    ) missing
end

@doc """ Retrieves or creates a Telegram client for a strategy.

$(TYPEDSIGNATURES)

The function first checks if a Telegram client for the provided strategy already exists. If it does, the function retrieves it. If it doesn't, the function creates a new Telegram client. The Telegram token and chat_id are retrieved from the strategy attributes or from environment variables. If these are not found, an error is thrown.
"""
function tgclient(s::Strategy)
    @lget! s.attrs :tgclient begin
        token = _getoption(s, :tgtoken)
        if ismissing(token)
            error(
                "tg: Telegram token not found, either use env var `$(_envvar(:tgtoken))` \
                or the `tgtoken` key in the strategy config file"
            )
        end
        chat_id = _getoption(s, :tgchat_id)
        if ismissing(chat_id)
            error(
                "tg: Telegram chat_id not found, either use env var `$(_envvar(:tgchat_id))` \
                or the `tg_chatid` key in the strategy config file",
            )
        end
        tgclient(token; chat_id)
    end
end

@doc """ Generates a list of Telegram commands.

$(TYPEDSIGNATURES)

This function generates a list of Telegram commands with their descriptions. The commands include operations like starting and stopping the strategy, showing summaries and histories, showing current balance, showing trades history by asset, showing toml config, uploading most recent logs, setting and getting a strategy attribute.
"""
function tgcommands()
    (
        (; command="start", description="start the strategy"),
        (; command="stop", description="stop the strategy"),
        (; command="status", description="show summary"),
        (; command="daily", description="rolling 1d history"),
        (; command="weekly", description="rolling 7d history"),
        (; command="monthly", description="rolling 30d history"),
        (; command="balance", description="show current balance"),
        (; command="assets", description="trades history by asset"),
        (; command="config", description="show toml config"),
        (; command="logs", description="upload most recent logs"),
        (; command="set", description="set a strategy attribute"),
        (; command="get", description="get a strategy attribute"),
    ) |> JSON3.write
end

@doc """ Sends an error message for an invalid command.

$(TYPEDSIGNATURES)

This function sends a message to the user indicating that the command they attempted to use is invalid.
"""
function invalid(cl, text, chat_id)
    sendMessage(cl; text=string("invalid command: ", text), chat_id)
end
@doc """ Creates an asynchronous task for handling Telegram messages.

$(TYPEDSIGNATURES)

This function creates an asynchronous task that listens for incoming Telegram messages. It checks the username of the sender and only processes the message if the username matches the one specified in the strategy. It also handles command execution and maintains the state of the last executed command.
"""
function tgtask(cl, s, running::Ref{Bool}, offset::Ref{Int})
    @async begin
        let t = get(RUNNING, cl, nothing)
            if t isa Task && !istaskdone(t)
                @warn "remote: existing task for this telegram bot, stopping it"
                prev_strat = t.storage[:strategy]
                tgstop!(prev_strat)
                wait(t)
                @warn "remote: stopped previous task" prev_strat
            end
        end
        task_local_storage(:strategy, s)
        RUNNING[cl] = current_task()
        user = _getoption(s, :tgusername)
        if !(user isa String) || isempty(user)
            @warn "tg: no telegram user name set (bot will refuse to reply) \
            either use env var `$(_envvar(:tgusername))` \
            or the `tgusername` key in the strategy config file"
        end
        running[] = true
        f_last = Ref{Option{Function}}(nothing)
        f_resp = Ref(false)
        _init(cl, s)
        tgrun(cl; offset) do msg
            @debug "tg: new message" msg
            running[] || throw(InterruptException())
            message = get(msg, :message, nothing)
            isnothing(message) && return nothing
            text = get(message, :text, "")
            chat = get(message, :chat, nothing)
            isnothing(chat) && return nothing
            chat_id = get(chat, :id, nothing)
            isnothing(chat_id) && return nothing
            from = get(message, :from, (;))
            msg_user = @coalesce get(from, :username, "") ""
            if ismissing(user) || msg_user != user
                sendMessage(
                    cl;
                    text="User $msg_user not allowed, please send the magic pass.",
                    chat_id,
                )
                return nothing
            end

            call_f(f, isinput) = begin
                ans = f(cl, s; text, chat_id, isinput)
                f_resp[], f_last[] = if ans isa Bool && !ans
                    (true, f)
                else
                    (false, nothing)
                end
            end

            if startswith(text, "/")
                spl = split(text, "/")
                cmd = Symbol(replace(spl[2], r"@.*" => ""))
                if isdefined(@__MODULE__, cmd)
                    try
                        @debug "tg: calling command" cmd
                        call_f(eval(cmd), false)
                    catch err
                        err isa InterruptException && rethrow()
                        sendMessage(cl; text=string(err), chat_id)
                        @debug_backtrace
                    end
                else
                    invalid(cl, text, chat_id)
                end
            elseif f_last[] isa Function
                @debug "tg: calling previous command" cmd = f_last[] text
                call_f(f_last[], true)
            else
                invalid(cl, text, chat_id)
            end
        end
    end
end

function _get_state(s)
    get(TASK_STATE, s, nothing)
end

function _get_task(s)
    try
        TASK_STATE[s].task
    catch
    end
end

@doc """ Starts a Telegram client for a given strategy.

$(TYPEDSIGNATURES)

This function checks if a Telegram client for the provided strategy already exists and is running. If it does, the function retrieves it. If it doesn't, the function creates a new Telegram client and starts it. The Telegram token and chat_id are retrieved from the strategy attributes or from environment variables. If these are not found, an error is thrown.
"""
function tgstart!(s::Strategy)
    cl = tgclient(s)
    state = _get_state(s)
    state = if isnothing(state) || istaskdone(state.task)
        setMyCommands(cl; commands=tgcommands())
        if isnothing(state)
            running = Ref(false)
            offset = Ref(-1)
            (task=tgtask(cl, s, running, offset), offset, running)
        else
            if !istaskdone(state.task)
                tgstop!(s)
            end
            (
                task=tgtask(cl, s, state.running, state.offset),
                offset=state.offset,
                state.running,
            )
        end
    else
        state
    end
    TASK_STATE[s] = state
end

@doc """ Stops a Telegram client for a given strategy.

$(TYPEDSIGNATURES)

This function checks if a Telegram client for the provided strategy is running. If it is, the function stops it and throws an InterruptException to the task associated with the client.
"""
function tgstop!(s::Strategy)
    state = _get_state(s)
    if state isa TaskState && !istaskdone(state.task)
        state.running[] = false
        try
            @async Base.throwto(state.task, InterruptException())
            wait(state.task)
        catch
        end
    end
end

@doc """ Updates the offset if the current message's update_id is greater.

$(TYPEDSIGNATURES)

This function checks if the current message's update_id is greater than the current offset. If it is, the function updates the offset to be one more than the update_id.
"""
update_offset!(offset, msg) =
    if offset[] <= get(msg, :update_id, -1)
        offset[] = get(msg, :update_id, -1) + 1
    end

@doc """ Runs the Telegram bot with error handling.

$(TYPEDSIGNATURES)

This function runs the Telegram bot in a loop, processing incoming messages. If an error occurs, it is logged and the loop continues. If an InterruptException is thrown, the loop breaks.
"""
function tgrun(
    f, tg::TelegramClient=Telegram.DEFAULT_OPTS.client; timeout=TIMEOUT[], offset=Ref(-1)
)
    while true
        try
            ignore_errors = true
            res = if offset[] == -1
                getUpdates(tg; timeout=timeout)
            else
                (ignore_errors = false; getUpdates(tg; timeout=timeout, offset=offset[]))
            end
            # @ifdebug Main.e = res
            for msg in res
                try
                    f(msg)
                    update_offset!(offset, msg)
                catch err
                    if err isa InterruptException
                        rethrow()
                    else
                        @error err
                        @debug_backtrace
                    end
                    update_offset!(offset, msg)
                end
            end
        catch err
            if err isa InterruptException || (
                err isa HTTP.HTTPError &&
                hasproperty(err, :error) &&
                err.error isa InterruptException
            )
                break
            else
                @error "tg: error" exception = err
                @debug_backtrace
            end
        end
    end
end

function _closeall()
    for state in values(TASK_STATE)
        if state isa TaskState && !istaskdone(state.task)
            state.running[] = false
            try
                @async Base.throwto(state.task, InterruptException())
                wait(state.task)
            catch
            end
        end
    end
end
