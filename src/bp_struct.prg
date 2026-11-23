/*
 * bp_struct.prg - Alter a database structure: data copy, file
 *                 swap (Alt-M of the structure editor) and INDEXES.
 * hwBro - clone of BroPlus 3.00 (Extrasensory Software) - Harbour + MSVC x64
 *
 * Altering the structure means REWRITING the file: a temporary file is created
 * with the new structure in the SAME directory as the target, the data is
 * copied field by field (by NAME, like APPEND FROM), the record count is
 * checked and the file is swapped through a .BAK backup.
 *
 * WATCH OUT - THE TRAP THAT HUNG THE PROGRAM (see AGENTS.md 5.15):
 *   dbCreate() does NOT open or select the file it creates. If afterwards
 *   APPEND FROM <alias> runs with the original database area still active, the
 *   database is copied OVER ITSELF: the loop reads to end of file and the
 *   file grows while copying, so it NEVER ends (it fills the disk). Measured:
 *   a 3 record / 100 bytes DBF went to 11.8 MB in 10 s.
 *   Here the temporary is ALWAYS opened in its own area and the copy is done
 *   record by record, which also allows reporting the progress.
 *
 * WATCH OUT (2) - INDEXES: they are only touched if the change hits a key.
 *   MEASURED: a .CDX whose keys do NOT change is still valid even if the
 *   record layout changes (the keys store the record number, not the
 *   field offset). So, if StructTagImpact() finds no affected key,
 *   StructApply() does NOT open or rewrite any index. If there are affected
 *   keys the user is asked Order by Order (bTagWarn returns an array of
 *   booleans) and StructRebuildIndexes() only rebuilds the approved Orders,
 *   reporting the progress with bIdxProg. A tag whose key uses a field
 *   removed/renamed cannot be kept (without it the database does not even open:
 *   "Variable does not exist") and it is dropped.
 *
 * WATCH OUT (3) - FieldPut() DOES NOT CONVERT TYPES:
 *   if the target field is N and the source value is C, it raises "Data type error";
 *   and a number that does not fit the target field raises "Data width error"
 *   (measured, see odd/tasks/structure-and-index-safety.md). That is why every
 *   value goes through StructConvert(), which casts it to the type/width of the target field.
 *
 * WATCH OUT (4) - RETURN CONVENTIONS (each one cost a while):
 *   dbCreate() and dbUseArea() return .T./.F.; FRename() and FErase() return
 *   **0** when they succeed and -1 when they fail (they are NOT logicals: `IF ! FRename(...)` would
 *   always fail). And `BREAK` inside BEGIN SEQUENCE passes its value to RECOVER,
 *   so here a TEXT is always thrown and RECOVER accepts a text or an object.
 *
 * This module draws NOTHING: the progress is reported with the bProg codeblock
 * and the index warning with the bTagWarn codeblock, so it can be tested without
 * a screen (see src/tests/).
 */
#include "dbinfo.ch"
#include "fileio.ch"
#include "bp_def.ch"

/* base name of the temporary (in the target directory, never in the working
 * one: FRename fails across volumes and it would dirty the current directory) */
#define STRUCT_TMP        "_BPSTRUCT"
#define STRUCT_TMPALIAS   "_BPTMP"
#define STRUCT_TMPEXT     ".DBF"
#define STRUCT_BAKEXT     ".BAK"
/* suffix used to move an old index aside while it is rebuilt */
#define STRUCT_IDXBAKEXT  ".IDXBAK"

/* CdxBagCheck(): layout of a .CDX bag (Harbour include/hbrddcdx.h) */
#define CDX_SIGNATURE     0x52434842      /* "RCHB": written by this Harbour */
#define CDX_HEADERLEN     1024            /* bag header block at offset 0 */
#define CDX_PAGEMIN       512             /* CDX_PAGELEN (power of two) */
#define CDX_PAGEHDR       12              /* attr, nKeys, leftPtr, rightPtr */
#define CDX_DUMMYNODE     4294967295      /* 0xFFFFFFFF: "no sibling" */
#define CDX_NODE_BRANCH   0
#define CDX_NODE_ROOT     1
#define CDX_NODE_LEAF     2
#define CDX_INDEXSIG_PAGE 0x21            /* pointers are page numbers */
/* bigger bags are not analysed: the warning is a help and cannot cost seconds
 * every time a database is opened */
#define CDX_CHECK_MAX     16777216        /* 16 MB */
#define CDX_CHECK_CHUNK   65536           /* read block (always whole pages) */

/* state of the running temporary: the error path checks it so that no
 * garbage is left if the copy blows up halfway (module STATIC variables, up there) */
STATIC s_nTempArea := 0
STATIC s_cTempBase := ""
STATIC s_cTempFile := ""

/* cache of the "language driver" byte (offset 28 of the header) read with the file
 * CLOSED: with the database open in EXCLUSIVE Windows does not allow a second
 * handle to read it and, since hwBro now opens in EXCLUSIVE by default, without
 * this cache every structure change lost it (dbCreate() writes it to 0).
 * It is filled from CoreOpen() before the USE and read from StructDbfLang()
 * when FOpen fails. The key is the BASE NAME ("ARTICULO.DBF"), which is what
 * arrives from CoreOpen() without a path and from StructApply() with a full path. */
STATIC s_aDbfLang := {}

/* result of the indexes of the LAST call to StructApply():
 *   { { cTag, cAction, cDetail }, ... }   cAction = "REBUILT" | "DROPPED"
 * The interface consumes it for the summary shown to the user. */
STATIC s_aTagResult := {}

/* result of the LAST call to StructRecreateIndexes() (F3 > Recreate Index File):
 *   { { cTag, "REBUILT"|"DROPPED", cDetail }, ... }
 * cDetail is the key expression, or the engine error description when the tag
 * could not be created. */
STATIC s_aRecreateRes := {}

/* -------------------------------------------------------------------------
 * StructValidate( aSt ) -> "" | <message>
 *
 * Checks that can keep the new structure from being CREATED, or that
 * leave the DBF ambiguous. No interface: used by Alt-M, Alt-E and the tests.
 *
 *   - at least one field, non empty name, only A-Z 0-9 _ and up to 10 characters
 *     (dbCreate() SILENTLY TRUNCATES to 10: "ABCDEFGHIJK" -> "ABCDEFGHIJ", and two
 *     different names can end up DUPLICATED in the new file)
 *   - unique names
 *   - width per type: C 1..255, N 1..20 (decimals < width), D 8, L 1, M 10
 * ------------------------------------------------------------------------- */
FUNCTION StructValidate( aSt )
   LOCAL i, j, cName, cType, nLen, nDec
   IF Empty( aSt )
      RETURN "No Database Fields specified"
   ENDIF
   FOR i := 1 TO Len( aSt )
      cName := Upper( AllTrim( StructAsText( aSt[ i ][ 1 ] ) ) )
      cType := Upper( AllTrim( StructAsText( aSt[ i ][ 2 ] ) ) )
      nLen  := Int( Val( StructAsText( aSt[ i ][ 3 ] ) ) )
      nDec  := Int( Val( StructAsText( aSt[ i ][ 4 ] ) ) )
      IF Empty( cName )
         RETURN "Blank Field Name"
      ENDIF
      IF Len( cName ) > 10
         RETURN "Illegal Field Name: " + cName + " (max 10 characters)"
      ENDIF
      IF ! StructNameOk( cName )
         RETURN "Illegal Field Name: " + cName
      ENDIF
      FOR j := 1 TO Len( aSt )
         IF j != i .AND. Upper( AllTrim( StructAsText( aSt[ j ][ 1 ] ) ) ) == cName
            RETURN "Duplicate Field Name: " + cName
         ENDIF
      NEXT
      DO CASE
      CASE cType == "C"
         IF nLen < 1 .OR. nLen > 255
            RETURN "Invalid Field Width: " + cName
         ENDIF
      CASE cType == "N"
         IF nLen < 1 .OR. nLen > 20
            RETURN "Invalid Field Width: " + cName
         ENDIF
         IF nDec < 0 .OR. nDec >= nLen
            RETURN "Invalid Decimal Width: " + cName
         ENDIF
      CASE cType == "D"
         IF nLen != 8 .OR. nDec != 0
            RETURN "Invalid Field Width: " + cName
         ENDIF
      CASE cType == "L"
         IF nLen != 1 .OR. nDec != 0
            RETURN "Invalid Field Width: " + cName
         ENDIF
      CASE cType == "M"
         IF nLen != 10 .OR. nDec != 0
            RETURN "Invalid Field Width: " + cName
         ENDIF
      OTHERWISE
         RETURN "Illegal Field Type: " + cName
      ENDCASE
   NEXT
RETURN ""

/* Normalizes the structure to what the engine is really going to store: Date=8,
 * Logical=1, Memo=10 and no decimals on the non numeric ones. Just like dBASE does
 * when the type changes, so the validation and the listing show the real thing. */
FUNCTION StructNormalize( aSt )
   LOCAL i, cType
   FOR i := 1 TO Len( aSt )
      cType := Upper( AllTrim( StructAsText( aSt[ i ][ 2 ] ) ) )
      DO CASE
      CASE cType == "D" ; aSt[ i ][ 3 ] := 8  ; aSt[ i ][ 4 ] := 0
      CASE cType == "L" ; aSt[ i ][ 3 ] := 1  ; aSt[ i ][ 4 ] := 0
      CASE cType == "M" ; aSt[ i ][ 3 ] := 10 ; aSt[ i ][ 4 ] := 0
      CASE cType == "C" ; aSt[ i ][ 4 ] := 0
      ENDCASE
   NEXT
RETURN aSt

/* -------------------------------------------------------------------------
 * StructInsertRow( aSt, nSel ) / StructDeleteRow( aSt, nSel )
 *
 * Add/remove a field in the structure the editor holds in memory.
 *
 * WATCH OUT (measured): `AIns()` does NOT grow the array in this Harbour. With
 * `a := {1,2,3}`; `AIns( a, 2 )` the array still has Len()==3 and ends up
 * `{1, NIL, 2}`: **the last element is lost**. The editor did exactly that,
 * so `Ins` (Insert Row) silently erased the LAST field of the database
 * (in ARTICULO it took ART_EAM away) and afterwards the index warning reported
 * that ART_EAM was disappearing, even though the user had not touched that field.
 * `ASize( aSt, Len( aSt ) + 1 )` has to be done BEFORE `AIns()`. See AGENTS.md 5.27.
 * ------------------------------------------------------------------------- */
FUNCTION StructInsertRow( aSt, nSel )
   IF Empty( aSt )
      AAdd( aSt, { "", "C", 10, 0 } )
      RETURN aSt
   ENDIF
   nSel := Max( 1, Min( nSel, Len( aSt ) ) )
   ASize( aSt, Len( aSt ) + 1 )      /* grow FIRST: AIns() does not grow */
   AIns( aSt, nSel )
   aSt[ nSel ] := { "", "C", 10, 0 }
RETURN aSt

FUNCTION StructDeleteRow( aSt, nSel )
   IF Empty( aSt )
      RETURN aSt
   ENDIF
   nSel := Max( 1, Min( nSel, Len( aSt ) ) )
   ADel( aSt, nSel )
   ASize( aSt, Len( aSt ) - 1 )
RETURN aSt

/* field name charset of the original: A-Z 0-9 _ and up to 10 characters */
STATIC FUNCTION StructNameOk( cName )
   LOCAL i, c
   IF Len( cName ) > 10
      RETURN .F.
   ENDIF
   FOR i := 1 TO Len( cName )
      c := Upper( SubStr( cName, i, 1 ) )
      IF ! ( c $ "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_" )
         RETURN .F.
      ENDIF
   NEXT
RETURN .T.

/* -------------------------------------------------------------------------
 * StructTags( nArea ) -> { { cBagFull, cTag, cExpr, cFor, lUnique, lDesc }, ... }
 *
 * Definitions of the tags of the indexes OPEN in the area (current order of
 * the RDD). They have to be captured BEFORE closing the database, because the close
 * takes the definitions away. DBFCDX opens only the production .CDX when the DBF
 * is opened, so the real tags of the database show up here.
 * ------------------------------------------------------------------------- */
FUNCTION StructTags( nArea )
   LOCAL a := {}, i, n, cBag, cTag
   LOCAL nOld := Select()
   IF ! Empty( nArea )
      SELECT ( nArea )
   ENDIF
   IF ! Used()
      RETURN a
   ENDIF
   n := dbOrderInfo( DBOI_ORDERCOUNT )
   FOR i := 1 TO n
      cBag := StructInfoStr( DBOI_FULLPATH, i )
      IF Empty( cBag )
         cBag := StructInfoStr( DBOI_BAGNAME, i )
      ENDIF
      cTag := StructInfoStr( DBOI_NAME, i )
      IF ! Empty( cBag ) .AND. ! Empty( cTag )
         AAdd( a, { cBag, ;
                    cTag, ;
                    StructInfoStr( DBOI_EXPRESSION, i ), ;
                    StructInfoStr( DBOI_CONDITION, i ), ;
                    ( dbOrderInfo( DBOI_UNIQUE, , i ) == .T. ), ;
                    ( dbOrderInfo( DBOI_ISDESC, , i ) == .T. ) } )
      ENDIF
   NEXT
   SELECT ( nOld )
RETURN a

/* dbOrderInfo() can return NIL: it is normalized to text */
STATIC FUNCTION StructInfoStr( nWhat, nIdx )
   LOCAL x := dbOrderInfo( nWhat, , nIdx )
   IF ValType( x ) == "C"
      RETURN x
   ENDIF
RETURN ""

/* -------------------------------------------------------------------------
 * StructTagImpact( aOld, aNew, aTags ) -> aImpact
 *
 *   aImpact[ i ] = { cTag, cExpr, cBag, lCanRebuild, aReasons }
 *
 * For each tag the words of its key expression are checked: the ones that are
 * fields of the OLD structure are compared with the NEW one.
 *   - the field no longer exists (removed or renamed) -> the tag CANNOT be
 *     kept: the database does not even open with that index (measured: "Variable
 *     does not exist"), so it is DROPPED (lCanRebuild = .F.)
 *   - the field changes type or width/decimals -> the tag CAN be
 *     rebuilt with the new key (lCanRebuild = .T.); the user decides
 *     whether to reindex it or leave the index as it is
 * Tags that do not touch any altered field do NOT appear in aImpact: no warning
 * is given for them and their index is left INTACT (measured: a .CDX whose keys do not
 * change is still valid even if the record layout changes).
 * ------------------------------------------------------------------------- */
FUNCTION StructTagImpact( aOld, aNew, aTags )
   LOCAL aImpact := {}, aReasons, aTokens, aOldF, aNewF
   LOCAL i, j, cField, lRebuild, lHit
   FOR i := 1 TO Len( aTags )
      aReasons := {}
      aTokens := StructTokens( aTags[ i ][ 3 ] )
      lRebuild := .T.
      lHit := .F.
      FOR j := 1 TO Len( aTokens )
         cField := Upper( aTokens[ j ] )
         aOldF := StructFieldByName( aOld, cField )
         IF Empty( aOldF )
            LOOP                       /* not a field of this database */
         ENDIF
         aNewF := StructFieldByName( aNew, cField )
         IF Empty( aNewF )
            AAdd( aReasons, "field " + cField + " is removed or renamed" )
            lRebuild := .F.
            lHit := .T.
         ELSEIF ! ( Upper( StructAsText( aNewF[ 2 ] ) ) == Upper( StructAsText( aOldF[ 2 ] ) ) )
            AAdd( aReasons, "field " + cField + " changes type " + ;
                  Upper( StructAsText( aOldF[ 2 ] ) ) + " -> " + Upper( StructAsText( aNewF[ 2 ] ) ) )
            lHit := .T.
         ELSEIF aNewF[ 3 ] != aOldF[ 3 ] .OR. aNewF[ 4 ] != aOldF[ 4 ]
            AAdd( aReasons, "field " + cField + " changes width " + ;
                  StructWidthText( aOldF ) + " -> " + StructWidthText( aNewF ) )
            lHit := .T.
         ENDIF
      NEXT
      IF lHit
         AAdd( aImpact, { aTags[ i ][ 2 ], aTags[ i ][ 3 ], aTags[ i ][ 1 ], ;
                          lRebuild, aReasons } )
      ENDIF
   NEXT
RETURN aImpact

STATIC FUNCTION StructWidthText( aF )
   LOCAL c := LTrim( Str( aF[ 3 ] ) )
   IF aF[ 4 ] > 0
      c += "," + LTrim( Str( aF[ 4 ] ) )
   ENDIF
RETURN c

/* field of the structure by NAME (exact comparison in upper case); {} if
 * it does not exist */
STATIC FUNCTION StructFieldByName( aSt, cName )
   LOCAL i, f := {}
   FOR i := 1 TO Len( aSt )
      IF Upper( AllTrim( StructAsText( aSt[ i ][ 1 ] ) ) ) == cName
         f := aSt[ i ]
         EXIT
      ENDIF
   NEXT
RETURN f

/* words of an expression, ignoring literals between quotes (so as not to
 * confuse "NOMBRE" with the field NOMBRE) */
STATIC FUNCTION StructTokens( cText )
   LOCAL a := {}, cW := "", i, c, cQ := ""
   FOR i := 1 TO Len( cText )
      c := SubStr( cText, i, 1 )
      IF ! Empty( cQ )
         IF c == cQ
            cQ := ""
         ENDIF
      ELSEIF c == '"' .OR. c == "'"
         cQ := c
         IF ! Empty( cW )
            AAdd( a, cW )
            cW := ""
         ENDIF
      ELSEIF c $ "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_"
         cW += Upper( c )
      ELSE
         IF ! Empty( cW )
            AAdd( a, cW )
            cW := ""
         ENDIF
      ENDIF
   NEXT
   IF ! Empty( cW )
      AAdd( a, cW )
   ENDIF
RETURN a

/* -------------------------------------------------------------------------
 * StructConvert( xVal, aField ) -> value with the TYPE and WIDTH of the target field
 *
 * FieldPut() does not convert types and besides blows up with "Data width error" if the
 * number does not fit the field. This function does both things, so the
 * copy never raises an error because of a type or width change.
 * ------------------------------------------------------------------------- */
FUNCTION StructConvert( xVal, aField )
   LOCAL cType := Upper( AllTrim( StructAsText( aField[ 2 ] ) ) )
   LOCAL nLen  := Int( Val( StructAsText( aField[ 3 ] ) ) )
   LOCAL nDec  := Int( Val( StructAsText( aField[ 4 ] ) ) )
   DO CASE
   CASE cType == "C"
      RETURN Left( StructValText( xVal ), Max( nLen, 0 ) )
   CASE cType == "N"
      RETURN StructNumVal( xVal, nLen, nDec )
   CASE cType == "D"
      RETURN StructDateVal( xVal )
   CASE cType == "L"
      RETURN StructLogicVal( xVal )
   CASE cType == "M"
      RETURN StructValText( xVal )
   ENDCASE
RETURN NIL

/* text of a value of any field type */
STATIC FUNCTION StructValText( xVal )
   DO CASE
   CASE ValType( xVal ) == "C" ; RETURN xVal
   CASE ValType( xVal ) == "N" ; RETURN LTrim( Str( xVal ) )
   CASE ValType( xVal ) == "D" ; RETURN iif( Empty( xVal ), "", DToC( xVal ) )
   CASE ValType( xVal ) == "L" ; RETURN iif( xVal, "T", "F" )
   CASE ValType( xVal ) == "M" ; RETURN xVal
   ENDCASE
RETURN ""

/* numeric value that DOES fit in a field of nLen digits and nDec decimals:
 * clipped to the representable range (the sign takes room too) */
STATIC FUNCTION StructNumVal( xVal, nLen, nDec )
   LOCAL n, c, nInt, nMax, nMin
   DO CASE
   CASE ValType( xVal ) == "N" ; n := xVal
   CASE ValType( xVal ) == "C" ; n := Val( AllTrim( xVal ) )
   CASE ValType( xVal ) == "D" ; n := iif( Empty( xVal ), 0, Val( DToS( xVal ) ) )
   CASE ValType( xVal ) == "L" ; n := iif( xVal, 1, 0 )
   CASE ValType( xVal ) == "M" ; n := Val( AllTrim( xVal ) )
   OTHERWISE ; n := 0
   ENDCASE
   nInt := nLen - nDec - iif( n < 0, 1, 0 )
   IF nInt < 0
      nInt := 0
   ENDIF
   nMax := 10 ^ nInt - 10 ^ ( -nDec )
   IF nMax < 0
      nMax := 0
   ENDIF
   nMin := iif( n < 0, -nMax, 0 )
   n := Max( nMin, Min( n, nMax ) )
   /* Str() is the same rounding to nDec decimals that the RDD applies */
   c := Str( n, nLen, nDec )
   IF "*" $ c
      c := Str( 0, nLen, nDec )
   ENDIF
RETURN Val( c )

/* CToD() does NOT accept "YYYYMMDD" (measured: it returns an empty date); SToD() does.
 * Texts with a separator (/ or -) or in MM/DD/YYYY format go through CToD(). */
STATIC FUNCTION StructDateVal( xVal )
   LOCAL c
   DO CASE
   CASE ValType( xVal ) == "D"
      RETURN xVal
   CASE ValType( xVal ) == "C"
      c := AllTrim( xVal )
      IF Empty( c )
         RETURN CToD( "" )
      ENDIF
      IF Len( c ) == 8 .AND. ! ( "/" $ c ) .AND. ! ( "-" $ c ) .AND. ! ( "." $ c )
         RETURN SToD( c )
      ENDIF
      RETURN CToD( c )
   CASE ValType( xVal ) == "N"
      IF xVal <= 0
         RETURN CToD( "" )
      ENDIF
      RETURN SToD( PadL( LTrim( Str( Int( xVal ) ) ), 8, "0" ) )
   ENDCASE
RETURN CToD( "" )

STATIC FUNCTION StructLogicVal( xVal )
   LOCAL c
   DO CASE
   CASE ValType( xVal ) == "L"
      RETURN xVal
   CASE ValType( xVal ) == "C"
      c := Upper( AllTrim( xVal ) )
      RETURN ( c == "T" .OR. c == "Y" .OR. c == "1" .OR. c == ".T." .OR. c == ".Y." )
   CASE ValType( xVal ) == "N"
      RETURN xVal != 0
   CASE ValType( xVal ) == "D"
      RETURN ! Empty( xVal )
   ENDCASE
RETURN .F.

/* -------------------------------------------------------------------------
 * StructApply( aSt, cFull, bProg, bTagWarn ) -> "" | BP_STRUCT_CANCEL | error
 *
 * Replaces the file cFull with another one carrying the aSt structure, copying the data
 * by field name. bProg( nDone, nTotal ) is called periodically and must
 * return .T. to CANCEL. bTagWarn( aImpact ) is called ONCE, only if the
 * change affects some index tag, and must return .T. to GO ON
 * (the warning is only that: a warning; the user decides).
 *
 * Returns:
 *   ""                 -> done (the original database is left CLOSED: the caller
 *                         has to reopen it)
 *   BP_STRUCT_CANCEL   -> the user cancelled (through the progress or the index
 *                         warning); NOTHING has been touched and the original database is
 *                         still open and in its place
 *   another text       -> error; the original database is left closed but intact
 *                         (or in its .BAK backup, which the message says)
 * ------------------------------------------------------------------------- */
FUNCTION StructApply( aSt, cFull, bProg, bTagWarn, bIdxProg )
   LOCAL cMsg := "", aOld := {}, aTags := {}, aImpact := {}, aDec := {}
   LOCAL i, xDec

   s_aTagResult := {}
   StructResetTemp()

   IF Empty( aSt )
      RETURN "No Database Fields specified"
   ENDIF
   IF Empty( cFull )
      RETURN "No database file specified"
   ENDIF

   StructNormalize( aSt )
   cMsg := StructValidate( aSt )
   IF ! Empty( cMsg )
      RETURN cMsg
   ENDIF

   /* index definitions BEFORE touching anything (afterwards the close takes
    * them away) and a check ONLY if the change touches the key of some tag */
   IF Used()
      aOld   := AClone( DbStruct() )
      aTags  := StructTags( Select() )
      aImpact := StructTagImpact( aOld, aSt, aTags )
      IF ! Empty( aImpact )
         /* by default everything that can be rebuilt is rebuilt; the caller can
          * decide tag by tag (bTagWarn returns an array of booleans) or
          * cancel the whole operation by returning .F. */
         aDec := Array( Len( aImpact ) )
         AFill( aDec, .T. )
         IF ! Empty( bTagWarn )
            xDec := Eval( bTagWarn, aImpact )
            IF ValType( xDec ) == "L"
               IF ! xDec
                  RETURN BP_STRUCT_CANCEL
               ENDIF
            ELSEIF ValType( xDec ) == "A"
               FOR i := 1 TO Min( Len( xDec ), Len( aDec ) )
                  aDec[ i ] := ( xDec[ i ] == .T. )
               NEXT
            ENDIF
         ENDIF
      ENDIF
   ENDIF

   BEGIN SEQUENCE WITH {| e | Break( e ) }
      cMsg := StructDoApply( aSt, cFull, bProg, aTags, aImpact, aDec, bIdxProg )
   RECOVER USING oErr
      StructDropTemp()
      cMsg := StructErrText( oErr )
   END SEQUENCE
   /* idempotent: no path may leave the temporary behind */
   StructDropTemp()
   BpLogStruct( "StructApply(" + cFull + ") -> [" + cMsg + "]" )
RETURN cMsg

/* result of the indexes of the last apply (the interface shows it) */
FUNCTION StructTagResult()
RETURN s_aTagResult

/* result of the last StructRecreateIndexes() (the interface shows it) */
FUNCTION StructRecreateResult()
RETURN s_aRecreateRes

STATIC PROCEDURE StructResetTemp()
   s_nTempArea := 0
   s_cTempBase := ""
   s_cTempFile := ""
RETURN

/* the body, split out so that StructApply() only normalizes the errors and can
 * ALWAYS report (cancellation included) with a text */
STATIC FUNCTION StructDoApply( aSt, cFull, bProg, aTags, aImpact, aDec, bIdxProg )
   LOCAL cPath, cBase, cExt, cTmpBase, cTmpFile, cBak, cBakBase
   LOCAL i, aMemo := { ".FPT", ".DBT" }
   LOCAL cTmpMemo, cOldMemo, cBakMemo, cMsg := "", cLang := ""
   LOCAL lHadSrc, nSrcArea, nTmpArea := 0, aMap, nTotal := 0, nCopied := 0

   hb_FNameSplit( cFull, @cPath, @cBase, @cExt )
   /* EVERYTHING that is generated goes in the SAME directory as the original: the
    * temporary (_BPSTRUCT.DBF + its memo) and the backup (.BAK). NEVER in the
    * working directory, among other things because FRename fails across
    * volumes and because the .BAK has to sit next to the file it is a
    * backup of. For that the caller has to pass the REAL PATH of the database
    * (in the program it is CoreFileName(), not DBF()). */
   cTmpBase := cPath + STRUCT_TMP
   cTmpFile := cTmpBase + STRUCT_TMPEXT
   cBak     := cPath + cBase + STRUCT_BAKEXT
   cBakBase := cPath + cBase + STRUCT_BAKEXT

   /* from here on the error path knows what to delete */
   s_cTempBase := cTmpBase
   s_cTempFile := cTmpFile

   lHadSrc  := Used()
   nSrcArea := Select()
   BpLogStruct( "StructApply: " + cFull + " [temp=" + cTmpFile + " bak=" + cBak + ;
                "] registros=" + LTrim( Str( iif( lHadSrc, RecCount(), 0 ) ) ) )

   /* leftovers of a previous attempt */
   IF hb_FNameExists( cTmpFile )
      FErase( cTmpFile )
   ENDIF

   /* the "language driver" byte of the original DBF (e.g. 1 = CP437): dbCreate()
    * sets it to 0 and it has to be preserved, since it is part of the user file.
    * WATCH OUT: it is read HERE, before touching areas, because closing the database the RDD
    * rewrites the header with its own value. LIMITATION: with the database open
    * in EXCLUSIVE a second read handle cannot be opened and the byte
    * is left as the RDD sets it. That is why CoreOpen() REMEMBERS it before the USE
    * with StructRememberDbfLang(), which is the only thing that works with the database
    * open in EXCLUSIVE (the default mode of hwBro). Measured: without cache the
    * byte goes from 1 to 0 after a structure change; with cache it is preserved. */
   cLang := StructDbfLang( cFull )

   IF ! dbCreate( cTmpFile, aSt )
      Break( "Unable to create " + cTmpFile )
   ENDIF
   /* dbCreate() does NOT open the file: it has to be opened in its OWN area and in
    * EXCLUSIVE (without record locks the copy is far faster) */
   IF ! dbUseArea( .T., NIL, cTmpFile, STRUCT_TMPALIAS, .F. )
      Break( "Unable to open " + cTmpFile )
   ENDIF
   nTmpArea := Select()
   s_nTempArea := nTmpArea
   IF lHadSrc
      aMap := StructFieldMap( nSrcArea, aSt )
      nCopied := StructCopyRecords( nSrcArea, nTmpArea, aMap, aSt, @nTotal, bProg )
      IF nCopied < 0
         StructDropTemp()
         SELECT ( nSrcArea )          /* cancelling changes NOTHING: same area */
         RETURN BP_STRUCT_CANCEL
      ENDIF
      IF nCopied != nTotal
         StructDropTemp()
         SELECT ( nSrcArea )
         RETURN "Record count mismatch: " + LTrim( Str( nCopied ) ) + ;
                " of " + LTrim( Str( nTotal ) ) + " records copied"
      ENDIF
   ENDIF
   /* close the temporary and the original database: Windows does not allow renaming an
    * open file (and the .CDX has to be released first) */
   SELECT ( nTmpArea )
   dbCloseArea()
   nTmpArea := 0
   s_nTempArea := 0
   IF lHadSrc
      SELECT ( nSrcArea )
      dbCloseArea()
   ENDIF
   /* backup of the original: if the swap fails, the data is not lost */
   IF hb_FNameExists( cFull )
      IF hb_FNameExists( cBak )
         FErase( cBak )
      ENDIF
      IF FRename( cFull, cBak ) != 0
         StructDropTemp()
         RETURN "Unable to rename " + cFull + " to " + cBak
      ENDIF
   ENDIF
   IF FRename( cTmpFile, cFull ) != 0
      /* roll back: the original is left as it was */
      IF hb_FNameExists( cBak )
         FRename( cBak, cFull )
      ENDIF
      StructDropTemp()
      RETURN "Unable to rename " + cTmpFile + " to " + cFull
   ENDIF
   BpLogStruct( "StructApply: fichero cambiado (" + LTrim( Str( nTotal ) ) + " registros)" )
   StructSetDbfLang( cFull, cLang )
   /* memo files (.FPT/.DBT): the temporary brings its own, the original one is
    * kept next to the .BAK backup and discarded at the end */
   FOR i := 1 TO Len( aMemo )
      cTmpMemo := cTmpBase + aMemo[ i ]
      cOldMemo := cPath + cBase + aMemo[ i ]
      cBakMemo := cBakBase + aMemo[ i ]
      IF hb_FNameExists( cOldMemo )
         IF hb_FNameExists( cBakMemo )
            FErase( cBakMemo )
         ENDIF
         FRename( cOldMemo, cBakMemo )
      ENDIF
      IF hb_FNameExists( cTmpMemo )
         FRename( cTmpMemo, cOldMemo )
      ENDIF
   NEXT
   /* INDEXES: the file has just changed, so the old keys are useless.
    * They are rebuilt here, with the .BAK still in its place in case something goes wrong. */
   IF ! Empty( aTags )
      s_aTagResult := StructRebuildIndexes( aTags, aImpact, aDec, cFull, bIdxProg )
   ENDIF
   /* success: the backup is discarded (like the original, no copies are left) */
   IF hb_FNameExists( cBak )
      FErase( cBak )
   ENDIF
   FOR i := 1 TO Len( aMemo )
      cBakMemo := cBakBase + aMemo[ i ]
      IF hb_FNameExists( cBakMemo )
         FErase( cBakMemo )
      ENDIF
   NEXT
RETURN cMsg

/* -------------------------------------------------------------------------
 * StructRebuildIndexes( aTags, aImpact, aDec, cFull, bIdxProg )
 *                    -> { { cTag, cAction, cDetail }, ... }
 *
 * Rebuilds ONLY what is needed, and only of the indexes whose key is involved:
 *
 *   - If no tag of the database is affected, NO index file is touched.
 *     Measured: a .CDX whose keys do not change IS STILL VALID
 *     even if the record layout changes (the keys store the record
 *     number), so reindexing for the sake of it only wastes time.
 *   - aDec[ i ] = .T.  -> the user asked to REINDEX that Order: it is recreated with
 *     the new key.  aDec[ i ] = .F. -> it is left as it is (if its field only
 *     changed width, the old index is still consistent; if the index
 *     file has to be rewritten anyway because of another Order, it is rebuilt and
 *     reported: there is no way to keep the old keys in a .CDX that is
 *     rewritten).
 *   - aImpact[ i ][ 4 ] = .F. -> the key field NO LONGER EXISTS: that tag cannot
 *     be kept (measured: the database does not open, "Variable does not exist"),
 *     so it is DROPPED even if the user said nothing.
 *
 * Process per affected index file:
 *   1. move the old index aside to <index>.IDXBAK
 *   2. open the NEW database in its own EXCLUSIVE area
 *   3. recreate tag by tag with OrdCreate() (same key, same FOR, same
 *      UNIQUE/DESC) using the definition captured before the change; report
 *      the progress with bIdxProg( nDone, nTotal ) so the interface shows the
 *      progress bar
 *   4. delete the .IDXBAK files (the old index is useless: its keys were computed
 *      with the old values)
 * It never aborts the operation: worse than a dropped tag would be leaving a corrupt
 * index. The result is reported to the user.
 * ------------------------------------------------------------------------- */
STATIC FUNCTION StructRebuildIndexes( aTags, aImpact, aDec, cFull, bIdxProg )
   LOCAL aWork := {}, aBags := {}, aRes := {}
   LOCAL i, cBag, cBak, nArea, oErr, lOk, cAct, cWhy
   LOCAL nTotal := 0, nDone := 0

   /* 0. action per affected tag: DROP (impossible), REBUILD (the user said
    *    yes) or KEEP (the user said no) */
   FOR i := 1 TO Len( aImpact )
      IF ! aImpact[ i ][ 4 ]
         AAdd( aWork, { Upper( aImpact[ i ][ 1 ] ), "DROP", ;
                        StructReasonsText( aImpact[ i ][ 5 ] ) } )
      ELSEIF i <= Len( aDec ) .AND. aDec[ i ]
         AAdd( aWork, { Upper( aImpact[ i ][ 1 ] ), "REBUILD", "" } )
      ELSE
         AAdd( aWork, { Upper( aImpact[ i ][ 1 ] ), "KEEP", "" } )
      ENDIF
   NEXT

   /* if there is NOTHING to rebuild or drop, the indexes stay intact */
   IF StructCountAction( aWork, "DROP" ) == 0 .AND. StructCountAction( aWork, "REBUILD" ) == 0
      RETURN aRes
   ENDIF

   /* 1. index files that have to be rewritten: those of the tags with action
    *    DROP or REBUILD (KEEP alone moves nothing) */
   FOR i := 1 TO Len( aTags )
      cAct := StructActionFor( aWork, aTags[ i ][ 2 ] )
      IF ( cAct == "DROP" .OR. cAct == "REBUILD" ) .AND. ! Empty( aTags[ i ][ 1 ] ) .AND. ;
         ! StructInList( aBags, Upper( aTags[ i ][ 1 ] ) )
         AAdd( aBags, Upper( aTags[ i ][ 1 ] ) )
      ENDIF
   NEXT

   /* how many tags are going to be created (for the progress bar) */
   FOR i := 1 TO Len( aTags )
      IF StructInList( aBags, Upper( aTags[ i ][ 1 ] ) ) .AND. ;
         ! ( StructActionFor( aWork, aTags[ i ][ 2 ] ) == "DROP" )
         nTotal++
      ENDIF
   NEXT

   /* 2. move the old indexes aside and delete the leftovers of a previous attempt */
   FOR i := 1 TO Len( aBags )
      IF hb_FNameExists( aBags[ i ] )
         cBak := aBags[ i ] + STRUCT_IDXBAKEXT
         IF hb_FNameExists( cBak )
            FErase( cBak )
         ENDIF
         FRename( aBags[ i ], cBak )
      ENDIF
   NEXT

   /* 3. the new database, in its own area (without the old index next to it) */
   SELECT 0
   IF ! dbUseArea( .T., NIL, cFull, NIL, .F. )
      /* it could not be opened: give the old indexes back as they are (nothing is
       * destroyed) and warn */
      FOR i := 1 TO Len( aBags )
         IF hb_FNameExists( aBags[ i ] + STRUCT_IDXBAKEXT )
            FRename( aBags[ i ] + STRUCT_IDXBAKEXT, aBags[ i ] )
         ENDIF
      NEXT
      AAdd( aRes, { "", "DROPPED", "the structure file could not be reopened" } )
      RETURN aRes
   ENDIF
   nArea := Select()

   /* 4. recreate the tags of the files being rewritten */
   FOR i := 1 TO Len( aTags )
      IF ! StructInList( aBags, Upper( aTags[ i ][ 1 ] ) )
         LOOP
      ENDIF
      cAct := StructActionFor( aWork, aTags[ i ][ 2 ] )
      cWhy := StructWorkDetail( aWork, aTags[ i ][ 2 ] )
      IF cAct == "DROP"
         AAdd( aRes, { aTags[ i ][ 2 ], "DROPPED", cWhy } )
         LOOP
      ENDIF
      lOk := .F.
      oErr := NIL
      BEGIN SEQUENCE WITH {| e | Break( e ) }
         SELECT ( nArea )
         /* FOR condition and UNIQUE/DESCEND attributes of the original tag */
         IF Empty( aTags[ i ][ 4 ] )
            OrdCondSet( NIL, NIL, NIL, NIL, NIL, NIL, NIL, ;
                        aTags[ i ][ 6 ], aTags[ i ][ 5 ] )
         ELSE
            OrdCondSet( aTags[ i ][ 4 ], &( "{|| " + aTags[ i ][ 4 ] + " }" ), ;
                        NIL, NIL, NIL, NIL, NIL, ;
                        aTags[ i ][ 6 ], aTags[ i ][ 5 ] )
         ENDIF
         OrdCreate( aTags[ i ][ 1 ], aTags[ i ][ 2 ], aTags[ i ][ 3 ], ;
                    &( "{|| " + aTags[ i ][ 3 ] + " }" ), aTags[ i ][ 5 ] )
         lOk := .T.
      RECOVER USING oErr
         lOk := .F.
      END SEQUENCE
      nDone++
      IF ! Empty( bIdxProg )
         Eval( bIdxProg, nDone, nTotal )
      ENDIF
      IF lOk
         AAdd( aRes, { aTags[ i ][ 2 ], "REBUILT", ;
                       iif( cAct == "KEEP", "rebuilt with the index file (its key was not altered)", ;
                            aTags[ i ][ 3 ] ) } )
      ELSE
         AAdd( aRes, { aTags[ i ][ 2 ], "DROPPED", ;
                       "the key expression is no longer valid" + ;
                       iif( ValType( oErr ) == "O", " (" + oErr:Description + ")", "" ) } )
      ENDIF
   NEXT

   /* close the work area we opened to rebuild the tags: if it stays open in
    * EXCLUSIVE the caller cannot reopen the file ("Open
    * error") and the database looks broken */
   StructCloseArea( nArea )

   /* 5. the old index is useless now */
   FOR i := 1 TO Len( aBags )
      cBak := aBags[ i ] + STRUCT_IDXBAKEXT
      IF hb_FNameExists( cBak )
         FErase( cBak )
      ENDIF
   NEXT
RETURN aRes

/* -------------------------------------------------------------------------
 * StructRecreateIndexes( cFull, aDef, bProg ) -> lOk
 *
 * F3 > "Recreate Index File": the index FILE is destroyed and built again from
 * scratch, so a .CDX with several orders or an .NTX come out complete and with
 * the same order numbering. This is NOT a reindex in place (that is Alt-R):
 * here the old file is moved aside and a brand new one is created, which is
 * the only way to make an order that is not in the definition disappear.
 *
 *   cFull = FULL PATH of the database, and its work area ALREADY CLOSED by the
 *           caller: Windows does not allow touching an index file the RDD
 *           still holds.
 *   aDef  = { { cTag, cExpression, cCondition, lUnique, lDesc, cBagFullPath }, ... }
 *           (the layout of BpTagDefs()). The bag path of each tag decides which
 *           file it goes to, so a multi order .CDX and .NTX bags go through the
 *           same path.
 *   bProg = optional {| nStep, nTotal, cText | ... }; it is called BEFORE each
 *           step and a SECOND time with the SAME nStep when a tag has just been
 *           created, which is where the number of keys is reported. OrdCreate()
 *           reports no per record progress and OrdKeyAdd() does not exist in
 *           this build (AGENTS.md 5.32), so the detail goes in the text line.
 *
 * Returns .T. only when EVERY tag was created and the old index files were
 * deleted. On any failure the old index files come back byte for byte
 * (<index>.IDXBAK -> <index>) and the partial new one is deleted. No work area
 * is left open. A definition whose bag path is empty or is the database file
 * itself is refused BEFORE anything is touched (defence in depth: the caller
 * checks it too).
 * ------------------------------------------------------------------------- */
FUNCTION StructRecreateIndexes( cFull, aDef, bProg )
   LOCAL aBags := {}, aHad := {}, aMoved := {}
   LOCAL i, n, cBag, cBak, nArea := 0, oErr, lOk := .T., lOne
   LOCAL nStep := 0, nTotal := 0, nKeys

   s_aRecreateRes := {}
   IF Empty( aDef ) .OR. Empty( cFull )
      RETURN .F.
   ENDIF

   /* DEFENCE IN DEPTH, before ANY FErase()/FRename(): this engine DELETES and
    * RENAMES the files the definition names, so a definition whose bag path is
    * empty or points at the database itself is refused HERE, even when the
    * caller already checked it. Deleting the wrong file is the worst possible
    * bug of this process (measured: with a hand built definition the engine
    * renamed the .DBF aside and only the rollback saved it). Nothing is
    * touched and the result stays empty. */
   FOR i := 1 TO Len( aDef )
      IF ValType( aDef[ i ] ) != "A" .OR. Len( aDef[ i ] ) < 6 .OR. ;
         ValType( aDef[ i ][ 6 ] ) != "C" .OR. Empty( aDef[ i ][ 6 ] ) .OR. ;
         Upper( aDef[ i ][ 6 ] ) == Upper( cFull )
         RETURN .F.
      ENDIF
   NEXT

   /* 1. the DISTINCT index files, in the order they are first seen. The paths
    *    are upper cased so that StructInList() compares them case-insensitively
    *    (same thing StructRebuildIndexes() does) */
   FOR i := 1 TO Len( aDef )
      IF ValType( aDef[ i ] ) == "A" .AND. Len( aDef[ i ] ) >= 6 .AND. ;
         ValType( aDef[ i ][ 6 ] ) == "C" .AND. ! Empty( aDef[ i ][ 6 ] ) .AND. ;
         ! StructInList( aBags, Upper( aDef[ i ][ 6 ] ) )
         AAdd( aBags, Upper( aDef[ i ][ 6 ] ) )
      ENDIF
   NEXT
   IF Empty( aBags )
      RETURN .F.
   ENDIF

   /* steps of the progress bar: one per index file, one to open the database,
    * one per tag and one to finish */
   nTotal := Len( aBags ) + 1 + Len( aDef ) + 1

   FOR n := 1 TO Len( aBags )
      AAdd( aHad, hb_FNameExists( aBags[ n ] ) )
      AAdd( aMoved, .F. )
   NEXT

   /* 2. move the old index files aside: from here on the database has no
    *    index and only the .IDXBAK keeps the old one */
   FOR n := 1 TO Len( aBags )
      cBag := aBags[ n ]
      cBak := cBag + STRUCT_IDXBAKEXT
      nStep++
      IF ! Empty( bProg )
         Eval( bProg, nStep, nTotal, "Deleting " + hb_FNameNameExt( cBag ) )
      ENDIF
      IF hb_FNameExists( cBak )
         FErase( cBak )           /* leftover of a previous attempt */
      ENDIF
      IF aHad[ n ]
         IF FRename( cBag, cBak ) == 0
            aMoved[ n ] := .T.
         ELSE
            /* the file is still in its place: nothing else is touched and the
             * restore phase gives back what was moved so far */
            lOk := .F.
            EXIT
         ENDIF
      ENDIF
   NEXT

   /* 3. the database on its own and WITHOUT index: only like this can a brand
    *    new index file be built next to it */
   IF lOk
      nStep++
      IF ! Empty( bProg )
         Eval( bProg, nStep, nTotal, "Opening " + hb_FNameNameExt( cFull ) + ;
                                   "  (no index)" )
      ENDIF
      BEGIN SEQUENCE WITH {| e | Break( e ) }
         SELECT 0
         IF dbUseArea( .T., NIL, cFull, NIL, .F. )
            nArea := Select()
         ELSE
            lOk := .F.
         ENDIF
      RECOVER USING oErr
         lOk := .F.
      END SEQUENCE
   ENDIF

   /* 4. every order again from scratch, tag by tag */
   IF lOk
      FOR i := 1 TO Len( aDef )
         nStep++
         IF ! Empty( bProg )
            Eval( bProg, nStep, nTotal, "Tag " + LTrim( Str( i ) ) + "/" + ;
                 LTrim( Str( Len( aDef ) ) ) + "  " + aDef[ i ][ 1 ] )
         ENDIF
         lOne := .F.
         oErr := NIL
         BEGIN SEQUENCE WITH {| e | Break( e ) }
            SELECT ( nArea )
            /* FOR condition and UNIQUE/DESCEND of the definition. OrdCondSet()
             * only honours the FOR in this build, so UNIQUE goes as the 5th
             * parameter of OrdCreate() and DESCEND is applied afterwards
             * (AGENTS.md 5.32) */
            IF Empty( aDef[ i ][ 3 ] )
               OrdCondSet()
            ELSE
               OrdCondSet( aDef[ i ][ 3 ], &( "{|| " + aDef[ i ][ 3 ] + " }" ) )
            ENDIF
            OrdCreate( aDef[ i ][ 6 ], aDef[ i ][ 1 ], aDef[ i ][ 2 ], ;
                       &( "{|| " + aDef[ i ][ 2 ] + " }" ), aDef[ i ][ 4 ] )
            IF ValType( aDef[ i ][ 5 ] ) == "L" .AND. aDef[ i ][ 5 ]
               dbOrderInfo( DBOI_ISDESC, , dbOrderInfo( DBOI_ORDERCOUNT ), .T. )
            ENDIF
            lOne := .T.
         RECOVER USING oErr
            lOne := .F.
         END SEQUENCE
         IF lOne
            /* detailed progress: how many keys the tag that has just been
             * created has. It is only informative, it never fails the run */
            nKeys := 0
            BEGIN SEQUENCE WITH {| e | Break( e ) }
               OrdSetFocus( aDef[ i ][ 1 ] )
               nKeys := OrdKeyCount()
            RECOVER
               nKeys := 0
            END SEQUENCE
            IF ! Empty( bProg )
               Eval( bProg, nStep, nTotal, "Tag " + LTrim( Str( i ) ) + "/" + ;
                    LTrim( Str( Len( aDef ) ) ) + "  " + aDef[ i ][ 1 ] + "  " + ;
                    LTrim( Str( nKeys ) ) + " keys" )
            ENDIF
            AAdd( s_aRecreateRes, { aDef[ i ][ 1 ], "REBUILT", aDef[ i ][ 2 ] } )
         ELSE
            lOk := .F.
            AAdd( s_aRecreateRes, { aDef[ i ][ 1 ], "DROPPED", StructErrText( oErr ) } )
         ENDIF
      NEXT
   ENDIF

   /* 5. finish: the new files stay, or the old ones come back */
   nStep++
   IF ! Empty( bProg )
      Eval( bProg, nStep, nTotal, ;
            iif( lOk, "Index files recreated", "Restoring the old index files" ) )
   ENDIF
   /* the FOR condition of the last OrdCreate() must not stay armed for the
    * next index creation of the caller */
   IF ! Empty( nArea ) .AND. nArea > 0
      BEGIN SEQUENCE WITH {| e | Break( e ) }
         SELECT ( nArea )
         OrdCondSet()
      RECOVER
      END SEQUENCE
   ENDIF
   /* close the work area WE opened: if it stays open in EXCLUSIVE the caller
    * cannot reopen the file ("Open error") and the database looks broken */
   StructCloseArea( nArea )

   FOR n := 1 TO Len( aBags )
      cBag := aBags[ n ]
      cBak := cBag + STRUCT_IDXBAKEXT
      IF lOk
         /* the old keys are useless: the file is brand new */
         IF hb_FNameExists( cBak )
            FErase( cBak )
         ENDIF
      ELSE
         IF aMoved[ n ]
            /* the old file is in <index>.IDXBAK: drop the partial new one and
             * give the old one back BYTE FOR BYTE */
            IF hb_FNameExists( cBag )
               FErase( cBag )
            ENDIF
            IF hb_FNameExists( cBak )
               FRename( cBak, cBag )
            ENDIF
         ELSEIF ! aHad[ n ] .AND. hb_FNameExists( cBag )
            /* there was no index file before: nothing to give back, the
             * partial new one is thrown away */
            FErase( cBag )
         ENDIF
      ENDIF
   NEXT
RETURN lOk

/* action ("DROP"|"REBUILD"|"KEEP"|"") assigned to a tag */
STATIC FUNCTION StructActionFor( aWork, cTag )
   LOCAL i
   FOR i := 1 TO Len( aWork )
      IF aWork[ i ][ 1 ] == Upper( cTag )
         RETURN aWork[ i ][ 2 ]
      ENDIF
   NEXT
RETURN ""

STATIC FUNCTION StructWorkDetail( aWork, cTag )
   LOCAL i
   FOR i := 1 TO Len( aWork )
      IF aWork[ i ][ 1 ] == Upper( cTag )
         RETURN aWork[ i ][ 3 ]
      ENDIF
   NEXT
RETURN ""

STATIC FUNCTION StructCountAction( aWork, cAction )
   LOCAL i, n := 0
   FOR i := 1 TO Len( aWork )
      IF aWork[ i ][ 2 ] == cAction
         n++
      ENDIF
   NEXT
RETURN n

STATIC FUNCTION StructReasonsText( aReasons )
   LOCAL c := "", i
   FOR i := 1 TO Len( aReasons )
      c += iif( Empty( c ), "", "; " ) + aReasons[ i ]
   NEXT
RETURN c

STATIC FUNCTION StructInList( aList, cValue )
   LOCAL i
   FOR i := 1 TO Len( aList )
      IF aList[ i ] == cValue
         RETURN .T.
      ENDIF
   NEXT
RETURN .F.

/* "language driver" byte of the DBF header (offset 28, the 29th in 1-based).
 * dbCreate() writes it to 0; the original file could declare another one (1 = CP437
 * in the databases made by the DOS BroPlus). It is read BEFORE the change and
 * written back in the new file, so as not to silently change the character
 * set the user database declares. */
/* read and remember the "language driver" byte of a file. It is called with the
 * file CLOSED (CoreOpen(), before the USE), which is the only moment when
 * a read handle can be opened if the database is going to be opened EXCLUSIVE. */
FUNCTION StructRememberDbfLang( cFile )
   LOCAL c := "", cKey, i
   IF Empty( cFile )
      RETURN NIL
   ENDIF
   cKey := Upper( hb_FNameName( cFile ) + hb_FNameExt( cFile ) )
   c := StructDbfLang( cFile )
   IF Empty( c ) .OR. Empty( cKey )
      RETURN NIL
   ENDIF
   FOR i := 1 TO Len( s_aDbfLang )
      IF s_aDbfLang[ i ][ 1 ] == cKey
         s_aDbfLang[ i ][ 2 ] := c
         RETURN NIL
      ENDIF
   NEXT
   AAdd( s_aDbfLang, { cKey, c } )
RETURN NIL

/* "language driver" byte of the DBF: it is read from the file and, if that fails (database
 * open in EXCLUSIVE), the one remembered when opening it is used. */
STATIC FUNCTION StructDbfLang( cFile )
   LOCAL nH, cByte := "", cKey, i
   IF Empty( cFile ) .OR. ! hb_FNameExists( cFile )
      RETURN ""
   ENDIF
   nH := FOpen( cFile, FO_READ )
   IF nH != -1
      FSeek( nH, 28, FS_SET )
      cByte := Space( 1 )
      IF FRead( nH, @cByte, 1 ) != 1
         cByte := ""
      ENDIF
      FClose( nH )
   ELSE
      cKey := Upper( hb_FNameName( cFile ) + hb_FNameExt( cFile ) )
      FOR i := 1 TO Len( s_aDbfLang )
         IF s_aDbfLang[ i ][ 1 ] == cKey
            cByte := s_aDbfLang[ i ][ 2 ]
            EXIT
         ENDIF
      NEXT
   ENDIF
RETURN cByte

STATIC PROCEDURE StructSetDbfLang( cFile, cByte )
   LOCAL nH
   IF Empty( cByte ) .OR. Empty( cFile ) .OR. ! hb_FNameExists( cFile )
      RETURN
   ENDIF
   nH := FOpen( cFile, FO_READWRITE )
   IF nH != -1
      FSeek( nH, 28, FS_SET )
      FWrite( nH, cByte, 1 )
      FClose( nH )
   ENDIF
RETURN

/* Closes area n if it has an open file. WATCH OUT: `Select( n ) > 0` does NOT
 * work as a test of "occupied area" in this Harbour (measured: Select(1)
 * returns 0 even if area 1 has a database open); the pattern of the project
 * is SELECT ( n ) inside a BEGIN SEQUENCE and then look at Used(), like
 * CoreAreas() in bp_core.prg. If the area is left open in EXCLUSIVE the
 * caller cannot reopen the file, which is exactly what made the database look
 * "broken". */
STATIC PROCEDURE StructCloseArea( nArea )
   LOCAL lOk := .T.
   IF Empty( nArea ) .OR. nArea < 1
      RETURN
   ENDIF
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      SELECT ( nArea )
   RECOVER
      lOk := .F.
   END SEQUENCE
   IF lOk .AND. Used()
      dbCloseArea()
   ENDIF
RETURN

/* closes (if still open) and deletes the running temporary and its memo. It relies on
 * the module STATIC variables so that the error path of StructApply() can
 * call it without knowing the paths. It is idempotent. */
STATIC PROCEDURE StructDropTemp()
   LOCAL aMemo := { ".FPT", ".DBT" }, i, cF
   IF s_nTempArea > 0
      StructCloseArea( s_nTempArea )
      s_nTempArea := 0
   ENDIF
   IF ! Empty( s_cTempFile ) .AND. hb_FNameExists( s_cTempFile )
      FErase( s_cTempFile )
   ENDIF
   IF ! Empty( s_cTempBase )
      FOR i := 1 TO Len( aMemo )
         cF := s_cTempBase + aMemo[ i ]
         IF hb_FNameExists( cF )
            FErase( cF )
         ENDIF
      NEXT
   ENDIF
   StructResetTemp()
RETURN

/* the error that reaches RECOVER can be an Error object (real error) or the
 * text passed to Break(): either of the two is accepted */
STATIC FUNCTION StructErrText( xErr )
   IF ValType( xErr ) == "O"
      RETURN xErr:Description
   ENDIF
   IF ValType( xErr ) == "C" .AND. ! Empty( xErr )
      RETURN xErr
   ENDIF
RETURN "Structure alteration failed"

/* -------------------------------------------------------------------------
 * PHYSICAL copy of the records of area nSrcArea to area nTmpArea.
 * aMap[i] = SOURCE field number for field i of the TARGET (0 = the
 * field did not exist: it stays empty, like the "Content of Removed Fields ... LOST").
 * Returns the copied records, or -1 if the user cancels.
 * ------------------------------------------------------------------------- */
STATIC FUNCTION StructCopyRecords( nSrcArea, nTmpArea, aMap, aDst, nTotal, bProg )
   LOCAL nDone := 0, i, lCancel := .F., nStep, nOrd, cFilter, lDel, nRec
   LOCAL xVal, nDstFields

   SELECT ( nSrcArea )
   nTotal  := RecCount()
   nRec    := RecNo()
   nOrd    := dbOrderInfo( DBOI_NUMBER )
   cFilter := dbFilter()
   /* aDst is the structure of the TARGET (normalized aSt): it defines to which
    * type/width each value is converted */
   nDstFields := Len( aDst )
   /* records marked as deleted are copied TOO (mark included):
    * that is what APPEND FROM did and no information must be lost */
   lDel := Set( _SET_DELETED, .F. )
   SET ORDER TO 0
   SET FILTER TO
   /* every how many records the progress is reported (and <Esc> is checked) */
   nStep := Max( 1, iif( nTotal > 500, Int( nTotal / 200 ), 1 ) )
   dbGoTop()
   DO WHILE ! Eof() .AND. ! lCancel
      SELECT ( nTmpArea )
      dbAppend()
      FOR i := 1 TO Len( aMap )
         IF aMap[ i ] > 0 .AND. i <= nDstFields
            /* FieldPut() does NOT convert types or clip numbers: StructConvert()
             * leaves the value in the type/width of the target field */
            xVal := ( nSrcArea )->( FieldGet( aMap[ i ] ) )
            FieldPut( i, StructConvert( xVal, aDst[ i ] ) )
         ENDIF
      NEXT
      IF ( nSrcArea )->( Deleted() )
         dbDelete()
      ENDIF
      nDone++
      SELECT ( nSrcArea )
      dbSkip()
      IF nDone % nStep == 0
         SELECT ( nTmpArea )
         dbCommit()                     /* header up to date in case it is cut short */
         SELECT ( nSrcArea )
         IF ! Empty( bProg )
            IF Eval( bProg, nDone, nTotal )
               lCancel := .T.
            ENDIF
         ENDIF
      ENDIF
   ENDDO
   SELECT ( nTmpArea )
   dbCommit()
   /* leave the original database as it was (order, filter, deletions and record)
    * so that cancelling changes nothing of what the user was seeing */
   SELECT ( nSrcArea )
   /* restore filter and order as they were (if there was no filter it is removed,
    * without a macro over an empty string): cancelling must not change what is seen */
   IF Empty( cFilter )
      SET FILTER TO
   ELSE
      SET FILTER TO &( cFilter )
   ENDIF
   OrdSetFocus( nOrd )
   Set( _SET_DELETED, lDel )
   IF ! Empty( nRec )
      dbGoto( nRec )
   ENDIF
RETURN iif( lCancel, -1, nDone )

/* field map: position of the SOURCE field that corresponds to each field
 * of the NEW structure (0 if the name does not exist in the original) */
STATIC FUNCTION StructFieldMap( nSrcArea, aSt )
   LOCAL aMap := Array( Len( aSt ) ), i
   SELECT ( nSrcArea )
   FOR i := 1 TO Len( aSt )
      aMap[ i ] := FieldPos( StructAsText( aSt[ i ][ 1 ] ) )
   NEXT
RETURN aMap

/* one element of the structure as text (the interface and the test
 * files can bring numbers where the name goes and vice versa) */
STATIC FUNCTION StructAsText( xVal )
   DO CASE
   CASE ValType( xVal ) == "C" ; RETURN xVal
   CASE ValType( xVal ) == "N" ; RETURN LTrim( Str( xVal ) )
   CASE ValType( xVal ) == "L" ; RETURN iif( xVal, "T", "F" )
   ENDCASE
RETURN ""

/* optional trace in hwbro.err (BP_DEBUG=1); this module is also compiled
 * in the headless tests, where BpLog() of the main program does not exist */
STATIC PROCEDURE BpLogStruct( cText )
#ifdef BP_STRUCT_STANDALONE
   /* nothing: in the tests there is no log of the main program */
#else
   BpLog( cText )
#endif
RETURN

/* -------------------------------------------------------------------------
 * StructGenPrgText()  -> array of lines of the program (to show it on
 *                        screen and copy it to the clipboard)
 * StructGenPrg( cPrg, aLines ) -> lOk   writes those lines to a file
 *
 * Writes a Harbour program that RECREATES the structure of the OPEN database (its
 * fields, widths and decimals) and its indexes (each tag with its key, FOR, UNIQUE
 * and DESCENDING, in the SAME order so as not to change the .CDX numbering), with
 * the data blank. It is what F2 > Generate Structure PRG does.
 *
 * - The structure comes from DbStruct() (the same array the editor uses).
 * - The tags come from StructTags(), which already normalizes dbOrderInfo().
 * - The "language driver" byte of the header (offset 28) is copied with StructDbfLang()
 *   because dbCreate() writes it to 0 (see AGENTS.md trap 17).
 * - The dynamic texts (field name, key and FOR) are emitted with
 *   hb_ValToExp(), so a key with quotes comes out as a valid literal.
 * ------------------------------------------------------------------------- */
FUNCTION StructGenPrgText()
   LOCAL aSt, aTags, aLin := {}, i, cFull, cBase, cBag, nLang, cLang
   IF ! Used()
      RETURN aLin
   ENDIF
   cFull := dbInfo( DBI_FULLPATH )
   /* WATCH OUT (measured): hb_FNameName() returns the name WITHOUT extension and
    * hb_FNameNameExt() WITH it (the opposite of what the name suggests) */
   cBase := Upper( hb_FNameName( cFull ) )
   IF Empty( cBase )
      cBase := Upper( Alias() )
   ENDIF
   /* StructDbfLang() returns the BYTE as a 1 character text (or "" if it cannot be
    * read): here its numeric value is what matters for the new header */
   cLang := StructDbfLang( cFull )
   nLang := iif( Empty( cLang ), 0, Asc( cLang ) )
   aTags := StructTags()

   /* the structure of the open area as it is: { { name, type, width, dec }, ... }
    * (DbStruct() is the same thing the structure editor uses) */
   aSt := DbStruct()

   /* header of the generated program */
   AAdd( aLin, "/*" )
   AAdd( aLin, " * Structure of " + cBase + ".DBF and its indexes - generated by " + BP_APPNAME + " " + BP_VERSION )
   AAdd( aLin, " * Recreates the structure of " + cBase + ".DBF and its indexes (" + ;
              LTrim( Str( Len( aTags ) ) ) + " tag(s)), without data." )
   AAdd( aLin, " * Build:  hbmk2 <this file>" )
   AAdd( aLin, " */" )
   AAdd( aLin, "REQUEST DBFCDX" )
   AAdd( aLin, "REQUEST DBFFPT" )
   AAdd( aLin, '#include "common.ch"' )   /* DEFAULT comes from common.ch */
   AAdd( aLin, '#include "dbinfo.ch"' )
   AAdd( aLin, '#include "ord.ch"' )
   AAdd( aLin, '#include "fileio.ch"' )
   AAdd( aLin, "" )
   AAdd( aLin, "FUNCTION Main( cDbf )" )
   AAdd( aLin, "   LOCAL aSt := { ;" )
   FOR i := 1 TO Len( aSt )
      AAdd( aLin, "      { " + hb_ValToExp( aSt[ i ][ 1 ] ) + ", " + ;
                 hb_ValToExp( aSt[ i ][ 2 ] ) + ", " + ;
                 LTrim( Str( aSt[ i ][ 3 ] ) ) + ", " + ;
                 LTrim( Str( aSt[ i ][ 4 ] ) ) + " }" + ;
                 iif( i == Len( aSt ), " ;", ", ;" ) )
   NEXT
   AAdd( aLin, "   }" )
   AAdd( aLin, "   LOCAL cBag := " + hb_ValToExp( cBase ) )
   AAdd( aLin, "   LOCAL cKey, cFor, nH" )
   AAdd( aLin, "" )
   /* WATCH OUT: the LOCAL declarations ALWAYS go before DEFAULT (which is a statement, not
    * a declaration): the other way round the compiler says "LOCAL declaration follows
    * executable statement". */
   AAdd( aLin, "   DEFAULT cDbf TO " + hb_ValToExp( cBase + ".DBF" ) )
   AAdd( aLin, "" )
   /* without this OrdCreate() would create a .NTX instead of the .CDX */
   AAdd( aLin, "   rddSetDefault( " + hb_ValToExp( "DBFCDX" ) + " )" )
   AAdd( aLin, "" )
   AAdd( aLin, "   IF File( cDbf )" )
   AAdd( aLin, "      ? 'File already exists: ' + cDbf" )
   AAdd( aLin, "      ErrorLevel( 1 )" )
   AAdd( aLin, "      RETURN 1" )
   AAdd( aLin, "   ENDIF" )
   AAdd( aLin, "   IF ! dbCreate( cDbf, aSt )" )
   AAdd( aLin, "      ? 'Cannot create ' + cDbf" )
   AAdd( aLin, "      ErrorLevel( 1 )" )
   AAdd( aLin, "      RETURN 1" )
   AAdd( aLin, "   ENDIF" )
   /* The byte at offset 28 of the DBF header is the "language driver"
    * (the OEM codepage the data was written with: 1 = cp437, 3 = cp1252,
    * etc.). dbCreate() ALWAYS writes it to 0, so if the original had one
    * the codepage is lost (and with it the way accents and the
    * enye are sorted/compared). If the original database had it, it is copied here; if it was 0 nothing
    * is emitted, because there is nothing to copy. */
   IF nLang > 0
      AAdd( aLin, "   /* Copy the 'language driver' (OEM code page, header offset 28) from" )
      AAdd( aLin, "    * the original table: dbCreate() writes 0 there. */" )
      AAdd( aLin, "   nH := FOpen( cDbf, FO_READWRITE )" )
      AAdd( aLin, "   IF nH != -1" )
      AAdd( aLin, "      FSeek( nH, 28 )" )
      AAdd( aLin, "      FWrite( nH, Chr( " + LTrim( Str( nLang ) ) + " ) )" )
      AAdd( aLin, "      FClose( nH )" )
      AAdd( aLin, "   ENDIF" )
   ENDIF
   AAdd( aLin, "   dbUseArea( .T., NIL, cDbf, cBag, .F. )" )
   FOR i := 1 TO Len( aTags )
      cBag := Upper( hb_FNameName( aTags[ i ][ 1 ] ) )
      IF Empty( cBag )
         cBag := cBase
      ENDIF
      AAdd( aLin, "" )
      AAdd( aLin, "   /* tag " + aTags[ i ][ 2 ] + " */" )
      AAdd( aLin, "   cKey := " + hb_ValToExp( aTags[ i ][ 3 ] ) )
      AAdd( aLin, "   OrdCondSet()" )
      IF ! Empty( aTags[ i ][ 4 ] )
         AAdd( aLin, "   cFor := " + hb_ValToExp( aTags[ i ][ 4 ] ) )
         AAdd( aLin, '   OrdCondSet( cFor, &( "{|| " + cFor + " }" ) )' )
      ENDIF
      AAdd( aLin, "   OrdCreate( " + hb_ValToExp( cBag ) + ", " + ;
                 hb_ValToExp( aTags[ i ][ 2 ] ) + ", cKey, " + ;
                 '&( "{|| " + cKey + " }" ), ' + ;
                 iif( aTags[ i ][ 5 ], ".T.", ".F." ) + " )" )
      IF aTags[ i ][ 6 ]
         AAdd( aLin, "   dbOrderInfo( DBOI_ISDESC, , " + ;
                    hb_ValToExp( aTags[ i ][ 2 ] ) + ", .T. )" )
      ENDIF
   NEXT
   AAdd( aLin, "" )
   AAdd( aLin, "   dbCloseArea()" )
   AAdd( aLin, "   ? 'Created ' + cDbf + ' (' + LTrim( Str( Len( aSt ) ) ) + ' field(s), " + ;
              LTrim( Str( Len( aTags ) ) ) + " tag(s))'" )
   AAdd( aLin, "   ErrorLevel( 0 )" )
   AAdd( aLin, "RETURN 0" )
RETURN aLin

/* Writes the lines to a file. WATCH OUT: hb_MemoWrit() with an array does NOT create the
 * file in this build (it returns NIL and writes nothing), measured, that is why it is
 * written by hand. */
FUNCTION StructGenPrg( cPrg, aLines )
   LOCAL i, nH
   DEFAULT aLines TO StructGenPrgText()
   IF Empty( aLines ) .OR. Empty( cPrg )
      RETURN .F.
   ENDIF
   nH := FCreate( cPrg )
   IF nH == -1
      RETURN .F.
   ENDIF
   FOR i := 1 TO Len( aLines )
      FWrite( nH, aLines[ i ] + hb_eol() )
   NEXT
   FClose( nH )
RETURN File( cPrg )

/* -------------------------------------------------------------------------
 * CdxBagCheck( cFile ) -> "" | <short description of the first broken link>
 *
 * READ-ONLY sanity check of the page tree of a .CDX index bag. It looks for the
 * incoherence that makes the balancer abort the whole program with
 *   "Unrecoverable error 9201: hb_cdxPageKeyIntBalance: index corrupted."
 * as soon as a key field is written (measured on tests\REMITOS.CDX, see
 * odd/tasks/index-integrity-guard.md). The engine wants, for every page that
 * holds sibling pointers, that the page on the left points back with its right
 * pointer and vice versa (dbfcdx1.c, hb_cdxPageKeyIntBalance). A ROOT page is
 * never a sibling: a link to it is already impossible.
 *
 * MEASURED (that is why the rules are not the same for every bag): the bags
 * written by OTHER engines - the SIx Driver of BroPlus: no "RCHB" signature,
 * 512-byte pages, absolute byte offsets - keep LOOSE back links. Files that
 * write perfectly well (CLIENTES.CDX, ARTICULO.CDX) still have pages whose
 * right pointer is the head of another chain and orphan pages with stale
 * links, so the strict double-link test gives false positives on them. The
 * strict test is therefore applied only to the bags written by this Harbour
 * ("RCHB"); on a foreign bag only the impossible link is reported.
 *
 * Bag header (1024 bytes at offset 0):
 *   rootPtr LE u32 @0    freePtr LE u32 @4    counter BE u32 @8
 *   keySize LE u16 @12   indexOpt @14         indexSig @15
 *   headerLen LE u16 @16 pageLen  LE u16 @18  signature BE u32 @20
 * Page header (12 bytes): attr LE u16 @0 (1 = root, 2 = leaf, 3 = both),
 *   nKeys LE u16 @2, leftPtr LE u32 @4, rightPtr LE u32 @8.
 * Without "RCHB" the bag is foreign: 512-byte pages and the pointers are
 * ABSOLUTE BYTE OFFSETS. With "RCHB" pageLen comes from @18 and, when
 * indexSig == 0x21, the pointers are PAGE NUMBERS (offset = n * pageLen).
 * A valid pointer is CDX_DUMMYNODE (0xFFFFFFFF) or a page aligned inside the
 * file; 0 is never a page (offset 0 is the bag header).
 *
 * It NEVER opens the bag with the RDD and never writes: only FOpen/FRead/
 * FSeek/FClose, so the headless bench (bp_struct.prg compiled alone) can test
 * it. A missing or unreadable file, a file that does not look like a bag and a
 * bag bigger than CDX_CHECK_MAX give "" - it never warns when in doubt.
 * ------------------------------------------------------------------------- */
FUNCTION CdxBagCheck( cFile )
   LOCAL nH, nSize, cHdr, cBuf, nPageLen, lPageNum, lHarbour, nRoot
   LOCAL aPages := {}, nChunk, nOff, nRead, nStep, nAttr, nLeft, nRight, nId
   LOCAL i, nSide, nPtr, nTgt, nBack, cSide, lRead := .T.

   IF Empty( cFile ) .OR. ! hb_FNameExists( cFile )
      RETURN ""
   ENDIF
   nH := FOpen( cFile, FO_READ )
   IF nH == -1
      RETURN ""
   ENDIF
   nSize := FSeek( nH, 0, FS_END )
   IF nSize < CDX_HEADERLEN .OR. nSize > CDX_CHECK_MAX
      FClose( nH )
      RETURN ""
   ENDIF
   cHdr := Space( CDX_HEADERLEN )
   FSeek( nH, 0, FS_SET )
   IF FRead( nH, @cHdr, CDX_HEADERLEN ) != CDX_HEADERLEN
      FClose( nH )
      RETURN ""
   ENDIF

   /* page size and kind of pointer (see the header of this function) */
   lHarbour := ( CdxBE32( cHdr, 21 ) == CDX_SIGNATURE )
   IF lHarbour
      nPageLen := CdxU16( cHdr, 19 )
      lPageNum := ( Asc( SubStr( cHdr, 16, 1 ) ) == CDX_INDEXSIG_PAGE )
      IF CdxU16( cHdr, 17 ) != CDX_HEADERLEN .OR. ;
         ! ( nPageLen == 512 .OR. nPageLen == 1024 .OR. nPageLen == 2048 .OR. ;
             nPageLen == 4096 .OR. nPageLen == 8192 )
         FClose( nH )
         RETURN ""
      ENDIF
   ELSE
      /* foreign bag: 512-byte pages and byte offsets, whatever the header says */
      nPageLen := CDX_PAGEMIN
      lPageNum := .F.
   ENDIF

   /* the root of the first tag has to be a plausible page: the cheapest way to
    * tell a real bag from any other file (a .PRG gives "" too) */
   nRoot := CdxU32( cHdr, 1 )
   IF nSize < nPageLen .OR. ! CdxIsPagePtr( nRoot, nPageLen, lPageNum, nSize )
      FClose( nH )
      RETURN ""
   ENDIF

   /* read the file in BLOCKS of whole pages (never page by page) and keep only
    * the page headers; the pages whose attr or pointers make no sense are
    * ignored so that no false positive comes out of them */
   nChunk := ( CDX_CHECK_CHUNK / nPageLen ) * nPageLen
   nOff := 0
   DO WHILE nOff < nSize .AND. lRead
      nRead := Min( nChunk, nSize - nOff )
      cBuf := Space( nRead )
      FSeek( nH, nOff, FS_SET )
      IF FRead( nH, @cBuf, nRead ) != nRead
         lRead := .F.
         EXIT
      ENDIF
      nStep := 1
      DO WHILE nStep + CDX_PAGEHDR - 1 <= nRead
         nAttr  := CdxU16( cBuf, nStep )
         nLeft  := CdxU32( cBuf, nStep + 4 )
         nRight := CdxU32( cBuf, nStep + 8 )
         IF nAttr >= CDX_NODE_BRANCH .AND. ;
            nAttr <= CDX_NODE_ROOT + CDX_NODE_LEAF .AND. ;
            CdxPtrOk( nLeft, nPageLen, lPageNum, nSize ) .AND. ;
            CdxPtrOk( nRight, nPageLen, lPageNum, nSize )
            /* the page id is the byte offset, or the page number, which is
             * exactly what the pointers store in each case */
            nId := nOff + nStep - 1
            IF lPageNum
               nId := Int( nId / nPageLen )
            ENDIF
            AAdd( aPages, { nId, nAttr, nLeft, nRight } )
         ENDIF
         nStep += nPageLen
      ENDDO
      nOff += nRead
   ENDDO
   FClose( nH )
   IF ! lRead
      RETURN ""
   ENDIF

   /* the pages are in ascending order: the binary search finds the page a
    * pointer refers to */
   FOR i := 1 TO Len( aPages )
      nId   := aPages[ i ][ 1 ]
      nAttr := aPages[ i ][ 2 ]
      FOR nSide := 1 TO 2
         nPtr := aPages[ i ][ nSide + 2 ]
         IF ! CdxIsPagePtr( nPtr, nPageLen, lPageNum, nSize )
            LOOP
         ENDIF
         nTgt := CdxFindPage( aPages, nPtr )
         IF nTgt == 0
            LOOP
         ENDIF
         cSide := iif( nSide == 1, "left", "right" )
         IF CdxIsRootPage( aPages[ nTgt ][ 2 ] )
            /* a root has no siblings: this is the link of REMITOS.CDX that
             * sends the balancer to "index corrupted." */
            IF ! CdxIsRootPage( nAttr )
               RETURN "page " + LTrim( Str( nId ) ) + ": " + cSide + ;
                      " pointer to the tag root " + LTrim( Str( nPtr ) )
            ENDIF
         ELSEIF lHarbour
            /* this Harbour keeps the double link tight, so the back link can
             * be required (a foreign bag may hold stale ones) */
            nBack := aPages[ nTgt ][ iif( nSide == 1, 4, 3 ) ]
            IF nBack != nId
               RETURN "page " + LTrim( Str( nId ) ) + ": " + cSide + ;
                      " pointer " + LTrim( Str( nPtr ) ) + " points back to " + ;
                      LTrim( Str( nBack ) )
            ENDIF
         ENDIF
      NEXT
   NEXT
RETURN ""

/* little/big endian readers over a binary string, 1-based position */
STATIC FUNCTION CdxU16( cBuf, nPos )
RETURN Asc( SubStr( cBuf, nPos, 1 ) ) + ;
       Asc( SubStr( cBuf, nPos + 1, 1 ) ) * 256

STATIC FUNCTION CdxU32( cBuf, nPos )
RETURN Asc( SubStr( cBuf, nPos, 1 ) ) + ;
       Asc( SubStr( cBuf, nPos + 1, 1 ) ) * 256 + ;
       Asc( SubStr( cBuf, nPos + 2, 1 ) ) * 65536 + ;
       Asc( SubStr( cBuf, nPos + 3, 1 ) ) * 16777216

STATIC FUNCTION CdxBE32( cBuf, nPos )
RETURN Asc( SubStr( cBuf, nPos, 1 ) ) * 16777216 + ;
       Asc( SubStr( cBuf, nPos + 1, 1 ) ) * 65536 + ;
       Asc( SubStr( cBuf, nPos + 2, 1 ) ) * 256 + ;
       Asc( SubStr( cBuf, nPos + 3, 1 ) )

/* byte offset in the file of a page pointer: a byte offset, or a page number
 * multiplied by the page size when the bag stores page numbers */
STATIC FUNCTION CdxPtrOffset( nPtr, nPageLen, lPageNum )
RETURN iif( lPageNum, nPtr * nPageLen, nPtr )

/* is the pointer a REAL page? (0xFFFFFFFF means "no sibling" and offset 0 is
 * the bag header, never a page) */
STATIC FUNCTION CdxIsPagePtr( nPtr, nPageLen, lPageNum, nSize )
   LOCAL nOff
   IF nPtr <= 0 .OR. nPtr == CDX_DUMMYNODE
      RETURN .F.
   ENDIF
   nOff := CdxPtrOffset( nPtr, nPageLen, lPageNum )
RETURN ( nOff % nPageLen == 0 .AND. nOff + CDX_PAGEHDR <= nSize )

/* a page header pointer is acceptable when it means "no sibling" or it is a
 * real page inside the file */
STATIC FUNCTION CdxPtrOk( nPtr, nPageLen, lPageNum, nSize )
RETURN ( nPtr == CDX_DUMMYNODE ) .OR. ;
       CdxIsPagePtr( nPtr, nPageLen, lPageNum, nSize )

/* attr of a page that is the root of its tree (CDX_NODE_ROOT, with or without
 * CDX_NODE_LEAF) */
STATIC FUNCTION CdxIsRootPage( nAttr )
RETURN ( nAttr == CDX_NODE_ROOT .OR. nAttr == CDX_NODE_ROOT + CDX_NODE_LEAF )

/* index of the page with id nId in aPages (ascending), 0 when it is not there */
STATIC FUNCTION CdxFindPage( aPages, nId )
   LOCAL nLo := 1, nHi := Len( aPages ), nMid
   DO WHILE nLo <= nHi
      nMid := Int( ( nLo + nHi ) / 2 )
      IF aPages[ nMid ][ 1 ] == nId
         RETURN nMid
      ELSEIF aPages[ nMid ][ 1 ] < nId
         nLo := nMid + 1
      ELSE
         nHi := nMid - 1
      ENDIF
   ENDDO
RETURN 0
