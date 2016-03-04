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

-module(rabbit_trust_store_event_handler).
-behaviour(gen_event).

%% gen_event callbacks
-export([init/1]).
-export([handle_event/2]).
-export([handle_call/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

%%%===================================================================
%%% gen_event callbacks
%%%===================================================================

%% @private
init(Pid) when is_pid(Pid) ->
	{ok, Pid}.

%% @private
handle_event(Event, Pid) ->
	catch Pid ! {'$rabbitmq-trust-store', Event},
	{ok, Pid}.

%% @private
handle_call(_Request, Pid) ->
	{ok, ok, Pid}.

%% @private
handle_info({'EXIT', _Parent, shutdown}, _Pid) ->
	remove_handler;
handle_info(_Info, Pid) ->
	{ok, Pid}.

%% @private
terminate(_Reason, _Pid) ->
	ok.

%% @private
code_change(_OldVsn, Pid, _Extra) ->
	{ok, Pid}.
