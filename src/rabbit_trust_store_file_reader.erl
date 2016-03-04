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

-module(rabbit_trust_store_file_reader).

%% API
-export([start_link/1]).
-export([read/2]).

%%%===================================================================
%%% API functions
%%%===================================================================

start_link(Filename) ->
	proc_lib:start_link(?MODULE, read, [self(), Filename]).

%% @private
read(Parent, Filename) ->
	ok = proc_lib:init_ack(Parent, {ok, self()}),
	try file:read_file(Filename) of
		{ok, Binary} ->
			try_decode(Binary, Filename);
		_ ->
			terminate(removed, Filename)
	catch
		_:_ ->
			terminate(removed, Filename)
	end.

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------

%% @private
terminate(Reason) ->
	exit(Reason).

%% @private
terminate(removed, Filename) ->
	ok = rabbit_trust_store_file_event:removed(Filename),
	terminate(normal).

%% @private
try_decode(Binary, Filename) ->
	try rabbit_trust_store_certificate:pem_decode(Binary) of
		[] ->
			terminate(removed, Filename);
		Certificates when is_list(Certificates) ->
			Source = {file, Filename},
			PrevCertificateKeys = rabbit_trust_store:list_certificates_by_source(Source),
			NextCertificateKeys = [begin
				rabbit_trust_store:add_certificate(Key, Certificate, Source),
				Key
			end || {Key, Certificate} <- Certificates],
			RemovedCertificateKeys = PrevCertificateKeys -- NextCertificateKeys,
			_ = [begin
				rabbit_trust_store:delete_certificate_source(Key, Source)
			end || Key <- RemovedCertificateKeys],
			terminate(normal);
		_ ->
			terminate(removed, Filename)
	catch
		_:_ ->
			terminate(removed, Filename)
	end.
