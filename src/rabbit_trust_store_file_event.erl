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

-module(rabbit_trust_store_file_event).

%% API
-export([manager/0]).
-export([add_handler/2]).
-export([delete_handler/2]).
-export([changed/1]).
-export([removed/1]).

%% Macros
-define(MANAGER, rabbit_trust_store_file_manager).

%%%===================================================================
%%% API functions
%%%===================================================================

manager() ->
	?MANAGER.

add_handler(Handler, Pid) ->
	gen_event:add_handler(?MANAGER, Handler, Pid).

delete_handler(Handler, Pid) ->
	gen_event:delete_handler(?MANAGER, Handler, Pid).

changed(Filename) ->
	notify({file, changed, Filename}).

removed(Filename) ->
	notify({file, removed, Filename}).

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------

%% @private
notify(Message) ->
	gen_event:notify(?MANAGER, Message).
