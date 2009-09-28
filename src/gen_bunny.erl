%% The MIT License

%% Copyright (c) David Reid <dreid@dreid.org>, Andy Gross <andy@andygross.org>

%% Permission is hereby granted, free of charge, to any person obtaining a copy
%% of this software and associated documentation files (the "Software"), to deal
%% in the Software without restriction, including without limitation the rights
%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%% copies of the Software, and to permit persons to whom the Software is
%% furnished to do so, subject to the following conditions:

%% The above copyright notice and this permission notice shall be included in
%% all copies or substantial portions of the Software.

%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
%% THE SOFTWARE.

%% @doc The gen_bunny RabbitMQ consumer behavior.
-module(gen_bunny).
-author('Andy Gross <andy@andygross.org>').
-author('David Reid <dreid@dreid.org').
-behavior(gen_server).
-include_lib("gen_bunny.hrl").

-export([start_link/4]).
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).
-export([behaviour_info/1]).

-export([call/2,
         call/3,
         cast/2]).

-export([get_connection/1,
         get_channel/1,
         get_consumer_tag/1,
         stop/1]).

-record(state, {mod,
                modstate,
                channel,
                connection,
                queue,
                declare_info,
                consumer_tag}).

behaviour_info(callbacks) ->
    [{init, 1},
     {handle_message, 2},
     {handle_call, 3},
     {handle_cast, 2},
     {handle_info, 2},
     {terminate, 2}];
behaviour_info(_) ->
    undefined.

start_link(Module, ConnectionInfo, DeclareInfo, InitArgs)
  when is_atom(ConnectionInfo) orelse is_tuple(ConnectionInfo),
       is_binary(DeclareInfo) orelse is_tuple(DeclareInfo),
       is_list(InitArgs) ->
    gen_server:start_link(
      ?MODULE,
      [Module, ConnectionInfo, DeclareInfo, InitArgs],
      []).

call(Name, Request) ->
    gen_server:call(Name, Request).

call(Name, Request, Timeout) ->
    gen_server:call(Name, Request, Timeout).

cast(Dest, Request) ->
    gen_server:cast(Dest, Request).


init([Module, ConnectionInfo, DeclareInfo, InitArgs0]) ->
    {NoAck, InitArgs1} = get_opt(no_ack, InitArgs0, true),
    {ConnectFun, InitArgs2} = get_opt(connect_fun, InitArgs1,
                                      fun bunny_util:connect/1),
    {DeclareFun, InitArgs3} = get_opt(declare_fun, InitArgs2,
                                      fun bunny_util:declare/2),
    case Module:init(InitArgs3) of
        {ok, ModState} ->
            case connect_declare_subscribe(
                   ConnectFun, DeclareFun,
                   ConnectionInfo, DeclareInfo, NoAck) of
                {ok, ConnectionPid, ChannelPid, QueueName} ->
                    %% TODO:  monitor channel/connection pids?
                    {ok, #state{mod=Module,
                                modstate=ModState,
                                channel=ChannelPid,
                                connection=ConnectionPid,
                                declare_info=DeclareInfo,
                                queue=QueueName}};
                {_ErrClass, {error, Reason}} ->
                    Module:terminate(Reason, ModState),
                    {stop, Reason}
            end;
        Error ->
            Error
    end.

stop(Pid) when is_pid(Pid) ->
    gen_server:cast(Pid, stop).

get_connection(Pid) when is_pid(Pid) ->
    gen_server:call(Pid, get_connection).

get_channel(Pid) when is_pid(Pid) ->
    gen_server:call(Pid, get_channel).

get_consumer_tag(Pid) when is_pid(Pid) ->
    gen_server:call(Pid, get_consumer_tag).

handle_call(get_connection, _From, State=#state{connection=Connection}) ->
    {reply, Connection, State};
handle_call(get_channel, _From, State=#state{channel=Channel}) ->
    {reply, Channel, State};
handle_call(get_consumer_tag, _From, State=#state{consumer_tag=CTag}) ->
    {reply, CTag, State};
handle_call(Request, From, State=#state{mod=Module, modstate=ModState}) ->
    case Module:handle_call(Request, From, ModState) of
        {reply, Reply, NewModState} ->
            {reply, Reply, State#state{modstate=NewModState}};
        {reply, Reply, NewModState, A} when A =:= hibernate orelse is_number(A) ->
            {reply, Reply, State#state{modstate=NewModState}, A};
        {noreply, NewModState} ->
            {noreply, State#state{modstate=NewModState}};
        {noreply, NewModState, A} when A =:= hibernate orelse is_number(A) ->
            {noreply, State#state{modstate=NewModState}, A};
        {stop, Reason, NewModState} ->
            {stop, Reason, State#state{modstate=NewModState}};
        {stop, Reason, Reply, NewModState} ->
            {stop, Reason, Reply, State#state{modstate=NewModState}}
  end.

handle_cast(stop, State=#state{channel=Channel, consumer_tag=CTag, connection=Connection}) ->
    ok = lib_amqp:unsubscribe(Channel, CTag),
    ok = lib_amqp:teardown(Connection, Channel),
    {stop, normal, State};
handle_cast(Msg, State=#state{mod=Module, modstate=ModState}) ->
    case Module:handle_cast(Msg, ModState) of
        {noreply, NewModState} ->
            {noreply, State#state{modstate=NewModState}};
        {noreply, NewModState, A} when A =:= hibernate orelse is_number(A) ->
            {noreply, State#state{modstate=NewModState}, A};
        {stop, Reason, NewModState} ->
            {stop, Reason, State#state{modstate=NewModState}}
    end.

handle_info({#'basic.deliver'{},
            {content, _ClassId, _Props, _PropertiesBin, [Payload]}},
            State=#state{mod=Module, modstate=ModState}) ->
    %% TODO: figure out what fields we want to expose from the 'P_basic' record
    %% TODO: decode_properties is failing for me - do we even need to do this?
    %%#'P_basic'{} = rabbit_framing:decode_properties(ClassId, PropertiesBin),
    case Module:handle_message(Payload, ModState) of
        {noreply, NewModState} ->
            {noreply, State#state{modstate=NewModState}};
        {noreply, NewModState, A} when A =:= hibernate orelse is_number(A) ->
            {noreply, State#state{modstate=NewModState}, A};
        {stop, Reason, NewModState} ->
            {stop, Reason, State#state{modstate=NewModState}}
    end;
handle_info(#'basic.consume_ok'{consumer_tag=CTag}, State=#state{}) ->
    {noreply, State#state{consumer_tag=CTag}};
handle_info(Info, State=#state{mod=Module, modstate=ModState}) ->
    case Module:handle_info(Info, ModState) of
        {noreply, NewModState} ->
            {noreply, State#state{modstate=NewModState}};
        {noreply, NewModState, A} when A =:= hibernate orelse is_number(A) ->
            {noreply, State#state{modstate=NewModState}, A};
        {stop, Reason, NewModState} ->
            {stop, Reason, State#state{modstate=NewModState}}
    end.


terminate(Reason, #state{mod=Mod, modstate=ModState}) ->
    io:format("gen_bunny terminating with reason ~p~n", [Reason]),
    Mod:terminate(Reason, ModState),
    ok.

code_change(_OldVersion, State, _Extra) ->
    %% TODO:  support code changes?
    {ok, State}.

%% TODO: better error handling here.
connect_declare_subscribe(ConnectFun, DeclareFun,
                          ConnectionInfo, DeclareInfo, NoAck) ->
    %% TODO: link?
    case catch ConnectFun(ConnectionInfo) of
        {'EXIT', {Reason, _Stack}} ->
            Reason;
        {ConnectionPid, ChannelPid} when is_pid(ConnectionPid),
                                         is_pid(ChannelPid) ->
            case catch DeclareFun(ChannelPid, DeclareInfo) of
                {'EXIT', {Reason, _Stack}} ->
                    Reason;
                {_Exchange, Queue} when ?is_queue(Queue) ->
                    QueueName = bunny_util:get_name(Queue),
                    lib_amqp:subscribe(ChannelPid,
                                       QueueName,
                                       self(), NoAck),
                    {ok, ConnectionPid, ChannelPid, QueueName}
            end
    end.

get_opt(Opt, Proplist) ->
    get_opt(Opt, Proplist, undefined).

get_opt(Opt, Proplist, Default) ->
    {proplists:get_value(Opt, Proplist, Default),
     proplists:delete(Opt, Proplist)}.


%%
%% Tests
%%

-include_lib("eunit/include/eunit.hrl").

cds_setup() ->
    {ok, _} = mock:mock(lib_amqp),
    ok.

cds_stop(_) ->
    mock:verify_and_stop(lib_amqp),
    ok.


cds_expects(_DummyConn, DummyChannel, NoAck) ->
    mock:expects(lib_amqp, subscribe,
                 fun({Chan, <<"cds.test">>, _Pid, NA})
                    when Chan =:= DummyChannel,
                         NA =:= NoAck ->
                         true
                 end,
                 ok),
    ok.

cds_funs(DummyConn, DummyChannel) ->
    ConnectFun = fun(direct) ->
                         {DummyConn, DummyChannel}
                 end,

    DeclareFun = fun(Chan, <<"cds.test">>) when Chan =:= DummyChannel ->
                         {bunny_util:new_exchange(<<"cds.test">>),
                          bunny_util:new_queue(<<"cds.test">>)}
                 end,

    {ConnectFun, DeclareFun}.


cds_test_() ->
    DummyConn = c:pid(0,0,0),
    DummyChannel = c:pid(0,0,1),
    {ConnectFun, DeclareFun} = cds_funs(DummyConn, DummyChannel),

    {setup, fun cds_setup/0, fun cds_stop/1,
     ?_test(
        [begin
             cds_expects(DummyConn, DummyChannel, false),
             connect_declare_subscribe(ConnectFun, DeclareFun,
                                       direct, <<"cds.test">>, false)
         end])}.


cds_noack_test_() ->
    DummyConn = c:pid(0,0,0),
    DummyChannel = c:pid(0,0,1),
    {ConnectFun, DeclareFun} = cds_funs(DummyConn, DummyChannel),

    {setup, fun cds_setup/0, fun cds_stop/1,
     ?_test(
        [begin
             cds_expects(DummyConn, DummyChannel, true),
             connect_declare_subscribe(ConnectFun, DeclareFun,
                                       direct, <<"cds.test">>, true)
         end])}.


cds_conn_error_test_() ->
    ConnectFun = fun(direct) ->
                         {'EXIT', {{blah, "You suck"}, []}}
                 end,

    {setup, fun cds_setup/0, fun cds_stop/1,
     ?_test(
        [begin
             ?assertEqual(
                {blah, "You suck"},
                connect_declare_subscribe(ConnectFun, fun() -> ok end,
                                          direct, <<"cds.test">>, true))
         end])}.


cds_declare_error_test_() ->
    DummyConn = c:pid(0,0,0),
    DummyChannel = c:pid(0,0,1),
    {ConnectFun, _} = cds_funs(DummyConn, DummyChannel),

    DeclareFun = fun(Chan, <<"cds.test">>) when Chan =:= DummyChannel ->
                         {'EXIT', {{blah, "I declare that you suck"}, []}}
                 end,

    {setup, fun cds_setup/0, fun cds_stop/1,
     ?_test(
        [begin
             ?assertEqual(
                {blah, "I declare that you suck"},
                connect_declare_subscribe(ConnectFun, DeclareFun,
                                          direct, <<"cds.test">>, true))
         end])}.
