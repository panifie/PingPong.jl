@preset let
    ExchangeTypes.Python.py_start_loop()
    mod = PingPong.Engine.Strategies.BareStrat
    s = PingPong.Engine.strategy(mod, Config())
    # NOTE: needs a telegram token bot
    rmt = Remote
    ENV["TELEGRAM_TOKEN_BOT"] = "6911910250:AAERDZD9hc8e33_c63Wyw6xyWVXn_DhdHyU"
    @precomp @ignore begin
        rmt.tgstart!(s)
        rmt.tgclient(s)
    end
    cl = rmt.tgclient(s)
    text = "abc"
    chat_id = 123
    @precomp @ignore begin
        rmt.start(cl, s; text, chat_id)
        rmt.stop(cl, s; text, chat_id)
        rmt.status(cl, s; text, chat_id)
        rmt.daily(cl, s; text, chat_id)
        rmt.weekly(cl, s; text, chat_id)
        rmt.monthly(cl, s; text, chat_id)
        rmt.balance(cl, s; text, chat_id)
        rmt.asset(cl, s; text, chat_id)
        rmt.config(cl, s; text, chat_id)
        rmt.logs(cl, s; text, chat_id)
        rmt.set(cl, s; text, chat_id)
        rmt.get(cl, s; text, chat_id)
        rmt.tgstop!(s)
    end
    ExchangeTypes.Python.py_stop_loop()
end
