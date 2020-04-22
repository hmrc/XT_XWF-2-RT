library LoadFileIngester;
{
  *** Requirements ***
  This X-Tension is designed for use only with X-Ways Forensics.
  This X-Tension is designed for use only with v18.9 or later (due to file category lookup).
  This X-Tension is not designed for use on Linux or OSX platforms.
  The case must have either MD5, SHA-1 or SHA256 hash algorithms computed.

  ** Usage Disclaimer ***
  This X-Tension is a Proof-Of-Concept Alpha level prototype, and is not finished. It has known
  limitations. You are NOT advised to use it, yet, for any evidential work for criminal courts.

  *** Functionality Overview ***
  The X-Tension creates a Relativity Loadfile from the users selected files.
  The user must execute it by right clicking the required files and then "Run X-Tensions".
  By default, the generated output will be written to the path specified in the
  supplied file : OutputLocation.txt. The folder does not have to exist before execution.
  This text file MUST be copied to the location of where
  X-Ways Forensics is running from. By default, the output location is
  c:\temp\RelativityOutput\
  Upon completion, the output can be injested into Relativity.

  TODOs
   // TODO TedSmith : Add a decompression library for
    * MS Office and
    * LibreOffice files and
    * Adobe PDF files
   // TODO TedSmith : Fix parent object lookup for items embedded in another object
     where the actual file parent seems to be being skipped, even if the remaining path is not.
   // TODO Ted Smith : Write user manual

  *** License ***
  This source code is open source software licensed under the Apache 2.0 License and
  The Open Government Licence (OGL) v3.0. This information is
  licensed under the terms of the Open Government Licence
  (http://www.nationalarchives.gov.uk/doc/open-government-licence and
  http://www.nationalarchives.gov.uk/doc/open-government-licence/version/3/).

  *** Collaboration ***
  Collaboration is welcomed, particularly from Delphi or Freepascal developers.
  This version was created using the Lazarus IDE v2.0.4 and Freepascal v3.0.4.
  (www.lazarus-ide.org)

}
{$mode Delphi}{$H+}
{$codepage utf8}

uses
  LazUTF8,
  lazutf8classes, // we need this unit to use TFileStreamUTF8 with UTF16toUTF8 function,
                  // which is needed to write filestream with eastern Unicode, e.g. Chinese chars etc)
  Classes,
  XT_API,         // This is the XWF X-Tension API itself
  windows,
  sysutils,
  dateutils,
  contnrs,
  FileUtil,
  Zipper;        // To enable exploration of compound Office files

  const
    BufEvdNameLen=4096;
    BufLen=2048;
var
  // These are global vars
  MainWnd                  : THandle;
  CurrentVolume            : THandle;
  VerRelease               : LongInt;
  ServiceRelease           : Byte;
  TotalDataInBytes         : Int64;
  HasAParent               : integer;
  RunFolderBuilderAgain    : Boolean;
  VerReleaseIsLessThan2000 : Boolean;
  VerRelease2000OrAbove    : Boolean;
  intOutputLength          : integer;
  slOutput                 : TStringlist;
  HashType                 : Int64;
  StartTime, EndTime       : TDateTime;
  TimeTaken, TextificationOutputPath : string;
  OutputSubFolderNative, OutputSubFolderText, OutputFolder : array[0..Buflen-1] of WideChar;

  // Evidence name is global for later filesave by name
  pBufEvdName              : array[0..BufEvdNameLen-1] of WideChar;

// XT_Init : The first call needed by the X-Tension API. Must return 1 for the X-Tension to continue.
function XT_Init(nVersion, nFlags: DWord; hMainWnd: THandle; lpReserved: Pointer): LongInt; stdcall; export;
begin
  VerReleaseIsLessThan2000 := false;
  VerRelease2000OrAbove    := false;
  // Get high 2 bytes from nVersion
  VerRelease := Hi(nVersion);
  // Get 3rd high byte for service release. We dont need it yet but we might one day
  ServiceRelease := HiByte(nVersion);

  // If the version of XWF is less than v18.9, abort.
  if VerRelease < 1890 then
  begin
     MessageBox(MainWnd, 'Error: ' +
                        ' Please execute this X-Tension using v18.9 or above ',
                        'Relativity LoadFile Generator', MB_ICONINFORMATION);


    result := -1;  // Should abort and not run any further
  end
  else  // If the version of XWF is less than v20.00 but greater than 18.9, continue but with advisory.
    if (VerRelease > 1890) and (VerRelease < 2000) then
    begin
      VerReleaseIsLessThan2000 := true;
      MessageBox(MainWnd, 'Warning: ' +
                              ' Limited support for compound files (e.g. DOCX) available. Advise use of XWF v20.00+ ',
                              'Relativity LoadFile Generator', MB_ICONINFORMATION);


      result := 1;  // Continue, with warning accepted
    end;

  // If the versioning is above 18.9, and regardless of whether it is less than v20.00 or higher, continue
  VerRelease2000OrAbove := true;
  TotalDataInBytes      := 0;
  FillChar(pBufEvdName, SizeOf(pBufEvdName), $00);

  // Check XWF is ready to go. 1 is normal mode, 2 is thread-safe. Using 1 for now
  if Assigned(XWF_OutputMessage) then
  begin
    Result := 1; // lets go
    MainWnd:= hMainWnd;
  end
  else Result := -1; // stop
end;


// FormatVersionRelease : Converts the "1980" style of version number to "19.8"
// Returns version as string on success
// We need to use a divsion to convert "1850" for example to a floating point.
// Then we can define the location of the decimal and the digit length of the string
// The outcome is "1850" becomes "v18.5"
function FormatVersionRelease(nVersion : LongInt) : widestring;
const
  RequiredFormat : TFormatSettings = (DecimalSeparator: '.');
begin
  result := '';
  result := FormatFloat('v##.#', nVersion/100.0, RequiredFormat);
end;
// Used by the button in the X-Tension dialog to tell the user about the X-Tension
// Must return 0
function XT_About(hMainWnd : THandle; lpReserved : Pointer) : Longword; stdcall; export;
begin
  result := 0;
  MessageBox(MainWnd,  ' Load File Generator for Relativity. An X-Tension for X-Ways Forensics. ' +
                       ' To be executed only via by XWF v18.9 or higher and via right click of selected files. ' +
                       ' Developed by HMRC, Crown Copyright applies (c) 2019.' +
                       ' Intended use : automates extraction of selected files, creating a Load File for Relativity.'
                      ,'Load File Generator v1.0 Beta', MB_ICONINFORMATION);
end;
// Returns a human formatted version of the time
function TimeStampIt(TheDate : TDateTime) : string; stdcall; export;
begin
  result := FormatDateTime('DD/MM/YYYY HH:MM:SS', TheDate);
end;

// Renders integers representing bytes into string format, e.g. 1MiB, 2GiB etc
function FormatByteSize(const bytes: QWord): string;  stdcall; export;
var
  B: byte;
  KB: word;
  MB: QWord;
  GB: QWord;
  TB: QWord;
begin

  B  := 1;         // byte
  KB := 1024 * B;  // kilobyte
  MB := 1024 * KB; // megabyte
  GB := 1024 * MB; // gigabyte
  TB := 1024 * GB; // terabyte

  if bytes > TB then
    result := FormatFloat('#.## TiB', bytes / TB)
  else
    if bytes > GB then
      result := FormatFloat('#.## GiB', bytes / GB)
    else
      if bytes > MB then
        result := FormatFloat('#.## MiB', bytes / MB)
      else
        if bytes > KB then
          result := FormatFloat('#.## KiB', bytes / KB)
        else
          result := FormatFloat('#.## bytes', bytes) ;
end;

// IsValidFilename : takes a filename string pointer and checks it does not contain
// '/' or ':' or '*' or ? etc. i.e. Windows illegal filename chars. If it does,
// it returns false. True otherwise
function IsValidFilename(s : unicodestring) : boolean;  stdcall; export;
var
  i : integer;
begin
  result := true;

  for i := 1 to Length(s) do
   begin
     if ((s[i] = #34) or    // the quote char "
         (s[i] = #42) or    // the asterix *
         (s[i] = #47) or    // the forward slash /
         (s[i] = #58) or    // the colon :
         (s[i] = #60) or    // the less than <
         (s[i] = #62) or    // the greater than >
         (s[i] = #63) or    // the question mark ?
         (s[i] = #124) or    // the pipe char |
         (s[i] = #92)) then // the backslash \
       begin
         result := false;
         exit; // We only need to check once. Once theres one invalid char, goodnight
       end;
   end;
end;

// SanistiseFilename : iterates the string and wherever an illegal char
// is found, it is replaced with an underscore
// It returns the new sanitised filename or an empty string on failure.
function SanitiseFilename(s : unicodestring) : unicodestring;
const
  BufLen=2048;
var
  s2 :  unicodestring;
  i : integer;
  Buf, Outputmessage : array[0..Buflen-1] of WideChar;
begin
  // Make sure length of new sanatised string is equal to original string
  SetLength(s2, length(s));

  for i := 1 to Length(s) do
   begin
     if ((s[i] = #34) or    // the quote char "
         (s[i] = #42) or    // the asterix *
         (s[i] = #47) or    // the forward slash /
         (s[i] = #58) or    // the colon :
         (s[i] = #60) or    // the less than <
         (s[i] = #62) or    // the greater than >
         (s[i] = #63) or    // the question mark ?
         (s[i] = #124) or    // the pipe char |
         (s[i] = #92)) then // the backslash \
       begin
         s2[i] := #95; // '_' char
       end
     else s2[i] := s[i];
   end;
  outputmessage := s + ' contained illegal characters and was sanitised with underscores.';
  lstrcpyw(Buf, outputmessage);
  XWF_OutputMessage(@Buf[0], 0);
  result := s2;
end;

// GetHashValue : returns a string representation of a hash value, if one exists.
// Returns empty string on failure.
function GetHashValue(ItemID : LongWord) : string ; stdcall; export;
var
  i               : integer;
  bufHashVal      : array of Byte;
  HashValue       : string;
  HasAHashValue   : boolean;
begin
  result := '';
  HashValue := '';
  // Set the buffer to the appropriate size for the hash type
  if HashType = 7 then
  SetLength(bufHashVal, 16)  // MD5 is 128 bits, 16 bytes, so 32 hex chars produced.
  else if HashType = 8 then
  SetLength(bufHashVal, 20)  // SHA-1 is 160 bits, 20 bytes, so 40 hex chars produced
  else if HashType = 9 then
  SetLength(bufHashVal, 40); // SHA-256 is 256 bits, 32 bytes, so 64 hex chars needed

  FillByte(HashValue, SizeOf(bufHashVal), $00);

  // XWF_GetHashValue returns the appropriate hash value as a digest, if one exists.
  // The buffer it stores it in has to start with 0x01 for the primary hash value
  bufHashVal[0] := $01;
  HasAHashValue := false;
  HasAHashValue := XWF_GetHashValue(ItemID, @bufHashVal[0]);

  // if a hash digest was returned, itterate it to a string
  if HasAHashValue then
  for i := 0 to Length(bufHashVal) -1 do
  begin
   HashValue := HashValue + IntToHex(bufHashVal[i],2);
  end;
  result := HashValue;
end;

// FileTimeToDateTime : Converts the Int64 nano-second based Windows filetime returned by
// XWF_GetItemInformation(nItemID,  XWF_ITEM_INFO_MODIFICATIONTIME, nil);
// to generic human readable string.
function FileTimeToDateTime(const FileTime: Int64): TDateTime; stdcall; export;
const
  // number of days elapsed between the years 1601 to 1900 (accounting for leap years etc)
  FileTimeBase           = -109205.0;
  // 100 nSek per Day
  FileTimeStep: Extended = 24.0 * 60.0 * 60.0 * 1000.0 * 1000.0 * 10.0;
begin
  Result := (FileTime) / FileTimeStep;
  Result := Result + FileTimeBase;
end;

function ExtractFileFromZip(ZipName : string) : string;
var
  UnZipper: TUnZipper;
begin
  result := '';
  UnZipper := TUnZipper.Create;
  try
    UnZipper.FileName := ZipName;
    UnZipper.OutputPath := TextificationOutputPath;
    UnZipper.Examine;
    UnZipper.UnZipAllFiles(ZipName);
    if FileExists(Unzipper.OutputPath + '\word\' + 'document.xml') then
      result := Unzipper.OutputPath + '\word\' + 'document.xml'
    else
      if FileExists(Unzipper.OutputPath + 'content.xml') then
          result := Unzipper.OutputPath + 'content.xml'
          else result := '';
  finally
    UnZipper.Free;
  end;
end;

// GetOutputLocation : Open OutputLocation.txt and get the path from line 1 and
// return that string. Returns empty string on failure
function GetOutputLocation() : widestring; stdcall; export;
const
  C_FNAME = 'OutputLocation.txt';

var
  UserFile  : Text;
  FileName,
    TFile   : String;
begin
  result              := '';
  intOutputLength     := 0;
  FileName            := C_FNAME;

  Assign(UserFile, FileName);
  Reset(UserFile); { 'Reset' means open the file x and reset cursor to the beginning of file }
  Repeat
    Readln(UserFile,TFile);
  Until Eof(UserFile);

  // Get the length of the output path. We need this for later to make sure long filenames dont break Windows
  intOutputLength := Length(TFile);
  // Close the file
  Close(UserFile);
  // Switch the result to a UTF16 string for Windows and return that as result
  result := UTF8ToUTF16(TFile);
end;

// CreateFolderStructure : CreateFolderStructure creates the output folders for the data to live in
function CreateFolderStructure(RootOutputFolderName : array of widechar) : boolean; stdcall; export;
const
  BufLen=2048;
var
  Buf, outputmessage : array[0..Buflen-1] of WideChar;

begin
  result                := false;
  OutputSubFolderNative := IncludeTrailingPathDelimiter(RootOutputFolderName) + 'NATIVE';
  OutputSubFolderText   := IncludeTrailingPathDelimiter(RootOutputFolderName) + 'TEXT';

  if not DirectoryExists(RootOutputFolderName) then
    begin
      CreateDir(RootOutputFolderName);
    end;

  if not DirectoryExists(OutputSubFolderNative) then
    begin
      CreateDir(OutputSubFolderNative);
    end;

  if not DirectoryExists(OutputSubFolderText) then
    begin
      CreateDir(OutputSubFolderText);
    end;

  outputmessage := 'Output folders created successfully : OK. Now processing files...';
  lstrcpyw(Buf, outputmessage);
  XWF_OutputMessage(@Buf[0], 0);

  RunFolderBuilderAgain := false; // prevent execution of this function for remainder of file items
  result := true;
end;

// Gets the case name, and currently selected evidence object, and the image size
// and stores as a header for writing to HTML output later. Returns true on success. False otherwise.
{ Not currently used...
function GetEvdData(hEvd : THandle) : boolean; stdcall; export;
const
  BufLen=4096;
var
  Buf            : array[0..BufLen-1] of WideChar;
  pBufCaseName   : array[0..Buflen-1] of WideChar;
  CaseProperty, EvdSize, intEvdName : Int64;

begin
  result := false;
  // Get the case name, to act as the title in the output file, and store in pBufCaseName
  // XWF_CASEPROP_TITLE = 1, thus that value passed
  CaseProperty := -1;
  CaseProperty := XWF_GetCaseProp(nil, 1, @pBufCaseName[0], Length(pBufCaseName));

  // Get the item size of the evidence object. 16 = Evidence Total Size
  EvdSize := -1;
  EvdSize := XWF_GetEvObjProp(hEvd, 16, nil);

  // Get the evidence object name and store in pBufEvdName. 7 = object name
  intEvdName := -1;
  intEvdName := XWF_GetEvObjProp(hEvd, 7, @pBufEvdName[0]);

  lstrcpyw(Buf, 'Case properties established : OK');
  XWF_OutputMessage(@Buf[0], 0);
  result := true;
end;
}

// XT_Prepare : used for every evidence object involved in execution
function XT_Prepare(hVolume, hEvidence : THandle; nOpType : DWord; lpReserved : Pointer) : integer; stdcall; export;
var
  outputmessage, Buf  : array[0..MAX_PATH] of WideChar;
  OutputFoldersCreatedOK : boolean;
begin
  FillChar(outputmessage, Length(outputmessage), $00);
  FillChar(Buf, Length(Buf), $00);
  OutputFoldersCreatedOK := false;
  HashType := -1;
  RunFolderBuilderAgain := true;
  if nOpType <> 4 then
  begin
    MessageBox(MainWnd, 'Error: ' +
                        ' Please execute this X-Tension by right clicking one '    +
                        ' or more selected files only. Not via RVS or main menu. ' +
                        ' Thank you.','Relativity LoadFile Generator v1.0 Beta', MB_ICONINFORMATION);

    // Tell XWF to abort if the user attempts another mode of execution, by returning -3
    result := -3;
  end
  else
    begin
      // We need our X-Tension to return 0x01, 0x08, 0x10, and 0x20, depending on exactly what we want
      // We can change the result using or combinations as we need, as follows:
      // Call XT_ProcessItem for each item in the evidence object : (0x01)  : XT_PREPARE_CALLPI
      result         := XT_PREPARE_CALLPI;

       StartTime     := Now;
       outputmessage := 'X-Tension execution started at ' + FormatDateTime('DD/MM/YY HH:MM:SS',StartTime) + ' using XWF '+FormatVersionRelease(VerRelease) + '...please wait...';
       lstrcpyw(Buf, outputmessage);
       XWF_OutputMessage(@Buf[0], 0);

      CurrentVolume := hVolume;            // Make sure the right column is set

      HashType := XWF_GetVSProp(20, nil);  // Work out what hash algorithm was used for the case. Correct as XWF v19.8
                                          {
                                          0: undefined
                                          1: CS8
                                          2: CS16
                                          3: CS32
                                          4: CS64
                                          5: CRC16
                                          6: CRC32
                                          7: MD5
                                          8: SHA-1
                                          9: SHA-256
                                          10: RIPEMD-128
                                          11: RIPEMD-160
                                          12: MD4
                                          13: ED2K
                                          14: Adler32
                                          15: Tiger Tree Hash (TTH, from v18.1)
                                          16: Tiger128 (from v18.1)
                                          17: Tiger160 (from v18.1)
                                          18: Tiger192 (from v18.1)
                                          }

      try
        // Initiate the LoadFile structure
        slOutput := TStringList.Create;
        // Populate the loadfile, using Unicode TAB character value. Not comma,
        // because sometimes e-mail attachments contain comma in the name
        // These values enable Auto Mapping of XWF fields to Relativity fields
        // Control Number        | in Relativity is Unique ID in XWF
        // Primary Document Name | in Relativity is the native Filename in XWF
        // Extracted Text        | in Relativity is the location of the text based version of the native file
        // Hash                  | in Relativity is the computed hash from XWF
        // Primary Date          | in Relativity is the Modified Date value from XWF
        // NATIVE Filepath       | is the relative file path of the exported original file
        slOutput.Add('Control Number'+#09+
                     'Primary Document Name'+#09+
                     'Path'+#09+
                     'Extracted Text'+#09+
                     'NATIVE Filepath'+#09+
                     'Hash'+#09+
                     'Primary Date');
      finally
        // slOutput is freed and closed later
      end;

      // To process compound Office documents, they are exported and then unzipped
      // This will take place in C:\temp\compound. So we check that on launch of
      // the X-Tension for use later.
      // If the folder exists from previous runs, delete it and then re-create it.
      // Or, create it if it does not exist to start with
      try
        if  VerReleaseIsLessThan2000 = true then
        begin
          if DirectoryExists('C:\temp\compound') = true then
          begin
            DeleteDirectory('C:\temp\compound', true);
            if ForceDirectories('C:\temp\compound') then
            begin
              TextificationOutputPath := 'C:\temp\compound\';
            end;
          end
          else
          begin
            ForceDirectories('C:\temp\compound');
            TextificationOutputPath := 'C:\temp\compound\';
          end;
        end; // VersionRelease is 20.0 or higher, so no need for these folder
      finally
        // Nothing to finalise
      end;

      // Assign export locations for TEXT, IMAGES and a folder for NATIVE files
      // as defined in the OutputLocation.txt file
      OutputFolder          := GetOutputLocation;
      if DirectoryExists(OutputFolder) = false then ForceDirectories(OutputFolder);
      OutputFoldersCreatedOK:= CreateFolderStructure(OutputFolder);
      if OutputFoldersCreatedOK then
      begin
        OutputSubFolderNative := IncludeTrailingPathDelimiter(OutputFolder) + 'NATIVE';
        OutputSubFolderText   := IncludeTrailingPathDelimiter(OutputFolder) + 'TEXT';
      end;
    end;
end;


// Returns a buffer of textified data from an Input buffer
function RunTextification(Buf : TBytes) : TBytes;
var
  // 2 billion bytes is 2Gb, so unless user processes a docx > 2Gb, integer should be OK
  i, j : integer;
  OutputBytesBuffer : TBytes;
  begin
    j := 0;
    SetLength(OutputBytesBuffer, Length(Buf));
    // itterate the buffer looking for ASCII printables
    for i := 0 to Length(Buf) - 1 do
    begin
      if Buf[i] in [32..127] then
        begin
          OutputBytesBuffer[j] := Buf[i];
          inc(j, 1);
        end
      else
      if Buf[i] = 13 then
        begin
          OutputBytesBuffer[j] := Buf[i];
          inc(j, 1);
        end
      else
      if Buf[i] = 10 then
        begin
          OutputBytesBuffer[j] := Buf[i];
          inc(j, 1);
        end;
      end; // buffer itteration ends
    result := OutputBytesBuffer;
  end;

// XT_ProcessItem : Examines each item in the selected evidence object. The "type category" of the item
// is then added to a string list for traversal later. Must return 0! -1 if fails.
function XT_ProcessItem(nItemID : LongWord; lpReserved : Pointer) : integer; stdcall; export;
const
  BufLen=2048;
var
  // WideChar arrays. More preferable on Windows UTF16 systems and better for Unicode chars
  lpTypeDescr, lpTypeDescrOffice, Buf, OutputFolder,
    UniqueID, errormessage, TruncatedFilename, strHashValue,
    OutputLocationForNATIVE, OutputLocationForTEXT, JoinedFilePath,
    JoinedFilePathAndName, OutputFileText,  strModifiedDateTime,
    OfficeFileName, OutputLocationOfFile : array[0..Buflen-1] of WideChar;

  // 32-bit integers
   itemtypeinfoflag, itemtypeinfoflagOfficeFile, intBytesRead, parentCounter, intLengthOfOutputFolder,
     intLengthOfFilename, WriteSuccess, intTotalOutputLength,
     intBreachValue                          : integer;

  // 64-bit integers
  ItemSize, intModifiedDateTime   : Int64;

  // Plain Byte arrays, TBytes
  InputBytesBuffer, TextifiedBuffer          : TBytes; // using TBytes because it allows use of SetLength so we can enlarge or reduce depending on file size (i.e.ItemSize)

  // Handles
  hItem                                      : THandle;

  // Booleans
  IsItAPicture, IsItAnOfficeFile, FilenameLegal, TruncatedFileFlag : boolean;

  // TFilestreams
  OutputStreamNative, OutputStreamText, temp_strm : TFileStream;

  // UTF8 BOM arrays
  UTF8BOM                                    : array[0..2] of byte = ($EF, $BB, $BF);

  // PWideChar Pointer arrays are used a lot due to X-Ways and Windows using UTF16.
  // XWF_GetFileName returns a pointer to a null terminated widechar. It decides what array to return
  // However, using UnicodeStrings is more generally advised in FPC as memory handling is taken
  // care of automatically by the compiler, thus avoiding the need for New() and Dispose()
  NativeFileName, ParentFileName, CorrectedFilename, FileExtension : unicodestring;

begin
  ItemSize               := -1;
  intBytesRead           := 0;
  intTotalOutputLength   := 0;
  intBreachValue         := 0;
  intModifiedDateTime    := 0;

  // Make sure buffers are empty and filled with zeroes
  // This explains why its done this way : https://forum.lazarus.freepascal.org/index.php?topic=13296.0
  FillByte(lpTypeDescr[0],       Length(lpTypeDescr)*sizeof(lpTypeDescr[0]), 0);
  FillByte(lpTypeDescrOffice[0], Length(lpTypeDescrOffice)*sizeof(lpTypeDescrOffice[0]), 0);
  //FillByte(bufHashVal[0], Length(bufHashVal)*sizeof(bufHashVal[0]), 0);
  JoinedFilePath          := '';
  JoinedFilePathAndName   := '';
  OutputLocationForNATIVE := '';
  OutputLocationForTEXT   := '';
  strHashValue            := '';
  strModifiedDateTime     := '';
  TruncatedFilename       := '';
  IsItAPicture            := false;
  TruncatedFileFlag       := false;
  IsItAnOfficeFile        := false;

  // Get the size of the item
  ItemSize := XWF_GetItemSize(nItemID);

  if ItemSize > 0 then
  begin
    // Keep track of how much data we process
    inc(TotalDataInBytes, ItemSize);

    // Make InputBytesBuffer big enough to hold file content
    SetLength(InputBytesBuffer, ItemSize);

    // Make the output text buffer big enough to hold the max file content (though it will always be less)
    SetLength(TextifiedBuffer, ItemSize);

    // For every item, check the type status. We also collect the category (0x4000000)
    // though we do not use it in this X-Tension, yet, as we are exporting selected files
    // chosen by the user, regardless of their type. However, we are only then exporting if
    // they have a valid status. 3, 4, and 5 are potentially legible files. 0, 1 and 2 are not.

    itemtypeinfoflag := XWF_GetItemType(nItemID, @lpTypeDescr, Length(lpTypeDescr) or $40000000);

    { API docs state that the first byte in the buffer should be empty on failure to lookup category
      So if the buffer is empty, no text category could be retrieved. Otherwise, classify it. }
    if lpTypeDescr<> #0 then
    begin
      // 3 = Confirmed file
      // 4 = Not confirmed
      // 5 = Newly identified
      if (itemtypeinfoflag = 3) or (itemtypeinfoflag = 4) or (itemtypeinfoflag = 5) then
      begin
        // Get the nano second Windows FILETIME date of the modified date value for the item
        intModifiedDateTime := XWF_GetItemInformation(nItemID,  XWF_ITEM_INFO_MODIFICATIONTIME, nil);

        // Convert the date (if there is one) to human readable using bespoke function FileTimeToDateTime
        if intModifiedDateTime > 0 then
        begin
          strModifiedDateTime := FormatDateTime('DD/MM/YYYY HH:MM:SS', FileTimeToDateTime(intModifiedDateTime));
        end;

        // Open the file item. Returns 0 if item ID could not be opened.
        hItem := XWF_OpenItem(CurrentVolume, nItemID, $01);
        if hItem > 0 then
        begin
          // Get the file item name and path, if one exists
          NativeFileName := XWF_GetItemName(nItemID);
          if NativeFileName <> NULL then
            begin
              parentCounter  := XWF_GetItemParent(nItemID);
              HasAParent     := 0;
              repeat
                HasAParent := XWF_GetItemParent(parentCounter);
                if HasAParent > -1 then
                begin
                  parentCounter  := HasAParent;
                  ParentFileName := XWF_GetItemName(HasAParent);
                  JoinedFilePath := IncludeTrailingPathDelimiter(ParentFileName) + JoinedFilePath;
                end;
              until HasAParent = -1;
              JoinedFilePathAndName := JoinedFilePath + NativeFileName; // Not needed, yet. But might do in future.
            end;

          // Get the UniqueID for each item processed based on ItemID from XWF case.
          // Note this does not include the partition prefix. Example :
          // X-Ways reports a unique ID of 0-1468, which means "First partition, item 1468,
          // but the value returned here will be just "1468".
          UniqueID := IntToStr(nItemID);

          // Get the hash value, if one exists.
          strHashValue := GetHashValue(nItemID);

          // Check validity of filename and fix it, if it contains illegal chars
          FilenameLegal := false;
          FilenameLegal := IsValidFilename(NativeFileName);
          if FilenameLegal = false then
          begin
            CorrectedFilename := '';
            CorrectedFilename := SanitiseFilename(NativeFileName);
          end;

          // Calculate the path and filename lengths
          // First, get the length of the Unique ID and Filename
          intLengthOfFilename     := SysUtils.StrLen(UniqueID) + Length(NativeFilename);

          // Second, compute the length of the output folder length, including the "NATIVE" sub dir
          intLengthOfOutputFolder := intOutputLength + SysUtils.StrLen(OutputSubFolderNATIVE);

          // Third, add these first two values together to get a combined length
          intTotalOutputLength    := intLengthOfFilename + intLengthOfOutputFolder;

          // Now, if thats over 255, work out how much over 255 the combined length is
          // and truncate it by that amount, called the BreachValue
          if intTotalOutputLength > 255 then
          begin
            intBreachValue := intTotalOutputLength - 255;
            // Get the file extension before we lose it all together during truncation
            FileExtension := ExtractFileExt(NativeFileName);
            // Now copy what should be a valid lengthed and truncated filename, with extension
            StrPLCopy(TruncatedFilename, NativeFileName, 255-intBreachValue);
            TruncatedFilename := TruncatedFilename + FileExtension;
            TruncatedFileFlag := true;
          end;

          // Export the original (aka native) file to the output folder, and that might be a shorter version than original

          try
            OutputStreamNative := nil;
            if (FilenameLegal = true) and (TruncatedFileFlag = false) then
            begin
              try
              OutputStreamNative := TFileStreamUTF8.Create(IncludeTrailingPathDelimiter(OutputSubFolderNATIVE) + UniqueID+'-'+ UTF16toUTF8(NativeFileName), fmCreate);
              OutputLocationOfFile := IncludeTrailingPathDelimiter(OutputSubFolderNATIVE) + UniqueID+'-'+ UTF16toUTF8(NativeFileName);
              except
                on E: EFOpenError do
                begin
                  errormessage := 'Could not write native filestream. Maybe permissions or disk storage issue? ' + E.Message;
                  lstrcpyw(Buf, errorMessage);
                  XWF_OutputMessage(@Buf[0], 0);
                end;
              end;
              OutputLocationForNATIVE := '.\NATIVE\' + UniqueID+'-'+NativeFileName;
            end
            else
            if FileNameLegal = false then
            begin
              try
              OutputStreamNative := TFileStreamUTF8.Create(IncludeTrailingPathDelimiter(OutputSubFolderNATIVE) + UniqueID+'-'+UTF16toUTF8(CorrectedFilename), fmCreate);
              OutputLocationOfFile := IncludeTrailingPathDelimiter(OutputSubFolderNATIVE) + UniqueID+'-'+UTF16toUTF8(CorrectedFilename);
              except
                on E: EFOpenError do
                  begin
                    errormessage := 'ERROR : Could not write native filestream as sanitised stream. Maybe a filename issue remaining? ' + E.Message;
                    lstrcpyw(Buf, errorMessage);
                    XWF_OutputMessage(@Buf[0], 0);
                  end;
              end;
              OutputLocationForNATIVE := '.\NATIVE\' + UniqueID+'-'+CorrectedFilename;
            end
            else
            if TruncatedFileFlag = true then
            begin
              try
              OutputStreamNative := TFileStreamUTF8.Create(IncludeTrailingPathDelimiter(OutputSubFolderNATIVE) + UniqueID+'-'+UTF16toUTF8(TruncatedFileName), fmCreate);
              OutputLocationOfFile := IncludeTrailingPathDelimiter(OutputSubFolderNATIVE) + UniqueID+'-'+UTF16toUTF8(TruncatedFileName);
              except
                on E: EFOpenError do
                begin
                  errormessage := 'ERROR : Could not create truncated filestream. Maybe filename has not been suitbly shortened? Check length? ' + E.Message;
                  lstrcpyw(Buf, errorMessage);
                  XWF_OutputMessage(@Buf[0], 0);
                end;
              end;
              OutputLocationForNATIVE := '.\NATIVE\' + UniqueID+'-'+UTF16toUTF8(TruncatedFilename);
            end;

            // Read the native file item to buffer
            intBytesRead := XWF_Read(hItem, 0, @InputBytesBuffer[0], ItemSize);
            // Write the native file out to disk using the above declared stream
            WriteSuccess := -1;
            WriteSuccess := OutputStreamNative.Write(InputBytesBuffer[0], ItemSize);
            if WriteSuccess = -1 then
              begin
                errormessage := 'ERROR : ' + UniqueID+'-'+NativeFileName + ' could not be written to disk. FileStream write error.';
                lstrcpyw(Buf, errormessage);
                XWF_OutputMessage(@Buf[0], 0);
              end;
          finally
            OutputStreamNative.free;
          end;

          // Check if it's a picture, because if it is, we dont textify it
          // This iw hy v18.9 or higher is required, because prior to that version
          // the type CATEGORY (e.g. Pictures) was not available.
          if (lpTypeDescr = 'Pictures') then
          begin
           IsItAPicture := true
          end
          else IsItAPicture := false;

          // ======== VERSIONS OF XWF < v20.0 ============================================
          // Due to XWF_OpenItem in versions less than v20.0 not having a text based handle option
          // we do not have the ability to get the users view of Office and other compressed
          // file types. So, we have to manually export, decompress, and then read them,
          // including the XML schemas. So this section handles that specifically as best we can.
          if VerReleaseIsLessThan2000 = true then
          begin
          // Now do a different type lookup, using file extension instead of category
          // to see if it is a docx or odt type file
          // If it is such a file, unzip it to get the document.xml extracted to
          // temporary location. Then read that, instead of the compressed DOCX native file

            itemtypeinfoflagOfficeFile := XWF_GetItemType(nItemID, @lpTypeDescrOffice, Length(lpTypeDescrOffice) or $20000000);
            // If an Office type descriptor was retrieved, unzip it and read it
            if lpTypeDescrOffice <> #0 then
            begin
              if (lpTypeDescrOffice = 'MS Word 2007') or (lpTypeDescrOffice = 'OpenOffice Writer') then
              begin
               IsItAnOfficeFile := true
              end
              else IsItAnOfficeFile := false;

              if IsItAnOfficeFile then
              begin
                // Unzip the compound file and get the path to "\word\document.xml" (Word) or "content.xml" (Libreoffice)
                OfficeFileName := ExtractFileFromZip(OutputLocationOfFile);
                // Read the appropriate.xml from the docx or odt file and store its content in InputBytesBuffer
                // This obviously replaces anything already in the buffer from the initial read
                // TODO : Work out how to do the read only once rather than twice when a compound file
                temp_strm := TFileStream.Create(OfficeFileName, fmOpenRead or fmShareDenyWrite);
                try
                  SetLength(InputBytesBuffer, temp_strm.Size);
                  temp_strm.Read(InputBytesBuffer[1], temp_strm.Size);
                finally
                  temp_strm.Free;
                end;
              end;
            end; // End of if lpTypeDescrOffice <> #0 then

            // Now carry on as normal, doing the textification work

            // If item is not a picture file, and if item is a DOCx file, textify it.
            if (IsItAPicture = false) or (IsItAnOfficeFile = true) then
            begin
              // if its not a picture file and it is a compound file...textify it and then export it as text

              TextifiedBuffer := RunTextification(InputBytesBuffer);

              if (FilenameLegal = true) and (TruncatedFileFlag = false) then
              begin
                OutputFileText := UniqueID+'-'+UTF16toUTF8(NativeFileName) + '.txt';
              end
              else
              if FilenameLegal = false then
              begin
                OutputFileText := UniqueID+'-'+UTF16toUTF8(CorrectedFilename) + '.txt';
              end
              else
              if TruncatedFileFlag = true then
              begin
                OutputFileText := UniqueID+'-'+UTF16toUTF8(TruncatedFilename) + '.txt';
              end;

              try
                OutputStreamText := nil;
                try
                  OutputStreamText := TFileStreamUTF8.Create(IncludeTrailingPathDelimiter(OutputSubFolderText) + OutputFileText, fmCreate);
                except
                  on E: EFOpenError do
                    begin
                      errormessage := 'ERROR : Could not create textified filestream of native fie ' + OutputFileText + ', ' + E.Message;
                      lstrcpyw(Buf, errorMessage);
                      XWF_OutputMessage(@Buf[0], 0);
                    end;
                end;
                OutputStreamText.Write(UTF8BOM[0],3);
                WriteSuccess := -1;
                WriteSuccess := OutputStreamText.Write(TextifiedBuffer[0], Length(TextifiedBuffer));
                if WriteSuccess = -1 then
                begin
                  errormessage := 'ERROR : ' + UniqueID+'-'+NativeFileName + '.txt' + ' could not be written to disk. TextStream write error.';
                  lstrcpyw(Buf, errormessage);
                  XWF_OutputMessage(@Buf[0], 0);
                end;
              finally
                OutputStreamText.Free;
                // Define the outputs of the files for the load file itself
                OutputLocationForTEXT := '.\TEXT\' + OutputFileText;
              end;
            end; // text file check and export ends
          // Close the original file handle
          XWF_Close(hItem);
          end // End of pre XWF v20.0 behaviour
          else
          // ======== VERSIONS OF XWF => v20.0 ===========================================
          // Due to the new text based handle of XWF_OpenItem in v20.0, we get a handle to
          // the users view of Office and other compressed file types. As all the filename
          // business has been handled above already, all we have to do is release the
          // existing handle, get a new text based one, read the content and write it out
          // And as before, if it is a Picture file, don't try and textifiy. Its already
          // been written out to disk.
          if (VerRelease2000OrAbove = true) and (IsItAPicture = false) then
          begin
            // Get new text based handle to itemID, if one can be obtained, i.e. not encrypted etc
            hItem := XWF_OpenItem(CurrentVolume, nItemID, $400);
            if hItem > 0 then
            begin
              // Get size of the text file associated with the handle, not size of original (nItemID) file
              // Note use of XWF_GetSize, and not XWF_GetItemSize
              // This will give us the size of the text value of the file, not the size of the original file

              ItemSize := -1;
              ItemSize := XWF_GetSize(hItem, nil);

              // Read the native file item as text to buffer
              if ItemSize > -1 then
              begin
                intBytesRead := XWF_Read(hItem, 0, @InputBytesBuffer[0], ItemSize);

                // Format the filenames of the text formatted output files to ensure filesystem suitability
                if (FilenameLegal = true) and (TruncatedFileFlag = false) then
                begin
                  OutputFileText := UniqueID+'-'+UTF16toUTF8(NativeFileName) + '.txt';
                end
                else
                if FilenameLegal = false then
                begin
                  OutputFileText := UniqueID+'-'+UTF16toUTF8(CorrectedFilename) + '.txt';
                end
                else
                if TruncatedFileFlag = true then
                begin
                  OutputFileText := UniqueID+'-'+UTF16toUTF8(TruncatedFilename) + '.txt';
                end;

                // Write the text to files on disk, named accordingly
                try
                  OutputStreamText := nil;
                  try
                    OutputStreamText := TFileStreamUTF8.Create(IncludeTrailingPathDelimiter(OutputSubFolderText) + OutputFileText, fmCreate);
                  except
                    on E: EFOpenError do
                      begin
                        errormessage := 'ERROR : Could not create textified filestream of native fie ' + OutputFileText + ', ' + E.Message;
                        lstrcpyw(Buf, errorMessage);
                        XWF_OutputMessage(@Buf[0], 0);
                      end;
                  end;
                  OutputStreamText.Write(UTF8BOM[0],3);
                  WriteSuccess := -1;
                  WriteSuccess := OutputStreamText.Write(InputBytesBuffer[0], ItemSize);
                  if WriteSuccess = -1 then
                  begin
                    errormessage := 'ERROR : ' + UniqueID+'-'+NativeFileName + '.txt' + ' could not be written to disk. TextStream write error.';
                    lstrcpyw(Buf, errormessage);
                    XWF_OutputMessage(@Buf[0], 0);
                  end;
                finally
                  OutputStreamText.Free;
                  // Define the outputs of the files for the load file itself
                  OutputLocationForTEXT := '.\TEXT\' + OutputFileText;
                end; // end of write text try statement
              end; // End of ItemSize valid
            end // End of valid handle check : if hItem > 0 etc. If the handle failed, warn the user
            else
            begin // Alert the user that a viewer component view of the file could not be painted
              errormessage := 'ERROR : ' + UniqueID+'-'+NativeFileName + '.txt' + ' could not be written because a text based viewer component read of it cannot be obtained. Encrypted? Corrupt?';
              lstrcpyw(Buf, errormessage);
              XWF_OutputMessage(@Buf[0], 0);
            end;
          end; // And of Version 20+ specific actions and end of 2nd XWF_OpenItem call

          // Finalise output to the Loadfile for this Item
          // Populate the loadfile, using Unicode TAB character value. Not comma, because sometimes e-mail attachments contain comma in the name
          slOutput.Add(UniqueID+#09+NativeFileName+#09+JoinedFilePath+#09+OutputLocationForTEXT+#09+OutputLocationForNATIVE+#09+strHashValue+#09+strModifiedDateTime);
        end; // end of first XWF_OpenItem
      end; // end of item type flags check
    end; // end of description check
  end; // end of itemsize check

  // The ALL IMPORTANT 0 return value!!
  result := 0;
end;

// Called after all items in the evidence objects have been itterated.
// Return -1 on failure. 0 on success.
function XT_Finalize(hVolume, hEvidence : THandle; nOpType : DWord; lpReserved : Pointer) : integer; stdcall; export;
const
  Buflen=1024;
var
  Buf, outputmessage, LoadFileOutputFolder : array[0..Buflen-1] of WideChar;
begin
  LoadFileOutputFolder := GetOutputLocation;
  // Write the CSV LoadFile to disk
  try
    slOutput.SaveToFile(LoadFileOutputFolder + 'LoadFile.tsv');
  finally
    // Free the memory used to store CSV LoadFile in RAM
    slOutput.Free;
  end;
  EndTime       := Now;
  TimeTaken     := FormatDateTime('HH:MM:SS',EndTime-StartTime);
  outputmessage := 'X-Tension execution ended at ' + FormatDateTime('DD/MM/YY HH:MM:SS',EndTime) + ', ' + FormatByteSize(TotalDataInBytes) + ' read. Time taken : ' + TimeTaken;
  RunFolderBuilderAgain := true;
  lstrcpyw(Buf, outputmessage);
  XWF_OutputMessage(@Buf[0], 0);
  result := 0;
end;

// called just before the DLL is unloaded to give XWF chance to dispose any allocated memory,
// Should return 0.
function XT_Done(lpReserved: Pointer) : integer; stdcall; export;
begin
  result := 0;
end;

exports
  XT_Init,
  XT_About,
  XT_Prepare,
  XT_ProcessItem,
  XT_Finalize,
  XT_Done,
  // I dont think the remainders need to be specifically exported so may be removed in future
  TimeStampIt,
  FormatByteSize,
  IsValidFilename,
  GetHashValue,
  FileTimeToDateTime,
  CreateFolderStructure,
  GetOutputLocation;
begin

end.



