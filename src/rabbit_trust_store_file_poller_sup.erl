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

-module(rabbit_trust_store_file_poller_sup).
-behaviour(supervisor).

%% API
-export([start_link/0]).
-export([start_file_poller/3]).
-export([stop_file_poller/1]).

%% Supervisor callbacks
-export([init/1]).

%% Macros
-define(SUPERVISOR, ?MODULE).

%%%===================================================================
%%% API functions
%%%===================================================================

start_link() ->
	supervisor:start_link({local, ?SUPERVISOR}, ?MODULE, []).

start_file_poller(Directory, Recurse, Interval) ->
	supervisor:start_child(?SUPERVISOR, [Directory, Recurse, Interval]).

stop_file_poller(Pid) ->
	case supervisor:terminate_child(?SUPERVISOR, Pid) of
		ok ->
			_ = supervisor:delete_child(?SUPERVISOR, Pid),
			ok;
		{error, Reason} ->
			{error, Reason}
	end.

%%%===================================================================
%%% Supervisor callbacks
%%%===================================================================

%% @private
init([]) ->
	ChildSpecs = [
		{undefined,
			{rabbit_trust_store_file_poller, start_link, []},
			transient, 5000, worker, [rabbit_trust_store_file_poller]}
	],
	Restart = {simple_one_for_one, 10, 10},
	{ok, {Restart, ChildSpecs}}.

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------
