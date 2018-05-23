#!/bin/sh

export ERL_CRASH_DUMP_SECONDS=1

erl \
  -name http_proxy@`hostname` \
  -pa ebin deps/*/ebin \
  -config app.config \
  -eval 'lists:foreach(fun(App) -> ok = application:start(App) end, [ crypto, asn1, public_key, ssl, ranch, cowlib, cowboy, ibrowse, http_proxy ])'
