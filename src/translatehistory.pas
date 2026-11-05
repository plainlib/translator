//-----------------------------------------------------------------------------------
//  Translator Package © 2026 by Alexander Tverskoy
//  Licensed under the MIT License
//  You may obtain a copy of the License at https://opensource.org/licenses/MIT
//-----------------------------------------------------------------------------------

unit TranslateHistory;

{$mode ObjFPC}{$H+}
{$codepage utf8}

interface

uses
  Classes,
  SysUtils;

type
  // Single stored translation entry
  THistoryItem = class
  public
    SourceText: string;
    TargetText: string;
    SourceLang: string;
    TargetLang: string;
    ConfigFile: string;
    Timestamp: TDateTime;
  end;

  // Dynamic array of entry indices, returned by Find
  TIntegerArray = array of integer;

  // Holds the translation history and the current navigation position
  THistoryManager = class
  private
    FItems: TList;
    FIndex: integer;
    FMaxItems: integer;
    FFileName: string;
    // Number of Add records currently in the file; grows on each append,
    // resets when the file is rewritten by Compact
    FFileEntryCount: integer;
    // True when the file could not be fully parsed; next Add will Compact
    FNeedsRebuild: boolean;
    procedure ClearItems;
    procedure TrimOldest;
    procedure WriteString(AStream: TStream; const AValue: string);
    function ReadString(AStream: TStream): string;
    procedure AppendEntryToFile(AItem: THistoryItem);
    function GetCount: integer;
  public
    constructor Create(const AFileName: string; AMaxItems: integer = 100);
    destructor Destroy; override;
    procedure Load;
    // Rewrites the file from the current in-memory state; used for Delete,
    // Clear, forward-branch truncation and lazy cleanup of orphan records
    procedure Compact;
    // Alias for Compact, kept for backward compatibility
    procedure Save;
    procedure Add(AItem: THistoryItem);
    function AddText(const ASourceText, ATargetText, ASourceLang, ATargetLang, AConfigFile: string): THistoryItem;
    function Prev(out AItem: THistoryItem): boolean;
    function Next(out AItem: THistoryItem): boolean;
    function First(out AItem: THistoryItem): boolean;
    function Last(out AItem: THistoryItem): boolean;
    // Sets the current position to AIndex without touching the file
    function Select(AIndex: integer; out AItem: THistoryItem): boolean;
    function Delete(AIndex: integer): boolean;
    function DeleteCurrent: boolean;
    function CanPrev: boolean;
    function CanNext: boolean;
    function GetItem(AIndex: integer): THistoryItem;
    // Returns indices of entries matching the filter and the date range.
    // Filter is a case-insensitive substring in any field; empty means all.
    // Date range is half-open [ADateFrom, ADateTo); zero means unbounded
    function Find(const AFilter: string; const ADateFrom: TDateTime = 0; const ADateTo: TDateTime = 0): TIntegerArray;
    // Convenience wrapper: date range only, same time semantics as Find
    function FindByDate(const ADateFrom, ADateTo: TDateTime): TIntegerArray;
    procedure Clear;
    property Index: integer read FIndex;
    property Count: integer read GetCount;
    property MaxItems: integer read FMaxItems write FMaxItems;
    property FileName: string read FFileName write FFileName;
  end;

implementation

uses
  LazUTF8,
  StringHelper,
  OSUtils;

const
  // File header: 'TLH2' + version (2) + reserved (2)
  HISTORY_MAGIC: array[0..3] of byte = (Ord('T'), Ord('L'), Ord('H'), Ord('2'));
  HISTORY_HEADER_SIZE = 8;
  HISTORY_VERSION = 1;

  // Sanity guards against corrupted length fields
  MAX_RECORD_PAYLOAD = 64 * 1024 * 1024;
  MAX_STRING_BYTES = 16 * 1024 * 1024;

  // Record types
  REC_ADD = 1;
  REC_CLEAR = 2;

constructor THistoryManager.Create(const AFileName: string; AMaxItems: integer = 100);
begin
  inherited Create;
  FItems := TList.Create;
  FIndex := -1;
  FMaxItems := AMaxItems;
  FFileName := AFileName;
  FFileEntryCount := 0;
  FNeedsRebuild := False;
end;

destructor THistoryManager.Destroy;
begin
  ClearItems;
  FItems.Free;
  inherited Destroy;
end;

procedure THistoryManager.ClearItems;
var
  i: integer;
begin
  for i := 0 to FItems.Count - 1 do
    THistoryItem(FItems[i]).Free;
  FItems.Clear;
end;

procedure THistoryManager.TrimOldest;
begin
  // Drop oldest entries until the limit is respected
  while (FMaxItems > 0) and (FItems.Count > FMaxItems) do
  begin
    THistoryItem(FItems[0]).Free;
    FItems.Delete(0);
    if FIndex > 0 then
      Dec(FIndex);
  end;
end;

procedure THistoryManager.WriteString(AStream: TStream; const AValue: string);
var
  Len: cardinal;
  Utf8: rawbytestring;
begin
  Utf8 := UTF8Encode(AValue);
  Len := Length(Utf8);
  AStream.WriteBuffer(Len, SizeOf(Len));
  if Len > 0 then
    AStream.WriteBuffer(Utf8[1], Len);
end;

function THistoryManager.ReadString(AStream: TStream): string;
var
  Len: cardinal;
  Utf8: rawbytestring;
begin
  AStream.ReadBuffer(Len, SizeOf(Len));
  if Len > MAX_STRING_BYTES then
    raise Exception.Create('History entry is corrupted');
  if Len = 0 then
  begin
    Result := '';
    Exit;
  end;
  SetLength(Utf8, Len);
  AStream.ReadBuffer(Utf8[1], Len);
  Result := UTF8Decode(Utf8);
end;

procedure THistoryManager.Load;
var
  FileStream: TFileStream = nil;
  Header: array[0..HISTORY_HEADER_SIZE - 1] of byte;
  RecType: byte;
  PayloadLen: cardinal;
  CompressedBuf: TMemoryStream = nil;
  RawBuf: TMemoryStream = nil;
  Item: THistoryItem;
  Ts: double;
  Ver: word;
  Clean: boolean;
begin
  ClearItems;
  FIndex := -1;
  FFileEntryCount := 0;

  if not FileExists(FFileName) then
  begin
    FNeedsRebuild := False;
    Exit;
  end;

  // Any failure below leaves FNeedsRebuild = True so the next Add compacts
  FNeedsRebuild := True;

  try
    try
      FileStream := TFileStream.Create(FFileName, fmOpenRead or fmShareDenyNone);
      try
        if FileStream.Size < HISTORY_HEADER_SIZE then
          Exit;

        FileStream.ReadBuffer(Header, HISTORY_HEADER_SIZE);

        // Reject other formats and versions
        if (Header[0] <> HISTORY_MAGIC[0]) or (Header[1] <> HISTORY_MAGIC[1]) or (Header[2] <> HISTORY_MAGIC[2]) or
          (Header[3] <> HISTORY_MAGIC[3]) then
          Exit;

        Move(Header[4], Ver, SizeOf(Ver));
        if Ver <> HISTORY_VERSION then
          Exit;

        Clean := True;
        while FileStream.Position < FileStream.Size do
        begin
          if FileStream.Read(RecType, SizeOf(RecType)) <> SizeOf(RecType) then
          begin
            Clean := False;
            Break;
          end;
          if FileStream.Read(PayloadLen, SizeOf(PayloadLen)) <> SizeOf(PayloadLen) then
          begin
            Clean := False;
            Break;
          end;
          if PayloadLen > MAX_RECORD_PAYLOAD then
          begin
            Clean := False;
            Break;
          end;
          if FileStream.Position + PayloadLen > FileStream.Size then
          begin
            Clean := False;
            Break;
          end;

          if PayloadLen > 0 then
          begin
            CompressedBuf := TMemoryStream.Create;
            try
              CompressedBuf.SetSize(PayloadLen);
              FileStream.ReadBuffer(CompressedBuf.Memory^, PayloadLen);
              CompressedBuf.Position := 0;
              RawBuf := TOS.DecompressMemoryStream(CompressedBuf);
            finally
              FreeAndNil(CompressedBuf);
            end;
          end
          else
            RawBuf := TMemoryStream.Create;

          try
            try
              case RecType of
                REC_ADD:
                begin
                  Item := THistoryItem.Create;
                  try
                    Item.SourceText := ReadString(RawBuf);
                    Item.TargetText := ReadString(RawBuf);
                    Item.SourceLang := ReadString(RawBuf);
                    Item.TargetLang := ReadString(RawBuf);
                    Item.ConfigFile := ReadString(RawBuf);
                    RawBuf.ReadBuffer(Ts, SizeOf(Ts));
                    Item.Timestamp := Ts;
                  except
                    Item.Free;
                    raise;
                  end;
                  FItems.Add(Item);
                  Inc(FFileEntryCount);
                end;
                REC_CLEAR:
                begin
                  ClearItems;
                  FFileEntryCount := 0;
                end;
                else
                  raise Exception.Create('Unknown record type');
              end;
            except
              Clean := False;
              Break;
            end;
          finally
            FreeAndNil(RawBuf);
          end;
        end;

        // File fully parsed: trust it for appends
        if Clean then
          FNeedsRebuild := False;
      finally
        FreeAndNil(FileStream);
      end;

      // Memory cap; drop orphans from the file when trimming happened
      if (FMaxItems > 0) and (FItems.Count > FMaxItems) then
      begin
        TrimOldest;
        Compact;
      end;
    except
      // Unreadable file: start from an empty in-memory history
      ClearItems;
      FFileEntryCount := 0;
    end;
  finally
    if FItems.Count = 0 then
      FIndex := -1
    else
      FIndex := FItems.Count - 1;
  end;
end;

procedure THistoryManager.AppendEntryToFile(AItem: THistoryItem);
var
  RawBuf: TMemoryStream = nil;
  CompressedBuf: TMemoryStream = nil;
  FileStream: TFileStream = nil;
  RecType: byte;
  PayloadLen: cardinal;
  Ver: word;
  Reserved: word;
  Ts: double;
  Dir: string;
begin
  if (FFileName = '') or (AItem = nil) then
    Exit;

  RawBuf := TMemoryStream.Create;
  try
    WriteString(RawBuf, AItem.SourceText);
    WriteString(RawBuf, AItem.TargetText);
    WriteString(RawBuf, AItem.SourceLang);
    WriteString(RawBuf, AItem.TargetLang);
    WriteString(RawBuf, AItem.ConfigFile);
    Ts := AItem.Timestamp;
    RawBuf.WriteBuffer(Ts, SizeOf(Ts));
    RawBuf.Position := 0;
    CompressedBuf := TOS.CompressMemoryStream(RawBuf);
  finally
    FreeAndNil(RawBuf);
  end;

  try
    Dir := ExtractFileDir(FFileName);
    if Dir <> '' then
      ForceDirectories(Dir);

    if FileExists(FFileName) then
      FileStream := TFileStream.Create(FFileName, fmOpenReadWrite or fmShareDenyNone)
    else
      FileStream := TFileStream.Create(FFileName, fmCreate);

    try
      // Fresh file gets the header
      if FileStream.Size = 0 then
      begin
        FileStream.WriteBuffer(HISTORY_MAGIC, SizeOf(HISTORY_MAGIC));
        Ver := HISTORY_VERSION;
        FileStream.WriteBuffer(Ver, SizeOf(Ver));
        Reserved := 0;
        FileStream.WriteBuffer(Reserved, SizeOf(Reserved));
      end;

      // Append one Add record
      FileStream.Position := FileStream.Size;
      RecType := REC_ADD;
      FileStream.WriteBuffer(RecType, SizeOf(RecType));
      PayloadLen := CompressedBuf.Size;
      FileStream.WriteBuffer(PayloadLen, SizeOf(PayloadLen));
      CompressedBuf.Position := 0;
      FileStream.CopyFrom(CompressedBuf, CompressedBuf.Size);
    finally
      FreeAndNil(FileStream);
    end;
  except
    // History is not critical; a failed append must not break the app
  end;

  FreeAndNil(CompressedBuf);
end;

procedure THistoryManager.Compact;
var
  TmpFileName: string;
  FileStream: TFileStream = nil;
  RawBuf: TMemoryStream = nil;
  CompressedBuf: TMemoryStream = nil;
  i: integer;
  Item: THistoryItem;
  RecType: byte;
  PayloadLen: cardinal;
  Ver: word;
  Reserved: word;
  Ts: double;
  Dir: string;
begin
  if FFileName = '' then
    Exit;

  Dir := ExtractFileDir(FFileName);
  if Dir <> '' then
    ForceDirectories(Dir);

  TmpFileName := FFileName + '.tmp';

  try
    FileStream := TFileStream.Create(TmpFileName, fmCreate);
    try
      // Header
      FileStream.WriteBuffer(HISTORY_MAGIC, SizeOf(HISTORY_MAGIC));
      Ver := HISTORY_VERSION;
      FileStream.WriteBuffer(Ver, SizeOf(Ver));
      Reserved := 0;
      FileStream.WriteBuffer(Reserved, SizeOf(Reserved));

      // One Add record per current entry
      for i := 0 to FItems.Count - 1 do
      begin
        Item := THistoryItem(FItems[i]);

        RawBuf := TMemoryStream.Create;
        try
          WriteString(RawBuf, Item.SourceText);
          WriteString(RawBuf, Item.TargetText);
          WriteString(RawBuf, Item.SourceLang);
          WriteString(RawBuf, Item.TargetLang);
          WriteString(RawBuf, Item.ConfigFile);
          Ts := Item.Timestamp;
          RawBuf.WriteBuffer(Ts, SizeOf(Ts));
          RawBuf.Position := 0;
          CompressedBuf := TOS.CompressMemoryStream(RawBuf);
        finally
          FreeAndNil(RawBuf);
        end;

        try
          RecType := REC_ADD;
          FileStream.WriteBuffer(RecType, SizeOf(RecType));
          PayloadLen := CompressedBuf.Size;
          FileStream.WriteBuffer(PayloadLen, SizeOf(PayloadLen));
          CompressedBuf.Position := 0;
          FileStream.CopyFrom(CompressedBuf, CompressedBuf.Size);
        finally
          FreeAndNil(CompressedBuf);
        end;
      end;
    finally
      FreeAndNil(FileStream);
    end;

    // Replace the old file atomically
    if FileExists(FFileName) then
      DeleteFile(FFileName);
    if not RenameFile(TmpFileName, FFileName) then
      DeleteFile(TmpFileName);

    FFileEntryCount := FItems.Count;
    FNeedsRebuild := False;
  except
    // Failed compact leaves the previous file intact
    if FileExists(TmpFileName) then
      DeleteFile(TmpFileName);
  end;
end;

procedure THistoryManager.Save;
begin
  Compact;
end;

procedure THistoryManager.Add(AItem: THistoryItem);
var
  Truncated: boolean;
begin
  if AItem = nil then
    Exit;

  // Truncate the forward branch when not at the last item
  Truncated := False;
  if (FIndex >= 0) and (FIndex < FItems.Count - 1) then
  begin
    while FItems.Count > FIndex + 1 do
    begin
      THistoryItem(FItems[FItems.Count - 1]).Free;
      FItems.Delete(FItems.Count - 1);
    end;
    Truncated := True;
  end;

  FItems.Add(AItem);
  FIndex := FItems.Count - 1;

  // Compact when the file is untrusted or the forward branch was dropped,
  // because append alone cannot express either case to Load
  if FNeedsRebuild or Truncated then
  begin
    Compact;
    Exit;
  end;

  // Normal case: append one record, O(1) regardless of history size
  Inc(FFileEntryCount);
  AppendEntryToFile(AItem);

  // Lazy cleanup of orphan records once the file outgrows twice the limit
  if (FMaxItems > 0) and (FItems.Count > FMaxItems) then
  begin
    TrimOldest;
    if FFileEntryCount > FMaxItems * 2 then
      Compact;
  end;
end;

function THistoryManager.AddText(const ASourceText, ATargetText, ASourceLang, ATargetLang, AConfigFile: string): THistoryItem;
var
  Current: THistoryItem;
begin
  Result := nil;
  if Trim(ASourceText) = '' then
    Exit;

  // Skip when the new entry fully matches the current item, which after the
  // forward-branch truncation becomes the record immediately before it.
  // Trim drops outer whitespace, EqualNormalized folds CRLF vs LF: RichMemo
  // rewrites line endings when text round-trips through the memo, so the raw
  // service output and the memo readback rarely match byte-for-byte
  if (FIndex >= 0) and (FIndex < FItems.Count) then
  begin
    Current := THistoryItem(FItems[FIndex]);
    if Trim(Current.SourceText).EqualNormalized(Trim(ASourceText), False) and
      Trim(Current.TargetText).EqualNormalized(Trim(ATargetText), False) and SameText(Current.SourceLang, ASourceLang) and
      SameText(Current.TargetLang, ATargetLang) and
      // Config paths are case-insensitive on Windows; never treat them as
      // different entries just because the case drifted
      SameText(Current.ConfigFile, AConfigFile) then
      Exit;
  end;

  Result := THistoryItem.Create;
  Result.SourceText := ASourceText;
  Result.TargetText := ATargetText;
  Result.SourceLang := ASourceLang;
  Result.TargetLang := ATargetLang;
  Result.ConfigFile := AConfigFile;
  Result.Timestamp := Now;
  Add(Result);
end;

function THistoryManager.Prev(out AItem: THistoryItem): boolean;
begin
  // Navigation changes only FIndex; the file is not touched
  AItem := nil;
  if not CanPrev then
    Exit(False);
  Dec(FIndex);
  AItem := THistoryItem(FItems[FIndex]);
  Result := True;
end;

function THistoryManager.Next(out AItem: THistoryItem): boolean;
begin
  AItem := nil;
  if not CanNext then
    Exit(False);
  Inc(FIndex);
  AItem := THistoryItem(FItems[FIndex]);
  Result := True;
end;

function THistoryManager.First(out AItem: THistoryItem): boolean;
begin
  AItem := nil;
  if FItems.Count = 0 then
    Exit(False);
  FIndex := 0;
  AItem := THistoryItem(FItems[FIndex]);
  Result := True;
end;

function THistoryManager.Last(out AItem: THistoryItem): boolean;
begin
  AItem := nil;
  if FItems.Count = 0 then
    Exit(False);
  FIndex := FItems.Count - 1;
  AItem := THistoryItem(FItems[FIndex]);
  Result := True;
end;

function THistoryManager.Select(AIndex: integer; out AItem: THistoryItem): boolean;
begin
  // Navigation changes only FIndex; the file is not touched
  AItem := nil;
  if (AIndex < 0) or (AIndex >= FItems.Count) then
    Exit(False);
  FIndex := AIndex;
  AItem := THistoryItem(FItems[FIndex]);
  Result := True;
end;

function THistoryManager.Delete(AIndex: integer): boolean;
begin
  Result := False;
  if (AIndex < 0) or (AIndex >= FItems.Count) then Exit;

  THistoryItem(FItems[AIndex]).Free;
  FItems.Delete(AIndex);

  // Keep the position stable after removal
  if FItems.Count = 0 then
    FIndex := -1
  else if AIndex < FIndex then
    Dec(FIndex)
  else if (AIndex = FIndex) and (FIndex >= FItems.Count) then
    FIndex := FItems.Count - 1;

  // Delete is rare; rewrite the file from the in-memory state
  Compact;
  Result := True;
end;

function THistoryManager.DeleteCurrent: boolean;
begin
  Result := Delete(FIndex);
end;

function THistoryManager.CanPrev: boolean;
begin
  Result := FIndex > 0;
end;

function THistoryManager.CanNext: boolean;
begin
  Result := (FIndex >= 0) and (FIndex < FItems.Count - 1);
end;

function THistoryManager.GetItem(AIndex: integer): THistoryItem;
begin
  if (AIndex >= 0) and (AIndex < FItems.Count) then
    Result := THistoryItem(FItems[AIndex])
  else
    Result := nil;
end;

function THistoryManager.Find(const AFilter: string; const ADateFrom: TDateTime = 0; const ADateTo: TDateTime = 0): TIntegerArray;
var
  FilterLower: string;
  HasFilter, HasFrom, HasTo: boolean;
  i, MatchCount: integer;
  Item: THistoryItem;
  Match: boolean;
begin
  SetLength(Result, 0);
  if FItems.Count = 0 then
    Exit;

  HasFilter := AFilter <> '';
  HasFrom := ADateFrom > 0;
  HasTo := ADateTo > 0;

  // No constraints at all returns every entry
  if not (HasFilter or HasFrom or HasTo) then
  begin
    SetLength(Result, FItems.Count);
    for i := 0 to FItems.Count - 1 do
      Result[i] := i;
    Exit;
  end;

  if HasFilter then
    FilterLower := UTF8LowerCase(AFilter)
  else
    FilterLower := '';

  SetLength(Result, FItems.Count);
  MatchCount := 0;

  for i := 0 to FItems.Count - 1 do
  begin
    Item := THistoryItem(FItems[i]);
    Match := True;

    // Date range is half-open [From, To); zero means unbounded
    if HasFrom and (Item.Timestamp < ADateFrom) then
      Match := False;
    if Match and HasTo and (Item.Timestamp >= ADateTo) then
      Match := False;

    // Text filter matches any of the stored text or metadata fields
    if Match and HasFilter then
    begin
      if (Pos(FilterLower, UTF8LowerCase(Item.SourceText)) = 0) and (Pos(FilterLower, UTF8LowerCase(Item.TargetText)) = 0) and
        (Pos(FilterLower, UTF8LowerCase(Item.SourceLang)) = 0) and (Pos(FilterLower, UTF8LowerCase(Item.TargetLang)) = 0) and
        (Pos(FilterLower, UTF8LowerCase(Item.ConfigFile)) = 0) then
        Match := False;
    end;

    if Match then
    begin
      Result[MatchCount] := i;
      Inc(MatchCount);
    end;
  end;

  SetLength(Result, MatchCount);
end;

function THistoryManager.FindByDate(const ADateFrom, ADateTo: TDateTime): TIntegerArray;
begin
  Result := Find('', ADateFrom, ADateTo);
end;

function THistoryManager.GetCount: integer;
begin
  Result := FItems.Count;
end;

procedure THistoryManager.Clear;
begin
  ClearItems;
  FIndex := -1;
  FFileEntryCount := 0;
  Compact;
end;

end.
