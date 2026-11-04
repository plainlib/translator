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

  // Holds the translation history and the current navigation position
  THistoryManager = class
  private
    FItems: TList;
    FIndex: integer;
    FMaxItems: integer;
    FFileName: string;
    procedure ClearItems;
    procedure TrimOldest;
    procedure WriteString(AStream: TStream; const AValue: string);
    function ReadString(AStream: TStream): string;
    function GetCount: integer;
  public
    constructor Create(const AFileName: string; AMaxItems: integer = 100);
    destructor Destroy; override;
    procedure Load;
    procedure Save;
    procedure Add(AItem: THistoryItem);
    function AddText(const ASourceText, ATargetText, ASourceLang, ATargetLang, AConfigFile: string): THistoryItem;
    function Prev(out AItem: THistoryItem): boolean;
    function Next(out AItem: THistoryItem): boolean;
    function First(out AItem: THistoryItem): boolean;
    function Last(out AItem: THistoryItem): boolean;
    function Delete(AIndex: integer): boolean;
    function DeleteCurrent: boolean;
    function CanPrev: boolean;
    function CanNext: boolean;
    function GetItem(AIndex: integer): THistoryItem;
    procedure Clear;
    property Index: integer read FIndex;
    property Count: integer read GetCount;
    property MaxItems: integer read FMaxItems write FMaxItems;
    property FileName: string read FFileName write FFileName;
  end;

implementation

uses
  Math,
  OSUtils;

const
  HISTORY_MAGIC: array[0..3] of byte = (Ord('T'), Ord('L'), Ord('H'), Ord('1'));
  HISTORY_VERSION = 1;
  MAX_HISTORY_ITEMS = 10000;
  MAX_STRING_BYTES = 16 * 1024 * 1024;

constructor THistoryManager.Create(const AFileName: string; AMaxItems: integer = 100);
begin
  inherited Create;
  FItems := TList.Create;
  FIndex := -1;
  FMaxItems := AMaxItems;
  FFileName := AFileName;
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
  // Drop the oldest entries and keep the index inside the new range
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
    raise Exception.Create('History file is corrupted');
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
  RawStream: TMemoryStream = nil;
  CompressedStream: TMemoryStream = nil;
  FileStream: TFileStream = nil;
  Magic: array[0..3] of byte;
  Version: word;
  ItemCount: cardinal;
  CurIndex: integer;
  i: integer;
  Item: THistoryItem;
  Ts: double;
begin
  ClearItems;
  FIndex := -1;

  if not FileExists(FFileName) then
    Exit;

  try
    try
      FileStream := TFileStream.Create(FFileName, fmOpenRead or fmShareDenyNone);
      try
        CompressedStream := TMemoryStream.Create;
        CompressedStream.CopyFrom(FileStream, 0);
      finally
        FileStream.Free;
      end;

      if CompressedStream.Size = 0 then
        Exit;

      CompressedStream.Position := 0;
      RawStream := TOS.DecompressMemoryStream(CompressedStream);

      if RawStream.Size < SizeOf(Magic) + SizeOf(Version) + SizeOf(ItemCount) + SizeOf(CurIndex) then
        Exit;

      RawStream.ReadBuffer(Magic, SizeOf(Magic));
      if (Magic[0] <> HISTORY_MAGIC[0]) or (Magic[1] <> HISTORY_MAGIC[1]) or (Magic[2] <> HISTORY_MAGIC[2]) or
        (Magic[3] <> HISTORY_MAGIC[3]) then
        Exit;

      RawStream.ReadBuffer(Version, SizeOf(Version));
      if Version <> HISTORY_VERSION then
        Exit;

      RawStream.ReadBuffer(ItemCount, SizeOf(ItemCount));
      if ItemCount > MAX_HISTORY_ITEMS then
        Exit;

      RawStream.ReadBuffer(CurIndex, SizeOf(CurIndex));

      for i := 0 to ItemCount - 1 do
      begin
        Item := THistoryItem.Create;
        try
          Item.SourceText := ReadString(RawStream);
          Item.TargetText := ReadString(RawStream);
          Item.SourceLang := ReadString(RawStream);
          Item.TargetLang := ReadString(RawStream);
          Item.ConfigFile := ReadString(RawStream);
          RawStream.ReadBuffer(Ts, SizeOf(Ts));
          Item.Timestamp := Ts;
        except
          Item.Free;
          raise;
        end;
        FItems.Add(Item);
      end;

      if FItems.Count = 0 then
        FIndex := -1
      else
        FIndex := EnsureRange(CurIndex, 0, FItems.Count - 1);
    except
      // Any read error means an unreadable file; start with empty history
      ClearItems;
      FIndex := -1;
    end;
  finally
    RawStream.Free;
    CompressedStream.Free;
  end;
end;

procedure THistoryManager.Save;
var
  RawStream: TMemoryStream = nil;
  CompressedStream: TMemoryStream = nil;
  FileStream: TFileStream = nil;
  i: integer;
  Item: THistoryItem;
  ItemCount: cardinal;
  CurIndex: integer;
  Version: word;
  Ts: double;
  Dir: string;
begin
  if FFileName = '' then
    Exit;

  Dir := ExtractFileDir(FFileName);
  if Dir <> '' then
    ForceDirectories(Dir);

  try
    RawStream := TMemoryStream.Create;
    try
      RawStream.WriteBuffer(HISTORY_MAGIC, SizeOf(HISTORY_MAGIC));
      Version := HISTORY_VERSION;
      RawStream.WriteBuffer(Version, SizeOf(Version));
      ItemCount := FItems.Count;
      RawStream.WriteBuffer(ItemCount, SizeOf(ItemCount));
      CurIndex := FIndex;
      RawStream.WriteBuffer(CurIndex, SizeOf(CurIndex));

      for i := 0 to FItems.Count - 1 do
      begin
        Item := THistoryItem(FItems[i]);
        WriteString(RawStream, Item.SourceText);
        WriteString(RawStream, Item.TargetText);
        WriteString(RawStream, Item.SourceLang);
        WriteString(RawStream, Item.TargetLang);
        WriteString(RawStream, Item.ConfigFile);
        Ts := Item.Timestamp;
        RawStream.WriteBuffer(Ts, SizeOf(Ts));
      end;

      RawStream.Position := 0;
      CompressedStream := TOS.CompressMemoryStream(RawStream);
    finally
      RawStream.Free;
    end;

    FileStream := TFileStream.Create(FFileName, fmCreate);
    try
      FileStream.CopyFrom(CompressedStream, 0);
    finally
      FileStream.Free;
    end;
  except
    // History is not critical; a failed save must not break the app
  end;
  CompressedStream.Free;
end;

procedure THistoryManager.Add(AItem: THistoryItem);
var
  i: integer;
begin
  if AItem = nil then
    Exit;

  // Truncate the forward branch when not at the last item
  if (FIndex >= 0) and (FIndex < FItems.Count - 1) then
  begin
    for i := FItems.Count - 1 downto FIndex + 1 do
    begin
      THistoryItem(FItems[i]).Free;
      FItems.Delete(i);
    end;
  end;

  FItems.Add(AItem);
  FIndex := FItems.Count - 1;
  TrimOldest;
  Save;
end;

function THistoryManager.AddText(const ASourceText, ATargetText, ASourceLang, ATargetLang, AConfigFile: string): THistoryItem;
var
  Current: THistoryItem;
begin
  Result := nil;
  if Trim(ASourceText) = '' then
    Exit;

  // Skip duplicates of the current item
  if (FIndex >= 0) and (FIndex < FItems.Count) then
  begin
    Current := THistoryItem(FItems[FIndex]);
    if SameText(Current.SourceText, ASourceText) and SameText(Current.TargetText, ATargetText) and
      SameText(Current.SourceLang, ASourceLang) and SameText(Current.TargetLang, ATargetLang) and
      SameStr(Current.ConfigFile, AConfigFile) then
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
  AItem := nil;
  if not CanPrev then
    Exit(False);
  Dec(FIndex);
  AItem := THistoryItem(FItems[FIndex]);
  Save;
  Result := True;
end;

function THistoryManager.Next(out AItem: THistoryItem): boolean;
begin
  AItem := nil;
  if not CanNext then
    Exit(False);
  Inc(FIndex);
  AItem := THistoryItem(FItems[FIndex]);
  Save;
  Result := True;
end;

function THistoryManager.First(out AItem: THistoryItem): boolean;
begin
  AItem := nil;
  if FItems.Count = 0 then
    Exit(False);
  FIndex := 0;
  AItem := THistoryItem(FItems[FIndex]);
  Save;
  Result := True;
end;

function THistoryManager.Last(out AItem: THistoryItem): boolean;
begin
  AItem := nil;
  if FItems.Count = 0 then
    Exit(False);
  FIndex := FItems.Count - 1;
  AItem := THistoryItem(FItems[FIndex]);
  Save;
  Result := True;
end;

function THistoryManager.Delete(AIndex: integer): boolean;
begin
  Result := False;
  if (AIndex < 0) or (AIndex >= FItems.Count) then Exit;

  THistoryItem(FItems[AIndex]).Free;
  FItems.Delete(AIndex);

  // Keep the position stable: when the current entry is removed, advance to
  // the next one; when the tail is removed, clamp to the new last entry
  if FItems.Count = 0 then
    FIndex := -1
  else if AIndex < FIndex then
    Dec(FIndex)
  else if (AIndex = FIndex) and (FIndex >= FItems.Count) then
    FIndex := FItems.Count - 1;

  Save;
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

function THistoryManager.GetCount: integer;
begin
  Result := FItems.Count;
end;

procedure THistoryManager.Clear;
begin
  ClearItems;
  FIndex := -1;
  Save;
end;

end.
