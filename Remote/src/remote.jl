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

const TaskState = NamedTuple{(:task, :offset, :running),Tuple{Task,Ref{Int},Ref{Bool}}}
const CLIENTS = LittleDict{UInt64,Any}()
const TASK_STATE = IdDict{Strategy,TaskState}()
const TIMEOUT = Ref(20)

include("emojis.jl")
include("commands.jl")

function tgclient(token, args...; kwargs...)
    @lget! CLIENTS hash(token) TelegramClient(token, args...; kwargs...)
end

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

function invalid(cl, text, chat_id)
    sendMessage(cl; text=string("invalid command: ", text), chat_id)
end
function tgtask(cl, s, running::Ref{Bool}, offset::Ref{Int})
    @async begin
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
            msg_user = get(from, :username, "")
            if msg_user != user
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
                cmd = Symbol(spl[2])
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

update_offset!(offset, msg) =
    if offset[] <= get(msg, :update_id, -1)
        offset[] = get(msg, :update_id, -1) + 1
    end

@doc "Same as `Telegram.run_bot` but rethrows interrupts in the inner loop"
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
            if err isa InterruptException ||
                err isa HTTP.RequestError && err.error isa InterruptException
                break
            else
                @error err
                @debug_backtrace
            end
        end
    end
end
