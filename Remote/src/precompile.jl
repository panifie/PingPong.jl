using .Misc.Lang: @preset, @precomp, @ignore

@preset let
    using Telegram.HTTP
    function closeconn_layer(handler)
        return function (req; kw...)
            HTTP.setheader(req, "Connection" => "close")
            return handler(req; kw...)
        end
    end
    HTTP.pushlayer!(closeconn_layer)
    LiveMode.ExchangeTypes.Python.py_start_loop()
    mod = LiveMode.st.BareStrat
    s = LiveMode.st.strategy(mod, Config(; mode=Live()))
    # NOTE: needs a telegram token bot
    ENV["TELEGRAM_BOT_TOKEN"] = "6911910250:AAERDZD9hc8e33_c63Wyw6xyWVXn_DhdHyU"
    chat_id = ENV["TELEGRAM_BOT_CHAT_ID"] = "-1001996551827"
    Remote.TIMEOUT[] = 1
    @precomp begin
        tgstart!(s)
        tgclient(s)
    end
    cl = tgclient(s)
    text = "abc123"
    @precomp @ignore begin
        @ignore start(cl, s; text, chat_id)
        @ignore stop(cl, s; text="now", chat_id)
        status(cl, s; text, chat_id)
        daily(cl, s; text, chat_id)
        weekly(cl, s; text, chat_id)
        monthly(cl, s; text, chat_id)
        balance(cl, s; text, chat_id)
        @ignore assets(cl, s; isinput=true, text, chat_id)
        @ignore config(cl, s; isinput=true, text, chat_id)
        logs(cl, s; isinput=true, text, chat_id)
        # can't be precompiled because rely on multiple getUpdates
        # set(cl, s; text, chat_id)
        # get(cl, s; text, chat_id)
        tgstop!(s)
    end
    stop!(s)
    empty!(TASK_STATE) # NOTE: Required to avod spurious errors
    HTTP.Connections.closeall()
    LiveMode.ExchangeTypes._closeall()
    Base.GC.gc(true) # trigger finalizer
    LiveMode.ExchangeTypes.Python.py_stop_loop()
end
