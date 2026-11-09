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

  // Optional resolver that maps a stored language code to its display name;
  // lets Find match queries like "English" against code "en"
  TLangDisplayResolver = function(const ACode: string): string of object;

  // Callback invoked before forward history is truncated; AAllow defaults to
  // True, set to False to keep the full history and jump to the end instead
  THistoryTruncateQueryEvent = procedure(Sender: TObject; var AAllow: boolean) of object;

  // Per-record index entry: file offset and compressed payload length.
  // Record must be declared before the pointer that refers to it
  TFileEntry = record
    Offset: int64;
    PayloadLen: uint32;
  end;
  PFileEntry = ^TFileEntry;

  // Holds the translation history and the current navigation position.
  // In lazy mode only the file index is kept in memory; entries are read
  // on demand. Call LoadFull to materialize everything (used by Find and by
  // host forms that need bulk access), and Unload to release it again
  THistoryManager = class
  private
    FEntries: TList;         // of PFileEntry, mirrors file record order
    FItems: TList;           // of THistoryItem, populated only when FLoaded
    FCurrentItem: THistoryItem;  // cached current entry for lazy mode
    FLoaded: boolean;        // True when FItems holds every entry
    FIndex: integer;         // current position in the live entry list
    FMaxItems: integer;
    FFileName: string;
    FFileEntryCount: integer;  // records physically present in the file
    FNeedsRebuild: boolean;    // file could not be trusted; next Add compacts
    FOnTruncateQuery: THistoryTruncateQueryEvent;
    procedure ClearItems;
    procedure ClearEntries;
    procedure SetMaxItems(const AValue: integer);
    procedure TrimOldest;
    procedure WriteString(AStream: TStream; const AValue: string);
    function ReadString(AStream: TStream): string;
    function LoadEntryFromStream(AStream: TStream; AEntry: PFileEntry): THistoryItem;
    function LoadEntryFromFile(AIndex: integer): THistoryItem;
    procedure AppendEntryToFile(AItem: THistoryItem; AEntry: PFileEntry);
    procedure EnsureLoaded;
    function GetCount: integer;
    function GetLoaded: boolean;
  public
    constructor Create(const AFileName: string; AMaxItems: integer = 100);
    destructor Destroy; override;
    // Builds only the file index; existing FItems are released
    procedure Load;
    // Materializes every entry into memory for bulk access
    procedure LoadFull;
    // Releases the loaded entries, keeps the index and the current entry
    procedure Unload;
    // Rewrites the file from the current in-memory state
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
    // Date range is half-open [ADateFrom, ADateTo); zero means unbounded.
    // Auto-calls LoadFull; caller should Unload when bulk access ends
    function Find(const AFilter: string; const ADateFrom: TDateTime = 0; const ADateTo: TDateTime = 0;
      ALangResolver: TLangDisplayResolver = nil): TIntegerArray;
    function FindByDate(const ADateFrom, ADateTo: TDateTime): TIntegerArray;
    procedure Clear;
    property Index: integer read FIndex;
    property Count: integer read GetCount;
    property Loaded: boolean read GetLoaded;
    property MaxItems: integer read FMaxItems write SetMaxItems;
    property FileName: string read FFileName write FFileName;
    // Fires before forward entries are dropped after AddText on a stale
    // position; leave nil to always truncate (legacy behavior)
    property OnTruncateQuery: THistoryTruncateQueryEvent read FOnTruncateQuery write FOnTruncateQuery;
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

  REC_ADD = 1;

constructor THistoryManager.Create(const AFileName: string; AMaxItems: integer = 100);
begin
  inherited Create;
  FEntries := TList.Create;
  FItems := TList.Create;
  FCurrentItem := nil;
  FLoaded := False;
  FIndex := -1;
  FMaxItems := AMaxItems;
  FFileName := AFileName;
  FFileEntryCount := 0;
  FNeedsRebuild := False;
end;

destructor THistoryManager.Destroy;
begin
  ClearItems;
  ClearEntries;
  FreeAndNil(FCurrentItem);
  FreeAndNil(FItems);
  FreeAndNil(FEntries);
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

procedure THistoryManager.ClearEntries;
var
  i: integer;
begin
  for i := 0 to FEntries.Count - 1 do
    Dispose(PFileEntry(FEntries[i]));
  FEntries.Clear;
end;

procedure THistoryManager.SetMaxItems(const AValue: integer);
begin
  if FMaxItems = AValue then
    Exit;
  FMaxItems := AValue;

  // Apply the new limit immediately so the file shrinks as well
  if (FMaxItems > 0) and (FEntries.Count > FMaxItems) then
  begin
    // Release the cache before trimming: after TrimOldest FIndex moves,
    // so the cached item no longer matches FEntries[FIndex]
    FreeAndNil(FCurrentItem);
    TrimOldest;
    Compact;
    // Reset position to the newest entry, same as Load does after trimming
    if FEntries.Count > 0 then
    begin
      FIndex := FEntries.Count - 1;
      FCurrentItem := LoadEntryFromFile(FIndex);
    end
    else
      FIndex := -1;
  end;
end;

procedure THistoryManager.TrimOldest;
begin
  // Drop oldest entries until the limit is respected
  while (FMaxItems > 0) and (FEntries.Count > FMaxItems) do
  begin
    if FLoaded then
    begin
      THistoryItem(FItems[0]).Free;
      FItems.Delete(0);
    end;
    Dispose(PFileEntry(FEntries[0]));
    FEntries.Delete(0);
    if FIndex > 0 then
      Dec(FIndex);
  end;
end;

procedure THistoryManager.WriteString(AStream: TStream; const AValue: string);
var
  Len: cardinal = 0;
begin
  // AValue is string in $codepage utf8 mode, i.e. already UTF-8; store raw
  Len := Length(AValue);
  AStream.WriteBuffer(Len, SizeOf(Len));
  if Len > 0 then
    AStream.WriteBuffer(AValue[1], Len);
end;

function THistoryManager.ReadString(AStream: TStream): string;
var
  Len: cardinal = 0;
begin
  AStream.ReadBuffer(Len, SizeOf(Len));
  if Len > MAX_STRING_BYTES then
    raise Exception.Create('History entry is corrupted');
  if Len = 0 then
    Exit('');
  SetLength(Result, Len);
  AStream.ReadBuffer(Result[1], Len);
end;

function THistoryManager.LoadEntryFromStream(AStream: TStream; AEntry: PFileEntry): THistoryItem;
var
  CompressedBuf: TMemoryStream;
  RawBuf: TMemoryStream;
  Ts: double = 0;
begin
  Result := nil;
  if (AStream = nil) or (AEntry = nil) then
    Exit;

  AStream.Position := AEntry^.Offset;
  CompressedBuf := TMemoryStream.Create;
  try
    CompressedBuf.SetSize(AEntry^.PayloadLen);
    if AEntry^.PayloadLen > 0 then
      AStream.ReadBuffer(CompressedBuf.Memory^, AEntry^.PayloadLen);
    CompressedBuf.Position := 0;
    RawBuf := TOS.DecompressMemoryStream(CompressedBuf);
  finally
    CompressedBuf.Free;
  end;

  try
    Result := THistoryItem.Create;
    try
      Result.SourceText := ReadString(RawBuf);
      Result.TargetText := ReadString(RawBuf);
      Result.SourceLang := ReadString(RawBuf);
      Result.TargetLang := ReadString(RawBuf);
      Result.ConfigFile := ReadString(RawBuf);
      RawBuf.ReadBuffer(Ts, SizeOf(Ts));
      Result.Timestamp := Ts;
    except
      Result.Free;
      raise;
    end;
  finally
    RawBuf.Free;
  end;
end;

function THistoryManager.LoadEntryFromFile(AIndex: integer): THistoryItem;
var
  FileStream: TFileStream;
begin
  Result := nil;
  if (AIndex < 0) or (AIndex >= FEntries.Count) then
    Exit;
  if not FileExists(FFileName) then
    Exit;

  try
    FileStream := TFileStream.Create(FFileName, fmOpenRead or fmShareDenyNone);
    try
      Result := LoadEntryFromStream(FileStream, PFileEntry(FEntries[AIndex]));
    finally
      FileStream.Free;
    end;
  except
    Result := nil;
  end;
end;

procedure THistoryManager.Load;
var
  FileStream: TFileStream;
  Header: array[0..HISTORY_HEADER_SIZE - 1] of byte = (0, 0, 0, 0, 0, 0, 0, 0);
  RecType: byte = 0;
  PayloadLen: uint32 = 0;
  EntryOffset: int64 = 0;
  Entry: PFileEntry;
  Ver: word = 0;
  Clean: boolean;
begin
  ClearItems;
  ClearEntries;
  FreeAndNil(FCurrentItem);
  FLoaded := False;
  FIndex := -1;
  FFileEntryCount := 0;

  if not FileExists(FFileName) then
  begin
    FNeedsRebuild := False;
    Exit;
  end;

  FNeedsRebuild := True;

  try
    try
      FileStream := TFileStream.Create(FFileName, fmOpenRead or fmShareDenyNone);
      try
        if FileStream.Size < HISTORY_HEADER_SIZE then
          Exit;

        FileStream.ReadBuffer(Header, HISTORY_HEADER_SIZE);
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
          EntryOffset := FileStream.Position;
          if EntryOffset + PayloadLen > FileStream.Size then
          begin
            Clean := False;
            Break;
          end;

          if RecType = REC_ADD then
          begin
            New(Entry);
            Entry^.Offset := EntryOffset;
            Entry^.PayloadLen := PayloadLen;
            FEntries.Add(Entry);
          end;

          FileStream.Position := EntryOffset + PayloadLen;
        end;

        if Clean then
          FNeedsRebuild := False;
      finally
        FileStream.Free;
      end;

      FFileEntryCount := FEntries.Count;

      // Enforce memory cap; compact drops orphans from the file too
      if (FMaxItems > 0) and (FEntries.Count > FMaxItems) then
      begin
        TrimOldest;
        Compact;
      end;

      // Position at the last entry and prime the lazy cache
      if FEntries.Count > 0 then
      begin
        FIndex := FEntries.Count - 1;
        FCurrentItem := LoadEntryFromFile(FIndex);
      end;
    except
      ClearItems;
      ClearEntries;
      FreeAndNil(FCurrentItem);
      FFileEntryCount := 0;
      FIndex := -1;
    end;
  finally
    if FEntries.Count = 0 then
      FIndex := -1;
  end;
end;

procedure THistoryManager.LoadFull;
begin
  EnsureLoaded;
end;

procedure THistoryManager.EnsureLoaded;
var
  FileStream: TFileStream;
  i: integer;
  Item: THistoryItem;
begin
  if FLoaded then
    Exit;
  if FEntries.Count = 0 then
  begin
    FreeAndNil(FCurrentItem);
    FLoaded := True;
    Exit;
  end;

  ClearItems;
  try
    FileStream := TFileStream.Create(FFileName, fmOpenRead or fmShareDenyNone);
    try
      for i := 0 to FEntries.Count - 1 do
      begin
        Item := LoadEntryFromStream(FileStream, PFileEntry(FEntries[i]));
        if Item <> nil then
          FItems.Add(Item);
      end;
    finally
      FileStream.Free;
    end;
    FreeAndNil(FCurrentItem);
    FLoaded := True;
  except
    ClearItems;
    FLoaded := False;
    raise;
  end;
end;

procedure THistoryManager.Unload;
begin
  if not FLoaded then
    Exit;
  ClearItems;
  FLoaded := False;
  FreeAndNil(FCurrentItem);
  if (FIndex >= 0) and (FIndex < FEntries.Count) then
    FCurrentItem := LoadEntryFromFile(FIndex);
end;

procedure THistoryManager.AppendEntryToFile(AItem: THistoryItem; AEntry: PFileEntry);
var
  FileStream: TFileStream = nil;
  CompressedBuf: TMemoryStream = nil;
  RawBuf: TMemoryStream = nil;
  RecType: byte;
  PayloadLen: uint32;
  Ver: word;
  Reserved: word;
  Ts: double;
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
    ForceDirectories(ExtractFileDir(FFileName));

    if FileExists(FFileName) then
      FileStream := TFileStream.Create(FFileName, fmOpenReadWrite or fmShareDenyNone)
    else
      FileStream := TFileStream.Create(FFileName, fmCreate);

    try
      if FileStream.Size = 0 then
      begin
        FileStream.WriteBuffer(HISTORY_MAGIC, SizeOf(HISTORY_MAGIC));
        Ver := HISTORY_VERSION;
        FileStream.WriteBuffer(Ver, SizeOf(Ver));
        Reserved := 0;
        FileStream.WriteBuffer(Reserved, SizeOf(Reserved));
      end;

      FileStream.Position := FileStream.Size;
      RecType := REC_ADD;
      FileStream.WriteBuffer(RecType, SizeOf(RecType));
      PayloadLen := CompressedBuf.Size;
      FileStream.WriteBuffer(PayloadLen, SizeOf(PayloadLen));

      if AEntry <> nil then
      begin
        AEntry^.Offset := FileStream.Position;
        AEntry^.PayloadLen := PayloadLen;
      end;

      CompressedBuf.Position := 0;
      if CompressedBuf.Size > 0 then
        FileStream.CopyFrom(CompressedBuf, CompressedBuf.Size);
    finally
      FreeAndNil(FileStream);
    end;
  except
    // Append failure: mark for rebuild so the next access regenerates the file
    FNeedsRebuild := True;
  end;

  FreeAndNil(CompressedBuf);
end;

procedure THistoryManager.Compact;
var
  TmpFileName: string;
  OutStream: TFileStream = nil;
  InStream: TFileStream = nil;
  Item: THistoryItem;
  OwnItem: boolean;
  i: integer;
  RecType: byte;
  PayloadLen: uint32;
  RawBuf: TMemoryStream;
  CompressedBuf: TMemoryStream;
  Ts: double;
  Ver: word;
  Reserved: word;
  Offset: int64;
begin
  if FFileName = '' then
    Exit;

  ForceDirectories(ExtractFileDir(FFileName));
  TmpFileName := FFileName + '.tmp';

  try
    OutStream := TFileStream.Create(TmpFileName, fmCreate);
    try
      // Header
      OutStream.WriteBuffer(HISTORY_MAGIC, SizeOf(HISTORY_MAGIC));
      Ver := HISTORY_VERSION;
      OutStream.WriteBuffer(Ver, SizeOf(Ver));
      Reserved := 0;
      OutStream.WriteBuffer(Reserved, SizeOf(Reserved));

      // Single input handle for lazy mode; one entry decompressed at a time
      if (not FLoaded) and (FEntries.Count > 0) then
        InStream := TFileStream.Create(FFileName, fmOpenRead or fmShareDenyNone);

      Offset := HISTORY_HEADER_SIZE;
      for i := 0 to FEntries.Count - 1 do
      begin
        if FLoaded then
        begin
          Item := THistoryItem(FItems[i]);
          OwnItem := False;
        end
        else if (i = FIndex) and (FCurrentItem <> nil) then
        begin
          Item := FCurrentItem;
          OwnItem := False;
        end
        else
        begin
          Item := LoadEntryFromStream(InStream, PFileEntry(FEntries[i]));
          OwnItem := True;
        end;

        try
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
            OutStream.WriteBuffer(RecType, SizeOf(RecType));
            PayloadLen := CompressedBuf.Size;
            OutStream.WriteBuffer(PayloadLen, SizeOf(PayloadLen));
            PFileEntry(FEntries[i])^.Offset := OutStream.Position;
            PFileEntry(FEntries[i])^.PayloadLen := PayloadLen;
            CompressedBuf.Position := 0;
            if CompressedBuf.Size > 0 then
              OutStream.CopyFrom(CompressedBuf, CompressedBuf.Size);
            Inc(Offset, 5 + int64(PayloadLen));
          finally
            FreeAndNil(CompressedBuf);
          end;
        finally
          if OwnItem then
            Item.Free;
        end;
      end;
    finally
      FreeAndNil(InStream);
      FreeAndNil(OutStream);
    end;

    // Replace the old file atomically
    if FileExists(FFileName) then
      DeleteFile(FFileName);
    if not RenameFile(TmpFileName, FFileName) then
      DeleteFile(TmpFileName);

    FFileEntryCount := FEntries.Count;
    FNeedsRebuild := False;
  except
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
  NewEntry: PFileEntry;
begin
  if AItem = nil then
    Exit;

  Truncated := (FIndex >= 0) and (FIndex < FEntries.Count - 1);

  if Truncated then
  begin
    // Drop the forward branch from the index and from the loaded list
    while FEntries.Count > FIndex + 1 do
    begin
      Dispose(PFileEntry(FEntries[FEntries.Count - 1]));
      FEntries.Delete(FEntries.Count - 1);
    end;
    if FLoaded then
      while FItems.Count > FIndex + 1 do
      begin
        THistoryItem(FItems[FItems.Count - 1]).Free;
        FItems.Delete(FItems.Count - 1);
      end;
  end;

  FreeAndNil(FCurrentItem);
  if FLoaded then
    FItems.Add(AItem)
  else
    FCurrentItem := AItem;
  Inc(FIndex);

  New(NewEntry);
  NewEntry^.Offset := 0;
  NewEntry^.PayloadLen := 0;
  FEntries.Add(NewEntry);

  if Truncated or FNeedsRebuild then
    Compact
  else
  begin
    AppendEntryToFile(AItem, NewEntry);
    Inc(FFileEntryCount);
  end;

  if (FMaxItems > 0) and (FEntries.Count > FMaxItems) then
  begin
    TrimOldest;
    if (not Truncated) and (not FNeedsRebuild) and (FFileEntryCount > FMaxItems * 2) then
      Compact;
  end;
end;

function THistoryManager.AddText(const ASourceText, ATargetText, ASourceLang, ATargetLang, AConfigFile: string): THistoryItem;
var
  Current: THistoryItem;
  AllowTruncate: boolean;
begin
  Result := nil;
  if Trim(ASourceText) = '' then
    Exit;

  // Skip when the new entry fully matches the current item; a duplicate is
  // a no-op, so the truncate query must not fire for it
  Current := GetItem(FIndex);
  if Current <> nil then
  begin
    if Trim(Current.SourceText).EqualNormalized(Trim(ASourceText), False) and
      Trim(Current.TargetText).EqualNormalized(Trim(ATargetText), False) and SameText(Current.SourceLang, ASourceLang) and
      SameText(Current.TargetLang, ATargetLang) and SameText(Current.ConfigFile, AConfigFile) then
      Exit;
  end;

  // Ask the host before dropping forward entries after the current position
  if (FIndex >= 0) and (FIndex < FEntries.Count - 1) then
  begin
    AllowTruncate := True;
    if Assigned(FOnTruncateQuery) then
      FOnTruncateQuery(Self, AllowTruncate);
    if not AllowTruncate then
    begin
      // Jump to end without truncating; reload cache for accurate dedup
      if FLoaded then
        FIndex := FEntries.Count - 1
      else
      begin
        FreeAndNil(FCurrentItem);
        FIndex := FEntries.Count - 1;
        if FIndex >= 0 then
          FCurrentItem := LoadEntryFromFile(FIndex);
      end;

      // Re-check duplicate against the new tail we just jumped to
      Current := GetItem(FIndex);
      if Current <> nil then
      begin
        if Trim(Current.SourceText).EqualNormalized(Trim(ASourceText), False) and
          Trim(Current.TargetText).EqualNormalized(Trim(ATargetText), False) and SameText(Current.SourceLang, ASourceLang) and
          SameText(Current.TargetLang, ATargetLang) and SameText(Current.ConfigFile, AConfigFile) then
          Exit;
      end;
    end;
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
  AItem := nil;
  if not CanPrev then
    Exit(False);
  Dec(FIndex);
  if FLoaded then
    AItem := THistoryItem(FItems[FIndex])
  else
  begin
    FreeAndNil(FCurrentItem);
    FCurrentItem := LoadEntryFromFile(FIndex);
    AItem := FCurrentItem;
  end;
  Result := True;
end;

function THistoryManager.Next(out AItem: THistoryItem): boolean;
begin
  AItem := nil;
  if not CanNext then
    Exit(False);
  Inc(FIndex);
  if FLoaded then
    AItem := THistoryItem(FItems[FIndex])
  else
  begin
    FreeAndNil(FCurrentItem);
    FCurrentItem := LoadEntryFromFile(FIndex);
    AItem := FCurrentItem;
  end;
  Result := True;
end;

function THistoryManager.First(out AItem: THistoryItem): boolean;
begin
  AItem := nil;
  if FEntries.Count = 0 then
    Exit(False);
  FIndex := 0;
  if FLoaded then
    AItem := THistoryItem(FItems[FIndex])
  else
  begin
    FreeAndNil(FCurrentItem);
    FCurrentItem := LoadEntryFromFile(FIndex);
    AItem := FCurrentItem;
  end;
  Result := True;
end;

function THistoryManager.Last(out AItem: THistoryItem): boolean;
begin
  AItem := nil;
  if FEntries.Count = 0 then
    Exit(False);
  FIndex := FEntries.Count - 1;
  if FLoaded then
    AItem := THistoryItem(FItems[FIndex])
  else
  begin
    FreeAndNil(FCurrentItem);
    FCurrentItem := LoadEntryFromFile(FIndex);
    AItem := FCurrentItem;
  end;
  Result := True;
end;

function THistoryManager.Select(AIndex: integer; out AItem: THistoryItem): boolean;
begin
  AItem := nil;
  if (AIndex < 0) or (AIndex >= FEntries.Count) then
    Exit(False);
  FIndex := AIndex;
  if FLoaded then
    AItem := THistoryItem(FItems[FIndex])
  else
  begin
    FreeAndNil(FCurrentItem);
    FCurrentItem := LoadEntryFromFile(FIndex);
    AItem := FCurrentItem;
  end;
  Result := True;
end;

function THistoryManager.Delete(AIndex: integer): boolean;
begin
  Result := False;
  if (AIndex < 0) or (AIndex >= FEntries.Count) then
    Exit;

  if FLoaded then
  begin
    THistoryItem(FItems[AIndex]).Free;
    FItems.Delete(AIndex);
  end;
  Dispose(PFileEntry(FEntries[AIndex]));
  FEntries.Delete(AIndex);

  if FEntries.Count = 0 then
    FIndex := -1
  else if AIndex < FIndex then
    Dec(FIndex)
  else if (AIndex = FIndex) and (FIndex >= FEntries.Count) then
    FIndex := FEntries.Count - 1;

  // Drop the cached entry first: the deleted item may still be referenced
  // there, and Compact must read the new FIndex entry from disk instead
  FreeAndNil(FCurrentItem);

  // Delete is rare; rewrite the file from the current state
  Compact;

  if FIndex >= 0 then
    FCurrentItem := LoadEntryFromFile(FIndex);

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
  Result := (FIndex >= 0) and (FIndex < FEntries.Count - 1);
end;

function THistoryManager.GetItem(AIndex: integer): THistoryItem;
begin
  if (AIndex < 0) or (AIndex >= FEntries.Count) then
    Exit(nil);

  if FLoaded then
    Exit(THistoryItem(FItems[AIndex]));

  if (AIndex = FIndex) and (FCurrentItem <> nil) then
    Exit(FCurrentItem);

  Result := LoadEntryFromFile(AIndex);
end;

function THistoryManager.Find(const AFilter: string; const ADateFrom: TDateTime = 0; const ADateTo: TDateTime = 0;
  ALangResolver: TLangDisplayResolver = nil): TIntegerArray;
var
  FilterLower: string;
  HasFilter, HasFrom, HasTo: boolean;
  i, MatchCount: integer;
  Item: THistoryItem;
  Match: boolean;
  SourceDisplay, TargetDisplay: string;
  DateStr, DateStrIso: string;
begin
  Result := nil;
  SetLength(Result, 0);

  // Find works on the fully loaded list; auto-load for caller convenience
  EnsureLoaded;
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

    if HasFrom and (Item.Timestamp < ADateFrom) then
      Match := False;
    if Match and HasTo and (Item.Timestamp >= ADateTo) then
      Match := False;

    if Match and HasFilter then
    begin
      // Try raw fields first, including language codes like "en"
      Match := (Pos(FilterLower, UTF8LowerCase(Item.SourceText)) > 0) or (Pos(FilterLower, UTF8LowerCase(Item.TargetText)) > 0) or
        (Pos(FilterLower, UTF8LowerCase(Item.SourceLang)) > 0) or (Pos(FilterLower, UTF8LowerCase(Item.TargetLang)) > 0) or
        (Pos(FilterLower, UTF8LowerCase(Item.ConfigFile)) > 0);

      // Date is stored as TDateTime; match against the display form used by
      // the UI plus the ISO form so both "05.11.2025" and "2025-11-05" work
      if not Match then
      begin
        DateStr := DateTimeToStr(Item.Timestamp);
        DateStrIso := FormatDateTime('yyyy-mm-dd hh:nn', Item.Timestamp);
        Match := (Pos(FilterLower, UTF8LowerCase(DateStr)) > 0) or (Pos(FilterLower, UTF8LowerCase(DateStrIso)) > 0);
      end;

      // Fall back to display names so "English" matches code "en"
      if (not Match) and Assigned(ALangResolver) then
      begin
        SourceDisplay := ALangResolver(Item.SourceLang);
        TargetDisplay := ALangResolver(Item.TargetLang);
        Match := (Pos(FilterLower, UTF8LowerCase(SourceDisplay)) > 0) or (Pos(FilterLower, UTF8LowerCase(TargetDisplay)) > 0);
      end;
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
  Result := nil;
  Result := Find('', ADateFrom, ADateTo);
end;

function THistoryManager.GetCount: integer;
begin
  Result := FEntries.Count;
end;

function THistoryManager.GetLoaded: boolean;
begin
  Result := FLoaded;
end;

procedure THistoryManager.Clear;
begin
  ClearItems;
  ClearEntries;
  FreeAndNil(FCurrentItem);
  FIndex := -1;
  FLoaded := False;
  FFileEntryCount := 0;
  Compact;
end;

end.
