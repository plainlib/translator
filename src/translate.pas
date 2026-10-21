//-----------------------------------------------------------------------------------
//  Translator Package © 2026 by Alexander Tverskoy
//  Licensed under the MIT License
//  You may obtain a copy of the License at https://opensource.org/licenses/MIT
//-----------------------------------------------------------------------------------

unit Translate;

{$mode objfpc}{$H+}

interface

uses
  Classes,
  Forms,
  SysUtils,
  RegExpr,
  StrUtils,
  Controls,
  DateUtils,
  Graphics,
  ExtCtrls,
  LazUTF8,
  IniFiles,
  fpjson,
  jsonparser,
  ScriptRunner,
  Network,
  {$PUSH}
  {$WARNINGS OFF}
  {$HINTS OFF}
  {$NOTES OFF}
  httpsend;
  {$POP}

type
  { TLangType }
  TLangType = (
    vtNone,            // as is
    vtLanguage,        // languages
    vtCurrencyAll,     // fiat + crypto
    vtCurrencyFiat,    // fiat only
    vtCurrencyCrypto,  // crypto only
    vtUnit             // units of measure
    );

  PConfigData = ^TConfigData;

  TConfigData = record
    Order: integer;
    PathOnly: string;
    Name: string;
    Color: TColor;
    Visible: boolean;
    ImageIndex: integer;
  end;

  { Action proposed by language detection analysis }
  TLanguageDetectAction = (ldaNone, ldaSwap, ldaChangeSource, ldaChangeTarget, ldaChangeBoth);

  { Language detection analysis result, passed to OnLanguageDetected }
  TLanguageDetectResult = record
    DetectedLanguage: string;  // Normalized detected language code
    OldSource: string;         // Source language before analysis
    OldTarget: string;         // Target language before analysis
    NewSource: string;         // Suggested source code (empty means no change)
    NewTarget: string;         // Suggested target code (empty means no change)
    Action: TLanguageDetectAction;
    Applied: boolean;          // True when Detect.AutoApply already applied the result
  end;

  { Translate Events }
  TLanguageDetectEvent = procedure(Sender: TObject; const AResult: TLanguageDetectResult) of object;
  TGetParameterEvent = procedure(const AParamName: string; var AValue: string; var AHandled: boolean) of object;
  TTranslateNotify = procedure(Sender: TObject; const AText: string) of object;

  TTranslateThread = class;  // defined below the base class

type
  { Proxy options for the Object Inspector }
  TTranslateProxy = class(TPersistent)
  private
    FMode: TProxyMode;
    FType: TProxyType;
    FHost: string;
    FPort: string;
    FAuthentication: boolean;
    FLogin: string;
    FPassword: string;
    FOnChange: TNotifyEvent;
    procedure Changed;
  public
    procedure Assign(Source: TPersistent); override;
    function ToProxy: TProxy;
    procedure FromProxy(const AProxy: TProxy);
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
  published
    // Proxy mode: none, system, or custom from the fields below
    property Mode: TProxyMode read FMode write FMode default pmNone;
    // Proxy protocol used for custom mode, HTTP by default
    property Type_: TProxyType read FType write FType default ptHTTP;
    // Proxy server host name or IP address
    property Host: string read FHost write FHost;
    // Proxy server port as a string to allow empty values
    property Port: string read FPort write FPort;
    // Enables login and password authentication on the proxy
    property Authentication: boolean read FAuthentication write FAuthentication default False;
    // User name sent when proxy authentication is enabled
    property Login: string read FLogin write FLogin;
    // Password sent when proxy authentication is enabled
    property Password: string read FPassword write FPassword;
  end;

  { Timeout options for the Object Inspector }
  TTranslateTimeout = class(TPersistent)
  private
    FConnection: integer;
    FRequest: integer;
    FOnChange: TNotifyEvent;
    procedure Changed;
  public
    procedure Assign(Source: TPersistent); override;
    function ToTimeout: TTimeout;
    procedure FromTimeout(const ATimeout: TTimeout);
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
  published
    // Connection timeout in milliseconds, used while opening the socket
    property Connection: integer read FConnection write FConnection default 10000;
    // Request timeout in milliseconds, covers the whole HTTP exchange
    property Request: integer read FRequest write FRequest default 30000;
  end;

  { Nested language detection settings }
  TDetectSettings = class(TPersistent)
  private
    FAllowProxy: boolean;
    FConfigFile: string;
    FBuiltinDetect: boolean;
    FEnabled: boolean;
    FAutoApply: boolean;
    FAutoSwap: boolean;
    FSmartSwap: boolean;
    FSmartHard: boolean;
    FPrimaryLanguage: string;
    FSecondaryLanguage: string;
    FOnChange: TNotifyEvent;
    procedure Changed;
    procedure SetConfigFile(const Value: string);
    procedure SetUseBuiltin(Value: boolean);
    procedure SetEnabled(Value: boolean);
    procedure SetAutoApply(Value: boolean);
    procedure SetAutoSwap(Value: boolean);
    procedure SetSmartSwap(Value: boolean);
    procedure SetSmartHard(Value: boolean);
    procedure SetPrimaryLanguage(const Value: string);
    procedure SetSecondaryLanguage(const Value: string);
    procedure SetAllowProxy(Value: boolean);
  public
    constructor Create;
    procedure Assign(Source: TPersistent); override;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
  published
    // Apply the detection result automatically; no OnLanguageDetected handler needed
    property AutoApply: boolean read FAutoApply write SetAutoApply default False;
    // Allows the detect engine to use the configured proxy
    property AllowProxy: boolean read FAllowProxy write SetAllowProxy default True;
    // Path to the detect service INI, ignored when UseBuiltin is True
    property ConfigFile: string read FConfigFile write SetConfigFile;
    // Use the built-in offline detector instead of an HTTP service
    property BuiltinDetect: boolean read FBuiltinDetect write SetUseBuiltin default True;
    // Run detection before each translation and notify via OnLanguageDetected
    property Enabled: boolean read FEnabled write SetEnabled default False;
    // Allow plain swap when detected language matches the target
    property AutoSwap: boolean read FAutoSwap write SetAutoSwap default True;
    // Compare detected language with the pair instead of blind swap
    property SmartSwap: boolean read FSmartSwap write SetSmartSwap default False;
    // Restrict smart swap to the primary and secondary pair only
    property SmartHard: boolean read FSmartHard write SetSmartHard default False;
    // Main language code used by smart swap as the expected source
    property PrimaryLanguage: string read FPrimaryLanguage write SetPrimaryLanguage;
    // Second language code used by smart swap as the expected target
    property SecondaryLanguage: string read FSecondaryLanguage write SetSecondaryLanguage;
  end;

  { TCustomTranslate }
  TCustomTranslate = class(TComponent)
  private
    FSourceLanguage: string;
    FTargetLanguage: string;
    FTextToTranslate: string;
    FIsTruncated: boolean;
    FCookies: TStringList;
    FCurrentHTTP: THTTPSend;
    FHTTPList: TList;

    FServiceName: string;
    FServiceIcon: string;
    FServiceOrder: integer;
    FServiceVisible: boolean;
    FServiceAutoSwap: boolean;
    FServiceRealTime: boolean;
    FServiceOnlyButton: boolean;
    FServiceProxy: boolean;
    FAllowProxy: boolean;
    FWebMethod: TWebMethod;
    FUserAgent: string;
    FHeaders: TStringList;
    FCustomParameters: TStringList;
    FScriptParameters: TStringList;
    FScriptResponse: TStringList;
    FServiceColorRecent: TColor;
    FServiceDescription: TStringList;
    FEncodeText: boolean;
    FMaxLength: integer;
    FEncodeCustomParameters: boolean;
    FUrl: string;
    FContentType: string;
    FPostData: string;
    FAccept: string;
    FJsonPointer: string;
    FRegexp: string;
    FLanguages: TStringList;
    FLanguagesTarget: TStringList;
    FLanguagesOriginal: TStringList;
    FLanguagesTargetOriginal: TStringList;
    FLanguageCodes: TStringArray;
    FLangType: TLangType;
    FProxy: TTranslateProxy;
    FTimeout: TTranslateTimeout;

    FInitUserAgent: string;
    FInitHeaders: TStringList;
    FInitUrl: string;
    FInitParameters: TStringList;
    FInitLiveTime: integer;
    FParameterValues: TStringList;
    FParameterEncode: TStringList;

    FParametersAge: TDateTime;

    FParamName: string;
    FResultValue: string;
    FResultOk: boolean;
    FUserParameters: TStringList;
    FOnGetParameter: TGetParameterEvent;

    // Thread management
    FTranslateThread: TTranslateThread;
    FActiveThreads: TList;
    FCancelled: boolean;
    FRawTranslate: string;

    // Built-in language detection profiles state
    FProfilesLoaded: boolean;

    // Nested detection settings and internal HTTP detect engine
    FDetect: TDetectSettings;
    FDetectEngine: TCustomTranslate;
    FLoadedDetectConfig: string;
    FLastBuiltinDetect: boolean;

    // Detection event and cross-thread result buffer
    FOnLanguageDetected: TLanguageDetectEvent;
    FPendingDetectResult: TLanguageDetectResult;

    // Configuration file for designer use
    FConfigFile: string;

    // Translate lifecycle events
    FOnTranslateStart: TNotifyEvent;
    FOnTranslateComplete: TTranslateNotify;
    FOnTranslateFinish: TNotifyEvent;
    FOnChange: TNotifyEvent;

    procedure SyncGetParameterValue;
    procedure ThreadTerminated(Sender: TObject);
    procedure ThreadTerminatedAsync(Sender: TObject);

    // Config file handling
    procedure SetConfigFile(const Value: string);

    // Nested persistent object setters (required for LFM streaming)
    procedure SetProxy(Value: TTranslateProxy);
    procedure SetTimeout(Value: TTranslateTimeout);

    // Language accessors (fire OnChange)
    function GetSourceLanguage: string;
    procedure SetSourceLanguage(const Value: string);
    function GetTargetLanguage: string;
    procedure SetTargetLanguage(const Value: string);

    // Detect settings handler and internal detect engine plumbing
    procedure SetDetect(Value: TDetectSettings);
    procedure DetectChanged(Sender: TObject);
    procedure ProxyChanged(Sender: TObject);
    procedure TimeoutChanged(Sender: TObject);
    procedure EnsureDetectEngine;
    function DetectLanguageInternal(const AText: string): string;
    function AnalyzeLanguage(const AText: string): TLanguageDetectResult;
    procedure ApplyDetectResult(const AResult: TLanguageDetectResult);
    procedure DoLanguageDetected;
    procedure FireLanguageDetected(const AResult: TLanguageDetectResult);
    function FindLanguageCode(const ALangCode: string): string;
    function ShouldAutoDetect(ADetectLanguage: boolean): boolean;
  protected
    // Fires OnChange for designer notifications
    procedure Changed;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    procedure Clear;
    procedure AbortRequest;
    procedure ExecuteParametersScript;
    procedure ExecuteResponseScript(var Response: string);
    function GetParameters(Data: string): boolean;
    function SetParameters(Data: string; IncludeSet: boolean = True): string;
    procedure SetParametersList(Strings: TStrings);
    function GetInit: string;
    function Get(ReturnHeaders: boolean = False): string;
    function Post(ReturnHeaders: boolean = False): string;
    function ParseJsonByPointer(const JsonStr, JsonPointer: string): string;
    function ParseResponse(content: string): string;
    // Clean translated text by replacing <br> and HTML entities only if they were not present in the original.
    function CleanTranslatedText(const OriginalText, TranslatedText: string): string;
    function Translate: string;
    // Thread management
    function TranslateSync(const AText: string; ADetectLanguage: boolean = True): string;
    procedure TranslateAsync(const AText: string; ADetectLanguage: boolean = True);
    function IsTranslating: boolean;
    procedure CancelTranslate;

    // Wrapper for TLangDetect.DetectLanguageSafe; empty AText and ACurrentLang fall back to TextToTranslate and LangSource
    function DetectLanguage(const AText: string = string.Empty; ACurrentLang: string = string.Empty;
      MinConfidence: double = 0.5; AAllowedLangs: TStringArray = nil; ASampleSize: integer = 1000): string;
    // Maps deprecated or aliased language codes to canonical ones
    function NormalizeLanguageCode(const ACode: string): string;
    // Loads built-in detection profiles; safe to call repeatedly
    procedure LoadDetectProfiles;
    // Releases built-in detection profiles to free memory; safe to call repeatedly
    procedure UnloadDetectProfiles;

    { Ini config }
    procedure SaveIniSettings(AFileName: string);
    procedure LoadIniSettings(AFileName: string);
    class function IsValidIni(const FileName: string): boolean; static;
    class procedure FindIniFiles(const Dir: string; List: TStrings); static;
    class procedure GetIniFiles(List: TStrings; AppName: string); static;
    class function GetConfigFullPath(const ConfigName: string; ConfigFiles: TStringList): string; static;
    class function ConfigSortByOrderPathName(List: TStringList; Index1, Index2: integer): integer; static;
    class procedure ClearSection(AIni: TIniFile; const ASection: string; AErase: boolean); static;
    class function GetIniDirectory(AppName: string; fileName: string = string.Empty): string;

    { Properties }
    property Detect: TDetectSettings read FDetect write SetDetect;
    property DetectEngine: TCustomTranslate read FDetectEngine;
    property OnLanguageDetected: TLanguageDetectEvent read FOnLanguageDetected write FOnLanguageDetected;
    // True when built-in detection profiles are loaded in memory
    property ProfilesLoaded: boolean read FProfilesLoaded;

    property SourceLanguage: string read GetSourceLanguage write SetSourceLanguage;
    property TargetLanguage: string read GetTargetLanguage write SetTargetLanguage;
    property TextToTranslate: string read FTextToTranslate write FTextToTranslate;
    property ParametersAge: TDateTime read FParametersAge write FParametersAge;
    property ParameterValues: TStringList read FParameterValues write FParameterValues;
    property ParameterEncode: TStringList read FParameterEncode write FParameterEncode;

    property ServiceName: string read FServiceName write FServiceName;
    property ServiceIcon: string read FServiceIcon write FServiceIcon;
    property ServiceOrder: integer read FServiceOrder write FServiceOrder;
    property ServiceVisible: boolean read FServiceVisible write FServiceVisible;
    property ServiceAutoSwap: boolean read FServiceAutoSwap write FServiceAutoSwap;
    property ServiceRealTime: boolean read FServiceRealTime write FServiceRealTime;
    property ServiceOnlyButton: boolean read FServiceOnlyButton write FServiceOnlyButton;
    property ServiceProxy: boolean read FServiceProxy write FServiceProxy;
    property ServiceColorRecent: TColor read FServiceColorRecent write FServiceColorRecent;
    property ServiceDescription: TStringList read FServiceDescription write FServiceDescription;
    property WebMethod: TWebMethod read FWebMethod write FWebMethod;
    property UserAgent: string read FUserAgent write FUserAgent;
    property Headers: TStringList read FHeaders write FHeaders;
    property EncodeText: boolean read FEncodeText write FEncodeText;
    property MaxLength: integer read FMaxLength write FMaxLength;
    property Url: string read FUrl write FUrl;
    property ContentType: string read FContentType write FContentType;
    property PostData: string read FPostData write FPostData;
    property Accept: string read FAccept write FAccept;
    property JsonPointer: string read FJsonPointer write FJsonPointer;
    property EncodeCustomParameters: boolean read FEncodeCustomParameters write FEncodeCustomParameters;
    property CustomParameters: TStringList read FCustomParameters write FCustomParameters;
    property ScriptParameters: TStringList read FScriptParameters write FScriptParameters;
    property ScriptResponse: TStringList read FScriptResponse write FScriptResponse;
    property AllowProxy: boolean read FAllowProxy write FAllowProxy;

    // Designer-friendly wrappers; use ToProxy/ToTimeout for the Network layer
    property Proxy: TTranslateProxy read FProxy write SetProxy;
    property Timeout: TTranslateTimeout read FTimeout write SetTimeout;

    // Languages from config, eg en=en
    property Languages: TStringList read FLanguages write FLanguages;
    property LanguagesTarget: TStringList read FLanguagesTarget write FLanguagesTarget;
    property LanguagesOriginal: TStringList read FLanguagesOriginal write FLanguagesOriginal;
    property LanguagesTargetOriginal: TStringList read FLanguagesTargetOriginal write FLanguagesTargetOriginal;
    property LanguageCodes: TStringArray read FLanguageCodes write FLanguageCodes;
    property LangType: TLangType read FLangType write FLangType;

    property InitUserAgent: string read FInitUserAgent write FInitUserAgent;
    property InitHeaders: TStringList read FInitHeaders write FInitHeaders;
    property InitUrl: string read FInitUrl write FInitUrl;
    property InitParameters: TStringList read FInitParameters write FInitParameters;
    property InitLiveTime: integer read FInitLiveTime write FInitLiveTime;

    property UserParameters: TStringList read FUserParameters write FUserParameters;
    property OnGetParameter: TGetParameterEvent read FOnGetParameter write FOnGetParameter;

    // Thread state
    property RawTranslate: string read FRawTranslate;
    property TranslateThread: TTranslateThread read FTranslateThread;
    property Cancelled: boolean read FCancelled write FCancelled;

    // Thread events
    property OnTranslateStart: TNotifyEvent read FOnTranslateStart write FOnTranslateStart;
    property OnTranslateComplete: TTranslateNotify read FOnTranslateComplete write FOnTranslateComplete;
    property OnTranslateFinish: TNotifyEvent read FOnTranslateFinish write FOnTranslateFinish;

    // Configuration file for designer use - loads INI when set
    property ConfigFile: string read FConfigFile write SetConfigFile;

    // Fired when a designer-visible property changes
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
  end;

  { TTranslate }
  TTranslate = class(TCustomTranslate)
  published
    // Path to the INI file with the service configuration
    property ConfigFile;

    // Source language code, overrides the INI value when not empty
    property SourceLanguage;

    // Target language code, overrides the INI value when not empty
    property TargetLanguage;

    // Allow this service to use the proxy configured below
    property AllowProxy;

    // Language detection settings
    property Detect;

    // Proxy settings, expandable group in the Object Inspector
    property Proxy;

    // Connection and request timeouts, expandable group
    property Timeout;

    // Fires before the translation request starts
    property OnTranslateStart;

    // Fires on success with the translated text as parameter
    property OnTranslateComplete;

    // Fires always when the operation ends, including cancel and errors
    property OnTranslateFinish;

    // Fires when the service needs a user-supplied parameter value
    property OnGetParameter;

    // Fires when detection proposes a language change; caller applies it
    property OnLanguageDetected;

    // Fires when a designer-visible property changes
    property OnChange;
  end;

  { TTranslateThread }
  TTranslateThread = class(TThread)
  private
    FTrans: TCustomTranslate;
    FResult: PString;
    FDone: PBoolean;
    FSourceText: string;
    FDetectLanguage: boolean;
    FExceptionMessage: string;
    FCancelled: boolean;
  protected
    procedure Execute; override;
    function GetIsTerminated: boolean;
    function GetIsCancelled: boolean;
    function GetResultText: string;
  public
    constructor Create(ATrans: TCustomTranslate; AResult: PString; ADone: PBoolean; ADetectLanguage: boolean = True;
      AFreeOnTerminate: boolean = True);
    procedure Cancel;
    property IsTerminated: boolean read GetIsTerminated;
    property IsCancelled: boolean read GetIsCancelled;
    property ExceptionMessage: string read FExceptionMessage;
    property ResultText: string read GetResultText;
  end;

const
  DEFAULT_LANG = 'en';
  EMPTY_LANG = 'empty';
  REGEXP_ERROR = 'REGEX_ERROR: ';
  THREADS_WAIT_TIME = 5000;

implementation

uses StringsHelper, StringHelper, Localize, OSUtils, Languages, LangDetect;

  {%Region -fold TDetectSettings }

constructor TDetectSettings.Create;
begin
  inherited Create;
  FAllowProxy := True;
  FBuiltinDetect := True;
  FEnabled := False;
  FAutoApply := False;
  FAutoSwap := True;
  FSmartSwap := False;
  FSmartHard := False;
end;

procedure TDetectSettings.Changed;
begin
  if Assigned(FOnChange) then
    FOnChange(Self);
end;

procedure TDetectSettings.SetConfigFile(const Value: string);
begin
  if FConfigFile = Value then Exit;
  FConfigFile := Value;
  Changed;
end;

procedure TDetectSettings.SetUseBuiltin(Value: boolean);
begin
  if FBuiltinDetect = Value then Exit;
  FBuiltinDetect := Value;
  Changed;
end;

procedure TDetectSettings.SetEnabled(Value: boolean);
begin
  if FEnabled = Value then Exit;
  FEnabled := Value;
  Changed;
end;

procedure TDetectSettings.SetAutoApply(Value: boolean);
begin
  if FAutoApply = Value then Exit;
  FAutoApply := Value;
  Changed;
end;

procedure TDetectSettings.SetAutoSwap(Value: boolean);
begin
  if FAutoSwap = Value then Exit;
  FAutoSwap := Value;
  Changed;
end;

procedure TDetectSettings.SetSmartSwap(Value: boolean);
begin
  if FSmartSwap = Value then Exit;
  FSmartSwap := Value;
  Changed;
end;

procedure TDetectSettings.SetSmartHard(Value: boolean);
begin
  if FSmartHard = Value then Exit;
  FSmartHard := Value;
  Changed;
end;

procedure TDetectSettings.SetPrimaryLanguage(const Value: string);
begin
  if FPrimaryLanguage = Value then Exit;
  FPrimaryLanguage := Value;
  Changed;
end;

procedure TDetectSettings.SetSecondaryLanguage(const Value: string);
begin
  if FSecondaryLanguage = Value then Exit;
  FSecondaryLanguage := Value;
  Changed;
end;

procedure TDetectSettings.SetAllowProxy(Value: boolean);
begin
  if FAllowProxy = Value then Exit;
  FAllowProxy := Value;
  Changed;
end;

procedure TDetectSettings.Assign(Source: TPersistent);
begin
  if Source is TDetectSettings then
  begin
    FAllowProxy := TDetectSettings(Source).FAllowProxy;
    FConfigFile := TDetectSettings(Source).FConfigFile;
    FBuiltinDetect := TDetectSettings(Source).FBuiltinDetect;
    FEnabled := TDetectSettings(Source).FEnabled;
    FAutoApply := TDetectSettings(Source).FAutoApply;
    FAutoSwap := TDetectSettings(Source).FAutoSwap;
    FSmartSwap := TDetectSettings(Source).FSmartSwap;
    FSmartHard := TDetectSettings(Source).FSmartHard;
    FPrimaryLanguage := TDetectSettings(Source).FPrimaryLanguage;
    FSecondaryLanguage := TDetectSettings(Source).FSecondaryLanguage;
    Changed;
  end
  else
    inherited Assign(Source);
end;

{%EndRegion}

{%Region -fold TTranslateProxy }

procedure TTranslateProxy.Changed;
begin
  if Assigned(FOnChange) then
    FOnChange(Self);
end;

procedure TTranslateProxy.Assign(Source: TPersistent);
begin
  if Source is TTranslateProxy then
  begin
    FMode := TTranslateProxy(Source).FMode;
    FType := TTranslateProxy(Source).FType;
    FHost := TTranslateProxy(Source).FHost;
    FPort := TTranslateProxy(Source).FPort;
    FAuthentication := TTranslateProxy(Source).FAuthentication;
    FLogin := TTranslateProxy(Source).FLogin;
    FPassword := TTranslateProxy(Source).FPassword;
    Changed;
  end
  else
    inherited Assign(Source);
end;

function TTranslateProxy.ToProxy: TProxy;
begin
  Result.ProxyMode := FMode;
  Result.ProxyType := FType;
  Result.Host := FHost;
  Result.Port := FPort;
  Result.Authentication := FAuthentication;
  Result.Login := FLogin;
  Result.Password := FPassword;
end;

procedure TTranslateProxy.FromProxy(const AProxy: TProxy);
begin
  FMode := AProxy.ProxyMode;
  FType := AProxy.ProxyType;
  FHost := AProxy.Host;
  FPort := AProxy.Port;
  FAuthentication := AProxy.Authentication;
  FLogin := AProxy.Login;
  FPassword := AProxy.Password;
  Changed;
end;

{ TTranslateTimeout }

procedure TTranslateTimeout.Changed;
begin
  if Assigned(FOnChange) then
    FOnChange(Self);
end;

procedure TTranslateTimeout.Assign(Source: TPersistent);
begin
  if Source is TTranslateTimeout then
  begin
    FConnection := TTranslateTimeout(Source).FConnection;
    FRequest := TTranslateTimeout(Source).FRequest;
    Changed;
  end
  else
    inherited Assign(Source);
end;

function TTranslateTimeout.ToTimeout: TTimeout;
begin
  Result.Connection := FConnection;
  Result.Request := FRequest;
end;

procedure TTranslateTimeout.FromTimeout(const ATimeout: TTimeout);
begin
  FConnection := ATimeout.Connection;
  FRequest := ATimeout.Request;
  Changed;
end;

{%EndRegion}

{%Region -fold TCustomTranslate }

{ Private }

procedure TCustomTranslate.SyncGetParameterValue;
begin
  FResultOk := True;
  FResultValue := string.Empty;
  if Assigned(FOnGetParameter) then
    FOnGetParameter(FParamName, FResultValue, FResultOk);
end;

procedure TCustomTranslate.ThreadTerminated(Sender: TObject);
var
  Idx: integer;
begin
  if Sender = FTranslateThread then
    FTranslateThread := nil;

  if Assigned(FActiveThreads) then
  begin
    Idx := FActiveThreads.IndexOf(Sender);
    if Idx >= 0 then
      FActiveThreads.Delete(Idx);
  end;
end;

procedure TCustomTranslate.ThreadTerminatedAsync(Sender: TObject);
var
  Idx: integer;
  Text: string;
  WasCancelled: boolean;
begin
  // Snapshot before firing user events, so a new async call from a handler
  // does not see a half-updated state
  Text := FRawTranslate;
  WasCancelled := FCancelled;

  // Clear the active thread first so user handlers may start a new async call
  if Sender = FTranslateThread then
    FTranslateThread := nil;

  if Assigned(FActiveThreads) then
  begin
    Idx := FActiveThreads.IndexOf(Sender);
    if Idx >= 0 then
      FActiveThreads.Delete(Idx);
  end;

  try
    if not WasCancelled and (Text.Trim <> string.Empty) then
    begin
      if Assigned(FOnTranslateComplete) then
        FOnTranslateComplete(Self, Text);
    end;
  finally
    if Assigned(FOnTranslateFinish) then
      FOnTranslateFinish(Self);
  end;
end;

procedure TCustomTranslate.SetConfigFile(const Value: string);
begin
  if FConfigFile = Value then Exit;
  FConfigFile := Value;
  // Load INI content immediately so the designer shows real values
  if (Value <> string.Empty) and FileExists(Value) then
    LoadIniSettings(Value);
  Changed;
end;

procedure TCustomTranslate.SetProxy(Value: TTranslateProxy);
begin
  FProxy.Assign(Value);
end;

procedure TCustomTranslate.SetTimeout(Value: TTranslateTimeout);
begin
  FTimeout.Assign(Value);
end;

function TCustomTranslate.GetSourceLanguage: string;
begin
  Result := FSourceLanguage;
end;

procedure TCustomTranslate.SetSourceLanguage(const Value: string);
begin
  if FSourceLanguage = Value then Exit;
  FSourceLanguage := Value;
  Changed;
end;

function TCustomTranslate.GetTargetLanguage: string;
begin
  Result := FTargetLanguage;
end;

procedure TCustomTranslate.SetTargetLanguage(const Value: string);
begin
  if FTargetLanguage = Value then Exit;
  FTargetLanguage := Value;
  Changed;
end;

procedure TCustomTranslate.SetDetect(Value: TDetectSettings);
begin
  FDetect.Assign(Value);
end;

procedure TCustomTranslate.DetectChanged(Sender: TObject);
begin
  // Unload built-in profiles only when BuiltinDetect switches off. Loading is
  // deferred to DetectLanguageInternal because LFM applies sub-properties one
  // by one in file order, and Enabled may arrive before BuiltinDetect.
  if FLastBuiltinDetect and not FDetect.BuiltinDetect then
    UnloadDetectProfiles;
  FLastBuiltinDetect := FDetect.BuiltinDetect;

  // Force reload of detect engine INI on next use
  FLoadedDetectConfig := string.Empty;
  // Keep runtime proxy gate in sync with stored intent
  if Assigned(FDetectEngine) then
    FDetectEngine.AllowProxy := FDetect.AllowProxy and FDetectEngine.ServiceProxy;
end;

procedure TCustomTranslate.ProxyChanged(Sender: TObject);
begin
  if Assigned(FDetectEngine) then
    FDetectEngine.Proxy.Assign(FProxy);
end;

procedure TCustomTranslate.TimeoutChanged(Sender: TObject);
begin
  if Assigned(FDetectEngine) then
    FDetectEngine.Timeout.Assign(FTimeout);
end;

procedure TCustomTranslate.EnsureDetectEngine;
begin
  if FDetect.BuiltinDetect then Exit;
  if FDetect.ConfigFile = string.Empty then Exit;

  if not Assigned(FDetectEngine) then
  begin
    FDetectEngine := TTranslate.Create(Self);
    FDetectEngine.OnGetParameter := FOnGetParameter;
    FDetectEngine.UserParameters := FUserParameters;
    FDetectEngine.Proxy.Assign(FProxy);
    FDetectEngine.Timeout.Assign(FTimeout);
    FLoadedDetectConfig := string.Empty;
  end;

  if FLoadedDetectConfig <> FDetect.ConfigFile then
  begin
    if FileExists(FDetect.ConfigFile) then
    begin
      FDetectEngine.LoadIniSettings(FDetect.ConfigFile);
      FLoadedDetectConfig := FDetect.ConfigFile;
    end;
  end;

  // Re-apply proxy gate now that ServiceProxy is known from INI
  FDetectEngine.AllowProxy := FDetect.AllowProxy and FDetectEngine.ServiceProxy;
end;

function TCustomTranslate.DetectLanguageInternal(const AText: string): string;
var
  Sample: string;
begin
  Result := string.Empty;

  if FDetect.BuiltinDetect then
  begin
    // Safety net: profiles are loaded on BuiltinDetect transitions, but
    // force-load here too in case the component was created with Builtin=True
    LoadDetectProfiles;
    Sample := AText.ExtractTextSample;
    Result := DetectLanguage(Sample, FSourceLanguage);
  end
  else
  begin
    if FDetect.ConfigFile = string.Empty then Exit;

    EnsureDetectEngine;
    if not Assigned(FDetectEngine) then Exit;

    Sample := AText.ExtractTextSample;
    FDetectEngine.SourceLanguage := FSourceLanguage;
    FDetectEngine.TargetLanguage := FTargetLanguage;
    FDetectEngine.TextToTranslate := Sample;
    // Synchronous fetch from the current worker thread, no nested thread
    Result := Trim(FDetectEngine.Translate);
  end;

  Result := NormalizeLanguageCode(LowerCase(Result));
end;

function TCustomTranslate.AnalyzeLanguage(const AText: string): TLanguageDetectResult;
var
  LangSrc, LangTar, LangDetect, LangPrimary, LangSecondary: string;
  NewSrcCode, NewTarCode: string;
  NeedSrcChange, NeedTarChange: boolean;
begin
  Result := Default(TLanguageDetectResult);
  Result.OldSource := FSourceLanguage;
  Result.OldTarget := FTargetLanguage;
  Result.Action := ldaNone;

  if FCancelled then Exit;
  if not FDetect.Enabled then Exit;

  LangDetect := DetectLanguageInternal(AText);
  if FCancelled then Exit;
  if (LangDetect = string.Empty) or (Length(LangDetect) > 5) or (LangDetect = UNKNOWN) then Exit;

  Result.DetectedLanguage := LangDetect;

  LangSrc := LowerCase(FSourceLanguage);
  LangTar := LowerCase(FTargetLanguage);
  LangPrimary := LowerCase(FDetect.PrimaryLanguage);
  LangSecondary := LowerCase(FDetect.SecondaryLanguage);

  NewSrcCode := string.Empty;
  NewTarCode := string.Empty;
  NeedSrcChange := False;
  NeedTarChange := False;

  if not FDetect.SmartSwap then
  begin
    // Ordinary swap
    if ((LangSrc = LangDetect) or (LangTar = LangDetect)) and (not TLanguages.IsSpecialCode(LangSrc)) and
      (not TLanguages.IsSpecialCode(LangTar)) then
    begin
      if FDetect.AutoSwap and (LangTar = LangDetect) then
      begin
        Result.Action := ldaSwap;
        Result.NewSource := FTargetLanguage;
        Result.NewTarget := FSourceLanguage;
      end;
    end;
  end
  else
  begin
    // Smart swap
    if ((LangSrc = LangDetect) or (LangTar = LangDetect)) and (not TLanguages.IsSpecialCode(LangSrc)) and
      (not TLanguages.IsSpecialCode(LangTar)) and ((not FDetect.SmartHard) or
      (((LangSrc = LangPrimary) and (LangTar = LangSecondary)) or ((LangSrc = LangSecondary) and (LangTar = LangPrimary)))) then
    begin
      if FDetect.AutoSwap and (LangTar = LangDetect) then
      begin
        Result.Action := ldaSwap;
        Result.NewSource := FTargetLanguage;
        Result.NewTarget := FSourceLanguage;
      end;
    end
    else
    begin
      if (LangSrc <> LangDetect) or TLanguages.IsSpecialCode(LangSrc) then
      begin
        if LangDetect = LangPrimary then
        begin
          if (LangSrc <> LangPrimary) and (not TLanguages.IsSpecialCode(LangSrc)) then
          begin
            NewSrcCode := FindLanguageCode(LangPrimary);
            NeedSrcChange := NewSrcCode <> string.Empty;
          end;
          if (LangTar <> LangSecondary) and FDetect.SmartHard then
          begin
            NewTarCode := FindLanguageCode(LangSecondary);
            NeedTarChange := NewTarCode <> string.Empty;
          end;
        end
        else
        begin
          if (LangSrc <> LangDetect) and (not TLanguages.IsSpecialCode(LangSrc)) then
          begin
            NewSrcCode := FindLanguageCode(LangDetect);
            NeedSrcChange := NewSrcCode <> string.Empty;
          end;
          if (LangTar <> LangPrimary) and FDetect.SmartHard then
          begin
            NewTarCode := FindLanguageCode(LangPrimary);
            NeedTarChange := NewTarCode <> string.Empty;
          end;
        end;
      end;
    end;
  end;

  // Fill change fields only when a swap was not already selected
  if Result.Action = ldaNone then
  begin
    Result.NewSource := NewSrcCode;
    Result.NewTarget := NewTarCode;

    if NeedSrcChange and NeedTarChange then
      Result.Action := ldaChangeBoth
    else if NeedSrcChange then
      Result.Action := ldaChangeSource
    else if NeedTarChange then
      Result.Action := ldaChangeTarget;
  end;
end;

procedure TCustomTranslate.ApplyDetectResult(const AResult: TLanguageDetectResult);
begin
  case AResult.Action of
    ldaSwap, ldaChangeBoth:
    begin
      if AResult.NewSource <> string.Empty then
        FSourceLanguage := AResult.NewSource;
      if AResult.NewTarget <> string.Empty then
        FTargetLanguage := AResult.NewTarget;
    end;
    ldaChangeSource:
      if AResult.NewSource <> string.Empty then
        FSourceLanguage := AResult.NewSource;
    ldaChangeTarget:
      if AResult.NewTarget <> string.Empty then
        FTargetLanguage := AResult.NewTarget;
    ldaNone:
      ; // nothing to apply
  end;
end;

procedure TCustomTranslate.DoLanguageDetected;
begin
  if Assigned(FOnLanguageDetected) then
    FOnLanguageDetected(Self, FPendingDetectResult);
end;

procedure TCustomTranslate.FireLanguageDetected(const AResult: TLanguageDetectResult);
begin
  if not Assigned(FOnLanguageDetected) then Exit;
  FPendingDetectResult := AResult;
  // Detection runs inside the translate thread, so marshal the event to the main thread
  if TThread.CurrentThread.ThreadID <> MainThreadID then
    TThread.Synchronize(nil, @DoLanguageDetected)
  else
    DoLanguageDetected;
end;

function TCustomTranslate.FindLanguageCode(const ALangCode: string): string;
var
  Idx: integer;
begin
  Result := string.Empty;
  Idx := Languages.IndexOfNameIgnoreCase(ALangCode);
  if Idx >= 0 then
    Result := Languages.Names[Idx];
end;

function TCustomTranslate.ShouldAutoDetect(ADetectLanguage: boolean): boolean;
begin
  Result := ADetectLanguage and FDetect.Enabled and not FCancelled;
end;

{ Protected }

procedure TCustomTranslate.Changed;
begin
  if Assigned(FOnChange) then
    FOnChange(Self);
end;

{ Public }

constructor TCustomTranslate.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FServiceName := 'default';
  FServiceIcon := string.Empty;
  FServiceColorRecent := clBlue;
  FServiceVisible := True;
  FServiceAutoSwap := False;
  FServiceRealTime := False;
  FServiceOnlyButton := False;
  FWebMethod := wmGet;
  FUserAgent := 'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:148.0) Gecko/20100101 Firefox/148.0';
  FHeaders := TStringList.Create;
  FHeaders.Duplicates := dupAccept;
  FHeaders.TrailingLineBreak := False;
  FHeaders.SkipLastLineBreak := True;
  FCustomParameters := TStringList.Create;
  FCustomParameters.TrailingLineBreak := False;
  FCustomParameters.SkipLastLineBreak := True;
  FScriptParameters := TStringList.Create;
  FScriptParameters.TrailingLineBreak := False;
  FScriptParameters.SkipLastLineBreak := True;
  FScriptResponse := TStringList.Create;
  FScriptResponse.TrailingLineBreak := False;
  FScriptResponse.SkipLastLineBreak := True;
  FServiceDescription := TStringList.Create;
  FServiceDescription.TrailingLineBreak := False;
  FServiceDescription.SkipLastLineBreak := True;
  FEncodeText := True;
  FMaxLength := 0;
  FUrl := string.Empty;
  FContentType := 'application/json';
  FPostData := string.Empty;
  FAccept := 'application/json';
  FJsonPointer := '/0/*/0';
  FRegexp := string.Empty;
  FLanguages := TStringList.Create;
  FLanguages.TrailingLineBreak := False;
  FLanguages.SkipLastLineBreak := True;
  FLanguagesTarget := TStringList.Create;
  FLanguagesTarget.TrailingLineBreak := False;
  FLanguagesTarget.SkipLastLineBreak := True;
  FLanguagesOriginal := TStringList.Create;
  FLanguagesOriginal.TrailingLineBreak := False;
  FLanguagesOriginal.SkipLastLineBreak := True;
  FLanguagesTargetOriginal := TStringList.Create;
  FLanguagesTargetOriginal.TrailingLineBreak := False;
  FLanguagesTargetOriginal.SkipLastLineBreak := True;
  FLangType := vtLanguage;

  FInitUserAgent := 'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:148.0) Gecko/20100101 Firefox/148.0';
  FInitHeaders := TStringList.Create;
  FInitHeaders.TrailingLineBreak := False;
  FInitHeaders.SkipLastLineBreak := True;
  FInitUrl := string.Empty;
  FInitParameters := TStringList.Create;
  FInitParameters.TrailingLineBreak := False;
  FInitParameters.SkipLastLineBreak := True;
  FParameterValues := TStringList.Create;
  FParameterValues.TrailingLineBreak := False;
  FParameterValues.SkipLastLineBreak := True;
  FParameterEncode := TStringList.Create;
  FParameterEncode.TrailingLineBreak := False;
  FParameterEncode.SkipLastLineBreak := True;
  FInitLiveTime := 60;
  FAllowProxy := True;

  FSourceLanguage := DEFAULT_LANG;
  FTargetLanguage := Language;
  FCookies := TStringList.Create;
  FCurrentHTTP := nil;
  FHTTPList := TList.Create;

  // Thread management
  FActiveThreads := TList.Create;
  FTranslateThread := nil;
  FCancelled := False;
  FRawTranslate := string.Empty;
  FConfigFile := string.Empty;
  FProfilesLoaded := False;
  FProxy := TTranslateProxy.Create;
  FProxy.OnChange := @ProxyChanged;
  FProxy.Mode := pmNone;
  FProxy.Type_ := ptHTTP;
  FTimeout := TTranslateTimeout.Create;
  FTimeout.OnChange := @TimeoutChanged;
  FTimeout.Connection := CONNECT_TIMEOUT;
  FTimeout.Request := REQUEST_TIMEOUT;

  // Nested detection settings
  FDetect := TDetectSettings.Create;
  FDetect.OnChange := @DetectChanged;

  // Detect engine is created lazily only when an INI config is used
  FDetectEngine := nil;
  FLoadedDetectConfig := string.Empty;
  FLastBuiltinDetect := FDetect.BuiltinDetect;
  FOnLanguageDetected := nil;
  FPendingDetectResult := Default(TLanguageDetectResult);

  FOnTranslateStart := nil;
  FOnTranslateComplete := nil;
  FOnTranslateFinish := nil;
  FOnChange := nil;
end;

destructor TCustomTranslate.Destroy;
var
  TotalDeadline: DWORD;
  i: integer;
  Th: TTranslateThread;
begin
  // Wait for all translation threads with the configured global timeout
  if Assigned(FActiveThreads) then
  begin
    TotalDeadline := TOS.GetTickCountXp + DWORD(THREADS_WAIT_TIME);
    repeat
      // Sweep finished threads from the end
      i := FActiveThreads.Count - 1;
      while i >= 0 do
      begin
        Th := TTranslateThread(FActiveThreads[i]);
        if not Assigned(Th) or Th.Finished then
          FActiveThreads.Delete(i);
        Dec(i);
      end;

      if FActiveThreads.Count = 0 then Break;
      if TOS.GetTickCountXp >= TotalDeadline then
      begin
        {$IFDEF DEBUG}
          UseHeapTrace := False;
        {$ENDIF}
        Break;
      end;

      // Keep the message loop alive so threads can post Synchronize calls
      Application.ProcessMessages;
      Sleep(1);
    until False;

    FreeAndNil(FActiveThreads);
  end;

  FreeAndNil(FCookies);
  FreeAndNil(FHeaders);
  FreeAndNil(FCustomParameters);
  FreeAndNil(FScriptParameters);
  FreeAndNil(FScriptResponse);
  FreeAndNil(FServiceDescription);
  FreeAndNil(FLanguages);
  FreeAndNil(FLanguagesTarget);
  FreeAndNil(FLanguagesOriginal);
  FreeAndNil(FLanguagesTargetOriginal);
  AbortRequest;
  FreeAndNil(FHTTPList);
  SetLength(FLanguageCodes, 0);
  FLanguageCodes := nil;

  FInitHeaders.Free;
  FInitParameters.Free;
  FParameterValues.Free;
  FParameterEncode.Free;
  FreeAndNil(FProxy);
  FreeAndNil(FTimeout);
  FreeAndNil(FDetectEngine);
  FreeAndNil(FDetect);
  inherited Destroy;
end;

procedure TCustomTranslate.Clear;
begin
  FServiceName := string.Empty;
  FServiceIcon := string.Empty;
  FServiceOrder := 0;
  FServiceVisible := True;
  FServiceAutoSwap := False;
  FServiceRealTime := False;
  FServiceOnlyButton := False;
  FServiceProxy := True;
  FAllowProxy := True;
  FProxy.FromProxy(Default(TProxy));
  FServiceColorRecent := clBlue;
  FServiceDescription.Clear;
  FWebMethod := wmGet;
  FUserAgent := string.Empty;
  FHeaders.Clear;
  FEncodeText := False;
  FMaxLength := 0;
  FUrl := string.Empty;
  FContentType := string.Empty;
  FPostData := string.Empty;
  FAccept := string.Empty;
  FJsonPointer := string.Empty;
  FEncodeCustomParameters := False;
  FCustomParameters.Clear;
  FScriptParameters.Clear;
  FScriptResponse.Clear;
  FLangType := vtNone;
  FLanguages.Clear;
  FLanguagesTarget.Clear;
  FLanguagesOriginal.Clear;
  FLanguagesTargetOriginal.Clear;
  FInitUserAgent := string.Empty;
  FInitHeaders.Clear;
  FInitUrl := string.Empty;
  FInitParameters.Clear;
  FInitLiveTime := 0;
  FServiceIcon := string.Empty;
end;

procedure TCustomTranslate.AbortRequest;
var
  i: integer;
  HTTP: THTTPSend;
begin
  if not Assigned(FHTTPList) then Exit;

  for i := 0 to FHTTPList.Count - 1 do
  begin
    HTTP := THTTPSend(FHTTPList[i]);
    if Assigned(HTTP) then
    begin
      HTTP.Sock.StopFlag := True;
      HTTP.Sock.AbortSocket;
    end;
  end;
  FHTTPList.Clear;
end;

procedure TCustomTranslate.ExecuteParametersScript;
var
  Runner: TScriptRunner;
  i: integer;
begin
  if FScriptParameters.Count = 0 then Exit;

  // 1. Create the script runner instance
  Runner := TScriptRunner.Create;
  try
    // 2. Load the script source
    Runner.LoadScript(FScriptParameters);

    // 3. Pass input parameters
    Runner.Params.Assign(FParameterValues);

    // 4. Compile and run the script
    Runner.Execute;   // automatically compiles if needed

    // 5. Retrieve all outputs in a loop
    for i := 0 to Runner.OutputList.Count - 1 do
      FParameterValues.Values[Runner.OutputList.Names[i]] := Runner.OutputList.ValueFromIndex[i];
  finally
    Runner.Free;
  end;
end;

procedure TCustomTranslate.ExecuteResponseScript(var Response: string);
var
  Runner: TScriptRunner;
begin
  if FScriptResponse.Count = 0 then Exit;

  // 1. Create the script runner instance
  Runner := TScriptRunner.Create;
  try
    // 2. Load the script source
    Runner.LoadScript(FScriptResponse);

    // 3. Pass input parameters
    Runner.Params.Assign(FParameterValues);
    Runner.Params.Values['result'] := Response;

    // 4. Compile and run the script
    Runner.Execute;   // automatically compiles if needed

    // 5. Retrieve output Result
    if Runner.OutputList.ContainsName('result') then
      Response := Runner.OutputList.Values['result'];
  finally
    Runner.Free;
  end;
end;

function TCustomTranslate.GetParameters(Data: string): boolean;
var
  i: integer;
  ParamName: string;
  RegExpStr: string;
  R: TRegExpr;
  Value: string;
  FullRandom: int64;
begin
  Result := True;

  // User parameters {key=value} supplied by the host
  if Assigned(FUserParameters) and (FUserParameters.Count > 0) then
  begin
    for i := 0 to FUserParameters.Count - 1 do
    begin
      ParamName := FUserParameters.Names[i];
      Value := FUserParameters.ValueFromIndex[i];

      // Skip empty parameters
      if (ParamName = string.Empty) or (Value = string.Empty) then
        Continue;

      // Add or override parameter
      FParameterValues.Values[ParamName] := Value;
      FParameterEncode.Values[ParamName] := ifthen(FEncodeCustomParameters, '1', '0');
    end;
  end;

  // Custom parameters (key=value)
  if Assigned(FCustomParameters) then
  begin
    for i := 0 to FCustomParameters.Count - 1 do
    begin
      ParamName := FCustomParameters.Names[i];
      Value := FCustomParameters.ValueFromIndex[i];

      if Trim(Value) = string.Empty then
      begin
        // Store parameters in fields of the current class
        Self.FParamName := ParamName;

        // Synchronize using the current thread context
        TThread.Synchronize(TThread.CurrentThread, @Self.SyncGetParameterValue);
        if Application.Terminated then Exit;

        // Get the result
        Result := FResultOk;
        Value := Self.FResultValue;
      end;

      // Skip empty keys
      if ParamName = string.Empty then
        Continue;

      // Add or override parameter
      FParameterValues.Values[ParamName] := Value;
      FParameterEncode.Values[ParamName] := ifthen(FEncodeCustomParameters, '1', '0');
    end;
  end;

  FIsTruncated := False;
  if FTextToTranslate <> string.Empty then
  begin
    if (FMaxLength > 0) then
    begin
      FParameterValues.Values['text'] := FTextToTranslate.Utf8TruncateWithEncoding(FMaxLength, FEncodeText);
      FIsTruncated := Length(FParameterValues.Values['text']) < Length(FTextToTranslate);
    end
    else
      FParameterValues.Values['text'] := FTextToTranslate;
  end
  else
    FParameterValues.Values['text'] := string.Empty;
  FParameterEncode.Values['text'] := ifthen(FEncodeText, '1', '0');

  FParameterValues.Values['source'] := ifthen(FSourceLanguage = EMPTY_LANG, string.Empty, FSourceLanguage);
  FParameterValues.Values['target'] := FTargetLanguage;

  // TimeStamp
  FParameterValues.Values['timestamp'] := TOS.GetTimestamp.ToString;

  // Random
  FullRandom := TOS.GetRandom(9);
  FParameterValues.Values['random'] := FullRandom.ToString;
  FParameterValues.Values['rand'] := FullRandom.ToString;
  for i := 1 to Length(FullRandom.ToString) do
    FParameterValues.Values['rand' + IntToStr(i)] := Copy(FullRandom.ToString, 1, i);

  // Extract additional parameters using regex
  if Assigned(FInitParameters) and (Data <> string.Empty) and (SecondsBetween(Now, FParametersAge) >= FInitLiveTime) then
  begin
    R := TRegExpr.Create;
    try
      for i := 0 to FInitParameters.Count - 1 do
      begin
        ParamName := FInitParameters.Names[i];
        RegExpStr := FInitParameters.ValueFromIndex[i];

        R.Expression := RegExpStr;

        if R.Exec(Data) then
        begin
          // Use first captured group if exists, otherwise full match
          if R.SubExprMatchCount >= 1 then
            Value := R.Match[1]
          else
            Value := R.Match[0];

          // Only add parameter if value is not empty
          if Value <> string.Empty then
            FParameterValues.Values[ParamName] := Value;
        end;
      end;
    finally
      R.Free;
      FParametersAge := Now;
    end;
  end;

  // ScriptParameters
  ExecuteParametersScript;
end;

function TCustomTranslate.SetParameters(Data: string; IncludeSet: boolean = True): string;
var
  i: integer;
  ParamName: string;
  ParamValue: string;

  function Encode(AName, AValue: string): string;
  begin
    if (ParameterEncode.IndexOfName(AName) <> -1) then
    begin
      if (ParameterEncode.Values[AName] = '1') then
        Result := AValue.EncodeURLElement
      else
        Result := AValue.EscapeText;
    end
    else
      Result := AValue;
  end;

begin
  Result := Data;

  if not Assigned(FParameterValues) then
    Exit;

  for i := 0 to FParameterValues.Count - 1 do
  begin
    ParamName := FParameterValues.Names[i];
    ParamValue := FParameterValues.ValueFromIndex[i].RemoveTrailingLineBreak;

    if IncludeSet and (Pos('{', ParamValue) > 0) and (Pos('}', ParamValue) > 0) then
      ParamValue := SetParameters(ParamValue, False);

    // Replace all occurrences of {name} with value
    Result := StringReplace(Result, '{' + ParamName + '}', Encode(ParamName, ParamValue), [rfReplaceAll]);

    // lowercase {!param}
    Result := StringReplace(Result, '{!' + ParamName + '}', Encode(ParamName, UTF8LowerCase(ParamValue)), [rfReplaceAll]);

    // UPPERCASE {^param}
    Result := StringReplace(Result, '{^' + ParamName + '}', Encode(ParamName, UTF8UpperCase(ParamValue)), [rfReplaceAll]);
  end;
end;

procedure TCustomTranslate.SetParametersList(Strings: TStrings);
var
  i: integer;
begin
  if not Assigned(Strings) then Exit;

  for i := 0 to Strings.Count - 1 do
    Strings[i] := SetParameters(Strings[i]);
end;

function TCustomTranslate.GetInit: string;
var
  responseHeaders: TStringList;
  responseBody: string;
  i: integer;
  header: string;
  Error: boolean;
  localHTTP: THTTPSend;   // we will create and own the HTTP object
begin
  Result := string.Empty;
  if FInitUrl = string.Empty then Exit;
  if SecondsBetween(Now, FParametersAge) < FInitLiveTime then Exit;
  FParameterValues.Clear;
  FCookies.Clear;

  localHTTP := THTTPSend.Create;   // create new HTTP object
  FHTTPList.Add(localHTTP);        // add to list for abort
  FCurrentHTTP := localHTTP;       // allow external abort while the request is active
  try
    // Call overloaded WebRequest (caller takes ownership)
    responseBody := TNetwork.WebRequest(wmGet, FInitUrl, string.Empty, InitHeaders, FInitUserAgent,
      string.Empty, string.Empty, FAllowProxy, FProxy.ToProxy, FTimeout.ToTimeout, FCookies, responseHeaders, Error, localHTTP);

    if Error then Exit(responseBody);

    // Build header string from response headers
    header := string.Empty;
    for i := 0 to responseHeaders.Count - 1 do
      header := header + responseHeaders[i] + LineEnding;

    Result := header + LineEnding + responseBody;
  finally
    FHTTPList.Remove(localHTTP); // remove from abort list
    FreeAndNil(localHTTP);   // free HTTP object when done
    FCurrentHTTP := nil;   // clear abort reference
    responseHeaders.Free;
  end;
end;

function TCustomTranslate.Get(ReturnHeaders: boolean = False): string;
var
  responseHeaders: TStringList;
  responseBody: string;
  TempUrl: string;
  TempHeaders: TStringList;
  i: integer;
  header: string;
  Error: boolean;
  localHTTP: THTTPSend;
begin
  Result := string.Empty;
  if FUrl = string.Empty then exit;

  try
    if not GetParameters(GetInit) or Application.Terminated then
      Exit;

    TempUrl := FUrl;
    TempUrl := SetParameters(TempUrl);
    if (FSourceLanguage = EMPTY_LANG) or (FSourceLanguage = EMPTY_LANG) then
      TempUrl := TempUrl.RemoveEmptyParams;

    TempHeaders := nil;
    if Assigned(Headers) then
    begin
      TempHeaders := TStringList.Create;
      TempHeaders.Duplicates := dupAccept;
      TempHeaders.Assign(Headers);
      SetParametersList(TempHeaders);
    end;

    localHTTP := THTTPSend.Create;
    FHTTPList.Add(localHTTP);
    FCurrentHTTP := localHTTP;
    try
      responseBody := TNetwork.WebRequest(wmGet, TempUrl, string.Empty, TempHeaders, FUserAgent, FContentType,
        FAccept, FAllowProxy, FProxy.ToProxy, FTimeout.ToTimeout, FCookies, responseHeaders, Error, localHTTP);

      if Error then
      begin
        FCookies.Clear;
        FParametersAge := 0;
        Exit(responseBody);
      end;

      if ReturnHeaders then
      begin
        header := string.Empty;
        for i := 0 to responseHeaders.Count - 1 do
          header := header + responseHeaders[i] + LineEnding;
        Result := header + LineEnding + responseBody;
      end
      else
        Result := responseBody;
    finally
      FHTTPList.Remove(localHTTP);
      FreeAndNil(localHTTP);
      FCurrentHTTP := nil;
      TempHeaders.Free;
      responseHeaders.Free;
    end;
  except
    on E: Exception do
      Result := E.Message;
  end;
end;

function TCustomTranslate.Post(ReturnHeaders: boolean = False): string;
var
  responseHeaders: TStringList;
  responseBody: string;
  TempData: string;
  TempUrl: string;
  TempHeaders: TStringList;
  i: integer;
  header: string;
  Error: boolean;
  localHTTP: THTTPSend;
begin
  Result := string.Empty;
  if FUrl = string.Empty then exit;

  try
    if not GetParameters(GetInit) or Application.Terminated then
      Exit;

    TempUrl := FUrl;
    TempUrl := SetParameters(TempUrl);
    TempData := FPostData;
    TempData := SetParameters(TempData);

    if (FSourceLanguage = EMPTY_LANG) or (FSourceLanguage = EMPTY_LANG) then
    begin
      TempUrl := TempUrl.RemoveEmptyParams;
      TempData := TempData.RemoveEmptyParams;
    end;

    TempHeaders := nil;
    if Assigned(Headers) then
    begin
      TempHeaders := TStringList.Create;
      TempHeaders.Duplicates := dupAccept;
      TempHeaders.Assign(Headers);
      SetParametersList(TempHeaders);
    end;

    localHTTP := THTTPSend.Create;
    FHTTPList.Add(localHTTP);
    FCurrentHTTP := localHTTP;
    try
      responseBody := TNetwork.WebRequest(wmPost, TempUrl, TempData, TempHeaders, FUserAgent, FContentType,
        FAccept, FAllowProxy, FProxy.ToProxy, FTimeout.ToTimeout, FCookies, responseHeaders, Error, localHTTP);

      if Error then
      begin
        FCookies.Clear;
        FParametersAge := 0;
        Exit(responseBody);
      end;

      if ReturnHeaders then
      begin
        header := string.Empty;
        for i := 0 to responseHeaders.Count - 1 do
          header := header + responseHeaders[i] + LineEnding;
        Result := header + LineEnding + responseBody;
      end
      else
        Result := responseBody;
    finally
      FHTTPList.Remove(localHTTP);
      FreeAndNil(localHTTP);
      FCurrentHTTP := nil;
      TempHeaders.Free;
      responseHeaders.Free;
    end;
  except
    on E: Exception do
      Result := E.Message;
  end;
end;

function TCustomTranslate.ParseJsonByPointer(const JsonStr, JsonPointer: string): string;
var
  Data: TJSONData;

  function Traverse(Data: TJSONData; PathParts: TStringList; Level: integer): string;
  var
    Key: string;
    i: integer;
    Arr: TJSONArray;
    Obj: TJSONObject;
    SubResult: string;
    Child: TJSONData;
    ExtValue: extended;
  begin
    Result := string.Empty;
    if Data = nil then Exit;

    // --- NEW: Handle ~ (Return current branch as JSON string) ---
    if (Level < PathParts.Count) and (PathParts[Level] = '~') then
    begin
      Result := Data.AsJSON;
      Exit;
    end;

    // If we have reached the end of the path, return the value
    if Level >= PathParts.Count then
    begin
      case Data.JSONType of
        jtString:
          Result := Data.AsString;
        jtBoolean:
          Result := Data.AsString;
        jtNumber:
        begin
          ExtValue := TJSONNumber(Data).AsFloat; // get number as Extended
          Result := Format('%0.*g', [17, ExtValue]); // 17 digits precision
        end;
        jtArray:
        begin
          Arr := TJSONArray(Data);
          for i := 0 to Arr.Count - 1 do
          begin
            SubResult := Traverse(Arr.Items[i], PathParts, Level);
            if SubResult <> string.Empty then
            begin
              if Result <> string.Empty then
                Result := Result + #10;
              Result := Result + SubResult;
            end;
          end;
        end;
        // Return object as JSON if path ends on an object
        jtObject: Result := Data.AsJSON;
        else
          ;
      end;
      Exit;
    end;

    Key := PathParts[Level];

    // Decoding special characters JSON Pointer (RFC 6901)
    Key := StringReplace(Key, '~1', '/', [rfReplaceAll]);
    Key := StringReplace(Key, '~0', '~', [rfReplaceAll]);

    case Data.JSONType of
      jtObject:
      begin
        Obj := TJSONObject(Data);

        // 1. Processing Wildcard for an object (take all properties)
        if (Key = '*') or (Key = '*#10') then
        begin
          for i := 0 to Obj.Count - 1 do
          begin
            SubResult := Traverse(Obj.Items[i], PathParts, Level + 1);
            if SubResult <> string.Empty then
            begin
              if (Result <> string.Empty) and (Key = '*#10') then
                Result := Result + #10;
              Result := Result + SubResult;
            end;
          end;
        end
        else
        begin
          // 2. Search by key name
          Child := Obj.Find(Key);
          if Child <> nil then
            Result := Traverse(Child, PathParts, Level + 1)
          else
          begin
            // 3. If you can’t find it by name, try to interpret the key as an index
            i := StrToIntDef(Key, -1);
            if (i >= 0) and (i < Obj.Count) then
              Result := Traverse(Obj.Items[i], PathParts, Level + 1);
          end;
        end;
      end;

      jtArray:
      begin
        Arr := TJSONArray(Data);
        if (Key = '*') or (Key = '*#10') then
        begin
          for i := 0 to Arr.Count - 1 do
          begin
            SubResult := Traverse(Arr.Items[i], PathParts, Level + 1);
            if SubResult <> string.Empty then
            begin
              if (Result <> string.Empty) and (Key = '*#10') then
                Result := Result + #10;
              Result := Result + SubResult;
            end;
          end;
        end
        else
        begin
          i := StrToIntDef(Key, -1);
          if (i >= 0) and (i < Arr.Count) then
            Result := Traverse(Arr.Items[i], PathParts, Level + 1);
        end;
      end;
      else
        ;
    end;
  end;

var
  PathParts: TStringList;
begin
  Result := string.Empty;
  if Trim(JsonStr) = string.Empty then Exit;
  if (JsonPointer = '~') or (JsonPointer = '/~') then Exit(JsonStr);
  if not JsonStr.IsJson then Exit;

  PathParts := TStringList.Create;
  try
    PathParts.Delimiter := '/';
    PathParts.StrictDelimiter := True;
    PathParts.DelimitedText := JsonPointer;

    if (PathParts.Count > 0) and (PathParts[0] = string.Empty) then
      PathParts.Delete(0);

    // Root-level dump if pointer is just "~"
    if (PathParts.Count = 1) and (PathParts[0] = '~') then
    begin
      Result := JsonStr;
      Exit;
    end;

    try
      Data := fpjson.GetJSON(JsonStr);
      try
        Result := Traverse(Data, PathParts, 0);
      finally
        Data.Free;
      end;
    except
      Result := string.Empty;
    end;
  finally
    PathParts.Free;
  end;
end;

function TCustomTranslate.ParseResponse(content: string): string;
const
  // A unique marker that will not appear in user data.
  // Used to temporarily escape literal '#10' substrings in extracted data
  // so they are not converted to newline characters by the template substitution.
  TEMP_NL_MARKER = '<!--#1#0-->';
var
  Segments: TStringList;
  regex: TRegExpr;
  i, j, k, pStart, pEnd, innerStart, innerEnd, OpenBrackets, SlashPos: integer;
  rStart, rEnd: integer;
  MatchResPart: string;
  Segment, FinalResult, PointerPath, PointerValue: string;
  BlockContent, InnerBlock, MatchRes, MatchGlue, MatchIdxStr: string;
  PointerFound, IsInverted, HasAnyRegex, HasAnyMatch: boolean;
  MatchIdx, CurrentIdx: integer;
  Expr: string; // Pre-processed expression (comments removed)
begin
  Result := string.Empty;
  if (Trim(content) = string.Empty) then Exit;
  if (JsonPointer = string.Empty) then Exit;

  // Remove /* comments */ only if a closing tag exists
  Expr := JsonPointer;

  // Optimization: Quick check if both start and end markers even exist
  if (Pos('/*', Expr) > 0) and (Pos('*/', Expr) > 0) then
  begin
    j := 1;
    while j < Length(Expr) do
    begin
      // Check for "/*" starting sequence
      if (Expr[j] = '/') and (Expr[j + 1] = '*') then
      begin
        pStart := j;
        pEnd := j + 2;
        PointerFound := False; // Reuse existing boolean to flag if closing '*/' is found

        // Look for closing "*/"
        while pEnd < Length(Expr) do
        begin
          if (Expr[pEnd] = '*') and (Expr[pEnd + 1] = '/') then
          begin
            PointerFound := True;
            Break;
          end;
          Inc(pEnd);
        end;

        if PointerFound then
        begin
          // If closed, delete the whole block including markers
          Delete(Expr, pStart, (pEnd + 2) - pStart);
          // Do not increment j, check the new character at this position
          Continue;
        end;
      end;
      Inc(j);
    end;
  end;

  Segments := TStringList.Create;
  regex := TRegExpr.Create;
  regex.ModifierStr := 'is';
  FinalResult := string.Empty;
  try
    Segments.Delimiter := ';';
    Segments.StrictDelimiter := True;
    Segments.DelimitedText := Expr;

    for i := 0 to Segments.Count - 1 do
    begin
      Segment := Trim(Segments[i]);
      if Segment = string.Empty then Continue;

      PointerPath := string.Empty;
      PointerValue := string.Empty;
      PointerFound := False;
      IsInverted := False;
      SlashPos := 0;

      // 1 & 2. Segment Scan
      OpenBrackets := 0;
      j := 1;
      while j <= Length(Segment) do
      begin
        if Segment[j] = '{' then Inc(OpenBrackets)
        else if Segment[j] = '}' then Dec(OpenBrackets)
        else if (OpenBrackets = 0) then
        begin
          if Segment[j] = '!' then
          begin
            IsInverted := True;
            Delete(Segment, j, 1);
            Continue;
          end;
          if (SlashPos = 0) and ((Segment[j] = '/') or (Segment[j] = '~')) then
            SlashPos := j;
        end;
        Inc(j);
      end;

      // 3. Pointer processing
      if SlashPos > 0 then
      begin
        pEnd := SlashPos;
        while (pEnd <= Length(Segment)) and (Segment[pEnd] <> '{') do Inc(pEnd);
        PointerPath := Trim(Copy(Segment, SlashPos, pEnd - SlashPos));

        if PointerPath = '~' then
          PointerValue := content
        else
        begin
          PointerValue := ParseJsonByPointer(content, PointerPath);
          PointerValue := PointerValue.HTTPDecode.UnescapeUnicode;
        end;

        // Temporarily replace literal '#10' in the extracted data with a unique marker.
        // This prevents the final '#10' -> newline substitution from altering user data.
        PointerValue := StringReplace(PointerValue, '#10', TEMP_NL_MARKER, [rfReplaceAll]);

        if IsInverted then
        begin
          if PointerValue <> string.Empty then
          begin
            Segment := string.Empty; // Hide whole segment if data exists
            PointerValue := string.Empty;
          end
          else
            PointerValue := ' '; // Satisfaction of !
        end;

        if (not IsInverted) and (PointerValue = string.Empty) then
          Segment := string.Empty;

        PointerFound := (PointerPath <> string.Empty);
      end;

      // 4. Block processing
      if Segment <> string.Empty then
      begin
        k := 1;
        while k <= Length(Segment) do
        begin
          if Segment[k] = '{' then
          begin
            pStart := k;
            pEnd := k + 1;
            OpenBrackets := 1;
            while (pEnd <= Length(Segment)) and (OpenBrackets > 0) do
            begin
              if Segment[pEnd] = '{' then Inc(OpenBrackets)
              else if Segment[pEnd] = '}' then Dec(OpenBrackets);
              if OpenBrackets > 0 then Inc(pEnd);
            end;

            if (pEnd <= Length(Segment)) and (Segment[pEnd] = '}') then
            begin
              BlockContent := Copy(Segment, pStart + 1, pEnd - pStart - 1);
              HasAnyRegex := False;
              HasAnyMatch := False;

              innerStart := 1;
              while innerStart <= Length(BlockContent) do
              begin
                if BlockContent[innerStart] = '{' then
                begin
                  innerEnd := innerStart + 1;
                  OpenBrackets := 1;
                  while (innerEnd <= Length(BlockContent)) and (OpenBrackets > 0) do
                  begin
                    if BlockContent[innerEnd] = '{' then Inc(OpenBrackets)
                    else if BlockContent[innerEnd] = '}' then Dec(OpenBrackets);
                    if OpenBrackets > 0 then Inc(innerEnd);
                  end;

                  if (innerEnd <= Length(BlockContent)) and (BlockContent[innerEnd] = '}') then
                  begin
                    InnerBlock := Copy(BlockContent, innerStart + 1, innerEnd - innerStart - 1);
                    MatchRes := string.Empty;

                    if InnerBlock = '~' then
                    begin
                      MatchRes := content;
                      HasAnyMatch := True;
                    end
                    else
                    begin
                      HasAnyRegex := True;
                      MatchGlue := string.Empty;
                      MatchIdx := -1;

                      if (Length(InnerBlock) > 2) and (InnerBlock[Length(InnerBlock)] = ']') then
                      begin
                        rEnd := Length(InnerBlock) - 1;
                        rStart := rEnd;
                        while (rStart > 1) and (InnerBlock[rStart] <> '[') do Dec(rStart);

                        if (InnerBlock[rStart] = '[') and (InnerBlock[rStart - 1] <> '\') then
                        begin
                          MatchIdxStr := Copy(InnerBlock, rStart + 1, rEnd - rStart);
                          PointerFound := False;
                          if MatchIdxStr = '*' then
                          begin
                            MatchGlue := ' ';
                            PointerFound := True;
                          end
                          else if MatchIdxStr = '*#10' then
                          begin
                            MatchGlue := #10;
                            PointerFound := True;
                          end
                          else if TryStrToInt(MatchIdxStr, MatchIdx) then PointerFound := True;

                          if PointerFound then InnerBlock := Copy(InnerBlock, 1, rStart - 1);
                          PointerFound := (PointerPath <> string.Empty); // Restore state
                        end;
                      end;

                      try
                        regex.Expression := InnerBlock;
                        CurrentIdx := 0;
                        if regex.Exec(content) then
                        begin
                          HasAnyMatch := True;
                          repeat
                            if regex.SubExprMatchCount > 0 then MatchResPart := regex.Match[1]
                            else
                              MatchResPart := regex.Match[0];

                            if MatchIdx <> -1 then
                            begin
                              if CurrentIdx = MatchIdx then
                              begin
                                MatchRes := MatchResPart;
                                Break;
                              end;
                            end
                            else
                            begin
                              if MatchRes <> string.Empty then MatchRes := MatchRes + MatchGlue;
                              MatchRes := MatchRes + MatchResPart;
                              if MatchGlue = string.Empty then Break;
                            end;
                            Inc(CurrentIdx);
                          until not regex.ExecNext;
                        end;
                      except
                        on E: Exception do
                        begin
                          MatchRes := REGEXP_ERROR + E.Message;
                          HasAnyMatch := True;
                        end;
                      end;
                    end;

                    MatchRes := MatchRes.HTTPDecode.UnescapeUnicode;
                    // Temporarily replace literal '#10' in extracted match data
                    // with a unique marker to prevent corruption during final substitution.
                    MatchRes := StringReplace(MatchRes, '#10', TEMP_NL_MARKER, [rfReplaceAll]);

                    Delete(BlockContent, innerStart, innerEnd - innerStart + 1);
                    Insert(MatchRes, BlockContent, innerStart);
                    innerStart := innerStart + Length(MatchRes);
                    Continue;
                  end;
                end;
                Inc(innerStart);
              end;

              if HasAnyRegex and not HasAnyMatch then BlockContent := string.Empty;

              Delete(Segment, pStart, pEnd - pStart + 1);
              if BlockContent <> string.Empty then
              begin
                Insert(BlockContent, Segment, pStart);
                k := pStart + Length(BlockContent);
              end
              else
                k := pStart;
            end
            else
              Inc(k);
          end
          else
            Inc(k);
        end;
      end;

      // Replace the pointer path with the actual data value (now containing markers instead of #10)
      if (PointerPath <> string.Empty) and (Segment <> string.Empty) then
        Segment := StringReplace(Segment, PointerPath, PointerValue, [rfReplaceAll]);

      // Convert all remaining (template-only) '#10' sequences to actual newline characters.
      Segment := StringReplace(Segment, '#10', #10, [rfReplaceAll]);
      FinalResult := FinalResult + Segment;
    end;

    // Restore literal '#10' that came from user data (currently stored as the marker)
    FinalResult := StringReplace(FinalResult, TEMP_NL_MARKER, '#10', [rfReplaceAll]);
    Result := FinalResult;
  finally
    Segments.Free;
    regex.Free;
  end;
end;

function TCustomTranslate.CleanTranslatedText(const OriginalText, TranslatedText: string): string;
var
  i, Start: integer;
  EntityStr: string;
  DecodedChar: string;
  TagWasReplaced: boolean;
begin
  // Quick exit if the translated text contains no markers that need processing
  if (Pos('&', TranslatedText) = 0) and (Pos('<', TranslatedText) = 0) then
  begin
    Result := TranslatedText;
    Exit;
  end;

  Result := '';
  i := 1;
  while i <= Length(TranslatedText) do
  begin
    // Check for <br> tag (case insensitive)
    if (TranslatedText[i] = '<') and (i + 3 <= Length(TranslatedText)) and (LowerCase(Copy(TranslatedText, i, 4)) = '<br>') then
    begin
      TagWasReplaced := Pos('<br>', OriginalText) = 0;
      if TagWasReplaced then
        Result := Result + LineEnding
      else
        Result := Result + '<br>';
      Inc(i, 4);
      // If we replaced the tag with a newline, skip the following space if present
      if TagWasReplaced and (i <= Length(TranslatedText)) and (TranslatedText[i] = ' ') then
        Inc(i);
    end
    // Check for <br/> tag (case insensitive)
    else if (TranslatedText[i] = '<') and (i + 5 <= Length(TranslatedText)) and (LowerCase(Copy(TranslatedText, i, 5)) = '<br/>') then
    begin
      TagWasReplaced := Pos('<br/>', OriginalText) = 0;
      if TagWasReplaced then
        Result := Result + LineEnding
      else
        Result := Result + '<br/>';
      Inc(i, 5);
      // If we replaced the tag with a newline, skip the following space if present
      if TagWasReplaced and (i <= Length(TranslatedText)) and (TranslatedText[i] = ' ') then
        Inc(i);
    end
    // Handle HTML entities starting with '&'
    else if TranslatedText[i] = '&' then
    begin
      Start := i;
      // Find the closing semicolon
      while (i <= Length(TranslatedText)) and (TranslatedText[i] <> ';') do
        Inc(i);
      if (i <= Length(TranslatedText)) and (TranslatedText[i] = ';') then
      begin
        EntityStr := Copy(TranslatedText, Start, i - Start + 1);
        if Pos(EntityStr, OriginalText) > 0 then
        begin
          // Keep the entity if it existed in original text
          Result := Result + EntityStr;
        end
        else
        begin
          // Try to decode the entity using the string helper
          DecodedChar := EntityStr.DecodeHtmlEntity;
          if DecodedChar <> '' then
            Result := Result + DecodedChar
          else
            // Unknown entity, keep it as is
            Result := Result + EntityStr;
        end;
        Inc(i); // move past the semicolon
      end
      else
      begin
        // No closing semicolon found, copy the '&' and continue
        Result := Result + TranslatedText[Start];
        i := Start + 1;
      end;
    end
    else
    begin
      Result := Result + TranslatedText[i];
      Inc(i);
    end;
  end;
end;

function TCustomTranslate.Translate: string;
var
  content: string;
  temp: string;
begin
  Result := string.Empty;

  if FWebMethod = wmPost then
    content := Post
  else
    content := Get;

  if content <> string.Empty then
  begin
    // Workaround for an FPC 3.2.2 fpjson bug when parsing consecutive \u200B sequences.
    content := StringReplace(content, '\u200b', string.Empty, [rfReplaceAll, rfIgnoreCase]);

    Result := ParseResponse(content);
  end;

  if (Trim(Result) = string.Empty) then
    content.TryFormatJson(Result)
  else
  begin
    Temp := Result;
    // Replace HTML codes (entities and <br>) with actual characters only if they were absent in the original text
    if not Temp.TryFormatJson(Result) then
    begin
      Result := CleanTranslatedText(FTextToTranslate, Result);

      if FIsTruncated then Result := Result + '...';
    end;
  end;

  // Execute response handle script
  ExecuteResponseScript(Result);
  Temp := Result.PreserveIndentation(FTextToTranslate);
  Temp.TryFormatJson(Result);
end;

function TCustomTranslate.TranslateSync(const AText: string; ADetectLanguage: boolean = True): string;
var
  Th: TTranslateThread;
  ThDone: boolean;
begin
  Result := string.Empty;

  // Already cancelled before we started - notify finish so the host can restore UI
  if FCancelled then
  begin
    if Assigned(FOnTranslateFinish) then FOnTranslateFinish(Self);
    Exit;
  end;

  // Ensure any previous translation is fully stopped and cleaned up
  if Assigned(FTranslateThread) then CancelTranslate;

  try
    FCancelled := False;
    FTextToTranslate := AText;
    FRawTranslate := string.Empty;
    ThDone := False;

    Th := TTranslateThread.Create(Self, @FRawTranslate, @ThDone, ADetectLanguage);
    FTranslateThread := Th;
    FActiveThreads.Add(Th);

    if Assigned(FOnTranslateStart) then FOnTranslateStart(Self);

    Th.OnTerminate := @ThreadTerminated;
    Th.Start;
    try
      while Assigned(Th) and not ThDone do
      begin
        // Thread replaced or cancelled externally - abandon the local reference
        if FCancelled or (FTranslateThread <> Th) then
        begin
          Th := nil;
          Result := string.Empty;
          Break;
        end;
        Application.ProcessMessages;
        Sleep(1);
      end;

      // Result only if the thread was not cancelled and text is present
      if not FCancelled and (FRawTranslate.Trim <> string.Empty) then
      begin
        Result := FRawTranslate;
        if Assigned(FOnTranslateComplete) then FOnTranslateComplete(Self, Result);
      end;
    finally
      // Real removal happens in ThreadTerminated via OnTerminate
      Th := nil;
    end;
  finally
    if Assigned(FOnTranslateFinish) then FOnTranslateFinish(Self);
  end;
end;

procedure TCustomTranslate.TranslateAsync(const AText: string; ADetectLanguage: boolean = True);
begin
  // Already cancelled - just notify finish and return
  if FCancelled then
  begin
    if Assigned(FOnTranslateFinish) then FOnTranslateFinish(Self);
    Exit;
  end;

  // Cancel any previous async translation before starting a new one
  if Assigned(FTranslateThread) then CancelTranslate;

  FCancelled := False;
  FTextToTranslate := AText;
  FRawTranslate := string.Empty;

  FTranslateThread := TTranslateThread.Create(Self, @FRawTranslate, nil, ADetectLanguage);
  FActiveThreads.Add(FTranslateThread);

  if Assigned(FOnTranslateStart) then FOnTranslateStart(Self);

  FTranslateThread.OnTerminate := @ThreadTerminatedAsync;
  FTranslateThread.Start;
end;

function TCustomTranslate.IsTranslating: boolean;
begin
  Result := Assigned(FTranslateThread) and not FTranslateThread.Finished and not FTranslateThread.IsCancelled;
end;

procedure TCustomTranslate.CancelTranslate;
begin
  FCancelled := True;
  if Assigned(FTranslateThread) then
    FTranslateThread.Cancel;
end;

function TCustomTranslate.DetectLanguage(const AText: string; ACurrentLang: string; MinConfidence: double;
  AAllowedLangs: TStringArray; ASampleSize: integer): string;
var
  Allowed: TStringArray = nil;
  Source, CurrentLang, Sample: string;
begin
  // Fall back to the component's own language codes when caller omits them
  if Assigned(AAllowedLangs) then
    Allowed := AAllowedLangs
  else
    Allowed := FLanguageCodes;

  // Use the pending translation text when the caller passes nothing
  if AText <> string.Empty then
    Source := AText
  else
    Source := FTextToTranslate;

  // Use the current source language when the caller passes nothing
  if ACurrentLang <> string.Empty then
    CurrentLang := ACurrentLang
  else
    CurrentLang := FSourceLanguage;

  // Extract a shorter sample to speed up detection on long texts
  if ASampleSize > 0 then
    Sample := Source.ExtractTextSample(ASampleSize)
  else
    Sample := Source;

  Result := TLangDetect.DetectLanguageSafe(Sample, CurrentLang, MinConfidence, Allowed);
end;

function TCustomTranslate.NormalizeLanguageCode(const ACode: string): string;
begin
  Result := TLangDetect.NormalizeLanguageCode(ACode);
end;

procedure TCustomTranslate.LoadDetectProfiles;
begin
  if FProfilesLoaded then Exit;
  TLangDetect.LoadProfiles;
  FProfilesLoaded := True;
end;

procedure TCustomTranslate.UnloadDetectProfiles;
begin
  if not FProfilesLoaded then Exit;
  TLangDetect.UnloadProfiles;
  FProfilesLoaded := False;
end;

{%EndRegion}

{%Region -fold TTranslate Ini Config }

procedure TCustomTranslate.SaveIniSettings(AFileName: string);
var
  Ini: TMemIniFile;
  i: integer;
  PostDataEscaped: string;
begin
  Ini := TMemIniFile.Create(AFileName);
  try
    // { Service page }
    if Trim(ServiceName) <> string.Empty then
      Ini.WriteString('Service', 'Name', ServiceName)
    else
      Ini.DeleteKey('Service', 'Name');
    if Trim(ServiceIcon) <> string.Empty then
      Ini.WriteString('Service', 'Icon', ServiceIcon)
    else
      Ini.DeleteKey('Service', 'Icon');
    Ini.WriteInteger('Service', 'Order', ServiceOrder);
    Ini.WriteBool('Service', 'Visible', ServiceVisible);
    Ini.WriteBool('Service', 'AutoSwapLanguage', ServiceAutoSwap);
    Ini.WriteBool('Service', 'RealTimeTranslation', ServiceRealTime);
    Ini.WriteBool('Service', 'TranslateOnlyByButton', ServiceOnlyButton);
    Ini.WriteBool('Service', 'AllowProxy', ServiceProxy);
    Ini.WriteInteger('Service', 'ColorRecent', ServiceColorRecent);

    case LangType of
      vtNone: Ini.WriteString('Service', 'ValueType', 'None');
      vtLanguage: Ini.WriteString('Service', 'ValueType', 'Language');
      vtCurrencyAll: Ini.WriteString('Service', 'ValueType', 'CurrencyAll');
      vtCurrencyFiat: Ini.WriteString('Service', 'ValueType', 'CurrencyFiat');
      vtCurrencyCrypto: Ini.WriteString('Service', 'ValueType', 'CurrencyCrypto');
      vtUnit: Ini.WriteString('Service', 'ValueType', 'Unit');
      else
        ;
    end;

    // Save service description
    ClearSection(Ini, 'Service Description', not Assigned(ServiceDescription) or (ServiceDescription.Count = 0));
    if Assigned(ServiceDescription) then
      for i := 0 to ServiceDescription.Count - 1 do
        Ini.WriteString('Service Description',
          IntToStr(i), // key: 0,1,2...
          ServiceDescription[i]);

    // Request page
    if WebMethod = wmPost then
      Ini.WriteString('Request', 'Method', 'POST')
    else
      Ini.WriteString('Request', 'Method', 'GET');

    if Trim(UserAgent) <> string.Empty then
      Ini.WriteString('Request', 'UserAgent', UserAgent)
    else
      Ini.DeleteKey('Request', 'UserAgent');

    Ini.WriteBool('Request', 'EncodeText', EncodeText);
    Ini.WriteInteger('Request', 'MaxLength', MaxLength);

    if Trim(Url) <> string.Empty then
      Ini.WriteString('Request', 'Url', Url)
    else
      Ini.DeleteKey('Request', 'Url');

    if Trim(ContentType) <> string.Empty then
      Ini.WriteString('Request', 'ContentType', ContentType)
    else
      Ini.DeleteKey('Request', 'ContentType');

    // Replace line breaks with \r\n for single-line storage
    if Trim(PostData) <> string.Empty then
    begin
      PostDataEscaped := StringReplace(PostData, LineEnding, '\r\n', [rfReplaceAll]);
      Ini.WriteString('Request', 'PostData', PostDataEscaped);
    end
    else
      Ini.DeleteKey('Request', 'PostData');

    if Trim(Accept) <> string.Empty then
      Ini.WriteString('Request', 'Accept', Accept)
    else
      Ini.DeleteKey('Request', 'Accept');

    // Save headers
    ClearSection(Ini, 'Headers', not Assigned(Headers) or (Headers.Count = 0));
    if Assigned(Headers) then
      for i := 0 to Headers.Count - 1 do
        Ini.WriteString('Headers',
          IntToStr(i),
          Headers[i]);

    // Response page
    if Trim(JsonPointer) <> string.Empty then
      Ini.WriteString('Response', 'JsonPointer', JsonPointer)
    else
    begin
      Ini.DeleteKey('Response', 'JsonPointer');
      ClearSection(Ini, 'Response', True);
    end;

    // Parameters page
    Ini.WriteBool('Parameters', 'EncodeCustomParameters', EncodeCustomParameters);

    // Save custom parameters
    ClearSection(Ini, 'Custom Parameters', not Assigned(CustomParameters) or (CustomParameters.Count = 0));
    if Assigned(CustomParameters) then
      for i := 0 to CustomParameters.Count - 1 do
        Ini.WriteString('Custom Parameters',
          CustomParameters.Names[i],
          CustomParameters.ValueFromIndex[i]);

    // Save script parameters
    ClearSection(Ini, 'Script Parameters', not Assigned(ScriptParameters) or (ScriptParameters.Count = 0));
    if Assigned(ScriptParameters) then
      for i := 0 to ScriptParameters.Count - 1 do
        Ini.WriteString('Script Parameters',
          IntToStr(i),
          '#' + ScriptParameters[i]);

    // Save script response
    ClearSection(Ini, 'Script Response', not Assigned(ScriptResponse) or (ScriptResponse.Count = 0));
    if Assigned(ScriptResponse) then
      for i := 0 to ScriptResponse.Count - 1 do
        Ini.WriteString('Script Response',
          IntToStr(i),
          '#' + ScriptResponse[i]);

    ClearSection(Ini, 'Initial Request', (Trim(InitUserAgent) = string.Empty) and (Trim(InitUrl) = string.Empty) and
      (InitLiveTime = 0));
    if Trim(InitUserAgent) <> string.Empty then
      Ini.WriteString('Initial Request', 'UserAgent', InitUserAgent)
    else
      Ini.DeleteKey('Initial Request', 'UserAgent');

    if Trim(InitUrl) <> string.Empty then
      Ini.WriteString('Initial Request', 'Url', InitUrl)
    else
      Ini.DeleteKey('Initial Request', 'Url');

    if InitLiveTime > 0 then
      Ini.WriteInteger('Initial Request', 'LiveTime', InitLiveTime)
    else
      Ini.DeleteKey('Initial Request', 'LiveTime');

    // Save initial headers
    ClearSection(Ini, 'Initial Headers', not Assigned(InitHeaders) or (InitHeaders.Count = 0));
    if Assigned(InitHeaders) then
      for i := 0 to InitHeaders.Count - 1 do
        Ini.WriteString('Initial Headers',
          InitHeaders.Names[i],
          InitHeaders.ValueFromIndex[i]);

    // Save initial parameters
    ClearSection(Ini, 'Initial Parameters', not Assigned(InitParameters) or (InitParameters.Count = 0));
    if Assigned(InitParameters) then
      for i := 0 to InitParameters.Count - 1 do
        Ini.WriteString('Initial Parameters',
          InitParameters.Names[i],
          InitParameters.ValueFromIndex[i]);

    // Languages Page
    // Save language mappings (code=apiCode)
    ClearSection(Ini, 'Languages', not Assigned(LanguagesOriginal) or (LanguagesOriginal.Count = 0));
    if Assigned(LanguagesOriginal) then
      for i := 0 to LanguagesOriginal.Count - 1 do
        Ini.WriteString('Languages',
          IfThen(LanguagesOriginal.Names[i] = string.Empty, LanguagesOriginal[i] + '_' + IntToStr(i),
          LanguagesOriginal.Names[i] + '_' + IntToStr(i)),
          IfThen(LanguagesOriginal.ValueFromIndex[i] = string.Empty, IfThen(LanguagesOriginal.Names[i] =
          string.Empty, LanguagesOriginal[i], LanguagesOriginal.Names[i]), LanguagesOriginal.ValueFromIndex[i]));

    // Target Languages Page
    // Save language target mappings (code=apiCode)
    ClearSection(Ini, 'LanguagesTarget', not Assigned(LanguagesTargetOriginal) or (LanguagesTargetOriginal.Count = 0));
    if Assigned(LanguagesTargetOriginal) then
      for i := 0 to LanguagesTargetOriginal.Count - 1 do
        Ini.WriteString('LanguagesTarget',
          IfThen(LanguagesTargetOriginal.Names[i] = string.Empty, LanguagesTargetOriginal[i] + '_' + IntToStr(i),
          LanguagesTargetOriginal.Names[i] + '_' + IntToStr(i)),
          IfThen(LanguagesTargetOriginal.ValueFromIndex[i] = string.Empty, IfThen(LanguagesTargetOriginal.Names[i] =
          string.Empty, LanguagesTargetOriginal[i], LanguagesTargetOriginal.Names[i]), LanguagesTargetOriginal.ValueFromIndex[i]));

    Ini.UpdateFile;
  finally
    Ini.Free;
  end;
end;

procedure TCustomTranslate.LoadIniSettings(AFileName: string);
var
  Ini: TIniFile;
  Method: string;
  PostDataEscaped: string;
  Value: string;
  Keys: TStringList;
  i: integer;

  procedure LoadSection(const Section: string; Dest: TStrings);
  var
    Keys: TStringList;
    i, Num: integer;
    Key, Val: string;
    UnderscorePos: integer;
  begin
    Dest.Clear;
    Keys := TStringList.Create;
    try
      Ini.ReadSection(Section, Keys);
      for i := 0 to Keys.Count - 1 do
      begin
        Key := Keys[i];
        Val := Ini.ReadString(Section, Key, '');

        // remove trailing _number
        UnderscorePos := LastDelimiter('_', Key);
        if (UnderscorePos > 0) and TryStrToInt(Copy(Key, UnderscorePos + 1, MaxInt), Num) then
          Key := Copy(Key, 1, UnderscorePos - 1);

        Dest.Add(Key + '=' + Val);
      end;
    finally
      Keys.Free;
    end;
  end;

begin
  Ini := TIniFile.Create(AFileName);
  try
    FCookies.Clear;
    FParametersAge := 0;
    ServiceName := Ini.ReadString('Service', 'Name', string.Empty);
    ServiceIcon := Ini.ReadString('Service', 'Icon', string.Empty);
    ServiceOrder := Ini.ReadInteger('Service', 'Order', 0);
    ServiceVisible := Ini.ReadBool('Service', 'Visible', True);
    ServiceAutoSwap := Ini.ReadBool('Service', 'AutoSwapLanguage', False);
    ServiceRealTime := Ini.ReadBool('Service', 'RealTimeTranslation', False);
    ServiceOnlyButton := Ini.ReadBool('Service', 'TranslateOnlyByButton', False);
    ServiceProxy := Ini.ReadBool('Service', 'AllowProxy', False);
    ServiceColorRecent := Ini.ReadInteger('Service', 'ColorRecent', clBlue);

    ServiceDescription.Clear;
    Keys := TStringList.Create;
    try
      Ini.ReadSection('Service Description', Keys);

      for i := 0 to Keys.Count - 1 do
        ServiceDescription.Add(
          Ini.ReadString('Service Description', Keys[i], '')
          );
    finally
      Keys.Free;
    end;

    Value := Ini.ReadString('Service', 'ValueType', 'None');
    if SameText(Value, 'None') then
      LangType := vtNone
    else if SameText(Value, 'Language') then
      LangType := vtLanguage
    else if SameText(Value, 'CurrencyAll') then
      LangType := vtCurrencyAll
    else if SameText(Value, 'CurrencyFiat') then
      LangType := vtCurrencyFiat
    else if SameText(Value, 'CurrencyCrypto') then
      LangType := vtCurrencyCrypto
    else if SameText(Value, 'Unit') then
      LangType := vtUnit
    else
      LangType := vtNone; // default

    Method := Ini.ReadString('Request', 'Method', 'GET');
    if SameText(Method, 'POST') then
      WebMethod := wmPost
    else
      WebMethod := wmGet;

    UserAgent := Ini.ReadString('Request', 'UserAgent', string.Empty);
    EncodeText := Ini.ReadBool('Request', 'EncodeText', True);
    MaxLength := Ini.ReadInteger('Request', 'MaxLength', 0);

    Url := Ini.ReadString('Request', 'Url', string.Empty);

    ContentType := Ini.ReadString('Request', 'ContentType', string.Empty);
    // Restore line breaks from \r\n
    PostDataEscaped := Ini.ReadString('Request', 'PostData', string.Empty);
    PostData := StringReplace(PostDataEscaped, '\r\n', LineEnding, [rfReplaceAll]);
    Accept := Ini.ReadString('Request', 'Accept', string.Empty);
    Headers.Clear;
    if Ini.ValueExists('Headers', '0') then
    begin
      // New format: indexed entries
      i := 0;
      while Ini.ValueExists('Headers', IntToStr(i)) do
      begin
        Headers.Add(Ini.ReadString('Headers', IntToStr(i), string.Empty));
        Inc(i);
      end;
    end
    else
    begin
      // Old format: Key=Value
      Ini.ReadSectionValues('Headers', Headers);
    end;

    JsonPointer := Ini.ReadString('Response', 'JsonPointer', string.Empty);

    // Custom Parameters
    EncodeCustomParameters := Ini.ReadBool('Parameters', 'EncodeCustomParameters', True);
    CustomParameters.Clear;
    Ini.ReadSectionValues('Custom Parameters', CustomParameters);

    // Script Parameters
    ScriptParameters.Clear;
    Keys := TStringList.Create;
    try
      Ini.ReadSection('Script Parameters', Keys);

      for i := 0 to Keys.Count - 1 do
      begin
        Value := Ini.ReadString('Script Parameters', Keys[i], '');

        if (Value <> string.Empty) and (Value[1] = '#') then
          Delete(Value, 1, 1);

        ScriptParameters.Add(Value);
      end;
    finally
      Keys.Free;
    end;

    // Script Response
    ScriptResponse.Clear;
    Keys := TStringList.Create;
    try
      Ini.ReadSection('Script Response', Keys);

      for i := 0 to Keys.Count - 1 do
      begin
        Value := Ini.ReadString('Script Response', Keys[i], '');

        if (Value <> string.Empty) and (Value[1] = '#') then
          Delete(Value, 1, 1);

        ScriptResponse.Add(Value);
      end;
    finally
      Keys.Free;
    end;

    InitUserAgent := Ini.ReadString('Initial Request', 'UserAgent', string.Empty);
    InitUrl := Ini.ReadString('Initial Request', 'Url', string.Empty);
    InitLiveTime := Ini.ReadInteger('Initial Request', 'LiveTime', 0);
    InitHeaders.Clear;
    Ini.ReadSectionValues('Initial Headers', InitHeaders);
    InitParameters.Clear;
    Ini.ReadSectionValues('Initial Parameters', InitParameters);

    LoadSection('Languages', LanguagesOriginal);
    LoadSection('LanguagesTarget', LanguagesTargetOriginal);

    LanguagesOriginal.RemoveEmptyValues;
    LanguagesTargetOriginal.RemoveEmptyValues;

    Languages.Assign(LanguagesOriginal);
    LanguagesTarget.Assign(LanguagesTargetOriginal);

    FLanguageCodes := TLanguages.GetCodeArrayFromStringList(Languages);
  finally
    Ini.Free;
  end;
end;

class function TCustomTranslate.IsValidIni(const FileName: string): boolean;
var
  Ini: TIniFile;
  Method: string;
begin
  Result := False;

  if not FileExists(FileName) then
    Exit;

  Ini := TIniFile.Create(FileName);
  try
    // Check required keys
    Method := Ini.ReadString('Request', 'Method', string.Empty);

    if ((Method = 'GET') or (Method = 'POST')) and Ini.ValueExists('Request', 'EncodeText') and
      Ini.ValueExists('Service', 'Order') then
      Result := True;
  finally
    Ini.Free;
  end;
end;

class procedure TCustomTranslate.FindIniFiles(const Dir: string; List: TStrings);
var
  SR: TSearchRec;
  FilePath: string;
begin
  if not DirectoryExists(Dir) then
    Exit;

  // Search for *.ini files in current directory
  if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*.ini', faAnyFile and not faDirectory, SR) = 0 then
  begin
    repeat
      FilePath := IncludeTrailingPathDelimiter(Dir) + SR.Name;

      if IsValidIni(FilePath) then
        List.Add(FilePath);

    until FindNext(SR) <> 0;

    FindClose(SR);
  end;

  // Search subdirectories recursively
  if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*', faDirectory, SR) = 0 then
  begin
    repeat
      if (SR.Name <> '.') and (SR.Name <> '..') then
      begin
        if (SR.Attr and faDirectory) <> 0 then
        begin
          FilePath := IncludeTrailingPathDelimiter(Dir) + SR.Name;
          FindIniFiles(FilePath, List); // Recursive call
        end;
      end;
    until FindNext(SR) <> 0;

    FindClose(SR);
  end;
end;

class procedure TCustomTranslate.GetIniFiles(List: TStrings; AppName: string);
var
  ExeDir: string;
  SettingsDir: string;
begin
  List.Clear;

  // Executable directory
  ExeDir := ExtractFilePath(ParamStr(0));
  FindIniFiles(ExeDir, List);

  // Settings directory
  SettingsDir := TOS.GetSettingsDirectory(AppName, '');
  if CompareText(ExcludeTrailingPathDelimiter(ExeDir), ExcludeTrailingPathDelimiter(SettingsDir)) <> 0 then
    FindIniFiles(SettingsDir, List);
end;

class function TCustomTranslate.GetConfigFullPath(const ConfigName: string; ConfigFiles: TStringList): string;
var
  i: integer;
  NameOnly: string;
begin
  // Initialize result as empty string
  Result := string.Empty;

  // Extract only the file name in case ConfigName contains a full path
  NameOnly := ExtractFileName(ConfigName);

  // Iterate through all config file paths
  for i := 0 to ConfigFiles.Count - 1 do
  begin
    // Compare only the file name, case-insensitive
    if SameText(ExtractFileName(ConfigFiles[i]), NameOnly) then
    begin
      Result := ConfigFiles[i]; // return full path
      Exit;
    end;
  end;
  // If not found, Result remains empty
end;

class function TCustomTranslate.ConfigSortByOrderPathName(List: TStringList; Index1, Index2: integer): integer;
var
  Data1, Data2: PConfigData;
  Ord1, Ord2: integer;
begin
  Data1 := PConfigData(List.Objects[Index1]);
  Data2 := PConfigData(List.Objects[Index2]);

  // Treat Order=0 as "largest" to push it to the bottom
  if Data1^.Order = 0 then
    Ord1 := MaxInt
  else
    Ord1 := Data1^.Order;

  if Data2^.Order = 0 then
    Ord2 := MaxInt
  else
    Ord2 := Data2^.Order;

  Result := Ord1 - Ord2; // primary sort
  if Result = 0 then
  begin
    Result := CompareText(Data1^.PathOnly, Data2^.PathOnly); // secondary sort
    if Result = 0 then
      Result := CompareText(Data1^.Name, Data2^.Name); // tertiary sort
  end;
end;

class procedure TCustomTranslate.ClearSection(AIni: TIniFile; const ASection: string; AErase: boolean);
var
  Keys: TStringList;
  i: integer;
begin
  if AErase then
  begin
    // Completely remove section (may change file order)
    AIni.EraseSection(ASection);
    Exit;
  end;

  Keys := TStringList.Create;
  try
    // Read all keys from section
    AIni.ReadSection(ASection, Keys);

    // Delete each key individually (keeps section position)
    for i := 0 to Keys.Count - 1 do
      AIni.DeleteKey(ASection, Keys[i]);
  finally
    Keys.Free;
  end;
end;

class function TCustomTranslate.GetIniDirectory(AppName: string; fileName: string = string.Empty): string;
begin
  {$IFDEF WINDOWS}
  Result := ExtractFilePath(ParamStr(0)) + fileName;
  {$ELSE}
  Result := IncludeTrailingPathDelimiter(GetUserDir) + '.config/' + AppName + '/' + filename;
  {$ENDIF}
end;

{%EndRegion}

{%Region -fold TTranslateThread }

constructor TTranslateThread.Create(ATrans: TCustomTranslate; AResult: PString; ADone: PBoolean;
  ADetectLanguage: boolean = True; AFreeOnTerminate: boolean = True);
begin
  inherited Create(True);
  FreeOnTerminate := AFreeOnTerminate;

  FTrans := ATrans;
  FSourceText := FTrans.TextToTranslate;
  FDetectLanguage := ADetectLanguage;
  FCancelled := False;
  FExceptionMessage := string.Empty;
  FResult := AResult;
  FDone := ADone;

  if Assigned(FDone) then
    FDone^ := False;
end;

function TTranslateThread.GetIsTerminated: boolean;
begin
  Result := Terminated;
end;

function TTranslateThread.GetIsCancelled: boolean;
begin
  Result := FCancelled or Terminated or Application.Terminated;
end;

function TTranslateThread.GetResultText: string;
begin
  if Assigned(FResult) then
    Result := FResult^
  else
    Result := string.Empty;
end;

procedure TTranslateThread.Execute;
var
  DetResult: TLanguageDetectResult;
begin
  try
    if IsCancelled then Exit;
    try
      // Language detection runs first, in the same thread as translation
      if FTrans.ShouldAutoDetect(FDetectLanguage) then
      begin
        DetResult := FTrans.AnalyzeLanguage(FSourceText);
        if IsCancelled then Exit;
        // Fire only when detection actually produced a language
        if DetResult.DetectedLanguage <> string.Empty then
        begin
          // Apply in the worker thread before the event fires so the
          // event handler sees the state matching AResult.Applied
          if FTrans.Detect.AutoApply and (DetResult.Action <> ldaNone) then
          begin
            FTrans.ApplyDetectResult(DetResult);
            DetResult.Applied := True;
          end;
          // Event is informational when Applied = True
          FTrans.FireLanguageDetected(DetResult);
          if IsCancelled then Exit;
        end;
      end;

      if Length(Trim(FSourceText)) > 0 then
        FResult^ := FTrans.Translate
      else
        FResult^ := string.Empty;
    except
      on E: Exception do
        FResult^ := E.ClassName + ': ' + E.Message;
    end;
  finally
    if Assigned(FDone) then
      FDone^ := True;
  end;
end;

procedure TTranslateThread.Cancel;
begin
  if IsCancelled then Exit;
  FCancelled := True;

  if Assigned(FTrans) then
    FTrans.AbortRequest;
end;

{%EndRegion}

end.
