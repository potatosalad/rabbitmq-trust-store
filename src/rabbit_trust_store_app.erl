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

-module(rabbit_trust_store_app).
-behaviour(application).

%% Application callbacks
-export([start/2]).
-export([stop/1]).

%% RabbitMQ Boot Steps
-export([change_ssl_options/0]).
-export([revert_ssl_options/0]).

-rabbit_boot_step({rabbit_trust_store, [
	{description, "Change necessary SSL options."},
	{mfa, {?MODULE, change_ssl_options, []}},
	{cleanup, {?MODULE, revert_ssl_options, []}},
	{enables, networking}
]}).

%% Internal API
-export([default/1]).

%% Macros
-define(DEFAULT_DIRECTORY,        default_directory()).
-define(DEFAULT_RECURSE,          false).
-define(DEFAULT_REFRESH_INTERVAL, 30).

%%%===================================================================
%%% Application callbacks
%%%===================================================================

start(_Type, _Args) ->
	rabbit_trust_store_sup:start_link([
		{file, [
			{directory, get_env(directory)},
			{recurse, get_env(recurse)},
			{refresh_interval, get_env(refresh_interval)}
		]}
	]).

stop(_State) ->
	ok.

%%%===================================================================
%%% RabbitMQ Boot Steps
%%%===================================================================

change_ssl_options() ->
	InitialSSLOptions = application:get_env(rabbit, ssl_options, undefined),
	ok = application:set_env(rabbit, pre_trust_store_ssl_options, InitialSSLOptions, [{persistent, true}]),
	SSLOptions = edit_ssl_options(InitialSSLOptions),
	ok = application:set_env(rabbit, ssl_options, SSLOptions, [{persistent, true}]).

revert_ssl_options() ->
	InitialSSLOptions = application:get_env(rabbit, pre_trust_store_ssl_options, undefined),
	ok = application:unset_env(rabbit, pre_trust_store_ssl_options, [{persistent, true}]),
	ok = application:set_env(rabbit, ssl_options, InitialSSLOptions, [{persistent, true}]).

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------

%% @private
default(directory) ->
	?DEFAULT_DIRECTORY;
default(recurse) ->
	?DEFAULT_RECURSE;
default(refresh_interval) ->
	?DEFAULT_REFRESH_INTERVAL.

%% @private
default_directory() ->
	%% Dismantle the directory tree: first the table & meta-data
	%% directory, then the Mesia database directory, finally the node
	%% directory where we will place the default whitelist.
	Mnesia = filename:dirname(rabbit_mnesia:dir()),
	Node   = filename:dirname(Mnesia),
	filename:join([Node, "trust_store", "whitelist"]).

%% @private
edit_ssl_options(undefined) ->
	[
		{fail_if_no_peer_cert, true},
		{verify, verify_peer},
		{verify_fun, {fun rabbit_trust_store_certificate:verify/3, continue}}
	];
edit_ssl_options(InitialSSLOptions) when is_list(InitialSSLOptions) ->
	Options = orddict:from_list(InitialSSLOptions),
	orddict:merge(fun
		(verify_fun, {Function1, State1}, {Function2, State2})
				when is_function(Function1, 3) ->
			VerifyFunction = fun(Certificate, Event, {S1, S2}) ->
				case Function1(Certificate, Event, S1) of
					{fail, Reason} ->
						{fail, Reason};
					{Returned, NewS1}
							when Returned =:= unknown
							orelse Returned =:= valid ->
						case Function2(Certificate, Event, S2) of
							{fail, Reason} ->
								{fail, Reason};
							{valid, NewS2} ->
								{valid, {NewS1, NewS2}};
							{unknown, NewS2} ->
								{unknown, {NewS1, NewS2}}
						end
				end
			end,
			{VerifyFunction, {State1, State2}};
		(_Key, _Value1, Value2) ->
			Value2
	end, Options, edit_ssl_options(undefined)).

%% @private
get_env(directory) ->
	% TODO: error nicely if the config value is bad
	case application:get_env(directory) of
		{ok, D} when is_binary(D) orelse is_list(D) ->
			D;
		undefined ->
			?DEFAULT_DIRECTORY
	end;
get_env(recurse) ->
	% TODO: error nicely if the config value is bad
	case application:get_env(recurse) of
		{ok, B} when is_boolean(B) ->
			B;
		undefined ->
			?DEFAULT_RECURSE
	end;
get_env(refresh_interval) ->
	% TODO: error nicely if the config value is bad
	case application:get_env(refresh_interval) of
		{ok, {seconds, S}} when is_integer(S) andalso S >= 0 ->
			S;
		undefined ->
			?DEFAULT_REFRESH_INTERVAL
	end.
