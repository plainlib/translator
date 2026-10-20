//-----------------------------------------------------------------------------------
//  Trayslate © 2026 by Alexander Tverskoy
//  Licensed under the GNU General Public License, Version 3 (GPL-3.0)
//  You may obtain a copy of the License at https://www.gnu.org/licenses/gpl-3.0.html
//-----------------------------------------------------------------------------------

unit Languages;

{$mode objfpc}{$H+}

interface

uses
  Classes,
  SysUtils,
  StrUtils,
  StdCtrls,
  Graphics,
  FPImage,
  FPReadPNG,
  LResources,
  Translate;

type
  { TAppValue }
  TAppValue = record
    Code: string;        // ISO code (ru, en, de ...)
    DisplayName: string; // Name shown in UI (English)
  end;

  TValueArray = array of TAppValue;

const
  SpecialCodes: array[0..1] of string = ('auto', 'empty');
  AutoDetect = 'Auto Detect';
  MAX_LANG_LENGTH = 15;

// Helper functions replacing the former record helper
function AppValueDisplayText(const AValue: TAppValue): string;
function ExtractCodeFromDisplayText(const ItemText: string): string;

type
  // Static class that holds all language/currency/unit data and operations
  TLanguages = class sealed
  strict private
    class procedure SortValues(var AValues: TValueArray); static;
  public
    // Data retrieval
    class function GetLanguages: TValueArray; static;
    class function GetCurrencyFiat: TValueArray; static;
    class function GetCurrencyCrypto: TValueArray; static;
    class function GetUnits: TValueArray; static;
    class function GetValues(AValueType: TLangType; ASorted: boolean = True): TValueArray; static;
    class function GetFlag(const LangCode: string): TBitmap;

    // Utility methods
    class function GetLanguageCodePairList(AValueType: TLangType; ASorted: boolean = False): TStringList;
    class function GetLanguageDisplayStrings(AValueType: TLangType): TStringList; static;
    class function GetDisplayNamesFromCodeMap(ACodeMap: TStringList; AValueType: TLangType; ASorted: boolean = False): TStringList; static;
    class function GetDisplayName(const ACode: string): string; static;
    class function GetLanguageCodeDisplayPairs(AValueType: TLangType; ASorted: boolean = False;
      AIncludeSpecial: boolean = False): TStringList; static;
    class function GetCodeArrayFromStringList(ACodeMap: TStringList): TStringArray;
    class function ExtractCodeFromItem(const ItemText: string): string; static;
    class function FindIndexByCode(const AStrings: TStrings; const ACode: string): integer; static;
    class function IsSpecialCode(const Value: string): boolean; static;
    class procedure SetComboBoxByCode(ComboBox: TComboBox; const Code: string); static;
  end;

implementation

uses StringsHelper;

  {$include languages_data.inc}
  {$include currency_data.inc}
  {$include currencycrypto_data.inc}
  {$include units_data.inc}

// Replacement for TAppValueHelper.DisplayText
function AppValueDisplayText(const AValue: TAppValue): string;
begin
  Result := Format('%s (%s)', [AValue.DisplayName, AValue.Code]);
end;

// Replacement for TAppValueHelper.ExtractCode
function ExtractCodeFromDisplayText(const ItemText: string): string;
var
  P: SizeInt;
begin
  P := RPos(' (', ItemText);
  if P > 0 then
    Result := Copy(ItemText, P + 2, Length(ItemText) - P - 2)
  else
    Result := ItemText;
end;

{%Region -fold [TLanguages - Sorting]}

class procedure TLanguages.SortValues(var AValues: TValueArray);
var
  i, j: integer;
  Temp: TAppValue;
begin
  for i := 1 to High(AValues) do
  begin
    Temp := AValues[i];
    j := i - 1;
    while (j >= 1) and (AValues[j].DisplayName > Temp.DisplayName) do
    begin
      AValues[j + 1] := AValues[j];
      Dec(j);
    end;
    AValues[j + 1] := Temp;
  end;
end;

{%EndRegion}

{%Region -fold [TLanguages - Data Retrieval]}

class function TLanguages.GetLanguages: TValueArray;
var
  i: integer;
begin
  Result := [];
  SetLength(Result, Length(Languages_Data));
  for i := 0 to High(Languages_Data) do
    Result[i] := Languages_Data[i];
end;

class function TLanguages.GetCurrencyFiat: TValueArray;
var
  i: integer;
begin
  Result := [];
  SetLength(Result, Length(Currency_Data));
  for i := 0 to High(Currency_Data) do
    Result[i] := Currency_Data[i];
end;

class function TLanguages.GetCurrencyCrypto: TValueArray;
var
  i: integer;
begin
  Result := [];
  SetLength(Result, Length(CurrencyCrypto_Data));
  for i := 0 to High(CurrencyCrypto_Data) do
    Result[i] := CurrencyCrypto_Data[i];
end;

class function TLanguages.GetUnits: TValueArray;
var
  i: integer;
begin
  Result := [];
  SetLength(Result, Length(Units_Data));
  for i := 0 to High(Units_Data) do
    Result[i] := Units_Data[i];
end;

class function TLanguages.GetValues(AValueType: TLangType; ASorted: boolean): TValueArray;
var
  i: integer;
  Fiat, Crypto: TValueArray;
begin
  Result := [];
  case AValueType of
    vtNone: ;
    vtLanguage: Result := GetLanguages;
    vtCurrencyAll:
    begin
      Fiat := GetCurrencyFiat;
      Crypto := GetCurrencyCrypto;
      SetLength(Result, Length(Fiat) + Length(Crypto));
      for i := 0 to High(Fiat) do
        Result[i] := Fiat[i];
      for i := 0 to High(Crypto) do
        Result[Length(Fiat) + i] := Crypto[i];
    end;
    vtCurrencyFiat: Result := GetCurrencyFiat;
    vtCurrencyCrypto: Result := GetCurrencyCrypto;
    vtUnit: Result := GetUnits;
    else
      SetLength(Result, 0);
  end;

  if ASorted then
    SortValues(Result);
end;

class function TLanguages.GetFlag(const LangCode: string): TBitmap;
var
  Res: TLResource;
  Stream: TMemoryStream;
  Pic: TPicture;
  ResName: string;
begin
  Result := nil;

  // Build resource name from language code
  ResName := 'flag-' + LangCode;

  // Find resource in the compiled LRS data
  Res := LazarusResources.Find(ResName);
  if Res = nil then
    Exit;

  Stream := TMemoryStream.Create;
  try
    // Copy binary data from resource string to stream
    if Length(Res.Value) > 0 then
      Stream.WriteBuffer(Res.Value[1], Length(Res.Value));

    Stream.Position := 0;

    // Use TPicture to auto-detect image format
    Pic := TPicture.Create;
    try
      Pic.LoadFromStream(Stream);
      Result := TBitmap.Create;
      Result.Assign(Pic.Bitmap);
    finally
      Pic.Free;
    end;
  finally
    Stream.Free;
  end;
end;

{%EndRegion}

{%Region -fold [TLanguages - Utility Methods]}

class function TLanguages.GetLanguageCodePairList(AValueType: TLangType; ASorted: boolean = False): TStringList;
var
  Langs: TValueArray;
  i: integer;
begin
  Result := TStringList.Create;
  Result.TrailingLineBreak := False;
  try
    Langs := GetValues(AValueType);
    for i := 0 to High(Langs) do
      Result.Add(Langs[i].Code + '=' + Langs[i].Code);
    if ASorted then
      Result.Sort;
  except
    Result.Free;
    raise;
  end;
end;

class function TLanguages.GetLanguageDisplayStrings(AValueType: TLangType): TStringList;
var
  Langs: TValueArray;
  L: TAppValue;
begin
  Result := TStringList.Create;
  Langs := GetValues(AValueType);
  for L in Langs do
    Result.Add(L.DisplayName + ' (' + L.Code + ')');
end;

class function TLanguages.GetDisplayNamesFromCodeMap(ACodeMap: TStringList; AValueType: TLangType; ASorted: boolean): TStringList;
var
  Langs: TValueArray;
  LangMap: TStringList;
  i, j, idx: integer;
  Key, ApiValue, DisplayString: string;
  SpecialsList, OthersList: TStringList;
  IsSpecial: boolean;
  CaseSensitiveSearch: boolean;
begin
  Result := TStringList.Create;
  try
    Langs := GetValues(AValueType);
    LangMap := TStringList.Create;
    try
      CaseSensitiveSearch := AValueType in [vtUnit, vtNone];
      LangMap.CaseSensitive := CaseSensitiveSearch;

      for i := 0 to High(Langs) do
        LangMap.Add(Langs[i].Code + '=' + Langs[i].DisplayName);

      SpecialsList := TStringList.Create;
      OthersList := TStringList.Create;
      try
        for i := 0 to ACodeMap.Count - 1 do
        begin
          if Trim(ACodeMap[i]) = string.Empty then
            Continue;

          Key := Trim(ACodeMap.Names[i]);
          ApiValue := Trim(ACodeMap.ValueFromIndex[i]);

          if (Key = string.Empty) or (ApiValue = string.Empty) then
            Continue;

          if CaseSensitiveSearch then
            idx := LangMap.IndexOfName(Key)
          else
            idx := LangMap.IndexOfNameIgnoreCase(Key);

          if idx >= 0 then
            DisplayString := LangMap.ValueFromIndex[idx] + ' (' + ApiValue + ')'
          else
            DisplayString := Key;

          IsSpecial := False;
          for j := Low(SpecialCodes) to High(SpecialCodes) do
            if SameText(Key, SpecialCodes[j]) then
            begin
              IsSpecial := True;
              Break;
            end;

          if IsSpecial then
            SpecialsList.Add(DisplayString)
          else
            OthersList.Add(DisplayString);
        end;

        if ASorted then
        begin
          SpecialsList.Sort;
          OthersList.Sort;
        end;

        Result.Assign(SpecialsList);
        Result.AddStrings(OthersList);
      finally
        SpecialsList.Free;
        OthersList.Free;
      end;
    finally
      LangMap.Free;
    end;
  except
    Result.Free;
    raise;
  end;
end;

class function TLanguages.GetDisplayName(const ACode: string): string;
var
  Langs: TValueArray;
  i: integer;
begin
  Result := '';
  Langs := GetLanguages;
  for i := 0 to High(Langs) do
    if SameText(Langs[i].Code, ACode) then
      Exit(Langs[i].DisplayName);
end;

class function TLanguages.GetLanguageCodeDisplayPairs(AValueType: TLangType; ASorted: boolean; AIncludeSpecial: boolean): TStringList;
var
  Langs: TValueArray;
  L: TAppValue;
begin
  Result := TStringList.Create;
  try
    Langs := GetValues(AValueType, ASorted);
    for L in Langs do
    begin
      if not AIncludeSpecial and IsSpecialCode(L.Code) then
        Continue;
      Result.Add(L.DisplayName + ' (' + L.Code + ')');
    end;
  except
    Result.Free;
    raise;
  end;
end;

class function TLanguages.GetCodeArrayFromStringList(ACodeMap: TStringList): TStringArray;
var
  i, Count: integer;
begin
  Result := nil;
  if ACodeMap = nil then Exit;

  SetLength(Result, ACodeMap.Count);
  Count := 0;
  for i := 0 to ACodeMap.Count - 1 do
  begin
    // Names[i] returns the substring before the first '=' character.
    // For lines without '=', Names[i] returns the whole line, which we skip.
    if (Pos('=', ACodeMap[i]) > 0) and (ACodeMap.Names[i] <> '') then
    begin
      Result[Count] := ACodeMap.Names[i];
      Inc(Count);
    end;
  end;
  SetLength(Result, Count);
end;

class function TLanguages.ExtractCodeFromItem(const ItemText: string): string;
begin
  Result := ExtractCodeFromDisplayText(ItemText);
end;

class function TLanguages.FindIndexByCode(const AStrings: TStrings; const ACode: string): integer;
var
  i: integer;
begin
  Result := -1;
  for i := 0 to AStrings.Count - 1 do
    if ExtractCodeFromItem(AStrings[i]) = ACode then
      Exit(i);
end;

class function TLanguages.IsSpecialCode(const Value: string): boolean;
var
  i: integer;
begin
  for i := Low(SpecialCodes) to High(SpecialCodes) do
    if SpecialCodes[i] = Value then
      Exit(True);
  Result := False;
end;

class procedure TLanguages.SetComboBoxByCode(ComboBox: TComboBox; const Code: string);
var
  i: integer;
begin
  for i := 0 to ComboBox.Items.Count - 1 do
  begin
    if SameText(ExtractCodeFromItem(ComboBox.Items[i]), Code) then
    begin
      ComboBox.ItemIndex := i;
      Exit;
    end;
  end;
end;

{%EndRegion}

initialization
  {$I flags.lrs}

end.
