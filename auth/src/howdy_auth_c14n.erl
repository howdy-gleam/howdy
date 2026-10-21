%% Vendored from esaml 4.6.0 (https://github.com/dropbox/esaml), src/xmerl_c14n.erl.
%% Changes: the module is renamed so it cannot collide with an application's own
%% esaml, and the eunit tests, which need the rest of esaml, are dropped.
%% Howdy uses only this canonicaliser; signature verification is its own, in
%% howdy_auth_saml_ffi. The original licence follows and applies to this file.
%%
%% Copyright (c) 2013, Alex Wilson and the University of Queensland
%% Copyright (c) 2021 Dropbox, Inc.
%% All rights reserved.
%%
%% Redistribution and use in source and binary forms, with or without modification,
%% are permitted provided that the following conditions are met:
%%
%%  * Redistributions of source code must retain the above copyright notice,
%%    this list of conditions and the following disclaimer.
%%  * Redistributions in binary form must reproduce the above copyright notice,
%%    this list of conditions and the following disclaimer in the documentation and/or
%%    other materials provided with the distribution.
%%
%% THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY
%% EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
%% OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT
%% SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
%% INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
%% TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR
%% BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
%% CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY
%% WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

%% esaml - SAML for erlang
%%
%% Copyright (c) 2013, Alex Wilson and the University of Queensland
%% All rights reserved.
%%
%% Distributed subject to the terms of the 2-clause BSD license, see
%% the LICENSE file in the root of the distribution.

%% @doc XML canonocialisation for xmerl
%%
%% Functions for performing XML canonicalisation (C14n), as specified
%% at http://www.w3.org/TR/xml-c14n .
%%
%% These routines work on xmerl data structures (see the xmerl user guide
%% for details).
-module(howdy_auth_c14n).

-export([c14n/3, c14n/2, c14n/1, xml_safe_string/2, xml_safe_string/1, canon_name/1]).

-include_lib("xmerl/include/xmerl.hrl").
-include_lib("public_key/include/public_key.hrl").

%% @doc Returns the canonical namespace-URI-prefix-resolved version of an XML name.
%% @private
-spec canon_name(Prefix :: string(), Name :: string() | atom(), Nsp :: #xmlNamespace{}) -> string().
canon_name(Ns, Name, Nsp) ->
    NsPartRaw = case Ns of
        empty -> Nsp#xmlNamespace.default;
        [] ->
            if Nsp == [] -> 'urn:oasis:names:tc:SAML:2.0:assertion';
               true -> Nsp#xmlNamespace.default
            end;
        _ ->
            case proplists:get_value(Ns, Nsp#xmlNamespace.nodes) of
                undefined ->
                    error({ns_not_found, Ns, Nsp});
                Uri -> atom_to_list(Uri)
            end
    end,
    NsPart = if is_atom(NsPartRaw) -> atom_to_list(NsPartRaw); true -> NsPartRaw end,
    NamePart = if is_atom(Name) -> atom_to_list(Name); true -> Name end,
    lists:flatten([NsPart | NamePart]).

%% @doc Returns the canonical URI name of an XML element or attribute.
%% @private
-spec canon_name(#xmlElement{} | #xmlAttribute{}) -> string().
canon_name(#xmlAttribute{name = Name, nsinfo = Exp, namespace = Nsp}) ->
    case Exp of
        {Ns, Nme} -> canon_name(Ns, Nme, Nsp);
        _ -> canon_name([], Name, Nsp)
    end;
canon_name(#xmlElement{name = Name, nsinfo = Exp, namespace = Nsp}) ->
    case Exp of
        {Ns, Nme} -> canon_name(Ns, Nme, Nsp);
        _ -> canon_name([], Name, Nsp)
    end.

%% @doc Compares two XML attributes for c14n purposes
-spec attr_lte(A :: #xmlAttribute{}, B :: #xmlAttribute{}) -> true | false.
attr_lte(AttrA, AttrB) ->
    A = canon_name(AttrA), B = canon_name(AttrB),
    PrefixedA = case AttrA#xmlAttribute.nsinfo of {_, _} -> true; _ -> false end,
    PrefixedB = case AttrB#xmlAttribute.nsinfo of {_, _} -> true; _ -> false end,
    if (PrefixedA) andalso (not PrefixedB) ->
        false;
    (not PrefixedA) andalso (PrefixedB) ->
        true;
    true ->
        A =< B
    end.

%% @doc Cleans out all namespace definitions from an attribute list and returns it sorted.
%% @private
-spec clean_sort_attrs(Attrs :: [#xmlAttribute{}]) -> [#xmlAttribute{}].
clean_sort_attrs(Attrs) ->
    lists:sort(fun(A,B) ->
        attr_lte(A, B)
    end, lists:filter(fun(Attr) ->
        case Attr#xmlAttribute.nsinfo of
            {"xmlns", _} -> false;
            _ -> case Attr#xmlAttribute.name of
                'xmlns' -> false;
                _ -> true
            end
        end
    end, Attrs)).

%% @doc Returns the list of namespace prefixes "needed" by an element in canonical form
%% @private
-spec needed_ns(Elem :: #xmlElement{}, InclNs :: [string()]) -> [string()].
needed_ns(#xmlElement{nsinfo = NsInfo, attributes = Attrs}, InclNs) ->
    NeededNs1 = case NsInfo of
        {Nas, _} -> [Nas];
        _ -> []
    end,
    % show through namespaces that apply at the bottom level? this part of the spec is retarded
    %KidElems = [K || K <- Kids, element(1, K) =:= xmlElement],
    NeededNs2 = NeededNs1, %case KidElems of
        %[] -> [K || {K,V} <- E#xmlElement.namespace#xmlNamespace.nodes];
        %_ -> NeededNs1
    %end,
    lists:foldl(fun(Attr, Needed) ->
        case Attr#xmlAttribute.nsinfo of
            {"xmlns", Prefix} ->
                case lists:member(Prefix, InclNs) and not lists:member(Prefix, Needed) of
                    true -> [Prefix | Needed];
                    _ -> Needed
                end;
            {Ns, _Name} ->
                case lists:member(Ns, Needed) of
                    true -> Needed;
                    _ -> [Ns | Needed]
                end;
            _ -> Needed
        end
    end, NeededNs2, Attrs).

%% @doc Make xml ok to eat, in a non-quoted situation.
%% @private
-spec xml_safe_string(term()) -> string().
xml_safe_string(Term) -> xml_safe_string(Term, false).

%% @doc Make xml ok to eat
%% @private
-spec xml_safe_string(String :: term(), Quotes :: boolean()) -> string().
xml_safe_string(Atom, Quotes) when is_atom(Atom) -> xml_safe_string(atom_to_list(Atom), Quotes);
xml_safe_string(Bin, Quotes) when is_binary(Bin) -> xml_safe_string(binary_to_list(Bin), Quotes);
xml_safe_string([], _) -> [];
xml_safe_string(Str, Quotes) when is_list(Str) ->
    [Next | Rest] = Str,
    if
        (not Quotes andalso ([Next] =:= "\n")) -> [Next | xml_safe_string(Rest, Quotes)];
        (Next < 32) ->
            lists:flatten(["&#x" ++ integer_to_list(Next, 16) ++ ";" | xml_safe_string(Rest, Quotes)]);
        (Quotes andalso ([Next] =:= "\"")) -> lists:flatten(["&quot;" | xml_safe_string(Rest, Quotes)]);
        ([Next] =:= "&") -> lists:flatten(["&amp;" | xml_safe_string(Rest, Quotes)]);
        ([Next] =:= "<") -> lists:flatten(["&lt;" | xml_safe_string(Rest, Quotes)]);
        (not Quotes andalso ([Next] =:= ">")) -> lists:flatten(["&gt;" | xml_safe_string(Rest, Quotes)]);
        true -> [Next | xml_safe_string(Rest, Quotes)]
    end;
xml_safe_string(Term, Quotes) ->
    xml_safe_string(io_lib:format("~p", [Term]), Quotes).

%% @doc Worker function for canonicalisation (c14n). It accumulates the canonical string data
%%      for a given XML "thing" (element/attribute/whatever)
%% @private
-type xml_thing() :: #xmlDocument{} | #xmlElement{} | #xmlAttribute{} | #xmlPI{} | #xmlText{} | #xmlComment{}.
-spec c14n(XmlThing :: xml_thing(), KnownNs :: [{string(), string()}], ActiveNS :: [string()], Comments :: boolean(), InclNs :: [string()], Acc :: [string() | number()]) -> [string() | number()].

c14n(#xmlText{value = Text}, _KnownNS, _ActiveNS, _Comments, _InclNs, Acc) ->
    [xml_safe_string(Text) | Acc];

c14n(#xmlComment{value = Text}, _KnownNS, _ActiveNS, true, _InclNs, Acc) ->
    ["-->", xml_safe_string(Text), "<!--" | Acc];

c14n(#xmlPI{name = Name, value = Value}, _KnownNS, _ActiveNS, _Comments, _InclNs, Acc) ->
    NameString = if is_atom(Name) -> atom_to_list(Name); true -> string:strip(Name) end,
    case string:strip(Value) of
        [] -> ["?>", NameString, "<?" | Acc];
        _ -> ["?>", Value, " ", NameString, "<?" | Acc]
    end;

c14n(#xmlDocument{content = Kids}, KnownNS, ActiveNS, Comments, InclNs, Acc) ->
    case lists:foldl(fun(Kid, AccIn) ->
        case c14n(Kid, KnownNS, ActiveNS, Comments, InclNs, AccIn) of
            AccIn -> AccIn;
            Other -> ["\n" | Other]
        end
    end, Acc, Kids) of
        ["\n" | Rest] -> Rest;
        Other -> Other
    end;

c14n(#xmlAttribute{nsinfo = NsInfo, name = Name, value = Value}, _KnownNs, ActiveNS, _Comments, _InclNs, Acc) ->
    case NsInfo of
        {Ns, NName} ->
            case lists:member(Ns, ActiveNS) of
                true -> ["\"",xml_safe_string(Value, true),"=\"",NName,":",Ns," " | Acc];
                _ -> error("attribute namespace is not active")
            end;
        _ ->
            ["\"",xml_safe_string(Value, true),"=\"",atom_to_list(Name)," " | Acc]
    end;

c14n(Elem = #xmlElement{}, KnownNSIn, ActiveNSIn, Comments, InclNs, Acc) ->
    Namespace = Elem#xmlElement.namespace,
    Default = case Elem#xmlElement.nsinfo of
        [] -> Namespace#xmlNamespace.default;
        _ -> [] % omit a default namespace if it is not visibly utilized.
    end,
    {ActiveNS, ParentDefault} = case ActiveNSIn of
        [{default, P} | Rest] -> {Rest, P};
        Other -> {Other, ''}
    end,
    % add any new namespaces this element has that we haven't seen before
    KnownNS = lists:foldl(fun({Ns, Uri}, Nss) ->
        case proplists:is_defined(Ns, Nss) of
            true -> Nss;
            _ -> [{Ns, atom_to_list(Uri)} | Nss]
        end
    end, KnownNSIn, Namespace#xmlNamespace.nodes),

    % now figure out the minimum set of namespaces we need at this level
    NeededNs = needed_ns(Elem, InclNs),
    % and all of the attributes that aren't xmlns
    Attrs = clean_sort_attrs(Elem#xmlElement.attributes),

    % we need to append any xmlns: that our parent didn't have (ie, aren't in ActiveNS) but
    % that we need
    NewNS = NeededNs -- ActiveNS,
    NewActiveNS = ActiveNS ++ NewNS,

    % the opening tag
    Acc1 = case Elem#xmlElement.nsinfo of
        {ENs, EName} ->
            [EName, ":", ENs, "<" | Acc];
        _ ->
            [atom_to_list(Elem#xmlElement.name), "<" | Acc]
    end,
    % xmlns definitions
    {Acc2, FinalActiveNS} = if
        not (Default =:= []) andalso not (Default =:= ParentDefault) ->
            {["\"", xml_safe_string(Default, true), " xmlns=\"" | Acc1], [{default, Default} | NewActiveNS]};
        not (Default =:= []) ->
            {Acc1, [{default, Default} | NewActiveNS]};
        true ->
            {Acc1, NewActiveNS}
    end,
    Acc3 = lists:foldl(fun(Ns, AccIn) ->
        ["\"",xml_safe_string(proplists:get_value(Ns, KnownNS, ""), true),"=\"",Ns,":"," xmlns" | AccIn]
    end, Acc2, lists:sort(NewNS)),
    % any other attributes
    Acc4 = lists:foldl(fun(Attr, AccIn) ->
        c14n(Attr, KnownNS, FinalActiveNS, Comments, InclNs, AccIn)
    end, Acc3, Attrs),
    % close the opening tag
    Acc5 = [">" | Acc4],

    % now accumulate all our children
    Acc6 = lists:foldl(fun(Kid, AccIn) ->
        c14n(Kid, KnownNS, FinalActiveNS, Comments, InclNs, AccIn)
    end, Acc5, Elem#xmlElement.content),

    % and finally add the close tag
    case Elem#xmlElement.nsinfo of
        {Ns, Name} ->
            [">", Name, ":", Ns, "</" | Acc6];
        _ ->
            [">",atom_to_list(Elem#xmlElement.name),"</" | Acc6]
    end;

% I do not give a shit
c14n(_, _KnownNS, _ActiveNS, _Comments, _InclNs, Acc) ->
    Acc.

%% @doc Puts an XML document or element into canonical form, as a string.
-spec c14n(XmlThing :: xml_thing()) -> string().
c14n(Elem) ->
    c14n(Elem, true).

%% @doc Puts an XML document or element into canonical form, as a string.
%%
%% If the Comments argument is true, preserves comments in the output.
-spec c14n(XmlThing :: xml_thing(), Comments :: boolean()) -> string().
c14n(Elem, Comments) ->
    c14n(Elem, Comments, []).

%% @doc Puts an XML document or element into canonical form, as a string.
%%
%% If the Comments argument is true, preserves comments in the output. Any
%% namespace prefixes listed in InclusiveNs will be left as they are and not
%% modified during canonicalization.
-spec c14n(XmlThing :: xml_thing(), Comments :: boolean(), InclusiveNs :: [string()]) -> string().
c14n(Elem, Comments, InclusiveNs) ->
    lists:flatten(lists:reverse(c14n(Elem, [], [], Comments, InclusiveNs, []))).
