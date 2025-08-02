%% 广告播放设备管理系统
%% 文件: ad_device_system.erl

-module(ad_device_system).
-behaviour(gen_server).

%% API exports
-export([start_link/0, stop/0, get_device_status/0, get_device_info/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%% 设备进程相关exports
-export([start_devices/1, device_process/1, heartbeat_server/2, http_server/1]).

-define(DEVICE_COUNT, 3).
-define(HEARTBEAT_INTERVAL, 5000).  % 5秒心跳间隔
-define(CRASH_PROBABILITY, 0.02).   % 2%崩溃概率
-define(TCP_PORT, 18888).
-define(UDP_PORT, 18889).
-define(HTTP_PORT, 8080).

-record(device_state, {
    id,
    pid,
    last_heartbeat,
    status,  % online | offline | crashed
    offline_time,
    crash_count = 0
}).

-record(state, {
    devices = #{},
    tcp_socket,
    udp_socket,
    http_pid
}).

%% ===================================================================
%% API Functions
%% ===================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

stop() ->
    gen_server:call(?MODULE, stop).

get_device_status() ->
    gen_server:call(?MODULE, get_device_status).

get_device_info(DeviceId) ->
    gen_server:call(?MODULE, {get_device_info, DeviceId}).

%% ===================================================================
%% gen_server callbacks
%% ===================================================================

init([]) ->
    process_flag(trap_exit, true),
    
    % 启动TCP服务器
    {ok, TcpSocket} = gen_tcp:listen(?TCP_PORT, [binary, {packet, 0}, {active, true}, {reuseaddr, true}]),
    spawn_link(?MODULE, heartbeat_server, [tcp, TcpSocket]),
    
    % 启动UDP服务器
    {ok, UdpSocket} = gen_udp:open(?UDP_PORT, [binary, {active, true}]),
    spawn_link(?MODULE, heartbeat_server, [udp, UdpSocket]),
    
    % 启动HTTP服务器
    HttpPid = spawn_link(?MODULE, http_server, [?HTTP_PORT]),
    
    % 启动设备进程
    Devices = start_devices(?DEVICE_COUNT),
    
    % 启动状态检查定时器
    timer:send_interval(1000, check_device_status),
    
    io:format("广告播放设备管理系统已启动~n"),
    io:format("- TCP心跳端口: ~p~n", [?TCP_PORT]),
    io:format("- UDP心跳端口: ~p~n", [?UDP_PORT]),
    io:format("- HTTP查询端口: ~p~n", [?HTTP_PORT]),
    io:format("- 设备数量: ~p~n", [?DEVICE_COUNT]),
    
    {ok, #state{
        devices = Devices,
        tcp_socket = TcpSocket,
        udp_socket = UdpSocket,
        http_pid = HttpPid
    }}.

handle_call(get_device_status, _From, State) ->
    DeviceList = maps:fold(fun(Id, Device, Acc) ->
        [{Id, Device#device_state.status, Device#device_state.last_heartbeat, 
          Device#device_state.offline_time, Device#device_state.crash_count} | Acc]
    end, [], State#state.devices),
    {reply, DeviceList, State};

handle_call({get_device_info, DeviceId}, _From, State) ->
    case maps:get(DeviceId, State#state.devices, undefined) of
        undefined ->
            {reply, {error, device_not_found}, State};
        Device ->
            {reply, {ok, Device}, State}
    end;

handle_call(stop, _From, State) ->
    {stop, normal, ok, State};

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast({heartbeat, DeviceId, Protocol}, State) ->
    Now = erlang:system_time(second),
    Devices = case maps:get(DeviceId, State#state.devices, undefined) of
        undefined ->
            State#state.devices;
        Device ->
            UpdatedDevice = Device#device_state{
                last_heartbeat = Now,
                status = online,
                offline_time = undefined
            },
            maps:put(DeviceId, UpdatedDevice, State#state.devices)
    end,
    io:format("设备 ~p 通过 ~p 发送心跳~n", [DeviceId, Protocol]),
    {noreply, State#state{devices = Devices}};

handle_cast({device_crashed, DeviceId}, State) ->
    Now = erlang:system_time(second),
    Devices = case maps:get(DeviceId, State#state.devices, undefined) of
        undefined ->
            State#state.devices;
        Device ->
            UpdatedDevice = Device#device_state{
                status = crashed,
                offline_time = Now,
                crash_count = Device#device_state.crash_count + 1
            },
            maps:put(DeviceId, UpdatedDevice, State#state.devices)
    end,
    io:format("设备 ~p 已崩溃 (第~p次)~n", [DeviceId, 
        (maps:get(DeviceId, Devices))#device_state.crash_count]),
    
    % 5秒后重启设备
    timer:apply_after(5000, fun() -> restart_device(DeviceId) end),
    {noreply, State#state{devices = Devices}};

handle_cast({device_restarted, DeviceId, Device}, State) ->
    Devices = maps:put(DeviceId, Device, State#state.devices),
    {noreply, State#state{devices = Devices}};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(check_device_status, State) ->
    Now = erlang:system_time(second),
    Devices = maps:map(fun(_Id, Device) ->
        case Device#device_state.status of
            online ->
                % 检查是否超过心跳超时
                if Now - Device#device_state.last_heartbeat > 10 ->
                    Device#device_state{
                        status = offline,
                        offline_time = Now
                    };
                true ->
                    Device
                end;
            _ ->
                Device
        end
    end, State#state.devices),
    {noreply, State#state{devices = Devices}};

handle_info({tcp, _Socket, Data}, State) ->
    handle_heartbeat_data(Data, tcp),
    {noreply, State};

handle_info({udp, _Socket, _IP, _Port, Data}, State) ->
    handle_heartbeat_data(Data, udp),
    {noreply, State};

handle_info({'EXIT', Pid, Reason}, State) ->
    io:format("进程 ~p 退出，原因: ~p~n", [Pid, Reason]),
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    gen_tcp:close(State#state.tcp_socket),
    gen_udp:close(State#state.udp_socket),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ===================================================================
%% Internal functions
%% ===================================================================

start_devices(Count) ->
    lists:foldl(fun(Id, Acc) ->
        % Command = io_lib:format("erl -noshell -s ~s device_process ~p -s init stop", [?MODULE, Id]),
        Command = io_lib:format("erl -s ~s device_process ~p -s init stop", [?MODULE, Id]),
        Port = open_port({spawn, Command}, [{packet, 2}, binary, exit_status]),
        Now = erlang:system_time(second),
        Device = #device_state{
            id = Id,
            pid = Port,
            last_heartbeat = Now,
            status = online,
            offline_time = undefined
        },
        maps:put(Id, Device, Acc)
    end, #{}, lists:seq(1, Count)).

device_process(DeviceId) ->
    if is_list(DeviceId) ->
        io:format("设备ID应为整数，接收到列表: ~p~n", [DeviceId]);
    is_atom(DeviceId) ->
        io:format("设备ID应为整数，接收到原子: ~p~n", [DeviceId]);
    is_integer(DeviceId) ->
        io:format("设备ID为整数: ~p~n", [DeviceId]);
    true ->
        io:format("设备ID类型未知: ~p~n", [DeviceId])
    end,
    % 随机选择心跳协议
    Protocol = case rand:uniform(2) of
        1 -> tcp;
        2 -> udp
    end,
    
    % 发送心跳
    send_heartbeat(DeviceId, Protocol),
    
    % 检查是否崩溃
    case rand:uniform() < ?CRASH_PROBABILITY of
        true ->
            gen_server:cast(?MODULE, {device_crashed, DeviceId}),
            exit(crashed);
        false ->
            timer:sleep(?HEARTBEAT_INTERVAL + rand:uniform(2000) - 1000), % 添加随机延迟
            device_process(DeviceId)
    end.

send_heartbeat(DeviceId, tcp) ->
    case gen_tcp:connect("localhost", ?TCP_PORT, [binary, {packet, 0}]) of
        {ok, Socket} ->
            Data = iolist_to_binary(io_lib:format("HEARTBEAT:~s", [atom_to_list(X) || X <- DeviceId])),
            io:format("发送心跳数据: ~p~n", [Data]), % 添加调试日志
            gen_tcp:send(Socket, Data),
            gen_tcp:close(Socket);
        {error, _} ->
            ok
    end;

send_heartbeat(DeviceId, udp) ->
    case gen_udp:open(0) of
        {ok, Socket} ->
            Data = iolist_to_binary(io_lib:format("HEARTBEAT:~s", [atom_to_list(X) || X <- DeviceId])),
            io:format("发送心跳数据: ~p~n", [Data]), % 添加调试日志
            gen_udp:send(Socket, "localhost", ?UDP_PORT, Data),
            gen_udp:close(Socket);
        {error, _} ->
            ok
    end.

handle_heartbeat_data(Data, Protocol) ->
    case binary:split(Data, <<":">>) of
        [<<"HEARTBEAT">>, DeviceIdBin] ->
            try
                DeviceId = binary_to_integer(DeviceIdBin),
                gen_server:cast(?MODULE, {heartbeat, DeviceId, Protocol})
            catch
                _:_ ->
                    io:format("无效的心跳数据: ~p~n", [Data])
            end;
        _ ->
            io:format("未知的数据格式: ~p~n", [Data])
    end.

heartbeat_server(tcp, Sock) ->
    tcp_accept_loop(Sock);

heartbeat_server(udp, Sock) ->
    udp_receive_loop(Sock).

tcp_accept_loop(ListenSocket) ->
    case gen_tcp:accept(ListenSocket) of
        {ok, Socket} ->
            spawn(fun() -> tcp_handle_client(Socket) end),
            tcp_accept_loop(ListenSocket);
        {error, Reason} ->
            io:format("TCP接受连接失败: ~p~n", [Reason])
    end.

tcp_handle_client(Socket) ->
    receive
        {tcp, Socket, Data} ->
            handle_heartbeat_data(Data, tcp),
            tcp_handle_client(Socket);
        {tcp_closed, Socket} ->
            ok;
        {tcp_error, Socket, Reason} ->
            io:format("TCP客户端错误: ~p~n", [Reason])
    after 10000 ->
        gen_tcp:close(Socket)
    end.

udp_receive_loop(Socket) ->
    receive
        {udp, Socket, _IP, _Port, Data} ->
            handle_heartbeat_data(Data, udp),
            udp_receive_loop(Socket)
    end.

restart_device(DeviceId) ->
    io:format("重启设备 ~p~n", [DeviceId]),
    Pid = spawn_link(?MODULE, device_process, [DeviceId]),
    Now = erlang:system_time(second),
    Device = #device_state{
        id = DeviceId,
        pid = Pid,
        last_heartbeat = Now,
        status = online,
        offline_time = undefined
    },
    gen_server:cast(?MODULE, {device_restarted, DeviceId, Device}).

%% ===================================================================
%% HTTP Server
%% ===================================================================

http_server(Port) ->
    case gen_tcp:listen(Port, [binary, {packet, http}, {active, false}, {reuseaddr, true}]) of
        {ok, ListenSocket} ->
            io:format("HTTP服务器启动在端口 ~p~n", [Port]),
            http_accept_loop(ListenSocket);
        {error, Reason} ->
            io:format("HTTP服务器启动失败: ~p~n", [Reason])
    end.

http_accept_loop(ListenSocket) ->
    case gen_tcp:accept(ListenSocket) of
        {ok, Socket} ->
            spawn(fun() -> http_handle_request(Socket) end),
            http_accept_loop(ListenSocket);
        {error, Reason} ->
            io:format("HTTP接受连接失败: ~p~n", [Reason])
    end.

http_handle_request(Socket) ->
    case gen_tcp:recv(Socket, 0) of
        {ok, {http_request, 'GET', {abs_path, Path}, _Version}} ->
            % 接收HTTP头部
            recv_headers(Socket),
            
            % 处理路径
            Response = case Path of
                "/status" ->
                    handle_status_request();
                "/devices" ->
                    handle_devices_request();
                _ ->
                    handle_404()
            end,
            
            gen_tcp:send(Socket, Response),
            gen_tcp:close(Socket);
        {error, Reason} ->
            io:format("HTTP请求接收失败: ~p~n", [Reason])
    end.

recv_headers(Socket) ->
    case gen_tcp:recv(Socket, 0) of
        {ok, {http_header, _, _, _, _}} ->
            recv_headers(Socket);
        {ok, http_eoh} ->
            ok;
        {error, _} ->
            ok
    end.

handle_status_request() ->
    DeviceList = get_device_status(),
    
    OnlineDevices = [{Id, Status, LastHB, OfflineTime, CrashCount} || {Id, Status, LastHB, OfflineTime, CrashCount} <- DeviceList, Status =:= online],
    OfflineDevices = [{Id, Status, LastHB, OfflineTime, CrashCount} || {Id, Status, LastHB, OfflineTime, CrashCount} <- DeviceList, Status =/= online],
    
    Now = erlang:system_time(second),
    
    JsonData = lists:flatten(io_lib:format(
        "{\"total_devices\": ~p, \"online_devices\": ~p, \"offline_devices\": ~p, \"online_list\": [~s], \"offline_list\": [~s]}",
        [
            length(DeviceList),
            length(OnlineDevices),
            length(OfflineDevices),
            string:join([integer_to_list(Id) || {Id, online, _LastHB, _OfflineTime, _CrashCount} <- DeviceList], ","),
            string:join([
                lists:flatten(io_lib:format("{\"id\": ~p, \"status\": \"~p\", \"offline_time\": ~p, \"crash_count\": ~p}",
                    [Id, Status, 
                     case OfflineTime of 
                         undefined -> 0; 
                         _ -> Now - OfflineTime 
                     end, 
                     CrashCount]))
                || {Id, Status, _LastHB, OfflineTime, CrashCount} <- DeviceList, Status =/= online
            ], ",")
        ])),
    io:format("JsonData ~p ~n", [JsonData]),
    
    http_response(200, "application/json", JsonData).

handle_devices_request() ->
    DeviceList = get_device_status(),
    
    Html = [unicode:characters_to_binary("<html><head><title>设备状态</title>"),
            "<meta charset='utf-8'>",
            "<style>table{border-collapse:collapse;width:100%;}th,td{border:1px solid #ddd;padding:8px;text-align:left;}th{background-color:#f2f2f2;}</style>",
            "</head><body>",
            unicode:characters_to_binary("<h1>广告播放设备状态</h1>"),
            "<table>",
            unicode:characters_to_binary("<tr><th>设备ID</th><th>状态</th><th>最后心跳</th><th>离线时间(秒)</th><th>崩溃次数</th></tr>"),
            [format_device_row(D) || D <- DeviceList],
            "</table>",
            "</body></html>"],
    io:format("Html ~p ~n", [Html]),
    io:format("你好 ~n"),
    io:format("format_device_row() ~p ~n", [lists:flatten([format_device_row(D) || D <- DeviceList])]),
    
    http_response(200, "text/html; charset=utf-8", Html).

format_device_row({Id, Status, LastHeartbeat, OfflineTime, CrashCount}) ->
    Now = erlang:system_time(second),
    OfflineSeconds = case OfflineTime of
        undefined -> 0;
        _ -> Now - OfflineTime
    end,
    StatusColor = case Status of
        online -> "green";
        offline -> "orange";
        crashed -> "red"
    end,
    io_lib:format("<tr><td>~p</td><td style='color:~s'>~p</td><td>~p</td><td>~p</td><td>~p</td></tr>",
        [Id, StatusColor, Status, LastHeartbeat, OfflineSeconds, CrashCount]).

handle_404() ->
    http_response(404, "text/html", "<html><body><h1>404 Not Found</h1></body></html>").

http_response(Code, ContentType, Body) ->
    BodyBin = iolist_to_binary(Body),
    io_lib:format("HTTP/1.1 ~p OK\r\nContent-Type: ~s\r\nContent-Length: ~p\r\nConnection: close\r\n\r\n~s",
        [Code, ContentType, byte_size(BodyBin), BodyBin]).
% http_response(Code, ContentType, Body) ->
%     % io_lib:format("HTTP/1.1 ~p OK\r\nContent-Type: ~s\r\nContent-Length: ~p\r\n\r\n~s",
%     %     [Code, ContentType, iolist_size(Body), Body]).
%     % Header = io_lib:format(
%     %     "HTTP/1.1 ~p OK\r\nContent-Type: ~s\r\nContent-Length: ~p\r\n\r\n",
%     %     [Code, ContentType, iolist_size(Body)]
%     % ),
%     % iolist_to_binary([Header, Body]).
%     % 将 Body (iolist) 转换为二进制
%     BodyBinary = iolist_to_binary(Body),
%     % 计算二进制的大小
%     ContentLength = byte_size(BodyBinary),
%     % 构造响应，使用转换后的二进制作为响应体
%     Response = io_lib:format("HTTP/1.1 ~p OK\r\nContent-Type: ~s\r\nContent-Length: ~p\r\n\r\n~s",
%                              [Code, ContentType, ContentLength, BodyBinary]),
%     % io_lib:format 返回的也是 iolist，如果需要返回二进制，可以再转换一次
%     % 但通常 gen_tcp:send 可以直接发送 iolist
%     Response. % 或者 iolist_to_binary(Response) 如果 socket 需要二进制

%% ===================================================================
%% 使用示例
%% ===================================================================

%% 启动系统:
%% 1. 编译: c(ad_device_system).
%% 2. 启动: ad_device_system:start_link().
%% 3. 查看状态: ad_device_system:get_device_status().
%% 4. HTTP接口:
%%    - http://localhost:8080/status (JSON格式状态)
%%    - http://localhost:8080/devices (HTML格式设备列表)
%% 5. 停止: ad_device_system:stop().