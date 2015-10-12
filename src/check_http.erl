-module(check_http).
-behaviour(gen_server).

-include("common.hrl").

%% API
-export([start_link/1, check/1]).

%% gen_server callbacks.
-export([init/1, handle_call/3, handle_cast/2,
        handle_info/2, terminate/2, code_change/3]).

%%%% API -----------------------------------------------------------------------

start_link(#realconf{ip=IP, ping_port=Port} = Options) ->
    gen_server:start_link({local,
                           list_to_atom(IP ++ ":" ++ integer_to_list(Port))},
                          ?MODULE,
                          Options, []).

check(Real) ->
    gen_server:call(Real, check_health).

%%%% gen_server callbacks ------------------------------------------------------

init(#realconf{ip=IP, ping_protocol=http, ping_port=Port,
               ping_path=Path} = Options) ->
    timer:send_after(?WAITTIME, self(), trigger),
    {ok, [#checkstate{options = Options},
          {url, "http://" ++ IP ++ ":" ++ integer_to_list(Port) ++ Path},
          {requestid, none}]};
init(#realconf{} = Options) ->
    timer:send_after(?WAITTIME, self(), trigger),
    {ok, [#checkstate{options = Options}, tcp_check]}.

handle_call(check_health, _From,
            [#checkstate{status = Status}, _URL, _ReqID] = State) ->
    {reply, Status, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

%% NOTE(varoun): Should requestid in the message be none ?
handle_info(trigger,
            [#checkstate{options = Options} = CheckState,
             {url, URL},
             _ReqID] = _State) ->
    {ok, RequestID} =
        httpc:request(get,
                      {URL, []},
                      [{timeout, Options#realconf.response_timeout}],
                      [{sync, false}, {receiver, self()}]),
    timer:send_after(Options#realconf.check_interval, self(), trigger),
    {noreply, [CheckState,
               {url, URL},
               {requestid, RequestID}]};
handle_info({http, {RequestID, Result}},
            [#checkstate{options = Options,
                         healthy_count = HealthyCount,
                         unhealthy_count = UnhealthyCount,
                         status = Status} = CheckState,
             URL,
             {requestid, RequestID}] = _State) ->
    case Result of
        {{_Version, 200, _ReasonPhrase}, _Headers, _Body}
          when Status =:= healthy ->
            {noreply, [CheckState#checkstate{healthy_count = 0,
                                             unhealthy_count = 0},
                       URL,
                       {requestid, none}]};
        {{_Version, 200, _ReasonPhrase}, _Headers, _Body}
          when Status =:= unhealthy
               andalso HealthyCount < Options#realconf.healthy_threshold ->
            lager:notice("Service ~p transitioning to status HEALTHY", [URL]),
            {noreply, [CheckState#checkstate{healthy_count = HealthyCount + 1,
                                             unhealthy_count = 0},
                       URL,
                       {requestid, none}]};
        {{_Version, 200, _ReasonPhrase}, _Headers, _Body}
          when Status =:= unhealthy
               andalso HealthyCount =:= Options#realconf.healthy_threshold ->
            lager:notice("Service ~p has transitioned to status HEALTHY", [URL]),
            gen_server:cast(list_to_atom(Options#realconf.name), trigger),
            {noreply, [CheckState#checkstate{unhealthy_count = 0, status = healthy},
                       URL,
                       {requestid, none}]};
        {{_Version, _ResponseCode, _ReasonPhrase}, _Headers, _Body}
          when Status =:= unhealthy ->
            {noreply, [CheckState#checkstate{healthy_count = 0,
                                             unhealthy_count = 0},
                       URL,
                       {requestid, none}]};
        {{_Version, _ResponseCode, _ReasonPhrase}, _Headers, _Body}
          when Status =:= healthy
               andalso UnhealthyCount < Options#realconf.unhealthy_threshold ->
            lager:notice("Service ~p transitioning to status UNHEALTHY", [URL]),
            {noreply, [CheckState#checkstate{healthy_count = 0,
                                             unhealthy_count = UnhealthyCount + 1},
                       URL,
                       {requestid, none}]};
        {{_Version, _ResponseCode, _ReasonPhrase}, _Headers, _Body}
          when Status =:= healthy
               andalso UnhealthyCount =:= Options#realconf.unhealthy_threshold ->
            lager:notice("Service ~p has transitioned to status UNHEALTHY", [URL]),
            gen_server:cast(list_to_atom(Options#realconf.name), trigger),
            {noreply, [CheckState#checkstate{healthy_count = 0,
                                             status = unhealthy},
                       URL,
                       {requestid, none}]};

        {error, _Reason}
          when Status =:= unhealthy ->
            {noreply, [CheckState#checkstate{healthy_count = 0,
                                             unhealthy_count = 0},
                       URL,
                       {requestid, none}]};
        {error, _Reason}
          when Status =:= healthy
               andalso UnhealthyCount < Options#realconf.unhealthy_threshold ->
            lager:notice("Service ~p transitioning to status UNHEALTHY", [URL]),
            {noreply, [CheckState#checkstate{healthy_count = 0,
                                             unhealthy_count = UnhealthyCount + 1},
                       URL,
                       {requestid, none}]};
        {error, _Reason}
          when Status =:= healthy
               andalso UnhealthyCount =:= Options#realconf.unhealthy_threshold ->
            lager:notice("Service ~p has transitioned to status UNHEALTHY", [URL]),
            gen_server:cast(list_to_atom(Options#realconf.name), trigger),
            {noreply, [CheckState#checkstate{healthy_count = 0,
                                             status = unhealthy},
                       URL,
                       {requestid, none}]}
    end;

handle_info(trigger, [#checkstate{options=Options,
                                   healthy_count=HealthyCount,
                                   unhealthy_count=UnhealthyCount,
                                   status=Status} = CheckState,
                      tcp_check]) ->
    IP = Options#realconf.ip,
    PORT = Options#realconf.ping_port,
    case gen_tcp:connect(IP, PORT, [], Options#realconf.response_timeout) of
        {ok, Socket} when Status =:= healthy ->
            gen_tcp:close(Socket),
            {noreply, [CheckState#checkstate{healthy_count=0,
                                             unhealthy_count=0},
                       tcp_check]};
        {ok, Socket} when Status =:= unhealthy andalso
                          HealthyCount < Options#realconf.healthy_threshold ->
            gen_tcp:close(Socket),
            lager:notice("Service ~p transitioning to status HEALTHY",
                         [IP ++ ":" ++ PORT]),
            {noreply, [CheckState#checkstate{healthy_count = HealthyCount + 1,
                                             unhealthy_count = 0},
                       tcp_check]};
        {ok, Socket} when Status =:= unhealthy andalso
                          HealthyCount =:= Options#realconf.healthy_threshold ->
            gen_tcp:close(Socket),
            lager:notice("Service ~p has transitioned to status HEALTHY",
                         [IP ++ ":" ++ PORT]),
            gen_server:cast(list_to_atom(Options#realconf.name), trigger),
            {noreply, [CheckState#checkstate{unhealthy_count = 0, status = healthy},
                       tcp_check]};
        {error, _Reason} when Status =:= unhealthy ->
            {noreply, [CheckState#checkstate{healthy_count = 0,
                                             unhealthy_count = 0},
                       tcp_check]};
        {error, _Reason} when Status =:= healthy andalso
                              UnhealthyCount < Options#realconf.unhealthy_threshold ->
            lager:notice("Service ~p transitioning to status UNHEALTHY",
                         [IP ++ ":" ++ PORT]),
            {noreply, [CheckState#checkstate{healthy_count = 0,
                                             unhealthy_count = UnhealthyCount + 1},
                       tcp_check]};
        {error, _Reason} when Status =:= healthy andalso
                              UnhealthyCount =:= Options#realconf.unhealthy_threshold ->
            lager:notice("Service ~p has transitioned to status UNHEALTHY",
                         [IP ++ ":" ++ PORT]),
            gen_server:cast(list_to_atom(Options#realconf.name), trigger),
            {noreply, [CheckState#checkstate{healthy_count = 0,
                                             status = unhealthy},
                       tcp_check]}
    end;

%% NOTE(varoun): Delete the next function?
handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
