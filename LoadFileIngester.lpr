library LoadFileIngester;

{
  *** Requirements ***
  This X-Tension is designed for use only with X-Ways Forensics.
  This X-Tension is designed for use with v18.9 or later (due to file category lookup)
  and ideally v20.0+ for maximum capability
  This X-Tension is not designed for use on Linux or OSX platforms.
  The case must have either MD5, SHA-1 or SHA256 hash algorithms computed.

  ** Usage Disclaimer ***
  This X-Tension is a Proof-Of-Concept Alpha level prototype, and is not finished. It has known
  limitations. You are NOT advised to use it, yet, for any evidential work for criminal courts.

  *** Functionality Overview ***
  The X-Tension creates a Relativity Loadfile from the users selected files.
  The user must execute it by right clicking the required files and then "Run X-Tensions".

  By default, the generated output will be written to the path specified in the
  supplied file : OutputLocation.txt IF it is saved to the same folder as the DLL.
  If the path stated in that file does not exist it will be created. If
  OutputLocation.txt itself is missing, the default output location of c:\temp\relativityouput
  will be assumed, and created. The output folder does not have to exist before execution.

  Upon completion, the output can be ingested into Relativity.

  TODOs
    * Handle Adobe PDF files and more Office files (docx and odt added in April 2020)
   // Fix parent object lookup for items embedded in another object
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
  Types,
  Classes,
  XT_API,         // This is the XWF X-Tension API itself
  Windows,
  SysUtils,
  dateutils,
  strutils,
  contnrs,
  FileUtil,
  Character,     // So we can check string values are digits
  Zipper,        // To enable exploration of compound Office files
  Generics.Collections,
  ExportDocument;

const
  BufEvdNameLen = 4096;
  BufLen = 2048;

var
  // These are global vars, initialised using Default declarations where possible
  // for optimum memory management
  MainWnd: THandle;
  CurrentVolume: THandle;
  VerRelease: longint = Default(longint);
  ServiceRelease: byte = Default(byte);
  TotalDataInBytes: int64 = Default(int64);
  HashType: int64 = Default(int64);
  ObjectID: int64 = Default(int64);
  // This is the prefix value of Unique ID from the EVIDENCE Object (not hVolume), e.g. "3" in 3-15895"
  intOutputLength: integer = Default(integer);
  HasAParent: integer = Default(integer);
  TotalCounterNativeFiles: integer = Default(integer);
  TotalCounterTextFiles: integer = Default(integer);
  TotalCounterFailedTextFiles: integer = Default(integer);
  // Tallies failed text outputs of files otherwise considered suitable by XWF
  TotalCounterFailedNativeFiles: integer = Default(integer);
  // Tallies failed native file exports that were otherwise considered suitable by XWF
  SelectedItemsCounter: integer = Default(integer);
  RunFolderBuilder: boolean = True;
  VerReleaseIsLessThan2000: boolean = Default(boolean);
  VerRelease2000OrAbove: boolean = Default(boolean);
  TextificationOutputPath: string = Default(string);
  strTimeTakenLocal: string = Default(string);
  strTimeTakenGlobal: string = Default(string);
  strOutputLocation: WideString = Default(WideString);
  ErrorLog: TStringListUTF8;
  StartTime: TDateTime = Default(TDateTime);
  EndTime: TDateTime = Default(TDateTime);
  TimeTakenGlobal: TDateTime = Default(TDateTime);

  // List to hold all documents to be exported
  ExportDocumentList: ExportList;

  // string list for file modified dates lookup
  FileModifiedProperties: TStringArray;

  OutputSubFolderNative, OutputSubFolderText, OutputFolder: array[0..Buflen - 1] of
  widechar;

  // Evidence name is global for later use by name
  pBufEvdName: array[0..BufEvdNameLen - 1] of widechar;

  ControlNumberPrefixDigit_GlobalIncrementor: integer = Default(integer);
  ControlNumberPrefix_Global: WideString = Default(WideString);

  // XT_Init : The first call needed by the X-Tension API. Must return 1 for the X-Tension to continue.
  function XT_Init(nVersion, nFlags: DWord; hMainWnd: THandle;
    lpReserved: Pointer): longint; stdcall; export;
  begin
    // Get high 2 bytes from nVersion
    VerRelease := Hi(nVersion);
    // Get 3rd high byte for service release. We dont need it yet but we might one day
    ServiceRelease := HiByte(nVersion);

    // If the version of XWF is less than v18.9, abort, because we can't use it.
    if VerRelease < 1890 then
    begin
      MessageBox(MainWnd, 'Error: ' +
        ' Please execute this X-Tension using v18.9 or above ',
        'Relativity LoadFile Generator', MB_ICONINFORMATION);
      Result := -1;  // Should abort and not run any further
    end
    else  // If XWF version is less than v20.0 but greater than 18.9, continue but with an advisory.
    if (VerRelease > 1890) and (VerRelease < 2000) then
    begin
      VerReleaseIsLessThan2000 := True;
      MessageBox(MainWnd, 'Warning: ' +
        ' Limited support for compound files (e.g. DOCX) available. Advise use of XWF v20.00+ ',
        'Relativity LoadFile Generator', MB_ICONINFORMATION);
      Result := 1;  // Continue, with warning accepted
    end
    else
    begin
      // If XWF version is v20.0+, continue with no advisory needed.
      VerRelease2000OrAbove := True;
      Result := 1;  // Continue, with no need for warning
    end;

    // Check XWF is ready to go. 1 is normal mode, 2 is thread-safe. Using 1 for now
    if Assigned(XWF_OutputMessage) then
    begin
      TotalDataInBytes := 0;
      // Set Object ID to -1 ready to be set by GetEvdData
      ObjectID := -1;
      FillChar(pBufEvdName, SizeOf(pBufEvdName), $00);
      Result := 1; // lets go
      MainWnd := hMainWnd;
    end
    else
      Result := -1; // stop
  end;


  // FormatVersionRelease : Converts the "1980" style of version number to "19.8"
  // Returns version as string on success
  // We need to use a divsion to convert "1850" for example to a floating point.
  // Then we can define the location of the decimal and the digit length of the string
  // The outcome is "1850" becomes "v18.5"
  function FormatVersionRelease(nVersion: longint): WideString;
  const
    RequiredFormat: TFormatSettings = (DecimalSeparator: '.');
  begin
    Result := '';
    Result := FormatFloat('v##.#', nVersion / 100.0, RequiredFormat);
  end;
  // Used by the button in the X-Tension dialog to tell the user about the X-Tension
  // Must return 0
  function XT_About(hMainWnd: THandle; lpReserved: Pointer): longword; stdcall; export;
  begin
    Result := 0;
    MessageBox(MainWnd,
      ' Load File Generator for Relativity. An X-Tension for X-Ways Forensics. ' +
      ' To be executed only via by XWF v18.9 or higher (ideally XWF 20.0 upwards) and via right click of selected files. '
      + ' Developed by HMRC, Crown Copyright applies (c) 2019.' +
      ' Intended use : automates extraction of selected files, creating a Load File for Relativity.'
      , 'Load File Generator v1.0 Beta', MB_ICONINFORMATION);
  end;

  // Renders integers representing bytes into string format, e.g. 1MiB, 2GiB etc
  function FormatByteSize(const bytes: QWord): string; stdcall; export;
  var
    B: byte;
    KB: word;
    MB: QWord;
    GB: QWord;
    TB: QWord;
  begin
    if bytes > 0 then
    begin
      B := 1;         // byte
      KB := 1024 * B;  // kilobyte
      MB := 1024 * KB; // megabyte
      GB := 1024 * MB; // gigabyte
      TB := 1024 * GB; // terabyte

      if bytes > TB then
        Result := FormatFloat('#.## TiB', bytes / TB)
      else
      if bytes > GB then
        Result := FormatFloat('#.## GiB', bytes / GB)
      else
      if bytes > MB then
        Result := FormatFloat('#.## MiB', bytes / MB)
      else
      if bytes > KB then
        Result := FormatFloat('#.## KiB', bytes / KB)
      else
        Result := FormatFloat('#.## bytes', bytes);
    end
    else
      Result := '0 bytes';
  end;

  // GetHashValue : returns a string representation of a hash value, if one exists.
  // Returns empty string on failure.
  function GetHashValue(ItemID: longword): string; stdcall; export;
  var
    i: integer = Default(integer);
    HashValue: string = Default(string);
    HasAHashValue: boolean = Default(boolean);
    bufHashVal: array of byte;
  begin
    Result := Default(string);

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
    HasAHashValue := XWF_GetHashValue(ItemID, @bufHashVal[0]);

    // if a hash digest was returned, itterate it to a string
    if HasAHashValue then
      for i := 0 to Length(bufHashVal) - 1 do
      begin
        HashValue := HashValue + IntToHex(bufHashVal[i], 2);
      end;
    Result := HashValue;
  end;

  // FileTimeToDateTime : Converts the 100 Int64 nano-second based Windows filetime returned by
  // XWF_GetItemInformation(nItemID,  XWF_ITEM_INFO_MODIFICATIONTIME, nil);
  // to generic human readable string.
  function FileTimeToDateTime(const FileTime: int64): TDateTime; stdcall; export;
  const
    // Seconds to Unix Epoch from windows Filetime 01/01/1601
    FileTimeBase: int64 = -11644473600;
    // unix time is seconds so divide by this to get the filetime in seconds
    // convert filetime from 100nanoseconds resolution to seconds
    FileTimeStep : int64 = 10000000;
  var
    seconds: int64;
  begin
    // divide the Filetime by the step to get filetime in seconds
    seconds := FileTime div FileTimeStep;
    // takeaway seconds to unix epoch from windows filetime start and use built in function to convert
    Result := UnixToDateTime(seconds + FileTimeBase);
  end;
{
This is the original function to convert date times. This was consistently with my testing providing an answer that was ~4 minutes wrong

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
  end;}

  // GetOutputLocation : Gets the output location; i.e. where to put the LoadFile data
  // Returns empty string on failure
  function GetOutputLocation(): WideString; stdcall; export;
  const
    BufLen = 2048;
  var
  {UserFile  : Text;
  FileName  : Unicodestring = Default(UnicodeString);
  TFile     : Unicodestring = Default(UnicodeString);}
    Buf, outputmessage: array[0..Buflen - 1] of widechar;
    UsersSpecifiedPath: array[0..Buflen - 1] of widechar;

  begin
    Result := Default(WideString);
    intOutputLength := 0;
    outputmessage := '';
    FillChar(outputmessage, Length(outputmessage), $00);
    FillChar(UsersSpecifiedPath, Length(UsersSpecifiedPath), $00);
    FillChar(Buf, Length(Buf), $00);

    // Set default output location
    UsersSpecifiedPath := 'C:\temp\RelativityOutput';

    // Ask XWF to ask the user if s\he wants to override that default location
    XWF_GetUserInput('Specify output path', UsersSpecifiedPath,
      Length(UsersSpecifiedPath), $00000002);

    // Return the path location, whatever it may be
    Result := UTF8ToUTF16(UsersSpecifiedPath);
    strOutputLocation := Result;
    intOutputLength := Length(strOutputLocation);
    outputmessage := 'Output location set to : ' + strOutputLocation;
    lstrcpyw(Buf, outputmessage);
    XWF_OutputMessage(@Buf[0], 0);
  end;

  // CreateFolderStructure : CreateFolderStructure creates the output folders for the data to live in
  function CreateFolderStructure(RootOutputFolderName: array of widechar): boolean;
  stdcall; export;
  const
    BufLen = 2048;
  var
    Buf, outputmessage: array[0..Buflen - 1] of widechar;

  begin
    outputmessage := '';
    FillChar(outputmessage, Length(outputmessage), $00);
    FillChar(Buf, Length(Buf), $00);
    Result := Default(boolean);
    OutputSubFolderNative := IncludeTrailingPathDelimiter(RootOutputFolderName) +
      'NATIVE';
    OutputSubFolderText := IncludeTrailingPathDelimiter(RootOutputFolderName) + 'TEXT';

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

    RunFolderBuilder := False;
    // prevent execution of this function for remainder of file items
    Result := True;
  end;


  // Gets the case name, and currently selected evidence object, and the image size
  // and stores as a header for writing to HTML output later. Returns true on success. False otherwise.
  // Not currently used...
  function GetEvdData(hEvd: THandle): boolean; stdcall; export;
  const
    BufLen = 4096;
  var
    Buf: array[0..BufLen - 1] of widechar;
    pBufCaseName: array[0..Buflen - 1] of widechar;
    outputmessage: array[0..Buflen - 1] of widechar;
    CaseProperty, EvdSize, intEvdName: int64;

  begin
    Result := False;
    // Get the case name; we dont use it yet but I may want to later
    // XWF_CASEPROP_TITLE = 1, thus that value passed
    CaseProperty := -1;
    CaseProperty := XWF_GetCaseProp(nil, 1, @pBufCaseName[0], Length(pBufCaseName));

    // Get the item size of the evidence object. we dont use it yet but I may want to later
    // 16 = Evidence Total Size
    EvdSize := -1;
    EvdSize := XWF_GetEvObjProp(hEvd, 16, nil);

    // Get the evidence object name; we dont use it yet but I may want to later
    // 7 = object name
    intEvdName := -1;
    intEvdName := XWF_GetEvObjProp(hEvd, 7, @pBufEvdName[0]);

    // Get the Unique ID prefix value. We convert it to a WORD later as per the XWF_GetEvObjProp API docs.
    ObjectID := XWF_GetEvObjProp(hEvd, 3, nil);
    outputmessage := 'Case properties established : OK, now working on ' + pBufEvdName;
    lstrcpyw(Buf, outputmessage);
    XWF_OutputMessage(@Buf[0], 0);
    Result := True;
  end;

  // Gets the users desired base Control Number prefix name, e.g. SMITH001
  // Returns empty widestring on failure. UTF16 Widestring otherwise.
  function GetControlNumberPrefixName(): WideString; stdcall; export;
  const
    BufLen = 255;
  var
    ControlNumberPrefixName: array[0..Buflen - 1] of widechar;
  begin
    Result := '';
    // Get the Control Number prefix. Usually this is a seizure ref, as text, e.g. SMITH001.
    // Value is desriable, but not enforced (thus $00000002)
    ControlNumberPrefixName := '';
    XWF_GetUserInput('Specify exhibit ref. e.g. SMITH001', @ControlNumberPrefixName,
      Length(ControlNumberPrefixName), $00000002);
    Result := UTF8toUTF16(ControlNumberPrefixName);
    ControlNumberPrefix_Global := Result;
  end;

  // Gets the Control Number prefix starting digit that the user wishes to start from.
  // e.g. 1 or 79, to form "SMITH001-1-" or "SMITH001-79-".
  // Returns empty widestring on failure. UTF16 Widestring otherwise.
  function GetControlNumberPrefixDigit(): WideString; stdcall; export;
  const
    BufLen = 255;
  var
    lpBuff: array[0..Buflen - 1] of widechar;
    PrefixDigit: int64 = Default(int64);
  begin
    Result := '';
    //FillChar(ControlNumberPrefixDigit, Length(ControlNumberPrefixDigit), #0);
    //ControlNumberPrefixDigit := '';
    lpBuff[0] := #0; // NULL char is required by XWF_GetUserInput
    lpBuff[1] := #0; // NULL char is required by XWF_GetUserInput

    // Value must be entered as an integer digit so enforced ($00000001)
    // Only proceed if user enters a proper number
    PrefixDigit := XWF_GetUserInput(
      'Specify Control Number starting DIGIT (commonly "1")', @lpBuff, 0, $00000001);
    // Set the global counter to start from what the user has specified, e.g. '5'
    ControlNumberPrefixDigit_GlobalIncrementor := PrefixDigit;
    // return the digit as a widestring
    Result := UTF8toUTF16(IntToStr(PrefixDigit));
  end;

  // This holds the logic to check if a document is a parent or not, based on the value of $00000002
  function CheckIfParent(itemId: longint): boolean;
  stdcall; export;
  var
    itemInformation: int64;
  begin
    itemInformation := XWF_GetItemInformation(ItemID, XWF_ITEM_INFO_FLAGS, nil);
    Result := (itemInformation and $00000002) = $00000002;
  end;

  // XT_Prepare : used for every evidence object involved in execution
  function XT_Prepare(hVolume, hEvidence: THandle; nOpType: DWord;
    lpReserved: Pointer): integer; stdcall; export;
  const
    BufLen = 255;
  var
    outputmessage, Buf, tempdir: array[0..MAX_PATH] of widechar;
    OutputFoldersCreatedOK: boolean = Default(boolean);
    EvidDataGotOK: boolean = Default(boolean);
  begin
    FillChar(outputmessage, Length(outputmessage), $00);
    FillChar(Buf, Length(Buf), $00);
    Result := Default(integer);
    HashType := -1;
    //RunFolderBuilder := true;

    if nOpType <> 4 then
    begin
      MessageBox(MainWnd, 'Error: ' +
        ' Please execute this X-Tension by right clicking one ' +
        ' or more selected files only. Not via RVS or main menu. ' +
        ' Thank you.', 'Relativity LoadFile Generator v1.0 Beta',
        MB_ICONINFORMATION);

      // Tell XWF to abort if the user attempts another mode of execution, by returning -3
      Result := -3;
    end
    else
    begin
      // We need our X-Tension to return 0x01, 0x08, 0x10, and 0x20, depending on exactly what we want
      // We can change the result using or combinations as we need, as follows:
      // Call XT_ProcessItem for each item in the evidence object : (0x01)  : XT_PREPARE_CALLPI
      Result := XT_PREPARE_CALLPI;

      CurrentVolume := hVolume;            // Make sure the right column is set

      EvidDataGotOK := GetEvdData(hEvidence);

      HashType := XWF_GetVSProp(20, nil);
      // Work out what hash algorithm was used for the case. Correct as XWF v19.8
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
        // Create error log list in memory
        ErrorLog := TStringListUTF8.Create;
        ErrorLog.Add(
          'This file is tab seperated (TSV). Open in a spreadsheet tool for easy seperation of columns'
          + #09);
      finally
        // ErrorLog is freed in XT_Finalize
      end;


      // Assign export locations for TEXT, IMAGES and a folder for NATIVE files
      // as defined in the OutputLocation.txt file
      if RunFolderBuilder = True then
      begin
        OutputFolder := GetOutputLocation;
        if DirectoryExists(OutputFolder) = False then ForceDirectories(OutputFolder);
        OutputFoldersCreatedOK := CreateFolderStructure(OutputFolder);
        if OutputFoldersCreatedOK then
        begin
          OutputSubFolderNative := IncludeTrailingPathDelimiter(OutputFolder) + 'NATIVE';
          OutputSubFolderText := IncludeTrailingPathDelimiter(OutputFolder) + 'TEXT';
        end;
      end;

      // setup the document stores after the output folder so we know where the temp dir is
      // if the required date format changes it needs to be amended here
      ExportDocumentList := ExportList.Create(#09, OutputFolder,
        'DD/MM/YYYY HH:MM:SS', CheckIfParent);

      // because of variations add file modified property names lowercase now to save lower casing later
      // These are processed in order, so may need to change order at some point to get most accurate results
      FileModifiedProperties := TStringArray.Create('last saved', 'last modified');

      // Get user to set the relativity ID prefix e.g. 'SL' would be combined with the digit to make SL-0000001
      GetControlNumberPrefixName;
      // Set the pre-digit value - this is the first number that will be used when numbering documents
      // This is useful if there has already been an export of 3000 documents to Relativity, set the number here to 3001 to avoid clashes
      GetControlNumberPrefixDigit;


      // Start the timer now, as all user input and actions collected
      StartTime := Now;
      outputmessage := 'X-Tension execution started at ' +
        FormatDateTime('DD/MM/YY HH:MM:SS', StartTime) + ' using XWF ' +
        FormatVersionRelease(VerRelease) + '...please wait...';
      lstrcpyw(Buf, outputmessage);
      XWF_OutputMessage(@Buf[0], 0);
    end;
  end;

  // Parse the string from the metadata into a date
  function GetDateTimeFromString(str: WideString): TDateTime;
  var
    i: integer = Default(integer);
    spaceFound: boolean = Default(boolean);
    temp: TDateTime;
    d, date, time: WideString;
  begin
    try
      // some metadata had double spaces in between the date/time components so remove them
      // this is important as the built in free pascal datetime parser uses a space as a separator
      // so we use the space as a lookup to get the end of the date
      d := Trim(ReplaceStr(str, '  ', ' '));
      // Go through the string to find the correct point to separate at
      for i := 0 to Length(d) - 1 do
      begin
        // use spaces as a separator like the built in function
        // assume the first space is between the date and time
        // any secondary space is considered the end of the time and therefore the end of our string
        if d[i] = ' ' then
        begin
          // this is to check if it's the first space we find
          // continue for the first space, break for the second
          if not spaceFound then
          begin
            spaceFound := True;
          end
          else
          begin
            Break;
          end;
        end;
      end;
      // Using the position we work out above copy the text to a new string
      date := Trim(copy(d, 0, i));
      // use built in function to return the date
      Result := StrToDateTime(date);
    except
      on E: EConvertError do
         // if the conversion fails return default date so we can test against that
        Result := Default(TDateTime);
    end;
  end;

  // This should be used as a last resort
  // if X Ways date fields have a date, they take precedence
  function GetLastModifiedFromMetadata(meta: WideString): TDateTime;
  var
    i: integer = Default(integer);
    j: integer = Default(integer);
    p: integer = Default(integer);
    possibleDate: TDateTime;
    temp, dateSubstring: WideString;
    Data: TStringList;
  begin
    // metadata is split by #13#10, so get each line into a separate string and look at them individually
    Data := TStringList.Create;
    Data.StrictDelimiter := true;
    // can only split on char so pick the second of the two chars so we start at the beginning of the line
    Data.Delimiter := char(#10);
    Data.DelimitedText := meta;
    // cycle through each line of metadata
    for i := 0 to Data.Count - 1 do
    begin
      // lowercase the string, as our file properties are also lower case
      temp := LowerCase(Data.Strings[i]);
      // cycle through file modified properties list - names of the properties that contain file modified dates
      for j := 0 to Length(FileModifiedProperties) - 1 do
      begin
        // see if this file property exists in the current piece of metadata
        p := PosEx(FileModifiedProperties[j], temp);
        if p > 0 then
        begin
          // search for the first instance of a colon - after this should be the date
          p := PosEx(':', temp);
          // split string after position of : so it isn't included - adjust length to account for that
          dateSubstring := copy(temp, p + 1, Length(temp) - p - 1);
          // use our function to get datetime from string
          possibleDate := GetDateTimeFromString(dateSubstring);
          // if the conversion fails we return Default DateTime so check against this
          // if not the default, assume it's the right datetime and return it
          if possibleDate <> Default(TDateTime) then
          begin
            // free string list
               Data.Free;
            Exit(possibleDate);
          end;
        end;
      end;
    end;
    // free string list
    Data.Free;
    // return default datetime if we can't find a valid one
    Result := Default(TDateTime);
  end;

  // Returns a buffer of textified data from an Input buffer
  function RunTextification(Buf: TBytes): TBytes;
  var
    // 2 billion bytes is 2Gb, so unless user processes a docx > 2Gb, integer should be OK
    i: integer = Default(integer);
    j: integer = Default(integer);
    OutputBytesBuffer: TBytes = nil;
  begin
    SetLength(OutputBytesBuffer, Length(Buf));
    // itterate the buffer looking for ASCII printables
    for i := 0 to Length(Buf) - 1 do
    begin
      if Buf[i] in [32..127] then
      begin
        OutputBytesBuffer[j] := Buf[i];
        Inc(j, 1);
      end
      else
      if Buf[i] = 13 then
      begin
        OutputBytesBuffer[j] := Buf[i];
        Inc(j, 1);
      end
      else
      if Buf[i] = 10 then
      begin
        OutputBytesBuffer[j] := Buf[i];
        Inc(j, 1);
      end;
    end; // buffer itteration ends
    Result := OutputBytesBuffer;
  end;

  // XT_ProcessItem : Examines each item in the selected evidence object. The "type category" of the item
  // is then added to a string list for traversal later. Must return 0! -1 if fails.
  function XT_ProcessItemEx(nItemID: longword; hItemID: THandle;
    lpReserved: Pointer): integer; stdcall; export;
  const
    BufLen = 2048;
  var
    // WideChar arrays. More preferable on Windows UTF16 systems and better for Unicode chars
    lpTypeDescr, lpTypeDescrOffice, Buf, errormessage, strHashValue,
    OutputLocationForNATIVE, OutputLocationForTEXT, JoinedFilePath,
    UnzipLocation, OfficeFileName: array[0..Buflen - 1] of widechar;

    // 32-bit integers
    itemtypeinfoflag, itemtypeinfoflagOfficeFile, intBytesRead,
    parentCounter, WriteSuccess, iterator: integer;

    // PrimaryDate is used rather than LastModified as it may use the CreationDate instead
    // LastModified is preferred date, but CreationDate is acceptable
    // 64-bit integers
    ItemSize, intPrimaryDateTime, OfficeFileReadResult: int64;

    // DateTime
    PrimaryDateTime: TDateTime;

    // Plain Byte arrays, TBytes
    InputBytesBuffer, TextifiedBuffer: TBytes;
    // using TBytes because it allows use of SetLength so we can enlarge or reduce depending on file size (i.e.ItemSize)

    // Handles
    hItem: THandle;

    // Booleans
    IsItAPicture, IsItAnOfficeFile, GotItemDate: boolean;

    // TFilestreams
    OutputStreamNative, OutputStreamText, temp_strm: TFileStream;

    // UTF8 BOM arrays
    UTF8BOM: array[0..2] of byte = ($EF, $BB, $BF);

    // Array of DateFields to try and retrieve data from
    DateFields: array of long;

    // PWideChar Pointer arrays are used a lot due to X-Ways and Windows using UTF16.
    // XWF_GetFileName returns a pointer to a null terminated widechar. It decides what array to return
    // However, using UnicodeStrings is more generally advised in FPC as memory handling is taken
    // care of automatically by the compiler, thus avoiding the need for New() and Dispose()
    NativeFileName, ParentFileName, {CorrectedFilename,OutputLocationOfFile,}
    UniqueID, metadata: unicodestring;

  begin
    NativeFileName := Default(unicodestring);
    ParentFileName := Default(unicodestring);
    UniqueID := Default(unicodestring);

    ItemSize := -1;
    intBytesRead := Default(integer);
    intPrimaryDateTime := Default(int64);
    OfficeFileReadResult := -1;
    hItem := Default(THandle);
    // Make sure buffers are empty and filled with zeroes
    // This explains why its done this way : https://forum.lazarus.freepascal.org/index.php?topic=13296.0
    FillByte(lpTypeDescr[0], Length(lpTypeDescr) * sizeof(lpTypeDescr[0]), 0);
    FillByte(lpTypeDescrOffice[0], Length(lpTypeDescrOffice) * sizeof(
      lpTypeDescrOffice[0]), 0);
    FillByte(InputBytesBuffer[0], Length(InputBytesBuffer) * sizeof(
      InputBytesBuffer[0]), 0);
    FillByte(TextifiedBuffer[0], Length(TextifiedBuffer) *
      sizeof(TextifiedBuffer[0]), 0);

    JoinedFilePath := '';
    OutputLocationForNATIVE := '';
    OutputLocationForTEXT := '';
    strHashValue := '';
    IsItAPicture := Default(boolean);
    IsItAnOfficeFile := Default(boolean);
    GotItemDate := Default(boolean);

    // these field names are used to retrieve a working date
    // may need to remove creation time given the field on output is named modified date
    // different file types seem to contain the information in different places
    DateFields := [XWF_ITEM_INFO_MODIFICATIONTIME, XWF_ITEM_INFO_ENTRYMODIFICATIONTIME,
      XWF_ITEM_INFO_CREATIONTIME];

    Inc(SelectedItemsCounter, 1);

    // Get the size of the item
    ItemSize := XWF_GetItemSize(nItemID);

    if ItemSize > 0 then
    begin
      // Keep track of how much data we process
      Inc(TotalDataInBytes, ItemSize);

      // Make InputBytesBuffer big enough to hold file content
      SetLength(InputBytesBuffer, ItemSize);

      // For every item, check the type status. We also collect the category (0x4000000)
      // though we do not use it in this X-Tension, yet, as we are exporting selected files
      // chosen by the user, regardless of their type. However, we are only then exporting if
      // they have a valid type status, otherwise we may be exporting invalid type files.
      // 0=not verified, 1=too small, 2=totally unknown, 3=confirmed, 4=not confirmed, 5=newly identified, 6=mismatch detected. -1 means error.
      // 3, and 5 are potentially correctly identified types. 0, 1, 2, 4, 6 and -1 are not and so are skipped.

      itemtypeinfoflag := XWF_GetItemType(nItemID, @lpTypeDescr,
        Length(lpTypeDescr) or $40000000);

    { API docs state that the first byte in the buffer should be empty on failure to lookup category
      So if the buffer is empty, no text category could be retrieved. Otherwise, classify it. }
      if lpTypeDescr <> #0 then
      begin
        // 3 = Confirmed file type
        // 4 = Not confirmed file type but likely OK based on extension
        // 5 = Newly identified type status
        if (itemtypeinfoflag = 3) or (itemtypeinfoflag = 5) then
        begin
          // cycle through all the various item information field types in order
          // take the first value that has a value
          for iterator := 0 to Length(DateFields) - 1 do
          begin
            // Get the nano second Windows FILETIME date of the modified date value for the item
            intPrimaryDateTime :=
              XWF_GetItemInformation(nItemID, DateFields[iterator], @GotItemDate);
            if GotItemDate then
            begin
              Break;
            end;
          end;

          // if the date field is still the default (i.e. not set in the process above)
          // use the metadata to try and find a date
          // the fields for this are set in XT_Prepare
          if intPrimaryDateTime = Default(int64) then
          begin
             metadata := XWF_GetExtractedMetadata(nItemID);
             // this returns a TDateTime immediately
             PrimaryDateTime:= GetLastModifiedFromMetadata(metadata);
          end
          else
          begin
            // if the date field is set, convert from int to TDateTime
            PrimaryDateTime := FileTimeToDateTime(intPrimaryDateTime);
          end;

          // Open the file item. Returns 0 if item ID could not be opened.
          hItem := XWF_OpenItem(CurrentVolume, nItemID, $01);
          if hItem > 0 then
          begin
            // Get the file item name and path, if one exists
            NativeFileName := XWF_GetItemName(nItemID);
            if NativeFileName <> NULL then
            begin
              parentCounter := XWF_GetItemParent(nItemID);
              HasAParent := 0;
              repeat
                HasAParent := XWF_GetItemParent(parentCounter);
                if HasAParent > -1 then
                begin
                  parentCounter := HasAParent;
                  ParentFileName := XWF_GetItemName(HasAParent);
                  JoinedFilePath :=
                    IncludeTrailingPathDelimiter(ParentFileName) + JoinedFilePath;
                end;
              until HasAParent = -1;
            end;

            // Get the UniqueID for each item processed based on Evidence Object number
            // and the ItemID from the XWF case, e.g. 0-1468 where 0 = partition and 1468 = itemID.
            // Set the file ID as the Unique ID to write the file - should avoid collisions
            UniqueID := IntToStr(word(ObjectID)) + '-' + IntToStr(nItemID);

            // Get the hash value, if one exists.
            strHashValue := GetHashValue(nItemID);

            // Export the original (aka native) file to the output folder, and that might be a shorter version than original
            try
              OutputStreamNative := nil;
              try
                // save as XWD-ID.ext
                // THis helps avoid long names/illegal paths, and helps the end user match files to entries
                // e.g. <output folder>\NATIVE\12345.doc
                // will be reassigned to control number (relativity ID) when that is assigned
                OutputLocationForNATIVE :=
                  IncludeTrailingPathDelimiter(OutputSubFolderNATIVE) +
                  UniqueID + ExtractFileExt(UTF16toUTF8(NativeFileName));
                OutputStreamNative :=
                  TFileStreamUTF8.Create(OutputLocationForNATIVE, fmCreate);
              except
                on E: EFOpenError do
                begin
                  Inc(TotalCounterFailedNativeFiles, 1);
                  errormessage :=
                    'Could not write native filestream. Maybe permissions or disk storage issue? '
                    + E.Message;
                  lstrcpyw(Buf, errorMessage);
                  XWF_OutputMessage(@Buf[0], 0);
                end;
              end;


              // Only if an output stream was successfully created, try to read
              // the source and write it out to the stream
              if assigned(OutputStreamNative) then
              begin
                // Read the native file item to buffer
                intBytesRead := XWF_Read(hItem, 0, @InputBytesBuffer[0], ItemSize);
                // Write the native file out to disk using the above declared stream
                WriteSuccess := -1;
                WriteSuccess := OutputStreamNative.Write(InputBytesBuffer[0], ItemSize);
                if WriteSuccess = -1 then
                begin
                  Inc(TotalCounterFailedNativeFiles, 1);
                  errormessage :=
                    UniqueID + '-' + NativeFileName +
                    ' could not be written to disk. FileStream write error.';
                  lstrcpyw(Buf, errormessage);
                  XWF_OutputMessage(@Buf[0], 0);
                end
                else
                begin
                  Inc(TotalCounterNativeFiles, 1);
                end;
                OutputStreamNative.Free;
              end;
            finally
              // nothing to free
            end;

            // Check if it's a picture, because if it is, we dont textify it
            // This iw hy v18.9 or higher is required, because prior to that version
            // the type CATEGORY (e.g. Pictures) was not available.
            if (lpTypeDescr = 'Pictures') then
            begin
              IsItAPicture := True;
            end
            else
              IsItAPicture := False;

            // set the name of the output file first as we know it will be the same regardless of how we get the text
            OutputLocationForTEXT :=
              IncludeTrailingPathDelimiter(OutputSubFolderText) +
              UniqueID + '.txt';
             
            // NO LONGER SUPPORTING OLD VERSION, BUT LEAVING CHECK IN TO AVOID ERRORS AT RUNTIME
            // ======== VERSIONS OF XWF => v20.0 ===========================================
            // Due to the new text based handle of XWF_OpenItem in v20.0, we get a handle to
            // the users view of Office and other compressed file types. As all the filename
            // business has been handled above already, all we have to do is release the
            // existing handle, get a new text based one, read the content and write it out
            // And as before, if it is a Picture file, don't try and textifiy. Its already
            // been written out to disk.
            if (VerRelease2000OrAbove = True) and (IsItAPicture = False) then
            begin
              // Check the former handle has been freed
              if (hItem) > 0 then
              begin
                XWF_Close(hItem);
              end;
              // and now get new UTF16 text based handle to itemID, if one can be obtained,
              // i.e. it is not encrypted or devoid of text etc
              hItem := XWF_OpenItem(CurrentVolume, nItemID, $400);

              if hItem > 0 then
              begin
                // Get size of the text file associated with the handle, not size of original (nItemID) file
                // Note use of XWF_GetSize, and not XWF_GetItemSize
                // This will give us the size of the text value of the file, not the size of the original file
                // Note also XWF_GetSize is deprecated as of July 2020. Move to XWF_GetProp soon

                ItemSize := -1;
                ItemSize := XWF_GetSize(hItem, nil);
                // is deprecated. Move to XWF_GetProp soon
                // ItemSize :=  XWF_GetProp(hItem, 1, nil); // Placeholder for future adoption,

                // Make InputBytesBuffer big enough to hold the text based version
                // of the file content, which will be different to the previous call
                SetLength(InputBytesBuffer, ItemSize);

                // Read the native file item as text to buffer
                if ItemSize > -1 then
                begin
                  intBytesRead := XWF_Read(hItem, 0, @InputBytesBuffer[0], ItemSize);

                  // Write the text to files on disk, named accordingly
                  try
                    OutputStreamText := nil;
                    try
                      OutputStreamText :=
                        TFileStreamUTF8.Create(OutputLocationForTEXT, fmCreate);
                    except
                      on E: EFOpenError do
                      begin
                        errormessage :=
                          'Could not create textified filestream of native fie ' +
                          OutputLocationForNATIVE + ', ' + E.Message;
                        lstrcpyw(Buf, errorMessage);
                        XWF_OutputMessage(@Buf[0], 0);
                      end;
                    end;
                    OutputStreamText.Write(UTF8BOM[0], 3);
                    WriteSuccess := -1;
                    WriteSuccess :=
                      OutputStreamText.Write(InputBytesBuffer[0], ItemSize);
                    if WriteSuccess = -1 then
                    begin
                      Inc(TotalCounterFailedTextFiles, 1);
                      errormessage :=
                        UniqueID + '-' + NativeFileName + '.txt' +
                        ' could not be written to disk. TextStream write error.';
                      lstrcpyw(Buf, errormessage);
                      XWF_OutputMessage(@Buf[0], 0);
                    end
                    else
                    begin
                      Inc(TotalCounterTextFiles, 1);
                    end;
                  finally
                    OutputStreamText.Free;
                  end; // end of write text try statement
                end; // End of ItemSize valid

                // Close item again to ensure resources freed
                if (hItem) > 0 then
                begin
                  XWF_Close(hItem);
                end;
              end // End of valid handle check : if hItem > 0 etc. If the handle failed, warn the user
              else
              begin // Alert the user that a viewer component view of the file could not be painted
                errorlog.add(UniqueID + #9 + NativeFileName + '.txt' +
                  ' could not be written because a text based viewer component read cannot be obtained. No text? Encrypted? Corrupt?');
                errormessage :=
                  UniqueID + '-' + NativeFileName + '.txt' +
                  ' could not be written because a text based viewer component read of it cannot be obtained. No text? Encrypted? Corrupt?';
                lstrcpyw(Buf, errormessage);
                XWF_OutputMessage(@Buf[0], 0);
                errormessage := '....carrying on regardless....please wait';
                lstrcpyw(Buf, errormessage);
                XWF_OutputMessage(@Buf[0], 0);
              end;
            end; // End of 2nd XWF_OpenItem call, and of Version 20.0+ specific actions

            // if we couldn't write out a text file, we will still create an empty one
            // so that the file counts are complete/easy to validate for the user
            if (not FileExists(OutputLocationForTEXT)) then
            begin
              FileClose(FileCreate(OutputLocationForTEXT));
            end;

            // Add document to list to be processed in the finalize function
            ExportDocumentList.AddDocument(
              ExportDocument.ExportDocument.Create(nItemID, UniqueID,
              NativeFileName, JoinedFilePath, strHashValue,
              OutputLocationForNATIVE, OutputLocationForTEXT,
              PrimaryDateTime));
          end  // end of first XWF_OpenItem to native file
          else // Alert the user that the native file could not handled
          begin
            UniqueID := IntToStr(word(ObjectID)) + '-' + IntToStr(nItemID);
            errorlog.add(UniqueID + #09 +
              ' could not be accessed by XWF at all using this X-Tension. File handle initiatation failed.');
            errormessage := UniqueID +
              ' could not be accessed at all by XWF using this X-Tension. File handle initiatation failed';
            lstrcpyw(Buf, errormessage);
            XWF_OutputMessage(@Buf[0], 0);
            errormessage := '....carrying on regardless....please wait';
            lstrcpyw(Buf, errormessage);
            XWF_OutputMessage(@Buf[0], 0);
          end;
        end // end of item type flags check
        else // Item type was considered invalid so enter its ID to errorlog
        begin
          UniqueID := IntToStr(word(ObjectID)) + '-' + IntToStr(nItemID);
          // 0=not verified, 1=too small, 2=totally unknown, 3=confirmed, 4=not confirmed, 5=newly identified, 6=mismatch detected. -1 means error.
          if itemtypeinfoflag = 0 then
          begin
            errorlog.add(UniqueID + #09 + ' file type is not verified.');
          end
          else if itemtypeinfoflag = 1 then
          begin
            errorlog.add(UniqueID + #09 + ' file type is too small to be verified.');
          end
          else if itemtypeinfoflag = 2 then
          begin
            errorlog.add(UniqueID + #09 + ' file type is totally unknown to XWF.');
          end
          else if itemtypeinfoflag = 4 then
          begin
            errorlog.add(UniqueID + #09 +
              ' file type cannot be confirmed by XWF. Most likely invalid');
          end
          else if itemtypeinfoflag = 6 then
          begin
            errorlog.add(UniqueID + #09 + ' file type is mismatched.');
          end
          else if itemtypeinfoflag = -1 then
          begin
            errorlog.add(UniqueID + #09 + ' error looking up file type entirely.');
          end;
        end; // End of error log entry
      end // end of description check
      else
      begin
        UniqueID := IntToStr(word(ObjectID)) + '-' + IntToStr(nItemID);
        errorlog.add(UniqueID + #09 +
          ' type descriptor could not be identified at all. Skipped.');
      end;
    end // end of itemsize check
    else
    begin
      UniqueID := IntToStr(word(ObjectID)) + '-' + IntToStr(nItemID);
      errorlog.add(UniqueID + #09 + ' size was 0 bytes. Skipped.');
    end;

    // The ALL IMPORTANT 0 return value!!
    Result := 0;
  end;

  // Called after all items in the evidence objects have been itterated.
  // Return -1 on failure. 0 on success.
  function XT_Finalize(hVolume, hEvidence: THandle; nOpType: DWord;
    lpReserved: Pointer): integer; stdcall; export;
  const
    Buflen = 2048;
  var
    Buf, outputmessage: array[0..Buflen - 1] of widechar;
    LoadFileOutputFolder: WideString = Default(WideString);
    fsPrevLoadFile, fsPrevErrorLog: TFileStream;
  begin
    fsPrevLoadFile := Default(TFileStream);
    fsPrevErrorLog := Default(TFileStream);

    // This processes the stored data, finding family relationships based on IDs and a parent lookup
    ExportDocumentList.AddParents(XWF_GetItemParent);
    // Sort the documents so they are ordered by family
    ExportDocumentList.SortDocuments();
    // Go through the sorted documents and add incrementing control numbers, and group ID as well
    ExportDocumentList.GenerateControlNumbers(ControlNumberPrefix_Global,
      ControlNumberPrefixDigit_GlobalIncrementor);

    // Lookup where the output has been going
    LoadFileOutputFolder := strOutputLocation;
    // Write the CSV LoadFile to the same output location. Append if multiple evidence objects
    // have been selected for export.
    if FileExists(IncludeTrailingPathDelimiter(LoadFileOutputFolder) +
      'LoadFile.tsv') then
    begin
      try
        fsPrevLoadFile := TFileStream.Create(
          IncludeTrailingPathDelimiter(LoadFileOutputFolder) +
          'LoadFile.tsv', fmOpenWrite);
        fsPrevLoadFile.Position := fsPrevLoadFile.Size;
        // if the file exists we assume there is a header already, so pass False as a parameter to exclude headers
        ExportDocumentList.SaveToStream(fsPrevLoadFile, False);
      finally
        fsPrevLoadFile.Free;
        ExportDocumentList.Free;
      end;
    end
    else
      try
        ExportDocumentList.SaveToFile(IncludeTrailingPathDelimiter(
          LoadFileOutputFolder) + 'LoadFile.tsv');
      finally
        // Free the memory used to store CSV LoadFile in RAM
        ExportDocumentList.Free;
      end;

    // Write the error log to the same output location. Append if multiple evidence objects
    // have been selected for export.
    if FileExists(IncludeTrailingPathDelimiter(LoadFileOutputFolder) +
      'ErrorLog.txt') then
    begin
      try
        fsPrevErrorLog := TFileStream.Create(
          IncludeTrailingPathDelimiter(LoadFileOutputFolder) +
          'ErrorLog.txt', fmOpenWrite);
        fsPrevErrorLog.Position := fsPrevErrorLog.Size;
        errorlog.SaveToStream(fsPrevErrorLog);
      finally
        fsPrevErrorLog.Free;
        errorlog.Free;
      end;
    end
    else
      try // Save error log as a TSV file (was txt prior to v0.10 Alpha)
        errorlog.savetofile(IncludeTrailingPathDelimiter(LoadFileOutputFolder) +
          'ErrorLog.tsv');
      finally
        errorlog.Free;
      end;

    // Output finalising summary data
    EndTime := Now;
    strTimeTakenLocal := FormatDateTime('HH:MM:SS', EndTime - StartTime);
    // Time for THIS evidence object
    TimeTakenGlobal := TimeTakenGlobal + (EndTime - StartTime);
    // Time overall that the X-Tension has been running. Do not initialise to Default. Running total.
    strTimeTakenGlobal := FormatDateTime('HH:MM:SS', TimeTakenGlobal);
    // Do not initialise to Default. Running total.

    outputmessage := 'X-Tension execution ended at ' +
      FormatDateTime('DD/MM/YY HH:MM:SS', EndTime) + ', ' +
      strTimeTakenLocal + ' for this evidence object. Overall time so far: ' +
      strTimeTakenGlobal + ', ' + FormatByteSize(TotalDataInBytes) + ' read.';

    RunFolderBuilder := False;
    lstrcpyw(Buf, outputmessage);
    XWF_OutputMessage(@Buf[0], 0);
    Result := 0;
  end;

  // called just before the DLL is unloaded to give XWF chance to dispose any allocated memory,
  // Should return 0.
  function XT_Done(lpReserved: Pointer): integer; stdcall; export;
  const
    Buflen = 4096;
  var
    Buf, outputmessage: array[0..Buflen - 1] of widechar;
  begin
    // Tell the user we are totally done.
    outputmessage := 'FINISHED. ' + IntToStr(SelectedItemsCounter) +
      ' items considered (selected items and child items, if requested by user). ' +
      IntToStr(TotalCounterNativeFiles) + ' native files exported and ' +
      IntToStr(TotalCounterTextFiles) + ' text versions successfully exported.';

    // Only display stats about failed text files if some failed beyond the standard validation checks of XWF
    if TotalCounterFailedTextFiles > 0 then
    begin
      outputmessage := outputmessage + IntToStr(TotalCounterFailedTextFiles) +
        ' text versions could either not be generated or not written despite best efforts by XWF and ';
    end;

    // Only display stats about failed native files if some failed beyond the standard validation checks of XWF
    if TotalCounterFailedNativeFiles > 0 then
    begin
      outputmessage := outputmessage + IntToStr(TotalCounterFailedNativeFiles) +
        ' native files could not be read our written despite best efforts by XWF (i.e. they were considered valid but still failed to get out).';
    end;

    lstrcpyw(Buf, outputmessage);
    XWF_OutputMessage(@Buf[0], 0);
    Result := 0;
  end;

exports
  XT_Init,
  XT_About,
  XT_Prepare,
  XT_ProcessItemEx,
  XT_Finalize,
  XT_Done;
begin

end.
