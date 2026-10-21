//-----------------------------------------------------------------------------------
//  Translator Package © 2026 by Alexander Tverskoy
//  Licensed under the MIT License
//  You may obtain a copy of the License at https://opensource.org/licenses/MIT
//-----------------------------------------------------------------------------------

unit TranslatorRegister;

{$mode objfpc}{$H+}

interface

uses
  Controls, Classes, LResources, PropEdits, Dialogs, Translate, ConfigManager;

procedure Register;

implementation

type
  // Opens a file dialog when the user clicks the "..." button
  TTranslateConfigFilePropertyEditor = class(TStringPropertyEditor)
  public
    function GetAttributes: TPropertyAttributes; override;
    procedure Edit; override;
  end;

function TTranslateConfigFilePropertyEditor.GetAttributes: TPropertyAttributes;
begin
  Result := inherited GetAttributes + [paDialog];
end;

procedure TTranslateConfigFilePropertyEditor.Edit;
var
  Dlg: TOpenDialog;
begin
  Dlg := TOpenDialog.Create(nil);
  try
    Dlg.Title := 'Select Service Configuration File';
    Dlg.Filter := 'INI files (*.ini)|*.ini|All files (*.*)|*.*';
    Dlg.Options := Dlg.Options + [ofFileMustExist, ofPathMustExist];
    if Dlg.Execute then
      SetStrValue(Dlg.FileName);
  finally
    Dlg.Free;
  end;
end;

procedure Register;
begin
  RegisterComponents('Common Controls', [TTranslate, TConfigManager]);
  RegisterPropertyEditor(TypeInfo(string), TTranslate, 'ConfigFile', TTranslateConfigFilePropertyEditor);
  RegisterPropertyEditor(TypeInfo(string), TDetectSettings, 'ConfigFile', TTranslateConfigFilePropertyEditor);

  // Needed so LFM streaming can find the nested persistent classes by name
  RegisterClass(TTranslateProxy);
  RegisterClass(TTranslateTimeout);
end;

initialization
  {$I translator.lrs}

end.
