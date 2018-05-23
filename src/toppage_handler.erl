-module(toppage_handler).

-export([init/2]).
-export([handle/2]).
-export([terminate/2]).

-type request() :: cowboy_req:req().
-type headers() :: cowboy:http_headers().
-type processor() :: fun((binary()) -> binary()).
-type finalizer() :: fun(() -> binary()).
-type streamfunc() :: fun((any()) -> ok | { error, atom() }).
-type ibrowse_options() :: [{atom(), any()}].
-type rewrite_rules() :: [{any(), string()}].

-record(callbacks, {
        processor :: processor(),
        finalizer :: finalizer(),
        stream_next :: streamfunc(),
        stream_close :: streamfunc()
    }).

-record(state, {
        this_node :: binary(),
        enable_gzip :: boolean(),
        rewrite_rules :: rewrite_rules(),
        ibrowse_options :: ibrowse_options(),
        callbacks :: #callbacks{}
    }).

-define(SECRET_PROXY_HEADER, <<"x-erlang-http-proxy">>).
-define(HACKER_REDIRECT_PAGE, <<"http://www.fbi.gov/">>).

% copy-pasted from /usr/lib/erlang/lib/erts-5.9.1/src/zlib.erl
-define(MAX_WBITS, 15).

init(Req, _Opts) ->
    lager:log(info, "~p Initializing...", [self()]),
    { ok, EnableGzip } = application:get_env(http_proxy, enable_gzip, {ok, false}),
    AcceptGzip =
        case cowboy_req:header(<<"accept-encoding">>, Req) of
            undefined -> false;
            AcceptEncoding ->
                lists:any(
                    fun(X) -> X == "gzip" end,
                    string:tokens(
                        lists:filter(
                            fun(X) -> X =/= 16#20 end,
                            binary_to_list(AcceptEncoding)
                        ), ","
                    )
                )
        end, 
    State = #state {
        enable_gzip = EnableGzip andalso AcceptGzip,
        this_node = this_node(),
        rewrite_rules = init_rewrite_rules(),
        ibrowse_options = init_ibrowse_options(),
        callbacks = init_default_callbacks()
    },
    handle(Req, State).

handle(
        Req,
        #state {
            ibrowse_options = IBrowseOptions,
            rewrite_rules = RewriteRules,
            this_node = ThisNode
        } = State) ->
    Headers = cowboy_req:headers(Req),
    Method = cowboy_req:method(Req),
    {ok, Body, _} = readbody(Req, <<>>),
    Url = case cowboy_req:header(?SECRET_PROXY_HEADER, Req) of
            ThisNode ->
                {Peer, _} =  cowboy_req:peer(Req),
                lager:log(warning, "~p Recursive request from ~p!", [self(), Peer]),
                ?HACKER_REDIRECT_PAGE;
            undefined -> 
                ReqUrl = binary:list_to_bin(lists:flatten(cowboy_req:uri(Req))),
                RewriteResult = apply_rewrite_rules(ReqUrl, RewriteRules),
                case ReqUrl == RewriteResult of
                    true -> ok;
                    false ->
                        lager:log(info, "~p Request URL: ~s", [self(), ReqUrl])
                end,
                RewriteResult
        end,
    lager:log(info, "~p Fetching ~s", [self(), Url]),
    ModifiedHeaders = modify_req_headers(Headers, ThisNode),
    {ibrowse_req_id, _RequestId} = ibrowse:send_req(
        binary_to_list(Url),
        headers_cowboy_to_ibrowse(ModifiedHeaders),
        req_type_cowboy_to_ibrowse(Method),
        Body,
        IBrowseOptions,
        infinity
    ),

    FinalReq = receive_loop(State, Req),
    lager:log(info, "~p Done", [self()]),
    {ok, FinalReq, State}.

terminate(_Req, _State) ->
    ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec readbody(request(), string()) -> {ok, string(), request()}.
readbody (Req0, Acc) ->
    case cowboy_req:read_body(Req0) of
	    {ok, Data, Req} -> {ok, << Acc/binary, Data/binary >>, Req};
	    {more, Data, Req} -> readbody(Req, << Acc/binary, Data/binary >>)
end.

-spec init_rewrite_rules() -> rewrite_rules().
init_rewrite_rules() ->
    { ok, RewriteRules } = application:get_env(http_proxy, rewrite_rules, {ok, []}),
    lists:map(
        fun({ReString,ReplaceString}) ->
            {ok, CompiledRe} = re:compile(ReString),
            {CompiledRe, ReplaceString}
        end,
        RewriteRules
    ).

-spec init_ibrowse_options() -> ibrowse_options().
init_ibrowse_options() ->
    { ok, SyncStream } = application:get_env(http_proxy, sync_stream, {ok, false}),
    OptionsTemplate = [{ response_format, binary }],
    case SyncStream of
        true ->
            [ {stream_to, {self(), once}} | OptionsTemplate ];
        false ->
            { ok, ChunkSize } = application:get_env(
                http_proxy, stream_chunk_size, {ok, 4096}),
            OptionsTemplate ++ [
                { stream_to, self() },
                { stream_chunk_size, ChunkSize }
            ]
    end.

-spec init_default_callbacks() -> #callbacks{}.
init_default_callbacks() -> 
    { ok, SyncStream } = application:get_env(http_proxy, sync_stream, {ok, false}),
    CallbacksTemplate = #callbacks {
            processor = fun(X) -> X end,
            finalizer = fun() -> <<>> end,
            stream_next = fun(_ReqId) -> ok end,
            stream_close = fun(_ReqId) -> ok end
        },
    case SyncStream of
        true ->
            CallbacksTemplate#callbacks {
                stream_next = fun(ReqId) -> ibrowse:stream_next(ReqId) end,
                stream_close = fun(ReqId) -> ibrowse:stream_close(ReqId) end
            };
        false ->
            CallbacksTemplate
    end.

receive_loop(
        #state { 
            enable_gzip = EnableGzip,
            callbacks = #callbacks {
                processor = Processor,
                finalizer = Finalizer,
                stream_next = StreamNext,
                stream_close = StreamClose
            } = Callbacks
        } = State,
        Req) ->
    receive
        { ibrowse_async_headers, RequestId, Code, IBrowseHeaders } ->
            ok = StreamNext(RequestId),
            Headers = headers_ibrowse_to_cowboy(IBrowseHeaders),
            ModifiedHeaders = modify_res_headers(Headers),

            { NewHeaders, NewCallbacks} = 
                case EnableGzip of
                    true ->
                        optional_add_gzip_compression(
                            ModifiedHeaders, Callbacks
                        );
                    false ->
                        { ModifiedHeaders, Callbacks }
                end,
            NewReq = send_headers(Req, Code, NewHeaders),
            receive_loop(State#state { callbacks = NewCallbacks }, NewReq);
        { ibrowse_async_response, RequestId, Data } ->
            ok = StreamNext(RequestId),
            ok = send_chunk(Req, nofin, Processor(Data)),
            receive_loop(State, Req);

        { ibrowse_async_response_end, RequestId } ->
            ok = StreamClose(RequestId),
            ok = send_chunk(Req, fin, Finalizer()),
            Req 
    end.

-spec send_chunk(request(), boolean(), binary()) -> ok | {error, atom()}.
send_chunk(Req, IsFin, Data) ->
    case Data of
        <<>> -> ok;
        _ ->
            cowboy_req:stream_body(Data, IsFin, Req)
    end.

-spec apply_rewrite_rules(binary(), rewrite_rules()) -> binary().
apply_rewrite_rules(Url, []) ->
    Url;
apply_rewrite_rules(Url, [{CompiledRe,ReplaceString}|OtherRules]) ->
    ApplyResult = re:replace(Url, CompiledRe, ReplaceString),
    case is_list(ApplyResult) of
        true -> iolist_to_binary(ApplyResult);
        false -> apply_rewrite_rules(Url, OtherRules)
    end.

-spec optional_add_gzip_compression(headers(), #callbacks{}) -> { headers(), #callbacks{} }.
optional_add_gzip_compression(Headers, Callbacks) ->
    case proplists:get_value(<<"content-encoding">>, Headers) of 
        undefined ->
            lager:log(debug, "~p Using gzip compression", [self()]),
            ZlibStream = zlib:open(),
            ok = zlib:deflateInit(ZlibStream, default, deflated, 16+?MAX_WBITS, 8, default),
            {
                 [ {<<"content-encoding">>, <<"gzip">>} | Headers ],
                 Callbacks#callbacks {
                     processor =
                     fun(<<>>) -> <<>>;
                        (Data) ->
                         iolist_to_binary(
                             zlib:deflate(ZlibStream, Data, sync)
                         )
                     end,
                     finalizer = fun() ->
                         Data = iolist_to_binary(
                              zlib:deflate(ZlibStream, <<>>, finish)
                         ),
                         ok = zlib:deflateEnd(ZlibStream),
                         ok = zlib:close(ZlibStream),
                         Data
                     end
                }
            };
        _Other ->
            { Headers, Callbacks }
    end.

-spec send_headers(request(), string(), headers()) -> { ok, request() }.
send_headers(Req, Code, Headers) ->
    lager:log(info, '~p', Headers),
    NewReq = cowboy_req:set_resp_headers(Headers, Req),
    cowboy_req:stream_reply(list_to_integer(Code), NewReq).

-spec modify_req_headers(headers(), binary()) -> headers().
modify_req_headers(Headers, ThisNode) ->
    FilteredHeaders = maps:filter(
        fun(<<"proxy-connection">>, _) -> false;
           (?SECRET_PROXY_HEADER, _) -> false;
           (<<"host">>, _) -> false;
           (_, _) -> true
        end,
        Headers
    ),
    maps:put(?SECRET_PROXY_HEADER, ThisNode, FilteredHeaders).

-spec modify_res_headers(headers()) -> headers().
modify_res_headers(Headers) ->
    maps:filter(
        fun(<<"date">>, _) -> false;
           (<<"transfer-encoding">>, _) -> false;
           (<<"connection">>, _) -> false;
           (<<"server">>, _) -> false;
           (<<"content-length">>, _) -> false;
           (_, _) -> true
        end,
        Headers
    ).

-spec req_type_cowboy_to_ibrowse(binary()) -> get | head | post.
req_type_cowboy_to_ibrowse(RequestBinary) ->
    case string:to_lower(binary_to_list(RequestBinary)) of
        "post" -> post;
        "head" -> head;
         _Other -> get
    end.

-spec headers_ibrowse_to_cowboy([{string(),string()}]) -> headers().
headers_ibrowse_to_cowboy(Headers) ->
	maps:from_list(Headers).

-spec headers_cowboy_to_ibrowse(headers()) -> [{string(),string()}].
headers_cowboy_to_ibrowse(Headers) ->
	maps:to_list(Headers).

-spec this_node() -> binary().
this_node() ->
    [Node, Host] = string:tokens(atom_to_list(node()), "@"),
    iolist_to_binary([Node, "/", Host]).
