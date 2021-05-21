-module(woody_cert).

-include_lib("public_key/include/public_key.hrl").

-export([from_req/1]).
-export([get_common_name/1]).

-opaque cert() :: public_key:der_encoded() | #'OTPCertificate'{} | undefined.

-type common_name() :: binary().

-export_type([cert/0, common_name/0]).

%%% API

-spec from_req(cowboy_req:req()) -> cert().
from_req(Req) ->
    cowboy_req:cert(Req).

-spec get_common_name(cert()) -> common_name() | undefined.
get_common_name(undefined) ->
    undefined;
get_common_name(Cert) when is_binary(Cert) ->
    get_common_name(public_key:pkix_decode_cert(Cert, otp));
get_common_name(#'OTPCertificate'{tbsCertificate = TbsCert}) ->
    case get_cn_from_rdn(TbsCert#'OTPTBSCertificate'.subject) of
        [CN] ->
            CN;
        [] ->
            undefined
    end.

%%% Internal functions

get_cn_from_rdn({rdnSequence, RDNSeq}) ->
    [
        to_binary(V)
     || ATVs <- RDNSeq,
        #'AttributeTypeAndValue'{type = ?'id-at-commonName', value = {_T, V}} <- ATVs
    ];
get_cn_from_rdn(_) ->
    [].

to_binary(Str) when is_list(Str) ->
    erlang:list_to_binary(Str);
to_binary(Bin) ->
    Bin.
