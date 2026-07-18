-module(fips_boot).
-export([verify/0]).

verify() ->
    case application:ensure_all_started(crypto) of
        {ok, _} -> ok;
        {error, Reason} -> fail({crypto_start_failed, Reason})
    end,
    Info = crypto:info(),
    State = {crypto:info_fips(),
             maps:get(link_type, Info, missing),
             maps:get(fips_provider_available, Info, false),
             maps:get(fips_provider_buildinfo, Info, missing)},
    case State of
        {enabled, static, true, BuildInfo} when is_list(BuildInfo) ->
            case string:find(BuildInfo, "3.1.2") of
                nomatch -> fail({unexpected_fips_provider, BuildInfo});
                _ -> ok
            end;
        _ ->
            fail({fips_invariant_failed, State, Info})
    end.

fail(Reason) ->
    io:format(standard_error, "FIPS startup check failed: ~tp~n", [Reason]),
    erlang:halt(78).
