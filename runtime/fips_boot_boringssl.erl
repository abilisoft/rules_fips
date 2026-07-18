-module(fips_boot_boringssl).
-compile({nowarn_deprecated_function, [{crypto, enable_fips_mode, 1}]}).
-export([verify/0]).

verify() ->
    case application:ensure_all_started(crypto) of
        {ok, _} -> ok;
        {error, Reason} -> fail({crypto_start_failed, Reason})
    end,
    Info = crypto:info(),
    State = {crypto:info_fips(),
             maps:get(link_type, Info, missing),
             maps:get(cryptolib_version_compiled, Info, missing),
             maps:get(cryptolib_version_linked, Info, missing)},
    case State of
        {enabled, static, Compiled, Linked}
          when is_list(Compiled), is_list(Linked) ->
            case {string:find(Compiled, "BoringSSL"),
                  string:find(Linked, "BoringSSL")} of
                {nomatch, _} -> fail({unexpected_compiled_library, Compiled});
                {_, nomatch} -> fail({unexpected_linked_library, Linked});
                _ -> ok
            end;
        _ ->
            fail({fips_invariant_failed, State, Info})
    end,
    case crypto:enable_fips_mode(false) of
        false -> ok;
        Other -> fail({fips_disable_was_not_rejected, Other})
    end,
    case crypto:info_fips() of
        enabled -> ok;
        OtherState -> fail({fips_state_changed, OtherState})
    end,
    try crypto:hash(md5, <<"rules_fips">>) of
        Md5Result -> fail({md5_was_not_rejected, Md5Result})
    catch
        error:{notsup, _, _} -> ok
    end.

fail(Reason) ->
    io:format(standard_error, "FIPS startup check failed: ~tp~n", [Reason]),
    erlang:halt(78).
