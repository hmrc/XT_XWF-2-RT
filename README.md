
# XT_XWF-2-RT (X-Ways Forensics to Relativity Injestion X-Tension)

###  *** Requirements ***
  This X-Tension is designed for use only with X-Ways Forensics.
  This X-Tension is designed for use only with v18.9 or later (due to file category lookup).
  This X-Tension is not designed for use on Linux or OSX platforms.
  The case must have either MD5, SHA-1 or SHA256 hash algorithms computed.
  There is a compiled 32 and 64 bit version of the X-Tension to be used with the corresponding version of X-Wyas Forensics. 

###  ** Usage Disclaimer ***
  This X-Tension is a Proof-Of-Concept Alpha level prototype, and is not finished. It has known
  limitations. You are NOT advised to use it, yet, for any evidential work for criminal courts.

###  *** Functionality Overview ***
  The X-Tension creates a Relativity Loadfile from the users selected files.
  The user must execute it by right clicking the required files and then "Run X-Tensions".
  By default, the generated output will be written to the path specified in the
  supplied file : OutputLocation.txt. The folder does not have to exist before execution.
  This text file MUST be copied to the location of where
  X-Ways Forensics is running from. By default, the output location is
  c:\temp\RelativityOutput\
  Upon completion, the output can be injested into Relativity.

###  TODOs
   // TODO TedSmith : Add a decompression library for
    * MS Office and
    * LibreOffice files and
    * Adobe PDF files
   // TODO TedSmith : Fix parent object lookup for items embedded in another object
     where the actual file parent seems to be being skipped, even if the remaining path is not.
   // TODO Ted Smith : Write user manual

  *** License ***
  This code is open source software licensed under the [Apache 2.0 License]("http://www.apache.org/licenses/LICENSE-2.0.html")
  and The Open Government Licence (OGL) v3.0. 
  (http://www.nationalarchives.gov.uk/doc/open-government-licence and
  http://www.nationalarchives.gov.uk/doc/open-government-licence/version/3/).

###  *** Collaboration ***
  Collaboration is welcomed, particularly from Delphi or Freepascal developers.
  This version was created using the Lazarus IDE v2.0.4 and Freepascal v3.0.4.
  (www.lazarus-ide.org)