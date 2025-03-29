{
  Notes:
  1. currently implementing DropBox only
  2. other cloud drivers will be gradually supported
}

unit MacCloudFunc;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils,
  WfxPlugin,
  uDropBoxClient,
  uMiniUtil;

function FsInitW(PluginNr:integer;pProgressProc:tProgressProcW;pLogProc:tLogProcW;pRequestProc:tRequestProcW):integer; cdecl;
function FsFindFirstW(path:pwidechar;var FindData:tWIN32FINDDATAW):thandle; cdecl;
function FsFindNextW(Hdl:thandle;var FindData:tWIN32FINDDATAW):bool; cdecl;
function FsFindClose(Hdl:thandle):integer; cdecl;
function FsGetFileW(RemoteName,LocalName:pwidechar;CopyFlags:integer;RemoteInfo:pRemoteInfo):integer; cdecl;
function FsPutFileW(LocalName,RemoteName:pwidechar;CopyFlags:integer):integer; cdecl;
function FsMkDirW(RemoteDir:pwidechar):bool; cdecl;
function FsDeleteFileW(RemoteName:pwidechar):bool; cdecl;
function FsRemoveDirW(RemoteName:pwidechar):bool; cdecl;
function FsRenMovFileW(OldName,NewName:pwidechar;Move,OverWrite:bool;RemoteInfo:pRemoteInfo):integer; cdecl;
function FsGetBackgroundFlags:integer; cdecl;
procedure FsGetDefRootName(DefRootName:pchar;maxlen:integer); cdecl;

implementation

var
  PluginNumber: integer;
  ProgressProc: TProgressProcW;
  LogProc: TLogProcW;
  RequestProc: TRequestProcW;

  client: TDropBoxClient;

type

  ULONGLONG  = qword;

  ULARGE_INTEGER = record
     case byte of
       0: (LowPart : DWORD;
           HighPart : DWORD);
       1: (QuadPart : ULONGLONG);
    end;

function FileTimeToDateTime(AFileTime: FILETIME): TDateTime;
var
  li: ULARGE_INTEGER;
const
  OA_ZERO_TICKS = UInt64(94353120000000000);
  TICKS_PER_DAY = UInt64(864000000000);
begin
  // Convert a FILETIME (which is UTC by definition), into a UTC TDateTime.

  // Copy FILETIME into LARGE_INTEGER to allow UInt64 access without alignment faults.
  li.LowPart := AFileTime.dwLowDateTime;
  li.HighPart := AFileTime.dwHighDateTime;
  Result := (Real(li.QuadPart) - OA_ZERO_TICKS) / TICKS_PER_DAY;
end;

function DateTimeToFileTime(ADateTimeUTC: TDateTime): FILETIME;
var
  li: ULARGE_INTEGER;
const
  OA_ZERO_TICKS = UInt64(94353120000000000);
  TICKS_PER_DAY = UInt64(864000000000);
begin
  // Convert a UTC TDateTime into a FILETIME (which is UTC by definition).

  li.QuadPart := Round(ADateTimeUtc*TICKS_PER_DAY + OA_ZERO_TICKS);
  Result.dwLowDateTime := li.LowPart;
  Result.dwHighDateTime := li.HighPart;
end;

procedure wfxLogProc( const MsgType: Integer; const message: String );
var
  buffer: Array [0..1024*10-1] of widechar;
begin
  TStringUtil.stringToWidechars( buffer, 'MacCloud: ' + message, sizeof(buffer) );
  LogProc( PluginNumber, MsgType, buffer );
end;

function exceptionToResult( const e: Exception ): Integer;
begin
  TLogUtil.log( msgtype_importanterror, e.ClassName + ': ' + e.Message );

  if e is EAbort then
    Result:= FS_FILE_USERABORT
  else if e is EFileNotFoundException then
    Result:= FS_FILE_NOTFOUND
  else if e is EInOutError then
    Result:= FS_FILE_WRITEERROR
  else
    Result:= FS_FILE_NOTSUPPORTED;
end;

function FsInitW(PluginNr:integer;pProgressProc:tProgressProcW;pLogProc:tLogProcW;
                pRequestProc:tRequestProcW):integer; cdecl;
var
  config: TDropBoxConfig;
begin
  PluginNumber:= PluginNr;
  ProgressProc:= pProgressProc;
  LogProc:= pLogProc;
  RequestProc:= pRequestProc;

  TLogUtil.setLogProc( @wfxLogProc );

  config:= TDropBoxConfig.Create( '10mwuvryt76yise', 'dc-10mwuvryt76yise://dropbox/auth' );
  client:= TDropBoxClient.Create( config );
  try
    client.authorize;
  except
    on e: Exception do
      exceptionToResult( e );
  end;
  Result:= 0
end;


procedure DbFileToWinFindData( dbFile: TDropBoxFile; var FindData:tWIN32FINDDATAW );
var
  li: ULARGE_INTEGER;
begin
  FillChar(FindData, SizeOf(FindData), 0);
  if dbFile.isFolder then
    FindData.dwFileAttributes:= FILE_ATTRIBUTE_DIRECTORY
  else
    FindData.dwFileAttributes:= 0;
  li.QuadPart:= dbFile.size;
  FindData.nFileSizeLow:= li.LowPart;
  FindData.nFileSizeHigh:= li.HighPart;
  FindData.ftCreationTime:= DateTimeToFileTime( dbFile.clientModified );
  FindData.ftLastWriteTime:= DateTimeToFileTime( dbFile.serverModified );
  TStringUtil.stringToWidechars( FindData.cFileName, dbFile.name, sizeof(FindData.cFileName) );
  dbFile.Free;
end;

function FsFindFirstW(path:pwidechar;var FindData:tWIN32FINDDATAW):thandle; cdecl;
var
  dbFile: TDropBoxFile;
begin
  client.listFolderBegin( TStringUtil.widecharsToString(path) );
  dbFile:= client.listFolderGetNextFile;
  if dbFile = nil then begin
    Result:= wfxInvalidHandle;
    Exit;
  end;

  DbFileToWinFindData( dbFile, FindData );
  Result:= 0;
end;

function FsFindNextW(Hdl:thandle;var FindData:tWIN32FINDDATAW):bool; cdecl;
var
  dbFile: TDropBoxFile;
begin
  dbFile:= client.listFolderGetNextFile;
  if dbFile = nil then begin
    Result:= False;
    Exit;
  end;

  DbFileToWinFindData( dbFile, FindData );
  Result:= True;
end;

function FsFindClose(Hdl:thandle):integer; cdecl;
begin
  client.listFolderEnd;
  Result:= 0;
end;

type

  { TProgressCallback }

  TProgressCallback = class( IDropBoxProgressCallback )
  private
    _progressProc: TProgressProcW;
    _pluginNumber: Integer;
    _serverPath: pwidechar;
    _localPath: pwidechar;
    _totalBytes: Integer;
  public
    constructor Create(
      const progressProc: TProgressProcW;
      const pluginNumber: Integer;
      const serverPath: pwidechar;
      const localPath: pwidechar;
      const totalBytes: Integer );
    function progress( const accumulatedBytes: Integer ): Boolean;
  end;

function FsGetFileW(RemoteName,LocalName:pwidechar;CopyFlags:integer;
  RemoteInfo:pRemoteInfo):integer; cdecl;
var
  serverPath: String;
  localPath: String;
  callback: TProgressCallback;
  totalBytes: Integer;
  li: ULARGE_INTEGER;
  exits: Boolean;

  function doGetFile: Integer;
  begin
    serverPath:= TStringUtil.widecharsToString( RemoteName );
    localPath:= TStringUtil.widecharsToString( LocalName );
    li.LowPart:= RemoteInfo^.SizeLow;
    li.HighPart:= RemoteInfo^.SizeHigh;
    totalBytes:= li.QuadPart;
    exits:= TFileUtil.exists( localPath );

    TLogUtil.logInformation(
      'FsGetFileW: remote=' + serverPath + ', local=' + localPath +
      ', CopyFlags=' + IntToStr(CopyFlags) + ', size=' + IntToStr(totalBytes) +
      ', LocalFileExists=' + BoolToStr(exits,True) );

    if (CopyFlags and FS_COPYFLAGS_RESUME <> 0) then
      Exit( FS_FILE_NOTSUPPORTED );
    if exits and (CopyFlags and FS_COPYFLAGS_OVERWRITE = 0) then
      Exit( FS_FILE_EXISTS );

    callback:= TProgressCallback.Create(
      ProgressProc,
      PluginNumber,
      RemoteName,
      LocalName,
      totalBytes );

    try
      callback.progress( 0 );
      client.download( serverPath, localPath, callback );
    finally
      callback.Free;
    end;

    Result:= FS_FILE_OK;
  end;

begin
  try
    Result:= doGetFile;
  except
    on e: Exception do
      Result:= exceptionToResult( e );
  end;
end;

function FsPutFileW(LocalName,RemoteName:pwidechar;CopyFlags:integer):integer; cdecl;
const
  FS_EXISTS = FS_COPYFLAGS_EXISTS_SAMECASE or FS_COPYFLAGS_EXISTS_DIFFERENTCASE;
var
  serverPath: String;
  localPath: String;
  callback: TProgressCallback;
  totalBytes: Integer;
  exits: Boolean;
  ret: Boolean;

  function doPutFile: Integer;
  begin
    serverPath:= TStringUtil.widecharsToString( RemoteName );
    localPath:= TStringUtil.widecharsToString( LocalName );
    totalBytes:= TFileUtil.filesize( localPath );
    exits:= (CopyFlags and FS_EXISTS <> 0);

    TLogUtil.logInformation(
      'FsPutFileW: remote=' + serverPath + ', local=' + localPath +
      ', CopyFlags=' + IntToStr(CopyFlags) + ', size=' + IntToStr(totalBytes) +
      ', RemoteFileExists=' + BoolToStr(exits,True) );

    if (CopyFlags and FS_COPYFLAGS_RESUME <> 0) then
      Exit( FS_FILE_NOTSUPPORTED );
    if exits and (CopyFlags and FS_COPYFLAGS_OVERWRITE = 0) then
      Exit( FS_FILE_EXISTS );

    callback:= TProgressCallback.Create(
      ProgressProc,
      PluginNumber,
      RemoteName,
      LocalName,
      totalBytes );

    try
      callback.progress( 0 );
      client.upload( serverPath, localPath, callback );
    finally
      callback.Free;
    end;

    Result:= FS_FILE_OK;
  end;

begin
  try
    Result:= doPutFile;
  except
    on e: Exception do
      Result:= exceptionToResult( e );
  end;
end;

function FsMkDirW(RemoteDir: pwidechar): bool; cdecl;
var
  path: String;
begin
  try
    path:= TStringUtil.widecharsToString( RemoteDir );
    client.createFolder( path );
    Result:= True;
  except
    on e: Exception do begin
      exceptionToResult( e );
      Result:= False;
    end;
  end;
end;

function FsDeleteFileW(RemoteName: pwidechar): bool; cdecl;
var
  path: String;
begin
  try
    path:= TStringUtil.widecharsToString( RemoteName );
    client.delete( path );
    Result:= True;
  except
    on e: Exception do begin
      exceptionToResult( e );
      Result:= False;
    end;
  end;
end;

function FsRemoveDirW(RemoteName: pwidechar): bool; cdecl;
var
  path: String;
begin
  try
    path:= TStringUtil.widecharsToString( RemoteName );
    client.delete( path );
    Result:= True;
  except
    on e: Exception do begin
      exceptionToResult( e );
      Result:= False;
    end;
  end;
end;

function FsRenMovFileW(OldName, NewName: pwidechar; Move, OverWrite: bool;
  RemoteInfo: pRemoteInfo): integer; cdecl;
var
  oldUtf8Path: String;
  newUtf8Path: String;
  ret: Boolean;
begin
  try
    oldUtf8Path:= TStringUtil.widecharsToString( OldName );
    newUtf8Path:= TStringUtil.widecharsToString( NewName );

    ret:= ProgressProc( PluginNumber, oldName, newName, 0 ) = 0;
    if ret then begin
      client.copyOrMove( oldUtf8Path, newUtf8Path, Move );
      ProgressProc( PluginNumber, oldName, newName, 100 );
      Result:= FS_FILE_OK
    end else
      Result:= FS_FILE_USERABORT;
  except
    on e: Exception do
      Result:= exceptionToResult( e );
  end;
end;

function FsGetBackgroundFlags:integer; cdecl;
begin
  Result:= BG_DOWNLOAD or BG_UPLOAD{ or BG_ASK_USER};
end;

procedure FsGetDefRootName(DefRootName: pchar; maxlen: integer); cdecl;
begin
  strlcopy( DefRootName, 'DropBox', maxlen );
end;


{ TDownloadCallback }

constructor TProgressCallback.Create(
  const progressProc: TProgressProcW;
  const pluginNumber: Integer;
  const serverPath: pwidechar;
  const localPath: pwidechar;
  const totalBytes: Integer);
begin
  _progressProc:= progressProc;
  _pluginNumber:= pluginNumber;
  _serverPath:= serverPath;
  _localPath:= localPath;
  _totalBytes:= totalBytes;
end;

function TProgressCallback.progress(const accumulatedBytes: Integer): Boolean;
var
  percent: Integer;
  ret: Integer;
begin
  if _totalBytes > 0 then
    percent:= accumulatedBytes * 100 div _totalBytes
  else
    percent:= 50;
  ret:= _progressProc( _pluginNumber, _serverPath, _localPath, percent );
  Result:= (ret = 0);
end;

end.
