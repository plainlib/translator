//-----------------------------------------------------------------------------------
//  Translator Package © 2026 by Alexander Tverskoy
//  Licensed under the MIT License
//  You may obtain a copy of the License at https://opensource.org/licenses/MIT
//-----------------------------------------------------------------------------------

unit ConfigManager;

{$mode ObjFPC}{$H+}

interface

uses
  Forms, Classes, SysUtils, Menus, Graphics, Controls, ImgList, IniFiles, ExtCtrls, Translate;

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

  // Fires after the editor loads or saves a config file; set AHandled when the host applied it
  TConfigReloadEvent = procedure(Sender: TObject; const AConfigFile: string; var AHandled: boolean) of object;

  // Host provides a string value on demand
  TConfigGetStringEvent = procedure(Sender: TObject; var AValue: string) of object;

  // Host signals that the editor is busy with a config load or save
  TConfigBusyEvent = procedure(Sender: TObject; ABusy: boolean) of object;

  { Nested config editor window position and size }
  TConfigFormPosition = class(TPersistent)
  private
    FLeft: integer;
    FTop: integer;
    FWidth: integer;
    FHeight: integer;
    FSep1: integer;
    FSep2: integer;
  public
    procedure Assign(Source: TPersistent); override;
  published
    // Left edge of the editor window; zero means center
    property Left: integer read FLeft write FLeft default 0;
    // Top edge of the editor window; zero means center
    property Top: integer read FTop write FTop default 0;
    // Editor window width; zero means form default
    property Width: integer read FWidth write FWidth default 0;
    // Editor window height; zero means form default
    property Height: integer read FHeight write FHeight default 0;
    // Custom parameters group height; zero means form default
    property Sep1: integer read FSep1 write FSep1 default 0;
    // Response group height; zero means form default
    property Sep2: integer read FSep2 write FSep2 default 0;
  end;

  // Base class with logic and API; use TConfigManager in applications
  TCustomConfigManager = class(TComponent)
  private
    FTargetMenu: TMenuItem;
    FDirectories: TStrings;
    FAppName: string;
    FImages: TImageList;
    FConfigFiles: TStringList;
    FConfigTitles: TStringList;
    FConfigColors: TStringList;
    FConfigImages: TStringList;
    FConfigVisible: TStringList;
    FSelectedConfig: string;
    FUpdateLock: boolean;
    FLoaded: boolean;
    FAutoRefresh: boolean;
    FAutoConfigEditor: boolean;
    FAutoApplyTranslate: boolean;
    FRefreshTimer: TTimer;
    FOnBeforeSelect: TConfigBeforeSelectEvent;
    FOnSelect: TConfigSelectEvent;
    FOnBeforeRefresh: TConfigNotifyEvent;
    FOnAfterRefresh: TConfigNotifyEvent;
    FConfigForm: TForm;
    FTranslate: TTranslate;
    FOnBusy: TConfigBusyEvent;
    FFormPosition: TConfigFormPosition;
    FOnConfigReload: TConfigReloadEvent;
    FOnConfigsUpdated: TConfigNotifyEvent;
    FOnRefreshSettings: TConfigNotifyEvent;
    FOnConfigEditorShow: TConfigNotifyEvent;
    FOnConfigEditorHide: TConfigNotifyEvent;
    FOnGetSourceText: TConfigGetStringEvent;
    procedure SetTargetMenu(Value: TMenuItem);
    procedure SetTranslate(Value: TTranslate);
    procedure SetFormPosition(Value: TConfigFormPosition);
    procedure SetDirectories(Value: TStrings);
    procedure SetAppName(const Value: string);
    procedure SetConfig(const Value: string);
    procedure ApplySelection(AIndex: integer; const AConfigFile: string);
    procedure SetAutoRefresh(Value: boolean);
    procedure SetAutoConfigEditor(Value: boolean);
    procedure SetAutoApplyTranslate(Value: boolean);
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
    procedure NotifyConfigReload(var AHandled: boolean);
    // Notify the host that the set or contents of configs changed
    procedure NotifyConfigsUpdated;
    // Notify the host that the settings form config list needs refresh
    procedure NotifyRefreshSettings;
    // Notify the host that the editor is busy with a config load or save
    procedure NotifyBusy(ABusy: boolean);
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

    // Writable properties, declared in full; redeclared in TConfigManager
    property TargetMenu: TMenuItem read FTargetMenu write SetTargetMenu;
    property Directories: TStrings read FDirectories write SetDirectories stored DirectoriesStored;
    property AppName: string read FAppName write SetAppName;
    property ConfigFile: string read FSelectedConfig write SetConfig;
    property AutoRefresh: boolean read FAutoRefresh write SetAutoRefresh default True;
    property AutoConfigEditor: boolean read FAutoConfigEditor write SetAutoConfigEditor default False;
    property Translate: TTranslate read FTranslate write SetTranslate;
    property AutoApplyTranslate: boolean read FAutoApplyTranslate write SetAutoApplyTranslate default False;
    // Fires with ABusy=True before a config load or save, and False after
    property OnBusy: TConfigBusyEvent read FOnBusy write FOnBusy;
    property FormPosition: TConfigFormPosition read FFormPosition write SetFormPosition;

    // Events exposed through TConfigManager published section
    property OnBeforeSelect: TConfigBeforeSelectEvent read FOnBeforeSelect write FOnBeforeSelect;
    property OnSelect: TConfigSelectEvent read FOnSelect write FOnSelect;
    property OnBeforeRefresh: TConfigNotifyEvent read FOnBeforeRefresh write FOnBeforeRefresh;
    property OnAfterRefresh: TConfigNotifyEvent read FOnAfterRefresh write FOnAfterRefresh;
    property OnConfigReload: TConfigReloadEvent read FOnConfigReload write FOnConfigReload;
    property OnConfigsUpdated: TConfigNotifyEvent read FOnConfigsUpdated write FOnConfigsUpdated;
    property OnRefreshSettings: TConfigNotifyEvent read FOnRefreshSettings write FOnRefreshSettings;
    property OnConfigEditorShow: TConfigNotifyEvent read FOnConfigEditorShow write FOnConfigEditorShow;
    property OnConfigEditorHide: TConfigNotifyEvent read FOnConfigEditorHide write FOnConfigEditorHide;
    property OnGetSourceText: TConfigGetStringEvent read FOnGetSourceText write FOnGetSourceText;

    // Read-only discovery results
    // List of discovered config file paths
    property ConfigFiles: TStrings read GetConfigFiles;
    // Config title parsed from each INI, keyed by path
    property ConfigTitles: TStrings read GetConfigTitles;
    // Config color parsed from each INI, keyed by path
    property ConfigColors: TStrings read GetConfigColors;
    // Config icon index parsed from each INI, keyed by path
    property ConfigImages: TStrings read GetConfigImages;
    // Internal image list that holds config icons
    property Images: TImageList read FImages;
    // Number of discovered config files
    property ConfigCount: integer read GetConfigCount;
    // Currently active config path, same value as ConfigFile
    property SelectedConfig: string read FSelectedConfig;
    // Index of the active config in ConfigFiles
    property SelectedIndex: integer read GetSelectedIndex;
    // Icon index of the active config in Images
    property SelectedImageIndex: integer read GetSelectedImageIndex;
  end;

  // Manages a set of translator INI config files.
  // Scans Directories (or the exe directory plus AppName settings directory
  // when Directories is empty), builds cache lists, owns the icon image list
  // and fills an assigned TargetMenu with one item per config.
  TConfigManager = class(TCustomConfigManager)
  published
    // Menu that receives one item per discovered config
    property TargetMenu;
    // Extra search roots; empty means exe directory plus AppName settings
    property Directories;
    // Application name used to resolve the default settings directory
    property AppName;
    // Active config path; assigning applies the selection and fires events
    property ConfigFile;
    // When True, a delayed scan runs right after LFM streaming is finished
    property AutoRefresh;
    // When True, the config menu gets a Config Editor entry below all configs
    property AutoConfigEditor;
    // Translator component that the config editor edits
    property Translate;
    // When True, selecting a config also loads it into Translate
    property AutoApplyTranslate;
    // Fires with ABusy=True before a config load or save, and False after
    property OnBusy;
    // Editor form state, expandable group in the Object Inspector
    property FormPosition;
    // Fires before selection; set AAllow to False to cancel the switch
    property OnBeforeSelect;
    // Fires after the selection has been committed
    property OnSelect;
    // Fires before Refresh starts scanning directories
    property OnBeforeRefresh;
    // Fires after Refresh finished and the menu has been rebuilt
    property OnAfterRefresh;
    // Fires when the editor has loaded or saved a config
    property OnConfigReload;
    // Fires when the set or contents of configs changed; refresh derived UI
    property OnConfigsUpdated;
    // Fires when the settings form config list needs refresh
    property OnRefreshSettings;
    // Fires right before the editor form is shown
    property OnConfigEditorShow;
    // Fires when the editor form is freed
    property OnConfigEditorHide;
    // Fires when the editor needs the source text for response tests
    property OnGetSourceText;
  end;

implementation

uses
  Base64Utils, OSUtils, OneShotTimer, FormConfig;

const
  ICON_SIZE = 16;

  { TConfigFormPosition  }

procedure TConfigFormPosition.Assign(Source: TPersistent);
begin
  if Source is TConfigFormPosition then
  begin
    FLeft := TConfigFormPosition(Source).FLeft;
    FTop := TConfigFormPosition(Source).FTop;
    FWidth := TConfigFormPosition(Source).FWidth;
    FHeight := TConfigFormPosition(Source).FHeight;
    FSep1 := TConfigFormPosition(Source).FSep1;
    FSep2 := TConfigFormPosition(Source).FSep2;
  end
  else
    inherited Assign(Source);
end;

{ TCustomConfigManager }

constructor TCustomConfigManager.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FDirectories := TStringList.Create;
  FConfigFiles := TStringList.Create;
  FConfigTitles := TStringList.Create;
  FConfigColors := TStringList.Create;
  FConfigImages := TStringList.Create;
  FConfigVisible := TStringList.Create;
  FFormPosition := TConfigFormPosition.Create;
  FImages := TImageList.Create(Self);
  FImages.Width := ICON_SIZE;
  FImages.Height := ICON_SIZE;
  FSelectedConfig := string.Empty;
  FUpdateLock := False;
  FLoaded := False;
  FAutoRefresh := True;
  FAutoConfigEditor := False;
  FAutoApplyTranslate := False;
  FRefreshTimer := nil;
end;

destructor TCustomConfigManager.Destroy;
begin
  // Cancel a pending deferred refresh before tearing down
  ClearTimeout(FRefreshTimer);
  FreeAndNil(FFormPosition);
  FreeAndNil(FConfigVisible);
  FreeAndNil(FConfigImages);
  FreeAndNil(FConfigColors);
  FreeAndNil(FConfigTitles);
  FreeAndNil(FConfigFiles);
  FreeAndNil(FDirectories);
  inherited Destroy;
end;

procedure TCustomConfigManager.SetTranslate(Value: TTranslate);
begin
  FTranslate := Value;
end;

procedure TCustomConfigManager.SetAutoApplyTranslate(Value: boolean);
begin
  FAutoApplyTranslate := Value;
end;

procedure TCustomConfigManager.SetFormPosition(Value: TConfigFormPosition);
begin
  FFormPosition.Assign(Value);
end;

procedure TCustomConfigManager.ShowConfigEditor;
var
  Form: TformConfigTrayslate = nil;
begin
  if not Assigned(FTranslate) then Exit;

  // Bring an already created form to front
  if Assigned(FConfigForm) then
  begin
    if FConfigForm.Visible then FConfigForm.BringToFront
    else
      FConfigForm.Show;
    Exit;
  end;

  Form := TformConfigTrayslate.Create(Self, Self, FTranslate);
  Form.FreeNotification(Self);
  FConfigForm := Form;

  Form.Position := poDesigned;

  if FFormPosition.Left > 0 then
    Form.Left := FFormPosition.Left
  else
    Form.Position := poDesktopCenter;

  if FFormPosition.Top > 0 then
    Form.Top := FFormPosition.Top
  else
    Form.Position := poDesktopCenter;

  if FFormPosition.Width > 0 then
    Form.Width := FFormPosition.Width;
  if FFormPosition.Height > 0 then
    Form.Height := FFormPosition.Height;
  if FFormPosition.Sep1 > 0 then
    Form.GroupBoxCustomParameters.Height := FFormPosition.Sep1;
  if FFormPosition.Sep2 > 0 then
    Form.GroupResponse.Height := FFormPosition.Sep2;

  if Assigned(FOnConfigEditorShow) then
    FOnConfigEditorShow(Self);

  Form.Show;
  Form.BringToFront;
end;

function TCustomConfigManager.ConfigEditorActive: boolean;
begin
  Result := Assigned(FConfigForm);
end;

function TCustomConfigManager.ConfigEditorVisible: boolean;
begin
  Result := Assigned(FConfigForm) and FConfigForm.Visible;
end;

function TCustomConfigManager.TestConfigChanges: boolean;
begin
  Result := True;
  if Assigned(FConfigForm) and FConfigForm.HandleAllocated and FConfigForm.Showing then
    Result := TformConfigTrayslate(FConfigForm).TestChanges;
end;

procedure TCustomConfigManager.UpdateConfigEditor;
begin
  if not Assigned(FConfigForm) then Exit;
  if not FConfigForm.HandleAllocated then Exit;
  if not FConfigForm.Showing then Exit;

  TformConfigTrayslate(FConfigForm).UpdateConfigList;
  TformConfigTrayslate(FConfigForm).UpdateConfig;
end;

procedure TCustomConfigManager.InvalidateConfigEditor;
begin
  if not Assigned(FConfigForm) then Exit;
  if not FConfigForm.HandleAllocated then Exit;
  if Screen.ActiveForm <> FConfigForm then Exit;

  FConfigForm.Invalidate;
end;

procedure TCustomConfigManager.RelocalizeConfigEditor;
begin
  if Assigned(FConfigForm) and FConfigForm.HandleAllocated then
    TformConfigTrayslate(FConfigForm).Relocalize;
end;

procedure TCustomConfigManager.CloseConfigEditor;
begin
  if Assigned(FConfigForm) then
    FConfigForm.Close;
end;

procedure TCustomConfigManager.NotifyConfigReload(var AHandled: boolean);
begin
  AHandled := False;
  if Assigned(FOnConfigReload) then
    FOnConfigReload(Self, FSelectedConfig, AHandled);
end;

procedure TCustomConfigManager.NotifyConfigsUpdated;
begin
  if Assigned(FOnConfigsUpdated) then
    FOnConfigsUpdated(Self);
end;

procedure TCustomConfigManager.NotifyRefreshSettings;
begin
  if Assigned(FOnRefreshSettings) then
    FOnRefreshSettings(Self);
end;

procedure TCustomConfigManager.NotifyBusy(ABusy: boolean);
begin
  if Assigned(FOnBusy) then
    FOnBusy(Self, ABusy);
end;

function TCustomConfigManager.GetSourceText: string;
begin
  Result := string.Empty;
  if Assigned(FOnGetSourceText) then
    FOnGetSourceText(Self, Result);
end;

function TCustomConfigManager.GetConfigDirectory: string;
begin
  if FAppName <> string.Empty then
    Result := TOS.GetSettingsDirectory(FAppName, '')
  else
    Result := ExtractFilePath(ParamStr(0));
end;

procedure TCustomConfigManager.Loaded;
begin
  inherited Loaded;
  FLoaded := True;
  // Defer the first scan past LFM streaming; only when AutoRefresh is True
  if FAutoRefresh and (not (csDesigning in ComponentState)) then
    SetTimeout(FRefreshTimer, 10, @DeferredRefresh);
end;

procedure TCustomConfigManager.DeferredRefresh;
begin
  if not FLoaded then Exit;
  if csDesigning in ComponentState then Exit;
  if csDestroying in ComponentState then Exit;
  Refresh;
end;

procedure TCustomConfigManager.SetTargetMenu(Value: TMenuItem);
begin
  if FTargetMenu = Value then Exit;
  if Assigned(FTargetMenu) then
    FTargetMenu.RemoveFreeNotification(Self);
  FTargetMenu := Value;
  if Assigned(FTargetMenu) then
    FTargetMenu.FreeNotification(Self);
end;

procedure TCustomConfigManager.SetDirectories(Value: TStrings);
begin
  FDirectories.Assign(Value);
end;

procedure TCustomConfigManager.SetAppName(const Value: string);
begin
  if FAppName = Value then Exit;
  FAppName := Value;
end;

procedure TCustomConfigManager.SetSelectedConfigSilent(const Value: string);
begin
  if FSelectedConfig = Value then Exit;
  FSelectedConfig := Value;
  UpdateCheckState;
end;

procedure TCustomConfigManager.SetAutoRefresh(Value: boolean);
begin
  if FAutoRefresh = Value then Exit;
  FAutoRefresh := Value;
  // Turning auto-refresh off also aborts a pending deferred scan
  if not FAutoRefresh then
    ClearTimeout(FRefreshTimer);
end;

function TCustomConfigManager.DirectoriesStored: boolean;
begin
  Result := FDirectories.Count > 0;
end;

procedure TCustomConfigManager.SetAutoConfigEditor(Value: boolean);
begin
  if FAutoConfigEditor = Value then Exit;
  FAutoConfigEditor := Value;
  // Rebuild so the entry appears or disappears immediately
  RebuildMenu;
end;

procedure TCustomConfigManager.MenuItemClick(Sender: TObject);
var
  Item: TMenuItem;
begin
  if FUpdateLock then Exit;
  if not (Sender is TMenuItem) then Exit;

  Item := TMenuItem(Sender);

  // Editor entry opens the editor form; ConfigFile entries switch the ConfigFile
  if Item.Tag = -1 then
  begin
    ShowConfigEditor;
    Exit;
  end;

  if (Item.Tag < 0) or (Item.Tag >= FConfigFiles.Count) then Exit;

  ApplySelection(Item.Tag, FConfigFiles[Item.Tag]);
end;

procedure TCustomConfigManager.ApplySelection(AIndex: integer; const AConfigFile: string);
var
  Allow: boolean;
begin
  Allow := True;
  if Assigned(FOnBeforeSelect) then
    FOnBeforeSelect(Self, AIndex, AConfigFile, Allow);
  if not Allow then Exit;

  FSelectedConfig := AConfigFile;
  UpdateCheckState;

  // Optional shortcut: load the chosen ConfigFile into the translator
  if FAutoApplyTranslate and Assigned(FTranslate) then
    FTranslate.ConfigFile := AConfigFile;

  if Assigned(FOnSelect) then
    FOnSelect(Self, AIndex, AConfigFile);
end;

procedure TCustomConfigManager.SetConfig(const Value: string);
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

  // Optional shortcut: load the chosen ConfigFile into the translator
  if FAutoApplyTranslate and Assigned(FTranslate) then
    FTranslate.ConfigFile := Value;

  if (Idx >= 0) and Assigned(FOnSelect) then
    FOnSelect(Self, Idx, Value);
end;

procedure TCustomConfigManager.UpdateCheckState;
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
      // Skip separator (Tag = -2) and editor entry (Tag = -1)
      if FTargetMenu.Items[i].Tag < 0 then Continue;
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

procedure TCustomConfigManager.AttachImages;
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

procedure TCustomConfigManager.RebuildMenu;
var
  i: integer;
  Item: TMenuItem;
  Separator: TMenuItem;
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
    // The menu stays visible when the editor entry is enabled even without configs
    FTargetMenu.Visible := FAutoConfigEditor or (FConfigFiles.Count > 0);

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

    // Editor entry goes last, separated from the ConfigFile list
    if FAutoConfigEditor then
    begin
      if FConfigFiles.Count > 0 then
      begin
        Separator := TMenuItem.Create(FTargetMenu);
        Separator.Caption := '-';
        Separator.Tag := -2;
        FTargetMenu.Add(Separator);
      end;

      Item := TMenuItem.Create(FTargetMenu);
      Item.Caption := rconfigeditor;
      Item.Tag := -1;
      Item.OnClick := @MenuItemClick;
      FTargetMenu.Add(Item);
    end;
  finally
    FUpdateLock := False;
  end;
end;

procedure TCustomConfigManager.LoadConfigs;
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

procedure TCustomConfigManager.Refresh;
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

procedure TCustomConfigManager.Clear;
begin
  ClearTimeout(FRefreshTimer);

  FConfigFiles.Clear;
  FConfigTitles.Clear;
  FConfigColors.Clear;
  FConfigImages.Clear;
  FConfigVisible.Clear;
  FImages.Clear;
  FSelectedConfig := string.Empty;

  // Rebuild handles both the empty case and the optional editor entry
  RebuildMenu;
end;

function TCustomConfigManager.AddConfigFile(const AFileName: string): integer;
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

function TCustomConfigManager.RemoveConfigFile(const AFileName: string): boolean;
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

function TCustomConfigManager.IndexOfConfig(const AFileName: string): integer;
begin
  Result := FConfigFiles.IndexOf(AFileName);
end;

function TCustomConfigManager.ResolveConfigPath(const AConfigName: string): string;
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

function TCustomConfigManager.GetConfigIcon(AIndex: integer; AIcon: TIcon): boolean;
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

function TCustomConfigManager.GetSelectedIcon(AIcon: TIcon): boolean;
begin
  Result := GetConfigIcon(SelectedIndex, AIcon);
end;

function TCustomConfigManager.GetConfigCount: integer;
begin
  Result := FConfigFiles.Count;
end;

function TCustomConfigManager.GetSelectedIndex: integer;
begin
  Result := FConfigFiles.IndexOf(FSelectedConfig);
end;

function TCustomConfigManager.GetSelectedImageIndex: integer;
begin
  Result := GetConfigImageIndex(SelectedIndex);
end;

function TCustomConfigManager.GetConfigTitle(AIndex: integer): string;
begin
  Result := string.Empty;
  if (AIndex >= 0) and (AIndex < FConfigTitles.Count) then
    Result := FConfigTitles.ValueFromIndex[AIndex];
end;

function TCustomConfigManager.GetConfigColor(AIndex: integer): TColor;
begin
  Result := clBlue;
  if (AIndex >= 0) and (AIndex < FConfigColors.Count) then
    Result := StrToIntDef(FConfigColors.ValueFromIndex[AIndex], clBlue);
end;

function TCustomConfigManager.GetConfigImageIndex(AIndex: integer): integer;
begin
  Result := -1;
  if (AIndex >= 0) and (AIndex < FConfigImages.Count) then
    Result := StrToIntDef(FConfigImages.ValueFromIndex[AIndex], -1);
end;

function TCustomConfigManager.GetConfigVisible(AIndex: integer): boolean;
begin
  Result := True;
  if (AIndex >= 0) and (AIndex < FConfigVisible.Count) then
    Result := FConfigVisible.ValueFromIndex[AIndex] = '1';
end;

function TCustomConfigManager.GetConfigFiles: TStrings;
begin
  Result := FConfigFiles;
end;

function TCustomConfigManager.GetConfigTitles: TStrings;
begin
  Result := FConfigTitles;
end;

function TCustomConfigManager.GetConfigColors: TStrings;
begin
  Result := FConfigColors;
end;

function TCustomConfigManager.GetConfigImages: TStrings;
begin
  Result := FConfigImages;
end;

procedure TCustomConfigManager.Notification(AComponent: TComponent; Operation: TOperation);
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

class function TCustomConfigManager.IsValidIni(const FileName: string): boolean;
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

class procedure TCustomConfigManager.FindIniFiles(const Dir: string; List: TStrings);
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

class procedure TCustomConfigManager.GetIniFiles(List: TStrings; AppName: string);
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

class function TCustomConfigManager.ConfigSortByOrderPathName(List: TStringList; Index1, Index2: integer): integer;
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
