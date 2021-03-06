%%
%% %CopyrightBegin%
%%
%% Copyright (c) 2015-2016, Varoun. P <contact@varoun.com>.
%% All rights reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
%% %CopyrightEnd%
%%

%% Parser for rotor.conf

Nonterminals option options keyvals vals rconf rconfs gconf.

Terminals beginrotation endrotation keyval openangle closeangle opensquare closesquare equals.

Rootsymbol gconf.

keyvals -> keyval : ['$1'].
keyvals -> keyval keyvals : ['$1'|'$2'].

vals -> opensquare keyvals closesquare : '$2'.

option -> keyval equals keyval : make_option('$1', '$3').
option -> keyval equals vals : make_option('$1', '$3').
options -> option : ['$1'].
options -> option options : ['$1'| '$2'].

rconf ->
    openangle beginrotation keyval closeangle options openangle endrotation closeangle :
        make_rconf('$3', '$5').
rconfs -> rconf : ['$1'].
rconfs -> rconf rconfs : ['$1'|'$2'].

gconf -> options rconfs : make_gconf('$1', '$2').

Erlang code.

make_option({keyval, _LineNo, Key}, {keyval, _LineNo, Val}) ->
    {Key, Val};
make_option({keyval, _LineNo, Key}, Vals) ->
    {Key, [Val || {keyval, _LN, Val} <- Vals]}.

make_rconf({keyval, _LineNo, RName}, ROptions) ->
    [{rname, RName}, {roptions, ROptions}].

make_gconf(GlobalOptions, RotationOptions) ->
    [GlobalOptions, RotationOptions].
