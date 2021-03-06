#Region ;**** Directives created by AutoIt3Wrapper_GUI ****
#AutoIt3Wrapper_Change2CUI=y
#AutoIt3Wrapper_Res_Comment=CLI Parser for $UsnJrnl (NTFS)
#AutoIt3Wrapper_Res_Description=CLI Parser for $UsnJrnl (NTFS)
#AutoIt3Wrapper_Res_Fileversion=1.0.0.6
#AutoIt3Wrapper_Res_requestedExecutionLevel=asInvoker
#EndRegion ;**** Directives created by AutoIt3Wrapper_GUI ****
;
; This script is a reworking/combination of the UsnJrnl2Csv and MftRef2Name
; tools created by Joakim Schicht (https://github.com/jschicht).
;
; The basic idea is to, after enabling the USN Journal (https://en.wikipedia.org/wiki/USN_Journal)
; on an NTFS volume, use this tool to extract a list of files that the journal
; records as having been changed.  You then pass this list of changed files to
; your backup program (e.g. rsync --include-from=) so that it only backs up
; these files.
;
; Yes, rsync only copies files that have been changed by default,
; the problem arises however that if you have millions of files with only a
; limited subset of them changing, rsync will still spend a lot of time checking
; meta-data and checksums to work out what has changed.  Using this tool allows
; rsync to skip this check.
;
; So you don't repeat the mistake I made, because this is a console script, you
; can't simply double click the .au3 file or run "AutoIt3.exe FileName.au3" to
; use it.  You won't get any output.  You need to either compile the script into
; an executable using Aut2exe.exe with the "/console" switch or run this script
; from within the AutoIt3 provided SciTE-Lite editor.

; To create a stand alone executable:
;"C:\Program Files (x86)\AutoIt3\Aut2Exe\Aut2exe_x64.exe" /in BackupQueueFromUSNJournal.au3 /console /fileversion 1.0.0.6 /productversion 1.0.0.6 /productname BackupQueueFromUSNJournal /icon BackupQueueFromUSNJournal.ico
;
; Finally, my excuse for code in this script being ugly and inefficient is that
; this is the first time I have ever worked with AutoIt code and there are large
; portions of Joakim's code that I don't fully understand.  Sorry.
;
#Include <WinAPIEx.au3>
#include <GUIConstantsEx.au3>
#include <WindowsConstants.au3>
#include <StaticConstants.au3>
#include <StringConstants.au3>
#include <EditConstants.au3>
#include <GuiEdit.au3>
#Include <FileConstants.au3>
#Include <Array.au3>
#Include <Date.au3>
#Include "UsnJrnl2Csv_Functions.au3"
#Include "MftRef2Name_Functions.au3"

Global $MyName = "BackupQueueFromUSNJournal"
Global $MyVersion = "1.0.0.6"
Global $DateTimeFormat = 6
Global $TimestampPrecision = 3
Global $PrecisionSeparator = "."
Global $de = "|"
Global $Record_Size = 4096
Global $VerboseOn = 0
Global $VerboseToFileOn = 0
Global $ParserOutDir = @ScriptDir
Global $CPUThrottle = 10
Global $File, $WithQuotes, $MaxRecords, $nBytes, $UsnJrnlCsv, $UsnJrnlCsvFile
Global $TargetDrive, $ExtractUsnJrnlPath, $ExtractUsnJrnlPid
Global $ExtractUsnJrnlResult
Global $MFTReferences[2]
Global $MftRefNames[2]
Global $MftRefFullNames[2]
Global $MftRefParents[2]
Global $MaxUSNEntriesToProcess = 0
Global $FSUtilMaxUSN = 0
Global $MaxUSN = 0
Global $MinUSN = 0
Global $LastUsnJrnlTimestamp = ""
Global $FirstUSN = 0
Global $OutputToFile = ""
Global $StatusToFile = ""
Global $LogToFile = ""
Global $TimeLimit = 31557600 ; Not actually implemented
Global $AppendToOutputFile = 2  ; 1 = Append, 2 = Overwrite
Global $AppendToLogFile = 1
Global $OutputFileEncoding = 0  ;32 = Unicode, 0 = UTF8
Global $PathSeparator = "\"
Global $RelativePaths = False
Global $RelativePathPrefix = ""
Global $IncludeParents = False
Global $IgnoreSysVolInfo = False
Global $IgnoreRecycleBin = False
Global $ServiceMode = False
; Global $ServiceCycleFrequency = 300000    ; Every 5 minutes
Global $ServiceCycleFrequency = 15000    ; Every 15 seconds
; Global $ServiceStartupDelay = 300000    ; 5 minutes
Global $ServiceStartupDelay = 5000        ; 5 seconds
Global $CachePurgeFrequency = 86400000    ; Daily
Global $ExcludeFilePatterns[1]
Global $LastPageMaxUSN = 0
Global $CurrentPage = 0
Global $ProcessPriority = -1

_ArrayAdd($ExcludeFilePatterns, "(?i)\.frx$")
_ArrayAdd($ExcludeFilePatterns, "(?i)\.tmp$")

; Load some default settings from the registry
_LoadConfigFromRegistry("")

; Command line argument processing
If ($cmdline[0] > 0) Then
  ; Which volume are we to work on.  The Volume specified on the command line
  ;  can be in either the for of "X:" or just "X".
  $TargetDrive = ""
  If (StringLen($cmdline[$cmdline[0]]) = 1) Then
    $TargetDrive = $cmdline[$cmdline[0]] & ":"
  ElseIf (StringLen($cmdline[$cmdline[0]]) = 2) And (StringRight($cmdline[$cmdline[0]], 1) = ":") Then
    $TargetDrive = $cmdline[$cmdline[0]]
  EndIf

  ; Load the default settings for this specific volume from the registry.  These
  ;  will override the default settings loaded earlier
  _LoadConfigFromRegistry($TargetDrive)

  ; Process the remaining command line arguments.  These will override settings
  ;  found in the registry
  For $i = 1 To $cmdline[0]
    If $cmdline[$i] == "-a" Then
      $AppendToOutputFile = 1
      $OutputToFile = $cmdline[$i + 1]
    ElseIf $cmdline[$i] == "-v" Then
      $VerboseOn = $VerboseOn + 1
      If ($VerboseOn = 1) Then
        _ConsoleWriteLine("Turning on verbose output")
      Else
        _ConsoleWriteLine("Increasing output verbosity")
      EndIf
    ElseIf $cmdline[$i] == "-V" Then
      _ConsoleWriteLine($MyName & " " & $MyVersion)
      Exit
    ElseIf $cmdline[$i] = "-l" Then
      If ($CPUThrottle = 10) Then
        $CPUThrottle = 50
      ElseIf ($CPUThrottle = 50) Then
        $CPUThrottle = 200
      Else
        $CPUThrottle = 500
      EndIf
    ElseIf $cmdline[$i] == "-L" Then
      $LogToFile = $cmdline[$i + 1]
    ElseIf $cmdline[$i] == "-m" Then
      If StringIsDigit($cmdline[$i + 1]) Then
        $MinUSN = $cmdline[$i + 1]
      Else
        _ConsoleWriteError("Error: The value specified for the -m switch must be a number.")
        Exit
      EndIf
    ElseIf $cmdline[$i] == "-M" Then
      If StringIsDigit($cmdline[$i + 1]) Then
        $MaxUSNEntriesToProcess = $cmdline[$i + 1]
      Else
        _ConsoleWriteError("Error: The value specified for the -M switch must be a number.")
        Exit
      EndIf
    ElseIf $cmdline[$i] == "+p" Then
      $IncludeParents = True
    ElseIf $cmdline[$i] == "-p" Then
      $IncludeParents = False
    ElseIf $cmdline[$i] == "-r" Then
      $RelativePaths = True
    ElseIf $cmdline[$i] == "-R" Then
      $RelativePaths = True
      $RelativePathPrefix = $cmdline[$i + 1]
    ElseIf $cmdline[$i] == "-o" Then
      $OutputToFile = $cmdline[$i + 1]
    ElseIf $cmdline[$i] == "-service" Then
        $ServiceMode = True
    ElseIf $cmdline[$i] == "-S" Then
      $IgnoreSysVolInfo = True
    ElseIf $cmdline[$i] == "+S" Then
      $IgnoreSysVolInfo = False
    ElseIf $cmdline[$i] == "-T" Then
      $IgnoreRecycleBin = True
    ElseIf $cmdline[$i] == "+T" Then
      $IgnoreRecycleBin = False
    ElseIf $cmdline[$i] == "-t" Then
      $TimeLimit = $cmdline[$i + 1]
      _ConsoleWriteError("Sorry.  The Time Limit feature isn't implemented yet.")
    ElseIf $cmdline[$i] == "+u" Then
      $PathSeparator = "/"
    ElseIf $cmdline[$i] == "-u" Then
      $PathSeparator = "\"
    ElseIf $cmdline[$i] = "/?" Or $cmdline[$i] = "/h" Or $cmdline[$i] = "-h" Or $cmdline[$i] = "-?" Then
      HelpMessage()
      Exit
    EndIf
  Next

  ; If we don't know which drive/volume to process we can't do anything
  If (StringLen($TargetDrive) < 1) Then
    _ConsoleWriteError("'" & $cmdline[$cmdline[0]] & "' is not a valid value for Volume.")
    HelpMessage()
    Exit
  EndIf
Else
  ;HelpMessage()
  ;Exit

  ;For debugging in GUI
  $CPUThrottle = 50
  $TargetDrive = "E:"
  $VerboseOn = 1
  $MinUSN = 1639344
  $MaxUSNEntriesToProcess = 1084014
  $ServiceMode = True
EndIf

; Input validation - Ensure target volume exists
If Not (FileExists($TargetDrive & "\")) Then
  _ConsoleWriteError("Error: The specified target volume '" & $TargetDrive & "' doesn't seem to exist.")
  Exit
EndIf

; Input validation - Ensure target volume is NTFS
_ReadBootSector($TargetDrive)
If @error Then
	_ConsoleWriteError("Error: Filesystem not NTFS")
	Exit
EndIf

; Set Process Priority of self
_ConsoleWriteVerbose(1, "", "My PID: " & @AutoItPID)
If ($ProcessPriority > -1) Then
  _ConsoleWriteVerbose(1, "", "Setting my process priority to: " & $ProcessPriority)
  ProcessSetPriority (@AutoItPID, $ProcessPriority)
EndIf

If ($ServiceMode) Then
  ; We need to load the $MinUSN from the last time we ran from the registry
  ;https://www.autoitscript.com/autoit3/docs/functions/RegRead.htm
  Local $PotentialMinUSN = RegRead("HKEY_LOCAL_MACHINE\SOFTWARE\USNJBackupQueue\Volumes\" & $TargetDrive, "MinUSN")
  If IsNumber($PotentialMinUSN) Then
    _ConsoleWriteVerbose(1, "", "Minimum Acceped USN loaded from local registry: " & $PotentialMinUSN)
    $MinUSN = $PotentialMinUSN
  Else
    _ConsoleWriteError("No MinUSN found in the registry.  " & $PotentialMinUSN)
  EndIf

  ; Sleep for $ServiceStartupDelay
  _ConsoleWriteVerbose(1, "", "Service startup delay: " & ($ServiceStartupDelay / 1000) & "s")
  Sleep($ServiceStartupDelay)

  Local $LastCycle = 0
  Local $LastCachePurge = _DateDiff('s', "1970/01/01 00:00:00", _NowCalc())
  Local $Now = 0

  While (True)
    ; Check the last run time against the current time
    $Now = _DateDiff('s', "1970/01/01 00:00:00", _NowCalc())

    Local $CurrentProcessPriority = $ProcessPriority

    ; Reload settings from the regisrty.  This way we don't need to restart the
    ;  service each time a setting is changed
    ;TODO: this will override command line options which we didn't want to do.
    _LoadConfigFromRegistry($TargetDrive)

    If (($ProcessPriority > -1) And ($ProcessPriority <> $CurrentProcessPriority)) Then
      _ConsoleWriteVerbose(1, "", "Setting my process priority to: " & $ProcessPriority)
      ProcessSetPriority (@AutoItPID, $ProcessPriority)
    EndIf

    _ConsoleWriteVerbose(3, "", "LastCycle: " & $LastCycle & ", Now: " & $Now)
    If (($LastCycle + ($ServiceCycleFrequency / 1000)) < $Now) Then
      _ConsoleWriteVerbose(1, "", "Running _MainProcess")
      $LastCycle = $Now

      ; Run the part that does the hard work
      Local $MainProcessResult = _MainProcess()

      If Not ($MainProcessResult) Then
        _ConsoleWriteError("TODO: Something in the _MainProcess failed.  We need to let the backup program know to run a full backup.")
        ;TODO: Send something to $StatusToFile that indicates that a full backup should happen
      EndIf

      ; Cleanup variables so we're ready for the next cycle
      ReDim $MFTReferences[2]
      $MinUSN = $MaxUSN

      ; Save the most recently extracted USN as the new MinUSN in the registry
      ; https://www.autoitscript.com/autoit3/docs/functions/RegWrite.htm
      RegWrite("HKEY_LOCAL_MACHINE\SOFTWARE\USNJBackupQueue\Volumes\" & $TargetDrive, "MinUSN", "REG_QWORD", $MinUSN)
      RegWrite("HKEY_LOCAL_MACHINE\SOFTWARE\USNJBackupQueue\Volumes\" & $TargetDrive, "LastUsnJrnlTimestamp", "REG_SZ", $LastUsnJrnlTimestamp)

      $LastCycle = _DateDiff('s', "1970/01/01 00:00:00", _NowCalc())
    EndIf

    ; We don't want to purge these arrays every time because there is so much
    ; usefull information in them.  Over time though they will start to contain
    ; stale entries.
    $Now = _DateDiff('s', "1970/01/01 00:00:00", _NowCalc())
    _ConsoleWriteVerbose(3, "", "LastCachePurge: " & $LastCachePurge & ", Now: " & $Now)
    If (($LastCachePurge + ($CachePurgeFrequency / 1000)) < $Now) Then
      _ConsoleWriteVerbose(1, "", "Purging $MFT Cache")
      $LastCachePurge = _DateDiff('s', "1970/01/01 00:00:00", _NowCalc())
      ReDim $MftRefNames[2]
      ReDim $MftRefFullNames[2]
      ReDim $MftRefParents[2]
    EndIf

    ;TODO It would be great if we could sample the system CPU load and adjust
    ; $CPUThrottle dynamically to limit our impact on the system.
    ; https://www.autoitscript.com/forum/topic/90736-performance-counters-in-windows-measure-process-cpu-network-disk-usage/?page=1

    Sleep(2000)
  Wend
Else
  _MainProcess()
EndIf

Func _LoadConfigFromRegistry($TargetDrive)
  Local $PotentialValue = False
  Local $RegistryKey = "HKEY_LOCAL_MACHINE\SOFTWARE\USNJBackupQueue\Volumes\" & $TargetDrive

  ;TODO: Use new functions
  ;_LoadStringFromRegistry($RegistryKey, "PathSeparator", Null, $PathSeparator)
  ;_LoadBoolFromRegistry($RegistryKey, "IgnoreRecycleBin", Null, $IgnoreRecycleBin)
  _LoadNumberFromRegistry($RegistryKey, "MaxUSNEntriesToProcess", $MaxUSNEntriesToProcess, $MaxUSNEntriesToProcess)
  _LoadNumberFromRegistry($RegistryKey, "VerboseOn", $VerboseOn, $VerboseOn)
  _LoadNumberFromRegistry($RegistryKey, "VerboseToFileOn", $VerboseToFileOn, $VerboseToFileOn)
  _LoadNumberFromRegistry($RegistryKey, "ProcessPriority", $ProcessPriority, $ProcessPriority)
  _LoadNumberFromRegistry($RegistryKey, "ServiceCycleFrequency", $ServiceCycleFrequency, $ServiceCycleFrequency)
  _LoadNumberFromRegistry($RegistryKey, "ServiceStartupDelay", $ServiceStartupDelay, $ServiceStartupDelay)
  _LoadNumberFromRegistry($RegistryKey, "CachePurgeFrequency", $CachePurgeFrequency, $CachePurgeFrequency)
  _LoadNumberFromRegistry($RegistryKey, "CPUThrottle", $CPUThrottle, $CPUThrottle)
  _LoadBoolFromRegistry($RegistryKey, "RelativePaths", $RelativePaths, $RelativePaths)

  ; The AppendToXXXXFile variables need to be converted to 1 for append, 2 for
  ;  overwrite
  Local $PotentialAppendToFile = $AppendToOutputFile
  _LoadNumberFromRegistry($RegistryKey, "AppendToOutputFile", $PotentialAppendToFile, $PotentialAppendToFile)
  If ($PotentialAppendToFile > 0) Then
    $AppendToOutputFile = 1
  Else
    $AppendToOutputFile = 2
  EndIf
  $PotentialAppendToFile = $AppendToLogFile
  _LoadNumberFromRegistry($RegistryKey, "AppendToLogFile", $PotentialAppendToFile, $PotentialAppendToFile)
  If ($PotentialAppendToFile > 0) Then
    $AppendToLogFile = 1
  Else
    $AppendToLogFile = 2
  EndIf

  ;TODO: This is some ugly code!
  $PotentialValue = RegRead("HKEY_LOCAL_MACHINE\SOFTWARE\USNJBackupQueue\Volumes\" & $TargetDrive, "PathSeparator")
  If IsString($PotentialValue) And Not @error Then $PathSeparator = $PotentialValue
  SetError(0)

  $PotentialValue = RegRead("HKEY_LOCAL_MACHINE\SOFTWARE\USNJBackupQueue\Volumes\" & $TargetDrive, "IgnoreRecycleBin")
  If IsNumber($PotentialValue) And Not @error Then
    $IgnoreRecycleBin = False
    If ($PotentialValue > 0) Then $IgnoreRecycleBin = True
  EndIf

  $PotentialValue = RegRead("HKEY_LOCAL_MACHINE\SOFTWARE\USNJBackupQueue\Volumes\" & $TargetDrive, "OutputToFile")
  If IsString($PotentialValue) And Not @error Then $OutputToFile = $PotentialValue
  SetError(0)

  $PotentialValue = RegRead("HKEY_LOCAL_MACHINE\SOFTWARE\USNJBackupQueue\Volumes\" & $TargetDrive, "IgnoreSysVolInfo")
  If IsNumber($PotentialValue) And Not @error Then
    $IgnoreSysVolInfo = False
    If ($PotentialValue > 0) Then $IgnoreSysVolInfo = True
  EndIf

  ;$PotentialValue = RegRead("HKEY_LOCAL_MACHINE\SOFTWARE\USNJBackupQueue\Volumes\" & $TargetDrive, "RelativePaths")
  ;If IsNumber($PotentialValue) And Not @error Then
  ;  $RelativePaths = False
  ;  If ($PotentialValue > 0) Then $RelativePaths = True
  ;EndIf

  $PotentialValue = RegRead("HKEY_LOCAL_MACHINE\SOFTWARE\USNJBackupQueue\Volumes\" & $TargetDrive, "RelativePathPrefix")
  If IsString($PotentialValue) And Not @error Then $RelativePathPrefix = $PotentialValue
  SetError(0)

  $PotentialValue = RegRead("HKEY_LOCAL_MACHINE\SOFTWARE\USNJBackupQueue\Volumes\" & $TargetDrive, "IncludeParents")
  If IsNumber($PotentialValue) And Not @error Then
    $IncludeParents = False
    If ($PotentialValue > 0) Then $IncludeParents = True
  EndIf

  $PotentialValue = RegRead("HKEY_LOCAL_MACHINE\SOFTWARE\USNJBackupQueue\Volumes\" & $TargetDrive, "AppendToOutputFile")
  If IsNumber($PotentialValue) And Not @error Then
    $AppendToOutputFile = False
    If ($PotentialValue > 0) Then $AppendToOutputFile = True
  EndIf

  $PotentialValue = RegRead("HKEY_LOCAL_MACHINE\SOFTWARE\USNJBackupQueue\Volumes\" & $TargetDrive, "StatusToFile")
  If IsString($PotentialValue) And Not @error Then $StatusToFile = $PotentialValue
  SetError(0)

  $PotentialValue = RegRead("HKEY_LOCAL_MACHINE\SOFTWARE\USNJBackupQueue\Volumes\" & $TargetDrive, "LogToFile")
  If IsString($PotentialValue) And Not @error Then $LogToFile = $PotentialValue
  SetError(0)
EndFunc

Func _LoadStringFromRegistry($Key, $Value, $DefaultValue, ByRef $Variable)
  Local $PotentialValue = RegRead($Key, $Value)
  If IsString($PotentialValue) And Not @error Then
    $Variable = $PotentialValue
    Return True
  Else
    ;TODO: Only change the value to $DefaultValue if DefaultValue is not Null?
    $Variable = $DefaultValue
    Return False
  EndIf
EndFunc

Func _LoadNumberFromRegistry($Key, $Value, $DefaultValue, ByRef $Variable)
  Local $PotentialValue = RegRead($Key, $Value)
  If IsNumber($PotentialValue) And Not @error Then
    $Variable = $PotentialValue
    Return True
  ElseIf @error Then
    _ConsoleWriteError("Error reading registry value '" & $Value & "'.  " & @error)
    ;TODO: Only change the value to $DefaultValue if DefaultValue is not Null?
    $Variable = $DefaultValue
    Return False
  ElseIf Not IsNumber($PotentialValue) Then
    If ($PotentialValue = "") Then
      _ConsoleWriteVerbose(3, "", "Invalid value for registry value '" & $Key & "' '" & $Value & "' got '" & $PotentialValue & "'.  Number expected." )
      $Variable = $DefaultValue
    Else
      _ConsoleWriteError("Invalid value for registry value '" & $Key & "' '" & $Value & "' got '" & $PotentialValue & "'.  Number expected." )
      ;TODO: Only change the value to $DefaultValue if DefaultValue is not Null?
      $Variable = $DefaultValue
    EndIf
    Return False
  EndIf
EndFunc

Func _LoadBoolFromRegistry($Key, $Value, $DefaultValue, ByRef $Variable)
  Local $PotentialValue = RegRead($Key, $Value)
  Local $ReadError = @error
  If IsNumber($PotentialValue) And Not $ReadError Then
    If ($PotentialValue > 0) Then
      $Variable = True
    Else
      $Variable = False
    EndIf
    Return True
  ElseIf $ReadError Then
    _ConsoleWriteError("Error reading registry value '" & $Value & "'.  " & $ReadError)
    ;TODO: Only change the value to $DefaultValue if DefaultValue is not Null?
    $Variable = $DefaultValue
    Return False
  ElseIf Not IsNumber($PotentialValue) Then
    _ConsoleWriteError("Invalid value for registry value '" & $Key & "' '" & $Value & "'.  Number expected but found '" & $PotentialValue & "'." )
    ;TODO: Only change the value to $DefaultValue if DefaultValue is not Null?
    $Variable = $DefaultValue
    Return False
  EndIf
EndFunc

Func _MainProcess()
  ; Check that the target drive has the USN journal enabled.
  Local $FSUTILPid = Run("fsutil usn queryjournal " & $TargetDrive, @ScriptDir, @SW_HIDE, $STDOUT_CHILD)
  local $OutputEntries[1]
  ProcessWaitClose($FSUTILPid)
  Local $FSUTILResult = StdoutRead($FSUTILPid)
  _ConsoleWriteVerbose(1, "", $FSUTILResult)
  If (StringInStr($FSUTILResult, "First Usn") < 1) Then
    _ConsoleWriteError("The USN Journal is not enabled on " & $TargetDrive & "." & @CRLF)
    _ConsoleWriteError("On Windows 2008 and higher you can use the 'fsutil' tool to enable the USN Journal." & @CRLF)
    _ConsoleWriteError("Please complete a full, rather than an incremental, backup." & @CRLF)
    Exit
  Else
    _ConsoleWriteVerbose(1, "", "USN Journal is enabled for " & $TargetDrive & ".")
    ;We can check from the fsutil output if $MinUSN is still in the journal and if
    ; the most recent USN is way too far ahead to make the rest of the USN
    ; processing worth while.
    For $Line In StringSplit($FSUTILResult, @CRLF)
      If (StringInStr($Line, "First Usn") > 0) Then
        $FirstUSN = (StringSplit($Line, ":"))[2]
        If ((StringLen($FirstUSN) > 0) And (StringInStr($FirstUSN, "0x") > 0)) Then
          $FirstUSN = StringReplace($FirstUSN, " ", "")
          $FirstUSN = StringReplace($FirstUSN, "0x", "")
          $FirstUSN = Dec($FirstUSN)
        Else
          $FirstUSN = 20
        EndIf
      ElseIf (StringInStr($Line, "Next Usn") > 0) Then
        $FSUtilMaxUSN = (StringSplit($Line, ":"))[2]
        If ((StringLen($FSUtilMaxUSN) > 0) And (StringInStr($FSUtilMaxUSN, "0x") > 0)) Then
          $FSUtilMaxUSN = StringReplace($FSUtilMaxUSN, " ", "")
          $FSUtilMaxUSN = StringReplace($FSUtilMaxUSN, "0x", "")
          $FSUtilMaxUSN = Dec($FSUtilMaxUSN)
        Else
          $FSUtilMaxUSN = 20
        EndIf
      EndIf
    Next
  EndIf

  _ConsoleWriteLine("RelativePathPrefix: " & $RelativePathPrefix)

  ; If the MinUSN (-m) no longer exists in the journal, exit.
  If (($MinUSN < $FirstUSN) And ($MinUSN > 0)) Then
    _ConsoleWriteLine("Minimum Acceped USN: " & $MinUSN)
    _ConsoleWriteLine("Minimum Found USN: " & $FirstUSN)
    _ConsoleWriteLine("Maximum Found USN: " & $FSUtilMaxUSN)
    _ConsoleWriteError(@CRLF & "USN " & $MinUSN & " was not found in the journal.  This means that changes have been made to the filesystem between " & $MinUSN & " and now that have been removed from the journal." & @CRLF)
    _ConsoleWriteError("This may mean that your USN journal is too small or that too much time has passed (i.e. too many changes have occurred) since your last backup." & @CRLF)
    _ConsoleWriteError("Please complete a full, rather than an incremental, backup." & @CRLF)
    Return False
  EndIf

  ; If there are more than MaxUSNEntriesToProcess (-M) entries in the journal, exit.
  If ((($FSUtilMaxUSN - $MinUSN) > $MaxUSNEntriesToProcess) And ($MaxUSNEntriesToProcess > 0) And ($MinUSN > 0) And (Not $ServiceMode)) Then
    _ConsoleWriteLine("Minimum Acceped USN: " & $MinUSN)
    _ConsoleWriteLine("Minimum Found USN: " & $FirstUSN)
    _ConsoleWriteLine("Maximum Found USN: " & $FSUtilMaxUSN)
    _ConsoleWriteError(@CRLF & "More than " & $MaxUSNEntriesToProcess & " (limit set by -M command lime parameter) exist in the journal" & @CRLF)
    _ConsoleWriteError("Please complete a full, rather than an incremental, backup." & @CRLF)
    Return False
  ElseIf ((($FSUtilMaxUSN - $FirstUSN) > $MaxUSNEntriesToProcess) And ($MaxUSNEntriesToProcess > 0) And ($MinUSN = 0)) Then
    _ConsoleWriteLine("Minimum Acceped USN: " & $MinUSN)
    _ConsoleWriteLine("Minimum Found USN: " & $FirstUSN)
    _ConsoleWriteLine("Maximum Found USN: " & $FSUtilMaxUSN)
    _ConsoleWriteError(@CRLF & "More than " & $MaxUSNEntriesToProcess & " (limit set by -M command lime parameter) exist in the journal" & @CRLF)
    _ConsoleWriteError("Please complete a full, rather than an incremental, backup." & @CRLF)
    Return False
  EndIf

  ; We need ExtractUsnJrnl.exe.  Make sure it exists.
  If FileExists(@ScriptDir & "\ExtractUsnJrnl\ExtractUsnJrnl.exe") Then
    $ExtractUsnJrnlPath = @ScriptDir & "\ExtractUsnJrnl\"
  ElseIf FileExists(@ScriptDir & "\ExtractUsnJrnl.exe") Then
    $ExtractUsnJrnlPath = @ScriptDir & "\"
  Else
    _ConsoleWriteError("ExtractUsnJrnl.exe not found!")
    Return False
  EndIf

  ; Need to set $File to USN Journal file path
  $File = $ExtractUsnJrnlPath & "\$UsnJrnl_$J.bin"

  ; Delete $File if it exists
  If FileExists($File) Then
    _ConsoleWriteVerbose(1, "", "Deleting previously extracted USN Journal.")
    FileDelete($File)
  EndIf

  ; Here we call the ExtractUsnJrnl.exe to extract a copy of the USN Journal from
  ; the target drive
  _ConsoleWriteLine("Extracting USN Journal with ExtractUsnJrnl.exe")
  ;TODO: Maybe we allow for specifying the working directory used on the next line
  ; so the caller has more control over where the temporary file is stored.
  Local $ExtractUsnJrnlPid = Run($ExtractUsnJrnlPath & "ExtractUsnJrnl.exe " & $TargetDrive, $ExtractUsnJrnlPath, @SW_HIDE, $STDOUT_CHILD)
  ProcessWaitClose($ExtractUsnJrnlPid)
  Local $ExtractUsnJrnlResult = StdoutRead($ExtractUsnJrnlPid)
  _ConsoleWriteVerbose(1, "", $ExtractUsnJrnlResult)
  Sleep($CPUThrottle * 10)

  ;For Testing: To actually use a USN Journal file other than the one just
  ; extracted, override the value of $File here.
  ;$File = $ExtractUsnJrnlPath & "\$UsnJrnl_$J.bin-rds1-wak-C"

  If Not FileExists($File) Then
  	_ConsoleWriteError("Error: Could not find extracted USN Journal file.  Maybe ExtractUsnJrnl.exe failed.")
  	Return False
  EndIf
  $TimestampStart = @YEAR & "-" & @MON & "-" & @MDAY & "_" & @HOUR & "-" & @MIN & "-" & @SEC

  _ConsoleWriteLine("Decoding $UsnJrnl info...")
  $tBuffer = DllStructCreate("byte[" & $Record_Size & "]")
  $hFile = _WinAPI_CreateFile("\\.\" & $File,2,2,7)
  If $hFile = 0 Then
  	_ConsoleWriteError("Error: Creating handle on file")
  	Return False
  EndIf
  $InputFileSize = _WinAPI_GetFileSizeEx($hFile)
  $MaxRecords = Ceiling($InputFileSize/$Record_Size)
  $MaxUSN = 0
  $LastPageMaxUSN = 0
  $CurrentPage = 0
  Local $ProcessedPages = 0
  ;For $CurrentPage = 0 To $MaxRecords-1
  _ConsoleWriteLine("Max Records: " & $MaxRecords)
  _ConsoleWriteLine("Input File Size: " & $InputFileSize)
  While (($CurrentPage < $MaxRecords) And (($ProcessedPages < $MaxUSNEntriesToProcess) or ($MaxUSNEntriesToProcess < 1)))
    ; TODO: Time limiting code here

    ; Each page is 4096 bytes long and, as far as I can tell, contains a maximum
    ; of 57 records.  These records aren't sequential but are increasing by 72
    ; each time.  57*72 almost equals the page size of 4096 so there's probably a
    ; connection I'm not quite getting.  Anyway, based on the highest USN we have
    ; found so far, can we (with a 10% safety net), skip ahead some pages?  Note
    ; that even if we skip ahead we still process one page this loop so we don't
    ; do multiple skips without actually checking the journal to make sure our
    ; math is alligned with reality.
    If (($CurrentPage > 0) And ($MaxUSN > 0)) Then
      If (($MaxUSN + (5500 * 57 * 72)) < $MinUSN) Then
        _ConsoleWriteVerbose(1, "", "Skipping from page " & $CurrentPage & " to page " & ($CurrentPage + 5000) & " (5000 pages).")
        $CurrentPage = $CurrentPage + 5000
        Sleep($CPUThrottle)
      ElseIf (($MaxUSN + (1100 * 57 * 72)) < $MinUSN) Then
        _ConsoleWriteVerbose(1, "", "Skipping from page " & $CurrentPage & " to page " & ($CurrentPage + 1000) & " (1000 pages).")
        $CurrentPage = $CurrentPage + 1000
        Sleep($CPUThrottle)
      ElseIf (($MaxUSN + (550 * 57 * 72)) < $MinUSN) Then
        _ConsoleWriteVerbose(1, "", "Skipping from page " & $CurrentPage & " to page " & ($CurrentPage + 500) & " (500 pages).")
        $CurrentPage = $CurrentPage + 500
        Sleep($CPUThrottle)
      ElseIf (($MaxUSN + (110 * 57 * 72)) < $MinUSN) Then
        _ConsoleWriteVerbose(1, "", "Skipping from page " & $CurrentPage & " to page " & ($CurrentPage + 100) & " (100 pages).")
        $CurrentPage = $CurrentPage + 100
        Sleep($CPUThrottle)
      ElseIf (($MaxUSN + (55 * 57 * 72)) < $MinUSN) Then
        _ConsoleWriteVerbose(1, "", "Skipping from page " & $CurrentPage & " to page " & ($CurrentPage + 50) & " (50 pages).")
        $CurrentPage = $CurrentPage + 50
        Sleep($CPUThrottle)
      ElseIf (($MaxUSN + (11 * 57 * 72)) < $MinUSN) Then
        _ConsoleWriteVerbose(1, "", "Skipping from page " & $CurrentPage & " to page " & ($CurrentPage + 10) & " (10 pages).")
        $CurrentPage = $CurrentPage + 10
        Sleep($CPUThrottle)
      ElseIf (($MaxUSN + (5.5 * 57 * 72)) < $MinUSN) Then
        _ConsoleWriteVerbose(1, "", "Skipping from page " & $CurrentPage & " to page " & ($CurrentPage + 5) & " (5 pages).")
        $CurrentPage = $CurrentPage + 5
        Sleep($CPUThrottle)
      Else
        $ProcessedPages = $ProcessedPages + 1
      EndIf
    EndIf

    $LastPageMaxUSN = 0
  	_WinAPI_SetFilePointerEx($hFile, $CurrentPage*$Record_Size, $FILE_BEGIN)
  	If $CurrentPage = $MaxRecords-1 Then $tBuffer = DllStructCreate("byte[" & $Record_Size & "]")
  	_WinAPI_ReadFile($hFile, DllStructGetPtr($tBuffer), $Record_Size, $nBytes)
  	$RawPage = DllStructGetData($tBuffer, 1)
  	_UsnProcessPage(StringMid($RawPage,3))
    Sleep($CPUThrottle)
    $CurrentPage = $CurrentPage + 1
  Wend
  ;Next

  _ConsoleWriteLine("Decoding finished")
  _ConsoleWriteLine("Minimum Acceped USN: " & $MinUSN)
  _ConsoleWriteLine("Minimum Found USN: " & $FirstUSN)
  _ConsoleWriteLine("Maximum Found USN: " & $MaxUSN)

  ; If $MinUSN > $MaxUSN then the provided $MinUSN cannot have been correct
  If ($MinUSN > $MaxUSN) Then
    _ConsoleWriteError(@CRLF & "USN " & $MinUSN & " was higher than the highest USN found in the journal.  The highest USN actually found in the journal will now be used as the baseline." & @CRLF)
    _ConsoleWriteError("Please complete a full, rather than an incremental, backup." & @CRLF)
    _WinAPI_CloseHandle($hFile)
    Return False
  EndIf

  ; If $MinUSN < $FirstUSN then there are gaps in the journal between the
  ; last time we ran and now (somehow missed by the check earlier).  DO A FULL
  ; BACKUP!
  If (($MinUSN < $FirstUSN) And ($MinUSN > 0)) Then
    _ConsoleWriteError(@CRLF & "USN " & $MinUSN & " was not found in the journal.  This means that changes have been made to the filesystem between " & $MinUSN & " and now that have been removed from the journal." & @CRLF)
    _ConsoleWriteError("This may mean that your USN journal is too small or that too much time has passed (i.e. too many changes have occurred) since your last backup." & @CRLF)
    _ConsoleWriteError("Please complete a full, rather than an incremental, backup." & @CRLF)
    _WinAPI_CloseHandle($hFile)
    Return False
  EndIf

  ; If we're going to output to file, open the file for writing now
  If (StringLen($OutputToFile) > 0) Then
    $OutputFile = FileOpen($OutputToFile, $OutputFileEncoding + $AppendToOutputFile)
    If @error Then
      ConsoleWriteError("Error creating: " & $OutputToFile)
      Return False
    EndIf
  EndIf

  ; Resolve MtfReference numbers to real file paths.  This is still our biggest
  ; performance bottleneck and needs more attention
  $MFTReferences = _ArrayUnique($MFTReferences, 0, 0, 0, $ARRAYUNIQUE_NOCOUNT, $ARRAYUNIQUE_MATCH)
  _ConsoleWriteVerbose(1, "", "Accepted USNs: " & _ArrayToString($MFTReferences, ", "))
  For $RefIndex = 1 To UBound($MFTReferences)-1
    $FullFileName = MftRef2Name($MFTReferences[$RefIndex])
    If ($IgnoreSysVolInfo) And (StringInStr($FullFileName, "System Volume Information") > 0) And (StringInStr($FullFileName, "System Volume Information") < 5) Then
      Sleep($CPUThrottle / 5)
      ContinueLoop
    EndIf
    If ($IgnoreRecycleBin) And (StringInStr($FullFileName, "$RECYCLE.BIN") > 0) And (StringInStr($FullFileName, "$RECYCLE.BIN") < 5) Then
      Sleep($CPUThrottle / 5)
      ContinueLoop
    EndIf
    If ($IncludeParents) Then
      $Parents = StringSplit($FullFileName, $PathSeparator)
      $ParentTrail = $RelativePathPrefix
      For $ParentIndex = 1 To UBound($Parents)-2
        If (StringLen($Parents[$ParentIndex]) < 1) Then
          Sleep($CPUThrottle / 5)
          ContinueLoop
        EndIf
        If (StringLen($ParentTrail) > 1) Then
          $ParentTrail = $ParentTrail & $PathSeparator & $Parents[$ParentIndex]
        Else
          $ParentTrail = $ParentTrail & $Parents[$ParentIndex]
        EndIf
        If (_ArraySearch($OutputEntries, $ParentTrail, 0, 0, 0, 2) < 1) Then
          If (StringLen($OutputToFile) > 0) Then
            FileWriteLine($OutputFile, $ParentTrail)
          Else
            _ConsoleWriteLine($ParentTrail)
          EndIf
          _ArrayAdd($OutputEntries, $ParentTrail)
        EndIf
      Next
    EndIf

    If (_ArraySearch($OutputEntries, $FullFileName, 0, 0, 0, 2) < 1) Then
      If (StringLen($OutputToFile) > 0) Then
        FileWriteLine($OutputFile, $FullFileName)
      Else
        _ConsoleWriteLine($FullFileName)
      EndIf
      _ArrayAdd($OutputEntries, $FullFileName)
    EndIf
    Sleep($CPUThrottle / 5)
  Next

  _ConsoleWriteVerbose(3, "", "MftRefParents: " & _ArrayToString($MftRefParents, @CRLF))
  _ConsoleWriteVerbose(3, "", "MftRefNames: " & _ArrayToString($MftRefNames, @CRLF))
  _ConsoleWriteVerbose(3, "", "MftRefFullNames: " & _ArrayToString($MftRefFullNames, @CRLF))

  ; Close the output file
  If (StringLen($OutputToFile) > 0) Then
    FileFlush($OutputFile)
    FileClose($OutputFile)
  EndIf

  _WinAPI_CloseHandle($hFile)

  ;TODO: Probably should delete the extracted $UsnJrnl_$J.bin file before we quit
  Return True

EndFunc

Func _UsnDecodeRecord($Record)
	$UsnJrnlRecordLength = StringMid($Record,1,8)
	$UsnJrnlRecordLength = Dec(_SwapEndian($UsnJrnlRecordLength),2)
;	$UsnJrnlMajorVersion = StringMid($Record,9,4)
;	$UsnJrnlMinorVersion = StringMid($Record,13,4)
	$UsnJrnlFileReferenceNumber = StringMid($Record,17,12)
	$UsnJrnlFileReferenceNumber = Dec(_SwapEndian($UsnJrnlFileReferenceNumber),2)
	$UsnJrnlMFTReferenceSeqNo = StringMid($Record,29,4)
	$UsnJrnlMFTReferenceSeqNo = Dec(_SwapEndian($UsnJrnlMFTReferenceSeqNo),2)
	$UsnJrnlParentFileReferenceNumber = StringMid($Record,33,12)
	$UsnJrnlParentFileReferenceNumber = Dec(_SwapEndian($UsnJrnlParentFileReferenceNumber),2)
	$UsnJrnlParentReferenceSeqNo = StringMid($Record,45,4)
	$UsnJrnlParentReferenceSeqNo = Dec(_SwapEndian($UsnJrnlParentReferenceSeqNo),2)
	$UsnJrnlUsn = StringMid($Record,49,16)
	$UsnJrnlUsn = Dec(_SwapEndian($UsnJrnlUsn),2)
;	If $i = 1704000 Then $PreviousUsn = $UsnJrnlUsn
;	If $PreviousUsn < $UsnJrnlUsn Then Exit
;	$PreviousUsn = $UsnJrnlUsn
	$UsnJrnlTimestamp = StringMid($Record,65,16)
	$UsnJrnlTimestamp = _DecodeTimestamp($UsnJrnlTimestamp)
	$UsnJrnlReason = StringMid($Record,81,8)
	$UsnJrnlReason = _DecodeReasonCodes("0x"&_SwapEndian($UsnJrnlReason))
;	$UsnJrnlSourceInfo = StringMid($Record,89,8)
;	$UsnJrnlSourceInfo = _DecodeSourceInfoFlag("0x"&_SwapEndian($UsnJrnlSourceInfo))
;	$UsnJrnlSourceInfo = "0x"&_SwapEndian($UsnJrnlSourceInfo)
;	$UsnJrnlSecurityId = StringMid($Record,97,8)
	$UsnJrnlFileAttributes = StringMid($Record,105,8)
	$UsnJrnlFileAttributes = _File_Attributes("0x"&_SwapEndian($UsnJrnlFileAttributes))
	$UsnJrnlFileNameLength = StringMid($Record,113,4)
	$UsnJrnlFileNameLength = Dec(_SwapEndian($UsnJrnlFileNameLength),2)
	$UsnJrnlFileNameOffset = StringMid($Record,117,4)
	$UsnJrnlFileNameOffset = Dec(_SwapEndian($UsnJrnlFileNameOffset),2)
	$UsnJrnlFileName = StringMid($Record,121,$UsnJrnlFileNameLength*2)
	$UsnJrnlFileName = _UnicodeHexToStr($UsnJrnlFileName)

	If $VerboseOn > 3 Then
		_ConsoleWriteVerbose(3, "", "$UsnJrnlFileReferenceNumber: " & $UsnJrnlFileReferenceNumber)
		_ConsoleWriteVerbose(3, "", "$UsnJrnlMFTReferenceSeqNo: " & $UsnJrnlMFTReferenceSeqNo)
		_ConsoleWriteVerbose(3, "", "$UsnJrnlParentFileReferenceNumber: " & $UsnJrnlParentFileReferenceNumber)
		_ConsoleWriteVerbose(3, "", "$UsnJrnlParentReferenceSeqNo: " & $UsnJrnlParentReferenceSeqNo)
		_ConsoleWriteVerbose(3, "", "$UsnJrnlUsn: " & $UsnJrnlUsn)
		_ConsoleWriteVerbose(3, "", "$UsnJrnlTimestamp: " & $UsnJrnlTimestamp)
		_ConsoleWriteVerbose(3, "", "$UsnJrnlReason: " & $UsnJrnlReason)
;		_ConsoleWriteVerbose(3, "", "$UsnJrnlSourceInfo: " & $UsnJrnlSourceInfo)
;		_ConsoleWriteVerbose(3, "", "$UsnJrnlSecurityId: " & $UsnJrnlSecurityId)
		_ConsoleWriteVerbose(3, "", "$UsnJrnlFileAttributes: " & $UsnJrnlFileAttributes)
		_ConsoleWriteVerbose(3, "", "$UsnJrnlFileName: " & $UsnJrnlFileName)
	EndIf

  ; We're going to need to know that the first USN in the USN Journal is larger
  ; than the MaxUSN of the previous backup.  Otherwise we have missed changes.
  If (($FirstUSN > $UsnJrnlUsn) Or ($FirstUSN = 0)) Then
    $FirstUSN = $UsnJrnlUsn
  EndIf

  ; We will need the maximum USN value so we know where to kick off the next run
  _ConsoleWriteVerbose(4, "", "This USN: " & $UsnJrnlUsn)
  If ($UsnJrnlUsn > $MaxUSN) Then
    If ($UsnJrnlUsn > $FSUtilMaxUSN) Then
      _ConsoleWriteError("A journal entry has a USN (" & $UsnJrnlUsn & ") that is higher than FSUtil reported was possible (" & $FSUtilMaxUSN & ").")
    Else
      $MaxUSN = $UsnJrnlUsn
    EndIf
  EndIf

  ; The page skipping logic needs to know the highest USN that we find in this
  ; page
  If ($UsnJrnlUsn > $LastPageMaxUSN) Then
    $LastPageMaxUSN = $UsnJrnlUsn
    $LastUsnJrnlTimestamp = $UsnJrnlTimestamp
  EndIf

  ; Exclude files that match any of the regexp patterns in $ExcludeFilePatterns
  Local $PaternIndex = 0
  ;Local $SkipRecord = False
  For $PaternIndex = 1 To UBound($ExcludeFilePatterns)-1
    _ConsoleWriteVerbose(3, "", "Testing file name against pattern: '" & $UsnJrnlFileName & "', '" & $ExcludeFilePatterns[$PaternIndex] & "'")
    If (StringRegExp($UsnJrnlFileName, $ExcludeFilePatterns[$PaternIndex], $STR_REGEXPMATCH)) Then
      _ConsoleWriteVerbose(2, "", "Excluding file based on pattern match: '" & $UsnJrnlFileName & "', '" & $ExcludeFilePatterns[$PaternIndex] & "'")
      ;$SkipRecord = True
      Return True
    EndIf
  Next

  ; If this USN is lower then the MinUSN then this change has already been
  ;  actioned on a previous backup run
  If (($UsnJrnlUsn > $MinUSN) Or ($MinUSN = 0)) Then
    ; Here we have a file name, a file reference number and a parent reference
    ;  number, we may as well add them to the cache.  MftRef2Name might find
    ;  them useful.

    _ConsoleWriteVerbose(3, "", "Reference -> Parent from USN Journal: " & $UsnJrnlFileReferenceNumber & " -> " & $UsnJrnlParentFileReferenceNumber)
    _ArrayAdd($MftRefParents, ":" & $UsnJrnlFileReferenceNumber & ":" & $UsnJrnlParentFileReferenceNumber)
    _ArrayAdd($MftRefNames, ":" & $UsnJrnlFileReferenceNumber & ":" & $UsnJrnlFileName)
    _ArrayAdd($MFTReferences, $UsnJrnlFileReferenceNumber)
  EndIf
EndFunc

Func MftRef2Name($IndexNumber)
  Local Static $Initialised = False
  Local $FullFileName = ""

  If Not $Initialised Then
    _ConsoleWriteVerbose(2, "", "MftRef2Name: Initailising (this should only happen once)")
    $ParentDir = _GenDirArray($TargetDrive & "\")
    Global $MftRefArray[$DirArray[0]+1]

    $hDisk = _WinAPI_CreateFile("\\.\" & $TargetDrive,2,2,7)
    If $hDisk = 0 Then
      _ConsoleWriteError("MftRef2Name Error: CreateFile: " & _WinAPI_GetLastErrorMessage())
      Return
    EndIf

    $MFTEntry = _FindMFT(0)
    If $MFTEntry = "" Then ;something wrong with record for $MFT
      _ConsoleWriteError("MftRef2Name Error: Getting MFT record 0")
      Return
    EndIf

    $MFT = _DecodeMFTRecord0($MFTEntry, 0)        ;produces DataQ for $MFT, record 0
    If $MFT = "" Then
      _ConsoleWriteError("MftRef2Name Error: Parsing the MFT record 0")
      Return
    EndIf

    _GetRunsFromAttributeListMFT0() ;produces datarun for $MFT and converts datarun to RUN_VCN[] and RUN_Clusters[]
    _WinAPI_CloseHandle($hDisk)

    $MFTSize = $DATA_RealSize
    $MFT_RUN_VCN = $RUN_VCN
    $MFT_RUN_Clusters = $RUN_Clusters

    _GenRefArray()
    $Initialised = True
  EndIf

  ; Resolve path based on MFT ref as input
  $ParentIndex = -1
  $NameIndex = -1
  $ResolvedPath = ""
  If StringIsDigit($IndexNumber) Then
    ; _UsnDecodeRecord may have already inserted this file's name and index into the cache
    $ParentIndex = _ArraySearch($MftRefParents, ":" & $IndexNumber & ":", 0, 0, 0, 1)
    $NameIndex = _ArraySearch($MftRefNames, ":" & $IndexNumber & ":", 0, 0, 0, 1)

    If (($ParentIndex < 0) Or ($NameIndex < 0)) Then
    	Global $DataQ[1],$AttribX[1],$AttribXType[1],$AttribXCounter[1]
    	$NewRecord = _FindFileMFTRecord($IndexNumber)
    	_DecodeMFTRecord($NewRecord,2)
    	$TestHeaderFlags = $RecordHdrArr[7][1]
    	If StringInStr($TestHeaderFlags,"ALLOCATED")=0 And StringInStr($TestHeaderFlags,"ENABLED")=0 Then
    		Return "Deleted!"

      ;TODO: ElseIf: See "$HEADER_Flags = 'FOLDER'" in _DecodeMFTRecord to filter out folders
    	EndIf
    	$TmpRef = _GetParent()
    	$TestFileName = $TmpRef[1]
    	$TestParentRef = $TmpRef[0]
      ;$BottomRef = $TestParentRef
      $FileName = $TestFileName
      ConsoleWrite("I looked up this file's parent and it is: " & $TestParentRef)
      ConsoleWrite("I looked up this file's name and it is: " & $FileName)
    Else
      $TestParentRef = StringSplit($MftRefParents[$ParentIndex], ":", $STR_NOCOUNT)[2]
      $FileName = StringSplit($MftRefNames[$NameIndex], ":", $STR_NOCOUNT)[2]
    EndIf
    $BottomRef = $TestParentRef

    ; Our first line of defense against actually going to the $Mft to work out
    ; where in the filesystem heirachy this file exists is that we cache the
    ; full path of any folder reference we have used in the past in the
    ; $MftRefFullNames array.
    $NameIndex = _ArraySearch($MftRefFullNames, ":" & $TestParentRef & ":", 0, 0, 0, 1)
    If ($NameIndex > -1) Then
      ;ConsoleWrite("Using cached Full Name")
      $ResolvedPath = StringSplit($MftRefFullNames[$NameIndex], ":", $STR_NOCOUNT)[2]

    Else
      ; If we haven't cached the full location of this folder, we have to
      ; navigate our way up the tree to the root.  Each time we fetch a name and
      ; $Mft reference we cache it to MftRefNames and MftRefParents so we never
      ; need to ask the file system the same question twice
      Local $LoopCounter = 0;
    	Do
        $ParentIndex = _ArraySearch($MftRefParents, ":" & $TestParentRef & ":", 0, 0, 0, 1)
        $NameIndex = _ArraySearch($MftRefNames, ":" & $TestParentRef & ":", 0, 0, 0, 1)
        If (($ParentIndex > -1) And ($NameIndex > -1)) Then
          $TestFileName = StringSplit($MftRefNames[$NameIndex], ":", $STR_NOCOUNT)[2]
          $TestParentRef = StringSplit($MftRefParents[$ParentIndex], ":", $STR_NOCOUNT)[2]
          _ConsoleWriteVerbose(2, "", "I think I know the answer.  Is it #" & $TestParentRef & " and '" & $TestFileName & "' ?")
        Else
      		Global $DataQ[1],$AttribX[1],$AttribXType[1],$AttribXCounter[1]
      		$NewRecord = _FindFileMFTRecord($TestParentRef)
          If ($NewRecord = "") Then
            _ConsoleWriteError("_FindFileMFTRecord did not return a record.  Skipping.")
            ExitLoop
          EndIf
      		_DecodeMFTRecord($NewRecord,2)
      		$TmpRef = _GetParent()
      		If @error then ExitLoop
          _ConsoleWriteVerbose(2, "", "Reference -> Parent from $Mft: " & $TestParentRef & " -> " & $TmpRef[0])
          _ArrayAdd($MftRefParents, ":" & $TestParentRef & ":" & $TmpRef[0])
          _ArrayAdd($MftRefNames, ":" & $TestParentRef & ":" & $TmpRef[1])
        	$TestFileName = $TmpRef[1]
        	$TestParentRef = $TmpRef[0]
        EndIf
    		$ResolvedPath = $TestFileName & $PathSeparator & $ResolvedPath
        $LoopCounter = $LoopCOunter + 1

        ; Take a small sleep
        Sleep($CPUThrottle / 10)
    	Until (($TestParentRef = 5) Or ($LoopCounter > 500))

      ; This should never happen but just in case it does we will output an
      ;  error message.
      If ((Not $TestParentRef = 5) Or ($LoopCounter > 500)) Then
        _ConsoleWriteError("MftRef2Name: Unable to resolve $Mft entry to volume root.  " & $TestParentRef & " != 5")
        Exit
      EndIf

      If StringLeft($ResolvedPath,2) = "." & $PathSeparator Then $ResolvedPath = StringTrimLeft($ResolvedPath,2)
      _ArrayAdd($MftRefFullNames, ":" & $BottomRef & ":" & $ResolvedPath)
    EndIf

    If ($RelativePaths) Then
      $FullFileName = $RelativePathPrefix & $ResolvedPath & $PathSeparator & $FileName
      _ConsoleWriteVerbose(2, "", "'" & $FullFileName & "' should be a RELATIVE path.")
    Else
      $FullFileName = $TargetDrive & $PathSeparator & $ResolvedPath & $PathSeparator & $FileName
      _ConsoleWriteVerbose(2, "", "'" & $FullFileName & "' should be an ABSOLUTE path.")
    EndIf

  	Return StringReplace($FullFileName, $PathSeparator & $PathSeparator, $PathSeparator)
  EndIf
EndFunc

;TODO: The following functions need to be populated and calls to the original
; functions replaced
Func _ConsoleWriteLine($Text)
  _ConsoleWrite($Text & @CRLF)
EndFunc

Func _ConsoleWrite($Text)
  ConsoleWrite($Text)
  If (StringLen($LogToFile) > 0) Then
    _WriteToLogFile($LogToFile, @TAB & "  " & $Text)
  EndIf
EndFunc

Func _ConsoleWriteError($Text)
  ConsoleWriteError($Text & @CRLF)
  If (StringLen($LogToFile) > 0) Then
    ; Log to the "error" log
    _WriteToLogFile($LogToFile & ".errors", @TAB & "  " & $Text & @CRLF)

    ; Also log to the normal log so there can be some context
    _WriteToLogFile($LogToFile, @TAB & "! " & $Text & @CRLF)
  EndIf
EndFunc

Func _ConsoleWriteVerbose($Level, $Type, $Text)
  If ($Level <= $VerboseOn) Then
    ConsoleWrite($Text & @CRLF)
  EndIf

  If ($Level <= $VerboseToFileOn) Then
    If (StringLen($LogToFile) > 0) Then
      _WriteToLogFile($LogToFile & ".verbose", @TAB & "  " & $Text & @CRLF)
    EndIf
  EndIf
EndFunc

Func _WriteToLogFile($File, $Text)
  Local $LogFile = FileOpen($File & ".log", $OutputFileEncoding + $AppendToLogFile)
  FileWrite($LogFile, _NowCalc() & $Text)
  FileFlush($LogFile)
  FileClose($LogFile)
EndFunc

Func HelpMessage()
  ConsoleWrite($MyName & " " & $MyVersion & @CRLF & @CRLF)
  ConsoleWrite("  " & $MyName & ".exe [-h|-l|-v|-V] [-m num] [-a file|-o file] Volume" & @CRLF)
  ConsoleWrite("     -a file Append changed file list to file." & @CRLF)
  ConsoleWrite("     -h      Show this help message and quit" & @CRLF)
  ConsoleWrite("     -l      Use longer sleep cycles to reduce CPU usage and the expense of the" & @CRLF)
  ConsoleWrite("             process taking longer.  You can use this switch twice or three " & @CRLF)
  ConsoleWrite("             times to further increase the length of the sleep cycles." & @CRLF)
  ConsoleWrite("     -L file Send all console output to a log file as well as the console.  Not" & @CRLF)
  ConsoleWrite("             yet implemented.")
  ConsoleWrite("     -m num  Specify the USN of the first acceptable journal entry.  This will" & @CRLF)
  ConsoleWrite("             likely be the 'Maximum Found USN' from the previous run." & @CRLF)
  ConsoleWrite("             Basically, all journal entries before the specified num will be" & @CRLF)
  ConsoleWrite("             ignored as it is assumed that the changes they represent have" & @CRLF)
  ConsoleWrite("             already been captured by previous backup runs.  If unspecified" & @CRLF)
  ConsoleWrite("             the lowest numbered journal entry is used." & @CRLF)
  ConsoleWrite("     -M num  Maximum number of jounal entries between the first acceptable" & @CRLF)
  ConsoleWrite("             entry (see '-m' above) and the last entry in the journal. If there" & @CRLF)
  ConsoleWrite("             are more than num entries, abort and suggest running a full backup" & @CRLF)
  ConsoleWrite("             Not yet implemented." & @CRLF)
  ConsoleWrite("     -o file Output changed file list to file.  If file already exists it will " & @CRLF)
  ConsoleWrite("             be overwritten" & @CRLF)
  ConsoleWrite("     +p      Include the parent directories of each object in the output list." & @CRLF)
  ConsoleWrite("     -p      Do not include the parent directories of each object in the output " & @CRLF)
  ConsoleWrite("             list." & @CRLF)
  ConsoleWrite("     -r      Output file paths relative to the volume root." & @CRLF)
  ConsoleWrite("     -R path Output file paths relative to the volume root and prefixed with" & @CRLF)
  ConsoleWrite("             path.  This might be useful if you want to create a full path in" & @CRLF)
  ConsoleWrite("             UNC format or reference a VSS snapshot via" & @CRLF)
  ConsoleWrite("             \\?\GLOBALROOT\Device\HarddiskVolumeShadowCopyXXX" & @CRLF)
  ConsoleWrite("     -service Start " & $MyName & " in the experimental 'run as a" & @CRLF)
  ConsoleWrite("             servce' mode" & @CRLF)
  ConsoleWrite("     -S      Exclude files in the 'System Volume Information' directory." & @CRLF)
  ConsoleWrite("     +S      Include files in the 'System Volume Information' directory." & @CRLF)
  ConsoleWrite("     -T      Exclude files in the '$RECYCLE.BIN' directory." & @CRLF)
  ConsoleWrite("     +T      Include files in the '$RECYCLE.BIN' directory." & @CRLF)
  ConsoleWrite("     -t sec  Time limit.  Don't spend more the sec seconds extracting values" & @CRLF)
  ConsoleWrite("             before aborting and suggesting a full backup instead.  Not yet" & @CRLF)
  ConsoleWrite("             implemented." & @CRLF)
  ConsoleWrite("     +u      Use Unix (/) instead of Windows (\) path separator." & @CRLF)
  ConsoleWrite("     -u      Use Windows (\) instead of Unix (/) path separator." & @CRLF)
  ConsoleWrite("     -v      Enable verbose output.  Use twice for more verbose output." & @CRLF)
  ConsoleWrite("     -V      Output version and quit" & @CRLF)
  ConsoleWrite("     Volume  The volume to extract the USN Journal from" & @CRLF & @CRLF)
EndFunc
