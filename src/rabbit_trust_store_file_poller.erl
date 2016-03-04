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

-module(rabbit_trust_store_file_poller).
-behaviour(gen_server).

-include_lib("kernel/include/file.hrl").

%% API
-export([start_link/3]).
-export([unwatch/1]).

%% gen_server callbacks
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

%% Types
-record(entry, {
	filename = undefined :: undefined | file:name_all(),
	mtime    = undefined :: undefined | file:date_time() | non_neg_integer()
}).
-type entry() :: #entry{}.
-type entries() :: [entry()].

%% Records
-record(state, {
	directory = undefined :: undefined | file:name_all(),
	recurse   = false     :: boolean(),
	mtime     = undefined :: undefined | file:date_time() | non_neg_integer(),
	entries   = []        :: entries(),
	interval  = infinity  :: infinity | timeout(),
	reference = undefined :: undefined | reference(),
	closer    = undefined :: undefined | {pid(), reference()}
}).

%%%===================================================================
%%% API functions
%%%===================================================================

start_link(Directory, Recurse, Interval) ->
	gen_server:start_link({via, rabbit_trust_store_file, {poller, Directory}}, ?MODULE, [Directory, Recurse, Interval], []).

unwatch(Directory) ->
	gen_server:call({via, rabbit_trust_store_file, {poller, Directory}}, unwatch).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%% @private
init([Directory, Recurse, Interval]) ->
	ok = rabbit_trust_store_event:add_handler(rabbit_trust_store_event_handler, self()),
	State = #state{
		directory = Directory,
		recurse   = Recurse,
		interval  = resolve_interval(Interval)
	},
	{ok, schedule_poll(State, 0)}.

%% @private
handle_call(unwatch, From, State) ->
	{stop, normal, State#state{closer=From}};
handle_call(_Request, _From, State) ->
	{noreply, State}.

%% @private
handle_cast(_Request, State) ->
	{noreply, State}.

%% @private
handle_info({timeout, Reference, poll}, State=#state{reference=Reference}) ->
	maybe_poll(State#state{reference=undefined});
handle_info({'$rabbitmq-trust-store', refresh}, State0) ->
	State1 = schedule_poll(State0#state{mtime=undefined}, infinity),
	maybe_poll(State1);
handle_info(_Info, State) ->
	{noreply, State}.

%% @private
terminate(_Reason, #state{entries=Entries, closer=Closer}) ->
	_ = [begin
		rabbit_trust_store_file_event:removed(Filename)
	end || #entry{filename=Filename} <- Entries],
	catch gen_server:reply(Closer, ok),
	ok.

%% @private
code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------

%% @private
delta_entries([PrevEntry | PrevEntries], NextEntries0) ->
	case lists:keytake(PrevEntry#entry.filename, #entry.filename, NextEntries0) of
		{value, PrevEntry, NextEntries1} ->
			delta_entries(PrevEntries, NextEntries1);
		{value, NewEntry, NextEntries1} ->
			ok = rabbit_trust_store_file_event:changed(NewEntry#entry.filename),
			delta_entries(PrevEntries, NextEntries1);
		false ->
			ok = rabbit_trust_store_file_event:removed(PrevEntry#entry.filename),
			delta_entries(PrevEntries, NextEntries0)
	end;
delta_entries([], NextEntries) ->
	_ = [rabbit_trust_store_file_event:changed(F) || #entry{filename=F} <- NextEntries],
	ok.

%% @private
maybe_poll(State=#state{directory=Directory, mtime=PrevModified}) ->
	case file:read_file_info(Directory, [{time, posix}]) of
		{ok, #file_info{mtime=Modified}} when PrevModified =:= undefined ->
			poll(State#state{mtime=Modified});
		{ok, #file_info{mtime=NextModified}} when PrevModified < NextModified ->
			poll(State#state{mtime=NextModified});
		{ok, #file_info{mtime=Modified}} ->
			{noreply, schedule_poll(State#state{mtime=Modified})};
		{error, Reason}
				when Reason =:= eacces
				orelse Reason =:= enoent
				orelse Reason =:= enotdir ->
			{noreply, schedule_poll(State)};
		{error, Reason} ->
			{stop, Reason, State}
	end.

%% @private
poll(State=#state{directory=Directory, entries=PrevEntries, recurse=Recurse}) ->
	NextEntries = lists:usort(filelib:fold_files(Directory, [], Recurse, fun(Filename, Acc) ->
		case read_entry(Filename) of
			{ok, Entry} ->
				[Entry | Acc];
			{error, _Reason} ->
				Acc
		end
	end, [])),
	ok = delta_entries(PrevEntries, NextEntries),
	{noreply, schedule_poll(State#state{entries=NextEntries})}.

%% @private
read_entry(Filename) ->
	case file:read_file_info(Filename) of
		{ok, #file_info{mtime=Modified}} ->
			{ok, #entry{filename=Filename, mtime=Modified}};
		{error, Reason} ->
			{error, Reason}
	end.

%% @private
resolve_interval(infinity) ->
	infinity;
resolve_interval(undefined) ->
	infinity;
resolve_interval(Interval) when is_integer(Interval) ->
	timer:seconds(Interval).

%% @private
schedule_poll(State=#state{interval=Interval})
		when Interval =:= infinity
		orelse Interval =:= 0 ->
	schedule_poll(State, infinity);
schedule_poll(State=#state{interval=Interval}) ->
	schedule_poll(State, Interval).

%% @private
schedule_poll(State=#state{reference=undefined}, infinity) ->
	State;
schedule_poll(State=#state{reference=undefined}, Timeout) ->
	Reference = erlang:start_timer(Timeout, self(), poll),
	State#state{reference=Reference};
schedule_poll(State=#state{reference=Reference}, Timeout) ->
	catch erlang:cancel_timer(Reference),
	schedule_poll(State#state{reference=undefined}, Timeout).
