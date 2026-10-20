//-----------------------------------------------------------------------------------
//  Translator Package © 2026 by Alexander Tverskoy
//  Licensed under the MIT License
//  You may obtain a copy of the License at https://opensource.org/licenses/MIT
//-----------------------------------------------------------------------------------

unit TranslatorRegister;

{$mode objfpc}{$H+}

interface

uses
  Controls, Classes, LResources;

procedure Register;

implementation

procedure Register;
begin
  //RegisterComponents('Common Controls', [TTranslator]);
end;

initialization
  {$I translator.lrs}

end.
