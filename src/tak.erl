%%%-------------------------------------------------------------------
%% @copyright Heroku (2013)
%% @author Geoff Cant <nem@erlang.geek.nz>
%% @doc Tak: SSL Certificate Pinning.
%% @end
%%%-------------------------------------------------------------------
-module(tak).

%% Cert extraction functions
-export([pem_to_cert_chain/1
        ,root_cert/1
        ,peer_cert/1
        ,pin/1
        ]).

%% SSL connection helper functions
-export([chain_to_ssl_options/2
        ,pin_to_ssl_options/2
        ,pem_to_ssl_options/2
        ]).

%% SSL Callback function.
-export([verify_pin/3
        ]).

-include_lib("public_key/include/public_key.hrl").

%% Types

-type pem_data() :: iolist().
-type cert() :: #'OTPCertificate'{}.
-type cert_chain() :: [cert()].
-type pin() :: {CACert::cert(),
                PinnedCert::cert()}.
-type ssl_options() :: [ssl:ssl_option()].
%% Options to pass to tak: the certificate to pin,
%% and a boolean saying whether or not to ignore expired certificates
-record (options, { cert :: term(), ignore_expired_certificates :: boolean() }).

%%====================================================================
%% API
%%====================================================================

-spec pem_to_ssl_options(pem_data(), boolean()) -> ssl_options().
pem_to_ssl_options(Pem, IgnoreExpiredCerts) ->
    chain_to_ssl_options(pem_to_cert_chain(Pem), IgnoreExpiredCerts).

-spec pem_to_cert_chain(pem_data()) -> cert_chain().
pem_to_cert_chain(Pem) ->
    sort_chain(pem_to_certs(Pem)).

pem_to_certs(Pem) ->
    [public_key:pkix_decode_cert(Cert, otp)
     || {'Certificate', Cert, not_encrypted}
            <- public_key:pem_decode(iolist_to_binary(Pem)) ].

-spec chain_to_ssl_options(cert_chain(), boolean()) -> [ssl:ssl_option()].
chain_to_ssl_options(CertChain, IgnoreExpiredCerts) ->
    pin_to_ssl_options(pin(CertChain), IgnoreExpiredCerts).

pin_to_ssl_options({CACert, PinCert}, IgnoreExpiredCerts) when is_boolean(IgnoreExpiredCerts) ->
    CADer = public_key:pkix_encode('OTPCertificate', CACert, otp),
    [{cacerts, [CADer]},
     {verify_fun, {fun verify_pin/3, #options{ cert = PinCert, ignore_expired_certificates = IgnoreExpiredCerts }}}].


%%====================================================================
%% Internal functions
%%====================================================================

-spec pin(cert_chain()) -> pin().
pin(Certs) ->
    {root_cert(Certs),
     peer_cert(Certs)}.

-spec root_cert(cert_chain()) -> cert().
root_cert(Certs) ->
    hd(lists:filter(fun public_key:pkix_is_self_signed/1,
                    Certs)).


-spec peer_cert(cert_chain()) -> cert().
peer_cert(Certs) ->
    lists:last(sort_chain(Certs)).

-spec sort_chain(cert_chain()) ->
                        cert_chain() |
                        {error, Reason::term()}.
sort_chain(Certs) ->
    Root = root_cert(Certs),
    sort_chain([Root], lists:delete(Root, Certs)).

sort_chain(Chain, []) -> lists:reverse(Chain);
sort_chain([Current | _] = Chain, Certs) ->
    Issuer = subject(Current),
    case [ Cert
           || Cert <- Certs,
              issuer(Cert) =:= Issuer ] of
        [ Next ] ->
            sort_chain([ Next | Chain ], lists:delete(Next, Certs));
        [] ->
            {error, {bad_chain,
                     {nothing_issued_by, Issuer}}}
    end.

-spec subject(cert()) -> {rdnSequence,
                          [#'AttributeTypeAndValue'{}]}.
subject(#'OTPCertificate'{ tbsCertificate = TBS }) ->
    public_key:pkix_normalize_name(TBS#'OTPTBSCertificate'.subject).

-spec issuer(cert()) -> {rdnSequence,
                         [#'AttributeTypeAndValue'{}]}.
issuer(Cert) ->
    {ok, {_Id, RDN}} = public_key:pkix_issuer_id(Cert, self),
    RDN.

-spec verify_pin(cert(), Event, InitialUserState) ->
                        {valid, UserState :: term()} |
                        {fail, Reason :: term()} |
                        {unknown, UserState :: term()}
                            when
      Event :: {'bad_state', term()} |
               {'extension', term()} |
               valid |
               valid_peer,
      InitialUserState :: options.
verify_pin(PinCert, valid_peer, #options{cert = PinCert}) ->
    {valid, PinCert};
%% It's OK if the pinned certificate is expired, so long as
%% the certificates match and we've enabled the ignore_expired_certificates flag
verify_pin(PinCert,
           {bad_cert, cert_expired},
           #options{cert = PinCert, ignore_expired_certificates = true}) ->
    {valid, PinCert};
verify_pin(_Cert, {extension, _}, #options{cert = PinCert}) ->
    {unknown, PinCert};
verify_pin(_Cert, {bad_cert, _} = Reason, #options{cert = _PinCert}) ->
    {fail, Reason};
verify_pin(_Cert, valid, #options{cert = PinCert}) ->
    {valid, PinCert};
verify_pin(SomeRandomCert, valid_peer, #options{cert = PinCert}) ->
    {fail, {peer_cert_differs_from_pinned,
            subject(SomeRandomCert),
            subject(PinCert)}}.
