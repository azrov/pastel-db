{ Pastel DB - the connect dialog: a SQLite file or a server, saved connections. }
unit Connect;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Pastel.UI, Pastel.Dialogs, Pastel.Db, DbMeta, Connect.g;

type
  TConnectForm = class(TConnectFormBase)
    procedure FormCreate(Sender: TObject);
    procedure KindChange(Sender: TObject);
    procedure BrowseClick(Sender: TObject);
    procedure SavedChange(Sender: TObject);
    procedure ForgetClick(Sender: TObject);
    procedure ConnectClick(Sender: TObject);
  private
    FSaved: TConnections;
    procedure ShowSaved;
    function Current: TConnection;
  public
    { set when it connected: the database (the caller owns it) and its connection }
    Db: TDatabase;
    Conn: TConnection;
  end;

var
  ConnectForm: TConnectForm;

{ The password kept for a saved connection ('' when none). }
function KeptPassword(const C: TConnection): string;

implementation

uses
  Math, Pastel.SecureStore;

function SecretName(const C: TConnection): string;
begin
  Result := 'connection:' + ConnectionTitle(C);
end;

function KeptPassword(const C: TConnection): string;
begin
  try
    Result := SecureGet(SecretName(C));
  except
    Result := '';
  end;
end;

procedure TConnectForm.FormCreate(Sender: TObject);
begin
  FSaved := LoadConnections(ConnectionsFile);
  ShowSaved;
  KindChange(nil);
end;

procedure TConnectForm.ShowSaved;
var
  C: TConnection;
begin
  SavedList.Items.Clear;
  for C in FSaved do
    SavedList.Items.Add(ConnectionTitle(C));
  ForgetButton.Enabled := False;
end;

procedure TConnectForm.KindChange(Sender: TObject);
var
  Server: Boolean;
begin
  Server := KindBox.ItemIndex > 0;
  FileRow.Visible := not Server;
  HostEdit.Visible := Server;
  PortEdit.Visible := Server;
  DatabaseEdit.Visible := Server;
  UserEdit.Visible := Server;
  PasswordEdit.Visible := Server;
  RememberCheck.Visible := Server;
end;

procedure TConnectForm.BrowseClick(Sender: TObject);
begin
  if OpenDbDialog.Execute then
    FileEdit.Text := OpenDbDialog.FileName;
end;

procedure TConnectForm.SavedChange(Sender: TObject);
var
  C: TConnection;
begin
  if SavedList.ItemIndex < 0 then
    Exit;
  ForgetButton.Enabled := True;
  C := FSaved[SavedList.ItemIndex];
  KindBox.ItemIndex := Ord(C.Kind);
  KindChange(nil);
  FileEdit.Text := C.FileName;
  HostEdit.Text := C.Host;
  if C.Port > 0 then PortEdit.Text := IntToStr(C.Port) else PortEdit.Text := '';
  DatabaseEdit.Text := C.Database;
  UserEdit.Text := C.User;
  NameEdit.Text := C.Name;
  PasswordEdit.Text := KeptPassword(C);
  RememberCheck.Checked := PasswordEdit.Text <> '';
end;

procedure TConnectForm.ForgetClick(Sender: TObject);
var
  I: Integer;
begin
  I := SavedList.ItemIndex;
  if I < 0 then
    Exit;
  try
    SecureDelete(SecretName(FSaved[I]));
  except
  end;
  Delete(FSaved, I, 1);
  SaveConnections(ConnectionsFile, FSaved);
  ShowSaved;
end;

function TConnectForm.Current: TConnection;
begin
  Result := Default(TConnection);
  Result.Kind := TConnKind(Max(0, KindBox.ItemIndex));
  Result.FileName := Trim(FileEdit.Text);
  Result.Host := Trim(HostEdit.Text);
  Result.Port := StrToIntDef(Trim(PortEdit.Text), 0);
  Result.Database := Trim(DatabaseEdit.Text);
  Result.User := Trim(UserEdit.Text);
  Result.Name := Trim(NameEdit.Text);
end;

procedure TConnectForm.ConnectClick(Sender: TObject);
var
  C: TConnection;
  I, Found: Integer;
begin
  ErrorLabel.Text := '';
  C := Current;
  if (C.Kind = ckSQLite) and (C.FileName = '') then
  begin
    ErrorLabel.Text := 'Choose a SQLite file (Browse...).';
    Exit;
  end;
  if (C.Kind = ckSQLite) and not FileExists(C.FileName) then
  begin
    ErrorLabel.Text := 'There is no such file. A new one: Database > New SQLite file.';
    Exit;
  end;
  if (C.Kind <> ckSQLite) and (C.Database = '') then
  begin
    ErrorLabel.Text := 'Which database on the server?';
    Exit;
  end;
  try
    Db := TDatabase.Open(ConnectionUrl(C, PasswordEdit.Text));
    { a query, so a wrong password shows here and not later }
    Db.QueryValue('select 1', [], '');
  except
    on E: Exception do
    begin
      FreeAndNil(Db);
      ErrorLabel.Text := E.Message;
      Exit;
    end;
  end;
  Conn := C;
  { saved: replaced when it has the same name }
  Found := -1;
  for I := 0 to High(FSaved) do
    if ConnectionTitle(FSaved[I]) = ConnectionTitle(C) then
      Found := I;
  if Found < 0 then
  begin
    SetLength(FSaved, Length(FSaved) + 1);
    Found := High(FSaved);
  end;
  FSaved[Found] := C;
  SaveConnections(ConnectionsFile, FSaved);
  try
    if RememberCheck.Checked and (PasswordEdit.Text <> '') then
      SecureSet(SecretName(C), PasswordEdit.Text)
    else
      SecureDelete(SecretName(C));
  except
    on E: Exception do
      ShowToast('The password was not kept: ' + E.Message);
  end;
  ModalResult := mrOk;
end;

end.
