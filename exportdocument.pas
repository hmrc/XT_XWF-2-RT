unit ExportDocument;

{$mode Delphi}{$H+}
{$codepage utf8}

interface

uses
  Classes, SysUtils, Generics.Collections, Generics.Defaults, StrUtils,
  LazUTF8Classes, DateUtils, Math;

type
  // define the function input/output we use as a callback for getting parents - currently this matches XWF_GetItemParent
  TCallback = function(id: longint): int32; stdcall;
  // a function provided to test an id to see if the document is a parent (to store information about it)
  TParentCheck = function(id: longint): boolean; stdcall;

  // definte the Export Document type
  // This holds the information needed for it to write it's own line in the loadfile
  // Extra functions that are helpers for adding parent information
  ExportDocument = class(TObject)
    DocumentId, ParentId: int32;
    ControlNumber, GroupId, OriginalId, Filename, FilePath, Hash,
    NativePath, TextPath: unicodestring;
    LastModifiedDate, ParentDate: TDateTime;
    procedure AddParent(parentId: int32; parentDate: TDateTime);
    procedure AddIds(cn, groupId: WideString);
    function WriteLine(sep: char; tempDir: string; dateFormat: string): WideString;
    constructor Create(id: int32;
      originalId, fname, fpath, hash, npath, tpath: WideString; lastModDate: TDateTime);
  end;

  // define the Export List type
  // This holds the list of the documents
  // The extra functions resolve the family relationships
  ExportList = class(TObject)
    EDComparer: IComparer<ExportDocument>;
    ParentChecker: TParentCheck;
    ParentLookup: TDictionary<longword, TDateTime>;
    Separator: char;
    HeaderLine: unicodestring;
    TempDir, DateFormat: string;
    Documents: TObjectList<ExportDocument>;
    procedure AddDocument(document: ExportDocument);
    procedure AddParents(getParentId: TCallback);
    procedure SortDocuments;
    procedure GenerateControlNumbers(prefix: WideString; startNumber: int32);
    procedure SaveToStream(stream: TFileStream; includeHeader: boolean);
    procedure SaveToFile(path: string);
    constructor Create(sep: char; tempDir, dateFormat: string;
      parentCheck: TParentCheck);
    destructor Free;
  end;

implementation

function TextSanitizer(orig: WideString): WideString;
var
  interim: WideString;
begin
  // replace all new lines with a \n
  interim := WideStringReplace(orig, #10, '\n', [rfReplaceAll]);
  // replace all carriage returns with a \r
  interim := WideStringReplace(interim, #13, '\r', [rfReplaceAll]);
  // replace all tabs with a space and return
  Result := WideStringReplace(interim, #9, ' ', [rfReplaceAll]);
end;

// ID is the XWF assigned ID - this is required to match for potential families later
// npath and tpath are the paths to the native and text files respectively - they should be fully qualified
// all other fields are just for printing out in the loadfile as they area
constructor ExportDocument.Create(id: int32;
  originalId, fname, fpath, hash, npath, tpath: WideString; lastModDate: TDateTime);
begin
  self.DocumentId := id;
  self.OriginalId := originalId;
  self.Filename := fname;
  self.FilePath := fpath;
  self.Hash := hash;
  self.NativePath := npath;
  self.TextPath := tpath;
  self.LastModifiedDate := lastModDate;
end;

// This sets the parent ID (for family grouping) and the parent date (for sorting by family)
procedure ExportDocument.AddParent(parentId: int32; parentDate: TDateTime);
begin
  self.ParentId := parentId;
  self.ParentDate := parentDate;
end;

// This sets both the control number (document ID) and Group Id in their final form - i.e. how they will be seen in Relativity
// when a control number is added we want to rename the file on disk so that it matches
procedure ExportDocument.AddIds(cn, groupId: WideString);
var
  renamedNative, renamedText: WideString;
begin
  self.ControlNumber := cn;
  self.GroupId := groupId;

  // rename files to use control number, if the files exist already
  if NativePath <> EmptyStr then
  begin
    renamedNative := ExtractFilePath(NativePath) + cn + ExtractFileExt(NativePath);
    RenameFile(NativePath, renamedNative);
    self.NativePath := renamedNative;
  end;
  if TextPath <> EmptyStr then
  begin
    renamedText := ExtractFilePath(TextPath) + cn + ExtractFileExt(TextPath);
    RenameFile(TextPath, renamedText);
    self.TextPath := renamedText;
  end;
end;

// TODO have selectable information to export
// write out the document data in a specific format
function ExportDocument.WriteLine(sep: char; tempDir: string;
  dateFormat: string): WideString;
var
  relativeNPath, relativeTPath: WideString;
begin
  // change the native and text paths to relative paths, so they can be copied with the loadfile and still be correct
  if NativePath <> EmptyStr then
  begin
    relativeNPath := WideStringReplace(NativePath, tempDir, '.', [rfReplaceAll]);
  end;
  if TextPath <> EmptyStr then
  begin
    relativeTPath := WideStringReplace(TextPath, tempDir, '.', [rfReplaceAll]);
  end;
  // This is the line that will appear in the loadfile
  // ANY CHANGES MADE HERE NEED TO BE CHANGED IN THE EXPORT LIST FUNCTIONS TOO
  Result := ControlNumber + sep + GroupId + sep + self.OriginalId +
    sep + TextSanitizer(Filename) + sep + TextSanitizer(FilePath) +
    sep + FormatDateTime(dateFormat, LastModifiedDate) + sep +
    FormatDateTime(dateFormat, ParentDate) + sep + Hash + sep +
    relativeNPath + sep + relativeTPath;
end;

// A comparer function for ExportDocument Objects - needed for accurate sorting by parent
// used for sorting the documents
// firstly look at the parent date of the documents, to keep family units together
// if same family date then check if A and B are parents
//    if both are parents then use the lower ID as some sort of deterministic sort to avoid bugs
//    if any one is a parent, then put that first in the list
//    finally sort by last modified date of the item
// This will ensure that any documents are ordered by family, and then by their own document date inside that family group
function DocumentComparer(constref A, B: ExportDocument): integer;
var
  AisParent, BisParent: boolean;
  interim: TValueRelationship;
begin
  if (A = nil) or (B = nil) then
  begin
    Exit();
  end;
  if A.DocumentId = B.DocumentId then
  begin
    Exit(0);
  end;
  // sort by parent date in first order, so documents are labelled by family order
  interim := CompareDateTime(A.ParentDate, B.ParentDate);
  if (interim <> 0) then
  begin
    Exit(interim);
  end
  else
  begin
    // if the parent Id is the same as the document ID it is the parent document, and should therefore go first
    AIsParent := A.ParentId = A.DocumentId;
    BIsParent := B.ParentId = B.DocumentId;
    interim := A.ParentId - B.ParentId;
    // A.ParentId - B.ParentId keeps the families together, but deterministically sorts based on Parent ID (i.e. it's family XWF Id)
    // if the number is 0 then same family
    if (interim <> 0) then
    begin
      Exit(interim);
    end
    // if it has made it this far it must be same family documents being compared
    // if A is the parent then make it first
    else if AisParent then
    begin
      Exit(-1);
    end
    // if B is parent make it first
    else if BIsParent then
    begin
      Exit(1);
    end
    // use last modified date as a decider when the sorting child documents inside a family
    else
    begin
      interim := CompareDateTime(A.LastModifiedDate, B.LastModifiedDate);
      if interim <> 0 then
      begin
        Exit(interim);
      end
      else
      begin
      end;
    end;
  end;
end;
// pointer version of the comparer, that is explicitly cast before calling the main function
function DocumentComparerPtr(constref A, B: Pointer): integer;
begin
  Result := DocumentComparer(ExportDocument(A), ExportDocument(B));
end;

// Explicit constructor to provide temp directory, date format to export with, and separator char to use
constructor ExportList.Create(sep: char; tempDir, dateFormat: string;
  parentCheck: TParentCheck);
begin
  EDComparer := TComparer<ExportDocument>.Construct(@DocumentComparerPtr);
  ParentChecker := parentCheck;
  Separator := sep;
  self.TempDir := tempDir;
  self.DateFormat := dateFormat;
  // initialise the Object list we use for the Export Documents
  Documents := TObjectList<ExportDocument>.Create(EDComparer, True);
  ParentLookup := TDictionary<longword, TDateTime>.Create;
  // If changing the columns in the loadfile change the headers here
  // TODO make this composable
  // The date is referred to as Primary Date - That's because it may not necessarily be a Last Modified Date
  // We use the Last Modified Dates, and then the Creation Date, and finally find a date from the metadata (last saved/last modified)
  self.HeaderLine := 'Control Number' + Separator + 'Group Id' +
    Separator + 'XWF Id' + Separator + 'Filename' + Separator + 'Path' +
    Separator + 'Primary Date' + Separator + 'Family Date' + Separator +
    'Hash' + Separator + 'Native Path' + Separator + 'Text Path';
end;

// Need to override Free here, as we need to Free our Object List
// No need to Free individual ExportDocuments, as the list takes care of that
destructor ExportList.Free();
begin
  self.Documents.Free;
  self.ParentLookup.Free;
end;

// procedure to add document so we can check if it's a parent and store data appropriately for that too
procedure ExportList.AddDocument(document: ExportDocument);
begin
  // if parent, then store information in our lookup for later
  if self.ParentChecker(document.DocumentId) then
  begin
    self.ParentLookup.Add(document.DocumentId, document.LastModifiedDate);
  end;
  // Add document to list
  self.Documents.Add(document);
end;

// Only to be run once all documents are added
// Cycle through all documents, checking all their relatives (as per the getParentId function) against entries in the parentLookup until one is found
// If a parent is found in the lookup, the parent Id and parent date from the lookup are added to the document
// If no parent is found, the parent Id and parent date are set as it's own
procedure ExportList.AddParents(getParentId: TCallback);
var
  current: ExportDocument;
  i, currentId, parentId, highestParentId: int32;
  notSelf: boolean = False;
begin
  // cycle through each document
  for i := 0 to Documents.Count - 1 do
  begin
    highestParentId := -1;
    current := Documents.Items[i];
    currentId := current.DocumentId;
    parentId := getParentId(currentId);
    // while there are still parents to the parents....
    while parentId >= 0 do
    begin
      // if we stored a parent with that id in the parentlookup, use these values and break
      if self.ParentLookup.ContainsKey(parentId) then
      begin
        // we want all family members to be attached to same top level parent, so keep looking to find the highest parent document being export
        highestParentId := parentId;
        {current.AddParent(parentId, (self.ParentLookup[parentId]));
        notSelf := True;
        Break;   }
      end;
      parentId := getParentId(parentId);
    end;
    // if we have found a parent (current version is stored in highestParentId) then use this to set parent values
    if highestParentId > 0 then
    begin
      current.AddParent(highestParentId, (self.ParentLookup[highestParentId]));
    end
    else
    begin
      current.AddParent(currentId, Documents.Items[i].LastModifiedDate);
    end;
  end;
end;

// Only to be run once all documents are added and parents have been added
// This uses the supplied comparer to sort the documents into family order
procedure ExportList.SortDocuments();
begin
  Documents.Sort(self.EDComparer);
end;

// Only to be run once all documents are added and parents have been added and the list has been sorted
// Given a prefix and a start number, this will go through the sorted list and assign control numbers to the documents
// This also assigns the group Id based on whether or not a document has the same parentId as its document ID - if not, use the previous groupId
// THIS ONLY WORKS IF THE DOCUMENTS ARE SORTED CORRECTLY
procedure ExportList.GenerateControlNumbers(prefix: WideString; startNumber: int32);
var
  i, currentParentId: int32;
  current: ExportDocument;
  currentGroupId, cn: WideString;
begin
  // cycle through all documents
  for i := 0 to Documents.Count - 1 do
  begin
    current := Documents.Items[i];
    // get newest control number
    // start number + index
    // e.g. start on 1 and index 0 then the number will be 1
    // e.g. start on 200 and index 21 then the number will be 221
    // TODO choose how much padding to use
    cn := prefix + '-' + AddChar('0', IntToStr(startNumber + i), 7);
    // check whether or not the document is freestanding/parent - if so set the current group Id
    if (current.DocumentId = current.ParentId) or (currentGroupId = EmptyStr) then
    begin
      currentGroupId := cn;
    end;
    // assign the new IDs to the documents - this will automatically rename the exported files to go with it
    current.AddIds(cn, currentGroupId);
  end;
end;

// Gien a stream, save all of the document entries to it
// This function does NOT close the stream
procedure ExportList.SaveToStream(stream: TFileStream; includeHeader: boolean);
var
  line: WideString;
  i: int32;
  UTF16BOM: array[0..1] of byte = ($FF, $FE);  // Little Endian
begin
  // only print BOM and header line if we need to includeHeader
  // We could be appending onto an old file and not need them
  if includeHeader then
  begin
    // write the header and add LineEnding (os specific)
    line := self.HeaderLine + LineEnding;
    // multiple length by sizeof widechar to get the actual byte length
    stream.Write(UTF16BOM[0], 2);
    stream.Write(line[1], Length(line) * SizeOf(widechar));
  end;
  // cycle through all documents and add a line per documennt
  for i := 0 to Documents.Count - 1 do
  begin
    // write the (escaped) line into the loadfile for the document and add LineEnding (os specific)
    line := Documents.Items[i].WriteLine(Separator, TempDir, DateFormat) + LineEnding;
    stream.Write(line[1], Length(line) * SizeOf(widechar));
  end;
end;

// code example from https://wiki.freepascal.org/File_Handling_In_Pascal
// write a new load file to disk at the given path
procedure ExportList.SaveToFile(path: string);
var
  i: int32;
  tfOut: TextFile;
  outStream: TFilestream;
begin
  // create file and get handle
  outstream := TFileStream.Create(path, fmCreate);
  try
    // pass to stream save function
    self.SaveToStream(outstream, True);
  finally
    // free stream
    outstream.Free;
  end;
end;

end.
