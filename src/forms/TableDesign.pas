{ Pastel DB - the table designer: a new table's columns, and its SQL as it is
  being made. }
unit TableDesign;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, fpjson, Pastel.UI, Pastel.Db, DbMeta, TableDesign.g;

type
  TTableDesignForm = class(TTableDesignFormBase)
    procedure FormCreate(Sender: TObject);
    procedure AnyChange(Sender: TObject);
    procedure ColumnSelect(Sender: TObject);
    procedure AddColumnClick(Sender: TObject);
    procedure RemoveColumnClick(Sender: TObject);
    procedure UpClick(Sender: TObject);
    procedure FieldChange(Sender: TObject);
    procedure CreateClick(Sender: TObject);
  private
    FColumns: TColumnInfos;
    FCurrent: Integer;
    FFilling: Boolean;
    procedure ShowColumns(WithFields: Boolean = True);
    procedure ShowColumn;
    procedure ShowSql;
  public
    { set before ShowModal: the database it is made in }
    Db: TDatabase;
    { after mrOk: the new table's name }
    CreatedTable: string;
    procedure Start;
  end;

var
  TableDesignForm: TTableDesignForm;

implementation

uses
  Pastel.Syntax, MainWindow;

const
  Types: array[0..14] of string = ('integer', 'bigint', 'text', 'varchar(80)', 'varchar(255)', 'real',
    'double precision', 'numeric(10,2)', 'boolean', 'date', 'timestamp', 'datetime', 'blob', 'json', 'uuid');

procedure TTableDesignForm.FormCreate(Sender: TObject);
var
  T: string;
begin
  for T in Types do
    TypeEdit.Completions.Add(T);
  SqlView.OnHighlight := @Syntax.Sql;
end;

procedure TTableDesignForm.Start;
begin
  CreatedTable := '';
  TableEdit.Text := '';
  ErrorLabel.Text := '';
  FColumns := nil;
  SetLength(FColumns, 2);
  FColumns[0] := Default(TColumnInfo);
  FColumns[0].Name := 'id';
  FColumns[0].DataType := 'integer';
  FColumns[0].IsKey := True;
  FColumns[0].AutoNumber := True;
  FColumns[1] := Default(TColumnInfo);
  FColumns[1].Name := 'name';
  FColumns[1].DataType := 'text';
  FCurrent := 1;
  ShowColumns;
  TableEdit.SetFocus;
end;

procedure TTableDesignForm.ShowColumns(WithFields: Boolean);
var
  Rows: TJSONArray;
  C: TColumnInfo;
  Notes: string;
begin
  Rows := TJSONArray.Create;
  try
    for C in FColumns do
    begin
      Notes := '';
      if C.IsKey then Notes := 'key ';
      if C.AutoNumber then Notes := Notes + 'auto ';
      if not C.Nullable and not C.IsKey then Notes := Notes + 'required';
      Rows.Add(TJSONObject.Create(['Column', C.Name, 'Type', C.DataType, 'Notes', Trim(Notes)]));
    end;
    ShowRows(ColumnsGrid, Rows, ['Column', 'Type', 'Notes']);
  finally
    Rows.Free;
  end;
  if FCurrent > High(FColumns) then
    FCurrent := High(FColumns);
  ColumnsGrid.Row := FCurrent;
  if WithFields then
    ShowColumn;
  ShowSql;
end;

procedure TTableDesignForm.ShowColumn;
var
  Have: Boolean;
begin
  Have := (FCurrent >= 0) and (FCurrent <= High(FColumns));
  FFilling := True;
  try
    ColumnNameEdit.Enabled := Have;
    TypeEdit.Enabled := Have;
    DefaultEdit.Enabled := Have;
    KeyCheck.Enabled := Have;
    AutoCheck.Enabled := Have;
    RequiredCheck.Enabled := Have;
    RemoveColumnButton.Enabled := Have;
    UpButton.Enabled := Have and (FCurrent > 0);
    if not Have then
      Exit;
    ColumnNameEdit.Text := FColumns[FCurrent].Name;
    TypeEdit.Text := FColumns[FCurrent].DataType;
    DefaultEdit.Text := FColumns[FCurrent].DefaultValue;
    KeyCheck.Checked := FColumns[FCurrent].IsKey;
    AutoCheck.Checked := FColumns[FCurrent].AutoNumber;
    RequiredCheck.Checked := not FColumns[FCurrent].Nullable;
  finally
    FFilling := False;
  end;
end;

procedure TTableDesignForm.ShowSql;
var
  Kind: TDbKind;
begin
  if Db <> nil then Kind := Db.Kind else Kind := dbSQLite;
  try
    if Trim(TableEdit.Text) = '' then
      SqlView.Text := CreateTableSql(Kind, 'new_table', FColumns)
    else
      SqlView.Text := CreateTableSql(Kind, TableEdit.Text, FColumns);
    ErrorLabel.Text := '';
  except
    on E: Exception do
      SqlView.Text := '-- ' + E.Message;
  end;
end;

procedure TTableDesignForm.AnyChange(Sender: TObject);
begin
  ShowSql;
end;

procedure TTableDesignForm.ColumnSelect(Sender: TObject);
begin
  if (ColumnsGrid.Row >= 0) and (ColumnsGrid.Row <> FCurrent) then
  begin
    FCurrent := ColumnsGrid.Row;
    ShowColumn;
  end;
end;

procedure TTableDesignForm.AddColumnClick(Sender: TObject);
var
  C: TColumnInfo;
begin
  C := Default(TColumnInfo);
  C.Name := Format('column%d', [Length(FColumns) + 1]);
  C.DataType := 'text';
  C.Nullable := True;
  FColumns := Concat(FColumns, [C]);
  FCurrent := High(FColumns);
  ShowColumns;
  ColumnNameEdit.SetFocus;
  ColumnNameEdit.SelectAll;
end;

procedure TTableDesignForm.RemoveColumnClick(Sender: TObject);
begin
  if (FCurrent < 0) or (FCurrent > High(FColumns)) then
    Exit;
  Delete(FColumns, FCurrent, 1);
  ShowColumns;
end;

procedure TTableDesignForm.UpClick(Sender: TObject);
var
  C: TColumnInfo;
begin
  if (FCurrent < 1) or (FCurrent > High(FColumns)) then
    Exit;
  C := FColumns[FCurrent - 1];
  FColumns[FCurrent - 1] := FColumns[FCurrent];
  FColumns[FCurrent] := C;
  Dec(FCurrent);
  ShowColumns;
end;

procedure TTableDesignForm.FieldChange(Sender: TObject);
begin
  if FFilling or (FCurrent < 0) or (FCurrent > High(FColumns)) then
    Exit;
  FColumns[FCurrent].Name := ColumnNameEdit.Text;
  FColumns[FCurrent].DataType := TypeEdit.Text;
  FColumns[FCurrent].DefaultValue := DefaultEdit.Text;
  FColumns[FCurrent].IsKey := KeyCheck.Checked;
  FColumns[FCurrent].AutoNumber := AutoCheck.Checked;
  FColumns[FCurrent].Nullable := not RequiredCheck.Checked;
  { the list and the SQL again; the fields stay as they are typed }
  ShowColumns(False);
  UpButton.Enabled := FCurrent > 0;
end;

procedure TTableDesignForm.CreateClick(Sender: TObject);
begin
  if Db = nil then
    Exit;
  try
    if Trim(TableEdit.Text) = '' then
      raise Exception.Create('the table needs a name');
    Db.Exec(CreateTableSql(Db.Kind, TableEdit.Text, FColumns), []);
    CreatedTable := Trim(TableEdit.Text);
    ModalResult := mrOk;
  except
    on E: Exception do
      ErrorLabel.Text := E.Message;
  end;
end;

end.
