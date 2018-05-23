PROJECT = http_proxy
PROJECT_DESCRIPTION = Erlang Http Proxy
PROJECT_VERSION = 0.1.0

DEPS=cowboy ibrowse
dep_cowboy_commit = 2.4.0
dep_ibrowse_commit = v4.4.0

include erlang.mk
