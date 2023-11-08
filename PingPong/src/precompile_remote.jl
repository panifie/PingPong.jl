@preset let
    s = PingPong.Engine.strategy()
    @precomp @ignore begin
        tgstart!(s)
        tgclient(s)
    end
    cl = tgclient(s)
    text = "abc"
    chat_id = 123
    @precmop @ignore begin
        start(cl, s; text, chat_id)
        stop(cl, s; text, chat_id)
        status(cl, s; text, chat_id)
        daily(cl, s; text, chat_id)
        weekly(cl, s; text, chat_id)
        monthly(cl, s; text, chat_id)
        balance(cl, s; text, chat_id)
        asset(cl, s; text, chat_id)
        config(cl, s; text, chat_id)
        logs(cl, s; text, chat_id)
        set(cl, s; text, chat_id)
        get(cl, s; text, chat_id)
        tgstop!(s)
    end
end
