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

-module(rabbit_trust_store).
-behaviour(gen_server).

%% API
-export([start_link/0]).

%% Console API
-export([refresh/0]).

%% Certificate API
-export([add_certificate/3]).
-export([delete_certificate/1]).
-export([delete_certificate_source/2]).
-export([delete_certificates_by_source/1]).
-export([get_certificate/1]).
-export([is_certificate/1]).
-export([list_certificates/0]).
-export([list_certificates_by_source/1]).

%% gen_server callbacks
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

%% Macros
-define(SERVER, ?MODULE).
-define(TAB_C, rabbit_trust_store_certificates).
-define(TAB_S, rabbit_trust_store_sources).

%% Records
-record(state, {}).

%%%===================================================================
%%% API functions
%%%===================================================================

start_link() ->
	gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%%===================================================================
%%% Console API functions
%%%===================================================================

refresh() ->
	rabbit_trust_store_event:refresh().

%%%===================================================================
%%% Certificate API functions
%%%===================================================================

add_certificate(Key, Certificate, Source) ->
	gen_server:call(?SERVER, {add_certificate, Key, Certificate, Source}).

delete_certificate(Key) ->
	gen_server:call(?SERVER, {delete_certificate, Key}).

delete_certificate_source(Key, Source) ->
	gen_server:call(?SERVER, {delete_certificate_source, Key, Source}).

delete_certificates_by_source(Source) ->
	gen_server:call(?SERVER, {delete_certificates_by_source, Source}).

get_certificate(Key) ->
	ets:lookup_element(?TAB_C, Key, 1).

is_certificate(Key) ->
	ets:member(?TAB_C, Key).

list_certificates() ->
	ets:select(?TAB_C, [{{'$1', '_'}, [], ['$1']}]).

list_certificates_by_source(Source) ->
	ets:select(?TAB_S, [{{Source, '$1'}, [], ['$1']}]).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%% @private
init([]) ->
	ok = rabbit_trust_store_event:add_handler(rabbit_trust_store_event_handler, self()),
	{ok, #state{}}.

%% @private
handle_call({add_certificate, Key, Certificate, Source}, _From, State) ->
	ok = case ets:lookup(?TAB_C, Key) of
		[] ->
			true = ets:insert(?TAB_C, {Key, Certificate}),
			rabbit_trust_store_event:certificate_added(Key, Certificate);
		[{Key, Certificate}] ->
			ok;
		[{Key, OldCertificate}] ->
			true = ets:insert(?TAB_C, {Key, Certificate}),
			rabbit_trust_store_event:certificate_changed(Key, OldCertificate, Certificate)
	end,
	ok = case ets:insert_new(?TAB_S, {Source, Key}) of
		false ->
			ok;
		true ->
			rabbit_trust_store_event:certificate_source_added(Key, Source)
	end,
	{reply, ok, State};
handle_call({delete_certificate_source, Key, Source}, _From, State) ->
	case ets:match_object(?TAB_S, {Source, Key}) of
		[{Source, Key}] ->
			true = ets:delete_object(?TAB_S, {Source, Key}),
			ok = rabbit_trust_store_event:certificate_source_deleted(Key, Source),
			ok = maybe_delete_certificate(Key),
			{reply, ok, State};
		[] ->
			{reply, ok, State}
	end;
handle_call({delete_certificates_by_source, Source}, _From, State) ->
	case ets:take(?TAB_S, Source) of
		[] ->
			{reply, ok, State};
		Sources ->
			_ = [begin
				ok = rabbit_trust_store_event:certificate_source_deleted(Key, Source),
				maybe_delete_certificate(Key)
			end || {_, Key} <- Sources],
			{reply, ok, State}
	end;
handle_call(_Request, _From, State) ->
	{noreply, State}.

%% @private
handle_cast(_Request, State) ->
	{noreply, State}.

%% @private
handle_info({maybe_delete_certificate, Key}, State) ->
	case ets:select_count(?TAB_S, [{{'_', Key}, [], [true]}]) of
		0 ->
			case ets:take(?TAB_C, Key) of
				[{Key, Certificate}] ->
					ok = rabbit_trust_store_event:certificate_deleted(Key, Certificate),
					{noreply, State};
				[] ->
					{noreply, State}
			end;
		_ ->
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

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------

%% @private
maybe_delete_certificate(Key) ->
	_ = erlang:send_after(0, self(), {maybe_delete_certificate, Key}),
	ok.
