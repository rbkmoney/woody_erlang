-module(woody_cert).

-include_lib("public_key/include/public_key.hrl").

-export([get_common_names/1]).

-type cert() :: binary() | #'OTPCertificate'{}.

-spec get_common_names(cert()) -> [string()].

get_common_names(Cert) when is_binary(Cert) ->
    get_common_names(public_key:pkix_decode_cert(Cert, otp));
get_common_names(#'OTPCertificate'{tbsCertificate = TbsCert}) ->
    case TbsCert#'OTPTBSCertificate'.subject of
        {rdnSequence, RDNSeq} ->
            [to_string(V) ||
             ATVs <- RDNSeq, #'AttributeTypeAndValue'{type = ?'id-at-commonName', value = {_T, V}} <- ATVs];
        _ ->
            []
    end.

to_string(B) when is_binary(B) ->
    erlang:binary_to_list(B);
to_string(S) ->
    S.
