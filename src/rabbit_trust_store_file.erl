%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% Copyright (c) 2007-2016 Pivotal Software, Inc.  All rights reserved.
%%

-module(rabbit_trust_store_file).
-behaviour(gen_server).

%% API
-export([start_link/0]).
-export([list_directories/0]).
-export([unwatch_directory/1]).
-export([watch_directory/1]).
-export([watch_directory/2]).
-export([watch_directory/3]).

%% Name Server API
-export([register_name/2]).
-export([send/2]).
-export([unregister_name/1]).
-export([whereis_name/1]).

%% gen_server callbacks
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

%% Macros
-define(SERVER, ?MODULE).
-define(TAB, rabbit_trust_store_file).

%% Records & Types
-type monitors() :: [{{reference(), pid()}, any()}].
-record(state, {
	monitors = [] :: monitors()
}).
-type poller_name() :: {poller, file:name_all()}.
-type reader_name() :: {reader, file:name_all()}.
-type name()        :: poller_name() | reader_name().

%%%===================================================================
%%% API functions
%%%===================================================================

start_link() ->
	gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

list_directories() ->
	ets:select(?TAB, [{{{poller, '$1'}, '_'}, [], ['$1']}]).

unwatch_directory(Directory)
		when (is_binary(Directory) orelse is_list(Directory)) ->
	AbsDirectory = filename:absname(Directory),
	rabbit_trust_store_file_poller:unwatch(AbsDirectory).

watch_directory(Directory)
		when (is_binary(Directory) orelse is_list(Directory)) ->
	watch_directory(Directory, rabbit_trust_store_app:default(recurse)).

watch_directory(Directory, Recurse)
		when (is_binary(Directory) orelse is_list(Directory))
		andalso is_boolean(Recurse) ->
	watch_directory(Directory, Recurse, rabbit_trust_store_app:default(refresh_interval)).

watch_directory(Directory, Recurse, Interval)
		when (is_binary(Directory) orelse is_list(Directory))
		andalso is_boolean(Recurse)
		andalso (Interval =:= infinity orelse (is_integer(Interval) andalso Interval >= 0)) ->
	ok = filelib:ensure_dir(filename:join(Directory, ".keep")),
	AbsDirectory = filename:absname(Directory),
	rabbit_trust_store_file_poller_sup:start_file_poller(AbsDirectory, Recurse, Interval).

%%%===================================================================
%%% Name Server API functions
%%%===================================================================

-spec register_name(Name::poller_name(), Pid::pid()) -> yes | no.
register_name({Type=poller, Name}, Pid)
		when (is_binary(Name) orelse is_list(Name))
		andalso is_pid(Pid) ->
	gen_server:call(?SERVER, {register_name, {Type, Name}, Pid}, infinity).

-spec send(Name::name(), Msg::term()) -> pid().
send(Name, Msg) ->
	case whereis_name(Name) of
		Pid when is_pid(Pid) ->
			Pid ! Msg,
			Pid;
		undefined ->
			erlang:error(badarg, [Name, Msg])
	end.

-spec unregister_name(Name::poller_name()) -> ok.
unregister_name(Name={poller, _}) ->
	case whereis_name(Name) of
		undefined ->
			ok;
		Pid ->
			_ = rabbit_trust_store_file_poller_sup:stop_file_poller(Pid),
			ok
	end.

-spec whereis_name(Name::name()) -> pid() | undefined.
whereis_name({Type, Name})
		when (Type =:= poller orelse Type =:= reader)
		andalso (is_binary(Name) orelse is_list(Name)) ->
	case ets:lookup(?TAB, {Type, Name}) of
		[{{Type, Name}, Pid}] ->
			case erlang:is_process_alive(Pid) of
				true ->
					Pid;
				false ->
					undefined
			end;
		[] ->
			undefined
	end.

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%% @private
init([]) ->
	ok = rabbit_trust_store_file_event:add_handler(rabbit_trust_store_event_handler, self()),
	Monitors = [{{erlang:monitor(process, Pid), Pid}, Ref} || [Ref, Pid] <- ets:match(?TAB, {'$1', '$2'})],
	{ok, #state{monitors=Monitors}}.

%% @private
handle_call({register_name, Ref, Pid}, _From, State=#state{monitors=Monitors}) ->
	case ets:insert_new(?TAB, {Ref, Pid}) of
		true ->
			MonitorRef = erlang:monitor(process, Pid),
			{reply, yes, State#state{monitors=[{{MonitorRef, Pid}, Ref} | Monitors]}};
		false ->
			{reply, no, State}
	end;
handle_call(_Request, _From, State) ->
	{noreply, State}.

%% @private
handle_cast(_Request, State) ->
	{noreply, State}.

%% @private
handle_info({'$rabbitmq-trust-store', {file, changed, Filename}}, State=#state{monitors=Monitors}) ->
	Ref = {reader, Filename},
	case ets:member(?TAB, Ref) of
		false ->
			{ok, Pid} = rabbit_trust_store_file_reader_sup:start_file_reader(Filename),
			true = ets:insert(?TAB, Ref),
			MonitorRef = erlang:monitor(process, Pid),
			{noreply, State#state{monitors=[{{MonitorRef, Pid}, Ref} | Monitors]}};
		true ->
			{noreply, State}
	end;
handle_info({'$rabbitmq-trust-store', {file, removed, Filename}}, State) ->
	ok = rabbit_trust_store:delete_certificates_by_source({file, Filename}),
	{noreply, State};
handle_info({'DOWN', MonitorRef, process, Pid, _Reason}, State=#state{monitors=Monitors}) ->
	case lists:keytake({MonitorRef, Pid}, 1, Monitors) of
		{value, {_, Ref}, NewMonitors} ->
			true = ets:delete(?TAB, Ref),
			{noreply, State#state{monitors=NewMonitors}};
		false ->
			{noreply, State}
	end;
handle_info(_Info, State) ->
	{noreply, State}.

%% @private
terminate(_Reason, _State) ->
	ok.

%% @private
code_change(_OldVsn, State, _Extra) ->
	{ok, State}.
