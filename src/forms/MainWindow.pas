{ Pastel DB - the main window: the tables at the left; a table's rows, its
  structure, and SQL at the right. }
unit MainWindow;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpjson, Pastel.UI, Pastel.Controls, Pastel.Dialogs, Pastel.Grids, Pastel.Db, DbMeta,
  MainWindow.g;

type
  { a table's page, loaded on a thread of its own }
  TTableJob = class
    Db: TDatabase;
    Gen: Integer;
    Table, Where, OrderBy: string;
    Offset: Integer;
    NeedColumns: Boolean;
    Columns: TColumnInfos;
    Rows: TJSONArray;
    Total: Int64;
    Estimated: Boolean;
    Ms: QWord;
    destructor Destroy; override;
  end;

  { the statements of the SQL tab, run on a thread of their own }
  TQueryJob = class
    Db: TDatabase;
    Gen: Integer;
    Sql: string;
    Statements: TStringArray;
    Rows: TJSONArray;
    LastGivesRows, Schema: Boolean;
    RowsChanged, Done: Integer;
    Ms: QWord;
    destructor Destroy; override;
  end;

  TMainForm = class(TMainFormBase)
    procedure FormCreate(Sender: TObject);
    procedure ConnectClick(Sender: TObject);
    procedure NewSqliteClick(Sender: TObject);
    procedure RefreshClick(Sender: TObject);
    procedure QuitClick(Sender: TObject);
    procedure RunClick(Sender: TObject);
    procedure NewQueryClick(Sender: TObject);
    procedure ExportClick(Sender: TObject);
    procedure DarkClick(Sender: TObject);
    procedure FilterChange(Sender: TObject);
    procedure TablesChange(Sender: TObject);
    procedure ApplyWhereClick(Sender: TObject);
    procedure PrevClick(Sender: TObject);
    procedure NextClick(Sender: TObject);
    procedure AddRowClick(Sender: TObject);
    procedure DeleteRowClick(Sender: TObject);
    procedure DataGridCellEdit(Sender: TObject; ACol, ARow: Integer; var Value: string; var Accept: Boolean);
    procedure NewTableClick(Sender: TObject);
    procedure ImportClick(Sender: TObject);
    procedure DropTableClick(Sender: TObject);
    procedure BackupClick(Sender: TObject);
    procedure RestoreClick(Sender: TObject);
    procedure CloseQueryClick(Sender: TObject);
    procedure SelectQueryClick(Sender: TObject);
    procedure HistoryClick(Sender: TObject);
    procedure SqlChange(Sender: TObject);
    procedure HistoryFilterChange(Sender: TObject);
    procedure HistoryOpenClick(Sender: TObject);
    procedure HistoryClearClick(Sender: TObject);
    procedure HistoryListChange(Sender: TObject);
    procedure PagesChange(Sender: TObject);
    procedure StopClick(Sender: TObject);
  private
    FBusy, FTableGen, FQueryGen: Integer;
    FRetired: TFPList;           { databases left while a task still used them }
    FDb: TDatabase;
    FConn: TConnection;
    FTables, FViews: TStringArray;
    FTable: string;
    FColumns: TColumnInfos;
    FKeys: TStringArray;
    FOffset, FTotal: Integer;
    FDataRows, FResultRows: TJSONArray;
    FResultColumns: TStringArray;
    FQueries: TStringArray;
    FQueryIndex: Integer;
    FTabButtons: array of TButton;
    FHistory: THistory;
    FHistoryShown: array of Integer;
    FColumnCache: TStringList;
    procedure Busy(Delta: Integer);
    procedure LoadTableWork(Sender: TObject);
    procedure TableLoaded(Sender: TObject);
    procedure QueryWork(Sender: TObject);
    procedure QueryDone(Sender: TObject);
    procedure LoadTable(NeedColumns: Boolean);
    procedure ShowStructure;
    procedure Connected(Sender: TObject; AResult: Integer);
    procedure Designed(Sender: TObject; AResult: Integer);
    procedure ShowQueryTabs;
    procedure QueryTabClick(Sender: TObject);
    procedure OpenQuery(Index: Integer);
    procedure AddQuery(const Sql: string);
    procedure ShowHistory;
    procedure SqlCompletions(Sender: TObject; const Word: string; Items: TStrings);
    procedure SelectTable(const ATable: string);
    procedure UseDatabase(Db: TDatabase; const C: TConnection);
    procedure ShowTables;
    procedure ShowTable;
    procedure LoadPage;
    procedure Status(const S: string);
    procedure Failed(E: Exception);
  public
    destructor Destroy; override;
  end;

var
  MainForm: TMainForm;

const
  PageSize = 200;

{ Rows into a grid: its columns made from Columns (or the rows' own). }
procedure ShowRows(Grid: TGrid; Rows: TJSONArray; const Columns: TStringArray);

implementation

uses
  Math, Pastel.Files, Pastel.Syntax, Pastel.Sheets, Pastel.Workers, Connect, TableDesign;

destructor TTableJob.Destroy;
begin
  Rows.Free;
  inherited Destroy;
end;

destructor TQueryJob.Destroy;
begin
  Rows.Free;
  inherited Destroy;
end;

function ColumnWidth(Rows: TJSONArray; const Column: string): Integer;
var
  I, N: Integer;
begin
  N := Length(UTF8Decode(Column)) + 2;
  if Rows <> nil then
    for I := 0 to Min(Rows.Count, 60) - 1 do
      { long texts: the column is as wide as it may be anyway; only the start is counted }
      N := Max(N, Length(UTF8Decode(Copy(CellText(Rows.Objects[I], Column), 1, 200))));
  Result := EnsureRange(N * 9 + 24, 64, 380);
end;

function IsNumberColumn(Rows: TJSONArray; const Column: string): Boolean;
var
  I: Integer;
  D: TJSONData;
begin
  Result := False;
  if Rows = nil then
    Exit;
  for I := 0 to Min(Rows.Count, 20) - 1 do
  begin
    D := Rows.Objects[I].Find(Column);
    if (D = nil) or (D.JSONType = jtNull) then
      Continue;
    if D.JSONType <> jtNumber then
      Exit(False);
    Result := True;
  end;
end;

procedure ShowRows(Grid: TGrid; Rows: TJSONArray; const Columns: TStringArray);
var
  I: Integer;
  C: TGridColumn;
  Cols: TStringArray;
  Copy_: TJSONArray;
begin
  Grid.Clear;
  for I := Grid.ChildCount - 1 downto 0 do
    if Grid.Children[I] is TGridColumn then
      Grid.Children[I].Free;
  Cols := Columns;
  if Length(Cols) = 0 then
    Cols := ColumnsOf(Rows);
  for I := 0 to High(Cols) do
  begin
    { as wide as what is in it (the first rows), numbers at the right }
    C := Grid.AddColumn(Cols[I], ColumnWidth(Rows, Cols[I]));
    C.Field := Cols[I];
    if IsNumberColumn(Rows, Cols[I]) then
      C.Alignment := taRight;
  end;
  if (Rows <> nil) and (Rows.Count > 0) then
  begin
    { LoadJson takes the rows it is given }
    Copy_ := TJSONArray(Rows.Clone);
    Grid.LoadJson(Copy_);
  end;
end;

destructor TMainForm.Destroy;
begin
  if Length(FQueries) > 0 then
  try
    SaveQueries(QueriesFile, FQueries);
  except
    { the settings' folder cannot be written: the tabs are not kept }
  end;
  FColumnCache.Free;
  { a task still running ends with the program }
  if FBusy = 0 then
    while (FRetired <> nil) and (FRetired.Count > 0) do
    begin
      TObject(FRetired[0]).Free;
      FRetired.Delete(0);
    end;
  FRetired.Free;
  FDataRows.Free;
  FResultRows.Free;
  FDb.Free;
  inherited Destroy;
end;

procedure TMainForm.Status(const S: string);
begin
  StatusLabel.Text := S;
end;

procedure TMainForm.Failed(E: Exception);
begin
  Status(E.Message);
  ShowMessage(E.Message, 'Pastel DB');
end;

procedure TMainForm.FormCreate(Sender: TObject);
var
  L: TConnections;
  K: string;
begin
  FColumnCache := TStringList.Create;
  FRetired := TFPList.Create;
  StopButton.Enabled := False;
  SqlMemo.OnHighlight := @Syntax.Sql;
  HistorySql.OnHighlight := @Syntax.Sql;
  SqlMemo.OnCompletions := @SqlCompletions;
  for K in SqlKeywords do
    SqlMemo.Completions.Add(LowerCase(K));
  Pages.OnChange := @PagesChange;
  FQueries := LoadQueries(QueriesFile);
  if Length(FQueries) = 0 then
    FQueries := TStringArray.Create('');
  FQueryIndex := 0;
  SqlMemo.Text := FQueries[0];
  ShowQueryTabs;
  { the database of the command line, else the last one if it needs no password }
  if (ParamCount > 0) and FileExists(ParamStr(1)) then
  begin
    FConn := Default(TConnection);
    FConn.FileName := ExpandFileName(ParamStr(1));
    try
      UseDatabase(TDatabase.Open(ConnectionUrl(FConn, '')), FConn);
    except
      on E: Exception do
        Status(E.Message);
    end;
    Exit;
  end;
  L := LoadConnections(ConnectionsFile);
  if (Length(L) > 0) and (L[High(L)].Kind = ckSQLite) and FileExists(L[High(L)].FileName) then
  try
    UseDatabase(TDatabase.Open(ConnectionUrl(L[High(L)], '')), L[High(L)]);
  except
    on E: Exception do
      Status(E.Message);
  end;
end;

procedure TMainForm.ConnectClick(Sender: TObject);
begin
  ConnectForm.Db := nil;
  ConnectForm.ShowModal(@Connected);
end;

procedure TMainForm.Connected(Sender: TObject; AResult: Integer);
begin
  if (AResult = mrOk) and (ConnectForm.Db <> nil) then
    UseDatabase(ConnectForm.Db, ConnectForm.Conn);
  ConnectForm.Db := nil;
end;

procedure TMainForm.NewSqliteClick(Sender: TObject);
begin
  if not NewDbDialog.Execute then
    Exit;
  FConn := Default(TConnection);
  FConn.FileName := NewDbDialog.FileName;
  try
    UseDatabase(TDatabase.Open(ConnectionUrl(FConn, '')), FConn);
    SqlMemo.Text := 'create table customers (' + LineEnding + '  id integer primary key,' + LineEnding +
      '  name text not null,' + LineEnding + '  email text' + LineEnding + ');';
    Pages.TabIndex := 2;
  except
    on E: Exception do
      Failed(E);
  end;
end;

procedure TMainForm.UseDatabase(Db: TDatabase; const C: TConnection);
begin
  { what still runs on the old one: its results are not shown; it is freed when nothing uses it }
  Inc(FTableGen);
  Inc(FQueryGen);
  if (FDb <> nil) and (FBusy > 0) then
    FRetired.Add(FDb)
  else
    FDb.Free;
  FDb := nil;
  FDb := Db;
  FConn := C;
  FTable := '';
  FColumns := nil;
  FColumnCache.Clear;
  Title := ConnectionTitle(C) + ' - Pastel DB';
  ConnectionLabel.Text := ConnectionTitle(C) + '  ·  ' + Db.SafeUrl;
  ShowTables;
end;

procedure TMainForm.RefreshClick(Sender: TObject);
begin
  if FDb = nil then
    Exit;
  ShowTables;
  if FTable <> '' then
    ShowTable;
end;

procedure TMainForm.ShowTables;
var
  T, F: string;
  Root: TTreeNode;
begin
  if FDb = nil then
    Exit;
  try
    FTables := TableNames(FDb, FViews);
  except
    on E: Exception do
    begin
      Failed(E);
      Exit;
    end;
  end;
  F := LowerCase(Trim(FilterEdit.Text));
  FColumnCache.Clear;
  Tables.Clear;
  Root := Tables.Add(Format('Tables (%d)', [Length(FTables)]));
  for T in FTables do
    if (F = '') or (Pos(F, LowerCase(T)) > 0) then
      Root.AddChild(T);
  Root.Expanded := True;
  if Length(FViews) > 0 then
  begin
    Root := Tables.Add(Format('Views (%d)', [Length(FViews)]));
    for T in FViews do
      if (F = '') or (Pos(F, LowerCase(T)) > 0) then
        Root.AddChild(T);
    Root.Expanded := True;
  end;
  Status(Format('%d tables, %d views', [Length(FTables), Length(FViews)]));
end;

procedure TMainForm.FilterChange(Sender: TObject);
begin
  ShowTables;
end;

procedure TMainForm.TablesChange(Sender: TObject);
begin
  if (Tables.Selected = nil) or (Tables.Selected.Level = 0) then
    Exit;
  FTable := Tables.Selected.Text;
  FOffset := 0;
  WhereEdit.Text := '';
  ShowTable;
end;

procedure TMainForm.Busy(Delta: Integer);
begin
  Inc(FBusy, Delta);
  StopButton.Enabled := FBusy > 0;
  if FBusy = 0 then
    while FRetired.Count > 0 do
    begin
      TObject(FRetired[0]).Free;
      FRetired.Delete(0);
    end;
end;

procedure TMainForm.StopClick(Sender: TObject);
begin
  { the results are not waited for; the server ends the query by itself }
  Inc(FTableGen);
  Inc(FQueryGen);
  StopButton.Enabled := False;
  QueryLabel.Text := '';
  Status('Stopped: the server finishes that query by itself; its rows are not shown');
end;

procedure TMainForm.ShowTable;
begin
  LoadTable(True);
end;

procedure TMainForm.LoadPage;
begin
  LoadTable(False);
end;

{ the table's columns (when asked), its number of rows and a page: on a thread of its own }
procedure TMainForm.LoadTable(NeedColumns: Boolean);
var
  J: TTableJob;
begin
  if (FDb = nil) or (FTable = '') then
    Exit;
  Inc(FTableGen);
  J := TTableJob.Create;
  J.Db := FDb;
  J.Gen := FTableGen;
  J.Table := FTable;
  J.Where := WhereEdit.Text;
  J.Offset := FOffset;
  J.NeedColumns := NeedColumns or (Length(FColumns) = 0);
  J.Columns := FColumns;
  if J.NeedColumns then
  begin
    { another table: nothing of the one before may be changed meanwhile }
    FColumns := nil;
    FKeys := nil;
    FreeAndNil(FDataRows);
    ShowRows(DataGrid, nil, nil);
    ShowRows(StructureGrid, nil, nil);
  end;
  if (Length(FKeys) > 0) and not J.NeedColumns then
    J.OrderBy := FKeys[0];
  Status(Format('%s: loading...', [FTable]));
  PageLabel.Text := '...';
  Busy(1);
  RunInBackground(@LoadTableWork, @TableLoaded, J);
end;

procedure TMainForm.LoadTableWork(Sender: TObject);
var
  T: TBackgroundTask;
  J: TTableJob;
  C: TColumnInfo;
  T0: QWord;
begin
  T := TBackgroundTask(Sender);
  J := TTableJob(T.Data);
  T0 := GetTickCount64;
  if J.NeedColumns then
  begin
    J.Columns := TableColumns(J.Db, J.Table);
    for C in J.Columns do
      if C.IsKey then
      begin
        J.OrderBy := C.Name;
        Break;
      end;
  end;
  J.Rows := J.Db.Query(PageSql(J.Db, J.Table, J.Where, J.OrderBy, J.Offset, PageSize), []);
  { a big table of a server: its statistics, not counting millions of rows }
  J.Total := -1;
  if Trim(J.Where) = '' then
  begin
    J.Total := EstimatedRows(J.Db, J.Table);
    J.Estimated := J.Total >= 100000;
  end;
  if not J.Estimated then
    J.Total := J.Db.QueryInt(CountSql(J.Db, J.Table, J.Where), [], 0);
  J.Ms := GetTickCount64 - T0;
end;

procedure TMainForm.ShowStructure;
var
  Rows: TJSONArray;
  I: Integer;
begin
  Rows := TJSONArray.Create;
  try
    for I := 0 to High(FColumns) do
      Rows.Add(TJSONObject.Create(['Column', FColumns[I].Name, 'Type', FColumns[I].DataType,
        'Null', BoolToStr(FColumns[I].Nullable, 'yes', 'no'), 'Default', FColumns[I].DefaultValue,
        'Key', BoolToStr(FColumns[I].IsKey, 'primary key', '')]));
    ShowRows(StructureGrid, Rows, ['Column', 'Type', 'Null', 'Default', 'Key']);
  finally
    Rows.Free;
  end;
end;

procedure TMainForm.TableLoaded(Sender: TObject);
var
  T: TBackgroundTask;
  J: TTableJob;
  Cols: TStringArray;
  C: TColumnInfo;
  Of_: string;
begin
  T := TBackgroundTask(Sender);
  J := TTableJob(T.Data);
  try
    Busy(-1);
    if J.Gen <> FTableGen then
      Exit;           { another table was chosen meanwhile, or Stop }
    if T.Error <> '' then
    begin
      PageLabel.Text := '';
      Status(T.Error);
      ShowMessage(T.Error, 'Pastel DB');
      Exit;
    end;
    if J.NeedColumns then
    begin
      FColumns := J.Columns;
      FKeys := nil;
      for C in FColumns do
        if C.IsKey then
          FKeys := Concat(FKeys, [C.Name]);
      ShowStructure;
    end;
    FTotal := J.Total;
    FreeAndNil(FDataRows);
    FDataRows := J.Rows;
    J.Rows := nil;
    Cols := nil;
    for C in FColumns do
      Cols := Concat(Cols, [C.Name]);
    ShowRows(DataGrid, FDataRows, Cols);
    DataGrid.Editable := Length(FKeys) > 0;
    if J.Estimated then Of_ := 'of about ' else Of_ := 'of ';
    if (FTotal = 0) and (FDataRows.Count = 0) then
      PageLabel.Text := 'no rows'
    else
      PageLabel.Text := Format('%d-%d %s%d', [FOffset + 1, FOffset + FDataRows.Count, Of_, FTotal]);
    PrevButton.Enabled := FOffset > 0;
    NextButton.Enabled := (FOffset + PageSize < FTotal) or (FDataRows.Count = PageSize);
    if Length(FKeys) = 0 then
      Status(Format('%s: %s%d rows (%d ms) · no primary key: the rows cannot be changed here', [FTable, Of_, FTotal,
        J.Ms]))
    else
      Status(Format('%s: %s%d rows (%d ms) · double-click a cell to change it', [FTable, Of_, FTotal, J.Ms]));
  finally
    J.Free;
  end;
end;

procedure TMainForm.ApplyWhereClick(Sender: TObject);
begin
  FOffset := 0;
  LoadPage;
end;

procedure TMainForm.PrevClick(Sender: TObject);
begin
  FOffset := Max(0, FOffset - PageSize);
  LoadPage;
end;

procedure TMainForm.NextClick(Sender: TObject);
begin
  if (FOffset + PageSize < FTotal) or ((FDataRows <> nil) and (FDataRows.Count = PageSize)) then
    Inc(FOffset, PageSize);
  LoadPage;
end;

{ the row's key: "a = ? and b = ?" and its values }
function KeyWhere(Db: TDatabase; const Keys: TStringArray; Row: TJSONObject; out Values: TStringArray): string;
var
  K: string;
begin
  Result := '';
  Values := nil;
  for K in Keys do
  begin
    if Result <> '' then
      Result := Result + ' and ';
    Result := Result + QuoteName(Db, K) + ' = ?';
    Values := Concat(Values, [CellText(Row, K)]);
  end;
end;

function KeyType(const Columns: TColumnInfos; const Name: string): string;
var
  C: TColumnInfo;
begin
  Result := '';
  for C in Columns do
    if C.Name = Name then
      Exit(C.DataType);
end;

{ the key's values as parameters (numbers as numbers) after the others }
procedure AddKeyArgs(var Args: TVarRecs; const Columns: TColumnInfos; const Keys, Values: TStringArray);
var
  I, N: Integer;
begin
  N := Length(Args);
  SetLength(Args, N + Length(Keys));
  for I := 0 to High(Keys) do
    Args[N + I] := ParamFor(KeyType(Columns, Keys[I]), Values[I], False);
end;

procedure TMainForm.DataGridCellEdit(Sender: TObject; ACol, ARow: Integer; var Value: string; var Accept: Boolean);
var
  Where, Sql: string;
  Values: TStringArray;
  Args: TVarRecs;
begin
  Accept := False;
  if (FDataRows = nil) or (ARow >= FDataRows.Count) or (Length(FKeys) = 0) or (ACol > High(FColumns)) then
    Exit;
  Where := KeyWhere(FDb, FKeys, FDataRows.Objects[ARow], Values);
  { NULL in capitals: no value }
  Sql := 'update ' + QuoteName(FDb, FTable) + ' set ' + QuoteName(FDb, FColumns[ACol].Name) + ' = ? where ' + Where;
  Args := nil;
  SetLength(Args, 1);
  Args[0] := ParamFor(FColumns[ACol].DataType, Value, True);
  AddKeyArgs(Args, FColumns, FKeys, Values);
  try
    try
      if FDb.Exec(Sql, Args) <> 1 then
        raise Exception.Create('the row was not found (changed by someone else?): Refresh');
    finally
      FreeParams(Args);
    end;
    Accept := True;
    if Value = 'NULL' then
      FDataRows.Objects[ARow].Nulls[FColumns[ACol].Name] := True
    else
      FDataRows.Objects[ARow].Strings[FColumns[ACol].Name] := Value;
    Status(Format('%s.%s changed', [FTable, FColumns[ACol].Name]));
  except
    on E: Exception do
      Failed(E);
  end;
end;

procedure TMainForm.AddRowClick(Sender: TObject);
begin
  if (FDb = nil) or (FTable = '') then
    Exit;
  try
    if FDb.Kind = dbMySQL then
      FDb.Exec('insert into ' + QuoteName(FDb, FTable) + ' () values ()', [])
    else
      FDb.Exec('insert into ' + QuoteName(FDb, FTable) + ' default values', []);
    FOffset := Max(0, ((FTotal) div PageSize) * PageSize);
    LoadPage;
    DataGrid.Row := DataGrid.RowCount - 1;
    DataGrid.MakeVisible(DataGrid.RowCount - 1);
  except
    on E: Exception do
      Failed(E);
  end;
end;

procedure TMainForm.DeleteRowClick(Sender: TObject);
var
  Where: string;
  Values: TStringArray;
  Args: TVarRecs;
begin
  if (FDataRows = nil) or (DataGrid.Row < 0) or (DataGrid.Row >= FDataRows.Count) then
    Exit;
  if Length(FKeys) = 0 then
  begin
    ShowMessage('This table has no primary key: its rows cannot be told apart here.', 'Pastel DB');
    Exit;
  end;
  if not Ask('Delete this row?', 'Pastel DB') then
    Exit;
  Where := KeyWhere(FDb, FKeys, FDataRows.Objects[DataGrid.Row], Values);
  Args := nil;
  AddKeyArgs(Args, FColumns, FKeys, Values);
  try
    try
      FDb.Exec('delete from ' + QuoteName(FDb, FTable) + ' where ' + Where, Args);
    finally
      FreeParams(Args);
    end;
    LoadPage;
  except
    on E: Exception do
      Failed(E);
  end;
end;

procedure TMainForm.RunClick(Sender: TObject);
var
  J: TQueryJob;
begin
  if FDb = nil then
  begin
    ConnectClick(nil);
    Exit;
  end;
  Pages.TabIndex := 2;
  J := TQueryJob.Create;
  { a selection runs alone }
  if SqlMemo.SelLength > 0 then
    J.Sql := SqlMemo.SelText
  else
    J.Sql := SqlMemo.Text;
  J.Statements := SplitStatements(J.Sql);
  if Length(J.Statements) = 0 then
  begin
    J.Free;
    Exit;
  end;
  SqlMemo.HideCompletions;
  Inc(FQueryGen);
  J.Gen := FQueryGen;
  J.Db := FDb;
  QueryLabel.Color := Theme.TextMuted;
  QueryLabel.Text := 'Running...  (Stop: the toolbar)';
  Busy(1);
  RunInBackground(@QueryWork, @QueryDone, J);
end;

procedure TMainForm.QueryWork(Sender: TObject);
var
  T: TBackgroundTask;
  J: TQueryJob;
  S: string;
  T0: QWord;
begin
  T := TBackgroundTask(Sender);
  J := TQueryJob(T.Data);
  T0 := GetTickCount64;
  try
    for S in J.Statements do
    begin
      if GivesRows(S) then
      begin
        FreeAndNil(J.Rows);
        J.Rows := J.Db.Query(S, []);
      end
      else
      begin
        Inc(J.RowsChanged, J.Db.Exec(S, []));
        J.Schema := J.Schema or (Pos('create', LowerCase(S)) > 0) or (Pos('drop', LowerCase(S)) > 0) or
          (Pos('alter', LowerCase(S)) > 0);
      end;
      Inc(J.Done);
    end;
    J.LastGivesRows := GivesRows(J.Statements[High(J.Statements)]);
  finally
    J.Ms := GetTickCount64 - T0;
  end;
end;

procedure TMainForm.QueryDone(Sender: TObject);
var
  T: TBackgroundTask;
  J: TQueryJob;

  procedure Remember(Rows: Integer; AFailed: Boolean);
  var
    It: THistoryItem;
  begin
    It := Default(THistoryItem);
    It.When := Now;
    It.Connection := ConnectionTitle(FConn);
    It.Sql := Trim(J.Sql);
    It.Rows := Rows;
    It.Ms := J.Ms;
    It.Failed := AFailed;
    try
      AddHistory(HistoryFile, It);
    except
      { the settings' folder cannot be written: no history }
    end;
  end;

begin
  T := TBackgroundTask(Sender);
  J := TQueryJob(T.Data);
  try
    Busy(-1);
    if J.Gen <> FQueryGen then
      Exit;
    { the rows of the last statement that gave rows (also when a later one failed) }
    if J.Rows <> nil then
    begin
      FreeAndNil(FResultRows);
      FResultRows := J.Rows;
      J.Rows := nil;
      FResultColumns := ColumnsOf(FResultRows);
      ShowRows(ResultGrid, FResultRows, FResultColumns);
    end;
    if T.Error <> '' then
    begin
      QueryLabel.Color := Theme.Danger;
      QueryLabel.Text := Format('Statement %d: %s', [J.Done + 1, T.Error]);
      Remember(0, True);
    end
    else
    begin
      QueryLabel.Color := Theme.TextMuted;
      if (FResultRows <> nil) and J.LastGivesRows then
      begin
        QueryLabel.Text := Format('%d rows · %d ms', [FResultRows.Count, J.Ms]);
        Remember(FResultRows.Count, False);
      end
      else
      begin
        QueryLabel.Text := Format('%d statement(s) · %d rows changed · %d ms', [J.Done, J.RowsChanged, J.Ms]);
        Remember(J.RowsChanged, False);
      end;
    end;
    if J.Schema then
    begin
      FColumnCache.Clear;
      ShowTables;
    end;
  finally
    J.Free;
  end;
end;

{ ---- query tabs ---- }

procedure TMainForm.ShowQueryTabs;
var
  I: Integer;
  B: TButton;
  T: string;
begin
  for B in FTabButtons do
    B.Free;
  FTabButtons := nil;
  NewTabButton.Parent := nil;
  CloseTabButton.Parent := nil;
  for I := 0 to High(FQueries) do
  begin
    B := TButton.Create(Self);
    T := SqlTitle(FQueries[I]);
    if T = '' then
      T := Format('Query %d', [I + 1]);
    if Length(UTF8Decode(T)) > 22 then
      T := UTF8Encode(Copy(UTF8Decode(T), 1, 21)) + '…';
    B.Text := T;
    if I = FQueryIndex then
      B.Style := bsSecondary
    else
      B.Style := bsFlat;
    B.Tag := I;
    B.Hint := FQueries[I];
    B.OnClick := @QueryTabClick;
    B.Parent := QueryTabs;
    FTabButtons := Concat(FTabButtons, [B]);
  end;
  NewTabButton.Parent := QueryTabs;
  CloseTabButton.Parent := QueryTabs;
end;

procedure TMainForm.OpenQuery(Index: Integer);
begin
  if (Index < 0) or (Index > High(FQueries)) then
    Exit;
  FQueries[FQueryIndex] := SqlMemo.Text;
  FQueryIndex := Index;
  SqlMemo.Text := FQueries[Index];
  ShowQueryTabs;
  Pages.TabIndex := 2;
  SqlMemo.SetFocus;
end;

procedure TMainForm.QueryTabClick(Sender: TObject);
begin
  OpenQuery(TButton(Sender).Tag);
end;

procedure TMainForm.AddQuery(const Sql: string);
begin
  FQueries[FQueryIndex] := SqlMemo.Text;
  FQueries := Concat(FQueries, [Sql]);
  OpenQuery(High(FQueries));
end;

procedure TMainForm.SqlChange(Sender: TObject);
var
  T: string;
begin
  if FQueryIndex > High(FQueries) then
    Exit;
  FQueries[FQueryIndex] := SqlMemo.Text;
  { the tab's caption follows the first line }
  if FQueryIndex <= High(FTabButtons) then
  begin
    T := SqlTitle(SqlMemo.Text);
    if T = '' then
      T := Format('Query %d', [FQueryIndex + 1]);
    if Length(UTF8Decode(T)) > 22 then
      T := UTF8Encode(Copy(UTF8Decode(T), 1, 21)) + '…';
    if FTabButtons[FQueryIndex].Text <> T then
      FTabButtons[FQueryIndex].Text := T;
  end;
end;

procedure TMainForm.NewQueryClick(Sender: TObject);
begin
  AddQuery('');
end;

procedure TMainForm.CloseQueryClick(Sender: TObject);
begin
  if Length(FQueries) <= 1 then
  begin
    FQueries[0] := '';
    SqlMemo.Text := '';
    ShowQueryTabs;
    Exit;
  end;
  Delete(FQueries, FQueryIndex, 1);
  FQueryIndex := Min(FQueryIndex, High(FQueries));
  SqlMemo.Text := FQueries[FQueryIndex];
  ShowQueryTabs;
end;

procedure TMainForm.SelectQueryClick(Sender: TObject);
begin
  if (FDb = nil) or (FTable = '') then
    Exit;
  AddQuery('select * from ' + QuoteName(FDb, FTable) + ' limit 100;');
end;

{ ---- completions: keywords, tables; a table's columns after its name and a dot ---- }

procedure TMainForm.SqlCompletions(Sender: TObject; const Word: string; Items: TStrings);
var
  T, Cols: string;
  I: Integer;
  C: TColumnInfo;
begin
  for T in FTables do
    Items.Add(T);
  for T in FViews do
    Items.Add(T);
  for C in FColumns do
    Items.Add(C.Name);
  I := LastDelimiter('.', Word);
  if (I = 0) or (FDb = nil) then
    Exit;
  T := Copy(Word, 1, I - 1);
  if Pos('.', T) > 0 then
    T := Copy(T, LastDelimiter('.', T) + 1, MaxInt);
  Items.Clear;
  { an alias (from customers c) or the table's name as the database has it }
  T := AliasTable(SqlMemo.Text, T, Concat(FTables, FViews));
  if T = '' then
    Exit;
  I := FColumnCache.IndexOfName(LowerCase(T));
  if I >= 0 then
    Cols := FColumnCache.ValueFromIndex[I]
  else
  begin
    Cols := '';
    try
      for C in TableColumns(FDb, T) do
        Cols := Cols + C.Name + #9;
    except
      Cols := '';
    end;
    FColumnCache.Values[LowerCase(T)] := Cols;
  end;
  for T in Cols.Split([#9]) do
    if T <> '' then
      Items.Add(T);
end;

{ ---- history ---- }

procedure TMainForm.ShowHistory;
var
  I: Integer;
  F, Line: string;
begin
  FHistory := LoadHistory(HistoryFile);
  F := LowerCase(Trim(HistoryFilter.Text));
  HistoryList.Items.BeginUpdate;
  try
    HistoryList.Items.Clear;
    FHistoryShown := nil;
    for I := 0 to High(FHistory) do
      if (F = '') or (Pos(F, LowerCase(FHistory[I].Sql)) > 0) or (Pos(F, LowerCase(FHistory[I].Connection)) > 0) then
      begin
        Line := FormatDateTime('dd.mm hh:nn', FHistory[I].When) + '   ' + SqlTitle(FHistory[I].Sql);
        if FHistory[I].Failed then
          Line := Line + '   (failed)'
        else
          Line := Line + Format('   (%d rows, %d ms, %s)', [FHistory[I].Rows, FHistory[I].Ms, FHistory[I].Connection]);
        HistoryList.Items.Add(Line);
        FHistoryShown := Concat(FHistoryShown, [I]);
      end;
  finally
    HistoryList.Items.EndUpdate;
  end;
  HistorySql.Text := '';
  if Length(FHistoryShown) > 0 then
  begin
    HistoryList.ItemIndex := 0;
    HistoryListChange(nil);
  end;
end;

procedure TMainForm.HistoryClick(Sender: TObject);
begin
  Pages.TabIndex := 3;
  ShowHistory;
  HistoryFilter.SetFocus;
end;

procedure TMainForm.PagesChange(Sender: TObject);
begin
  if Pages.TabIndex = 3 then
    ShowHistory;
end;

procedure TMainForm.HistoryFilterChange(Sender: TObject);
begin
  ShowHistory;
end;

procedure TMainForm.HistoryListChange(Sender: TObject);
var
  I: Integer;
begin
  I := HistoryList.ItemIndex;
  if (I >= 0) and (I <= High(FHistoryShown)) then
    HistorySql.Text := FHistory[FHistoryShown[I]].Sql;
end;

procedure TMainForm.HistoryOpenClick(Sender: TObject);
var
  I: Integer;
begin
  I := HistoryList.ItemIndex;
  if (I < 0) or (I > High(FHistoryShown)) then
    Exit;
  if Trim(SqlMemo.Text) = '' then
  begin
    SqlMemo.Text := FHistory[FHistoryShown[I]].Sql;
    OpenQuery(FQueryIndex);
  end
  else
    AddQuery(FHistory[FHistoryShown[I]].Sql);
end;

procedure TMainForm.HistoryClearClick(Sender: TObject);
begin
  if not Ask('Forget all the queries that ran?', 'Pastel DB') then
    Exit;
  DeleteFile(HistoryFile);
  ShowHistory;
end;

{ ---- tables: new, import, drop; backups ---- }

procedure TMainForm.SelectTable(const ATable: string);
begin
  FColumnCache.Clear;
  ShowTables;
  FTable := ATable;
  FOffset := 0;
  WhereEdit.Text := '';
  ShowTable;
  Pages.TabIndex := 0;
end;

procedure TMainForm.NewTableClick(Sender: TObject);
begin
  if FDb = nil then
  begin
    ConnectClick(nil);
    Exit;
  end;
  TableDesignForm.Db := FDb;
  TableDesignForm.Start;
  TableDesignForm.ShowModal(@Designed);
end;

procedure TMainForm.Designed(Sender: TObject; AResult: Integer);
begin
  if (AResult = mrOk) and (TableDesignForm.CreatedTable <> '') then
  begin
    SelectTable(TableDesignForm.CreatedTable);
    Status(TableDesignForm.CreatedTable + ' made');
  end;
end;

{ a table's name from a file's: letters, digits and _ }
function NameFromFile(const FileName: string): string;
var
  C: Char;
begin
  Result := '';
  for C in LowerCase(ChangeFileExt(ExtractFileName(FileName), '')) do
    if C in ['a'..'z', '0'..'9', '_'] then
      Result := Result + C
    else if (Result <> '') and (Result[Length(Result)] <> '_') then
      Result := Result + '_';
  Result := Trim(StringReplace(Result, '__', '_', [rfReplaceAll]));
  if (Result = '') or (Result[1] in ['0'..'9']) then
    Result := 't_' + Result;
end;

procedure TMainForm.ImportClick(Sender: TObject);
var
  Rows: TSheetRows;
  TableName, T: string;
  Into: Boolean;
  N: Integer;
  T0: QWord;
begin
  if FDb = nil then
  begin
    ConnectClick(nil);
    Exit;
  end;
  if not ImportDialog.Execute then
    Exit;
  try
    Rows := ReadSpreadsheet(ImportDialog.FileName);
  except
    on E: Exception do
    begin
      Failed(E);
      Exit;
    end;
  end;
  if Length(Rows) < 2 then
  begin
    ShowMessage('The file has no rows under the first one (the names of the columns).', 'Pastel DB');
    Exit;
  end;
  Into := False;
  if FTable <> '' then
    case MessageDlg(Format('%d rows. Put them into the table %s?' + LineEnding +
      'No: into a new table.', [Length(Rows) - 1, FTable]), 'Import', [mrYes, mrNo, mrCancel]) of
      mrYes: Into := True;
      mrNo: Into := False;
    else
      Exit;
    end;
  if Into then
    TableName := FTable
  else
  begin
    TableName := NameFromFile(ImportDialog.FileName);
    if not InputQuery('Import', 'The new table''s name', TableName) or (Trim(TableName) = '') then
      Exit;
    TableName := Trim(TableName);
    for T in FTables do
      if SameText(T, TableName) then
      begin
        if not Ask(Format('There is a table %s. Put the rows into it?', [T]), 'Import') then
          Exit;
        TableName := T;
        Into := True;
      end;
  end;
  T0 := GetTickCount64;
  try
    N := ImportRows(FDb, TableName, Rows, not Into);
  except
    on E: Exception do
    begin
      Failed(E);
      Exit;
    end;
  end;
  SelectTable(TableName);
  Status(Format('%d rows imported into %s (%d ms)', [N, TableName, GetTickCount64 - T0]));
end;

procedure TMainForm.DropTableClick(Sender: TObject);
var
  What: string;
  IsView: Boolean;
  V: string;
begin
  if (FDb = nil) or (FTable = '') then
  begin
    ShowMessage('Choose a table at the left first.', 'Pastel DB');
    Exit;
  end;
  IsView := False;
  for V in FViews do
    if V = FTable then
      IsView := True;
  if IsView then What := 'view' else What := 'table';
  if MessageDlg(Format('Drop the %s %s and everything in it? This cannot be undone.', [What, FTable]),
    'Pastel DB', [mrYes, mrCancel], True) <> mrYes then
    Exit;
  try
    FDb.Exec('drop ' + What + ' ' + QuoteName(FDb, FTable), []);
    Status(FTable + ' dropped');
    FTable := '';
    FColumns := nil;
    FreeAndNil(FDataRows);
    ShowRows(DataGrid, nil, nil);
    ShowRows(StructureGrid, nil, nil);
    PageLabel.Text := '';
    FColumnCache.Clear;
    ShowTables;
  except
    on E: Exception do
      Failed(E);
  end;
end;

procedure TMainForm.BackupClick(Sender: TObject);
begin
  if FDb = nil then
    Exit;
  if FDb.Kind = dbSQLite then
  begin
    BackupDialog.Filter := 'SQLite|*.db';
    BackupDialog.DefaultExt := '.db';
    BackupDialog.FileName := NameFromFile(FConn.FileName) + '-' + FormatDateTime('yyyy-mm-dd', Now) + '.db';
  end
  else
  begin
    BackupDialog.Filter := 'SQL|*.sql';
    BackupDialog.DefaultExt := '.sql';
    BackupDialog.FileName := NameFromFile(FConn.Database) + '-' + FormatDateTime('yyyy-mm-dd', Now) + '.sql';
  end;
  if not BackupDialog.Execute then
    Exit;
  try
    FDb.Backup(BackupDialog.FileName);
    Status('Backed up to ' + BackupDialog.FileName);
  except
    on E: Exception do
      Failed(E);
  end;
end;

procedure TMainForm.RestoreClick(Sender: TObject);
begin
  if FDb = nil then
    Exit;
  if not RestoreDialog.Execute then
    Exit;
  if MessageDlg('The database becomes what is in ' + ExtractFileName(RestoreDialog.FileName) +
    '; what was changed after it is lost.', 'Restore', [mrYes, mrCancel], True) <> mrYes then
    Exit;
  try
    FDb.Restore(RestoreDialog.FileName);
    FTable := '';
    FColumnCache.Clear;
    ShowTables;
    Status('Restored from ' + RestoreDialog.FileName);
  except
    on E: Exception do
      Failed(E);
  end;
end;

procedure TMainForm.ExportClick(Sender: TObject);
var
  Rows: TJSONArray;
  Cols: TStringArray;
  BaseName: string;
  C: TColumnInfo;
begin
  if (Pages.TabIndex = 2) and (FResultRows <> nil) then
  begin
    Rows := FResultRows;
    Cols := FResultColumns;
    BaseName := 'query';
  end
  else if FDataRows <> nil then
  begin
    Rows := FDataRows;
    Cols := nil;
    for C in FColumns do
      Cols := Concat(Cols, [C.Name]);
    BaseName := FTable;
  end
  else
  begin
    ShowMessage('Open a table or run a query first.', 'Pastel DB');
    Exit;
  end;
  ExportDialog.FileName := BaseName + '.csv';
  if not ExportDialog.Execute then
    Exit;
  try
    ExportRows(Rows, Cols, ExportDialog.FileName, BaseName);
    Status(Format('%d rows written to %s', [Rows.Count, ExportDialog.FileName]));
  except
    on E: Exception do
      Failed(E);
  end;
end;

procedure TMainForm.DarkClick(Sender: TObject);
begin
  DarkItem.Checked := not DarkItem.Checked;
  UseDarkTheme(DarkItem.Checked);
end;

procedure TMainForm.QuitClick(Sender: TObject);
begin
  Close;
end;

end.
