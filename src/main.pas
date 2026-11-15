program pasteldb;

{$mode objfpc}{$H+}

uses
  Pastel.App, MainWindow, Connect, TableDesign;

begin
  Application.Initialize;
  Application.CreateForm(TMainForm, MainForm);
  Application.CreateForm(TConnectForm, ConnectForm);
  Application.CreateForm(TTableDesignForm, TableDesignForm);
  Application.Run;
end.
