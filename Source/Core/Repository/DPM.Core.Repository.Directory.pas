{***************************************************************************}
{                                                                           }
{           Delphi Package Manager - DPM                                    }
{                                                                           }
{           Copyright � 2019 Vincent Parrett and contributors               }
{                                                                           }
{           vincent@finalbuilder.com                                        }
{           https://www.finalbuilder.com                                    }
{                                                                           }
{                                                                           }
{***************************************************************************}
{                                                                           }
{  Licensed under the Apache License, Version 2.0 (the "License");          }
{  you may not use this file except in compliance with the License.         }
{  You may obtain a copy of the License at                                  }
{                                                                           }
{      http://www.apache.org/licenses/LICENSE-2.0                           }
{                                                                           }
{  Unless required by applicable law or agreed to in writing, software      }
{  distributed under the License is distributed on an "AS IS" BASIS,        }
{  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. }
{  See the License for the specific language governing permissions and      }
{  limitations under the License.                                           }
{                                                                           }
{***************************************************************************}

unit DPM.Core.Repository.Directory;

interface

uses
  Generics.Defaults,
  Spring.Collections,
  DPM.Core.Types,
  DPM.Core.Dependency.Version,
  DPM.Core.Logging,
  DPM.Core.Options.Search,
  DPM.Core.Package.Interfaces,
  DPM.Core.Configuration.Interfaces,
  DPM.Core.Repository.Interfaces;

  //TODO : makes this work for structured folders too
  //eg : \Vsoft.AntPattterns\Win32
  //     \Vsoft.AntPatterns\Win64
  // see https://docs.microsoft.com/en-au/nuget/reference/cli-reference/cli-ref-add

type
  TDirectoryPackageRepository = class(TInterfacedObject, IPackageRepository)
  private
    FLogger : ILogger;
    FIsLocal: Boolean;
    FIsRemote: Boolean;
    FName: string;
    FSource: string;
  protected
    function DoSearch(searchTerm : string; const compilerVersion : TCompilerVersion; const platform : TDPMPlatform) : IList<string>;
    function DoExactSearch(const id : string; const compilerVersion : TCompilerVersion; const platform : TDPMPlatform; const version : string) : IList<string>;


    procedure Init(const source : ISourceConfig; const isRemote : boolean);
    function GetIsLocal: Boolean;
    function GetIsRemote: Boolean;
    function GetName: string;
    function GetSource: string;
    function Search(const options : TSearchOptions): IList<IPackageIdentity>;overload;
    function Search(const id : string; const range : TVersionRange) :  IList<IPackageIdentity>;overload;
    function DownloadPackage(const packageMetadata : IPackageIdentity; const localFolder : string; var fileName : string ) : boolean;

    function GetPackageMetaData(const id : string; const version : TPackageVersion; const compilerVersion : TCompilerVersion; const platform : TDPMPlatform) : IPackageMetadata;overload;
    function GetPackageMetaData(const id : string; const version : TPackageVersion; const compilerVersion : TCompilerVersion; const platforms : TDPMPlatforms) : IList<IPackageMetadata>;overload;

    function GetPackageVersions(const id : string; const compilerVersion : TCompilerVersion; const platform : TDPMPlatform; const versionRange : TVersionRange; const preRelease : boolean) : IList<TPackageVersion>;
    function GetPackageVersionsWithDependencies(const id: string; const compilerVersion: TCompilerVersion; const platform: TDPMPlatform; const versionRange: TVersionRange; const preRelease: Boolean): IList<IPackageInfo>;

    function GetPackageInfo(const packageIdentity: IPackageIdentity): IPackageInfo;overload;
    function GetPackageInfo(const fileName : string) : IPackageInfo; overload;

  public
    constructor Create(const logger : ILogger);
  end;

implementation

uses
  VSoft.Uri,
  System.Types,
  System.SysUtils,
  System.IOUtils,
  System.RegularExpressions,
  System.Zip,
  Spring.Collections.Enumerable,
  Spring.Collections.Extensions,
  DPM.Core.Constants,
  DPM.Core.Package.Metadata,
  DPM.Core.Spec.Interfaces,
  DPM.Core.Spec.Reader,
  DPM.Core.Utils.Strings,
  DPM.Core.Utils.Path;

{ TDirectoryPackageRespository }

function GetSearchRegex(const compilerVersion : TCompilerVersion; const platforms : TDPMPlatforms; const version : string) : string;
begin
  // ^(\w+\.\w+)\-([^\-]+)\-([^\-]+)\-(.*)$';
  result := '^(\w+\.\w+)\-';
  if (compilerVersion > TCompilerVersion.UnknownVersion) then
    result := result + Format('(%s)\-', [CompilerToString(compilerVersion)])
  else
    result := result + '([^\-]+)\-';

  if platforms <> [] then
    result := result + Format('(%s)\-', [DPMPlatformsToString(platforms,'|')])
  else
    result := result + '([^\-]+)\-';

  if version <> '' then
    result := result + Format('(%s)$', [version])
  else
    result := result + '(.*)$';

end;




constructor TDirectoryPackageRepository.Create(const logger: ILogger);
begin
  FLogger := logger;
end;

function TDirectoryPackageRepository.DownloadPackage(const packageMetadata : IPackageIdentity; const localFolder : string; var fileName : string ) : boolean;
var
  sourceFile : string;
  destFile : string;
begin
  result := false;
  sourceFile := IncludeTrailingPathDelimiter(FSource) + packageMetadata.ToString + cPackageFileExt;
  if not FileExists(sourceFile) then
  begin
    FLogger.Error('File not found in repository [' + sourceFile + ']');
    exit;
  end;
  destFile := IncludeTrailingPathDelimiter(localFolder) + packageMetadata.ToString + cPackageFileExt;
  if TPathUtils.IsRelativePath(destFile) then
    destFile := TPath.GetFullPath(destFile);
  try
    ForceDirectories(ExtractFilePath(destFile));
    TFile.Copy(sourceFile, destFile,true );
    fileName := destFile;
    result := true;
  except
    on e : Exception do
    begin
      FLogger.Error('Error downloading  [' + sourceFile + '] to [' + destFile + ']');
    end;
  end;
end;

function TDirectoryPackageRepository.GetIsLocal: Boolean;
begin
  result := FIsLocal;
end;

function TDirectoryPackageRepository.GetIsRemote: Boolean;
begin
  result := FIsRemote;
end;

function TDirectoryPackageRepository.GetName: string;
begin
  result := FName;
end;

function TDirectoryPackageRepository.GetPackageMetaData(const id: string; const version: TPackageVersion; const compilerVersion : TCompilerVersion; const platform : TDPMPlatform): IPackageMetadata;
var
  packagFileName : string;
  zipFile : TZipFile;
  metaBytes : TBytes;
  metaString : string;
  spec : IPackageSpec;
  reader : IPackageSpecReader;
begin
  result := nil;
  packagFileName := Format('%s-%s-%s-%s.dpkg',[id, CompilerToString(compilerVersion),DPMPlatformToString(platform), version.ToStringNoMeta]);
  packagFileName := IncludeTrailingPathDelimiter(FSource) + packagFileName;
  if not FileExists(packagFileName) then
    exit;



  zipFile := TZipFile.Create;
  try
    try
      zipFile.Open(packagFileName, TZipMode.zmRead);
      zipFile.Read(cPackageMetaFile, metaBytes);
    except
      on e : Exception do
      begin
        FLogger.Error('Error opening package file [' + packagFileName + ']');
        exit;
      end;
    end;
  finally
    zipFile.Free;
  end;
  //doing this outside the try/finally to avoid locking the package for too long.
  metaString := TEncoding.UTF8.GetString(metaBytes);
  reader := TPackageSpecReader.Create(FLogger);
  spec := reader.ReadSpecString(metaString);
  if spec = nil then
    exit;

//  result := TPackageMetadata


end;

function TDirectoryPackageRepository.GetPackageInfo(const packageIdentity: IPackageIdentity): IPackageInfo;
var
  packagFileName : string;
begin
  result := nil;
  packagFileName := Format('%s-%s-%s-%s.dpkg',[ packageIdentity.Id, CompilerToString(packageIdentity.CompilerVersion),DPMPlatformToString(PackageIdentity.Platform), packageIdentity.Version.ToStringNoMeta]);
  packagFileName := IncludeTrailingPathDelimiter(FSource) + packagFileName;
  if not FileExists(packagFileName) then
    exit;

  result := GetPackageInfo(packagFileName);
end;

function TDirectoryPackageRepository.GetPackageInfo(const fileName: string): IPackageInfo;
var
  zipFile : TZipFile;
  metaBytes : TBytes;
  metaString : string;
  spec : IPackageSpec;
  reader : IPackageSpecReader;
begin
  result := nil;
  zipFile := TZipFile.Create;
  try
    try
      zipFile.Open(fileName, TZipMode.zmRead);
      zipFile.Read(cPackageMetaFile, metaBytes);
    except
      on e : Exception do
      begin
        FLogger.Error('Error opening package file [' + fileName + ']');
        exit;
      end;
    end;
  finally
    zipFile.Free;
  end;
  //doing this outside the try/finally to avoid locking the package for too long.
  metaString := TEncoding.UTF8.GetString(metaBytes);
  reader := TPackageSpecReader.Create(FLogger);
  spec := reader.ReadSpecString(metaString);
  if spec = nil then
    exit;
  result := TPackageInfo.CreateFromSpec(FName,spec);
end;

function TDirectoryPackageRepository.GetPackageMetaData(const id: string; const version: TPackageVersion; const compilerVersion : TCompilerVersion; const platforms: TDPMPlatforms): IList<IPackageMetadata>;
var
  platform : TDPMPlatform;
  metadata : IPackageMetadata;
begin
  result := TCollections.CreateList<IPackageMetadata>;
  for platform in platforms do
  begin
    metadata := GetPackageMetaData(id,version, compilerVersion, platform );
    if metadata <> nil then
      result.Add(metadata);
  end;
end;

function TDirectoryPackageRepository.GetPackageVersions(const id: string; const compilerVersion: TCompilerVersion; const platform: TDPMPlatform; const versionRange: TVersionRange; const preRelease : boolean): IList<TPackageVersion>;
var
  searchFiles : IList<string>;
  regex : TRegEx;
  searchRegex : string;
  packageFile : string;
  match : TMatch;
  i : integer;
  packageVersion : TPackageVersion;
begin
  result := TCollections.CreateList<TPackageVersion>;
  searchFiles := DoExactSearch(id, compilerVersion, platform,'');

  searchRegEx := GetSearchRegex(compilerVersion, [platform], '');
  regex := TRegEx.Create(searchRegEx, [roIgnoreCase]);
  for i := 0 to searchFiles.Count -1  do
  begin
    //ensure that the files returned are actually packages

    packageFile := ChangeFileExt(ExtractFileName(searchFiles[i]),'');
    match := regex.Match(packageFile);
    if match.Success then
    begin
      if not TPackageVersion.TryParse(match.Groups[4].Value, packageVersion) then
        continue;
      if not prerelease then
        if not packageVersion.IsStable then
          continue;

      if versionRange.IsEmpty or versionRange.Satisfies(packageVersion) then
        result.Add(packageVersion);
    end;
  end;



//  result.Sort(function(const Left, Right: TPackageVersion): Integer
//              begin
//                   result := right.CompareTo(left);
//              end);

end;

function TDirectoryPackageRepository.GetPackageVersionsWithDependencies(const id: string; const compilerVersion: TCompilerVersion; const platform: TDPMPlatform; const versionRange: TVersionRange; const preRelease: Boolean): IList<IPackageInfo>;
var
  searchFiles : IList<string>;
  regex : TRegEx;
  searchRegex : string;
  packageFile : string;
  match : TMatch;
  i : integer;
  packageVersion : TPackageVersion;
  packageInfo : IPackageInfo;
begin
  result := TCollections.CreateList<IPackageInfo>;

  searchFiles := DoExactSearch(id, compilerVersion, platform,'');

  searchRegEx := GetSearchRegex(compilerVersion, [platform], '');
  regex := TRegEx.Create(searchRegEx, [roIgnoreCase]);
  for i := 0 to searchFiles.Count -1  do
  begin
    //ensure that the files returned are actually packages
    packageFile := ChangeFileExt(ExtractFileName(searchFiles[i]),'');
    match := regex.Match(packageFile);
    if match.Success then
    begin
      if not TPackageVersion.TryParse(match.Groups[4].Value, packageVersion) then
        continue;
      if not prerelease then
        if not packageVersion.IsStable then
          continue;

      packageInfo := GetPackageInfo(searchFiles[i]);
      result.Add(packageInfo);
    end;
  end;

  result.Sort(TComparer<IPackageInfo>.Construct(
    function(const Left, Right: IPackageInfo): Integer
    begin
      result := right.Version.CompareTo(left.Version);;
    end));


end;

function TDirectoryPackageRepository.GetSource: string;
begin
  result := FSource;
end;

procedure TDirectoryPackageRepository.Init(const source: ISourceConfig; const isRemote : boolean);
begin
  FName := source.Name;
  FSource := source.Source;
  FIsRemote := isRemote;
  FIsLocal := not FIsRemote;
end;

function TDirectoryPackageRepository.Search(const id: string; const range : TVersionRange): IList<IPackageIdentity>;
begin
  result := nil;
end;

function CompilerVersionToSearchPart(const compilerVersion : TCompilerVersion) : string;
begin
  case compilerVersion of
    TCompilerVersion.UnknownVersion: result := '*';
  else
    result := CompilerToString(compilerVersion);
  end;
end;

function TDirectoryPackageRepository.DoExactSearch(const id : string; const compilerVersion : TCompilerVersion; const platform : TDPMPlatform; const version : string) : IList<string>;
var
  searchTerm : string;
  files : TStringDynArray;
begin
  result := TCollections.CreateList<string>;
  searchTerm := id;
  searchTerm := searchTerm + '-' + CompilerVersionToSearchPart(compilerVersion) ;
  if platform = TDPMPlatform.UnknownPlatform then
    searchTerm := searchTerm + '-*'
  else
    searchTerm := searchTerm + '-' + DPMPlatformToString(platform);

  if version <> '' then
    searchTerm := searchTerm + '-' + version + cPackageFileExt
  else
   searchTerm := searchTerm + '-*'  + cPackageFileExt;

  files := TDirectory.GetFiles(FSource,searchTerm);
  //dedupe
  result.AddRange(Enumerable<string>.Create(files).Distinct(TStringComparer.OrdinalIgnoreCase));

end;

function TDirectoryPackageRepository.DoSearch(searchTerm : string; const compilerVersion : TCompilerVersion; const platform : TDPMPlatform) : IList<string>;
var
  files : TStringDynArray;
begin
  result := TCollections.CreateList<string>;
  if searchTerm <> '*' then
    searchTerm := '*' + searchTerm + '*';

  searchTerm := searchTerm + '-' + CompilerVersionToSearchPart(compilerVersion) ;

  if platform = TDPMPlatform.UnknownPlatform then
    searchTerm := searchTerm + '-*-*' + cPackageFileExt
  else
    searchTerm := searchTerm + '-' + DPMPlatformToString(platform) + '-*'  + cPackageFileExt;

  files := TDirectory.GetFiles(FSource,searchTerm);
  //dedupe
  result.AddRange(Enumerable<string>.Create(files).Distinct(TStringComparer.OrdinalIgnoreCase));

end;

function TDirectoryPackageRepository.Search(const options : TSearchOptions): IList<IPackageIdentity>;
var
  searchTerms : TArray<string>;
  searchFiles : IList<string>;
  allFiles : IList<string>;
  distinctFiles : IEnumerable<string>;
  i : integer;
  platform : TDPMPlatform;
  info : IPackageIdentity;
  searchRegEx : string;
  regex : TRegEx;
  packageFile : string;
  match : TMatch;
  id : string;
  cv : TCompilerVersion;
  version : string;
  packageVersion : TPackageVersion;
begin
  result := TCollections.CreateList<IPackageIdentity>;
  if options.SearchTerms <> '' then
    searchTerms := TStringUtils.SplitStr(Trim(options.SearchTerms), ' ');
  //need at least 1 search term, if there are none then search for *.
  if length(searchTerms) = 0 then
  begin
    SetLength(searchTerms,1);
    searchTerms[0] := '*';
  end;

  allFiles := TCollections.CreateList<string>;

  for i := 0 to Length(searchTerms) -1 do
  begin
    if options.Platforms = [] then
    begin
      if options.Exact then
        searchFiles := DoExactSearch(searchTerms[i], options.CompilerVersion, TDPMPlatform.UnknownPlatform, options.Version.ToStringNoMeta)
      else
        searchFiles := DoSearch(searchTerms[i], options.CompilerVersion, TDPMPlatform.UnknownPlatform);
      allFiles.AddRange(searchFiles);
    end
    else
    begin
      for platform in options.Platforms do
      begin
      if options.Exact then
        searchFiles := DoExactSearch(searchTerms[i], options.CompilerVersion, platform, options.Version.ToStringNoMeta)
      else
        searchFiles := DoSearch(searchTerms[i], options.CompilerVersion, platform);
        allFiles.AddRange(searchFiles);
      end;
    end;
  end;

  //dedupe
  distinctFiles := TDistinctIterator<string>.Create(allFiles, TStringComparer.OrdinalIgnoreCase);
  if options.Skip > 0 then
    distinctFiles := distinctFiles.Skip(options.Skip);
  if options.Take > 0 then
    distinctFiles.Take(options.Take);
  searchFiles.Clear;
  searchFiles.AddRange(distinctFiles);


  //do we really need to do a regex check here?
  searchRegEx := GetSearchRegex(options.CompilerVersion, options.Platforms, options.Version.ToStringNoMeta);
  regex := TRegEx.Create(searchRegEx, [roIgnoreCase]);
  for i := 0 to searchFiles.Count -1  do
  begin
    //ensure that the files returned are actually packages

    packageFile := ChangeFileExt(ExtractFileName(searchFiles[i]),'');
    match := regex.Match(packageFile);
    if match.Success then
    begin
      id := match.Groups[1].Value;
      cv := StringToCompilerVersion(match.Groups[2].Value);
      platform := StringToDPMPlatform(match.Groups[3].Value);
      version := match.Groups[4].Value;
      if not TPackageVersion.TryParse(version, packageVersion) then
        continue;
      if not options.Prerelease then
        if not packageVersion.IsStable then
          continue;
      //not using the trycreate here as we need a specific regex.
      info := TPackageIdentity.Create(id, FName, packageVersion, cv, platform);
      result.Add(info);
    end;
  end;

end;

end.
