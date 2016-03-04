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

-module(rabbit_trust_store_certificate).

-include_lib("public_key/include/public_key.hrl").

%% API
-export([is_whitelisted/1]).
-export([pem_decode/1]).
-export([verify/3]).

%%%===================================================================
%%% API functions
%%%===================================================================

is_whitelisted(Key) ->
	rabbit_trust_store:is_certificate(Key).

pem_decode(Binary) when is_binary(Binary) ->
	case public_key:pem_decode(Binary) of
		Entries when is_list(Entries) ->
			pkix_decode_certs(Entries, []);
		PEMDecodeError ->
			PEMDecodeError
	end;
pem_decode(List) when is_list(List) ->
	pem_decode(iolist_to_binary(List)).

verify(_, {bad_cert, unknown_ca}, confirmed) ->
	{valid, confirmed};
verify(C=#'OTPCertificate'{}, {bad_cert, unknown_ca}, continue) ->
	Key = pkix_key(C),
	case is_whitelisted(Key) of
		true ->
			{valid, confirmed};
		false ->
			{fail, "CA not known AND certificate not whitelisted"}
	end;
verify(C=#'OTPCertificate'{}, {bad_cert, selfsigned_peer}, continue) ->
	Key = pkix_key(C),
	case is_whitelisted(Key) of
		true ->
			{valid, confirmed};
		false ->
			{fail, "certificate not whitelisted"}
	end;
verify(_, Reason={bad_cert, _}, _) ->
	{fail, Reason};
verify(_, valid, State) ->
	{valid, State};
verify(_, valid_peer, confirmed) ->
	{valid, confirmed};
verify(C=#'OTPCertificate'{}, valid_peer, continue) ->
	Key = pkix_key(C),
	case is_whitelisted(Key) of
		true ->
			{valid, confirmed};
		false ->
			{valid, continue}
	end;
verify(_, {extension, _}, State) ->
	{unknown, State}.

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------

%% @private
pkix_decode_certs([{'Certificate', Cert, not_encrypted} | Entries], Acc) ->
	Certificate=#'OTPCertificate'{} = public_key:pkix_decode_cert(Cert, otp),
	pkix_decode_certs(Entries, [{pkix_key(Certificate), Certificate} | Acc]);
pkix_decode_certs([_Entry | Entries], Acc) ->
	pkix_decode_certs(Entries, Acc);
pkix_decode_certs([], Acc) ->
	lists:reverse(Acc).

%% @private
pkix_key(Certificate=#'OTPCertificate'{}) ->
	case public_key:pkix_issuer_id(Certificate, other) of
		{ok, {Serial, Issuer}} ->
			{Issuer, Serial};
		{error, _Reason} ->
			{ok, {Serial, Issuer}} = public_key:pkix_issuer_id(Certificate, self),
			{Issuer, Serial}
	end.
