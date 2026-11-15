{ Pastel DB - what is in a database, the saved connections, and exporting.
  No forms here: the tests use it as it is. }
unit DbMeta;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpjson, Pastel.Db, Pastel.Sheets;

type
  TConnKind = (ckSQLite, ckPostgres, ckMySQL);

  TConnection = record
    Name: string;
    Kind: TConnKind;
    FileName, Host, Database, User: string;
    Port: Integer;
  end;
  TConnections = array of TConnection;

  TColumnInfo = record
    Name, DataType, DefaultValue: string;
    Nullable, IsKey: Boolean;
    AutoNumber: Boolean;        { the table designer: numbered by the database }
  end;
  TColumnInfos = array of TColumnInfo;

  { A query that ran (the history). }
  THistoryItem = record
    When: TDateTime;
    Connection, Sql: string;
    Rows, Ms: Integer;
    Failed: Boolean;
  end;
  THistory = array of THistoryItem;
  TVarRecs = array of TVarRec;

{ The address for TDatabase.Open (the password not kept anywhere else). }
function ConnectionUrl(const C: TConnection; const Password: string): string;
{ What it is called in the list: its name, else the file or user@host/database. }
function ConnectionTitle(const C: TConnection): string;
function LoadConnections(const FileName: string): TConnections;
procedure SaveConnections(const FileName: string; const L: TConnections);
{ The connections' file in the user's settings. }
function ConnectionsFile: string;

function QuoteName(Db: TDatabase; const Name: string): string;
{ Tables and views; a view's name ends with ' (view)' in Titles. }
function TableNames(Db: TDatabase; out Views: TStringArray): TStringArray;
function TableColumns(Db: TDatabase; const Table: string): TColumnInfos;
{ A page of a table: select ... where ... limit ... offset ... }
function PageSql(Db: TDatabase; const Table, Where, OrderBy: string; Offset, Limit: Integer): string;
function CountSql(Db: TDatabase; const Table, Where: string): string;
{ About how many rows a table has, from the server's statistics (MySQL,
  PostgreSQL; no counting); -1 when it does not know (SQLite). }
function EstimatedRows(Db: TDatabase; const Table: string): Int64;
{ The statements of a script: split at ; outside quotes and comments. }
function SplitStatements(const Sql: string): TStringArray;
{ True for statements that give rows (select, with, pragma, show, explain...). }
function GivesRows(const Statement: string): Boolean;
{ The columns of rows: those of the first row, in their order. }
function ColumnsOf(Rows: TJSONArray): TStringArray;
{ Rows into a file: .csv, .xlsx, .pdf or .json (by its extension). }
procedure ExportRows(Rows: TJSONArray; const Columns: TStringArray; const FileName, Title: string);
{ A cell of a row as text ('' for null). }
function CellText(Row: TJSONObject; const Column: string): string;

{ The settings' files: the history and the query tabs. }
function HistoryFile: string;
function QueriesFile: string;
{ The newest first. }
function LoadHistory(const FileName: string): THistory;
{ Adds it first (the same SQL again moves up); Keep at most. }
procedure AddHistory(const FileName: string; const Item: THistoryItem; Keep: Integer = 500);
function LoadQueries(const FileName: string): TStringArray;
procedure SaveQueries(const FileName: string; const Queries: TStringArray);
{ The table an alias stands for in Sql ('from customers c': c is customers),
  or Alias itself when it is a table's name; '' when not known. }
function AliasTable(const Sql, Alias: string; const Tables: TStringArray): string;
{ The first line of a statement, for a list. }
function SqlTitle(const Sql: string): string;

{ The table designer: create table ... for this database. }
function CreateTableSql(Kind: TDbKind; const Table: string; const Columns: TColumnInfos): string;
{ A value for a column of that type as a parameter: a number for a number
  column ('42' as 42, so PostgreSQL takes it), nil (null) for 'NULL'. }
function ParamFor(const DataType, Value: string; NullWord: Boolean): TVarRec;
{ Frees what ParamFor made. }
procedure FreeParams(var A: array of TVarRec);
{ Rows of a spreadsheet (the first one: the column names) into Table, in one
  transaction; CreateTable makes it first with types guessed from the values.
  Empty cells are null. Returns how many rows went in. }
function ImportRows(Db: TDatabase; const Table: string; const Rows: TSheetRows; CreateTable: Boolean): Integer;

implementation

uses
  Pastel.Files, Pastel.Config, Pastel.Report, Pastel.Json, StrUtils, DateUtils;

function Enc(const S: string): string;
const
  Safe = ['A'..'Z', 'a'..'z', '0'..'9', '-', '_', '.', '~'];
var
  C: Char;
begin
  Result := '';
  for C in S do
    if C in Safe then
      Result := Result + C
    else
      Result := Result + '%' + IntToHex(Ord(C), 2);
end;

function ConnectionUrl(const C: TConnection; const Password: string): string;
var
  Auth, Host: string;
begin
  if C.Kind = ckSQLite then
    Exit('sqlite:' + C.FileName);
  Auth := Enc(C.User);
  if Password <> '' then
    Auth := Auth + ':' + Enc(Password);
  if Auth <> '' then
    Auth := Auth + '@';
  Host := C.Host;
  if Host = '' then
    Host := 'localhost';
  if C.Port > 0 then
    Host := Host + ':' + IntToStr(C.Port);
  if C.Kind = ckPostgres then
    Result := 'postgres://'
  else
    Result := 'mysql://';
  Result := Result + Auth + Host + '/' + Enc(C.Database);
end;

function ConnectionTitle(const C: TConnection): string;
begin
  if C.Name <> '' then
    Result := C.Name
  else if C.Kind = ckSQLite then
    Result := ExtractFileName(C.FileName)
  else
  begin
    Result := C.Database;
    if C.User <> '' then
      Result := C.User + '@' + IfThen(C.Host = '', 'localhost', C.Host) + '/' + Result;
  end;
end;

function ConnectionsFile: string;
begin
  Result := JoinPath([UserConfigDir('pastel-db'), 'connections.json']);
end;

function LoadConnections(const FileName: string): TConnections;
var
  D: TJSONData;
  A: TJSONArray;
  O: TJSONObject;
  I: Integer;
begin
  Result := nil;
  if not FileExists(FileName) then
    Exit;
  try
    D := GetJSON(ReadText(FileName));
  except
    Exit;
  end;
  try
    if not (D is TJSONArray) then
      Exit;
    A := TJSONArray(D);
    SetLength(Result, A.Count);
    for I := 0 to A.Count - 1 do
    begin
      O := A.Objects[I];
      Result[I].Name := O.Get('name', '');
      Result[I].Kind := TConnKind(O.Get('kind', 0) mod 3);
      Result[I].FileName := O.Get('file', '');
      Result[I].Host := O.Get('host', '');
      Result[I].Port := O.Get('port', 0);
      Result[I].Database := O.Get('database', '');
      Result[I].User := O.Get('user', '');
    end;
  finally
    D.Free;
  end;
end;

procedure SaveConnections(const FileName: string; const L: TConnections);
var
  A: TJSONArray;
  O: TJSONObject;
  C: TConnection;
begin
  A := TJSONArray.Create;
  try
    for C in L do
    begin
      O := TJSONObject.Create;
      O.Add('name', C.Name);
      O.Add('kind', Ord(C.Kind));
      O.Add('file', C.FileName);
      O.Add('host', C.Host);
      O.Add('port', C.Port);
      O.Add('database', C.Database);
      O.Add('user', C.User);
      A.Add(O);
    end;
    ForceDirectories(ExtractFileDir(FileName));
    WriteText(FileName, A.FormatJSON);
  finally
    A.Free;
  end;
end;

function QuoteName(Db: TDatabase; const Name: string): string;
begin
  if Db.Kind = dbMySQL then
    Result := '`' + StringReplace(Name, '`', '``', [rfReplaceAll]) + '`'
  else
    Result := '"' + StringReplace(Name, '"', '""', [rfReplaceAll]) + '"';
end;

function Strings(Rows: TJSONArray; const Field: string): TStringArray;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, Rows.Count);
  for I := 0 to Rows.Count - 1 do
    Result[I] := CellText(Rows.Objects[I], Field);
end;

function TableNames(Db: TDatabase; out Views: TStringArray): TStringArray;
var
  T, V: TJSONArray;
begin
  case Db.Kind of
    dbSQLite:
      begin
        T := Db.Query('select name from sqlite_master where type = ''table'' and name not like ''sqlite_%'' order by name', []);
        V := Db.Query('select name from sqlite_master where type = ''view'' order by name', []);
      end;
    dbPostgres:
      begin
        T := Db.Query('select table_name as name from information_schema.tables where table_type = ''BASE TABLE'' ' +
          'and table_schema = current_schema() order by table_name', []);
        V := Db.Query('select table_name as name from information_schema.views where table_schema = current_schema() ' +
          'order by table_name', []);
      end;
  else
    T := Db.Query('select table_name as name from information_schema.tables where table_type = ''BASE TABLE'' ' +
      'and table_schema = database() order by table_name', []);
    V := Db.Query('select table_name as name from information_schema.views where table_schema = database() ' +
      'order by table_name', []);
  end;
  try
    Result := Strings(T, 'name');
    Views := Strings(V, 'name');
  finally
    T.Free;
    V.Free;
  end;
end;

function TableColumns(Db: TDatabase; const Table: string): TColumnInfos;
var
  R, K: TJSONArray;
  I: Integer;
  O: TJSONObject;
  Keys: TStringArray;
  S: string;
begin
  Result := nil;
  case Db.Kind of
    dbSQLite:
      begin
        R := Db.Query('select name, type, "notnull", dflt_value, pk from pragma_table_info(?)', [Table]);
        try
          SetLength(Result, R.Count);
          for I := 0 to R.Count - 1 do
          begin
            O := R.Objects[I];
            Result[I].Name := CellText(O, 'name');
            Result[I].DataType := CellText(O, 'type');
            Result[I].Nullable := CellText(O, 'notnull') = '0';
            Result[I].DefaultValue := CellText(O, 'dflt_value');
            Result[I].IsKey := (CellText(O, 'pk') <> '0') and (CellText(O, 'pk') <> '');
          end;
        finally
          R.Free;
        end;
        Exit;
      end;
    dbPostgres:
      begin
        R := Db.Query('select column_name as name, data_type as type, is_nullable as nullable, column_default as dflt ' +
          'from information_schema.columns where table_schema = current_schema() and table_name = ? ' +
          'order by ordinal_position', [Table]);
        K := Db.Query('select k.column_name as name from information_schema.table_constraints c ' +
          'join information_schema.key_column_usage k on k.constraint_name = c.constraint_name ' +
          'and k.table_schema = c.table_schema and k.table_name = c.table_name ' +
          'where c.constraint_type = ''PRIMARY KEY'' and c.table_schema = current_schema() and c.table_name = ?', [Table]);
      end;
  else
    begin
      R := Db.Query('select column_name as name, column_type as type, is_nullable as nullable, column_default as dflt ' +
        'from information_schema.columns where table_schema = database() and table_name = ? ' +
        'order by ordinal_position', [Table]);
      K := Db.Query('select column_name as name from information_schema.columns where table_schema = database() ' +
        'and table_name = ? and column_key = ''PRI''', [Table]);
    end;
  end;
  try
    Keys := Strings(K, 'name');
    SetLength(Result, R.Count);
    for I := 0 to R.Count - 1 do
    begin
      O := R.Objects[I];
      Result[I].Name := CellText(O, 'name');
      Result[I].DataType := CellText(O, 'type');
      Result[I].Nullable := SameText(CellText(O, 'nullable'), 'YES');
      Result[I].DefaultValue := CellText(O, 'dflt');
      Result[I].IsKey := False;
      for S in Keys do
        if S = Result[I].Name then
          Result[I].IsKey := True;
    end;
  finally
    R.Free;
    K.Free;
  end;
end;

function PageSql(Db: TDatabase; const Table, Where, OrderBy: string; Offset, Limit: Integer): string;
begin
  Result := 'select * from ' + QuoteName(Db, Table);
  if Trim(Where) <> '' then
    Result := Result + ' where ' + Where;
  if OrderBy <> '' then
    Result := Result + ' order by ' + QuoteName(Db, OrderBy);
  Result := Result + Format(' limit %d offset %d', [Limit, Offset]);
end;

function CountSql(Db: TDatabase; const Table, Where: string): string;
begin
  Result := 'select count(*) from ' + QuoteName(Db, Table);
  if Trim(Where) <> '' then
    Result := Result + ' where ' + Where;
end;

function SplitStatements(const Sql: string): TStringArray;
var
  I, Start: Integer;
  Q: Char;
  S: string;

  procedure Take(Upto: Integer);
  begin
    S := Trim(Copy(Sql, Start, Upto - Start));
    if S <> '' then
      Result := Concat(Result, [S]);
    Start := Upto + 1;
  end;

begin
  Result := nil;
  Start := 1;
  I := 1;
  Q := #0;
  while I <= Length(Sql) do
  begin
    if Q <> #0 then
    begin
      if Sql[I] = Q then
        Q := #0;
    end
    else if Sql[I] in ['''', '"', '`'] then
      Q := Sql[I]
    else if (Sql[I] = '-') and (I < Length(Sql)) and (Sql[I + 1] = '-') then
    begin
      while (I <= Length(Sql)) and (Sql[I] <> #10) do
        Inc(I);
      Continue;
    end
    else if (Sql[I] = '/') and (I < Length(Sql)) and (Sql[I + 1] = '*') then
    begin
      I := PosEx('*/', Sql, I + 2);
      if I = 0 then
        I := Length(Sql)
      else
        Inc(I, 2);
      Continue;
    end
    else if Sql[I] = ';' then
      Take(I);
    Inc(I);
  end;
  Take(Length(Sql) + 1);
end;

function GivesRows(const Statement: string): Boolean;
var
  S, W: string;
  I: Integer;
begin
  S := TrimLeft(Statement);
  { the first word, after comments }
  while (Copy(S, 1, 2) = '--') or (Copy(S, 1, 2) = '/*') do
    if Copy(S, 1, 2) = '--' then
    begin
      I := Pos(#10, S);
      if I = 0 then Exit(False);
      S := TrimLeft(Copy(S, I + 1, MaxInt));
    end
    else
    begin
      I := Pos('*/', S);
      if I = 0 then Exit(False);
      S := TrimLeft(Copy(S, I + 2, MaxInt));
    end;
  I := 1;
  while (I <= Length(S)) and (S[I] in ['a'..'z', 'A'..'Z']) do
    Inc(I);
  W := LowerCase(Copy(S, 1, I - 1));
  Result := (W = 'select') or (W = 'with') or (W = 'pragma') or (W = 'show') or (W = 'explain') or
    (W = 'describe') or (W = 'desc') or (W = 'values') or (W = 'table') or
    (Pos(' returning ', LowerCase(S) + ' ') > 0);
end;

function CellText(Row: TJSONObject; const Column: string): string;
var
  D: TJSONData;
  Fs: TFormatSettings;
begin
  D := Row.Find(Column);
  if (D = nil) or (D.JSONType = jtNull) then
    Result := ''
  else if D.JSONType in [jtArray, jtObject] then
    Result := D.AsJSON
  else if D is TJSONFloatNumber then
  begin
    Fs := DefaultFormatSettings;
    Fs.DecimalSeparator := '.';
    Fs.ThousandSeparator := #0;
    Result := FloatToStrF(D.AsFloat, ffGeneral, 15, 0, Fs);     { 20.5, not 2.05E+001 }
  end
  else
    Result := D.AsString;
end;

function ColumnsOf(Rows: TJSONArray): TStringArray;
var
  I: Integer;
  O: TJSONObject;
begin
  Result := nil;
  if (Rows = nil) or (Rows.Count = 0) or not (Rows[0] is TJSONObject) then
    Exit;
  O := Rows.Objects[0];
  SetLength(Result, O.Count);
  for I := 0 to O.Count - 1 do
    Result[I] := O.Names[I];
end;

procedure ExportRows(Rows: TJSONArray; const Columns: TStringArray; const FileName, Title: string);
var
  Ext: string;
  S: TSpreadsheet;
  R: TReport;
  V: array of Variant;
  Cells: array of string;
  Widths: array of Single;
  I, J: Integer;
  O: TJSONObject;
  D: TJSONData;
begin
  Ext := LowerCase(ExtractFileExt(FileName));
  if Ext = '.json' then
  begin
    WriteText(FileName, Rows.FormatJSON);
    Exit;
  end;
  if (Ext = '.csv') or (Ext = '.xlsx') then
  begin
    S := TSpreadsheet.Create(Copy(Title, 1, 31));
    try
      SetLength(V, Length(Columns));
      for J := 0 to High(Columns) do
        V[J] := Columns[J];
      S.Row(V, True);
      for I := 0 to Rows.Count - 1 do
      begin
        O := Rows.Objects[I];
        for J := 0 to High(Columns) do
        begin
          D := O.Find(Columns[J]);
          if (D = nil) or (D.JSONType = jtNull) then
            V[J] := ''
          else if D.JSONType = jtNumber then
            V[J] := D.AsFloat
          else if D.JSONType = jtBoolean then
            V[J] := D.AsBoolean
          else
            V[J] := CellText(O, Columns[J]);
        end;
        S.Row(V);
      end;
      S.SaveToFile(FileName);
    finally
      S.Free;
    end;
    Exit;
  end;
  if Ext = '.pdf' then
  begin
    R := TReport.Create('A4', Length(Columns) > 5);
    try
      R.Footer := Title + ' · {page} / {pages}';
      R.Title(Title);
      R.Note(Format('%d rows', [Rows.Count]));
      SetLength(Widths, Length(Columns));
      for J := 0 to High(Widths) do
        Widths[J] := 0;
      R.Table(Columns, Widths);
      SetLength(Cells, Length(Columns));
      for I := 0 to Rows.Count - 1 do
      begin
        for J := 0 to High(Columns) do
          Cells[J] := CellText(Rows.Objects[I], Columns[J]);
        R.Row(Cells);
      end;
      R.EndTable;
      R.SaveToFile(FileName);
    finally
      R.Free;
    end;
    Exit;
  end;
  raise Exception.CreateFmt('"%s": exports go to .csv, .xlsx, .pdf or .json', [ExtractFileName(FileName)]);
end;

{ ---- history and query tabs ---- }

function HistoryFile: string;
begin
  Result := JoinPath([UserConfigDir('pastel-db'), 'history.json']);
end;

function QueriesFile: string;
begin
  Result := JoinPath([UserConfigDir('pastel-db'), 'queries.json']);
end;

function LoadArray(const FileName: string): TJSONArray;
var
  D: TJSONData;
begin
  Result := nil;
  if not FileExists(FileName) then
    Exit;
  try
    D := GetJSON(ReadText(FileName));
  except
    Exit;
  end;
  if D is TJSONArray then
    Result := TJSONArray(D)
  else
    D.Free;
end;

function LoadHistory(const FileName: string): THistory;
var
  A: TJSONArray;
  O: TJSONObject;
  I: Integer;
begin
  Result := nil;
  A := LoadArray(FileName);
  if A = nil then
    Exit;
  try
    SetLength(Result, A.Count);
    for I := 0 to A.Count - 1 do
    begin
      O := A.Objects[I];
      Result[I].When := ISO8601ToDateDef(O.Get('when', ''), 0, False);
      Result[I].Connection := O.Get('connection', '');
      Result[I].Sql := O.Get('sql', '');
      Result[I].Rows := O.Get('rows', 0);
      Result[I].Ms := O.Get('ms', 0);
      Result[I].Failed := O.Get('failed', False);
    end;
  finally
    A.Free;
  end;
end;

procedure SaveHistory(const FileName: string; const H: THistory);
var
  A: TJSONArray;
  O: TJSONObject;
  It: THistoryItem;
begin
  A := TJSONArray.Create;
  try
    for It in H do
    begin
      O := TJSONObject.Create;
      O.Add('when', DateToISO8601(It.When, False));
      O.Add('connection', It.Connection);
      O.Add('sql', It.Sql);
      O.Add('rows', It.Rows);
      O.Add('ms', It.Ms);
      if It.Failed then
        O.Add('failed', True);
      A.Add(O);
    end;
    ForceDirectories(ExtractFileDir(FileName));
    WriteText(FileName, A.FormatJSON);
  finally
    A.Free;
  end;
end;

procedure AddHistory(const FileName: string; const Item: THistoryItem; Keep: Integer);
var
  Old, New: THistory;
  It: THistoryItem;
begin
  if Trim(Item.Sql) = '' then
    Exit;
  Old := LoadHistory(FileName);
  New := nil;
  SetLength(New, 1);
  New[0] := Item;
  for It in Old do
    if (Length(New) < Keep) and not ((Trim(It.Sql) = Trim(Item.Sql)) and (It.Connection = Item.Connection)) then
      New := Concat(New, [It]);
  SaveHistory(FileName, New);
end;

function LoadQueries(const FileName: string): TStringArray;
var
  A: TJSONArray;
  I: Integer;
begin
  Result := nil;
  A := LoadArray(FileName);
  if A = nil then
    Exit;
  try
    for I := 0 to A.Count - 1 do
      if A.Types[I] = jtString then
        Result := Concat(Result, [A.Strings[I]]);
  finally
    A.Free;
  end;
end;

procedure SaveQueries(const FileName: string; const Queries: TStringArray);
var
  A: TJSONArray;
  Q: string;
begin
  A := TJSONArray.Create;
  try
    for Q in Queries do
      A.Add(Q);
    ForceDirectories(ExtractFileDir(FileName));
    WriteText(FileName, A.FormatJSON);
  finally
    A.Free;
  end;
end;

function SqlTitle(const Sql: string): string;
var
  L: TStringArray;
  S: string;
begin
  Result := '';
  L := Trim(Sql).Split([#10]);
  for S in L do
    if (Trim(S) <> '') and not Trim(S).StartsWith('--') then
    begin
      Result := Trim(S);
      Break;
    end;
  if Result = '' then
    Result := Trim(Sql);
  if Length(L) > 1 then
    Result := Result + ' …';
  if Length(Result) > 120 then
    Result := Copy(Result, 1, 117) + '...';
end;

{ ---- the table designer ---- }

function IsNumberType(const DataType: string): Boolean;
var
  T: string;
begin
  T := LowerCase(DataType);
  Result := (Pos('int', T) > 0) or (Pos('real', T) > 0) or (Pos('double', T) > 0) or (Pos('float', T) > 0) or
    (Pos('numeric', T) > 0) or (Pos('decimal', T) > 0) or (T = 'serial') or (T = 'bigserial');
end;

function IsIntegerType(const DataType: string): Boolean;
begin
  Result := (Pos('int', LowerCase(DataType)) > 0) or (Pos('serial', LowerCase(DataType)) > 0);
end;

function KindQuote(Kind: TDbKind; const Name: string): string;
begin
  if Kind = dbMySQL then
    Result := '`' + StringReplace(Name, '`', '``', [rfReplaceAll]) + '`'
  else
    Result := '"' + StringReplace(Name, '"', '""', [rfReplaceAll]) + '"';
end;

function CreateTableSql(Kind: TDbKind; const Table: string; const Columns: TColumnInfos): string;
var
  C: TColumnInfo;
  Keys: TStringArray;
  Line, T: string;
  Lines: TStringArray;
  InlineKey: Boolean;
begin
  if Trim(Table) = '' then
    raise Exception.Create('the table needs a name');
  if Length(Columns) = 0 then
    raise Exception.Create('the table needs a column');
  Keys := nil;
  for C in Columns do
  begin
    if Trim(C.Name) = '' then
      raise Exception.Create('a column has no name');
    if C.IsKey then
      Keys := Concat(Keys, [KindQuote(Kind, Trim(C.Name))]);
  end;
  Lines := nil;
  InlineKey := False;
  for C in Columns do
  begin
    T := Trim(C.DataType);
    if T = '' then
      T := 'text';
    if C.AutoNumber then
      case Kind of
        dbPostgres:
          if Pos('big', LowerCase(T)) > 0 then T := 'bigserial' else T := 'serial';
        dbSQLite:
          T := 'integer';
      end;
    Line := '  ' + KindQuote(Kind, Trim(C.Name)) + ' ' + T;
    if (Kind = dbSQLite) and C.AutoNumber and C.IsKey and (Length(Keys) = 1) then
    begin
      Line := Line + ' primary key autoincrement';
      InlineKey := True;
    end
    else
    begin
      if (Kind = dbMySQL) and C.AutoNumber then
        Line := Line + ' auto_increment';
      if not C.Nullable and not C.IsKey then
        Line := Line + ' not null';
      if Trim(C.DefaultValue) <> '' then
        Line := Line + ' default ' + Trim(C.DefaultValue);
    end;
    Lines := Concat(Lines, [Line]);
  end;
  if (Length(Keys) > 0) and not InlineKey then
    Lines := Concat(Lines, ['  primary key (' + string.Join(', ', Keys) + ')']);
  Result := 'create table ' + KindQuote(Kind, Trim(Table)) + ' (' + LineEnding +
    string.Join(',' + LineEnding, Lines) + LineEnding + ')';
end;

function ParamFor(const DataType, Value: string; NullWord: Boolean): TVarRec;
var
  I: Int64;
  F: Double;
  Fs: TFormatSettings;
begin
  Result := Default(TVarRec);
  if NullWord and (Value = 'NULL') then
  begin
    Result.VType := vtPointer;
    Result.VPointer := nil;
    Exit;
  end;
  Fs := DefaultFormatSettings;
  Fs.DecimalSeparator := '.';
  if IsIntegerType(DataType) and TryStrToInt64(Trim(Value), I) then
  begin
    Result.VType := vtInt64;
    New(Result.VInt64);
    Result.VInt64^ := I;
  end
  else if IsNumberType(DataType) and TryStrToFloat(Trim(Value), F, Fs) then
  begin
    Result.VType := vtExtended;
    New(Result.VExtended);
    Result.VExtended^ := F;
  end
  else
  begin
    Result.VType := vtAnsiString;
    Result.VAnsiString := nil;
    AnsiString(Result.VAnsiString) := Value;
  end;
end;

procedure FreeParams(var A: array of TVarRec);
var
  I: Integer;
begin
  for I := 0 to High(A) do
    case A[I].VType of
      vtInt64: Dispose(A[I].VInt64);
      vtExtended: Dispose(A[I].VExtended);
      vtAnsiString: AnsiString(A[I].VAnsiString) := '';
    end;
end;

{ the type a column of a spreadsheet gets: whole numbers, numbers or text }
function GuessType(Kind: TDbKind; const Rows: TSheetRows; Col: Integer): string;
var
  R: Integer;
  V: string;
  Ints, Nums, Any: Boolean;
  I: Int64;
  F: Double;
  Fs: TFormatSettings;
begin
  Fs := DefaultFormatSettings;
  Fs.DecimalSeparator := '.';
  Ints := True;
  Nums := True;
  Any := False;
  for R := 1 to High(Rows) do
  begin
    if Col > High(Rows[R]) then
      Continue;
    V := Trim(Rows[R][Col]);
    if V = '' then
      Continue;
    Any := True;
    if not TryStrToInt64(V, I) or ((Length(V) > 1) and (V[1] = '0')) then
      Ints := False;
    if not TryStrToFloat(V, F, Fs) or ((Length(V) > 1) and (V[1] = '0') and (V[2] <> '.')) then
      Nums := False;
  end;
  if Any and Ints then
    if Kind = dbSQLite then Result := 'integer' else Result := 'bigint'
  else if Any and Nums then
    case Kind of
      dbSQLite: Result := 'real';
      dbPostgres: Result := 'double precision';
    else
      Result := 'double';
    end
  else
    Result := 'text';
end;

function ImportRows(Db: TDatabase; const Table: string; const Rows: TSheetRows; CreateTable: Boolean): Integer;
var
  Heads, Types, Missing: TStringArray;
  Cols: TColumnInfos;
  Fresh: TColumnInfos;
  I, J, R: Integer;
  Sql, Marks, V: string;
  Tx: TDbTransaction;
  Args: array of TVarRec;
  Found: Boolean;
begin
  Result := 0;
  if Length(Rows) = 0 then
    raise Exception.Create('the file has no rows');
  Heads := nil;
  for I := 0 to High(Rows[0]) do
    Heads := Concat(Heads, [Trim(Rows[0][I])]);
  { columns without a name at the end: nothing }
  while (Length(Heads) > 0) and (Heads[High(Heads)] = '') do
    SetLength(Heads, Length(Heads) - 1);
  if Length(Heads) = 0 then
    raise Exception.Create('the first row needs the names of the columns');
  for I := 0 to High(Heads) do
    if Heads[I] = '' then
      raise Exception.CreateFmt('column %d has no name in the first row', [I + 1]);
  SetLength(Types, Length(Heads));
  if CreateTable then
  begin
    Fresh := nil;
    SetLength(Fresh, Length(Heads));
    for I := 0 to High(Heads) do
    begin
      Fresh[I].Name := Heads[I];
      Fresh[I].DataType := GuessType(Db.Kind, Rows, I);
      Fresh[I].Nullable := True;
      Types[I] := Fresh[I].DataType;
    end;
    Db.Exec(CreateTableSql(Db.Kind, Table, Fresh), []);
  end
  else
  begin
    Cols := TableColumns(Db, Table);
    Missing := nil;
    for I := 0 to High(Heads) do
    begin
      Found := False;
      for J := 0 to High(Cols) do
        if SameText(Cols[J].Name, Heads[I]) then
        begin
          Heads[I] := Cols[J].Name;
          Types[I] := Cols[J].DataType;
          Found := True;
          Break;
        end;
      if not Found then
        Missing := Concat(Missing, [Heads[I]]);
    end;
    if Length(Missing) > 0 then
      raise Exception.CreateFmt('%s has no column %s', [Table, string.Join(', ', Missing)]);
  end;
  Sql := '';
  Marks := '';
  for I := 0 to High(Heads) do
  begin
    if I > 0 then
    begin
      Sql := Sql + ', ';
      Marks := Marks + ', ';
    end;
    Sql := Sql + QuoteName(Db, Heads[I]);
    Marks := Marks + '?';
  end;
  Sql := 'insert into ' + QuoteName(Db, Table) + ' (' + Sql + ') values (' + Marks + ')';
  SetLength(Args, Length(Heads));
  Tx := Db.BeginTransaction;
  try
    for R := 1 to High(Rows) do
    begin
      { an empty row: skipped }
      Found := False;
      for J := 0 to High(Rows[R]) do
        if Trim(Rows[R][J]) <> '' then
          Found := True;
      if not Found then
        Continue;
      for I := 0 to High(Heads) do
      begin
        if I <= High(Rows[R]) then V := Rows[R][I] else V := '';
        if V = '' then
        begin
          Args[I] := Default(TVarRec);
          Args[I].VType := vtPointer;
        end
        else
          Args[I] := ParamFor(Types[I], V, False);
      end;
      try
        Tx.Exec(Sql, Args);
      finally
        FreeParams(Args);
      end;
      Inc(Result);
    end;
    Tx.Commit;
  finally
    Tx.Free;
  end;
end;

function AliasTable(const Sql, Alias: string; const Tables: TStringArray): string;
var
  Words: TStringArray;
  W: string;
  I, J, K: Integer;

  function TableOf(const S: string): string;
  var
    T: string;
  begin
    Result := '';
    for T in Tables do
      if SameText(T, S) then
        Exit(T);
  end;

begin
  Result := TableOf(Alias);
  if Result <> '' then
    Exit;
  { the words of the SQL, without quotes }
  Words := nil;
  W := '';
  for I := 1 to Length(Sql) + 1 do
    if (I <= Length(Sql)) and (Sql[I] in ['A'..'Z', 'a'..'z', '0'..'9', '_', '$', '.', #128..#255]) then
      W := W + Sql[I]
    else if W <> '' then
    begin
      Words := Concat(Words, [W]);
      W := '';
    end;
  for J := 0 to High(Words) - 1 do
  begin
    K := J + 1;
    if SameText(Words[K], 'as') and (K < High(Words)) then
      Inc(K);
    { schema.table: the table's part }
    W := Words[J];
    if Pos('.', W) > 0 then
      W := Copy(W, LastDelimiter('.', W) + 1, MaxInt);
    if SameText(Words[K], Alias) and (TableOf(W) <> '') then
      Exit(TableOf(W));
  end;
end;

function EstimatedRows(Db: TDatabase; const Table: string): Int64;
begin
  Result := -1;
  try
    case Db.Kind of
      dbMySQL:
        Result := Db.QueryInt('select table_rows from information_schema.tables ' +
          'where table_schema = database() and table_name = ?', [Table], -1);
      dbPostgres:
        Result := Db.QueryInt('select reltuples::bigint from pg_class where oid = to_regclass(?)',
          [QuoteName(Db, Table)], -1);
    end;
  except
    Result := -1;
  end;
end;

end.
