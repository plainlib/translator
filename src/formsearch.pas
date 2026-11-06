unit FormSearch;

{$mode ObjFPC}{$H+}

interface

uses
  Classes,
  SysUtils,
  ExtCtrls,
  Forms,
  Controls,
  Graphics,
  Dialogs,
  ComCtrls,
  Buttons,
  Grids,
  StdCtrls,
  LCLType,
  LCLIntf,
  LazUTF8,
  Translate,
  TranslateHistory;

type
  // Cached per-language info used for both layout decisions and drawing
  TLangCellInfo = class
    Flag: TBitmap;
    DisplayName: string;
    // Minimum cell width needed for the side-by-side (flag + name) layout
    SideWidth: integer;
    destructor Destroy; override;
  end;

  { TFrmSearch }

  TFrmSearch = class(TForm)
    btnFilterClear: TSpeedButton;
    Filter: TEdit;
    GridSearch: TStringGrid;
    PanelFilter: TPanel;
    StatusBar: TStatusBar;
    TimerDebounce: TTimer;
    procedure btnFilterClearClick(Sender: TObject);
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormShow(Sender: TObject);
    procedure FormClose(Sender: TObject; var CloseAction: TCloseAction);
    procedure FormResize(Sender: TObject);
    procedure FormChangeBounds(Sender: TObject);
    procedure FilterChange(Sender: TObject);
    procedure FilterKeyDown(Sender: TObject; var Key: word; Shift: TShiftState);
    procedure TimerDebounceTimer(Sender: TObject);
    procedure GridSearchDblClick(Sender: TObject);
    procedure GridSearchDrawCell(Sender: TObject; aCol, aRow: integer; aRect: TRect; aState: TGridDrawState);
    procedure GridSearchPrepareCanvas(Sender: TObject; aCol, aRow: integer; aState: TGridDrawState);
  private
    // Translate component that owns this form
    FTranslate: TCustomTranslate;
    // Absolute history indices for each visible grid row
    FIndices: TIntegerArray;
    // Per-code cache of flag, display name and precomputed side width
    FLangCache: TStringList;
    // Fixed pixel metrics for the language cell layout
    FFlagWidth: integer;
    FFlagHeight: integer;
    // Minimum row height needed for the stacked (flag above name) layout
    FStackedRowHeight: integer;
    procedure ApplyFilter;
    procedure PopulateGrid;
    procedure AdjustColumnWidths;
    function GetLangCellInfo(const ACode: string): TLangCellInfo;
    function NeedsStacked(const ALangCode: string; ACellWidth: integer): boolean;
    procedure DrawLanguageCell(const ARect: TRect; const ALangCode: string);
  public
    constructor Create(AOwner: TComponent; ATranslate: TCustomTranslate); reintroduce;
    // Re-apply translation from package or custom PO and refresh UI strings
    procedure Relocalize;
  end;

resourcestring
  rsearchcaption = 'Translation History';
  rsearchhint = 'Type to search...';
  rsearchstatusnone = 'No results';
  rsearchstatusone = '1 result';
  rsearchstatusmany = '%d results';
  rsearchstatustruncated = 'Showing %d of %d results - refine the filter to narrow down';

implementation

uses DarkUtils, StringGridHelper, ColorHelper, Localize, Languages;

const
  MAX_VISIBLE_ROWS = 3000;
  MAX_ROW_HEIGHT = 240;

  {$R *.lfm}

destructor TLangCellInfo.Destroy;
begin
  // Flag owns a lazy-created Canvas with pen, brush, font and region;
  // without this override the bitmap and all of those leak on cache free
  FreeAndNil(Flag);
  inherited Destroy;
end;

constructor TFrmSearch.Create(AOwner: TComponent; ATranslate: TCustomTranslate);
begin
  FTranslate := ATranslate;
  inherited Create(AOwner);
end;

procedure TFrmSearch.FormCreate(Sender: TObject);
begin
  // Load resourcestring translations for this form's UI
  TLocalize.TranslateForm('formsearch', Self, ['FormSearch']);

  // Text that used to live in LFM is now sourced from resourcestrings
  Caption := rsearchcaption;
  Filter.TextHint := rsearchhint;

  TimerDebounce.Interval := 300;
  TimerDebounce.Enabled := False;
  SetLength(FIndices, 0);

  GridSearch.GridLineColor := TDarkUtils.ThemeColor(clLine, clLineDark);
  GridSearch.AlternateColor := TDarkUtils.ThemeColor(clLightGray, clLightGrayDark);
  GridSearch.FixedGridLineColor := TDarkUtils.ThemeColor(clLine, clLineDark);

  // LCL scales ColWidths of LFM-defined columns automatically through the
  // form's AutoAdjustLayout, so no manual base-width caching is required
  GridSearch.HandleNeeded;

  // Flag resources are 16x11; keep them unscaled to avoid blur
  FFlagWidth := 16;
  FFlagHeight := 11;

  // Stacked layout: flag + gap + text line + a bit of breathing room
  FStackedRowHeight := FFlagHeight + GridSearch.Scale96ToForm(2) + GridSearch.Canvas.TextHeight('Wg') + GridSearch.Scale96ToForm(6);

  FLangCache := TStringList.Create;
  FLangCache.OwnsObjects := True;
end;

procedure TFrmSearch.FormDestroy(Sender: TObject);
begin
  SetLength(FIndices, 0);
  FreeAndNil(FLangCache);
end;

procedure TFrmSearch.FormShow(Sender: TObject);
begin
  if not Assigned(FTranslate) then Exit;

  // Reapply translation on every show; covers the case where the form was
  // kept hidden (custom LFM without OnClose) and FormCreate did not re-run
  Relocalize;

  // Materialize the whole history for fast filtering; Translate releases it
  // again when this form closes, so the normal translator workflow stays lazy
  FTranslate.HistoryLoadFull;

  ApplyFilter;
  if Filter.CanFocus then
    Filter.SetFocus;
end;

procedure TFrmSearch.FormClose(Sender: TObject; var CloseAction: TCloseAction);
begin
  CloseAction := caFree;
end;

procedure TFrmSearch.FormResize(Sender: TObject);
begin
  if Assigned(FTranslate) then
  begin
    FTranslate.SearchPosition.Width := Width;
    FTranslate.SearchPosition.Height := Height;
  end;
  AdjustColumnWidths;
end;

procedure TFrmSearch.FormChangeBounds(Sender: TObject);
begin
  if Assigned(FTranslate) then
  begin
    FTranslate.SearchPosition.Left := Left;
    FTranslate.SearchPosition.Top := Top;
  end;
end;

procedure TFrmSearch.FilterChange(Sender: TObject);
begin
  // Restart the debounce window on every keystroke
  TimerDebounce.Enabled := False;
  TimerDebounce.Enabled := True;
end;

procedure TFrmSearch.FilterKeyDown(Sender: TObject; var Key: word; Shift: TShiftState);
begin
  // Enter applies the filter immediately, bypassing the debounce
  if Key = VK_RETURN then
  begin
    TimerDebounce.Enabled := False;
    ApplyFilter;
    Key := 0;
  end;
end;

procedure TFrmSearch.btnFilterClearClick(Sender: TObject);
begin
  Filter.Text := string.Empty;
end;

procedure TFrmSearch.TimerDebounceTimer(Sender: TObject);
begin
  TimerDebounce.Enabled := False;
  ApplyFilter;
end;

procedure TFrmSearch.ApplyFilter;
var
  AFilter: string;
begin
  if not Assigned(FTranslate) then
  begin
    SetLength(FIndices, 0);
    PopulateGrid;
    Exit;
  end;

  AFilter := Trim(Filter.Text);
  // Empty filter shows nothing until the user types something
  if AFilter = '' then
  begin
    SetLength(FIndices, 0);
    PopulateGrid;
    Exit;
  end;

  FIndices := FTranslate.HistoryFind(AFilter);
  PopulateGrid;
end;

procedure TFrmSearch.PopulateGrid;
var
  i, Shown, Total, Row: integer;
  Item: THistoryItem;
begin
  Total := Length(FIndices);
  Shown := Total;
  if Shown > MAX_VISIBLE_ROWS then
    Shown := MAX_VISIBLE_ROWS;

  GridSearch.BeginUpdate;
  try
    GridSearch.RowCount := Shown + 1;
    for i := 0 to Shown - 1 do
    begin
      Row := i + 1;
      Item := FTranslate.HistoryGetItem(FIndices[i]);
      if Item = nil then
      begin
        GridSearch.Cells[0, Row] := IntToStr(Row);
        GridSearch.Cells[1, Row] := '';
        GridSearch.Cells[2, Row] := '';
        GridSearch.Cells[3, Row] := '';
        GridSearch.Cells[4, Row] := '';
        GridSearch.Cells[5, Row] := '';
        Continue;
      end;

      GridSearch.Cells[0, Row] := IntToStr(Row);
      GridSearch.Cells[1, Row] := DateTimeToStr(Item.Timestamp);
      GridSearch.Cells[2, Row] := Item.SourceLang;
      GridSearch.Cells[3, Row] := Item.TargetLang;
      GridSearch.Cells[4, Row] := Item.SourceText;
      GridSearch.Cells[5, Row] := Item.TargetText;
    end;
  finally
    GridSearch.EndUpdate;
  end;

  // Row heights first: taller rows may add a vertical scrollbar, which
  // shrinks ClientWidth. Column widths must be recomputed after that, or
  // the sum of columns ends up wider than the visible area and the
  // horizontal scrollbar appears
  if Shown > 0 then
  begin
    GridSearch.UpdateRowHeights(True, GridSearch.Scale96ToForm(MAX_ROW_HEIGHT), '', 1);

    // Raise only rows that still fit below the stacked minimum
    for Row := 1 to Shown do
    begin
      if GridSearch.RowHeights[Row] >= FStackedRowHeight then
        Continue;
      if NeedsStacked(GridSearch.Cells[2, Row], GridSearch.ColWidths[2]) or NeedsStacked(GridSearch.Cells[3, Row],
        GridSearch.ColWidths[3]) then
        GridSearch.RowHeights[Row] := FStackedRowHeight;
    end;
  end;

  // Column widths last: ClientWidth now reflects the final scrollbar state
  AdjustColumnWidths;

  // Update StatusBar text
  if Total = 0 then
    StatusBar.Panels[0].Text := rsearchstatusnone
  else if Total > MAX_VISIBLE_ROWS then
    StatusBar.Panels[0].Text := Format(rsearchstatustruncated, [Shown, Total])
  else if Total = 1 then
    StatusBar.Panels[0].Text := rsearchstatusone
  else
    StatusBar.Panels[0].Text := Format(rsearchstatusmany, [Total]);
end;

procedure TFrmSearch.AdjustColumnWidths;
var
  Available, HalfWidth, LinesWidth: integer;
begin
  if not GridSearch.HandleAllocated then Exit;
  if GridSearch.ColCount < 6 then Exit;

  // Metadata columns (row, date, src, trg) keep whatever width LCL applied
  // for the current DPI and whatever the user resized with goColSizing;
  // only the two text columns adapt to the remaining space
  LinesWidth := GridSearch.ColCount * GridSearch.GridLineWidth;

  Available := GridSearch.ClientWidth - GridSearch.ColWidths[0] - GridSearch.ColWidths[1] - GridSearch.ColWidths[2] -
    GridSearch.ColWidths[3] - LinesWidth;

  if Available < 200 then
    Available := 200;

  HalfWidth := Available div 2;
  GridSearch.ColWidths[4] := HalfWidth;
  GridSearch.ColWidths[5] := Available - HalfWidth;
end;

procedure TFrmSearch.GridSearchPrepareCanvas(Sender: TObject; aCol, aRow: integer; aState: TGridDrawState);
begin
  if gdSelected in aState then
  begin
    // The selected cell uses the standard highlight color
    GridSearch.Canvas.Brush.Color := clHighlight;
    GridSearch.Canvas.Font.Color := clHighlightText;
  end
  else if gdRowHighlight in aState then
  begin
    // The rest of the row uses the row highlight color
    GridSearch.Canvas.Brush.Color := TDarkUtils.ThemeColor(clRowHighlight, clRowHighlightDark);
    GridSearch.Canvas.Font.Color := clWindowText;
  end;
end;

function TFrmSearch.GetLangCellInfo(const ACode: string): TLangCellInfo;
var
  Idx: integer;
  DisplayName: string;
begin
  Result := nil;
  if ACode = '' then
    Exit;

  Idx := FLangCache.IndexOf(ACode);
  if Idx >= 0 then
    Exit(TLangCellInfo(FLangCache.Objects[Idx]));

  Result := TLangCellInfo.Create;
  // Missing flag resources stay nil; layout falls back to text-only
  Result.Flag := TLanguages.GetFlag(ACode);

  // Force lazy Canvas creation at cache fill time, not during the first paint
  if Assigned(Result.Flag) then
    Result.Flag.Canvas;

  // Resolve the display name once per code, GetDisplayName is expensive
  DisplayName := TLanguages.GetDisplayName(ACode);
  if DisplayName = '' then
    DisplayName := ACode;
  Result.DisplayName := DisplayName;

  // Side-by-side layout needs flag + gap + text + right margin
  Result.SideWidth := FFlagWidth + GridSearch.Scale96ToForm(4) + GridSearch.Canvas.TextWidth(DisplayName) + GridSearch.Scale96ToForm(4);

  FLangCache.AddObject(ACode, Result);
end;

function TFrmSearch.NeedsStacked(const ALangCode: string; ACellWidth: integer): boolean;
var
  Info: TLangCellInfo;
begin
  Result := False;
  if ALangCode = '' then
    Exit;
  Info := GetLangCellInfo(ALangCode);
  Result := Assigned(Info) and Assigned(Info.Flag) and (Info.SideWidth > ACellWidth);
end;

procedure TFrmSearch.DrawLanguageCell(const ARect: TRect; const ALangCode: string);
var
  Info: TLangCellInfo;
  FlagRect, TextRect: TRect;
  FlagLeft, FlagTop, TotalH, TextH, TextTop, TextWidth, InnerWidth: integer;
  AFilter: string;
  HighlightColor: TColor;
  IsStacked: boolean;
  TxtFlags: cardinal;
begin
  Info := GetLangCellInfo(ALangCode);
  if not Assigned(Info) then
    Exit;

  TextH := GridSearch.Canvas.TextHeight(Info.DisplayName);
  AFilter := Trim(Filter.Text);
  if TDarkUtils.IsDarkMode then
    HighlightColor := clInfoDark
  else
    HighlightColor := clInfo;

  IsStacked := Assigned(Info.Flag) and (Info.SideWidth > ARect.Width);

  // Flag and text areas are computed once; text goes first, flag is painted
  // on top afterwards, which matches how DrawHighlightedText expects a clean
  // rectangle to render into
  if IsStacked then
  begin
    TotalH := FFlagHeight + GridSearch.Scale96ToForm(2) + TextH;
    FlagTop := ARect.Top + (ARect.Height - TotalH) div 2;
    FlagLeft := ARect.Left + (ARect.Width - FFlagWidth) div 2;
    FlagRect := Rect(FlagLeft, FlagTop, FlagLeft + FFlagWidth, FlagTop + FFlagHeight);

    TextTop := FlagRect.Bottom + GridSearch.Scale96ToForm(2);
    TextRect := Rect(ARect.Left + 1, TextTop, ARect.Right - 1, TextTop + TextH);
    TxtFlags := DT_CENTER;
  end
  else if Assigned(Info.Flag) then
  begin
    FlagLeft := ARect.Left + GridSearch.Scale96ToForm(2);
    FlagTop := ARect.Top + (ARect.Height - FFlagHeight) div 2;
    FlagRect := Rect(FlagLeft, FlagTop, FlagLeft + FFlagWidth, FlagTop + FFlagHeight);

    TextTop := ARect.Top + (ARect.Height - TextH) div 2;
    TextRect := Rect(FlagRect.Right + GridSearch.Scale96ToForm(4), TextTop, ARect.Right - GridSearch.Scale96ToForm(2),
      TextTop + TextH);
    TxtFlags := DT_LEFT;
  end
  else
  begin
    FlagRect := Rect(0, 0, 0, 0);
    TextTop := ARect.Top + (ARect.Height - TextH) div 2;
    TextRect := Rect(ARect.Left + GridSearch.Scale96ToForm(2), TextTop, ARect.Right - GridSearch.Scale96ToForm(2), TextTop + TextH);
    TxtFlags := DT_LEFT;
  end;

  TextWidth := GridSearch.Canvas.TextWidth(Info.DisplayName);
  InnerWidth := TextRect.Right - TextRect.Left;

  if TextWidth > InnerWidth then
  begin
    // Name does not fit: truncate with ellipsis, no highlight possible
    GridSearch.Canvas.Brush.Style := bsClear;
    DrawText(GridSearch.Canvas.Handle, PChar(Info.DisplayName), Length(Info.DisplayName),
      TextRect, TxtFlags or DT_SINGLELINE or DT_VCENTER or DT_END_ELLIPSIS or DT_NOPREFIX);
  end
  else if (AFilter <> '') and (Pos(UTF8LowerCase(AFilter), UTF8LowerCase(Info.DisplayName)) > 0) then
  begin
    // Center horizontally for the stacked case; helper left-aligns from
    // the rect's left edge, so shift the rect's left to hold the centered text
    if IsStacked then
      Inc(TextRect.Left, (InnerWidth - TextWidth) div 2);
    GridSearch.DrawHighlightedText(
      GridSearch.Canvas, TextRect,
      GridDrawColors(HighlightColor, clMaroon, clGray),
      Info.DisplayName, AFilter, '', False, False, False);
  end
  else
  begin
    // No filter match (or empty filter); DrawText handles the alignment
    GridSearch.Canvas.Brush.Style := bsClear;
    DrawText(GridSearch.Canvas.Handle, PChar(Info.DisplayName), Length(Info.DisplayName),
      TextRect, TxtFlags or DT_SINGLELINE or DT_VCENTER or DT_END_ELLIPSIS or DT_NOPREFIX);
  end;

  // Flag goes on top, in the upper strip that does not overlap the text
  if Assigned(Info.Flag) then
    GridSearch.Canvas.StretchDraw(FlagRect, Info.Flag);
end;

procedure TFrmSearch.GridSearchDrawCell(Sender: TObject; aCol, aRow: integer; aRect: TRect; aState: TGridDrawState);
var
  CellText, AFilter: string;
  HighlightColor: TColor;
begin
  // Skip the row-numbering column (0) and fixed header rows
  if (aCol < GridSearch.FixedCols) or (aRow < GridSearch.FixedRows) then
    Exit;

  // Language columns always render flag + name, regardless of filter state
  if (aCol = 2) or (aCol = 3) then
  begin
    GridSearch.Canvas.FillRect(aRect);
    DrawLanguageCell(aRect, GridSearch.Cells[aCol, aRow]);
    Exit;
  end;

  AFilter := Trim(Filter.Text);
  CellText := GridSearch.Cells[aCol, aRow];

  // Fast path: nothing to highlight and no line breaks -> default rendering
  if (AFilter = '') and (Pos(#10, CellText) = 0) and (Pos(#13, CellText) = 0) then
    Exit;

  GridSearch.Canvas.FillRect(aRect);

  if TDarkUtils.IsDarkMode then
    HighlightColor := clInfoDark
  else
    HighlightColor := clInfo;

  // Date goes through the same highlighting path as text columns, but with
  // word wrap disabled so it always stays on one line; the helper still draws
  // the value even when no match is found inside it
  GridSearch.DrawHighlightedText(
    GridSearch.Canvas,
    Rect(aRect.Left + GridSearch.Scale96ToForm(2), aRect.Top + GridSearch.Scale96ToForm(2), aRect.Right -
    GridSearch.Scale96ToForm(2), aRect.Bottom - GridSearch.Scale96ToForm(2)),
    GridDrawColors(HighlightColor, clMaroon, clGray),
    CellText,
    AFilter,
    '',
    aCol <> 1,  // word wrap for text columns only
    False,      // do not draw \n markers
    False,      // no bidi
    aCol = 1,   // vertical center: date column only
    aCol = 1    // horizontal center: date column only
    );
end;

procedure TFrmSearch.GridSearchDblClick(Sender: TObject);
var
  Row, Idx: integer;
begin
  if not Assigned(FTranslate) then
    Exit;

  Row := GridSearch.Row;
  if (Row < 1) or (Row > Length(FIndices)) then
    Exit;

  Idx := FIndices[Row - 1];
  // ActivateHistoryItem fires HistorySelect (switches config/languages/text)
  // and then OnHistoryItemActivated so the host can bring itself forward
  FTranslate.ActivateHistoryItem(Idx);
end;

procedure TFrmSearch.Relocalize;
begin
  // Re-apply translation from package or custom PO
  TLocalize.TranslateForm('formsearch', Self, ['FormSearch']);

  // Strings that live in code, not LFM
  Caption := rsearchcaption;
  Filter.TextHint := rsearchhint;

  // Status bar text is produced by PopulateGrid; refresh it in the new language
  PopulateGrid;
end;

end.
