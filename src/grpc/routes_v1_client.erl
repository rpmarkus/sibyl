-module(routes_v1_client).

%% this file was generated by grpc

-export([get_routes/3]).

-type 'Empty'() :: #{}.

-type routing_v1() :: #{
    oui => integer(),
    owner => binary(),
    router_addresses => [binary()],
    filters => [binary()],
    subnets => [binary()]
}.

-type routing_v1_response() :: #{
    routes => [routing_v1()],
    signature => binary(),
    height => integer()
}.

-type routing_v1_update() :: #{
    route => routing_v1(),
    signature => binary(),
    height => integer(),
    action => binary()
}.

-export_type([
    'Empty'/0,
    routing_v1/0,
    routing_v1_response/0,
    routing_v1_update/0
]).

-spec decoder() -> module().
%% The module (generated by gpb) used to encode and decode protobuf
%% messages.
decoder() -> routes_v1.

%% RPCs for service routes_v1

-spec get_routes(
    Connection :: grpc_client:connection(),
    Message :: 'Empty'(),
    Options :: [
        grpc_client:stream_option()
        | {timeout, timeout()}
    ]
) -> grpc_client:unary_response(routing_v1_response()).
%% This is a unary RPC
get_routes(Connection, Message, Options) ->
    grpc_client:unary(
        Connection,
        Message,
        routes_v1,
        get_routes,
        decoder(),
        Options
    ).
