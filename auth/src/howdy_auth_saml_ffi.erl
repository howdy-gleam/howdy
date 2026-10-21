-module(howdy_auth_saml_ffi).
-export([request/4, response/6, metadata/2, atoms_spent/0]).
-include_lib("xmerl/include/xmerl.hrl").
-include_lib("public_key/include/public_key.hrl").

%% SAML 2.0 Web Browser SSO, service provider side, in its narrowest useful
%% form: SP-initiated, an unsigned AuthnRequest out by HTTP-Redirect, a signed
%% Response in by HTTP-POST. No encrypted assertions, no IdP-initiated sign-in,
%% no single logout.
%%
%% The verifier trusts nothing the document says about itself. Keys come only
%% from the connection's pinned certificates, never from KeyInfo. Claims are
%% read only from the very element whose signature was verified, or from its
%% one Assertion child, so a signed element cannot vouch for an unsigned
%% sibling (signature wrapping). Algorithms are RSA with SHA-256 or better.

-define(SAML, 'urn:oasis:names:tc:SAML:2.0:assertion').
-define(SAMLP, 'urn:oasis:names:tc:SAML:2.0:protocol').
-define(DS, 'http://www.w3.org/2000/09/xmldsig#').
-define(EXC_C14N, "http://www.w3.org/2001/10/xml-exc-c14n#").
-define(ENVELOPED, "http://www.w3.org/2000/09/xmldsig#enveloped-signature").
-define(BEARER, "urn:oasis:names:tc:SAML:2.0:cm:bearer").
-define(SUCCESS, "urn:oasis:names:tc:SAML:2.0:status:Success").
-define(SKEW, 60).
-define(MAX_BYTES, 262144).
%% xmerl turns every element, attribute and namespace name into an atom, and
%% atoms are never collected. The assertion consumer is reachable before any
%% signature is checked, so names are read without atoms first, and a document
%% is refused once the node has spent this many atoms on SAML names it had not
%% seen before. Real providers share a vocabulary of a few hundred.
-define(ATOM_BUDGET, 5000).

%% --- AuthnRequest -----------------------------------------------------------

%% The SAMLRequest parameter: the request, raw-deflated and base64 encoded.
request(Id, Issuer, Acs, Destination) ->
    Instant = calendar:system_time_to_rfc3339(erlang:system_time(second), [{offset, "Z"}]),
    Xml = [<<"<samlp:AuthnRequest xmlns:samlp=\"urn:oasis:names:tc:SAML:2.0:protocol\"">>,
           <<" xmlns:saml=\"urn:oasis:names:tc:SAML:2.0:assertion\" ID=\"">>, escape(Id),
           <<"\" Version=\"2.0\" IssueInstant=\"">>, Instant,
           <<"\" Destination=\"">>, escape(Destination),
           <<"\" AssertionConsumerServiceURL=\"">>, escape(Acs),
           <<"\" ProtocolBinding=\"urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST\">">>,
           <<"<saml:Issuer>">>, escape(Issuer), <<"</saml:Issuer>">>,
           <<"<samlp:NameIDPolicy AllowCreate=\"true\"/></samlp:AuthnRequest>">>],
    base64:encode(zlib:zip(iolist_to_binary(Xml))).

metadata(EntityId, Acs) ->
    iolist_to_binary(
      [<<"<?xml version=\"1.0\" encoding=\"UTF-8\"?>">>,
       <<"<md:EntityDescriptor xmlns:md=\"urn:oasis:names:tc:SAML:2.0:metadata\" entityID=\"">>,
       escape(EntityId), <<"\"><md:SPSSODescriptor AuthnRequestsSigned=\"false\"">>,
       <<" WantAssertionsSigned=\"true\"">>,
       <<" protocolSupportEnumeration=\"urn:oasis:names:tc:SAML:2.0:protocol\">">>,
       <<"<md:NameIDFormat>urn:oasis:names:tc:SAML:2.0:nameid-format:persistent</md:NameIDFormat>">>,
       <<"<md:AssertionConsumerService index=\"0\" isDefault=\"true\"">>,
       <<" Binding=\"urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST\" Location=\"">>,
       escape(Acs), <<"\"/></md:SPSSODescriptor></md:EntityDescriptor>">>]).

escape(Value) ->
    lists:foldl(fun({From, To}, Acc) -> binary:replace(Acc, From, To, [global]) end, Value,
                [{<<"&">>, <<"&amp;">>}, {<<"<">>, <<"&lt;">>}, {<<">">>, <<"&gt;">>},
                 {<<"\"">>, <<"&quot;">>}, {<<"'">>, <<"&apos;">>}]).

%% --- Response ---------------------------------------------------------------

%% {ok, {InResponseTo, NameId, Email}} for a Response that proves an identity
%% to this service provider, now. Email is empty when none was asserted.
response(Encoded, Certificates, AcsUrl, Audience, Issuer, Now)
  when byte_size(Encoded) =< ?MAX_BYTES * 2 ->
    try
        %% xmerl attribute values are character lists; element text is binary.
        Acs = unicode:characters_to_list(AcsUrl),
        Xml = base64:decode(Encoded),
        true = byte_size(Xml) =< ?MAX_BYTES,
        %% No DTD means no entities to expand and nothing external to fetch.
        nomatch = binary:match(Xml, [<<"<!DOCTYPE">>, <<"<!ENTITY">>]),
        case spend_atoms(Xml) of
            ok -> verified(Xml, Certificates, Acs, Audience, Issuer, Now);
            %% Over budget is a refusal like any other, never a crash: the
            %% caller maps {error, nil} to an unauthorized sign-in.
            {error, atom_budget} -> {error, nil}
        end
    catch _:_ -> {error, nil} end;
response(_, _, _, _, _, _) -> {error, nil}.

verified(Xml, Certificates, Acs, Audience, Issuer, Now) ->
    try
        Keys = [key(Pem) || Pem <- Certificates],
        true = Keys =/= [],
        %% Comments are dropped at parse: canonical XML omits them, and a
        %% value split by one is then read whole rather than up to the comment.
        %% xmerl decodes UTF-8 itself and wants the bytes, not codepoints.
        true = is_list(unicode:characters_to_list(Xml, utf8)),
        {Root, _} = xmerl_scan:string(binary_to_list(Xml),
                                      [{namespace_conformant, true}, {comments, false},
                                       {quiet, true}]),
        {?SAMLP, 'Response'} = Root#xmlElement.expanded_name,
        Acs = attribute(Root, 'Destination'),
        InResponseTo = attribute(Root, 'InResponseTo'),
        true = InResponseTo =/= undefined,
        [Status] = children(Root, {?SAMLP, 'Status'}),
        [Code] = children(Status, {?SAMLP, 'StatusCode'}),
        ?SUCCESS = attribute(Code, 'Value'),
        [] = descendants(Root, {?SAML, 'EncryptedAssertion'}),
        %% One assertion in the whole document, and it is the Response's child.
        [Assertion] = children(Root, {?SAML, 'Assertion'}),
        [_] = descendants(Root, {?SAML, 'Assertion'}),
        %% Every signature present must verify, and the assertion must be
        %% covered by at least one: its own, or the Response's around it.
        Signed = [signed(Root, Keys), signed(Assertion, Keys)],
        false = lists:member(invalid, Signed),
        true = lists:member(valid, Signed),
        case children(Root, {?SAML, 'Issuer'}) of
            [] -> ok;
            [Outer] -> Issuer = text(Outer)
        end,
        [Inner] = children(Assertion, {?SAML, 'Issuer'}),
        Issuer = text(Inner),
        [Subject] = children(Assertion, {?SAML, 'Subject'}),
        [NameIdElement] = children(Subject, {?SAML, 'NameID'}),
        NameId = text(NameIdElement),
        true = NameId =/= <<>> andalso byte_size(NameId) =< 256,
        true = lists:any(fun(C) -> bearer(C, Acs, InResponseTo, Now) end,
                         children(Subject, {?SAML, 'SubjectConfirmation'})),
        [Conditions] = children(Assertion, {?SAML, 'Conditions'}),
        true = before(attribute(Conditions, 'NotBefore'), Now + ?SKEW),
        true = after_(attribute(Conditions, 'NotOnOrAfter'), Now - ?SKEW),
        Restrictions = children(Conditions, {?SAML, 'AudienceRestriction'}),
        true = Restrictions =/= [],
        true = lists:all(fun(R) ->
                   lists:member(Audience, [text(A) || A <- children(R, {?SAML, 'Audience'})])
               end, Restrictions),
        {ok, {unicode:characters_to_binary(InResponseTo), NameId,
              email(Assertion, NameId)}}
    catch _:_ -> {error, nil} end.

bearer(Confirmation, Acs, InResponseTo, Now) ->
    try
        ?BEARER = attribute(Confirmation, 'Method'),
        [Data] = children(Confirmation, {?SAML, 'SubjectConfirmationData'}),
        Acs = attribute(Data, 'Recipient'),
        InResponseTo = attribute(Data, 'InResponseTo'),
        %% A bearer confirmation is never valid from some future time.
        undefined = attribute(Data, 'NotBefore'),
        after_(attribute(Data, 'NotOnOrAfter'), Now - ?SKEW)
    catch _:_ -> false end.

%% An absent bound is no bound for NotBefore; NotOnOrAfter must be present.
before(undefined, _) -> true;
before(Instant, Limit) -> seconds(Instant) =< Limit.
after_(Instant, Limit) when Instant =/= undefined -> seconds(Instant) > Limit.

seconds(Instant) -> calendar:rfc3339_to_system_time(Instant, [{unit, second}]).

email(Assertion, NameId) ->
    Names = [<<"email">>, <<"mail">>, <<"emailaddress">>, <<"user.email">>,
             <<"urn:oid:0.9.2342.19200300.100.1.3">>,
             <<"http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress">>],
    Found = [text(Value)
             || Statement <- children(Assertion, {?SAML, 'AttributeStatement'}),
                Attribute <- children(Statement, {?SAML, 'Attribute'}),
                lists:member(lower(attribute(Attribute, 'Name')), Names),
                Value <- children(Attribute, {?SAML, 'AttributeValue'})],
    %% Okta's default is an address as the NameID, under the "unspecified"
    %% format and with no attribute. The caller keeps it only if it parses as
    %% an address, and believes it only inside the connection's domains.
    case Found of
        [Email | _] -> Email;
        [] -> NameId
    end.

lower(undefined) -> <<>>;
lower(Value) -> string:lowercase(unicode:characters_to_binary(Value)).

%% --- XML signature ----------------------------------------------------------

%% none when Element carries no signature of its own; otherwise whether that
%% signature is an enveloped RSA signature over exactly Element by a pinned key.
signed(Element, Keys) ->
    case children(Element, {?DS, 'Signature'}) of
        [] -> none;
        [Signature] ->
            try
                true = verify(Element, Signature, Keys),
                valid
            catch _:_ -> invalid end;
        _ -> invalid
    end.

verify(Element, Signature, Keys) ->
    [Info] = children(Signature, {?DS, 'SignedInfo'}),
    [Canonical] = children(Info, {?DS, 'CanonicalizationMethod'}),
    ?EXC_C14N = attribute(Canonical, 'Algorithm'),
    [Method] = children(Info, {?DS, 'SignatureMethod'}),
    Hash = signature_hash(attribute(Method, 'Algorithm')),
    %% The one reference must name the element that carries this signature.
    [Reference] = children(Info, {?DS, 'Reference'}),
    Id = attribute(Element, 'ID'),
    true = is_list(Id) andalso Id =/= [],
    true = attribute(Reference, 'URI') =:= "#" ++ Id,
    [Transforms] = children(Reference, {?DS, 'Transforms'}),
    Applied = children(Transforms, {?DS, 'Transform'}),
    true = length(Applied) =< 2,
    Algorithms = [attribute(T, 'Algorithm') || T <- Applied],
    true = lists:member(?ENVELOPED, Algorithms),
    [] = Algorithms -- [?ENVELOPED, ?EXC_C14N],
    Prefixes = lists:append([prefixes(T) || T <- Applied]),
    [DigestMethod] = children(Reference, {?DS, 'DigestMethod'}),
    DigestHash = digest_hash(attribute(DigestMethod, 'Algorithm')),
    [DigestValue] = children(Reference, {?DS, 'DigestValue'}),
    Stripped = Element#xmlElement{
        content = [K || K <- Element#xmlElement.content, K =/= Signature]},
    Digest = crypto:hash(DigestHash, canonical(Stripped, Prefixes)),
    true = howdy_auth_ffi:constant_time_equal(Digest, base64:decode(text(DigestValue))),
    [Value] = children(Signature, {?DS, 'SignatureValue'}),
    Proof = base64:decode(text(Value)),
    Data = canonical(Info, prefixes(Canonical)),
    lists:any(fun(Key) -> public_key:verify(Data, Hash, Proof, Key) end, Keys).

canonical(Element, Prefixes) ->
    unicode:characters_to_binary(howdy_auth_c14n:c14n(Element, false, Prefixes), unicode, utf8).

prefixes(Element) ->
    case [attribute(E, 'PrefixList')
          || E <- children(Element, {'http://www.w3.org/2001/10/xml-exc-c14n#', 'InclusiveNamespaces'})] of
        [List] when is_list(List) -> string:tokens(List, " ");
        _ -> []
    end.

signature_hash("http://www.w3.org/2001/04/xmldsig-more#rsa-sha256") -> sha256;
signature_hash("http://www.w3.org/2001/04/xmldsig-more#rsa-sha384") -> sha384;
signature_hash("http://www.w3.org/2001/04/xmldsig-more#rsa-sha512") -> sha512.

digest_hash("http://www.w3.org/2001/04/xmlenc#sha256") -> sha256;
digest_hash("http://www.w3.org/2001/04/xmldsig-more#sha384") -> sha384;
digest_hash("http://www.w3.org/2001/04/xmlenc#sha512") -> sha512.

key(Pem) ->
    [{'Certificate', Der, not_encrypted}] = public_key:pem_decode(Pem),
    Certificate = public_key:pkix_decode_cert(Der, otp),
    Info = (Certificate#'OTPCertificate'.tbsCertificate)#'OTPTBSCertificate'.subjectPublicKeyInfo,
    Key = #'RSAPublicKey'{modulus = Modulus} = Info#'OTPSubjectPublicKeyInfo'.subjectPublicKey,
    true = Modulus >= (1 bsl 2047),
    Key.

%% --- XML helpers ------------------------------------------------------------

children(#xmlElement{content = Content}, Name) ->
    [E || E = #xmlElement{expanded_name = N} <- Content, N =:= Name].

descendants(#xmlElement{content = Content}, Name) ->
    lists:append([[E || E#xmlElement.expanded_name =:= Name] ++ descendants(E, Name)
                  || E = #xmlElement{} <- Content]).

%% Unqualified attributes only: SAML and XML signature define no others here.
attribute(#xmlElement{attributes = Attributes}, Name) ->
    case [V || #xmlAttribute{name = N, value = V} <- Attributes, N =:= Name] of
        [Value] -> Value;
        [] -> undefined
    end.

%% All of an element's text, never just its first node.
text(#xmlElement{content = Content}) ->
    true = lists:all(fun(#xmlText{}) -> true; (_) -> false end, Content),
    string:trim(unicode:characters_to_binary([V || #xmlText{value = V} <- Content])).

%% --- Atom budget ------------------------------------------------------------

spend_atoms(Xml) ->
    Collect = fun({startElement, Uri, Local, {Prefix, _}, Attributes}, _, Names) ->
                      [Uri, Local, qualified(Prefix, Local)
                       | [N || {AttrUri, AttrPrefix, AttrLocal, _} <- Attributes,
                               N <- [AttrUri, AttrLocal, qualified(AttrPrefix, AttrLocal)]]] ++ Names;
                 ({startPrefixMapping, Prefix, Uri}, _, Names) -> [Prefix, Uri | Names];
                 (_, _, Names) -> Names
              end,
    {ok, Names, _} = xmerl_sax_parser:stream(Xml, [{event_fun, Collect}, {event_state, []},
                                                   {encoding, utf8}]),
    Fresh = [N || N <- lists:usort(Names), N =/= [], not known(N)],
    Counter = counter(),
    case counters:get(Counter, 1) + length(Fresh) =< ?ATOM_BUDGET of
        true ->
            counters:add(Counter, 1, length(Fresh)),
            ok;
        false ->
            {error, atom_budget}
    end.

%% How many atoms SAML names have cost this node so far.
atoms_spent() -> counters:get(counter(), 1).

qualified([], Local) -> Local;
qualified(Prefix, Local) -> Prefix ++ ":" ++ Local.

known(Name) ->
    try list_to_existing_atom(Name) of _ -> true
    catch error:badarg -> false end.

%% One counter for the life of the VM. The table owner decides the race to
%% create it, as it does for cache generations: two request processes racing
%% to create their own would each start a fresh budget.
counter() -> howdy_auth_tables:counter(howdy_auth_saml_atoms).
