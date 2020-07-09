# XT_XWF-2-RT (X-Ways Forensics to Relativity Injestion X-Tension)

###  *** Requirements ***
  This X-Tension is designed for use only with X-Ways Forensics.
  This X-Tension is designed for use only with v18.9 or later (due to file category lookup), and ideally v20.0 Beta5b or above due to newer API syntax.
  This X-Tension is not designed for use on Linux or OSX platforms.
  The case must have either MD5, SHA-1 or SHA256 hash algorithms computed.
  There will be a compiled 32 and 64 bit version of the X-Tension to be used with the corresponding version of X-Ways Forensics when stable. 

###  ** Usage Disclaimer ***
  This X-Tension is a Proof-Of-Concept Alpha level prototype, and is not finished. It has known
  limitations. You are NOT advised to use it, yet, for any evidential work for criminal courts.

###  *** Functionality Overview ***
  The X-Tension creates a Relativity Loadfile from the users selected files.
  The user must execute it by right clicking the required files and then "Run X-Tensions".
  By default, the generated output will be written to C:\Temp\RelativityOutput but as of v0.8 Alpha, the user is asked and can override
  If the path stated does not exist it will be created. 
  Upon completion, the output can be injested into Relativity.

###  TODOs
     
   // TODO Ted Smith : Write user manual

  *** License ***
  This code is open source software licensed under the [Apache 2.0 License]("http://www.apache.org/licenses/LICENSE-2.0.html") and The Open Government Licence (OGL) v3.0. 
  (http://www.nationalarchives.gov.uk/doc/open-government-licence and
  http://www.nationalarchives.gov.uk/doc/open-government-licence/version/3/).

###  *** Collaboration ***
  Collaboration is welcomed, particularly from Delphi or Freepascal developers.
  This version was created using the Lazarus IDE v2.0.4 and Freepascal v3.0.4.
  (www.lazarus-ide.org)