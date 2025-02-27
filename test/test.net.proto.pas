/// regression tests for Several Network Protocols
// - this unit is a part of the Open Source Synopse mORMot framework 2,
// licensed under a MPL/GPL/LGPL three license - see LICENSE.md
unit test.net.proto;

interface

{$I ..\src\mormot.defines.inc}

uses
  sysutils,
  mormot.core.base,
  mormot.core.os,
  mormot.core.text,
  mormot.core.buffers,
  mormot.core.unicode,
  mormot.core.datetime,
  mormot.core.rtti,
  mormot.core.data,
  mormot.core.variants,
  mormot.core.json,
  mormot.core.log,
  mormot.core.test,
  mormot.core.perf,
  mormot.core.threads,
  mormot.crypt.core,
  mormot.crypt.secure,
  mormot.net.sock,
  mormot.net.http,
  mormot.net.server,
  mormot.net.async,
  mormot.net.ldap,
  mormot.net.dns,
  mormot.net.rtsphttp,
  mormot.net.tunnel;

type
  /// this test case will validate several low-level protocols
  TNetworkProtocols = class(TSynTestCase)
  protected
    // for _TUriTree
    one, two: RawUtf8;
    three: boolean;
    request: integer;
    four: Int64;
    // for _TTunnelLocal
    session: Int64;
    appsec: RawUtf8;
    options: TTunnelOptions;
    tunnelexecutedone: boolean;
    tunnelexecuteremote, tunnelexecutelocal: TNetPort;
    procedure TunnelExecute(Sender: TObject);
    procedure TunnelExecuted(Sender: TObject);
    procedure TunnelTest(const clientcert, servercert: ICryptCert);
    // several methods used by _TUriTree
    function DoRequest_(Ctxt: THttpServerRequestAbstract): cardinal;
    function DoRequest0(Ctxt: THttpServerRequestAbstract): cardinal;
    function DoRequest1(Ctxt: THttpServerRequestAbstract): cardinal;
    function DoRequest2(Ctxt: THttpServerRequestAbstract): cardinal;
    function DoRequest3(Ctxt: THttpServerRequestAbstract): cardinal;
    function DoRequest4(Ctxt: THttpServerRequestAbstract): cardinal;
    // this is the main method called by RtspOverHttp[BufferedWrite]
    procedure DoRtspOverHttp(options: TAsyncConnectionsOptions);
  published
    /// validate TUriTree high-level structure
    procedure _TUriTree;
    /// validate DNS and LDAP clients (and NTP/SNTP)
    procedure DNSAndLDAP;
    /// RTSP over HTTP, as implemented in SynProtoRTSPHTTP unit
    procedure RTSPOverHTTP;
    /// RTSP over HTTP, with always temporary buffering
    procedure RTSPOverHTTPBufferedWrite;
    /// validate mormot.net.tunnel
    procedure _TTunnelLocal;
    /// validate IP processing functions
    procedure IPAddresses;
    /// validate THttpPeerCache process
    procedure _THttpPeerCache;
  end;


implementation

procedure RtspRegressionTests(proxy: TRtspOverHttpServer; test: TSynTestCase;
  clientcount, steps: integer);
type
  TReq = record
    get: THttpSocket;
    post: TCrtSocket;
    stream: TCrtSocket;
    session: RawUtf8;
  end;
var
  streamer: TCrtSocket;
  req: array of TReq;

  procedure Shutdown;
  var
    r, rmax: PtrInt;
    log: ISynLog;
    timer, one: TPrecisionTimer;
  begin
    log := proxy.Log.Enter(proxy, 'Shutdown');
    // first half deletes POST first, second half deletes GET first
    timer.Start;
    rmax := clientcount - 1;
    for r := 0 to rmax shr 1 do
      req[r].post.Free;
    if log <> nil then
      log.Log(sllCustom1, 'RegressionTests SHUTDOWN 1 %', [timer.Stop], proxy);
    timer.Start;
    req[0].stream.Free; // validates remove POST when RTSP already down
    if log <> nil then
      log.Log(sllCustom1, 'RegressionTests SHUTDOWN 2 %', [timer.Stop], proxy);
    timer.Start;
    for r := (rmax shr 1) + 1 to rmax do
      req[r].get.Free;
    if log <> nil then
      log.Log(sllCustom1, 'RegressionTests SHUTDOWN 3 %', [timer.Stop], proxy);
    timer.Start;
    for r := 0 to rmax shr 1 do
      req[r].get.Free;
    if log <> nil then
      log.Log(sllCustom1, 'RegressionTests SHUTDOWN 4 %', [timer.Stop], proxy);
    timer.Start;
    for r := (rmax shr 1) + 1 to rmax do
      req[r].post.Free;
    if log <> nil then
      log.Log(sllCustom1, 'RegressionTests SHUTDOWN 5 %', [timer.Stop], proxy);
    timer.Start;
    sleep(10);
    //proxy.Shutdown; // don't make any difference
    if log <> nil then
      log.Log(sllCustom1, 'RegressionTests SHUTDOWN 6 %', [timer.Stop], proxy);
    for r := 1 to rmax do
    begin
      one.Start;
      //req[r].stream.OnLog := TSynLog.DoLog;
      req[r].stream.Free;
      if log <> nil then
        log.Log(sllCustom1, 'RegressionTests SHUTDOWN 6-% %', [r, one.Stop], proxy);
    end;
    if log <> nil then
      log.Log(sllCustom1, 'RegressionTests % SHUTDOWN 7 %', [timer.Stop], proxy);
    timer.Start;
    streamer.Free;
    if log <> nil then
      log.Log(sllCustom1, 'RegressionTests ENDED %', [timer.Stop], proxy);
  end;

var
  rmax, r, i: PtrInt;
  text: RawUtf8;
  log: ISynLog;
begin
  // here we follow the steps and content stated by https://goo.gl/CX6VA3
  log := proxy.Log.Enter(proxy, 'Tests');
  if (proxy = nil) or
     (proxy.RtspServer <> '127.0.0.1') then
    test.Check(false, 'expect a running proxy on 127.0.0.1')
  else
  try
    rmax := clientcount - 1;
    streamer := TCrtSocket.Bind(proxy.RtspPort);
    try
      if log <> nil then
        log.Log(sllCustom1, 'RegressionTests % GET', [clientcount], proxy);
      SetLength(req, clientcount);
      for r := 0 to rmax do
        with req[r] do
        begin
          session := TSynTestCase.RandomIdentifier(20 + r and 15);
          get := THttpSocket.Open('localhost', proxy.Server.Port, nlTcp, 1000);
          get.SndLow('GET /sw.mov HTTP/1.0'#13#10 +
                     'User-Agent: QTS (qtver=4.1;cpu=PPC;os=Mac 8.6)'#13#10 +
                     'x-sessioncookie: ' + session + #13#10 +
                     'Accept: ' + RTSP_MIME + #13#10 +
                     'Pragma: no-cache'#13#10 +
                     'Cache-Control: no-cache'#13#10#13#10);
          get.SockRecvLn(text);
          test.Check(text = 'HTTP/1.0 200 OK');
          get.GetHeader(false);
          test.Check(hfConnectionClose in get.Http.HeaderFlags);
          test.Check(get.SockConnected);
          test.Check(get.Http.ContentType = RTSP_MIME);
        end;
      if log <> nil then
        log.Log(sllCustom1, 'RegressionTests % POST', [clientcount], proxy);
      for r := 0 to rmax do
        with req[r] do
        begin
          post := TCrtSocket.Open('localhost', proxy.Server.Port);
          post.SndLow('POST /sw.mov HTTP/1.0'#13#10 +
            'User-Agent: QTS (qtver=4.1;cpu=PPC;os=Mac 8.6)'#13#10 +
            'x-sessioncookie: ' + session + #13#10 +
            'Content-Type: ' + RTSP_MIME + #13#10 +
            'Pragma: no-cache'#13#10 +
            'Cache-Control: no-cache'#13#10 +
            'Content-Length: 32767'#13#10 +
            'Expires: Sun, 9 Jan 1972 00:00:00 GMT'#13#10#13#10);
          stream := streamer.AcceptIncoming(nil, {async=}false);
          if stream = nil then
          begin
            test.Check(false);
            exit;
          end;
          stream.Sock.SetLinger(0); // otherwise shutdown takes 40ms with epoll
          test.Check(get.SockConnected);
          test.Check(post.SockConnected);
        end;
      for i := 0 to steps do
      begin
        if log <> nil then
          log.Log(sllCustom1, 'RegressionTests % RUN #%', [clientcount, i], proxy);
        // send a RTSP command once in a while to the POST request
        if i and 7 = 0 then
        begin
          for r := 0 to rmax do
            req[r].post.SndLow(
              'REVTQ1JJQkUgcnRzcDovL3R1Y2tydS5hcHBsZS5jb20vc3cubW92IFJUU1AvMS4w'#13#10 +
              'DQpDU2VxOiAxDQpBY2NlcHQ6IGFwcGxpY2F0aW9uL3NkcA0KQmFuZHdpZHRoOiAx'#13#10 +
              'NTAwMDAwDQpBY2NlcHQtTGFuZ3VhZ2U6IGVuLVVTDQpVc2VyLUFnZW50OiBRVFMg'#13#10 +
              'KHF0dmVyPTQuMTtjcHU9UFBDO29zPU1hYyA4LjYpDQoNCg=='); 
          for r := 0 to rmax do
            test.check(req[r].stream.SockReceiveString =
              'DESCRIBE rtsp://tuckru.apple.com/sw.mov RTSP/1.0'#13#10 +
              'CSeq: 1'#13#10 +
              'Accept: application/sdp'#13#10 +
              'Bandwidth: 1500000'#13#10 +
              'Accept-Language: en-US'#13#10 +
              'User-Agent: QTS (qtver=4.1;cpu=PPC;os=Mac 8.6)'#13#10#13#10);
        end;
        // stream output should be redirected to the GET request
        for r := 0 to rmax do
          req[r].stream.SndLow(req[r].session); // session text as video stream
        if log <> nil then
          log.Log(sllCustom1, 'RegressionTests % RUN #% SndLow',
            [clientcount, i], proxy);
        for r := 0 to rmax do
          with req[r] do
          begin
            text := get.SockReceiveString;
            //if log <> nil then
            //  log.Log(sllCustom1, 'RegressionTests % #%/% received %',
            //    [clientcount, r, rmax, text], proxy);
            test.check(text = session);
          end;
      end;
      if log <> nil then
        log.Log(sllCustom1, 'RegressionTests % SHUTDOWN', [clientcount], proxy);
    finally
      Shutdown;
    end;
  except
    on E: Exception do
      test.Check(false, E.ClassName);
  end;
end;

procedure TNetworkProtocols.DoRtspOverHttp(options: TAsyncConnectionsOptions);
var
  N: integer;
  proxy: TRtspOverHttpServer;
begin
  {$ifdef OSDARWIN}
  N := 10;
  {$else}
  N := 100;
  {$endif OSDARWIN}
  proxy := TRtspOverHttpServer.Create(
    '127.0.0.1', '3999', '3998', TSynLog, nil, nil, options, {threads=}1);
    // threads=1 is the safest & fastest - but you may set 16 for testing
  try
    proxy.WaitStarted(10);
    RtspRegressionTests(proxy, self, N, 10);
  finally
    proxy.Free;
  end;
end;

const
  //ASYNC_OPTION = ASYNC_OPTION_DEBUG;
  ASYNC_OPTION = ASYNC_OPTION_VERBOSE;

procedure TNetworkProtocols.RTSPOverHTTP;
begin
  DoRtspOverHttp(ASYNC_OPTION);
end;

procedure TNetworkProtocols.RTSPOverHTTPBufferedWrite;
begin
  DoRtspOverHttp(ASYNC_OPTION + [acoWritePollOnly]);
end;

function TNetworkProtocols.DoRequest_(Ctxt: THttpServerRequestAbstract): cardinal;
begin
  one := Ctxt['one'];
  Ctxt.RouteUtf8('two', two);
  three := Ctxt.RouteEquals('three', '3');
  if not Ctxt.RouteInt64('four', four) then
    four := -1;
  result := HTTP_SUCCESS;
end;

function TNetworkProtocols.DoRequest0(Ctxt: THttpServerRequestAbstract): cardinal;
begin
  result := DoRequest_(Ctxt);
  request := 0;
end;

function TNetworkProtocols.DoRequest1(Ctxt: THttpServerRequestAbstract): cardinal;
begin
  result := DoRequest_(Ctxt);
  request := 1;
end;

function TNetworkProtocols.DoRequest2(Ctxt: THttpServerRequestAbstract): cardinal;
begin
  result := DoRequest_(Ctxt);
  request := 2;
end;

function TNetworkProtocols.DoRequest3(Ctxt: THttpServerRequestAbstract): cardinal;
begin
  result := DoRequest_(Ctxt);
  request := 3;
end;

function TNetworkProtocols.DoRequest4(Ctxt: THttpServerRequestAbstract): cardinal;
begin
  result := DoRequest_(Ctxt);
  request := 4;
end;

const
  NODES: array[0..10] of RawUtf8 = (
    'water', 'slow', 'slower', 'waste', 'watch', 'water',
    'toaster', 'team', 'tester', 't', 'toast');

procedure TNetworkProtocols._TUriTree;
var
  tree: TUriTree;
  router: TUriRouter;
  ctxt: THttpServerRequestAbstract;
  i: PtrInt;
  n: TRadixTreeNode;
  timer: TPrecisionTimer;
  rnd: array[0..999] of RawUtf8;

  procedure Call(const uri, exp1, exp2: RawUtf8; exp3: boolean = false;
    exp4: Int64 = -1; expstatus: integer = HTTP_SUCCESS;
    const met: RawUtf8 = 'GET');
  begin
    request := -1;
    one := '';
    two := '';
    three := false;
    four := -1;
    ctxt.Method := met;
    ctxt.Url := uri;
    CheckEqual(router.Process(ctxt), expstatus);
    CheckEqual(one, exp1);
    CheckEqual(two, exp2);
    Check(three = exp3);
    CheckEqual(four, exp4);
  end;

  procedure Compute(const uri, expected: RawUtf8; const met: RawUtf8 = 'POST';
    expstatus: integer = 0);
  begin
    ctxt.Method := met;
    ctxt.Url := uri;
    CheckEqual(router.Process(ctxt), expstatus);
    if expected <> '' then
      CheckEqual(ctxt.Url, expected);
  end;

begin
  tree := TUriTree.Create(TUriTreeNode);
  try
    tree.insert('romane');
    tree.insert('romanus');
    tree.insert('romulus');
    tree.insert('rubens');
    tree.insert('ruber');
    tree.insert('rubicon');
    tree.insert('rubicundus');
    CheckHash(tree.ToText, $0946B9A0);
    CheckEqual(tree.Root.Lookup('rubens', nil).FullText, 'rubens');
    Check(tree.Root.Lookup('Rubens', nil) = nil);
  finally
    tree.Free;
  end;
  tree := TUriTree.Create(TUriTreeNode, [rtoCaseInsensitiveUri]);
  try
    tree.insert('romanus');
    tree.insert('romane');
    tree.insert('rubicundus');
    tree.insert('rubicon');
    tree.insert('ruber');
    tree.insert('romulus');
    tree.insert('rubens');
    CheckHash(tree.ToText, $305E57F1);
    CheckEqual(tree.Root.Lookup('rubens', nil).FullText, 'rubens');
    CheckEqual(tree.Root.Lookup('Rubens', nil).FullText, 'rubens');
  finally
    tree.Free;
  end;
  tree := TUriTree.Create(TUriTreeNode);
  try
    tree.insert('/plaintext');
    tree.insert('/');
    tree.insert('/plain');
    //writeln(tree.ToText);
    CheckHash(tree.ToText, $B3522B86);
  finally
    tree.Free;
  end;
  tree := TUriTree.Create(TUriTreeNode);
  try
    for i := 0 to high(NODES) do
      CheckEqual(tree.Insert(NODES[i]).FullText, NODES[i]);
    //writeln(tree.ToText);
    CheckHash(tree.ToText, $CC40347C);
    for i := 0 to high(NODES) do
    begin
      n := tree.Find(NODES[i]);
      CheckUtf8(n <> nil, NODES[i]);
      CheckEqual(n.FullText, NODES[i]);
    end;
    for i := 0 to high(NODES) do
      CheckEqual(tree.Insert(NODES[i]).FullText, NODES[i]);
    tree.AfterInsert; // sort by depth
    //writeln(tree.ToText);
    CheckHash(tree.ToText, $200CAEEB);
    for i := 0 to high(NODES) do
      CheckEqual(tree.Find(NODES[i]).FullText, NODES[i]);
  finally
    tree.Free;
  end;
  tree := TUriTree.Create(TUriTreeNode);
  try
    for i := 0 to high(rnd) do
      rnd[i] := RandomIdentifier(Random32(24) * 2 + 1);
    for i := 0 to high(rnd) do
      CheckEqual(tree.Insert(rnd[i]).FullText, rnd[i]);
    timer.Start;
    for i := 0 to high(rnd) do
      CheckEqual(tree.Find(rnd[i]).FullText, rnd[i]);
    NotifyTestSpeed('big tree lookups', length(rnd), 0, @timer);
  finally
    tree.Free;
  end;
  ctxt := THttpServerRequestAbstract.Create;
  router := TUriRouter.Create(TUriTreeNode);
  try
    Call('/plaintext', '', '', false, -1, 0);
    Call('/', '', '', false, -1, 0);
    router.Get('/plaintext', DoRequest_);
    router.Get('/plaintext', DoRequest_);
    CheckEqual(request, -1);
    Call('/plaintext', '', '');
    Call('/', '', '', false, -1, 0);
    //writeln(router.Tree[urmGet].ToText);
    router.Get('/', DoRequest0);
    Call('/plaintext', '', '');
    CheckEqual(request, -1);
    Call('/', '', '', false);
    CheckEqual(request, 0);
    router.Get('/do/<one>/pic/<two>', DoRequest0);
    router.Get('/do/<one>', DoRequest1);
    router.Get('/do/<one>/pic', DoRequest2);
    router.Get('/do/<one>/pic/<two>/', DoRequest3);
    router.Get('/da/<one>/<two>/<three>/<four>/', DoRequest4);
    //writeln(router.Tree[urmGet].ToText);
    Call('/do/a', 'a', '');
    CheckEqual(request, 1);
    Call('/do/123', '123', '');
    CheckEqual(request, 1);
    Call('/do/toto/pic', 'toto', '');
    CheckEqual(request, 2);
    Call('/do/toto/pic/titi/', 'toto', 'titi');
    CheckEqual(request, 3);
    Call('/do/toto/pic/titi', 'toto', 'titi');
    CheckEqual(request, 0);
    Call('/do/toto/pic/titi/', 'toto', 'titi');
    CheckEqual(request, 3);
    Call('/da/1/2/3/4', '', '', false, -1, 0);
    CheckEqual(request, -1);
    Call('/da/1/2/3/4/', '1', '2', true, 4);
    CheckEqual(request, 4);
    Call('/da/a1/b2/3/47456/', 'a1', 'b2', true, 47456);
    CheckEqual(request, 4);
    Compute('/static', '/static');
    Compute('/static2', '/static2');
    Compute('/', '/');
    router.Post('/static', '/some/static');
    Compute('/static', '/some/static');
    Compute('/static2', '/static2');
    Compute('/', '/');
    router.Post('/static2', '/some2/static');
    router.Post('/', '/index');
    Compute('/static', '/some/static');
    Compute('/static2', '/some2/static');
    Compute('/', '/index');
    Compute('/stat', '/stat');
    router.Post('/user/<id>', '/root/user.new?id=<id>');
    Compute('/user/1234', '/root/user.new?id=1234');
    Compute('/user/1234/', '/user/1234/');
    router.Post('/user/<id>/picture', '/root/user.newpic?id=<id>&pic=');
    router.Post('/user/<id>/picture/<pic>', '/root/user.newpic?pic=<pic>&id=<id>');
    Compute('/user/1234/picture', '/root/user.newpic?id=1234&pic=');
    Compute('/user/1234/picture/5', '/root/user.newpic?pic=5&id=1234');
    Compute('/user/1234/picture/', '/user/1234/picture/');
    Compute('/user/1234', '/root/user.new?id=1234');
    Compute('/user/1234/', '/user/1234/');
    Compute('/static', '/some/static');
    Compute('/static2', '/some2/static');
    Compute('/', '/index');
    Compute('/stat', '/stat');
    timer.Start;
    for i := 1 to 1000 do
      CheckEqual(router.Tree[urmPost].Find('/static').FullText, '/static');
    NotifyTestSpeed('URI lookups', 1000, 0, @timer);
    timer.Start;
    for i := 1 to 1000 do
      Compute('/static', '/some/static');
    NotifyTestSpeed('URI static rewrites', 1000, 0, @timer);
    timer.Start;
    for i := 1 to 1000 do
      Compute('/user/1234', '/root/user.new?id=1234');
    NotifyTestSpeed('URI parametrized rewrites', 1000, 0, @timer);
    timer.Start;
    for i := 1 to 1000 do
      Compute('/plaintext', '', 'GET', 200);
    NotifyTestSpeed('URI static execute', 1000, 0, @timer);
    timer.Start;
    for i := 1 to 1000 do
      Compute('/do/toto/pic', '', 'GET', 200);
    NotifyTestSpeed('URI parametrized execute', 1000, 0, @timer);
    router.Put('/index.php', '404');
    router.Put('/index.php', '404');
    router.Put('/admin.php', '404');
    Compute('/index.php', '/index.php', 'PUT', 404);
    Compute('/admin.php', '/admin.php', 'PUT', 404);
    router.Delete('/*', '/static/*');
    router.Delete('/root1/<path:url>', '/roota/<url>');
    router.Delete('/root2/*', '/rootb/*');
    router.Delete('/root3/<url>', '/rootc/<url>');
    router.Delete('/root4/<int:id>', '/rootd/<id>');
    Compute('/root1/one', '/roota/one', 'DELETE');
    Compute('/root1/one/', '/roota/one/', 'DELETE');
    Compute('/root1/one/two', '/roota/one/two', 'DELETE');
    Compute('/root2/one', '/rootb/one', 'DELETE');
    Compute('/root2/one/', '/rootb/one/', 'DELETE');
    Compute('/root2/one/two', '/rootb/one/two', 'DELETE');
    Compute('/root3/one', '/rootc/one', 'DELETE');
    Compute('/root3/one/', '/static/root3/one/', 'DELETE');
    Compute('/root3/one/two', '/static/root3/one/two', 'DELETE');
    Compute('/root4/one', '/static/root4/one', 'DELETE');
    Compute('/root4/1', '/rootd/1', 'DELETE');
    Compute('/root4/123', '/rootd/123', 'DELETE');
    Compute('/roota/one', '/static/roota/one', 'DELETE');
    Compute('/one', '/static/one', 'DELETE');
    Compute('/one/two', '/static/one/two', 'DELETE');
    //writeln(router.Tree[urmGet].ToText);
    //writeln(router.Tree[urmPost].ToText);
    //writeln(router.Tree[urmPut].ToText);
    //writeln(router.Tree[urmDelete].ToText);
    CheckHash(router.Tree[urmGet].ToText, $18A0BF58);
    CheckHash(router.Tree[urmPost].ToText, $E173FBB0);
    CheckHash(router.Tree[urmPut].ToText, $80F7A0EF);
    CheckHash(router.Tree[urmDelete].ToText, $39501147);
    router.Clear([urmPost]);
    Call('/plaintext', '', '');
    Compute('/static', '/static');
    router.Clear;
    Call('/plaintext', '', '', false, -1, 0);
    Compute('/static', '/static');
  finally
    router.Free;
    ctxt.Free;
  end;
end;

procedure TNetworkProtocols.DNSAndLDAP;
var
  ip, u, v, sid: RawUtf8;
  c: cardinal;
  withntp: boolean;
  guid: TGuid;
  i, j, k: PtrInt;
  dns, clients: TRawUtf8DynArray;
  l: TLdapClientSettings;
  one: TLdapClient;
  utc1, utc2: TDateTime;
  ntp, usr, pwd, main, txt: RawUtf8;
  hasinternet: boolean;
begin
  CheckEqual(1 shl ord(uacPartialSecretsRodc), $04000000, 'uacHigh');
  // validate NTP/SNTP client using NTP_DEFAULT_SERVER = time.google.com
  if not Executable.Command.Get('ntp', ntp) then
    ntp := NTP_DEFAULT_SERVER;
  withntp := not Executable.Command.Option('nontp');
  hasinternet := DnsLookups('yahoo.com') <> nil; // avoid waiting for nothing
  if hasinternet then
  begin
    utc1 := GetSntpTime(ntp);
    //writeln(DateTimeMSToString(utc), ' = ', DateTimeMSToString(NowUtc));
    if utc1 <> 0 then
    begin
      utc2 := NowUtc;
      AddConsole('% : % = %', [ntp, DateTimeMSToString(utc1), DateTimeMSToString(utc2)]);
      // only make a single GetSntpTime call - most servers refuse to scale
      if withntp then
        CheckSame(utc1, utc2, 1, 'NTP system A'); // allow 1 day diff
    end;
  end
  else
    AddConsole('no Internet connection');
  // validate some IP releated process
  Check(not NetIsIP4(nil));
  Check(not NetIsIP4('1'));
  Check(not NetIsIP4('1.2'));
  Check(not NetIsIP4('1.2.3'));
  Check(not NetIsIP4('1.2.3.'));
  Check(not NetIsIP4('1.2.3.4.'));
  Check(not NetIsIP4('1.2.3.4.5'));
  Check(NetIsIP4('1.2.3.4'));
  Check(NetIsIP4('12.3.4.5'));
  Check(NetIsIP4('12.34.5.6'));
  Check(NetIsIP4('12.34.56.7'));
  Check(NetIsIP4('12.34.56.78'));
  Check(NetIsIP4('112.134.156.178'));
  Check(not NetIsIP4('312.34.56.78'));
  Check(not NetIsIP4('12.334.56.78'));
  Check(not NetIsIP4('12.34.256.78'));
  Check(not NetIsIP4('12.34.56.278'));
  c := 0;
  Check(NetIsIP4('1.2.3.4', @c));
  CheckEqual(c, $04030201);
  // validate DNS client with some known values
  CheckEqual(DnsLookup(''), '');
  CheckEqual(DnsLookup('localhost'), '127.0.0.1');
  CheckEqual(DnsLookup('LocalHost'), '127.0.0.1');
  CheckEqual(DnsLookup('::1'), '127.0.0.1');
  CheckEqual(DnsLookup('1.2.3.4'), '1.2.3.4');
  if hasinternet then
  begin
    ip := DnsLookup('synopse.info');
    CheckEqual(ip, '62.210.254.173', 'dns1');
    ip := DnsLookup('blog.synopse.info');
    CheckEqual(ip, '62.210.254.173', 'dns2');
    CheckEqual(DnsReverseLookup(ip), '62-210-254-173.rev.poneytelecom.eu', 'rev');
  end;
  // validate LDAP distinguished name conversion (no client)
  CheckEqual(DNToCN('CN=User1,OU=Users,OU=London,DC=xyz,DC=local'),
    'xyz.local/London/Users/User1');
  CheckEqual(DNToCN(
    'cn=JDoe,ou=Widgets,ou=Manufacturing,dc=USRegion,dc=OrgName,dc=com'),
    'USRegion.OrgName.com/Manufacturing/Widgets/JDoe');
  // validate LDAP escape/unescape
  for c := 0 to 200 do
  begin
    u := RandomIdentifier(c); // alphanums are never escaped
    CheckEqual(LdapEscape(u), u);
    CheckEqual(LdapUnescape(u), u);
    if u <> '' then
      CheckEqual(LdapEscapeName(u), u);
    CheckEqual(LdapEscapeCN(u), u);
    u := RandomAnsi7(c);
    CheckEqual(LdapUnescape(LdapEscape(u)), u);
  end;
  CheckEqual(LdapUnescape('abc\>'), 'abc>');
  CheckEqual(LdapUnescape('abc\>e'), 'abc>e');
  CheckEqual(LdapUnescape('abc\'), 'abc');
  Check(LdapSafe(''));
  Check(LdapSafe('abc'));
  Check(LdapSafe('ab cd'));
  Check(LdapSafe('@abc'));
  Check(not LdapSafe('\abc'));
  Check(not LdapSafe('abc*'));
  Check(not LdapSafe('a(bc'));
  Check(not LdapSafe('abc)'));
  Check(not LdapSafe('*'));
  Check(not LdapSafe('()'));
  // validate LDAP settings
  l := TLdapClientSettings.Create;
  try
    CheckEqual(l.TargetUri, '');
    CheckEqual(l.KerberosDN, '');
    l.TargetHost := 'ad.synopse.info';
    CheckEqual(l.TargetUri, 'ldap://ad.synopse.info');
    l.Tls := true;
    CheckEqual(l.TargetUri, 'ldaps://ad.synopse.info:389');
    l.TargetPort := LDAP_TLS_PORT;
    CheckEqual(l.TargetUri, 'ldaps://ad.synopse.info');
    l.TargetPort := '1234';
    u := l.TargetUri;
    CheckEqual(u, 'ldaps://ad.synopse.info:1234');
    l.TargetUri := 'http://ad.synopse.com';
    CheckEqual(l.TargetUri, '');
    l.TargetUri := 'ldap2://ad.synopse.com';
    CheckEqual(l.TargetUri, '');
    l.TargetUri := 'ldap://ad.synopse.com';
    CheckEqual(l.TargetUri, 'ldap://ad.synopse.com');
    l.TargetUri := 'ad.synopse.info';
    CheckEqual(l.TargetUri, 'ldap://ad.synopse.info');
    CheckEqual(l.KerberosDN, '');
  finally
    l.Free;
  end;
  l := TLdapClientSettings.Create;
  try
    CheckEqual(l.TargetUri, '');
    CheckEqual(l.KerberosDN, '');
    l.TargetHost := 'dc.synopse.com';
    CheckEqual(l.TargetUri, 'ldap://dc.synopse.com');
    CheckEqual(l.KerberosDN, '');
    l.KerberosDN := 'ad.synopse.com';
    v := l.TargetUri;
    CheckEqual(v, 'ldap://dc.synopse.com/ad.synopse.com');
    l.TargetUri := u;
    CheckEqual(l.TargetUri, u);
    CheckEqual(l.TargetUri, 'ldaps://ad.synopse.info:1234');
    CheckEqual(l.KerberosDN, '');
    l.TargetUri := v;
    CheckEqual(l.TargetUri, v);
    CheckEqual(l.KerberosDN, 'ad.synopse.com');
  finally
    l.Free;
  end;
  // optional LDAP client tests
  if Executable.Command.Get(['dns'], dns) then
    for i := 0 to high(dns) do
    begin
      // syntax is -dns server1 [-dns server2]
      clients := DnsLdapServices(dns[i]);
      if clients = nil then
      begin
        CheckUtf8(false, 'no Ldap for --dns %', [dns[i]]);
        continue;
      end;
      main := CldapGetBestLdapController(clients, dns[i], '');
      utc1 := GetSntpTime(dns[i]);
      if utc1 <> 0 then
      begin
        utc2 := NowUtc;
        AddConsole('% : % = %',
          [dns[i], DateTimeMSToString(utc1), DateTimeMSToString(utc2)]);
        if withntp then
          CheckSame(utc1, utc2, 1, 'NTP system B'); // allow 1 day diff
      end;
      for j := 0 to high(clients) do
      begin
        one := TLdapClient.Create;
        try
          one.Settings.TargetUri := clients[j];
          one.Settings.KerberosDN := dns[i];
          try
            if Executable.Command.Get('ldapusr', usr) and
               Executable.Command.Get('ldappwd', pwd) then
            begin
              one.Settings.UserName := usr;
              one.Settings.Password := pwd;
              {$ifdef OSPOSIX}
              // a valid current kinit session seems mandatory on GSSAPI,
              // which makes Kerberos password authentication pointless
              one.Settings.TargetPort := LDAP_TLS_PORT; // TLS needed for safety
              if not one.Bind then
              {$else}
              //  Windows allow a kerberos connection from an unrolled computer
              if not one.BindSaslKerberos then
              {$endif OSPOSIX}
              begin
                CheckUtf8(false, 'ldap:%', [clients[j]]);
                continue;
              end;
            end
            else if not one.BindSaslKerberos then
              continue;
            txt := '';
            if clients[j] = main then
              txt := ' (main)';
            Check(one.NetbiosDN <> '', 'NetbiosDN');
            Check(one.ConfigDN <> '', 'ConfigDN');
            Check(one.Search(one.WellKnownObjects.Users, {typesonly=}false,
                  '(cn=users)', ['*']), 'Search');
            Check(one.SearchResult.Count <> 0, 'SeachResult');
            AddConsole('%% = % search=%', [one.Settings.TargetHost, txt,
              one.NetbiosDN, one.SearchResult.Count]);
            for k := 0 to one.SearchResult.Count - 1 do
              with one.SearchResult.Items[k] do
              begin
                sid := '';
                if CopyObjectSid(sid) then
                  Check(sid <> '');
                FillZero(guid);
                Check(CopyObjectGUID(guid), 'objectGUID');
                Check(not IsNullGuid(guid));
                Check(IdemPropNameU(Attributes.Get('cn'), 'users'), 'cn');
                Check(Attributes.Get('name') <> '', 'name');
                Check(Attributes.Get('distinguishedName') <> '', 'distinguishedName');
              end;
              //writeln(one.SearchResult.Dump);
          except
            on E: Exception do
              Check(false, E.Message);
          end;
        finally
          one.Free;
        end;
      end;
    end;
end;

procedure TNetworkProtocols.TunnelExecute(Sender: TObject);
begin
  // one of the two handshakes should be done in another thread
  tunnelexecutelocal := (Sender as TTunnelLocal).Open(
    session, options, 1000, appsec, cLocalhost, tunnelexecuteremote);
  Check(tunnelexecutelocal <> 0);
  Check(tunnelexecuteremote <> 0);
end;

procedure TNetworkProtocols.TunnelExecuted(Sender: TObject);
begin
  tunnelexecutedone := true;
end;

procedure TNetworkProtocols.TunnelTest(const clientcert, servercert: ICryptCert);
var
  clientinstance, serverinstance: TTunnelLocal;
  clientcb, servercb: ITunnelTransmit;
  clienttunnel, servertunnel: ITunnelLocal;
  i: integer;
  sent, received, sent2, received2: RawByteString;
  clientsock, serversock: TNetSocket;
  local, remote: TNetPort;
begin
  // setup the two instances with the specified options and certificates
  clientinstance := TTunnelLocalClient.Create;
  clientinstance.SignCert := clientcert;
  clientinstance.VerifyCert := servercert;
  clienttunnel := clientinstance;
  clientcb := clientinstance;
  serverinstance := TTunnelLocalServer.Create;
  serverinstance.SignCert := servercert;
  serverinstance.VerifyCert := clientcert;
  servertunnel := serverinstance;
  servercb := serverinstance;
  clienttunnel.SetTransmit(servercb); // set before Open()
  servertunnel.SetTransmit(clientcb);
  // validate handshaking
  session := Random64;
  appsec := RandomAnsi7(10);
  TLoggedWorkThread.Create(
    TSynLog, 'servertunnel', serverinstance, TunnelExecute, TunnelExecuted);
  local := clienttunnel.Open(session, options, 1000, appsec, clocalhost, remote);
  Check(local <> 0);
  Check(remote <> 0);
  SleepHiRes(1000, tunnelexecutedone);
  CheckEqual(local, tunnelexecuteremote);
  CheckEqual(remote, tunnelexecutelocal);
  Check(tunnelexecutedone, 'TunnelExecuted');
  tunnelexecutedone := false; // for the next run
  Check(clienttunnel.LocalPort <> '');
  Check(servertunnel.LocalPort <> '');
  Check(servertunnel.LocalPort <> clienttunnel.LocalPort, 'ports');
  Check(clienttunnel.Encrypted = (toEncrypted * options <> []), 'cEncrypted');
  Check(servertunnel.Encrypted = (toEncrypted * options <> []), 'cEncrypted');
  Check(NewSocket('127.0.0.1', clienttunnel.LocalPort, nlTcp, {bind=}false,
    1000, 1000, 1000, 0, clientsock) = nrOk);
  Check(NewSocket('127.0.0.1', servertunnel.LocalPort, nlTcp, {bind=}false,
    1000, 1000, 1000, 0, serversock) = nrOk);
  try
    // validate raw TCP tunnelling
    CheckEqual(clientinstance.Thread.Received, 0);
    CheckEqual(clientinstance.Thread.Sent, 0);
    CheckEqual(serverinstance.Thread.Received, 0);
    CheckEqual(serverinstance.Thread.Sent, 0);
    for i := 1 to 100 do
    begin
      sent := RandomString(Random32(200) + 1);
      sent2 := RandomString(Random32(200) + 1);
      Check(clientsock.SendAll(pointer(sent), length(sent)) = nrOk);
      Check(serversock.RecvWait(1000, received) = nrOk);
      CheckEqual(sent, received);
      Check(clientsock.SendAll(pointer(sent2), length(sent2)) = nrOk);
      Check(serversock.SendAll(pointer(sent), length(sent)) = nrOk);
      Check(clientsock.RecvWait(1000, received) = nrOk);
      Check(serversock.RecvWait(1000, received2) = nrOk);
      CheckEqual(sent, received);
      CheckEqual(sent2, received2);
      CheckEqual(clientinstance.Thread.Received, serverinstance.Thread.Sent);
      CheckEqual(clientinstance.Thread.Sent, serverinstance.Thread.Received);
      Check(clientinstance.Thread.Received <> 0);
      Check(clientinstance.Thread.Sent <> 0);
      Check(serverinstance.Thread.Received <> 0);
      Check(serverinstance.Thread.Sent <> 0);
    end;
    Check(clientinstance.Thread.Received < clientinstance.Thread.Sent, 'smaller');
    Check(serverinstance.Thread.Received > serverinstance.Thread.Sent, 'bigger');
  finally
    clientsock.ShutdownAndClose(true);
    serversock.ShutdownAndClose(true);
  end;
  servertunnel.SetTransmit(nil); // avoid memory leak due to circular references
end;

procedure TNetworkProtocols._TTunnelLocal;
var
  c, s: ICryptCert;
begin
  c := Cert('syn-es256').Generate([cuDigitalSignature]);
  s := Cert('syn-es256').Generate([cuDigitalSignature]);
  // plain tunnelling
  TunnelTest(nil, nil);
  // symmetric secret encrypted tunnelling
  options := [toEncrypt];
  TunnelTest(nil, nil);
  // ECDHE encrypted tunnelling
  options := [toEcdhe];
  TunnelTest(nil, nil);
  // tunnelling with mutual authentication
  options := [];
  TunnelTest(c, s);
  // symmetric secret encrypted tunnelling with mutual authentication
  options := [toEncrypt];
  TunnelTest(c, s);
  // ECDHE encrypted tunnelling with mutual authentication
  options := [toEcdhe];
  TunnelTest(c, s);
end;

procedure TNetworkProtocols.IPAddresses;
var
  i: PtrInt;
  s: shortstring;
  txt: RawUtf8;
  ip: THash128Rec;
begin
  FillZero(ip.b);
  Check(IsZero(ip.b));
  IP4Short(@ip, s);
  Check(s = '0.0.0.0');
  IP4Text(@ip, txt);
  CheckEqual(txt, '');
  IP6Short(@ip, s);
  Check(s = '::', '::');
  IP6Text(@ip, txt);
  CheckEqual(txt, '');
  ip.b[15] := 1;
  IP6Short(@ip, s);
  Check(s = '::1', '::1');
  IP6Text(@ip, txt);
  CheckEqual(txt, '127.0.0.1', 'IPv6 loopback');
  ip.b[0] := 1;
  IP6Text(@ip, txt);
  CheckEqual(txt, '100::1');
  ip.b[15] := 0;
  IP6Text(@ip, txt);
  CheckEqual(txt, '100::');
  ip.b[6] := $70;
  IP6Text(@ip, txt);
  CheckEqual(txt, '100:0:0:7000::');
  for i := 0 to 7 do
    ip.b[i] := i;
  IP6Text(@ip, txt);
  CheckEqual(txt, '1:203:405:607::');
  for i := 8 to 15 do
    ip.b[i] := i;
  IP6Text(@ip, txt);
  CheckEqual(txt, '1:203:405:607:809:a0b:c0d:e0f');
  for i := 0 to 15 do
    ip.b[i] := i or $70;
  IP6Text(@ip, txt);
  CheckEqual(txt, '7071:7273:7475:7677:7879:7a7b:7c7d:7e7f');
  Check(mormot.core.text.HexToBin('200100B80A0B12F00000000000000001', PByte(@ip), 16));
  IP6Text(@ip, txt);
  CheckEqual(txt, '2001:b8:a0b:12f0::1');
  CheckEqual(IP4Netmask(1), $00000080);
  CheckEqual(IP4Netmask(8), $000000ff);
  CheckEqual(IP4Netmask(24), $00ffffff);
  CheckEqual(IP4Netmask(31), $feffffff);
  CheckEqual(IP4Netmask(32), $ffffffff);
  CheckEqual(IP4Netmask(0),  0, 'invalid prefix=0');
  CheckEqual(IP4Netmask(33), 0, 'invalid prefix=33');
  CheckEqual(IP4Prefix('128.0.0.0'), 1);
  CheckEqual(IP4Prefix('192.0.0.0'), 2);
  CheckEqual(IP4Prefix('254.0.0.0'), 7);
  CheckEqual(IP4Prefix('255.0.0.0'), 8);
  CheckEqual(IP4Prefix('255.128.0.0'), 9);
  CheckEqual(IP4Prefix('255.192.0.0'), 10);
  CheckEqual(IP4Prefix('255.254.0.0'), 15);
  CheckEqual(IP4Prefix('255.255.0.0'), 16);
  CheckEqual(IP4Prefix('255.255.128.0'), 17);
  CheckEqual(IP4Prefix('255.255.192.0'), 18);
  CheckEqual(IP4Prefix('255.255.254.0'), 23);
  CheckEqual(IP4Prefix('255.255.255.0'), 24);
  CheckEqual(IP4Prefix('255.255.255.128'), 25);
  CheckEqual(IP4Prefix('255.255.255.252'), 30);
  CheckEqual(IP4Prefix('255.255.255.254'), 31);
  CheckEqual(IP4Prefix('255.255.255.255'), 32);
  CheckEqual(IP4Prefix(''), 0, 'invalid netmask 1');
  CheckEqual(IP4Prefix('0.0.0.0'), 0, 'invalid netmask 2');
  CheckEqual(IP4Prefix('0.0.0.1'), 0, 'invalid netmask 3');
  CheckEqual(IP4Prefix('255.254.1.0'), 0, 'invalid netmask 4');
  CheckEqual(IP4Prefix('255.255.255.256'), 0, 'invalid netmask 5');
  CheckEqual(IP4Subnet('192.168.1.135', '255.255.255.0'), '192.168.1.0/24');
  Check(IP4Match('192.168.1.1', '192.168.1.0/24'), 'match1');
  Check(IP4Match('192.168.1.135', '192.168.1.0/24'), 'match2');
  Check(IP4Match('192.168.1.250', '192.168.1.0/24'), 'match3');
  Check(not IP4Match('192.168.2.135', '192.168.1.0/24'), 'match4');
  Check(not IP4Match('191.168.1.250', '192.168.1.0/24'), 'match5');
  Check(not IP4Match('192.168.1', '192.168.1.0/24'), 'match6');
  Check(not IP4Match('192.168.1.135', '192.168.1/24'), 'match7');
  Check(not IP4Match('192.168.1.135', '192.168.1.0/65'), 'match8');
  Check(not IP4Match('193.168.1.1', '192.168.1.0/24'), 'match9');
end;

type
  THttpPeerCacheHook = class(THttpPeerCache); // to test protected methods

procedure TNetworkProtocols._THttpPeerCache;
var
  hpc: THttpPeerCacheHook;
  hps: THttpPeerCacheSettings;
  msg, msg2: THttpPeerCacheMessage;
  i, n, alter: integer;
  tmp: RawByteString;
  timer: TPrecisionTimer;
begin
  // for further tests, use the dedicated "mORMot GET" (mget) sample
  hps := THttpPeerCacheSettings.Create;
  try
    hps.CacheTempPath := Executable.ProgramFilePath + 'peercachetemp';
    hps.CachePermPath := Executable.ProgramFilePath + 'peercacheperm';
    hps.Port := 8008; // don't use default 8089
    hps.Options := [pcoVerboseLog {,pcoSelfSignedHttps}];
    try
      hpc := THttpPeerCacheHook.Create(hps, 'secret');
      try
        timer.Start;
        hpc.MessageInit(pcfBearer, 0, msg);
        msg.Hash.Algo := hfSHA256;
        n := 1000;
        for i := 1 to n do
        begin
          msg.Size := i;
          msg.Hash.Hash.i0 := i;
          tmp := hpc.MessageEncode(msg);
          Check(tmp <> '');
          Check(hpc.MessageDecode(pointer(tmp), length(tmp), msg2));
          CheckEqual(msg2.Size, i);
          Check(CompareMem(@msg, @msg2, SizeOf(msg)));
        end;
        NotifyTestSpeed('messages', n * 2, n * 2 * SizeOf(msg), @timer);
        Check(ToText(msg) = ToText(msg2));
        timer.Start;
        n := 10000;
        for i := 1 to n do
        begin
          alter := Random32(length(tmp));
          inc(PByteArray(tmp)[alter]); // should be detected at crc level
          Check(not hpc.MessageDecode(pointer(tmp), length(tmp), msg2));
          dec(PByteArray(tmp)[alter]);
        end;
        NotifyTestSpeed('altered', n, n * SizeOf(msg), @timer);
        Check(hpc.MessageDecode(pointer(tmp), length(tmp), msg2));
        Check(CompareMem(@msg, @msg2, SizeOf(msg)));
        for i := 1 to 10 do
          Check(hpc.Ping = nil);
      finally
        hpc.Free;
      end;
    except
      // exception here is likely to be port 8089 already used -> continue
    end;
  finally
    hps.Free;
  end;
end;

end.

