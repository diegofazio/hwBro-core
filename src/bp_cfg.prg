/*
 * bp_cfg.prg - hwBro configuration file (hwbro.ini)
 * -----------------------------------------------------------------
 * Persists the GlobalSet of the DB manager plus the theme the program starts
 * with. The file is a plain INI ([section] key=value) named `hwbro.ini` and it
 * lives NEXT TO THE EXECUTABLE (the folder of hwbro.exe), never in the working
 * directory: the program is portable and its settings travel with it.
 *
 * It is written ONLY when the user asks for it ("Save Configuration" in the F6
 * GlobalSet of the DB manager and in Commands > Save configuration of the
 * Harbour Commander). At startup BpCfgLoad() applies what the file says; with no
 * file - or with a value it does not understand - the program keeps the defaults
 * it already installed (driver DBFCDX, EXCLUSIVE, dd/mm/yyyy, epoch 1950, Cell
 * Edit ON, Hide Deleted OFF, Softseek OFF, theme Dark).
 *
 * BRO.INI is the configuration of the ORIGINAL and is never read or written here
 * (see AGENTS.md section 1).
 * -----------------------------------------------------------------
 */
#include "fileio.ch"
#include "bp_def.ch"

#define CFG_FILE        "hwbro.ini"
#define CFG_SEC_GLOBAL  "GLOBALSET"      /* compared UPPER Cased */
#define CFG_SEC_LOOK    "APPEARANCE"     /* compared UPPER Cased */
#define CFG_SEC_COL     "COLORS"         /* compared UPPER Cased */

/* full path of the configuration: the FOLDER OF THE EXECUTABLE + hwbro.ini */
FUNCTION BpCfgPath()
   LOCAL c := hb_ProgName()
   LOCAL n := Max( Rat( "\", c ), Rat( "/", c ) )
   IF n > 0
      c := Left( c, n )
   ELSE
      c := CurDir() + "\"
   ENDIF
RETURN c + CFG_FILE

/* ON/OFF, Y/N and 1/0 -> logical (anything else is .F.) */
STATIC FUNCTION BpCfgBool( cValue )
   LOCAL c := Upper( AllTrim( iif( ValType( cValue ) == "C", cValue, "" ) ) )
RETURN ( c == "ON" .OR. c == "YES" .OR. c == "Y" .OR. c == "1" .OR. c == "TRUE" .OR. c == "T" )

/* whole file as a string ("" when it does not exist or cannot be read) */
STATIC FUNCTION BpCfgReadFile( cFile )
   LOCAL h, n, c := ""
   IF ! hb_FNameExists( cFile )
      RETURN ""
   ENDIF
   h := FOpen( cFile, FO_READ )
   IF h < 0
      RETURN ""
   ENDIF
   n := FSeek( h, 0, FS_END )
   FSeek( h, 0, FS_SET )
   IF n > 0
      c := Space( n )
      n := FRead( h, @c, n )
      IF n >= 0
         c := Left( c, n )
      ENDIF
   ENDIF
   FClose( h )
RETURN c

/* value of a key inside a section, "" when it is not there. Line based: comments
 * start with ';' or '#', a section is "[NAME]" and a key is "name=value". */
STATIC FUNCTION BpCfgGet( cText, cSection, cKey, cDefault )
   LOCAL aLine, i, cLine, cSec := "", nEq
   DEFAULT cDefault TO ""
   aLine := hb_ATokens( cText, Chr( 10 ) )
   FOR i := 1 TO Len( aLine )
      cLine := AllTrim( StrTran( aLine[ i ], Chr( 13 ), "" ) )
      IF Empty( cLine ) .OR. Left( cLine, 1 ) == ";" .OR. Left( cLine, 1 ) == "#"
         LOOP
      ENDIF
      IF Left( cLine, 1 ) == "[" .AND. Right( cLine, 1 ) == "]"
         cSec := Upper( AllTrim( SubStr( cLine, 2, Len( cLine ) - 2 ) ) )
         LOOP
      ENDIF
      IF cSec == Upper( cSection )
         nEq := At( "=", cLine )
         IF nEq > 1 .AND. Upper( AllTrim( Left( cLine, nEq - 1 ) ) ) == Upper( cKey )
            RETURN AllTrim( SubStr( cLine, nEq + 1 ) )
         ENDIF
      ENDIF
   NEXT
RETURN cDefault

/* every "key=value" of a section, as { { cKey, cValue }, ... }. The caller
 * (the colour exceptions) has one entry per key instead of a known name, so this
 * is the list version of BpCfgGet(); same syntax, same comment rules. */
STATIC FUNCTION BpCfgSection( cText, cSection )
   LOCAL aOut := {}, aLine, i, cLine, cSec := "", nEq
   aLine := hb_ATokens( cText, Chr( 10 ) )
   FOR i := 1 TO Len( aLine )
      cLine := AllTrim( StrTran( aLine[ i ], Chr( 13 ), "" ) )
      IF Empty( cLine ) .OR. Left( cLine, 1 ) == ";" .OR. Left( cLine, 1 ) == "#"
         LOOP
      ENDIF
      IF Left( cLine, 1 ) == "[" .AND. Right( cLine, 1 ) == "]"
         cSec := Upper( AllTrim( SubStr( cLine, 2, Len( cLine ) - 2 ) ) )
         LOOP
      ENDIF
      IF cSec == Upper( cSection )
         nEq := At( "=", cLine )
         IF nEq > 1
            AAdd( aOut, { AllTrim( Left( cLine, nEq - 1 ) ), ;
                          AllTrim( SubStr( cLine, nEq + 1 ) ) } )
         ENDIF
      ENDIF
   NEXT
RETURN aOut

/* writes hwbro.ini next to the executable. Answers .T. when the file was written.
 * lQuiet = .T. writes nothing on screen (used by the automated probes). */
FUNCTION BpCfgSave( lQuiet )
   LOCAL cPath := BpCfgPath(), cText, h, lOk := .F., nWrite
   LOCAL aOv, i
   DEFAULT lQuiet TO .F.
   cText := ;
      "; hwBro configuration" + hb_eol() + ;
      "; Written by Save Configuration (F6 > GlobalSet, or Commander > Commands)." + hb_eol() + ;
      "" + hb_eol() + ;
      "[hwbro]" + hb_eol() + ;
      "version=" + BP_VERSION + hb_eol() + ;
      "" + hb_eol() + ;
      "[globalset]" + hb_eol() + ;
      "driver=" + CoreDriver() + hb_eol() + ;
      "openmode=" + CoreOpenMode() + hb_eol() + ;
      "dateformat=" + UiDateFormatName() + hb_eol() + ;
      "epoch=" + LTrim( Str( UiDateEpoch() ) ) + hb_eol() + ;
      "celledit=" + iif( CoreCellEdit(), "ON", "OFF" ) + hb_eol() + ;
      "hidedeleted=" + iif( CoreHideDel(), "ON", "OFF" ) + hb_eol() + ;
      "softseek=" + iif( CoreSoftSeek(), "ON", "OFF" ) + hb_eol() + ;
      "" + hb_eol() + ;
      "[appearance]" + hb_eol() + ;
      "theme=" + UiThemeName() + hb_eol() + ;
      "" + hb_eol() + ;
      "; colour exceptions (F6 > Theme Colors): they win over the theme above," + hb_eol() + ;
      "; one line per element and ONLY the elements that were overridden." + hb_eol() + ;
      "[colors]" + hb_eol()
   /* S137 of odd/tasks/theme-color-overrides.md: the exceptions, and nothing
    * else - UiOvList() already answers only the slots that carry one, so a file
    * with no exceptions leaves the section empty. */
   aOv := UiOvList()
   FOR i := 1 TO Len( aOv )
      cText += aOv[ i ][ 1 ] + "=" + aOv[ i ][ 2 ] + hb_eol()
   NEXT
   h := FCreate( cPath )
   IF h >= 0
      nWrite := FWrite( h, cText )
      FClose( h )
      lOk := ( nWrite == Len( cText ) )
   ENDIF
   IF ! lQuiet
      IF lOk
         UiInfo( "Configuration saved to" + hb_eol() + cPath, "Save Configuration" )
      ELSE
         UiErr( "Could not write the configuration file:" + hb_eol() + cPath, ;
                "Save Configuration" )
      ENDIF
   ENDIF
RETURN lOk

/* applies hwbro.ini to the session. Answers .T. when a file was found and read.
 * Every value is validated against the rule of its own screen, so a hand-edited
 * file with a typo cannot leave the program in a state no screen can produce:
 * an unknown driver, open mode or date picture is IGNORED and the default stays. */
FUNCTION BpCfgLoad()
   LOCAL cPath := BpCfgPath(), cText, cVal, nYear
   cText := BpCfgReadFile( cPath )
   IF Empty( cText )
      RETURN .F.
   ENDIF
   cVal := Upper( AllTrim( BpCfgGet( cText, CFG_SEC_GLOBAL, "driver", "" ) ) )
   IF cVal == "DBFCDX" .OR. cVal == "DBFNTX"
      CoreSetDriver( cVal )
   ENDIF
   cVal := Upper( AllTrim( BpCfgGet( cText, CFG_SEC_GLOBAL, "openmode", "" ) ) )
   IF cVal == "SHARED" .OR. cVal == "EXCLUSIVE"
      CoreSetOpenMode( cVal )
   ENDIF
   cVal := AllTrim( BpCfgGet( cText, CFG_SEC_GLOBAL, "dateformat", "" ) )
   IF ! Empty( cVal ) .AND. UiDateFormatIdx( cVal ) > 0
      UiDateFormatSet( cVal )
   ENDIF
   cVal := AllTrim( BpCfgGet( cText, CFG_SEC_GLOBAL, "epoch", "" ) )
   IF ! Empty( cVal )
      nYear := UiDateEpochParse( cVal )
      IF UiDateEpochOk( nYear )
         UiDateEpochSet( nYear )
      ENDIF
   ENDIF
   cVal := BpCfgGet( cText, CFG_SEC_GLOBAL, "celledit", "" )
   IF ! Empty( cVal ) ; CoreSetCellEdit( BpCfgBool( cVal ) ) ; ENDIF
   cVal := BpCfgGet( cText, CFG_SEC_GLOBAL, "hidedeleted", "" )
   IF ! Empty( cVal ) ; CoreSetHideDel( BpCfgBool( cVal ) ) ; ENDIF
   cVal := BpCfgGet( cText, CFG_SEC_GLOBAL, "softseek", "" )
   IF ! Empty( cVal ) ; CoreSetSoftSeek( BpCfgBool( cVal ) ) ; ENDIF
   /* the theme: UiThemeSet() answers .F. for a name it does not know and changes
    * NOTHING, which is exactly what a hand-edited file has to do */
   cVal := AllTrim( BpCfgGet( cText, CFG_SEC_LOOK, "theme", "" ) )
   IF ! Empty( cVal )
      UiThemeSet( cVal )
   ENDIF
   /* the colour exceptions, AFTER the theme: they win over whichever theme ends
    * up active, and UiOvLoad() drops the lines it cannot paint instead of
    * breaking the program (S137) */
   UiOvLoad( BpCfgSection( cText, CFG_SEC_COL ) )
RETURN .T.
