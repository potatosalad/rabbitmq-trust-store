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

-module(rabbit_trust_store_test).
-compile([export_all]).

-include_lib("eunit/include/eunit.hrl").
-include_lib("amqp_client/include/amqp_client.hrl").

-define(SERVER_REJECT_CLIENT, {tls_alert, "unknown ca"}).

%%%===================================================================
%%% Test functions
%%%===================================================================

invasive_SSL_option_change_test() ->

	%% Given: Rabbit is started with the boot-steps in the
	%% Trust-Store's OTP Application file.

	%% When: we get Rabbit's SSL options.
	Options = cfg(),

	%% Then: all necessary settings are correct.
	true        = proplists:get_value(fail_if_no_peer_cert, Options),
	verify_peer = proplists:get_value(verify, Options),
	{F, _State} = proplists:get_value(verify_fun, Options),

	{module, rabbit_trust_store_certificate} = erlang:fun_info(F, module),
	{name,   verify}                         = erlang:fun_info(F, name).

validation_success_for_AMQP_client_test_() ->

	{timeout, 15, fun() ->

		%% Given: an authority and a certificate rooted with that
		%% authority.
		AuthorityInfo = {Root, _AuthorityKey} = erl_make_certs:make_cert([{key, dsa}]),
		{CertificateA, KeyA} = chain(AuthorityInfo),
		{CertificateB, KeyB} = chain(AuthorityInfo),

		%% When: Rabbit accepts just this one authority's certificate
		%% (i.e. these are options that'd be in the configuration
		%% file).
		ok = rabbit_networking:start_ssl_listener(port(), [
			{cacerts, [Root]},
			{cert, CertificateA},
			{key, KeyA}
			| cfg()
		], 1),

		%% Then: a client presenting a certifcate rooted at the same
		%% authority connects successfully.
		{ok, Con} = amqp_connection:start(#amqp_params_network{
			host = "127.0.0.1",
			port = port(),
			ssl_options = [
				{cert, CertificateB},
				{key, KeyB}
			]
		}),

		%% Clean: client & server TLS/TCP.
		ok = amqp_connection:close(Con),
		ok = rabbit_networking:stop_tcp_listener(port())

	end}.

validation_failure_for_AMQP_client_test_() ->

	{timeout, 15, fun() ->

		%% Given: a root certificate and a certificate rooted with another
		%% authority.
		{Root, CertificateA, KeyA} = ct_helper:make_certs(),
		{   _, CertificateB, KeyB} = ct_helper:make_certs(),

		%% When: Rabbit accepts certificates rooted with just one
		%% particular authority.
		ok = rabbit_networking:start_ssl_listener(port(), [
			{cacerts, [Root]},
			{cert, CertificateA},
			{key, KeyA}
			| cfg()
		], 1),

		%% Then: a client presenting a certificate rooted with another
		%% authority is REJECTED.
		{error, ?SERVER_REJECT_CLIENT} = amqp_connection:start(#amqp_params_network{
			host = "127.0.0.1",
			port = port(),
			ssl_options = [
				{cert, CertificateB},
				{key, KeyB}
			]
		}),

		%% Clean: server TLS/TCP.
		ok = rabbit_networking:stop_tcp_listener(port())

	end}.

whitelisted_certificate_accepted_from_AMQP_client_regardless_of_validation_to_root_test_() ->

	{timeout, 15, fun() ->

		%% Given: a certificate `CertificateB` AND that it is whitelisted.

		{Root, CertificateA, KeyA} = ct_helper:make_certs(),
		{   _, CertificateB, KeyB} = ct_helper:make_certs(),

		ok = build_directory_tree(friendlies()),
		ok = whitelist(friendlies(), "alice", CertificateB, KeyB),
		ok = change_configuration(rabbitmq_trust_store, [{directory, friendlies()}]),

		ok = watch_events(),
		_CertificateId = wait_for_certificate_added(),

		%% When: Rabbit validates paths with a different root `R` than
		%% that of the certificate `C`.
		ok = rabbit_networking:start_ssl_listener(port(), [
			{cacerts, [Root]},
			{cert, CertificateA},
			{key, KeyA}
			| cfg()
		], 1),

		%% Then: a client presenting the whitelisted certificate `C`
		%% is allowed.
		{ok, Con} = amqp_connection:start(#amqp_params_network{
			host = "127.0.0.1",
			port = port(),
			ssl_options = [
				{cert, CertificateB},
				{key, KeyB}
			]
		}),

		%% Clean: client & server TLS/TCP
		ok = unwatch_events(),
		ok = delete("alice.pem"),
		ok = amqp_connection:close(Con),
		ok = rabbit_networking:stop_tcp_listener(port()),

		ok = force_delete_entire_directory(friendlies())

	end}.

removed_certificate_denied_from_AMQP_client_test_() ->

	{timeout, 15, fun() ->

		%% Given: a certificate `CertificateB` AND that it is whitelisted.

		{Root, CertificateA, KeyA} = ct_helper:make_certs(),
		{   _, CertificateB, KeyB} = ct_helper:make_certs(),

		ok = build_directory_tree(friendlies()),
		ok = whitelist(friendlies(), "bob", CertificateB, KeyB),
		ok = change_configuration(rabbitmq_trust_store, [
			{directory, friendlies()}, {refresh_interval, {seconds, interval()}}]),

		ok = watch_events(),
		CertificateId = wait_for_certificate_added(),

		%% When: we wait for at least one second (the accuracy of the
		%% file system's time), remove the whitelisted certificate,
		%% then wait for the trust-store to refresh the whitelist.
		ok = rabbit_networking:start_ssl_listener(port(), [
			{cacerts, [Root]},
			{cert, CertificateA},
			{key, KeyA}
			| cfg()
		], 1),

		wait_for_file_system_time(),
		ok = delete("bob.pem"),
		?assert(CertificateId =:= wait_for_certificate_deleted()),

		%% Then: a client presenting the removed whitelisted
		%% certificate `C` is denied.
		{error, ?SERVER_REJECT_CLIENT} = amqp_connection:start(#amqp_params_network{
			host = "127.0.0.1",
			port = port(),
			ssl_options = [
				{cert, CertificateB},
				{key, KeyB}
			]
		}),

		%% Clean: server TLS/TCP
		ok = unwatch_events(),
		ok = rabbit_networking:stop_tcp_listener(port()),

		ok = force_delete_entire_directory(friendlies())

	end}.

installed_certificate_accepted_from_AMQP_client_test_() ->

	{timeout, 15, fun() ->

		%% Given: a certificate `CertificateB` which is NOT yet whitelisted.

		{Root, CertificateA, KeyA} = ct_helper:make_certs(),
		{   _, CertificateB, KeyB} = ct_helper:make_certs(),

		ok = build_directory_tree(friendlies()),
		ok = change_configuration(rabbitmq_trust_store, [
			{directory, friendlies()}, {refresh_interval, {seconds, interval()}}]),

		ok = watch_events(),

		%% When: we wait for at least one second (the accuracy of the
		%% file system's time), add a certificate to the directory,
		%% then wait for the trust-store to refresh the whitelist.
		ok = rabbit_networking:start_ssl_listener(port(), [
			{cacerts, [Root]},
			{cert, CertificateA},
			{key, KeyA}
			| cfg()
		], 1),

		wait_for_file_system_time(),
		ok = whitelist(friendlies(), "charlie", CertificateB, KeyB),
		_CertificateId = wait_for_certificate_added(),

		%% Then: a client presenting the whitelisted certificate `C`
		%% is allowed.
		{ok, Con} = amqp_connection:start(#amqp_params_network{
			host = "127.0.0.1",
			port = port(),
			ssl_options = [
				{cert, CertificateB},
				{key, KeyB}
			]
		}),

		%% Clean: Client & server TLS/TCP
		ok = unwatch_events(),
		ok = delete("charlie.pem"),
		ok = amqp_connection:close(Con),
		ok = rabbit_networking:stop_tcp_listener(port()),

		ok = force_delete_entire_directory(friendlies())

	end}.

whitelist_directory_DELTA_test_() ->

	{timeout, 20, fun() ->

		ok = build_directory_tree(friendlies()),

		%% Given: a certificate `R` which Rabbit can use as a
		%% root certificate to validate agianst AND three
		%% certificates which clients can present (the first two
		%% of which are whitelisted).

		{Root, CertificateA, KeyA} = ct_helper:make_certs(),
		{   _, CertificateB, KeyB} = ct_helper:make_certs(),
		{   _, CertificateC, KeyC} = ct_helper:make_certs(),
		{   _, CertificateD, KeyD} = ct_helper:make_certs(),

		ok = change_configuration(rabbitmq_trust_store, [
			{directory, friendlies()}, {refresh_interval, {seconds, interval()}}]),

		ok = watch_events(),
		ok = whitelist(friendlies(), "foo", CertificateB, KeyB),
		ok = rabbit_trust_store:refresh(),
		_CertificateIdB = wait_for_certificate_added(),
		ok = whitelist(friendlies(), "bar", CertificateC, KeyC),
		ok = rabbit_trust_store:refresh(),
		CertificateIdC = wait_for_certificate_added(),

		%% When: we wait for at least one second (the accuracy
		%% of the file system's time), delete a certificate and
		%% a certificate to the directory, then wait for the
		%% trust-store to refresh the whitelist.
		ok = rabbit_networking:start_ssl_listener(port(), [
			{cacerts, [Root]},
			{cert, CertificateA},
			{key, KeyA}
			| cfg()
		], 1),

		ok = delete("bar.pem"),
		ok = whitelist(friendlies(), "baz", CertificateD, KeyD),
		ok = rabbit_trust_store:refresh(),
		?assert(CertificateIdC =:= wait_for_certificate_deleted()),
		_CertificateIdD = wait_for_certificate_added(),

		%% Then: connectivity to Rabbit is as it should be.
		{ok, ConnectionB} = amqp_connection:start(#amqp_params_network{
			host = "127.0.0.1",
			port = port(),
			ssl_options = [
				{cert, CertificateB},
				{key, KeyB}
			]
		}),
		{error, ?SERVER_REJECT_CLIENT} = amqp_connection:start(#amqp_params_network{
			host = "127.0.0.1",
			port = port(),
			ssl_options = [
				{cert, CertificateC},
				{key, KeyC}
			]
		}),
		{ok, ConnectionD} = amqp_connection:start(#amqp_params_network{
			host = "127.0.0.1",
			port = port(),
			ssl_options = [
				{cert, CertificateD},
				{key, KeyD}
			]
		}),

		%% Clean: delete certificate file, close client & server
		%% TLS/TCP
		ok = unwatch_events(),
		ok = delete("foo.pem"),
		ok = delete("baz.pem"),

		ok = force_delete_entire_directory(friendlies()),

		ok = amqp_connection:close(ConnectionB),
		ok = amqp_connection:close(ConnectionD),

		ok = rabbit_networking:stop_tcp_listener(port())
	end}.

%%%-------------------------------------------------------------------
%%% Test Constants functions
%%%-------------------------------------------------------------------

%% @private
cfg() ->
	{ok, Cfg} = application:get_env(rabbit, ssl_options),
	Cfg.

%% @private
data_directory() ->
	Path = os:getenv("TMPDIR"),
	true = false =/= Path,
	Path.

%% @private
friendlies() ->
	filename:join([data_directory(), "friendlies"]).

%% @private
interval() ->
	1.

%% @private
port() ->
	case get(rabbit_ssl_port) of
		undefined ->
			{ok, Socket} = gen_tcp:listen(0, [
				{active, false},
				binary,
				{nodelay, true},
				{packet, raw},
				{reuseaddr, true}
			]),
			{ok, {_, Port}} = inet:sockname(Socket),
			gen_tcp:close(Socket),
			put(rabbit_ssl_port, Port),
			Port;
		Port ->
			Port
	end.

%%%-------------------------------------------------------------------
%%% Ancillary functions
%%%-------------------------------------------------------------------

%% @private
build_directory_tree(Path) ->
	filelib:ensure_dir(filename:join(Path, ".keep")).

%% @private
chain(Issuer) ->
	%% These are DER encoded.
	{Certificate, {Kind, Key, _}} = erl_make_certs:make_cert([{key, dsa}, {issuer, Issuer}]),
	{Certificate, {Kind, Key}}.

%% @private
change_cfg(_, []) ->
	ok;
change_cfg(App, [{Name,Value}|Rest]) ->
	ok = application:set_env(App, Name, Value),
	change_cfg(App, Rest).

%% @private
change_configuration(App, Props) ->
	ok = application:stop(App),
	ok = change_cfg(App, Props),
	application:start(App).

%% @private
delete(Name) ->
	file:delete(filename:join([friendlies(), Name])).

%% @private
flush_events() ->
	receive
		{'$rabbitmq-trust-store', _} ->
			flush_events()
	after
		0 ->
			ok
	end.

%% @private
force_delete_entire_directory(Path) ->
	rabbit_file:recursive_delete([Path]).

%% @private
unwatch_events() ->
	rabbit_trust_store_event:delete_handler(rabbit_trust_store_event_handler, self()),
	flush_events().

%% @private
wait_for_certificate_added() ->
	receive
		{'$rabbitmq-trust-store', {certificate, added, Key, _Certificate}} ->
			Key
	after
		100 ->
			% We may have already missed the added event, so just
			% check whether we have a single certificate or not.
			case rabbit_trust_store:list_certificates() of
				[Key] ->
					Key;
				_ ->
					wait_for_certificate_added()
			end
	end.

%% @private
wait_for_certificate_deleted() ->
	receive
		{'$rabbitmq-trust-store', {certificate, deleted, Key, _Certificate}} ->
			Key
	end.

%% @private
wait_for_file_system_time() ->
	timer:sleep(timer:seconds(1)).

%% @private
watch_events() ->
	rabbit_trust_store_event:add_handler(rabbit_trust_store_event_handler, self()).

%% @private
whitelist(Path, Filename, Certificate, {A, B} = _Key) ->
	ok = erl_make_certs:write_pem(Path, Filename, {Certificate, {A, B, not_encrypted}}),
	lists:foreach(fun delete/1, filelib:wildcard("*_key.pem", friendlies())).
