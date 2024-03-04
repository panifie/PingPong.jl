using .Python: pyin

function resptobool(::Exchange, resp)
    if haskey(resp, "code")
        pyeq(Bool, resp["code"], @pyconst("0"))
    elseif haskey(resp, "msg")
        @py "success" in resp["msg"]
    else
        @error "no matching key in response (default to false)" resp
        false
    end
end

function resptobool(::Exchange{<:eids(:binance, :binanceusdm, :binancecoin)}, resp)
    if haskey(resp, "code")
        @py resp["code"] in ("0", "1", "-4046")
    elseif haskey(resp, "msg")
        @py "success" in resp["msg"]
    else
        @error "no matching key in response (default to false)" resp
        false
    end
end
