using .Python: pyin

function resptobool(::Exchange, resp)
    if resp isa Exception
        @error "exchange: exception" exception = resp @caller
        false
    elseif applicable(haskey, resp, "code")
        if pyisTrue(@py haskey(resp, "code"))
            @py resp["code"] in (0, 200, "0", "200")
        elseif pyisTrue(@py haskey(resp, "msg"))
            @py "success" in resp["msg"]
        else
            @error "no matching key in response (default to false)" resp @caller
            false
        end
    else
        @error "exchange: unexpected value" resp @caller
        false
    end
end

function resptobool(::Exchange{<:eids(:binance, :binanceusdm, :binancecoin)}, resp)
    if resp isa Exception
        @error "exchange: exception" exception = resp @caller
        false
    elseif applicable(haskey, resp, "code")
        if haskey(resp, "code")
            @py resp["code"] in (0, 200, -4046)
        elseif haskey(resp, "msg")
            @py "success" in resp["msg"]
        else
            @error "exchange: no matching key in response (default to false)" resp @caller
            false
        end
    else
        @error "exchange: unexpected value" resp @caller
        false
    end
end
