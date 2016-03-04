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

-module(rabbit_trust_store_event).

%% API
-export([manager/0]).
-export([add_handler/2]).
-export([delete_handler/2]).
-export([refresh/0]).
-export([certificate_added/2]).
-export([certificate_changed/3]).
-export([certificate_deleted/2]).
-export([certificate_source_added/2]).
-export([certificate_source_deleted/2]).

%% Macros
-define(MANAGER, rabbit_trust_store_manager).

%%%===================================================================
%%% API functions
%%%===================================================================

manager() ->
	?MANAGER.

add_handler(Handler, Pid) ->
	gen_event:add_handler(?MANAGER, Handler, Pid).

delete_handler(Handler, Pid) ->
	gen_event:delete_handler(?MANAGER, Handler, Pid).

refresh() ->
	notify(refresh).

certificate_added(Key, Certificate) ->
	notify({certificate, added, Key, Certificate}).

certificate_changed(Key, OldCertificate, NewCertificate) ->
	notify({certificate, changed, Key, OldCertificate, NewCertificate}).

certificate_deleted(Key, Certificate) ->
	notify({certificate, deleted, Key, Certificate}).

certificate_source_added(Key, Source) ->
	notify({certificate, source_added, Key, Source}).

certificate_source_deleted(Key, Source) ->
	notify({certificate, source_deleted, Key, Source}).

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------

%% @private
notify(Message) ->
	gen_event:notify(?MANAGER, Message).
