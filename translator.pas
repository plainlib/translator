{ This file was automatically created by Lazarus. Do not edit!
  This source is only used to compile and install the package.
 }

unit translator;

{$warn 5023 off : no warning about unused units}
interface

uses
  Translate, ConfigManager, Languages, LangDetect, Network, ScriptRunner, 
  TranslatorRegister, LazarusPackageIntf;

implementation

procedure Register;
begin
  RegisterUnit('TranslatorRegister', @TranslatorRegister.Register);
end;

initialization
  RegisterPackage('translator', @Register);
end.
