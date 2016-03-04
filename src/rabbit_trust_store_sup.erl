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

-module(rabbit_trust_store_sup).
-behaviour(supervisor).

%% API
-export([start_link/1]).

%% Supervisor callbacks
-export([init/1]).

%% Macros
-define(SUPERVISOR, ?MODULE).
-define(TAB, rabbit_trust_store).

%% Helper macro for declaring children of supervisor
-define(CHILD(I, Type, Args), {I, {I, start_link, Args}, permanent, 5000, Type, [I]}).

%%%===================================================================
%%% API functions
%%%===================================================================

start_link(Options) ->
	supervisor:start_link({local, ?SUPERVISOR}, ?MODULE, [Options]).

%%%===================================================================
%%% Supervisor callbacks
%%%===================================================================

%% @private
init([Options]) ->
	rabbit_trust_store_certificates = ets:new(rabbit_trust_store_certificates, [
		named_table,
		ordered_set,
		public,
		{read_concurrency, true}
	]),
	rabbit_trust_store_sources = ets:new(rabbit_trust_store_sources, [
		named_table,
		bag,
		public,
		{read_concurrency, true}
	]),
	ChildSpecs = [
		{rabbit_trust_store_event:manager(),
			{gen_event, start_link, [{local, rabbit_trust_store_event:manager()}]},
			permanent, 5000, worker, [gen_event]},
		?CHILD(rabbit_trust_store, worker, []),
		?CHILD(rabbit_trust_store_file_sup, supervisor, [proplists:get_value(file, Options, [])])
	],
	Restart = {one_for_one, 1, 5},
	{ok, {Restart, ChildSpecs}}.

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------
