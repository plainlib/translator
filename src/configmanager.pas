//-----------------------------------------------------------------------------------
//  Translator Package © 2026 by Alexander Tverskoy
//  Licensed under the MIT License
//  You may obtain a copy of the License at https://opensource.org/licenses/MIT
//-----------------------------------------------------------------------------------

unit ConfigManager;

{$mode ObjFPC}{$H+}

interface

uses
  Forms, Classes, SysUtils, Menus, Graphics, Controls, ImgList, IniFiles, ExtCtrls;

type
  // Parsed config file data used for sorting
  PConfigData = ^TConfigData;

  TConfigData = record
    Order: integer;
    PathOnly: string;
    Name: string;
    Color: TColor;
    Visible: boolean;
    ImageIndex: integer;
  end;

  // Fires before a menu item is selected; set AAllow to False to cancel
  TConfigBeforeSelectEvent = procedure(Sender: TObject; AIndex: integer; const AConfigFile: string; var AAllow: boolean) of object;

  // Fires after the selection is committed
  TConfigSelectEvent = procedure(Sender: TObject; AIndex: integer; const AConfigFile: string) of object;

  // Simple notification event used for refresh lifecycle
  TConfigNotifyEvent = procedure(Sender: TObject) of object;

  // Fires after the editor loads or saves a config file
  TConfigReloadEvent = procedure(Sender: TObject; const AConfigFile: string) of object;

  // Host provides a string value on demand
  TConfigGetStringEvent = procedure(Sender: TObject; var AValue: string) of object;

  // Manages a set of translator INI config files.
  // Scans Directories (or the exe directory plus AppName settings directory
  // when Directories is empty), builds cache lists, owns the icon image list
  // and fills an assigned TargetMenu with one item per config.
  TConfigManager = class(TComponent)
  private
    FTargetMenu: TMenuItem;
    FDirectories: TStrings;
    FAppName: string;
    FImages: TImageList;
    FImageWidth: integer;
    FImageHeight: integer;
    FConfigFiles: TStringList;
    FConfigTitles: TStringList;
    FConfigColors: TStringList;
    FConfigImages: TStringList;
    FConfigVisible: TStringList;
    FSelectedConfig: string;
    FUpdateLock: boolean;
    FLoaded: boolean;
    FAutoRefresh: boolean;
    FRefreshTimer: TTimer;
    FOnBeforeSelect: TConfigBeforeSelectEvent;
    FOnSelect: TConfigSelectEvent;
    FOnBeforeRefresh: TConfigNotifyEvent;
    FOnAfterRefresh: TConfigNotifyEvent;
    FConfigForm: TForm;
    FTranslate: TComponent;
    FHostForm: TForm;
    FConfigFormLeft: integer;
    FConfigFormTop: integer;
    FConfigFormWidth: integer;
    FConfigFormHeight: integer;
    FConfigFormSep1: integer;
    FConfigFormSep2: integer;
    FOnConfigReload: TConfigReloadEvent;
    FOnConfigsUpdated: TConfigNotifyEvent;
    FOnRefreshSettings: TConfigNotifyEvent;
    FOnConfigEditorShow: TConfigNotifyEvent;
    FOnConfigEditorHide: TConfigNotifyEvent;
    FOnGetSourceText: TConfigGetStringEvent;
    procedure SetTargetMenu(Value: TMenuItem);
    procedure SetTranslate(Value: TComponent);
    procedure SetHostForm(Value: TForm);
    procedure SetDirectories(Value: TStrings);
    procedure SetAppName(const Value: string);
    procedure SetConfig(const Value: string);
    procedure ApplySelection(AIndex: integer; const AConfigFile: string);
    procedure SetImageWidth(Value: integer);
    procedure SetImageHeight(Value: integer);
    procedure SetAutoRefresh(Value: boolean);
    procedure MenuItemClick(Sender: TObject);
    procedure DeferredRefresh;
    function DirectoriesStored: boolean;
    function GetConfigFiles: TStrings;
    function GetConfigTitles: TStrings;
    function GetConfigColors: TStrings;
    function GetConfigImages: TStrings;
  protected
    function GetConfigCount: integer;
    function GetSelectedIndex: integer;
    function GetSelectedImageIndex: integer;
    function GetConfigTitle(AIndex: integer): string;
    function GetConfigColor(AIndex: integer): TColor;
    function GetConfigImageIndex(AIndex: integer): integer;
    function GetConfigVisible(AIndex: integer): boolean;
    procedure Loaded; override;
    procedure AttachImages;
    procedure RebuildMenu;
    procedure LoadConfigs;
    procedure UpdateCheckState;
    procedure Notification(AComponent: TComponent; Operation: TOperation); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    // Rescan directories and rebuild the menu
    procedure Refresh;
    // Clear all cached data and the menu
    procedure Clear;
    // Add a single config file to the list; returns its index or -1
    function AddConfigFile(const AFileName: string): integer;
    // Remove a config file from the list; does not delete it from disk
    function RemoveConfigFile(const AFileName: string): boolean;
    // Index of a config file in ConfigFiles; -1 if not found
    function IndexOfConfig(const AFileName: string): integer;
    // Resolve a config name to full path using ConfigFiles
    function ResolveConfigPath(const AConfigName: string): string;
    // Copy the icon of a config into an external TIcon; returns True on success
    function GetConfigIcon(AIndex: integer; AIcon: TIcon): boolean;
    // Copy the icon of the selected config into an external TIcon
    function GetSelectedIcon(AIcon: TIcon): boolean;

    // Show the config editor form; create it on first call
    procedure ShowConfigEditor;
    // True when the config editor form currently exists in memory
    function ConfigEditorActive: boolean;
    // True when the config editor form is visible
    function ConfigEditorVisible: boolean;
    // Ask the editor about unsaved changes; returns True if safe to continue
    function TestConfigChanges: boolean;
    // Refresh the editor's combo of configs and field values
    procedure UpdateConfigEditor;
    // Repaint the editor after theme or visual changes
    procedure InvalidateConfigEditor;
    // Re-apply resource strings on the editor after language change
    procedure RelocalizeConfigEditor;
    // Close the editor if it is open
    procedure CloseConfigEditor;
    // Notify the host that a config was loaded or saved by the editor
    procedure NotifyConfigReload;
    // Notify the host that the set or contents of configs changed
    procedure NotifyConfigsUpdated;
    // Notify the host that the settings form config list needs refresh
    procedure NotifyRefreshSettings;
    // Ask the host for the source text used by response tests
    function GetSourceText: string;
    // Directory for new config files; settings dir when AppName is set, exe dir otherwise
    function GetConfigDirectory: string;

    // Discovery helpers, previously part of TCustomTranslate
    class function IsValidIni(const FileName: string): boolean; static;
    class procedure FindIniFiles(const Dir: string; List: TStrings); static;
    class procedure GetIniFiles(List: TStrings; AppName: string); static;
    class function ConfigSortByOrderPathName(List: TStringList; Index1, Index2: integer): integer; static;

    // Silent setter: only updates state and Checked, no OnSelect
    procedure SetSelectedConfigSilent(const Value: string);

    property ConfigFiles: TStrings read GetConfigFiles;
    property ConfigTitles: TStrings read GetConfigTitles;
    property ConfigColors: TStrings read GetConfigColors;
    property ConfigImages: TStrings read GetConfigImages;
    property Images: TImageList read FImages;
    property ConfigCount: integer read GetConfigCount;
    // Currently active config path, same value as Config
    property SelectedConfig: string read FSelectedConfig;
    property SelectedIndex: integer read GetSelectedIndex;
    property SelectedImageIndex: integer read GetSelectedImageIndex;
  published
    // Menu that receives one item per discovered config
    property TargetMenu: TMenuItem read FTargetMenu write SetTargetMenu;
    // Extra search roots; empty means exe directory plus AppName settings
    property Directories: TStrings read FDirectories write SetDirectories stored DirectoriesStored;
    // Application name used to resolve the default settings directory
    property AppName: string read FAppName write SetAppName;
    // Active config path; assigning applies the selection and fires events
    property Config: string read FSelectedConfig write SetConfig;
    // When True, a delayed scan runs right after LFM streaming is finished
    property AutoRefresh: boolean read FAutoRefresh write SetAutoRefresh default True;
    // Icon size used by the internal image list
    property ImageWidth: integer read FImageWidth write SetImageWidth default 16;
    // Icon size used by the internal image list
    property ImageHeight: integer read FImageHeight write SetImageHeight default 16;
    // Fires before selection; set AAllow to False to cancel the switch
    property OnBeforeSelect: TConfigBeforeSelectEvent read FOnBeforeSelect write FOnBeforeSelect;
    // Fires after the selection has been committed
    property OnSelect: TConfigSelectEvent read FOnSelect write FOnSelect;
    // Fires before Refresh starts scanning directories
    property OnBeforeRefresh: TConfigNotifyEvent read FOnBeforeRefresh write FOnBeforeRefresh;
    // Fires after Refresh finished and the menu has been rebuilt
    property OnAfterRefresh: TConfigNotifyEvent read FOnAfterRefresh write FOnAfterRefresh;

    // Translator component that the config editor edits
    property Translate: TComponent read FTranslate write SetTranslate;
    // Host form used for TopMost and Enabled toggling while editing
    property HostForm: TForm read FHostForm write SetHostForm;
    // Saved editor window position and size, zero means center or default
    property ConfigFormLeft: integer read FConfigFormLeft write FConfigFormLeft default 0;
    property ConfigFormTop: integer read FConfigFormTop write FConfigFormTop default 0;
    property ConfigFormWidth: integer read FConfigFormWidth write FConfigFormWidth default 0;
    property ConfigFormHeight: integer read FConfigFormHeight write FConfigFormHeight default 0;
    property ConfigFormSep1: integer read FConfigFormSep1 write FConfigFormSep1 default 0;
    property ConfigFormSep2: integer read FConfigFormSep2 write FConfigFormSep2 default 0;
    // Fires when the editor has loaded or saved a config
    property OnConfigReload: TConfigReloadEvent read FOnConfigReload write FOnConfigReload;
    // Fires when the set or contents of configs changed; refresh derived UI
    property OnConfigsUpdated: TConfigNotifyEvent read FOnConfigsUpdated write FOnConfigsUpdated;
    // Fires when the settings form config list needs refresh
    property OnRefreshSettings: TConfigNotifyEvent read FOnRefreshSettings write FOnRefreshSettings;
    // Fires right before the editor form is shown
    property OnConfigEditorShow: TConfigNotifyEvent read FOnConfigEditorShow write FOnConfigEditorShow;
    // Fires when the editor form is freed
    property OnConfigEditorHide: TConfigNotifyEvent read FOnConfigEditorHide write FOnConfigEditorHide;
    // Fires when the editor needs the source text for response tests
    property OnGetSourceText: TConfigGetStringEvent read FOnGetSourceText write FOnGetSourceText;
  end;

implementation

uses
  Base64Utils, OSUtils, OneShotTimer, Translate, FormConfig;

  { TConfigManager }

constructor TConfigManager.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FDirectories := TStringList.Create;
  FConfigFiles := TStringList.Create;
  FConfigTitles := TStringList.Create;
  FConfigColors := TStringList.Create;
  FConfigImages := TStringList.Create;
  FConfigVisible := TStringList.Create;
  FImageWidth := 16;
  FImageHeight := 16;
  FImages := TImageList.Create(Self);
  FImages.Width := FImageWidth;
  FImages.Height := FImageHeight;
  FSelectedConfig := string.Empty;
  FUpdateLock := False;
  FLoaded := False;
  FAutoRefresh := True;
  FRefreshTimer := nil;
end;

destructor TConfigManager.Destroy;
begin
  // Cancel a pending deferred refresh before tearing down
  ClearTimeout(FRefreshTimer);
  FreeAndNil(FConfigVisible);
  FreeAndNil(FConfigImages);
  FreeAndNil(FConfigColors);
  FreeAndNil(FConfigTitles);
  FreeAndNil(FConfigFiles);
  FreeAndNil(FDirectories);
  inherited Destroy;
end;

procedure TConfigManager.SetTranslate(Value: TComponent);
begin
  FTranslate := Value;
end;

procedure TConfigManager.SetHostForm(Value: TForm);
begin
  FHostForm := Value;
end;

procedure TConfigManager.ShowConfigEditor;
var
  Form: TformConfigTrayslate = nil;
begin
  if not Assigned(FTranslate) then Exit;
  if not (FTranslate is TTranslate) then Exit;

  // Bring an already created form to front
  if Assigned(FConfigForm) then
  begin
    if FConfigForm.Visible then FConfigForm.BringToFront
    else
      FConfigForm.Show;
    Exit;
  end;

  Form := TformConfigTrayslate.Create(Self, Self, TTranslate(FTranslate));
  Form.FreeNotification(Self);
  FConfigForm := Form;

  Form.Position := poDesigned;

  if ConfigFormLeft > 0 then
    Form.Left := ConfigFormLeft
  else
    Form.Position := poDesktopCenter;

  if ConfigFormTop > 0 then
    Form.Top := ConfigFormTop
  else
    Form.Position := poDesktopCenter;

  if ConfigFormWidth > 0 then
    Form.Width := ConfigFormWidth;
  if ConfigFormHeight > 0 then
    Form.Height := ConfigFormHeight;
  if ConfigFormSep1 > 0 then
    Form.GroupBoxCustomParameters.Height := ConfigFormSep1;
  if ConfigFormSep2 > 0 then
    Form.GroupResponse.Height := ConfigFormSep2;

  if Assigned(FOnConfigEditorShow) then
    FOnConfigEditorShow(Self);

  Form.Show;
  Form.BringToFront;
end;

function TConfigManager.ConfigEditorActive: boolean;
begin
  Result := Assigned(FConfigForm);
end;

function TConfigManager.ConfigEditorVisible: boolean;
begin
  Result := Assigned(FConfigForm) and FConfigForm.Visible;
end;

function TConfigManager.TestConfigChanges: boolean;
begin
  Result := True;
  if Assigned(FConfigForm) and FConfigForm.HandleAllocated and FConfigForm.Showing then
    Result := TformConfigTrayslate(FConfigForm).TestChanges;
end;

procedure TConfigManager.UpdateConfigEditor;
begin
  if not Assigned(FConfigForm) then Exit;
  if not FConfigForm.HandleAllocated then Exit;
  if not FConfigForm.Showing then Exit;

  TformConfigTrayslate(FConfigForm).UpdateConfigList;
  TformConfigTrayslate(FConfigForm).UpdateConfig;
end;

procedure TConfigManager.InvalidateConfigEditor;
begin
  if not Assigned(FConfigForm) then Exit;
  if not FConfigForm.HandleAllocated then Exit;
  if Screen.ActiveForm <> FConfigForm then Exit;

  FConfigForm.Invalidate;
end;

procedure TConfigManager.RelocalizeConfigEditor;
begin
  if Assigned(FConfigForm) and FConfigForm.HandleAllocated then
    TformConfigTrayslate(FConfigForm).Relocalize;
end;

procedure TConfigManager.CloseConfigEditor;
begin
  if Assigned(FConfigForm) then
    FConfigForm.Close;
end;

procedure TConfigManager.NotifyConfigReload;
begin
  if Assigned(FOnConfigReload) then
    FOnConfigReload(Self, FSelectedConfig);
end;

procedure TConfigManager.NotifyConfigsUpdated;
begin
  if Assigned(FOnConfigsUpdated) then
    FOnConfigsUpdated(Self);
end;

procedure TConfigManager.NotifyRefreshSettings;
begin
  if Assigned(FOnRefreshSettings) then
    FOnRefreshSettings(Self);
end;

function TConfigManager.GetSourceText: string;
begin
  Result := string.Empty;
  if Assigned(FOnGetSourceText) then
    FOnGetSourceText(Self, Result);
end;

function TConfigManager.GetConfigDirectory: string;
begin
  if FAppName <> string.Empty then
    Result := TOS.GetSettingsDirectory(FAppName, '')
  else
    Result := ExtractFilePath(ParamStr(0));
end;

procedure TConfigManager.Loaded;
begin
  inherited Loaded;
  FLoaded := True;
  // Defer the first scan past LFM streaming; only when AutoRefresh is True
  if FAutoRefresh and (not (csDesigning in ComponentState)) then
    SetTimeout(FRefreshTimer, 10, @DeferredRefresh);
end;

procedure TConfigManager.DeferredRefresh;
begin
  if not FLoaded then Exit;
  if csDesigning in ComponentState then Exit;
  if csDestroying in ComponentState then Exit;
  Refresh;
end;

procedure TConfigManager.SetTargetMenu(Value: TMenuItem);
begin
  if FTargetMenu = Value then Exit;
  if Assigned(FTargetMenu) then
    FTargetMenu.RemoveFreeNotification(Self);
  FTargetMenu := Value;
  if Assigned(FTargetMenu) then
    FTargetMenu.FreeNotification(Self);
end;

procedure TConfigManager.SetDirectories(Value: TStrings);
begin
  FDirectories.Assign(Value);
end;

procedure TConfigManager.SetAppName(const Value: string);
begin
  if FAppName = Value then Exit;
  FAppName := Value;
end;

procedure TConfigManager.SetSelectedConfigSilent(const Value: string);
begin
  if FSelectedConfig = Value then Exit;
  FSelectedConfig := Value;
  UpdateCheckState;
end;

procedure TConfigManager.SetImageWidth(Value: integer);
begin
  if FImageWidth = Value then Exit;
  FImageWidth := Value;
  if Assigned(FImages) then
    FImages.Width := Value;
end;

procedure TConfigManager.SetImageHeight(Value: integer);
begin
  if FImageHeight = Value then Exit;
  FImageHeight := Value;
  if Assigned(FImages) then
    FImages.Height := Value;
end;

procedure TConfigManager.SetAutoRefresh(Value: boolean);
begin
  if FAutoRefresh = Value then Exit;
  FAutoRefresh := Value;
  // Turning auto-refresh off also aborts a pending deferred scan
  if not FAutoRefresh then
    ClearTimeout(FRefreshTimer);
end;

function TConfigManager.DirectoriesStored: boolean;
begin
  Result := FDirectories.Count > 0;
end;

procedure TConfigManager.MenuItemClick(Sender: TObject);
var
  Item: TMenuItem;
begin
  if FUpdateLock then Exit;
  if not (Sender is TMenuItem) then Exit;

  Item := TMenuItem(Sender);
  if (Item.Tag < 0) or (Item.Tag >= FConfigFiles.Count) then Exit;

  ApplySelection(Item.Tag, FConfigFiles[Item.Tag]);
end;

procedure TConfigManager.ApplySelection(AIndex: integer; const AConfigFile: string);
var
  Allow: boolean;
begin
  Allow := True;
  if Assigned(FOnBeforeSelect) then
    FOnBeforeSelect(Self, AIndex, AConfigFile, Allow);
  if not Allow then Exit;

  FSelectedConfig := AConfigFile;
  UpdateCheckState;

  if Assigned(FOnSelect) then
    FOnSelect(Self, AIndex, AConfigFile);
end;

procedure TConfigManager.SetConfig(const Value: string);
var
  Idx: integer;
  Allow: boolean;
begin
  if FSelectedConfig = Value then Exit;

  Idx := FConfigFiles.IndexOf(Value);

  // Events fire only for a path the manager knows about; invalid paths
  // still update the state so the host can read back the last value
  Allow := True;
  if (Idx >= 0) and Assigned(FOnBeforeSelect) then
    FOnBeforeSelect(Self, Idx, Value, Allow);
  if not Allow then Exit;

  FSelectedConfig := Value;
  UpdateCheckState;

  if (Idx >= 0) and Assigned(FOnSelect) then
    FOnSelect(Self, Idx, Value);
end;

procedure TConfigManager.UpdateCheckState;
var
  i: integer;
  Idx: integer;
  ImageIdx: integer;
begin
  if not Assigned(FTargetMenu) then Exit;
  if FUpdateLock then Exit;

  FUpdateLock := True;
  try
    Idx := FConfigFiles.IndexOf(FSelectedConfig);
    for i := 0 to FTargetMenu.Count - 1 do
    begin
      FTargetMenu.Items[i].Checked := (i = Idx);
      if FTargetMenu.Items[i].Checked then
        FTargetMenu.Items[i].ImageIndex := -1
      else
      begin
        if i < FConfigImages.Count then
          ImageIdx := StrToIntDef(FConfigImages.ValueFromIndex[i], -1)
        else
          ImageIdx := -1;
        FTargetMenu.Items[i].ImageIndex := ImageIdx;
      end;
    end;
  finally
    FUpdateLock := False;
  end;
end;

procedure TConfigManager.AttachImages;
var
  Root: TMenuItem;
begin
  if not Assigned(FTargetMenu) then Exit;

  // Menu items take their Images from the root owning TMenu, walk up to it
  Root := FTargetMenu;
  while Assigned(Root.Parent) do
    Root := Root.Parent;

  if Root.Owner is TMenu then
    TMenu(Root.Owner).Images := FImages;
end;

procedure TConfigManager.RebuildMenu;
var
  i: integer;
  Item: TMenuItem;
  FileName: string;
  Title: string;
  ImageIdx: integer;
  Visible: boolean;
  Idx: integer;
begin
  if not Assigned(FTargetMenu) then Exit;

  AttachImages;

  FUpdateLock := True;
  try
    FTargetMenu.Clear;
    FTargetMenu.Visible := FConfigFiles.Count > 0;

    Idx := FConfigFiles.IndexOf(FSelectedConfig);

    for i := 0 to FConfigFiles.Count - 1 do
    begin
      FileName := ExtractFileName(FConfigFiles[i]);

      Title := FConfigTitles.ValueFromIndex[i];
      if Title = '' then
        Title := FileName;

      if i < FConfigVisible.Count then
        Visible := FConfigVisible.ValueFromIndex[i] = '1'
      else
        Visible := True;

      Item := TMenuItem.Create(FTargetMenu);
      Item.Caption := Title;
      Item.Hint := FConfigFiles[i];
      Item.Tag := i;
      Item.Visible := Visible;
      Item.Checked := (i = Idx);

      if Item.Checked then
        Item.ImageIndex := -1
      else
      begin
        ImageIdx := StrToIntDef(FConfigImages.ValueFromIndex[i], -1);
        Item.ImageIndex := ImageIdx;
      end;

      Item.OnClick := @MenuItemClick;

      FTargetMenu.Add(Item);
    end;
  finally
    FUpdateLock := False;
  end;
end;

procedure TConfigManager.LoadConfigs;
var
  Files: TStringList = nil;
  SortedList: TStringList = nil;
  i: integer = 0;
  ExeDir: string = '';
  AppDir: string = '';
  Ini: TIniFile = nil;
  Data: PConfigData = nil;
  Base64Icon: string = '';
  IconIdx: integer = -1;
begin
  Files := TStringList.Create;
  SortedList := TStringList.Create;
  try
    if FDirectories.Count > 0 then
    begin
      for i := 0 to FDirectories.Count - 1 do
        FindIniFiles(FDirectories[i], Files);
    end
    else
    begin
      ExeDir := ExtractFilePath(ParamStr(0));
      FindIniFiles(ExeDir, Files);

      if FAppName <> '' then
      begin
        AppDir := TOS.GetSettingsDirectory(FAppName, '');
        if CompareText(ExcludeTrailingPathDelimiter(ExeDir), ExcludeTrailingPathDelimiter(AppDir)) <> 0 then
          FindIniFiles(AppDir, Files);
      end;
    end;

    for i := Files.Count - 1 downto 0 do
      if Files.IndexOf(Files[i]) <> i then
        Files.Delete(i);

    for i := 0 to Files.Count - 1 do
    begin
      New(Data);
      Data^.Name := string.Empty;
      Data^.Color := clBlue;
      Data^.Visible := True;
      Data^.Order := 0;
      Data^.ImageIndex := -1;
      Data^.PathOnly := ExtractFilePath(Files[i]);

      Base64Icon := string.Empty;
      Ini := TIniFile.Create(Files[i]);
      try
        Data^.Name := Trim(Ini.ReadString('Service', 'Name', string.Empty));
        Data^.Color := Ini.ReadInteger('Service', 'ColorRecent', clBlue);
        Data^.Visible := Ini.ReadBool('Service', 'Visible', True);
        Data^.Order := Ini.ReadInteger('Service', 'Order', 0);
        Base64Icon := Ini.ReadString('Service', 'Icon', string.Empty);
      finally
        Ini.Free;
      end;

      if Base64Icon <> string.Empty then
      begin
        IconIdx := TBase64.AddBase64ToImageList(Base64Icon, FImages);
        Data^.ImageIndex := IconIdx;
      end;

      SortedList.AddObject(Files[i], TObject(Data));
    end;

    SortedList.CustomSort(@ConfigSortByOrderPathName);

    for i := 0 to SortedList.Count - 1 do
    begin
      Data := PConfigData(SortedList.Objects[i]);

      FConfigFiles.Add(SortedList[i]);
      FConfigTitles.Add(SortedList[i] + '=' + Data^.Name);
      FConfigColors.Add(SortedList[i] + '=' + IntToStr(Data^.Color));
      FConfigImages.Add(SortedList[i] + '=' + IntToStr(Data^.ImageIndex));
      if Data^.Visible then
        FConfigVisible.Add(SortedList[i] + '=1')
      else
        FConfigVisible.Add(SortedList[i] + '=0');

      Dispose(Data);
      SortedList.Objects[i] := nil;
    end;
  finally
    SortedList.Free;
    Files.Free;
  end;
end;

procedure TConfigManager.Refresh;
begin
  // Cancel a pending deferred refresh to avoid a duplicate scan
  ClearTimeout(FRefreshTimer);

  if Assigned(FOnBeforeRefresh) then
    FOnBeforeRefresh(Self);

  try
    FConfigFiles.Clear;
    FConfigTitles.Clear;
    FConfigColors.Clear;
    FConfigImages.Clear;
    FConfigVisible.Clear;
    FImages.Clear;

    LoadConfigs;
  finally
    RebuildMenu;
    if Assigned(FOnAfterRefresh) then
      FOnAfterRefresh(Self);
  end;
end;

procedure TConfigManager.Clear;
begin
  ClearTimeout(FRefreshTimer);

  FConfigFiles.Clear;
  FConfigTitles.Clear;
  FConfigColors.Clear;
  FConfigImages.Clear;
  FConfigVisible.Clear;
  FImages.Clear;
  FSelectedConfig := string.Empty;

  if Assigned(FTargetMenu) then
  begin
    FUpdateLock := True;
    try
      FTargetMenu.Clear;
      FTargetMenu.Visible := False;
    finally
      FUpdateLock := False;
    end;
  end;
end;

function TConfigManager.AddConfigFile(const AFileName: string): integer;
var
  Idx: integer = -1;
begin
  Idx := FConfigFiles.IndexOf(AFileName);
  if Idx >= 0 then
    Exit(Idx);

  if not FileExists(AFileName) then
    Exit(-1);
  if not IsValidIni(AFileName) then
    Exit(-1);

  Refresh;
  Result := FConfigFiles.IndexOf(AFileName);
end;

function TConfigManager.RemoveConfigFile(const AFileName: string): boolean;
var
  Idx: integer = -1;
begin
  Idx := FConfigFiles.IndexOf(AFileName);
  if Idx < 0 then
    Exit(False);

  FConfigFiles.Delete(Idx);
  if Idx < FConfigTitles.Count then FConfigTitles.Delete(Idx);
  if Idx < FConfigColors.Count then FConfigColors.Delete(Idx);
  if Idx < FConfigImages.Count then FConfigImages.Delete(Idx);
  if Idx < FConfigVisible.Count then FConfigVisible.Delete(Idx);

  RebuildMenu;
  Result := True;
end;

function TConfigManager.IndexOfConfig(const AFileName: string): integer;
begin
  Result := FConfigFiles.IndexOf(AFileName);
end;

function TConfigManager.ResolveConfigPath(const AConfigName: string): string;
var
  i: integer = 0;
  NameOnly: string = '';
begin
  Result := string.Empty;
  NameOnly := ExtractFileName(AConfigName);

  for i := 0 to FConfigFiles.Count - 1 do
  begin
    if SameText(ExtractFileName(FConfigFiles[i]), NameOnly) then
      Exit(FConfigFiles[i]);
  end;
end;

function TConfigManager.GetConfigIcon(AIndex: integer; AIcon: TIcon): boolean;
var
  ImageIdx: integer = -1;
begin
  Result := False;
  if not Assigned(AIcon) then Exit;
  if (AIndex < 0) or (AIndex >= FConfigImages.Count) then Exit;

  ImageIdx := StrToIntDef(FConfigImages.ValueFromIndex[AIndex], -1);
  if (ImageIdx < 0) or (ImageIdx >= FImages.Count) then Exit;

  FImages.GetIcon(ImageIdx, AIcon);
  Result := True;
end;

function TConfigManager.GetSelectedIcon(AIcon: TIcon): boolean;
begin
  Result := GetConfigIcon(SelectedIndex, AIcon);
end;

function TConfigManager.GetConfigCount: integer;
begin
  Result := FConfigFiles.Count;
end;

function TConfigManager.GetSelectedIndex: integer;
begin
  Result := FConfigFiles.IndexOf(FSelectedConfig);
end;

function TConfigManager.GetSelectedImageIndex: integer;
begin
  Result := GetConfigImageIndex(SelectedIndex);
end;

function TConfigManager.GetConfigTitle(AIndex: integer): string;
begin
  Result := string.Empty;
  if (AIndex >= 0) and (AIndex < FConfigTitles.Count) then
    Result := FConfigTitles.ValueFromIndex[AIndex];
end;

function TConfigManager.GetConfigColor(AIndex: integer): TColor;
begin
  Result := clBlue;
  if (AIndex >= 0) and (AIndex < FConfigColors.Count) then
    Result := StrToIntDef(FConfigColors.ValueFromIndex[AIndex], clBlue);
end;

function TConfigManager.GetConfigImageIndex(AIndex: integer): integer;
begin
  Result := -1;
  if (AIndex >= 0) and (AIndex < FConfigImages.Count) then
    Result := StrToIntDef(FConfigImages.ValueFromIndex[AIndex], -1);
end;

function TConfigManager.GetConfigVisible(AIndex: integer): boolean;
begin
  Result := True;
  if (AIndex >= 0) and (AIndex < FConfigVisible.Count) then
    Result := FConfigVisible.ValueFromIndex[AIndex] = '1';
end;

function TConfigManager.GetConfigFiles: TStrings;
begin
  Result := FConfigFiles;
end;

function TConfigManager.GetConfigTitles: TStrings;
begin
  Result := FConfigTitles;
end;

function TConfigManager.GetConfigColors: TStrings;
begin
  Result := FConfigColors;
end;

function TConfigManager.GetConfigImages: TStrings;
begin
  Result := FConfigImages;
end;

procedure TConfigManager.Notification(AComponent: TComponent; Operation: TOperation);
begin
  inherited Notification(AComponent, Operation);
  if Operation = opRemove then
  begin
    if AComponent = FTargetMenu then
      FTargetMenu := nil
    else if AComponent = FConfigForm then
    begin
      FConfigForm := nil;
      // Skip callback during final destruction
      if not (csDestroying in ComponentState) then
        if Assigned(FOnConfigEditorHide) then
          FOnConfigEditorHide(Self);
    end;
  end;
end;

class function TConfigManager.IsValidIni(const FileName: string): boolean;
var
  Ini: TIniFile = nil;
  Method: string = '';
begin
  Result := False;
  if not FileExists(FileName) then Exit;

  Ini := TIniFile.Create(FileName);
  try
    Method := Ini.ReadString('Request', 'Method', string.Empty);
    if ((Method = 'GET') or (Method = 'POST')) and Ini.ValueExists('Request', 'EncodeText') and
      Ini.ValueExists('Service', 'Order') then
      Result := True;
  finally
    Ini.Free;
  end;
end;

class procedure TConfigManager.FindIniFiles(const Dir: string; List: TStrings);
var
  SR: TSearchRec;
  FilePath: string = '';
begin
  if not DirectoryExists(Dir) then Exit;

  if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*.ini', faAnyFile and not faDirectory, SR) = 0 then
  begin
    repeat
      FilePath := IncludeTrailingPathDelimiter(Dir) + SR.Name;
      if IsValidIni(FilePath) then
        List.Add(FilePath);
    until FindNext(SR) <> 0;
    FindClose(SR);
  end;

  if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*', faDirectory, SR) = 0 then
  begin
    repeat
      if (SR.Name <> '.') and (SR.Name <> '..') then
      begin
        if (SR.Attr and faDirectory) <> 0 then
        begin
          FilePath := IncludeTrailingPathDelimiter(Dir) + SR.Name;
          FindIniFiles(FilePath, List);
        end;
      end;
    until FindNext(SR) <> 0;
    FindClose(SR);
  end;
end;

class procedure TConfigManager.GetIniFiles(List: TStrings; AppName: string);
var
  ExeDir: string = '';
  SettingsDir: string = '';
begin
  List.Clear;

  ExeDir := ExtractFilePath(ParamStr(0));
  FindIniFiles(ExeDir, List);

  if AppName <> string.Empty then
  begin
    SettingsDir := TOS.GetSettingsDirectory(AppName, '');
    if CompareText(ExcludeTrailingPathDelimiter(ExeDir), ExcludeTrailingPathDelimiter(SettingsDir)) <> 0 then
      FindIniFiles(SettingsDir, List);
  end;
end;

class function TConfigManager.ConfigSortByOrderPathName(List: TStringList; Index1, Index2: integer): integer;
var
  Data1, Data2: PConfigData;
  Ord1, Ord2: integer;
begin
  Data1 := PConfigData(List.Objects[Index1]);
  Data2 := PConfigData(List.Objects[Index2]);

  if Data1^.Order = 0 then
    Ord1 := MaxInt
  else
    Ord1 := Data1^.Order;

  if Data2^.Order = 0 then
    Ord2 := MaxInt
  else
    Ord2 := Data2^.Order;

  Result := Ord1 - Ord2;
  if Result = 0 then
  begin
    Result := CompareText(Data1^.PathOnly, Data2^.PathOnly);
    if Result = 0 then
      Result := CompareText(Data1^.Name, Data2^.Name);
  end;
end;

end.
