//-----------------------------------------------------------------------------------
//  Translator Package © 2026 by Alexander Tverskoy
//  Licensed under the MIT License
//  You may obtain a copy of the License at https://opensource.org/licenses/MIT
//-----------------------------------------------------------------------------------

unit Network;

{$mode ObjFPC}{$H+}

interface

uses
  Classes,
  Controls,
  SysUtils,
  StrUtils,
  Math,
  Dialogs,
  LCLIntf,
  LCLType,
  PasZLib,
  {$IFDEF WINDOWS}
  Windows,
  wininet,
  {$ENDIF}
  {$IFDEF Linux}
  Unix,
  Process,
  opensslsockets,
  {$ENDIF}
  {$IFDEF MacOS}
  MacOSAll,
  opensslsockets,
  {$ENDIF}
  fpjson,
  jsonparser,
  {$PUSH}
  {$WARNINGS OFF}
  {$HINTS OFF}
  {$NOTES OFF}
  httpsend,
  blcksock,
  {$IFDEF WIN32}
  ssl_openssl11;
  {$ELSE}
  ssl_openssl3;
  {$ENDIF}
  {$POP}

type
  { TWebMethod }

  TWebMethod = (wmGet, wmPost);

  { TProxyMode }

  TProxyMode = (pmNone, pmSystem, pmCustom);

  { TProxyType }

  TProxyType = (ptHTTP, ptSOCKS4, ptSOCKS5);

  { TProxy }

  TProxy = record
    ProxyMode: TProxyMode;
    ProxyType: TProxyType;

    Host: string;
    Port: string;

    Authentication: boolean;
    Login: string;
    Password: string;
  end;

  TTimeout = record
    Request: integer;
    Connection: integer;
  end;

  { Streaming callback, set ACancel to True to abort the stream }
  TStreamChunkEvent = procedure(const AChunk: string; var ACancel: boolean) of object;

  TNetwork = class sealed
  public
    { Web Request }
    class function GetSynapseHeader(const AHeaders: TStringList; const AName: string): string; static;
    class function GetSystemProxy(out Host: string; out Port: integer): boolean; static;
    class procedure ApplyProxy(HTTP: THTTPSend; const P: TProxy);
    class function WebRequest(AMethod: TWebMethod; const AUrl: string; const APostData: string; AHeaders: TStrings;
      const AUserAgent, AContentType, AAccept: string; AllowProxy: boolean; AProxy: TProxy; ATimeout: TTimeout;
      var ACookies: TStringList; out AResponseHeaders: TStringList; out AError: boolean): string;
    // Overload – caller gets ownership of the THTTPSend object
    class function WebRequest(AMethod: TWebMethod; const AUrl: string; const APostData: string; AHeaders: TStrings;
      const AUserAgent, AContentType, AAccept: string; AllowProxy: boolean; AProxy: TProxy; ATimeout: TTimeout;
      var ACookies: TStringList; out AResponseHeaders: TStringList; out AError: boolean; var HTTP: THTTPSend): string; overload;
    // Streaming request for SSE; proxy is not supported in MVP
    class function WebStreamRequest(AMethod: TWebMethod; const AUrl, APostData: string; AHeaders: TStrings;
      const AUserAgent, AContentType, AAccept: string; ATimeout: TTimeout; AOnChunk: TStreamChunkEvent;
      out AErrorMsg: string): boolean; static;
    { Gzip }
    class function IsGzip(Stream: TMemoryStream): boolean; static;
    class function DecompressGzipToStream(Compressed: TMemoryStream): TMemoryStream; static;
  end;

const
  CONNECT_TIMEOUT = 10000;
  REQUEST_TIMEOUT = 30000;

implementation

{%Region -fold Web Request}

class function TNetwork.GetSynapseHeader(const AHeaders: TStringList; const AName: string): string;
var
  j: integer;
  s: string;
  prefix: string;
begin
  Result := string.Empty;
  prefix := AName + ':';
  for j := 0 to AHeaders.Count - 1 do
  begin
    s := AHeaders[j];
    if Pos(prefix, s) = 1 then
    begin
      Result := Trim(Copy(s, Length(prefix) + 1, MaxInt));
      Break;
    end;
  end;
end;

class function TNetwork.GetSystemProxy(out Host: string; out Port: integer): boolean;
var
  {$IFDEF WINDOWS}
  ProxyInfo: PInternetProxyInfo;
  Size: DWORD;
  ProxyStr: string;
  P1: Integer;
  {$ENDIF}

  {$IFDEF LINUX}
  Proxy: string;
  P1: Integer;
  {$ENDIF}
begin
  Result := False;
  Host := '';
  Port := 0;

  {$IFDEF WINDOWS}
  Size := 0;
  InternetQueryOption(nil, INTERNET_OPTION_PROXY, nil, Size);
  if Size = 0 then Exit;

  GetMem(ProxyInfo, Size);
  try
    if not InternetQueryOption(nil, INTERNET_OPTION_PROXY, ProxyInfo, Size) then
      Exit;

    // make sure proxy is really enabled and the string pointer is valid
    if (ProxyInfo^.dwAccessType <> INTERNET_OPEN_TYPE_PROXY) or
       (ProxyInfo^.lpszProxy = nil) then Exit;

    ProxyStr := ProxyInfo^.lpszProxy;

    // try to extract an HTTP (or HTTPS) proxy entry
    // format is typically "http=host:port;https=host:port" or just "host:port"
    if Pos('http=', LowerCase(ProxyStr)) > 0 then
      ProxyStr := Trim(Copy(ProxyStr, Pos('=', ProxyStr) + 1, MaxInt))
    else if Pos('https=', LowerCase(ProxyStr)) > 0 then
      ProxyStr := Trim(Copy(ProxyStr, Pos('=', ProxyStr) + 1, MaxInt))
    else if Pos('=', ProxyStr) > 0 then
      ProxyStr := Trim(Copy(ProxyStr, Pos('=', ProxyStr) + 1, MaxInt));

    // cut off any trailing parameters (other proxies, spaces)
    P1 := Pos(';', ProxyStr);
    if P1 > 0 then
      ProxyStr := Trim(Copy(ProxyStr, 1, P1 - 1));
    P1 := Pos(' ', ProxyStr);
    if P1 > 0 then
      ProxyStr := Trim(Copy(ProxyStr, 1, P1 - 1));

    // now we should have a clean "host:port" pair
    P1 := Pos(':', ProxyStr);
    if P1 = 0 then Exit;

    Host := Trim(Copy(ProxyStr, 1, P1 - 1));
    Port := StrToIntDef(Trim(Copy(ProxyStr, P1 + 1, MaxInt)), 0);

    Result := Host <> '';
  finally
    FreeMem(ProxyInfo);
  end;
  {$ENDIF}

  {$IFDEF LINUX}
  Proxy := GetEnvironmentVariable('http_proxy');
  if Proxy = '' then
    Proxy := GetEnvironmentVariable('https_proxy');
  if Proxy = '' then
    Proxy := GetEnvironmentVariable('all_proxy');

  if Proxy = '' then Exit;

  if Pos('://', Proxy) > 0 then
    Delete(Proxy, 1, Pos('://', Proxy) + 2);

  P1 := Pos(':', Proxy);
  if P1 = 0 then Exit;

  Host := Copy(Proxy, 1, P1 - 1);
  Port := StrToIntDef(Copy(Proxy, P1 + 1, MaxInt), 8080);

  Result := Host <> '';
  {$ENDIF}
end;

class procedure TNetwork.ApplyProxy(HTTP: THTTPSend; const P: TProxy);
var
  Host: string;
  Port: integer;
begin
  case P.ProxyMode of
    pmNone:
      Exit;

    pmSystem:
      if GetSystemProxy(Host, Port) then
      begin
        HTTP.ProxyHost := Host;
        HTTP.ProxyPort := Port.ToString;
      end;

    pmCustom:
    begin
      case P.ProxyType of
        ptHTTP:
        begin
          HTTP.ProxyHost := P.Host;
          HTTP.ProxyPort := P.Port;
          if P.Authentication then
          begin
            HTTP.ProxyUser := P.Login;
            HTTP.ProxyPass := P.Password;
          end;
        end;

        ptSOCKS4:
        begin
          HTTP.Sock.SocksType := ST_Socks4;
          HTTP.Sock.SocksIP := P.Host;
          HTTP.Sock.SocksPort := P.Port;
          if P.Authentication then
          begin
            HTTP.Sock.SocksUsername := P.Login;
            HTTP.Sock.SocksPassword := P.Password;
          end;
        end;

        ptSOCKS5:
        begin
          HTTP.Sock.SocksType := ST_Socks5;
          HTTP.Sock.SocksIP := P.Host;
          HTTP.Sock.SocksPort := P.Port;
          if P.Authentication then
          begin
            HTTP.Sock.SocksUsername := P.Login;
            HTTP.Sock.SocksPassword := P.Password;
          end;
        end;
        else
          ;
      end;
    end;
    else
      ;
  end;
end;

class function TNetwork.WebRequest(AMethod: TWebMethod; const AUrl: string; const APostData: string;
  AHeaders: TStrings; const AUserAgent, AContentType, AAccept: string; AllowProxy: boolean; AProxy: TProxy;
  ATimeout: TTimeout; var ACookies: TStringList; out AResponseHeaders: TStringList; out AError: boolean): string;
var
  HTTP: THTTPSend;
begin
  HTTP := nil;
  // Call overloaded version, then free the HTTP object
  Result := WebRequest(AMethod, AUrl, APostData, AHeaders, AUserAgent, AContentType, AAccept, AllowProxy,
    AProxy, ATimeout, ACookies, AResponseHeaders, AError, HTTP);
  FreeAndNil(HTTP);
end;

class function TNetwork.WebRequest(AMethod: TWebMethod; const AUrl: string; const APostData: string;
  AHeaders: TStrings; const AUserAgent, AContentType, AAccept: string; AllowProxy: boolean; AProxy: TProxy;
  ATimeout: TTimeout; var ACookies: TStringList; out AResponseHeaders: TStringList; out AError: boolean; var HTTP: THTTPSend): string;
var
  rawStream: TMemoryStream;
  decompressedStream: TMemoryStream;
  bodyStream: TStringStream;
  postStream: TStringStream;
  contentEncoding: string;
  i: integer;
begin
  Result := string.Empty;
  AResponseHeaders := TStringList.Create;
  AError := False;

  if Trim(AUrl) = string.Empty then
    Exit;

  if HTTP = nil then
    HTTP := THTTPSend.Create;

  rawStream := TMemoryStream.Create;
  try
    // Common setup
    HTTP.Protocol := '1.1';
    HTTP.Sock.SSL.SSLType := LT_TLSv1_2;

    // Timeouts
    HTTP.Timeout := IfThen(ATimeout.Request > 0, ATimeout.Request, REQUEST_TIMEOUT);
    HTTP.Sock.ConnectionTimeout := IfThen(ATimeout.Connection > 0, ATimeout.Connection, CONNECT_TIMEOUT);
    HTTP.Sock.HTTPTunnelTimeout := HTTP.Sock.ConnectionTimeout;
    HTTP.Sock.SocksTimeout := HTTP.Timeout;
    HTTP.Sock.NonblockSendTimeout := HTTP.Timeout;
    HTTP.Sock.SetSendTimeout(HTTP.Timeout);
    HTTP.Sock.SetRecvTimeout(HTTP.Timeout);
    HTTP.Sock.SetTimeout(HTTP.Timeout);

    if AllowProxy then
      ApplyProxy(HTTP, AProxy);

    HTTP.Headers.Clear;
    if AUserAgent <> string.Empty then
      HTTP.Headers.Add('User-Agent: ' + AUserAgent);
    if AContentType <> string.Empty then
    begin
      if AMethod = wmPost then
        HTTP.MimeType := AContentType
      else
        HTTP.Headers.Add('Content-Type: ' + AContentType);
    end;
    if AAccept <> string.Empty then
      HTTP.Headers.Add('Accept: ' + AAccept);

    // Custom headers – use Names/Values to ensure "Name: Value" format
    if Assigned(AHeaders) then
      for i := 0 to AHeaders.Count - 1 do
        HTTP.Headers.Add(AHeaders.Names[i] + ': ' + AHeaders.ValueFromIndex[i]);

    // POST body (UTF-8)
    if AMethod = wmPost then
    begin
      postStream := TStringStream.Create(APostData, TEncoding.UTF8);
      try
        HTTP.Document.CopyFrom(postStream, 0);
        HTTP.Document.Position := 0;   // Synapse reads from current position
      finally
        FreeAndNil(postStream);
      end;
    end;

    // Apply cookies before the request
    if Assigned(ACookies) and (ACookies.Count > 0) then
      HTTP.Cookies.Assign(ACookies);

    // ***********************
    // Execute request
    // ***********************
    rawStream.Clear;
    HTTP.OutputStream := rawStream;
    if AMethod = wmPost then
      HTTP.HTTPMethod('POST', AUrl)
    else
      HTTP.HTTPMethod('GET', AUrl);

    // Save cookies received in the response
    if Assigned(ACookies) and Assigned(HTTP.Cookies) and (HTTP.Cookies.Count > 0) then
      ACookies.Assign(HTTP.Cookies);

    // Capture response headers
    AResponseHeaders.Assign(HTTP.Headers);

    // Error handling
    if (HTTP.ResultCode div 100) <> 2 then
    begin
      // Try to get the server's error body first
      rawStream.Position := 0;
      if rawStream.Size > 0 then
      begin
        contentEncoding := GetSynapseHeader(AResponseHeaders, 'Content-Encoding');
        bodyStream := TStringStream.Create('', TEncoding.UTF8);
        try
          if SameText(contentEncoding, 'gzip') and IsGzip(rawStream) then
          begin
            decompressedStream := DecompressGzipToStream(rawStream);
            if Assigned(decompressedStream) then
            try
              bodyStream.CopyFrom(decompressedStream, 0);
            finally
              FreeAndNil(decompressedStream);
            end
            else
              bodyStream.CopyFrom(rawStream, 0); // Fallback to compressed body
          end
          else
            bodyStream.CopyFrom(rawStream, 0);

          Result := bodyStream.DataString;
        finally
          FreeAndNil(bodyStream);
        end;
      end;

      // Fallback to standard error description if body is empty
      if Result = string.Empty then
      begin
        if (HTTP.ResultCode = 0) and (HTTP.Sock.LastError <> 0) then
          Result := 'Socket Error: ' + HTTP.Sock.LastErrorDesc
        else
          Result := 'HTTP Error: ' + IntToStr(HTTP.ResultCode) + ' ' + HTTP.ResultString;
      end;

      AError := True;
      Exit;
    end;

    // Read response body
    rawStream.Position := 0;

    // Decompress gzip if needed
    contentEncoding := GetSynapseHeader(AResponseHeaders, 'Content-Encoding');
    bodyStream := TStringStream.Create(string.Empty, TEncoding.UTF8);
    try
      if SameText(contentEncoding, 'gzip') and IsGzip(rawStream) then
      begin
        decompressedStream := DecompressGzipToStream(rawStream);
        if Assigned(decompressedStream) then
        try
          bodyStream.CopyFrom(decompressedStream, 0);
        finally
          FreeAndNil(decompressedStream);
        end
        else
          bodyStream.CopyFrom(rawStream, 0); // Fallback to compressed body
      end
      else
        bodyStream.CopyFrom(rawStream, 0);

      Result := bodyStream.DataString;
    finally
      FreeAndNil(bodyStream);
    end;
  finally
    FreeAndNil(rawStream);
  end;
end;

{%EndRegion}

{%Region -fold Web Stream Request}

class function TNetwork.WebStreamRequest(AMethod: TWebMethod; const AUrl, APostData: string;
  AHeaders: TStrings; const AUserAgent, AContentType, AAccept: string; ATimeout: TTimeout;
  AOnChunk: TStreamChunkEvent; out AErrorMsg: string): boolean;
var
  Sock: TTCPBlockSocket;
  Url, Host, Path, PortStr, Scheme: string;
  Port, DefPort, TimeoutVal, PosSlash, StatusCode, ChunkSize: integer;
  UseHTTPS: boolean;
  Request, StatusLine, HeaderLine, BodyChunk, Value: string;
  ContentLength: int64;
  TransferEncoding: string;
  IsChunked: boolean;
  Cancel: boolean;
  HeaderDone: boolean;
begin
  Result := False;
  AErrorMsg := '';
  if Trim(AUrl) = '' then
  begin
    AErrorMsg := 'Empty URL';
    Exit;
  end;
  if not Assigned(AOnChunk) then
  begin
    AErrorMsg := 'No callback';
    Exit;
  end;

  // Parse scheme, host, port and path
  Url := AUrl;
  Scheme := LowerCase(Copy(Url, 1, 8));
  if Pos('https://', Scheme) = 1 then
  begin
    UseHTTPS := True;
    Delete(Url, 1, 8);
  end
  else if Pos('http://', Scheme) = 1 then
  begin
    UseHTTPS := False;
    Delete(Url, 1, 7);
  end
  else
  begin
    AErrorMsg := 'Unsupported scheme';
    Exit;
  end;

  if UseHTTPS then
    DefPort := 443
  else
    DefPort := 80;

  Path := '/';
  PosSlash := Pos('/', Url);
  if PosSlash > 0 then
  begin
    Path := Copy(Url, PosSlash, MaxInt);
    Url := Copy(Url, 1, PosSlash - 1);
  end;

  PortStr := '';
  StatusCode := Pos(':', Url);
  if StatusCode > 0 then
  begin
    Host := Copy(Url, 1, StatusCode - 1);
    PortStr := Copy(Url, StatusCode + 1, MaxInt);
  end
  else
    Host := Url;

  Port := StrToIntDef(PortStr, DefPort);
  if Host = '' then
  begin
    AErrorMsg := 'Empty host';
    Exit;
  end;

  // Build HTTP request manually
  Request := IfThen(AMethod = wmPost, 'POST ', 'GET ') + Path + ' HTTP/1.1' + CRLF;
  Request := Request + 'Host: ' + Host;
  if Port <> DefPort then
    Request := Request + ':' + IntToStr(Port);
  Request := Request + CRLF;
  if AUserAgent <> '' then
    Request := Request + 'User-Agent: ' + AUserAgent + CRLF;
  if AContentType <> '' then
    Request := Request + 'Content-Type: ' + AContentType + CRLF;
  if AAccept <> '' then
    Request := Request + 'Accept: ' + AAccept + CRLF;
  if Assigned(AHeaders) then
    for StatusCode := 0 to AHeaders.Count - 1 do
      Request := Request + AHeaders.Names[StatusCode] + ': ' +
        AHeaders.ValueFromIndex[StatusCode] + CRLF;
  if AMethod = wmPost then
    Request := Request + 'Content-Length: ' + IntToStr(Length(APostData)) + CRLF;
  Request := Request + 'Connection: close' + CRLF + CRLF;
  if AMethod = wmPost then
    Request := Request + APostData;

  Sock := TTCPBlockSocket.Create;
  try
    Sock.SSL.SSLType := LT_TLSv1_2;
    if ATimeout.Connection > 0 then
      Sock.ConnectionTimeout := ATimeout.Connection
    else
      Sock.ConnectionTimeout := CONNECT_TIMEOUT;
    if ATimeout.Request > 0 then
      TimeoutVal := ATimeout.Request
    else
      TimeoutVal := REQUEST_TIMEOUT;
    Sock.SetTimeout(TimeoutVal);

    Sock.Connect(Host, IntToStr(Port));
    if Sock.LastError <> 0 then
    begin
      AErrorMsg := 'Connect error: ' + Sock.LastErrorDesc;
      Exit;
    end;

    if UseHTTPS then
    begin
      Sock.SSLDoConnect;
      if Sock.LastError <> 0 then
      begin
        AErrorMsg := 'SSL error: ' + Sock.LastErrorDesc;
        Exit;
      end;
    end;

    Sock.SendString(Request);
    if Sock.LastError <> 0 then
    begin
      AErrorMsg := 'Send error: ' + Sock.LastErrorDesc;
      Exit;
    end;

    // Status line
    StatusLine := Sock.RecvString(TimeoutVal);
    if Sock.LastError <> 0 then
    begin
      AErrorMsg := 'Recv status error: ' + Sock.LastErrorDesc;
      Exit;
    end;

    StatusCode := 0;
    if Pos('HTTP/', StatusLine) = 1 then
    begin
      Value := Trim(Copy(StatusLine, Pos(' ', StatusLine) + 1, MaxInt));
      StatusCode := StrToIntDef(Copy(Value, 1, Pos(' ', Value + ' ') - 1), 0);
    end;

    // Headers
    ContentLength := -1;
    IsChunked := False;
    TransferEncoding := '';
    HeaderDone := False;
    repeat
      HeaderLine := Sock.RecvString(TimeoutVal);
      if Sock.LastError <> 0 then
      begin
        AErrorMsg := 'Recv header error: ' + Sock.LastErrorDesc;
        Exit;
      end;
      if HeaderLine = '' then
        HeaderDone := True
      else if Pos('content-length:', LowerCase(HeaderLine)) = 1 then
        ContentLength := StrToInt64Def(Trim(Copy(HeaderLine, 16, MaxInt)), -1)
      else if Pos('transfer-encoding:', LowerCase(HeaderLine)) = 1 then
      begin
        TransferEncoding := LowerCase(Trim(Copy(HeaderLine, 19, MaxInt)));
        if Pos('chunked', TransferEncoding) > 0 then
          IsChunked := True;
      end;
    until HeaderDone;

    if StatusCode <> 200 then
    begin
      AErrorMsg := 'HTTP ' + IntToStr(StatusCode);
      Exit;
    end;

    // Body
    Cancel := False;
    if IsChunked then
    begin
      while not Cancel do
      begin
        HeaderLine := Sock.RecvString(TimeoutVal);
        if Sock.LastError <> 0 then
          Break;
        ChunkSize := StrToIntDef('$' + Trim(HeaderLine), 0);
        if ChunkSize = 0 then
        begin
          Sock.RecvString(TimeoutVal);
          Break;
        end;
        BodyChunk := Sock.RecvBufferStr(ChunkSize, TimeoutVal);
        if Sock.LastError <> 0 then
          Break;
        // Consume trailing CRLF after chunk data
        Sock.RecvString(TimeoutVal);
        if BodyChunk <> '' then
          AOnChunk(BodyChunk, Cancel);
      end;
    end
    else if ContentLength >= 0 then
    begin
      while (ContentLength > 0) and not Cancel do
      begin
        if ContentLength > 4096 then
          ChunkSize := 4096
        else
          ChunkSize := ContentLength;
        BodyChunk := Sock.RecvBufferStr(ChunkSize, TimeoutVal);
        if Sock.LastError <> 0 then
          Break;
        if BodyChunk = '' then
          Break;
        Dec(ContentLength, Length(BodyChunk));
        AOnChunk(BodyChunk, Cancel);
      end;
    end
    else
    begin
      while not Cancel do
      begin
        BodyChunk := Sock.RecvBufferStr(4096, TimeoutVal);
        if BodyChunk = '' then
          Break;
        AOnChunk(BodyChunk, Cancel);
      end;
    end;

    Result := True;
  finally
    Sock.Free;
  end;
end;

{%EndRegion}

{%Region -fold Gzip}

class function TNetwork.IsGzip(Stream: TMemoryStream): boolean;
var
  p: pbyte;
begin
  Result := False;
  if Stream.Size < 2 then Exit;
  p := pbyte(Stream.Memory);
  Result := (p^ = $1F) and ((p + 1)^ = $8B);
end;

class function TNetwork.DecompressGzipToStream(Compressed: TMemoryStream): TMemoryStream;
var
  zstream: TZStream;
  err: integer;
  outBuffer: array[0..8191] of byte;
  bytesWritten: longint;
  p: pbyte;
  flags: byte;
  xlen: word;
  dataPos: integer;
begin
  zstream := Default(TZStream);
  Result := TMemoryStream.Create;
  try
    // Basic validation: gzip header
    if Compressed.Size < 10 then
      raise Exception.Create('Compressed data too small for gzip');
    p := pbyte(Compressed.Memory);
    if (p[0] <> $1F) or (p[1] <> $8B) then
      raise Exception.Create('Not a gzip stream (invalid ID bytes)');

    // Check compression method (must be deflate, 8)
    if p[2] <> 8 then
      raise Exception.Create('Unsupported compression method (not deflate)');

    flags := p[3];
    dataPos := 10; // start after fixed header (10 bytes)

    // Skip extra field (FEXTRA) if present
    if (flags and $04) <> 0 then
    begin
      if Compressed.Size < int64(dataPos) + 2 then
        raise Exception.Create('Truncated gzip: FEXTRA length missing');
      xlen := p[dataPos] or (p[dataPos + 1] shl 8);
      Inc(dataPos, 2 + xlen);
    end;

    // Skip original filename (FNAME) if present (null-terminated)
    if (flags and $08) <> 0 then
    begin
      while (dataPos < Compressed.Size) and (p[dataPos] <> 0) do
        Inc(dataPos);

      if dataPos >= Compressed.Size then
        raise Exception.Create('Truncated gzip header');

      Inc(dataPos); // skip null terminator
    end;

    // Skip file comment (FCOMMENT) if present (null-terminated)
    if (flags and $10) <> 0 then
    begin
      while (dataPos < Compressed.Size) and (p[dataPos] <> 0) do
        Inc(dataPos);

      if dataPos >= Compressed.Size then
        raise Exception.Create('Truncated gzip header');

      Inc(dataPos); // skip null terminator
    end;

    // Skip header CRC (FHCRC) if present (2 bytes)
    if (flags and $02) <> 0 then
      Inc(dataPos, 2);

    if dataPos > Compressed.Size then
      raise Exception.Create('Truncated gzip header');

    if dataPos = Compressed.Size then
      raise Exception.Create('No compressed data after gzip header');

    {$PUSH}
    {$NOTES OFF}

    // Zero out the zstream structure
    FillChar(zstream, SizeOf(zstream), 0);

    // Initialize for raw deflate decoding (windowBits = -15)
    err := inflateInit2(zstream, -15);  // uses correct version and size automatically
    if err <> Z_OK then
      raise Exception.Create('inflateInit2 error: ' + IntToStr(err));

    try
      // Point to the compressed data after the header
      zstream.next_in := p + dataPos;
      zstream.avail_in := cardinal(Compressed.Size - dataPos);

      repeat
        zstream.next_out := @outBuffer;
        zstream.avail_out := SizeOf(outBuffer);

        err := inflate(zstream, Z_NO_FLUSH);
        if err < 0 then
        begin
          FreeAndNil(Result);
          Exit;
        end;

        bytesWritten := SizeOf(outBuffer) - zstream.avail_out;
        if bytesWritten > 0 then
          Result.Write(outBuffer, bytesWritten);

      until err = Z_STREAM_END; // End of stream reached
    finally
      inflateEnd(zstream);
    end;
    {$POP}

    Result.Position := 0;
  except
    FreeAndNil(Result);
    // No raise;
  end;
end;

{%EndRegion}

end.
