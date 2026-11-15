{ Tests of DbMeta: connections, the tables of a SQLite file, statements, exports. }
unit dbmeta_test;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpjson, Pastel.Testing, Pastel.Db, Pastel.Sheets, DbMeta;

type
  TDbMetaTests = class(TTestSuite)
  published
    procedure Addresses;
    procedure SavedConnections;
    procedure TablesAndColumns;
    procedure Statements;
    procedure ExportFiles;
    procedure Servers;
    procedure History;
    procedure TableDesigner;
    procedure Importing;
  end;

implementation

uses
  Pastel.Files;

function Fresh(out Dir: string): TDatabase;
begin
  Dir := MakeTempDir('pastel-db');
  Result := TDatabase.Open('sqlite:' + Dir + 'test.db');
  Result.Exec('create table people (id integer primary key, name text not null, age integer)', []);
  Result.Exec('create table notes (body text)', []);
  Result.Exec('create view adults as select * from people where age >= 18', []);
  Result.Exec('insert into people (name, age) values (?, ?)', ['Ayşe', 34]);
  Result.Exec('insert into people (name, age) values (?, ?)', ['Ali', 12]);
end;

procedure TDbMetaTests.Addresses;
var
  C: TConnection;
begin
  C := Default(TConnection);
  C.FileName := '/data/shop.db';
  AssertEquals('sqlite:/data/shop.db', ConnectionUrl(C, ''));
  AssertEquals('shop.db', ConnectionTitle(C));
  C.Kind := ckPostgres;
  C.User := 'ali';
  C.Database := 'shop';
  C.Port := 5433;
  AssertEquals('postgres://ali:p%40ss%3Aw@localhost:5433/shop', ConnectionUrl(C, 'p@ss:w'));
  AssertEquals('ali@localhost/shop', ConnectionTitle(C));
  C.Kind := ckMySQL;
  C.Name := 'Shop server';
  AssertEquals('Shop server', ConnectionTitle(C));
  AssertTrue(Pos('mysql://', ConnectionUrl(C, '')) = 1);
end;

procedure TDbMetaTests.SavedConnections;
var
  Dir: string;
  L, Back: TConnections;
begin
  Dir := MakeTempDir('pastel-db');
  try
    SetLength(L, 2);
    L[0].Name := 'Local';
    L[0].FileName := '/tmp/a.db';
    L[1].Kind := ckPostgres;
    L[1].Host := 'db.example.com';
    L[1].Port := 5432;
    L[1].Database := 'shop';
    L[1].User := 'ali';
    SaveConnections(Dir + 'c.json', L);
    AssertFalse(Pos('password', ReadText(Dir + 'c.json')) > 0, 'no password in the file');
    Back := LoadConnections(Dir + 'c.json');
    AssertEquals(2, Length(Back));
    AssertEquals('/tmp/a.db', Back[0].FileName);
    AssertTrue(Back[1].Kind = ckPostgres);
    AssertEquals(5432, Back[1].Port);
    AssertEquals(0, Length(LoadConnections(Dir + 'none.json')));
  finally
    DeleteDir(Dir);
  end;
end;

procedure TDbMetaTests.TablesAndColumns;
var
  Db: TDatabase;
  Dir: string;
  T, V: TStringArray;
  C: TColumnInfos;
  R: TJSONArray;
begin
  Db := Fresh(Dir);
  try
    T := TableNames(Db, V);
    AssertEquals(2, Length(T));
    AssertEquals('notes', T[0]);
    AssertEquals('people', T[1]);
    AssertEquals(1, Length(V));
    AssertEquals('adults', V[0]);
    C := TableColumns(Db, 'people');
    AssertEquals(3, Length(C));
    AssertTrue(C[0].IsKey, 'id is the key');
    AssertFalse(C[1].Nullable, 'name is not null');
    AssertEquals('INTEGER', UpperCase(C[2].DataType));
    R := Db.Query(PageSql(Db, 'people', 'age > 18', 'id', 0, 10), []);
    try
      AssertEquals(1, R.Count);
      AssertEquals('Ayşe', CellText(R.Objects[0], 'name'));
    finally
      R.Free;
    end;
    AssertEquals(2, Db.QueryInt(CountSql(Db, 'people', ''), [], 0));
    AssertEquals('"we""ird"', QuoteName(Db, 'we"ird'));
  finally
    Db.Free;
    DeleteDir(Dir);
  end;
end;

procedure TDbMetaTests.Statements;
var
  S: TStringArray;
begin
  S := SplitStatements('select 1; insert into t values (''a;b''); -- a ; comment' + LineEnding +
    '/* ; */ update t set x = 1;');
  AssertEquals(3, Length(S));
  AssertEquals('insert into t values (''a;b'')', S[1]);
  AssertTrue(GivesRows(S[0]));
  AssertFalse(GivesRows(S[1]));
  AssertTrue(GivesRows('  -- the list' + LineEnding + 'WITH x as (select 1) select * from x'));
  AssertTrue(GivesRows('insert into t (a) values (1) returning id'));
  AssertTrue(GivesRows('pragma table_info(t)'));
end;

procedure TDbMetaTests.ExportFiles;
var
  Db: TDatabase;
  Dir: string;
  R: TJSONArray;
  F: string;
begin
  Db := Fresh(Dir);
  try
    R := Db.Query('select * from people order by id', []);
    try
      AssertEquals(3, Length(ColumnsOf(R)));
      for F in TStringArray.Create('out.csv', 'out.xlsx', 'out.pdf', 'out.json') do
      begin
        ExportRows(R, ColumnsOf(R), Dir + F, 'people');
        AssertTrue(FileExists(Dir + F), F);
      end;
      AssertTrue(Pos('Ayşe', ReadText(Dir + 'out.csv')) > 0);
      AssertTrue(Copy(ReadText(Dir + 'out.pdf'), 1, 5) = '%PDF-');
      AssertTrue(Copy(ReadText(Dir + 'out.xlsx'), 1, 2) = 'PK');
    finally
      R.Free;
    end;
  finally
    Db.Free;
    DeleteDir(Dir);
  end;
end;

{ PostgreSQL and MySQL when their test databases are there (PASTEL_TEST_POSTGRES_URL, PASTEL_TEST_MYSQL_URL) }
function Designed: TColumnInfos;
begin
  Result := nil;
  SetLength(Result, 3);
  Result[0].Name := 'id';
  Result[0].DataType := 'integer';
  Result[0].IsKey := True;
  Result[0].AutoNumber := True;
  Result[1].Name := 'title';
  Result[1].DataType := 'varchar(80)';
  Result[2].Name := 'state';
  Result[2].DataType := 'varchar(10)';
  Result[2].DefaultValue := '''new''';
  Result[2].Nullable := True;
end;

procedure TDbMetaTests.Servers;
var
  Url: string;
  Db: TDatabase;
  T, V: TStringArray;
  C: TColumnInfos;
  R: TJSONArray;
  Tested: Integer;
begin
  Tested := 0;
  for Url in TStringArray.Create(GetEnvironmentVariable('PASTEL_TEST_POSTGRES_URL'),
    GetEnvironmentVariable('PASTEL_TEST_MYSQL_URL')) do
  begin
    if Url = '' then
      Continue;
    Db := TDatabase.Open(Url);
    try
      Db.Exec('drop view if exists pdb_adults', []);
      Db.Exec('drop table if exists pdb_people', []);
      Db.Exec('create table pdb_people (id integer primary key, name varchar(40) not null, age integer default 7)', []);
      Db.Exec('create view pdb_adults as select * from pdb_people where age >= 18', []);
      Db.Exec('insert into pdb_people (id, name, age) values (1, ?, 34), (2, ?, 12)', ['Ayşe', 'Ali']);
      T := TableNames(Db, V);
      AssertTrue(Pos('pdb_people', string.Join(',', T)) > 0, Url + ': ' + string.Join(',', T));
      AssertTrue(Pos('pdb_adults', string.Join(',', V)) > 0, Url + ': views ' + string.Join(',', V));
      AssertFalse(Pos('pdb_adults', string.Join(',', T)) > 0, 'a view is not a table');
      C := TableColumns(Db, 'pdb_people');
      AssertEquals(3, Length(C), Url);
      AssertTrue(C[0].IsKey and not C[1].IsKey, Url + ': the key');
      AssertFalse(C[1].Nullable, Url + ': not null');
      AssertTrue(Pos('7', C[2].DefaultValue) > 0, Url + ': default ' + C[2].DefaultValue);
      R := Db.Query(PageSql(Db, 'pdb_people', 'age > 18', 'id', 0, 10), []);
      try
        AssertEquals(1, R.Count, Url);
        AssertEquals('Ayşe', CellText(R.Objects[0], 'name'));
      finally
        R.Free;
      end;
      AssertEquals(2, Db.QueryInt(CountSql(Db, 'pdb_people', ''), [], 0));
      { importing into the existing table: numbers as numbers }
      AssertEquals(2, ImportRows(Db, 'pdb_people', ParseCsv('ID,Name,age'#10'3,Can,40'#10'4,Ece,'#10), False), Url);
      AssertEquals(1, Db.QueryInt('select count(*) from pdb_people where age is null', [], 0), Url + ': empty: null');
      AssertEquals(40, Db.QueryInt('select age from pdb_people where id = 3', [], 0), Url);
      { a new table from a file, and the designer's SQL }
      Db.Exec('drop table if exists pdb_prices', []);
      AssertEquals(2, ImportRows(Db, 'pdb_prices', ParseCsv('item,price,count'#10'Cut,12.5,3'#10'Wash,8,10'#10), True), Url);
      AssertEquals('20.5', Db.QueryValue('select sum(price) from pdb_prices', [], ''), Url);
      Db.Exec('drop table pdb_prices', []);
      Db.Exec('drop table if exists pdb_made', []);
      Db.Exec(CreateTableSql(Db.Kind, 'pdb_made', Designed), []);
      Db.Exec('insert into pdb_made (title) values (?)', ['one']);
      Db.Exec('insert into pdb_made (title) values (?)', ['two']);
      AssertEquals(2, Db.QueryInt('select max(id) from pdb_made', [], 0), Url + ': numbered');
      AssertEquals('new', Db.QueryValue('select state from pdb_made where id = 1', [], ''), Url + ': the default');
      C := TableColumns(Db, 'pdb_made');
      AssertTrue(C[0].IsKey and not C[1].Nullable, Url);
      Db.Exec('drop table pdb_made', []);
      Db.Exec('drop view pdb_adults', []);
      Db.Exec('drop table pdb_people', []);
      Inc(Tested);
    finally
      Db.Free;
    end;
  end;
  if Tested = 0 then
    Skip('no test servers (PASTEL_TEST_POSTGRES_URL, PASTEL_TEST_MYSQL_URL)');
end;

procedure TDbMetaTests.History;
var
  Dir, F: string;
  It: THistoryItem;
  H: THistory;
  Q: TStringArray;
  I: Integer;
begin
  Dir := MakeTempDir('pastel-db');
  F := Dir + 'history.json';
  AssertEquals(0, Length(LoadHistory(F)), 'none yet');
  It := Default(THistoryItem);
  It.When := EncodeDate(2026, 11, 15) + EncodeTime(10, 30, 0, 0);
  It.Connection := 'shop.db';
  It.Sql := 'select 1';
  It.Rows := 1;
  AddHistory(F, It);
  It.Sql := 'select 2';
  It.Failed := True;
  AddHistory(F, It);
  It.Sql := 'select 1';
  It.Failed := False;
  AddHistory(F, It);
  H := LoadHistory(F);
  AssertEquals(2, Length(H), 'the same SQL again moves up');
  AssertEquals('select 1', H[0].Sql);
  AssertTrue(H[1].Failed);
  AssertEquals('shop.db', H[0].Connection);
  AssertTrue(Abs(H[0].When - It.When) < 1 / 86400, 'the time');
  for I := 1 to 20 do
  begin
    It.Sql := 'select ' + IntToStr(I + 10);
    AddHistory(F, It, 5);
  end;
  AssertEquals(5, Length(LoadHistory(F)), 'kept at most 5');
  SaveQueries(Dir + 'q.json', TStringArray.Create('select *'#10'from a', ''));
  Q := LoadQueries(Dir + 'q.json');
  AssertEquals(2, Length(Q));
  AssertEquals('select *'#10'from a', Q[0]);
  AssertEquals('select * …', SqlTitle('-- the list'#10'select *'#10'from a'));
  AssertEquals('drop table x', SqlTitle('  drop table x  '));
  Q := TStringArray.Create('customers', 'orders');
  AssertEquals('customers', AliasTable('select c. from customers c join orders as o on', 'c', Q));
  AssertEquals('orders', AliasTable('select c. from customers c join orders as o on', 'O', Q));
  AssertEquals('orders', AliasTable('select ORDERS.', 'ORDERS', Q), 'the name as the database has it');
  AssertEquals('customers', AliasTable('from public.customers x', 'x', Q));
  AssertEquals('', AliasTable('select x.', 'x', Q));
end;

procedure TDbMetaTests.TableDesigner;
var
  Dir: string;
  Db: TDatabase;
  C: TColumnInfos;
  S: string;
begin
  S := CreateTableSql(dbSQLite, 'tasks', Designed);
  AssertTrue(Pos('"id" integer primary key autoincrement', S) > 0, S);
  AssertTrue(Pos('"title" varchar(80) not null', S) > 0, S);
  AssertTrue(Pos('"state" varchar(10) default ''new''', S) > 0, S);
  S := CreateTableSql(dbPostgres, 'tasks', Designed);
  AssertTrue((Pos('"id" serial', S) > 0) and (Pos('primary key ("id")', S) > 0), S);
  S := CreateTableSql(dbMySQL, 'tasks', Designed);
  AssertTrue(Pos('`id` integer auto_increment', S) > 0, S);
  Db := Fresh(Dir);
  try
    Db.Exec(CreateTableSql(Db.Kind, 'tasks', Designed), []);
    Db.Exec('insert into tasks (title) values (?)', ['Paint']);
    C := TableColumns(Db, 'tasks');
    AssertEquals(3, Length(C));
    AssertTrue(C[0].IsKey);
    AssertEquals('new', Db.QueryValue('select state from tasks', [], ''));
    S := '';
    try
      CreateTableSql(dbSQLite, ' ', Designed);
    except
      on E: Exception do
        S := E.Message;
    end;
    AssertEquals('the table needs a name', S);
  finally
    Db.Free;
  end;
end;

procedure TDbMetaTests.Importing;
var
  Dir: string;
  Db: TDatabase;
  C: TColumnInfos;
  Failed: Boolean;
begin
  Db := Fresh(Dir);
  try
    AssertEquals(3, ImportRows(Db, 'prices', ParseCsv('Item,Price,Count,Code'#10'Cut,12.5,3,007'#10 +
      'Wash,8,10,010'#10',,,'#10'Dry,,1,1'#10), True), 'the empty row is skipped');
    C := TableColumns(Db, 'prices');
    AssertEquals('text', LowerCase(C[0].DataType));
    AssertEquals('real', LowerCase(C[1].DataType));
    AssertEquals('integer', LowerCase(C[2].DataType));
    AssertEquals('text', LowerCase(C[3].DataType), '007 stays a text');
    AssertEquals('007', Db.QueryValue('select Code from prices where Item = ''Cut''', [], ''));
    AssertEquals(1, Db.QueryInt('select count(*) from prices where Price is null', [], 0));
    { into a table that is there; names in any case }
    AssertEquals(1, ImportRows(Db, 'people', ParseCsv('NAME,age'#10'Can,40'#10), False));
    AssertEquals(3, Db.QueryInt('select count(*) from people', [], 0));
    Failed := False;
    try
      ImportRows(Db, 'people', ParseCsv('name,shoe'#10'X,42'#10), False);
    except
      on E: Exception do
      begin
        Failed := Pos('shoe', E.Message) > 0;
      end;
    end;
    AssertTrue(Failed, 'a column the table has not');
    AssertEquals(3, Db.QueryInt('select count(*) from people', [], 0), 'nothing went in');
    { a failing row: none of them }
    Failed := False;
    try
      ImportRows(Db, 'people', ParseCsv('name,age'#10'Ok,1'#10',2'#10), False);
    except
      Failed := True;
    end;
    AssertTrue(Failed, 'name is not null');
    AssertEquals(3, Db.QueryInt('select count(*) from people', [], 0), 'one transaction');
  finally
    Db.Free;
  end;
end;

initialization
  RegisterTests(TDbMetaTests);

end.
