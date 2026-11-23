/*
 * bp_core.prg - Global state, work areas, database opening, browse
 * hwBro - clone of BroPlus 3.00 (Extrasensory Software) - Harbour + MSVC x64
 */
#include "inkey.ch"
#include "dbinfo.ch"
#include "fileio.ch"
#include "bp_def.ch"
/* U1: HB_GTI_KBD_ALT / HB_GTI_KBD_CTRL, the bits of the Alt+<letter> shortcuts.
 * WITHOUT this include they are UNDEFINED identifiers, which Harbour compiles
 * as a reference to a variable that does not exist: the first Alt+key that
 * reached this file closed the whole application with no visible error and no
 * line in hwbro.err (trap 8). */
#include "hbgtinfo.ch"

/* ---------- global state ---------- */
STATIC s_cDir     := ""
STATIC s_nSelCol  := 1
STATIC s_cDriver  := "DBFCDX"
STATIC s_cOpenMode := "EXCLUSIVE"
STATIC s_lHideDel := .F.
STATIC s_lSoftSeek := .F.
STATIC s_nMemoWidth := 65
STATIC s_lCellEdit := .T.
STATIC s_lIncrSeek := .F.
STATIC s_cDbfSpec := "*.DBF"
STATIC s_cIdxSpec := "*.CDX"
STATIC s_aClip    := {}
STATIC s_xClipFld  := NIL          /* S71: field clipboard { name, value, type } */
/* right-click-esc (S8 of right-click-esc.md): the right gesture that started
 * OUTSIDE the record grid, remembered between polls. The detector of bp_hc.prg
 * consumes the cell of the press, so on the pass that sees the release the
 * question "did it start outside the grid?" can no longer be asked. */
STATIC s_lCtxRClickOutside := .F.
/* A2 of f2-dbmanager.md: the last base was closed from a MENU of this screen.
 * That is not the user leaving the manager, so Main() has to know it and stay
 * on the base-less face instead of going back to the file manager. One-shot: it
 * is read with CoreLeftByClosing(). */
STATIC s_lCoreLeftByClose := .F.
STATIC s_nBannerWait := 1500
/* bags already reported as damaged: one warning per file and session, even if
 * the database is reopened by a mode change or by BpDbReopen() */
STATIC s_aBagWarn  := {}

/* field view */
STATIC s_aOrder    := {}          // display order (field numbers)
STATIC s_aSel      := {}          // selected fields
STATIC s_lShowSel  := .F.         // show only the selected ones
STATIC s_nLock     := 0           // fixed columns on the left
STATIC s_cColExpr  := ""          // color condition (expression)
STATIC s_cColColor := "W+/R+"     // color when the condition is true

/* S2 of browse-edit-mouse.md: the identity of the LAST click of the record area,
 * so a double click can be decided with the RECORD and the COLUMN in hand. It
 * has to live here and not in the window hook: bp_win32.c only knows the screen
 * ROW, and pairing two clicks by row made a single click enter a directory after
 * the listing changed under it (trap 48). s_cClickId carries the base and the
 * order, so changing either drops the pair. */
STATIC s_cClickId  := ""
STATIC s_nClickPos := 0
STATIC s_nClickSel := 0
STATIC s_nClickTop := 0

FUNCTION CoreInit()
   LOCAL cExe := hb_ProgName()
   s_cDir := Left( cExe, Rat( "\", cExe ) )
   IF Empty( s_cDir ) ; s_cDir := CurDir() + "\" ; ENDIF
   Set( _SET_DEFAULT, s_cDir )
   rddSetDefault( s_cDriver )
   Set( _SET_DELETED, s_lHideDel )
   Set( _SET_SOFTSEEK, s_lSoftSeek )
   Set( _SET_EXCLUSIVE, ( s_cOpenMode == "EXCLUSIVE" ) )
RETURN NIL

FUNCTION CoreDriver()      ; RETURN s_cDriver
FUNCTION CoreSetDriver( c ) ; s_cDriver := c ; rddSetDefault( c ) ; RETURN NIL
FUNCTION CoreDir()         ; RETURN s_cDir
FUNCTION CoreSetDir( c )
   IF ! Empty( c )
      c := RTrim( c )
      IF Right( c, 1 ) != "\" ; c += "\" ; ENDIF
      s_cDir := c
      Set( _SET_DEFAULT, c )
   ENDIF
RETURN s_cDir
FUNCTION CoreOpenMode()    ; RETURN s_cOpenMode
FUNCTION CoreToggleMode()  ; s_cOpenMode := iif( s_cOpenMode == "SHARED", "EXCLUSIVE", "SHARED" ) ; RETURN s_cOpenMode

/* REAL mode of the active area ("SHARED"/"EXCLUSIVE"), which is what the bars
 * have to show. With no database open it returns the SETTING, that is the
 * mode the next opening will use. dbInfo( DBI_SHARED ) raises an error when
 * there is no active area (or the RDD does not support it), hence Used() + BEGIN SEQUENCE. */
FUNCTION CoreRealMode()
   LOCAL c := CoreOpenMode(), lShared
   IF Used()
      BEGIN SEQUENCE WITH {| e | Break( e ) }
         lShared := dbInfo( DBI_SHARED )
         c := iif( lShared, "SHARED", "EXCLUSIVE" )
      RECOVER
         c := CoreOpenMode()
      END SEQUENCE
   ENDIF
RETURN c

/* label of the real mode for the bars: "Shared" / "Exclusive" */
FUNCTION CoreModeName()
RETURN iif( CoreRealMode() == "SHARED", "Shared", "Exclusive" )
FUNCTION CoreHideDel()     ; RETURN s_lHideDel
FUNCTION CoreToggleHideDel() ; s_lHideDel := ! s_lHideDel ; Set( _SET_DELETED, s_lHideDel ) ; RETURN s_lHideDel
FUNCTION CoreSoftSeek()    ; RETURN s_lSoftSeek
FUNCTION CoreToggleSoftSeek() ; s_lSoftSeek := ! s_lSoftSeek ; Set( _SET_SOFTSEEK, s_lSoftSeek ) ; RETURN s_lSoftSeek
FUNCTION CoreCellEdit()    ; RETURN s_lCellEdit
FUNCTION CoreToggleCellEdit() ; s_lCellEdit := ! s_lCellEdit ; RETURN s_lCellEdit
FUNCTION CoreIncrSeek()    ; RETURN s_lIncrSeek
FUNCTION CoreToggleIncrSeek() ; s_lIncrSeek := ! s_lIncrSeek ; RETURN s_lIncrSeek
FUNCTION CoreMemoWidth()   ; RETURN s_nMemoWidth
FUNCTION CoreSetMemoWidth( n ) ; s_nMemoWidth := n ; RETURN n
FUNCTION CoreDbfSpec()     ; RETURN s_cDbfSpec
FUNCTION CoreSetDbfSpec( c ) ; s_cDbfSpec := c ; RETURN c
FUNCTION CoreIdxSpec()     ; RETURN s_cIdxSpec
FUNCTION CoreSetIdxSpec( c ) ; s_cIdxSpec := c ; RETURN c
FUNCTION CoreClip()        ; RETURN s_aClip
FUNCTION CoreSetClip( a )  ; s_aClip := a ; RETURN a
/* S71: the FIELD clipboard (Copy Field / Paste Field) is separate from the
 * record snapshot: { cFieldName, xValue, cType } or NIL when nothing was
 * copied. The old Copy Field wrote the whole record into s_aClip, so it and
 * Copy Record were the same thing and Paste Record replayed old snapshots. */
FUNCTION CoreClipField()      ; RETURN s_xClipFld
FUNCTION CoreSetClipField( x ) ; s_xClipFld := x ; RETURN x

/* ---------- work areas ---------- */

FUNCTION CoreAreas()
   LOCAL a := {}, n, nOld := Select(), lOk
   FOR n := 1 TO 64
      lOk := .T.
      BEGIN SEQUENCE WITH {| e | Break( e ) }
         SELECT ( n )
      RECOVER
         lOk := .F.
      END SEQUENCE
      IF ! lOk
         EXIT
      ENDIF
      IF Used()
         AAdd( a, { n, Alias(), DBF() } )
      ENDIF
   NEXT
   SELECT ( nOld )
RETURN a

FUNCTION CoreAreaCount()
RETURN Len( CoreAreas() )

/* first free area; 0 if there is none */
FUNCTION CoreFreeArea()
   LOCAL n, nOld := Select(), nFree := 0, lOk
   FOR n := 1 TO 64
      lOk := .T.
      BEGIN SEQUENCE WITH {| e | Break( e ) }
         SELECT ( n )
      RECOVER
         lOk := .F.
      END SEQUENCE
      IF ! lOk
         EXIT
      ENDIF
      IF ! Used()
         nFree := n
         EXIT
      ENDIF
   NEXT
   SELECT ( nOld )
RETURN nFree

/* open a database in its own area.
 * The default mode is EXCLUSIVE (F2 "Open Mode" setting); if the file
 * is taken by another process (or already open in another instance) the `USE ...
 * EXCLUSIVE` fails: the user is WARNED and offered to open it in SHARED. If accepted, the
 * setting stays in SHARED for the next openings of the session (F2 -> Open
 * Mode shows it) and the area is opened in SHARED.
 * lNoAsk = .T. disables the warning: BpDbToggleMode() uses it, since it already has its
 * own retry chain and must not ask twice. */
FUNCTION CoreOpen( cFile, cAlias, lNoAsk )
   LOCAL nArea, aRes, lShared := ( CoreOpenMode() != "EXCLUSIVE" )
   DEFAULT lNoAsk TO .F.
   BpLog( "CoreOpen: " + cFile + " modo=" + iif( lShared, "SHARED", "EXCLUSIVE" ) )
   nArea := CoreFreeArea()
   BpLog( "CoreOpen: free area=" + LTrim( Str( nArea ) ) )
   IF nArea == 0
      UiErr( "No free areas (16 maximum in use)." )
      RETURN .F.
   ENDIF
   /* the header "language driver" byte can only be read with the file
    * closed: it is remembered NOW, before opening it (see bp_struct.prg) */
   StructRememberDbfLang( cFile )
   aRes := CoreTryOpen( nArea, cFile, cAlias, lShared )
   IF ! aRes[ 1 ] .AND. ! lShared .AND. ! lNoAsk
      /* most likely another process has the file open: in that
       * case EXCLUSIVE will not work and the only thing left is SHARED */
      IF UiConfirm( "Could not open in Exclusive Mode:" + hb_eol() + ;
                    cFile + hb_eol() + ;
                    aRes[ 2 ] + hb_eol() + hb_eol() + ;
                    "Open it in Shared Mode?", "Open Mode" )
         CoreToggleMode()                 /* the setting switches to SHARED */
         lShared := .T.
         aRes := CoreTryOpen( nArea, cFile, cAlias, .T. )
      ENDIF
   ENDIF
   BpLog( "CoreOpen: resultado=" + iif( aRes[ 1 ], "OK", "FALLO: " + aRes[ 2 ] ) + ;
          iif( aRes[ 1 ], " modo real=" + CoreRealMode(), "" ) )
   IF ! aRes[ 1 ]
      UiErr( "Could not open " + cFile + ":" + hb_eol() + aRes[ 2 ] )
   ELSE
      CoreBagWarn( cFile )
   ENDIF
RETURN aRes[ 1 ]

/* S3: warn ONCE per bag file and session when the .CDX next to the database
 * shows a broken page tree. It only warns: nothing is deleted, rebuilt or
 * touched - the user is the one who runs F3 > Recreate Index File.
 * The alias of the freshly opened area is used, because it is what the user
 * sees in the bars. */
STATIC PROCEDURE CoreBagWarn( cFile )
   LOCAL cBag, cWhat
   IF Empty( cFile )
      RETURN
   ENDIF
   cBag := CoreBagPath( cFile )
   IF Empty( cBag ) .OR. ! hb_FNameExists( cBag )
      RETURN
   ENDIF
   /* already reported in this session? */
   IF AScan( s_aBagWarn, {| c | Upper( c ) == Upper( cBag ) } ) > 0
      RETURN
   ENDIF
   cWhat := CdxBagCheck( cBag )
   IF Empty( cWhat )
      RETURN
   ENDIF
   AAdd( s_aBagWarn, cBag )
   BpLog( "CoreOpen: damaged bag " + cBag + " (" + cWhat + ")" )
   UiMsg( "The index file of " + Upper( Alias() ) + " looks damaged:" + hb_eol() + ;
          hb_FNameNameExt( cBag ) + hb_eol() + ;
          "hwBro may close itself when a key field is written." + hb_eol() + ;
          "Use F3 > Recreate Index File to rebuild it." )
RETURN

/* path of the .CDX bag that lives next to a database: the extension is
 * replaced, and a database with no extension gets one added. The comparison
 * with the last separator keeps a dot inside a directory name from being
 * taken as the extension. */
STATIC FUNCTION CoreBagPath( cFile )
   LOCAL c := AllTrim( cFile ), nDot, nSep
   nDot := Rat( ".", c )
   nSep := Max( Rat( "\", c ), Rat( "/", c ) )
   IF nDot > nSep
      c := Left( c, nDot - 1 )
   ENDIF
RETURN c + ".CDX"

/* one open attempt: { lOk, cErrorDescription } */
STATIC FUNCTION CoreTryOpen( nArea, cFile, cAlias, lShared )
   LOCAL oErr, lOk := .F., cDesc := ""
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      SELECT ( nArea )
      IF Empty( cAlias )
         IF lShared
            USE ( cFile ) NEW SHARED
         ELSE
            USE ( cFile ) NEW EXCLUSIVE
         ENDIF
      ELSE
         /* dbUseArea() instead of "USE ... ALIAS &cAlias": with a macro, an alias
          * with odd characters would compile as an expression and blow up */
         dbUseArea( .F., NIL, cFile, cAlias, lShared )
      ENDIF
      lOk := .T.
   RECOVER USING oErr
      cDesc := oErr:Description
   END SEQUENCE
RETURN { lOk, cDesc }

/* close the current area */
FUNCTION CoreCloseArea()
   IF Used()
      CLOSE
      RETURN .T.
   ENDIF
RETURN .F.

FUNCTION CoreCloseAll()
   CLOSE ALL
RETURN NIL

/* If the current area was left without a database but others are open, activate the
 * first one. It keeps the application from falling to the desktop (Used() = .F.) with
 * databases open. Returns .T. if an active database is left. */
FUNCTION CoreActivateAnyArea()
   LOCAL a
   IF Used()
      RETURN .T.
   ENDIF
   a := CoreAreas()
   IF Empty( a )
      RETURN .F.
   ENDIF
   SELECT ( a[ 1 ][ 1 ] )
RETURN .T.

/* FULL file name of the data file of the active area.
 * NOTE (measured with a test program on this Harbour): **DBF() returns the
 * ALIAS, not the file name**, so it cannot be used to know which file is
 * open when the alias has been renamed (DBF() gave "ZZ" for ARTICULO.DBF
 * opened with ALIAS "ZZ"). dbInfo( DBI_FULLPATH ) does return the real path. */
FUNCTION CoreFileName()
   LOCAL c := ""
   IF Used()
      BEGIN SEQUENCE WITH {| e | Break( e ) }
         c := dbInfo( DBI_FULLPATH )
      RECOVER
         c := DBF()
      END SEQUENCE
   ENDIF
RETURN AllTrim( c )

/* base name of the file of the active database: no path and no extension, in
 * lowercase. NOTE: DBF() returns the ALIAS, so the name is taken from
 * CoreFileName(); the index bag (.CDX) is named like the FILE. */
FUNCTION CoreFileBase()
   LOCAL c := CoreFileName()
   IF Rat( "\", c ) > 0
      c := SubStr( c, Rat( "\", c ) + 1 )
   ENDIF
   IF Rat( ".", c ) > 0
      c := Left( c, Rat( ".", c ) - 1 )
   ENDIF
RETURN Lower( AllTrim( c ) )

/* base name of any file path: no directory and no extension, in upper case.
 * NOTE: in Harbour DBF() returns the name WITHOUT extension ("ARTICULO"), and
 * CoreFileName() returns a full path, so both are reduced with this helper
 * before they are compared. */
STATIC FUNCTION CoreBaseOfPath( cPath )
   LOCAL c := AllTrim( cPath )
   IF Rat( "\", c ) > 0
      c := SubStr( c, Rat( "\", c ) + 1 )
   ENDIF
   IF Rat( "/", c ) > 0
      c := SubStr( c, Rat( "/", c ) + 1 )
   ENDIF
   IF Rat( ".", c ) > 0
      c := Left( c, Rat( ".", c ) - 1 )
   ENDIF
RETURN Upper( c )

/* work area in which cFile is already open (0 if it is not).
 * The BASE NAME is compared (no path or extension), which is what makes the
 * file manager's <Enter> on an already open database ACTIVATE it instead of
 * trying to reopen it: in EXCLUSIVE mode a second USE of the same file fails
 * with "Open error" (measured). */
FUNCTION CoreAreaByFile( cFile )
   LOCAL aAreas := CoreAreas(), i, cBase := CoreBaseOfPath( cFile )
   FOR i := 1 TO Len( aAreas )
      IF CoreBaseOfPath( aAreas[ i ][ 3 ] ) == cBase
         RETURN aAreas[ i ][ 1 ]
      ENDIF
   NEXT
RETURN 0

/* extension of the memo file of the active database: the information block of the
 * F2 menu of the original shows "<driver> / <ext>" (measured: DBFCDX / DBT) */
FUNCTION CoreMemoExt()
   LOCAL c := "DBT"
   IF Used()
      BEGIN SEQUENCE WITH {| e | Break( e ) }
         IF hb_FNameExists( DBF() + ".FPT" )
            c := "FPT"
         ENDIF
      RECOVER
         c := "DBT"
      END SEQUENCE
   ENDIF
RETURN c

/* open the index of the current database by default (bag named like the database) */
FUNCTION CoreOrdList( cBag )
   LOCAL oErr, cBase
   DEFAULT cBag TO CoreFileBase()
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      ORDLISTADD( cBag )
   RECOVER USING oErr
      RETURN .F.
   END SEQUENCE
RETURN .T.

/* ---------- list of files of a directory ---------- */

FUNCTION CoreFiles( cSpec, cSub )
   LOCAL a := {}, cMask := cSpec, i
   DEFAULT cSub TO ""
   /* supports several ";*.EXT" */
   a := hb_DirScan( iif( Empty( s_cDir ), ".", s_cDir ), cMask )
   a := AClone( a )
RETURN a

/* ---------- status line ---------- */

/* bottom status line, in the style of the original:
 *   Directory: ...            Key: (order expression)            Driver: DBFCDX   */
FUNCTION CoreStatus()
   LOCAL nRow := MaxRow()
   /* bottom border of the original: "Directory: <dir>" in white on dark gray */
   SetColor( UI_C_STATUS )
   @ nRow, 0 SAY Space( MaxCol() + 1 )
   @ nRow, 0 SAY "Directory: " + s_cDir
   SetColor( UI_C_DESKTOP )
RETURN NIL

FUNCTION CoreApplySettings()
   Set( _SET_DELETED,  s_lHideDel )
   Set( _SET_SOFTSEEK, s_lSoftSeek )
   Set( _SET_EXCLUSIVE, ( s_cOpenMode == "EXCLUSIVE" ) )
   rddSetDefault( s_cDriver )
RETURN NIL

/* =======================================================================
 *  Field presentation: order, selection, lock and color
 * ======================================================================= */

FUNCTION BpRows()
RETURN MaxRow() - 2 - BP_ROW_TOP + 1    /* rows BP_ROW_TOP .. MaxRow()-2 */

FUNCTION CoreInitView()
   LOCAL i
   IF ! Used()
      RETURN .F.
   ENDIF
   s_aOrder := {}
   s_aSel   := {}
   FOR i := 1 TO FCount()
      AAdd( s_aOrder, i )
      AAdd( s_aSel, .T. )
   NEXT
   s_lShowSel := .F.
RETURN .T.

FUNCTION CoreFieldOrder()
   IF Empty( s_aOrder ) .AND. Used()
      CoreInitView()
   ENDIF
RETURN s_aOrder

FUNCTION CoreSelFields()
   IF Empty( s_aSel ) .AND. Used()
      CoreInitView()
   ENDIF
RETURN s_aSel

FUNCTION CoreShowSelected()      ; RETURN s_lShowSel
FUNCTION CoreSetShowSelected( l ) ; s_lShowSel := ( l == .T. ) ; RETURN s_lShowSel
FUNCTION CoreToggleShowSelected()
   s_lShowSel := ! s_lShowSel
RETURN s_lShowSel

FUNCTION CoreLockFields()        ; RETURN s_nLock
FUNCTION CoreSetLockFields( n )  ; s_nLock := Max( 0, Int( n ) ) ; RETURN s_nLock

FUNCTION CoreColorCond()         ; RETURN s_cColExpr
FUNCTION CoreSetColorCond( c )   ; s_cColExpr := c ; RETURN c
FUNCTION CoreColorColor()        ; RETURN s_cColColor
FUNCTION CoreSetColorColor( c )
   IF ! Empty( c )
      s_cColColor := c
   ENDIF
RETURN s_cColColor

FUNCTION CoreCutColumn( nPos )
   LOCAL nFld := 0
   IF nPos < 1 .OR. nPos > Len( s_aOrder )
      RETURN 0
   ENDIF
   nFld := s_aOrder[ nPos ]
   ADel( s_aOrder, nPos )
   ASize( s_aOrder, Len( s_aOrder ) - 1 )
RETURN nFld

FUNCTION CoreInsertColumn( nFld, nPos )
   IF nFld < 1 .OR. nFld > FCount()
      RETURN 0
   ENDIF
   IF nPos < 1 .OR. nPos > Len( s_aOrder ) + 1
      nPos := Len( s_aOrder ) + 1
   ENDIF
   /* ASize() FIRST: AIns() does not grow the array in this Harbour and without this
    * the last column of the view would be lost (see AGENTS.md 5.27) */
   ASize( s_aOrder, Len( s_aOrder ) + 1 )
   AIns( s_aOrder, nPos )
   s_aOrder[ nPos ] := nFld
RETURN nPos

/* cursor column in the browser (for the F4 information block) */
FUNCTION CoreSelCol()          ; RETURN s_nSelCol
FUNCTION CoreSetSelCol( n )    ; s_nSelCol := Max( 1, Int( n ) ) ; RETURN s_nSelCol

/* Effective view for the browser: aView[i] = { nField, cName, cType, nLen, nDec, nWidth } */
FUNCTION CoreView()
   LOCAL aSt, a := {}, i, n
   IF ! Used()
      RETURN a
   ENDIF
   CoreFieldOrder()
   aSt := DbStruct()
   FOR i := 1 TO Len( s_aOrder )
      n := s_aOrder[ i ]
      IF n >= 1 .AND. n <= Len( aSt )
         IF ! s_lShowSel .OR. n <= Len( s_aSel ) .AND. s_aSel[ n ]
            AAdd( a, { n, aSt[ n ][ 1 ], aSt[ n ][ 2 ], aSt[ n ][ 3 ], aSt[ n ][ 4 ], ;
                       CoreColumnWidth( aSt[ n ] ) } )
         ENDIF
      ENDIF
   NEXT
RETURN a

/* =======================================================================
 *  Record browser (main window of hwBro)
 * ======================================================================= */

FUNCTION CoreBrowse()
   LOCAL aView, nKey, nPos := 1, nTop := 1, i, nSel := 1, nRows
   LOCAL nLock, nCol1 := 0, nOldPos := 1, nOldTop := 1, nOldSel := 1
   LOCAL lFrame := .T., lRows := .T., lHead := .T., lCurRow := .F.
   LOCAL cBaseNow := "", aOrd, nOff := 0, nOrd := 0
   /* S69: the record search (Ctrl-F / Ctrl-Shift-F). nShift is the modifier
    * state of the key just read, cNote the answer of the last search and
    * nMsgPos/nMsgSel the record and column it belongs to. */
   LOCAL nShift := 0, cMode := "", cNote := "", lNote := .F.
   LOCAL cLast := "", cIn, aRes, nMsgPos := 0, nMsgSel := 0
   /* U1/U3: cAlt is the letter of an Alt+<key> shortcut, nClick the position of
    * a click in the record area and aPt the raw click.
    * S1/S2 (browse-edit-mouse.md): nWheel is the notches of this pass, lDbl the
    * double-click flag of this click, nSelAt the column the click picked and
    * aMv/aE the answers of the movement and edit helpers. */
   LOCAL cAlt := "", nClick := 0, aPt, nMenuAt
   LOCAL nWheel, lDbl, nSelAt, aMv, aE
   /* S5/S6 (browse-edit-mouse.md): aCtx is the press of the right button, cAct
    * the entry the context menu answered and cMenuMode the branch of the search
    * the menu enters (K_CTRL_F and K_END are the same code, so that action is
    * not faked as a key) */
   LOCAL aCtx, cAct, cMenuMode := ""
   /* the window hook of bp_win32.c is armed at the top of this procedure, but
    * the driver WINDOW only exists after the first paint: when the program starts
    * on a database (the file dropped on the executable or handed as the first
    * parameter, A6 of f2-dbmanager.md) this screen is entered before a single
    * cell was drawn, so the install fails and NOTHING re-arms it. lHook is the
    * state of that install and the loop below keeps retrying until it takes:
    * without the hook the session loses the clicks, the wheel and every Alt
    * chord (the ALT ring is fed by the same hook, so HcAltChord()/UiAltChord()
    * answer "" and the Alt shortcuts of the forms do nothing - reported on the
    * Append From form). */
   LOCAL lHook := .F.

   IF ! Used()
      RETURN NIL
   ENDIF
   IF Empty( s_aOrder )
      CoreInitView()
   ENDIF
   /* The browser draws its own cell cursor (green), so the SYSTEM caret must be
    * hidden here and not inherited: the file manager restores the previous state
    * on exit and the program starts with the caret visible, so the browser used
    * to run with it ON. UiPaintBegin/End hides it only while painting and then
    * restores it, so every repaint left a blinking caret where the last SAY of
    * the row-3 bar ended (reported: "a caret blinking next to <Softseek Off>"
    * after moving). CoreEditCell() shows it again while editing a cell and hides
    * it on exit, which is the only place where it belongs. */
   SetCursor( 0 )
   /* U3: the mouse. GTWVG of this Harbour delivers neither the clicks nor the
    * wheel through Inkey(), so bp_win32.c hooks the driver window and records
    * them; the hook is installed while THIS screen is on and removed on the way
    * out, exactly like the manager and the dot prompt do. Without this line a
    * click in the record area was simply not seen (measured). */
   CoreMouseHook( .T. )
   lHook := CoreMouseHookOn()
   /* A2 of f2-dbmanager.md: a flag left over from a previous session must never
    * make this one look as if it had closed its base on entry. */
   s_lCoreLeftByClose := .F.

   DO WHILE .T.
      /* S1/S4 of window-close.md (B3): the X of the window, once per pass. The
       * poll sits HERE, in the very check that already ends the loop, so the
       * browser leaves through its NORMAL exit -the EXIT below, which removes
       * the window hook at the end of the procedure- instead of unwinding in
       * the middle of a pass with the hook installed. BpCloseAsk() has already
       * raised the program's exit flag, so Main() ends the program after this
       * procedure returns, and no `Exit hwBro?` is asked (L7). */
      IF BpCloseAsk() .OR. BpExiting()
         EXIT
      ENDIF
      /* the window did not exist when this screen armed the hook: retry on the
       * passes of the loop while the hook reports 0, and only until it takes */
      IF ! lHook
         CoreMouseHook( .T. )
         lHook := CoreMouseHookOn()
      ENDIF
      IF ! Used()
         /* A2 of f2-dbmanager.md: the base was closed from a MENU of this screen
          * (`F2 > cLose Database` is an "R" row, so the menu stays open and the
          * Esc that follows is the menu's). That is NOT the user leaving the
          * manager: the flag is set and the caller shows its base-less face.
          * Leaving the screen with Esc takes the path above, which does not set
          * it. */
         s_lCoreLeftByClose := .T.
         EXIT
      ENDIF
      /* The F2/Alt-F2 menu opens the Harbour Commander file manager, which can
       * swap the database (or the work area) under us: the window position and
       * the column belong to the previous database, so rebuild both from
       * scratch when the base or the area changes. */
      IF ! ( iif( Used(), LTrim( Str( Select() ) ) + "|" + Upper( DBF() ), "" ) == cBaseNow )
         cBaseNow := iif( Used(), LTrim( Str( Select() ) ) + "|" + Upper( DBF() ), "" )
         nPos := 1 ; nTop := 1 ; nSel := 1
         /* S2: another database means the pending click pair is about records
          * that are no longer on screen */
         s_cClickId := ""
         GO TOP
         lFrame := .T.
      ENDIF
      aView := CoreView()
      nRows := BpRows()
      IF Empty( aView )
         aView := { { 0, "(no fields)", "C", 10, 0, 10 } }
      ENDIF
      nSel := Max( 1, Min( nSel, Len( aView ) ) )
      CoreSetSelCol( nSel )
      nLock := CoreLockN( aView )
      IF CoreCol1( aView, nSel ) != nCol1
         lRows := .T. ; lHead := .T.
         nCol1 := CoreCol1( aView, nSel )
      ENDIF

      /* S69: the answer of a search belongs to the record and the column where
       * it was produced (the same rule as the read-only browser): moving away
       * from them clears it. A key that changes NOTHING leaves it on screen, so
       * the answer does not vanish the moment it is given. */
      IF ! Empty( cNote ) .AND. ( nPos != nMsgPos .OR. nSel != nMsgSel )
         cNote := ""
         lNote := .T.
      ENDIF

      /* ---------------- repaint: only what has changed ---------------- */
      IF lFrame
         /* full screen, all at once (no flicker) */
         UiPaintBegin()
         CoreDrawFrame( aView, nTop, nPos, nSel, nRows, cNote )
         UiPaintEnd()
         lFrame := .F. ; lRows := .F. ; lHead := .F. ; lCurRow := .F. ; lNote := .F.
      ELSE
         IF lHead .OR. lRows .OR. nPos != nOldPos .OR. nSel != nOldSel .OR. lCurRow .OR. lNote
         UiPaintBegin()
         IF lHead
            CoreDrawHeader( aView, nSel, nLock, nCol1 )
            lHead := .F.
         ENDIF
         IF lRows
            CoreDrawRows( aView, nTop, nPos, nSel, nRows, nLock, nCol1, 1, nRows )
            lRows := .F.
         ELSEIF nPos != nOldPos
            IF nTop == nOldTop .AND. Abs( nPos - nOldPos ) == 1
               /* fast path (arrows): only two rows and without walking the window.
                * The pointer is on the current record, so the two rows are
                * painted moving with a single SKIP. */
               CoreDrawRow( nPos - nTop + 1, aView, nSel, nLock, nCol1, .T., CoreRowColor() )
               SKIP ( nOldPos - nPos )
               CoreDrawRow( nOldPos - nTop + 1, aView, nSel, nLock, nCol1, .F., CoreRowColor() )
               SKIP ( nPos - nOldPos )
            ELSE
               CoreDrawRows( aView, nTop, nPos, nSel, nRows, nLock, nCol1, 1, nRows )
            ENDIF
         ELSEIF nSel != nOldSel .OR. lCurRow
            /* the cell cursor moved to another column: the current row has to
             * be repainted so the green shading follows it (the pointer is
             * already on the current record) */
            CoreDrawRow( nPos - nTop + 1, aView, nSel, nLock, nCol1, .T., CoreRowColor() )
            lCurRow := .F.
         ENDIF
         IF nPos != nOldPos
            CoreDrawBars( nPos )
         ENDIF
         IF lNote
            /* only the `Key:` strip: the note is not worth a full repaint */
            CoreDrawKeyLine( cNote )
            lNote := .F.
         ENDIF
         UiPaintEnd()
         ENDIF
      ENDIF

      nOldPos := nPos ; nOldTop := nTop ; nOldSel := nSel
      /* U3: the loop waits 50 ms so the MOUSE can be polled (bp_win32.c records
       * the click and Main() hands it over through the UiSetClickHook() hook; it
       * never arrives through Inkey()). An idle click paints NOTHING: the paint
       * block below only runs when a flag is set. */
      nKey := Inkey( 0.05 )
      IF nKey == 0
         /* S1: the WHEEL of the record browser. One notch is one record, a
          * positive notch (the wheel turning away from the user) is the
          * PREVIOUS record and the clamps are the ones of the up and down keys,
          * because CoreWheelMove() walks those very helpers. Nothing else is
          * polled in this pass: the notches are already read and consumed. */
         nWheel := CoreMouseWheel()
         IF nWheel != 0
            aMv := CoreWheelMove( nWheel, nPos, nTop, nRows )
            nPos := aMv[ 1 ]
            nTop := aMv[ 2 ]
            LOOP
         ENDIF
         aPt := UiClick()
         IF HB_ISARRAY( aPt )
            /* S2: the double-click flag of the hook is read ONCE per click,
             * together with the cell (it clears itself when read), so it can
             * never stay pending for the click that comes next. */
            lDbl := CoreClickDbl()
            /* U2: a click on the MENU BAR opens that menu from HERE, because this
             * loop is the one polling the mouse: DoMenu() only starts after a
             * key has opened the menu, so it could never see the click that was
             * supposed to open it (measured: the click was swallowed). */
            BpLog( "CoreBrowse click=" + LTrim( Str( aPt[ 1 ] ) ) + "," + LTrim( Str( aPt[ 2 ] ) ) )
            nMenuAt := BpMenuBarAt( aPt[ 1 ], aPt[ 2 ] )
            IF nMenuAt > 0
               /* open that menu and come back: the same thing the F-key does
                * (the code of the key is NOT derived by arithmetic: K_F1 is 28
                * in this build, not -11). The position is resynced exactly like
                * the F7 case does: the entries move the record pointer and the
                * next repaint would undo it (trap 49). */
               DoMenu( nMenuAt )
               aOrd := CoreAfterMenu( nRows )
               nPos := aOrd[ 1 ]
               nTop := aOrd[ 2 ]
               s_cClickId := ""
               lFrame := .T.
               LOOP
            ELSE
               nClick := CoreClickWinPos( aPt[ 1 ], nTop, nRows )
               /* S2: the click also picks the COLUMN (the cells of the row are
                * the ones on screen, so the answer is a view index or 0) */
               nSelAt := CoreClickCol( aView, aPt[ 2 ], nLock, nCol1 )
               IF nClick > 0 .AND. CoreGotoPos( nClick )
                  nPos := nClick
                  IF nSelAt > 0
                     nSel := nSelAt
                  ENDIF
                  lRows := .T.
                  /* S2: a DOUBLE click on the SAME record and the SAME column
                   * edits that cell, through the very same helper Enter uses,
                   * so Cell Edit, the refusal of the memo
                   * fields and the resync after the edit cannot diverge. The
                   * pair is decided HERE because only Harbour knows the record
                   * and the column (the hook knows the row, trap 48). */
                  IF lDbl .AND. CoreClickPair( nPos, nSel, nTop )
                     /* the pair is spent: a third click does not edit again */
                     s_cClickId := ""
                     aE := CoreEditCellNow( aView, nSel, nPos, nTop, nRows, nLock, nCol1 )
                     nPos := aE[ 4 ]
                     nTop := aE[ 5 ]
                     IF aE[ 1 ]
                        lFrame := .T.
                     ENDIF
                     IF aE[ 2 ]
                        lRows := .T.
                     ENDIF
                     IF aE[ 3 ]
                        lCurRow := .T.
                     ENDIF
                  ELSE
                     CoreClickRemember( nPos, nSel, nTop )
                  ENDIF
                  LOOP
               ENDIF
            ENDIF
         ENDIF
         /* right-click-esc (S8 of right-click-esc.md): OUTSIDE the record grid
          * the right button did nothing at all, and out of the grid Esc closes
          * the base and goes back to the Harbour Commander, so a PLAIN right
          * click does the same. Two details make this exact:
          * (a) it can only fire when the WHOLE gesture is plain - the press AND
          * its release with no move in between -, so nothing happens on the
          * press alone (S3) and a drag never closes the base;
          * (b) the detector CONSUMES the cell of the press (AGENTS trap 65), so
          * "this gesture started outside the grid" is remembered here for the
          * pass that sees the release, and thrown away as soon as the arm is
          * gone (a drag, a lost capture) so a later click inside the grid can
          * never inherit it.
          * Asking it BEFORE CoreRightPress() is what leaves the record menu
          * below seeing only the presses that landed INSIDE the grid (S2). */
         IF nKey == 0
            IF ! s_lCtxRClickOutside .AND. CoreRightOutside( nTop, nRows )
               s_lCtxRClickOutside := .T.
            ENDIF
            IF s_lCtxRClickOutside
               IF HcMouseRightClick()
                  s_lCtxRClickOutside := .F.
                  nKey := K_ESC
               ELSEIF ! HcRClickArmed()
                  s_lCtxRClickOutside := .F.   /* it dragged, or the arm died */
               ENDIF
            ENDIF
         ENDIF
         /* S5/S6: the RIGHT button. In this screen it has no other use (the
          * manager spends the hold on its panel menu), so the menu opens on the
          * press ITSELF, with no 1 second wait. It opens on the record and the
          * column under the pointer, so the cursor moves there first (trap 42):
          * the menu is about THAT record, and an action on "the record of the
          * cursor" is then about the row the user pointed at. */
         aCtx := CoreRightPress()
         IF ! hb_IsNil( aCtx )
            nClick := CoreClickWinPos( aCtx[ 1 ], nTop, nRows )
            nSelAt := CoreClickCol( aView, aCtx[ 2 ], nLock, nCol1 )
            IF nClick > 0 .AND. CoreGotoPos( nClick )
               nPos := nClick
               IF nSelAt > 0
                  nSel := nSelAt
               ENDIF
               /* trap 42: the entries act on "the field of the cursor" and they
                * read that column through CoreSelCol(), which the loop refreshes
                * at its TOP - that is, BEFORE this press. It is refreshed here
                * too, or Copy Field / Paste Field would act on the column the
                * cursor had before the press (measured by the probe). */
               CoreSetSelCol( nSel )
               /* the chosen entry comes back as THE KEY of the browser, so the
                * DO CASE below - the only place where a key acts - runs it:
                * the menu and the keyboard cannot diverge */
               /* S6/L9: the two PASTE rows are only available when the
                * matching internal clipboard has something - Paste field needs
                * a previous Copy field and Paste Record a previous Copy
                * Record -, asked at the moment the menu is built. The messages
                * inside BpRecPasteField()/BpRecPasteRecord() stay as the last
                * line of defence. */
               cAct := HcCtxMenuRun( aCtx[ 1 ], aCtx[ 2 ], ;
                                     UiRecCtxItems( Deleted(), ;
                                                    ! hb_IsNIL( CoreClipField() ), ;
                                                    ! Empty( CoreClip() ) ) )
               nKey := UiRecCtxKey( cAct )
               s_cClickId := ""
               IF nKey == K_CTRL_F
                  /* Seek / Find: the search branch, exactly the one Ctrl-F
                   * enters. It cannot be entered with the KEY, because 6 is
                   * also K_END and DbfSearchMode() only answers for a stroke
                   * that carries the CTRL bit (measured), so the menu passes the
                   * mode in cMenuMode instead. */
                  cMenuMode := "FIELD"
                  nKey := 0
               ENDIF
               /* the whole screen is repainted: the menu may have restored the
                * rows it painted and the cursor may have moved to another
                * record or column */
               lRows := .T.
               IF nKey == 0 .AND. Empty( cMenuMode )
                  /* Esc or a click outside: nothing ran */
                  LOOP
               ENDIF
            ENDIF
         ENDIF
      ENDIF
      BpLog( "CoreBrowse: key=" + LTrim( Str( nKey ) ) + " nPos=" + LTrim( Str( nPos ) ) + ;
             " nTop=" + LTrim( Str( nTop ) ) + " rec=" + LTrim( Str( RecNo() ) ) )
      /* S2: any KEY breaks the pair of clicks (the user moved with the
       * keyboard), so a click after typing is never the second half of a double
       * click. */
      IF nKey != 0
         s_cClickId := ""
      ENDIF
      /* S69: the modifier state of the key just read, IMMEDIATELY after Inkey()
       * and before anything else touches the driver: K_CTRL_F and K_END are the
       * same key code (6) in this driver family and only this word tells them
       * apart (measured, see DbfSearchMode()). */
      nShift := HcShiftState()
      cMode := DbfSearchMode( nKey, nShift )
      /* S6: the entry `Seek / Find` of the context menu enters the search
       * branch of Ctrl-F (its key code is shared with End) */
      IF ! Empty( cMenuMode )
         cMode := cMenuMode
         cMenuMode := ""
      ENDIF
      /* U1: the letter of an Alt+<key> shortcut. Alt+Backspace is not a letter
       * and it carries the same ALT bit, so it is spelled out here. */
      cAlt := iif( nKey == K_BS .AND. CoreAltOnly( nShift ), "BS", ;
                   HcAltLetter( nKey, nShift ) )
      DO CASE
      CASE nKey == K_ESC
         /* <Esc>: back to Harbour Commander (the original asks `Exit BroPlus?`
          * here). The main loop re-enters the file manager, so the record and
          * screen row are rebuilt from zero there; nothing else to unwind. */
         CoreMouseHook( .F. )
         RETURN NIL
      CASE nKey == K_F1 ; DoMenu( 1 ) ; lFrame := .T.
      CASE nKey == K_F2 ; DoMenu( 2 ) ; lFrame := .T.
      CASE nKey == K_F3
         /* Choosing another tag in Tag Selection changes the order: the original
          * KEEPS the record and its screen row (measured: Rec. 69/400
          * after choosing another index). OrdSetFocus() leaves the pointer on the
          * first key, so it has to be repositioned. */
         nOff := nPos - nTop
         nOrd := CoreOrdNo()
         DoMenu( 3 )
         IF Used() .AND. CoreOrdNo() != nOrd
            aOrd := CoreReframe( nOff )
            nPos := aOrd[ 1 ] ; nTop := aOrd[ 2 ]
         ENDIF
         lFrame := .T.
      CASE nKey == K_F4 ; DoMenu( 4 ) ; lFrame := .T.
      CASE nKey == K_F5
         /* same with <Alt-U> Next Index Order of the AreaSet */
         nOff := nPos - nTop
         nOrd := CoreOrdNo()
         DoMenu( 5 )
         IF Used() .AND. CoreOrdNo() != nOrd
            aOrd := CoreReframe( nOff )
            nPos := aOrd[ 1 ] ; nTop := aOrd[ 2 ]
         ENDIF
         lFrame := .T.
      CASE nKey == K_F6 ; DoMenu( 6 ) ; lFrame := .T.
      CASE nKey == K_F7
         /* S71: EVERY action of the F7 menu moves the RECORD POINTER (Seek,
          * Goto, Locate, skip, Go Top, Go Bottom and the Append Record of the
          * menu). The browser keeps its own position in nPos/nTop, so it has
          * to be recomputed HERE: CoreDrawRows() starts with dbGoTop() +
          * SKIP nTop-1 and leaves the pointer back on nPos, so without this the
          * redraw undid the action before it could be seen (measured: Window
          * Top/Bottom and the four navigation entries looked dead).
          * Go Top pins the current record on the FIRST screen row and Go Bottom
          * on the LAST one; anything else centres it, like a search does. */
         DoMenu( 7 )
         aOrd := CoreAfterMenu( nRows )
         nPos := aOrd[ 1 ]
         nTop := aOrd[ 2 ]
         lFrame := .T.
      /* U1: the shortcuts the F7 menu advertises. They call the SAME functions
       * the menu runs, so the two paths can never diverge, and they resync the
       * same way (trap 49). Alt+<letter> arrives as the bare letter plus the
       * ALT bit (trap 37); AltGr is Ctrl+Alt and is rejected (trap 38).
       *
       *   Alt-S Seek   Alt-G Goto   Alt-U Locate   Alt-J Skip
       *   Alt-T Go Top Alt-B Go Bottom  Alt-A All Flds  Alt-E Sel. Flds
       *   Alt-BSpc Erase Memo
       */
      CASE ! Empty( cAlt ) .AND. ( cAlt $ "SGUJTBAE" .OR. cAlt == "BS" )
         DO CASE
         CASE cAlt == "S"  ; BpRecSeek()
         CASE cAlt == "G"  ; BpRecGoto()
         CASE cAlt == "U"  ; BpRecLocate()
         CASE cAlt == "J"  ; BpRecSkip()
         CASE cAlt == "T"  ; BpRecTop()
         CASE cAlt == "B"  ; BpRecBottom()
         CASE cAlt == "A"  ; BpRecViewAll()
         CASE cAlt == "E"  ; BpRecViewSelected()
         CASE cAlt == "BS" ; BpRecEraseMemo()
         ENDCASE
         /* the view may have changed (All/Selected Flds) and the record moved */
         nSel := Max( 1, Min( nSel, Len( CoreView() ) ) )
         aOrd := CorePosTotal()
         nPos := aOrd[ 1 ]
         nTop := CoreWindowTop( nPos, aOrd[ 2 ], nRows )
         lFrame := .T.
      CASE nKey == K_SH_F4   ; BpRecCopyField()  ; lFrame := .T.
      CASE nKey == K_CTRL_F4 ; BpRecPasteField() ; lFrame := .T.
      CASE nKey == K_SH_F7   ; BpRecCopyRecord() ; lFrame := .T.
      CASE nKey == K_CTRL_F7
         BpRecPasteRecord()
         IF Used()
            aOrd := CorePosTotal()
            nPos := aOrd[ 1 ]
            nTop := CoreWindowTop( nPos, aOrd[ 2 ], nRows )
         ENDIF
         lFrame := .T.
      CASE nKey == K_ALT_F7  ; BpRecViewClip()   ; lFrame := .T.
      /* S5/T3 of menu-accelerators.md: the GLOBAL accelerator map of the DB
       * manager, built from the shortcut texts of the menu rows. It is
       * dispatched HERE - after <Esc>, after the F-keys, after the F7 block and
       * after the copy/paste shortcuts that already worked - because those
       * keep their meaning (S6a) and because this way the map can never shadow
       * <Esc>, a menu, the arrow keys or the editor of a cell (that one runs in
       * its own loop anyway). The row runs the SAME block the menu runs
       * (BpAccelRun) with the cFlag discipline of BpNavOk(): a "D" row never
       * fires and an "I" row does. */
      CASE BpAccelRun( nKey, nShift )
         BpLog( "CoreBrowse accel" )
         /* an entry may have moved the record pointer (Next/Previous Database,
          * Next Order, a Select Area...) or changed the view, so the position
          * is recomputed exactly like the F7 branch does (trap 49): the repaint
          * would otherwise put the pointer back where it was */
         IF Used()
            nSel := Max( 1, Min( nSel, Len( CoreView() ) ) )
            aOrd := CoreAfterMenu( nRows )
            nPos := aOrd[ 1 ]
            nTop := aOrd[ 2 ]
         ENDIF
         lFrame := .T.
      CASE nKey == K_F8
         /* the Replace form of this menu may change the KEY of the order, so
          * the browser position is recomputed exactly like the F7 menu does
          * (trap 49): the drawing would otherwise put the pointer back */
         DoMenu( 8 )
         IF Used()
            aOrd := CoreAfterMenu( nRows )
            nPos := aOrd[ 1 ]
            nTop := aOrd[ 2 ]
         ENDIF
         lFrame := .T.
      CASE nKey == K_F9
         /* <F9> = dot prompt (it no longer exits the program; the exit is <Alt-X>).
          * The dot paints the whole screen and may change the area, the order,
          * the filter or the record, so on return EVERYTHING is repainted from
          * scratch. If the dot closed the database (<Esc> or USE/CLOSE) it goes back
          * to the desktop, like the rest of the exits. */
         nOff := nPos - nTop
         BpDot()
         IF ! Used()
            RETURN NIL
         ENDIF
         /* the dot may have changed the area/order/filter: the cursor is placed on
          * the SAME screen row it had (same pattern as the order change of
          * F3/F5) and the whole screen is repainted */
         aOrd := CoreReframe( nOff )
         nPos := aOrd[ 1 ] ; nTop := aOrd[ 2 ]
         nSel := Max( 1, Min( nSel, Len( CoreView() ) ) )
         lFrame := .T.
      CASE nKey == K_DOWN
         aMv := CoreMoveDown( nPos, nTop, nRows )
         nPos := aMv[ 1 ]
         nTop := aMv[ 2 ]
      CASE nKey == K_UP
         /* NOTE: Bof() is PHYSICAL. With an active index, the first key of the
          * order is not at the top of the file, so Bof() returns .F. and the
          * guard did not work: after stopping on the first row the "↑" kept
          * subtracting nPos and the bar even showed "Rec. -1". What counts is the
          * LOGICAL position (nPos). */
         aMv := CoreMoveUp( nPos, nTop )
         nPos := aMv[ 1 ]
         nTop := aMv[ 2 ]
      CASE nKey == K_PGDN
         /* one page: the screen row of the cursor is kept (like in the
          * original) moving the record and the window at the same time */
         FOR i := 1 TO nRows
            SKIP 1
            IF Eof()
               SKIP -1
               EXIT
            ENDIF
            nPos++
         NEXT
         nTop := Max( 1, nTop + ( nPos - nOldPos ) )
         lRows := .T.
      CASE nKey == K_PGUP
         FOR i := 1 TO nRows
            /* same reason as in K_UP: the top of the ORDER, not the physical one */
            IF nPos <= 1
               EXIT
            ENDIF
            SKIP -1
            IF Bof()
               SKIP 1
               EXIT
            ENDIF
            nPos--
         NEXT
         nTop := Max( 1, nTop + ( nPos - nOldPos ) )
         lRows := .T.
      CASE nKey == K_HOME
         dbGoTop() ; nPos := 1 ; nTop := 1 ; lRows := .T.
      /* --- S69: the SEARCH (Ctrl-F = this column, Ctrl-Shift-F = the whole
       * record). It MUST come before the K_END case below: K_CTRL_F and K_END
       * are the same key code (6) in this driver family, and a plain End still
       * falls through to its own case because DbfSearchMode() only answers for a
       * key that carries the CTRL bit (measured). F7/Shift-F7 are NOT search
       * keys here: F1..F8 are the menus of this screen. The read-only browser of
       * the manager has the same pair plus F7/Shift-F7, and both screens use the
       * same rule (DbfSearchMode()) and the same walk (DbfSearchRecords() and
       * DbfFindInFields() over DbfRecordText()), so they cannot diverge.
       * Searching only moves the pointer and the cell cursor: it never edits,
       * never marks and never writes (DbfSearchRecords() only SKIPs). */
      CASE ! Empty( cMode )
         cIn := UiInput( iif( cMode == "FIELD", "Find in this field:", "Find in the record:" ), ;
                         cLast, 40 )
         /* the dialog saved and restored the screen: repaint it whole */
         lFrame := .T.
         IF hb_IsNIL( cIn ) .OR. Len( AllTrim( cIn ) ) == 0
            /* Esc (NIL) or an empty query cancels: nothing moves */
            cNote := ""
         ELSE
            /* the last text is proposed again, so Enter searches the next one */
            cLast := cIn
            aRes := DbfSearchRecords( CoreSearchFld( aView ), cIn, ;
                                      iif( cMode == "FIELD", nSel, 0 ), nPos )
            IF aRes[ 1 ] == 0
               /* a NEGATIVE answer is a MODAL BOX: the note of the key line
                * (last row, cyan on dark grey) was too small to be read
                * (reported). Nothing moves and the note stays empty. */
               cNote := ""
               UiMsg( "Not found.", "hwBro" )
            ELSE
               nPos := aRes[ 1 ]
               nSel := aRes[ 2 ]
               cNote := aRes[ 3 ]
               /* the same window rule as the read-only browser: the match ends
                * up in the middle of the record area, always visible */
               nTop := Max( 1, nPos - Int( nRows / 2 ) )
               IF nPos > nTop + nRows - 1
                  nTop := Max( 1, nPos - nRows + 1 )
               ENDIF
               lHead := .T.
            ENDIF
            /* the note belongs to THIS record and column */
            nMsgPos := nPos ; nMsgSel := nSel
         ENDIF
      CASE nKey == K_END
         dbGoBottom()
         nPos := CorePosFromRec()      /* real position of the last one of the order */
         nTop := Max( 1, nPos - nRows + 1 )
         lRows := .T.
      CASE nKey == K_CTRL_PGUP
         /* the original: Ctrl-PgUp = beginning of the file (cursor on the 1st row) */
         dbGoTop() ; nPos := 1 ; nTop := 1 ; lRows := .T.
      CASE nKey == K_CTRL_PGDN
         /* the original: Ctrl-PgDn = end of the file (cursor on the last row) */
         dbGoBottom()
         nPos := CorePosFromRec()
         nTop := Max( 1, nPos - nRows + 1 )
         lRows := .T.
      CASE nKey == K_CTRL_HOME
         /* the original: Ctrl-Home = first column (does not change record) */
         nSel := 1 ; lHead := .T.
      CASE nKey == K_CTRL_END
         /* the original: Ctrl-End = last column (does not change record) */
         nSel := Len( aView ) ; lHead := .T.
      CASE nKey == K_RIGHT .OR. nKey == K_TAB
         nSel := Min( Len( aView ), nSel + 1 )
         lHead := .T.
      CASE nKey == K_LEFT .OR. nKey == K_SH_TAB
         nSel := Max( 1, nSel - 1 )
         lHead := .T.
      CASE nKey == K_ENTER
         /* S2: the body lives in CoreEditCellNow() because the DOUBLE CLICK of a
          * cell has to run exactly this path (Cell Edit, the
          * memo refusal and the resync of the window after the edit) */
         aE := CoreEditCellNow( aView, nSel, nPos, nTop, nRows, nLock, nCol1 )
         nPos := aE[ 4 ]
         nTop := aE[ 5 ]
         IF aE[ 1 ]
            lFrame := .T.
         ENDIF
         IF aE[ 2 ]
            lRows := .T.
         ENDIF
         IF aE[ 3 ]
            lCurRow := .T.
         ENDIF
      CASE nKey == K_INS
         IF CoreAppend()
            /* move to the new record (the last one of the order) */
            nPos := CorePosFromRec()
            IF nPos < nTop
               nTop := nPos
            ENDIF
            IF nPos > nTop + nRows - 1
               nTop := nPos - nRows + 1
            ENDIF
            IF nTop < 1
               nTop := 1
            ENDIF
         ENDIF
         lFrame := .T.
      CASE nKey == K_DEL
         /* S6: DELETE is reached from the Del key and from the `Delete record`
          * entry of the context menu - the entry comes back as this very key, so
          * the two paths cannot diverge.
          * D2/D3: the row must NOT move. With SET DELETED OFF (the default) the
          * key of the record does not change, so its position in the order does
          * not change either: nothing is recomputed and the cursor stays on the
          * very same screen row, which is what this screen did before (a
          * re-centring scroll of up to nRows/2 rows was the regression). With
          * SET DELETED ON the record LEAVES the order the moment it is marked and
          * it cannot be reached any more: RecNo() is not found by any walk (and
          * trap 18 forbids asking Bof()/Eof()/RecNo() whether a record is in the
          * order), so the position is KEPT and clamped to the new total - the
          * only case that pays an O(n) walk. An UNDELETE under SET DELETED ON
          * puts the record back into the order at its key position, so its
          * position is looked up again and the cursor keeps its SCREEN ROW. */
         CoreDeleteRecall()
         IF Used()
            IF CoreHideDel() .AND. Deleted()
               aOrd := CoreStayPos( nPos, nTop, nRows )
               nPos := aOrd[ 1 ]
               nTop := aOrd[ 2 ]
            ELSEIF CoreHideDel()
               aOrd := CoreReframe( nPos - nTop )
               nPos := aOrd[ 1 ]
               nTop := aOrd[ 2 ]
            ENDIF
         ENDIF
         lFrame := .T.
      ENDCASE
   ENDDO
   CoreMouseHook( .F. )
RETURN NIL

/* S69: the columns of the browser as the SHARED record search wants them:
 * { name, type, length, decimals, width, FIELD NUMBER }. The list is exactly
 * what the browser shows (the order, hidden fields and locks of CoreView()), so
 * a search only looks at the columns the user is looking at, and the answer is
 * an index into this same list - which is what the cell cursor nSel is. */
STATIC FUNCTION CoreSearchFld( aView )
   LOCAL a := {}, i
   FOR i := 1 TO Len( aView )
      AAdd( a, { aView[ i ][ 2 ], aView[ i ][ 3 ], aView[ i ][ 4 ], aView[ i ][ 5 ], ;
                 aView[ i ][ 6 ], aView[ i ][ 1 ] } )
   NEXT
RETURN a

/* active order number (0 if there is no index), error proof */
STATIC FUNCTION CoreOrdNo()
   LOCAL n := 0
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      n := OrdNumber()
   RECOVER
      n := 0
   END SEQUENCE
RETURN n

/* After changing the order: recompute the position of the current record and return
 * { nPos, nTop } so the cursor stays on the SAME screen row it
 * had (nOff = cursor row inside the window). */
STATIC FUNCTION CoreReframe( nOff )
   LOCAL nPos := CorePosFromRec()
RETURN { nPos, Max( 1, nPos - nOff ) }

/* position (inside the current order) of the record the pointer is on.
 * It leaves the pointer on that same record, as the repaint expects. */
STATIC FUNCTION CorePosFromRec()
   LOCAL n := 0, nRec := RecNo()
   dbGoTop()
   DO WHILE ! Eof()
      n++
      IF RecNo() == nRec
         EXIT
      ENDIF
      SKIP 1
   ENDDO
   IF Eof()
      IF n > 0
         SKIP -1
      ENDIF
   ENDIF
RETURN Max( 1, n )

/* S71: position of the current record inside the active order AND how many
 * records that order lists, in ONE walk. The browser needs both after an F7
 * action: the position to move its cursor and the total to pin the window on
 * the first/last screen row for Go Top / Go Bottom. The pointer is left on the
 * record the action left it on, which is what the repaint expects. */
STATIC FUNCTION CorePosTotal()
   LOCAL n := 0, nTotal := 0, nRec := RecNo(), nPos
   dbGoTop()
   DO WHILE ! Eof()
      nTotal++
      IF RecNo() == nRec
         n := nTotal
      ENDIF
      SKIP 1
   ENDDO
   nPos := iif( n > 0, n, Max( 1, nTotal ) )
   IF nTotal > 0
      dbGoTop()
      SKIP ( nPos - 1 )
      IF Eof()
         SKIP -1
      ENDIF
   ENDIF
RETURN { nPos, nTotal }

/* U2/S71: after a menu has been used (the F7 key, or any menu opened with a
 * click) the record pointer may be somewhere else and the browser keeps its own
 * position, so both are recomputed here (trap 49). Answer { nPos, nTop }. */
STATIC FUNCTION CoreAfterMenu( nRows )
   LOCAL a := { 1, 1 }
   IF Used()
      a := CorePosTotal()
      a := { a[ 1 ], CoreWindowTop( a[ 1 ], a[ 2 ], nRows ) }
   ENDIF
RETURN a

/* U3: install or remove the window hook of bp_win32.c, the one that records the
 * mouse for this program (GTWVG does not deliver it). Guarded so a build without
 * the C extension still links. */
STATIC FUNCTION CoreMouseHook( lOn )
   LOCAL lOk := .F.
   IF hb_IsFunction( "DotMouseHook" )
      lOk := DotMouseHook( lOn )
   ENDIF
RETURN lOk

/* Is the hook of bp_win32.c really installed? W32MOUSEHOOKON() answers a NUMBER,
 * so the comparison is explicit (traps 59 and 73). Guarded like CoreMouseHook()
 * so a build without the C extension still links and answers .F., which keeps
 * the retry of CoreBrowse() harmless there. */
STATIC FUNCTION CoreMouseHookOn()
   LOCAL l := .F.
   IF hb_IsFunction( "W32MOUSEHOOKON" )
      IF W32MOUSEHOOKON() != 0
         l := .T.
      ENDIF
   ENDIF
RETURN l

/* S1 (browse-edit-mouse.md): the notches accumulated by the window hook of
 * bp_win32.c, which ZEROES the counter when it is read. A positive notch is the
 * wheel turning away from the user (up). Guarded like CoreMouseHook() so a build
 * without the C extension still links, and it answers a NUMBER, so every caller
 * has to compare it explicitly (trap 59). */
STATIC FUNCTION CoreMouseWheel()
   LOCAL n := 0
   IF hb_IsFunction( "DotMouseWheel" )
      n := DotMouseWheel()
   ENDIF
RETURN n

/* S2: the double-click flag of the click that has just been handed over. It is
 * read ONCE per click (the native clears it), so the caller reads it together
 * with the cell and never leaves it pending for the next click. */
STATIC FUNCTION CoreClickDbl()
   LOCAL l := .F.
   IF hb_IsFunction( "W32CLICKDBL" )
      l := W32CLICKDBL()
   ENDIF
RETURN l

/* S5/S6 of browse-edit-mouse.md: the press of the RIGHT button waiting in the
 * channel of bp_win32.c, as { row, col } of the canvas, or NIL when there is
 * none. The whole gesture is consumed (its moves and its release, so they can
 * never leak into the next click) and the press is FORGOTTEN at once: those
 * getters keep the cell when they are read, so without the reset the menu would
 * open again on every idle pass (trap 65).
 *
 * The wrappers are the ones of bp_hc.prg (HcCtxRight*), the same channel the
 * manager and the text editor use, and they answer "nothing" in a build
 * without the window hook. */
/* A2 of f2-dbmanager.md: .T. when the browser left because its last base was
 * CLOSED from one of its menus (not because the user pressed Esc). One-shot, so
 * a stale flag can never open the manager on its own; the browser also clears it
 * when it is entered. */
FUNCTION CoreLeftByClosing()
   LOCAL l := s_lCoreLeftByClose
   s_lCoreLeftByClose := .F.
RETURN l

/* S8 of right-click-esc.md: TRUE when the LAST right gesture started OUTSIDE
 * the record grid, that is, when a plain right click there has to mean Esc. The
 * cell getters of bp_hc.prg are a PEEK (they do not clear), so asking here does
 * not disturb the record menu below. */
STATIC FUNCTION CoreRightOutside( nTop, nRows )
   LOCAL nR := HcCtxRightRow(), nC := HcCtxRightCol()
   IF nR < 0 .OR. nC < 0
      RETURN .F.
   ENDIF
RETURN ( CoreClickWinPos( nR, nTop, nRows ) <= 0 )

STATIC FUNCTION CoreRightPress()
   LOCAL nR, nC, lUp, aPt
   nR := HcCtxRightRow()
   nC := HcCtxRightCol()
   IF nR < 0 .OR. nC < 0
      RETURN NIL
   ENDIF
   DO WHILE HcCtxRightStep()
   ENDDO
   lUp := HcCtxRightUp()
   HcCtxRightReset()
   /* a LEFT click left unread belongs to whatever was on screen before the
    * press (the cell being edited does not read that channel at all): it is
    * drained here or the box would act on it the moment it paints */
   aPt := UiClick()
RETURN { nR, nC }

/* S5 of browse-edit-mouse.md: the TEXT menu of the cell being edited - the very
 * three entries of the text editor (HcTextCtxItems() of bp_hc.prg), opened by
 * the RIGHT button. It answers the clipboard chord the choice stands for the way
 * UiClipChord() does - 1 = copy, 2 = paste, 3 = cut - and 0 when the menu was
 * not opened or was closed without a choice, so the clipboard of the cell is
 * touched in ONE place (the block that already serves Ctrl-C / Ctrl-X /
 * Shift-Insert). */
STATIC FUNCTION CoreTextCtxChord()
   LOCAL aCtx, nKey
   aCtx := CoreRightPress()
   IF hb_IsNil( aCtx )
      RETURN 0
   ENDIF
   nKey := HcTextCtxKey( HcCtxMenuRun( aCtx[ 1 ], aCtx[ 2 ], HcTextCtxItems() ) )
   DO CASE
   CASE nKey == K_CTRL_C ; RETURN 1
   CASE nKey == K_CTRL_V ; RETURN 2
   CASE nKey == K_CTRL_X ; RETURN 3
   ENDCASE
RETURN 0

/* S1: the body of the up key as ONE helper, so the wheel cannot drift from the
 * key. nPos is the LOGICAL position: Bof() is physical and does not tell the top
 * of the ORDER (trap 18), which is what keeps this screen from showing
 * "Rec. -1". Answers the new { nPos, nTop }. */
STATIC FUNCTION CoreMoveUp( nPos, nTop )
   IF nPos > 1
      SKIP -1
      IF Bof()
         SKIP 1
      ELSE
         nPos--
         IF nPos < nTop
            nTop := nPos
         ENDIF
      ENDIF
   ENDIF
RETURN { nPos, nTop }

/* S1: the body of the down key (the window follows the cursor when it walks out
 * of the last visible row). Answers the new { nPos, nTop }. */
STATIC FUNCTION CoreMoveDown( nPos, nTop, nRows )
   DEFAULT nRows TO 1
   SKIP 1
   IF Eof()
      SKIP -1
   ELSE
      nPos++
      IF nPos > nTop + nRows - 1
         nTop := nPos - nRows + 1
      ENDIF
   ENDIF
RETURN { nPos, nTop }

/* S1: the wheel walks ONE RECORD PER NOTCH through the same helpers the keys
 * use, so the clamps of the first and the last record of the order are the ones
 * of the keyboard and a fast spin can never run past them. A positive notch is
 * the previous record. Answers { nPos, nTop }. */
STATIC FUNCTION CoreWheelMove( nNotch, nPos, nTop, nRows )
   LOCAL i, a
   DEFAULT nRows TO 1
   IF ValType( nNotch ) != "N" .OR. nNotch == 0
      RETURN { nPos, nTop }
   ENDIF
   FOR i := 1 TO Min( Abs( nNotch ), 1000 )
      DO CASE
      CASE nNotch > 0
         a := CoreMoveUp( nPos, nTop )
      CASE nNotch < 0
         a := CoreMoveDown( nPos, nTop, nRows )
      ENDCASE
      nPos := a[ 1 ]
      nTop := a[ 2 ]
   NEXT
RETURN { nPos, nTop }

/* S2: the VIEW column whose cells cover the canvas column nCol, built from the
 * columns that are VISIBLE in the current window - the same walk as
 * CoreCellGeom() and CoreDrawRow(): BP_COL_BASE, the width of the column and 3
 * cells of step. The gap between two columns belongs to the column on its left
 * (UiColAtX()), so a click on a separator moves the cursor one column at most.
 * Answers 0 when the click is not on the cells of the row and the caller then
 * keeps the column it had. */
STATIC FUNCTION CoreClickCol( aView, nCol, nLock, nCol1 )
   LOCAL aW := {}, aIdx := {}, i, nUsedW := 0, n
   FOR i := 1 TO Len( aView )
      IF ! CoreColVis( i, nLock, nCol1 )
         LOOP
      ENDIF
      IF BP_COL_BASE + nUsedW + aView[ i ][ 6 ] - 1 > MaxCol()
         EXIT
      ENDIF
      AAdd( aW, aView[ i ][ 6 ] )
      AAdd( aIdx, i )
      nUsedW += aView[ i ][ 6 ] + 3
   NEXT
   n := UiColAtX( aW, nCol, BP_COL_BASE, 3 )
   IF n < 1 .OR. n > Len( aIdx )
      RETURN 0
   ENDIF
RETURN aIdx[ n ]

/* S2: identity of the base and the order on screen. The click pair of a double
 * click is only valid while it does not change: the same screen can swap the
 * database from the F2 menu or the base list of the dot prompt. OrdName() needs
 * a work area, so it is guarded (trap 29). */
STATIC FUNCTION CoreBrowseId()
   LOCAL c := ""
   IF Used()
      c := LTrim( Str( Select() ) ) + "|" + Upper( DBF() )
      BEGIN SEQUENCE WITH {| e | Break( e ) }
         c += "|" + OrdName()
      RECOVER
         c += "|"
      END SEQUENCE
   ENDIF
RETURN c

/* S2: remember the click that can be the FIRST half of a double click */
STATIC FUNCTION CoreClickRemember( nPos, nSel, nTop )
   s_cClickId  := CoreBrowseId()
   s_nClickPos := nPos
   s_nClickSel := nSel
   s_nClickTop := nTop
RETURN NIL

/* S2: .T. when this click repeats the one remembered: SAME base and order, SAME
 * record position, SAME column and SAME window. Two clicks on another record or
 * on another column are NOT a double click, which is what the window hook alone
 * cannot tell (it only knows the screen row, trap 48). */
STATIC FUNCTION CoreClickPair( nPos, nSel, nTop )
   IF Empty( s_cClickId ) .OR. ! ( s_cClickId == CoreBrowseId() )
      RETURN .F.
   ENDIF
RETURN s_nClickPos == nPos .AND. s_nClickSel == nSel .AND. s_nClickTop == nTop

/* S71: the window row for a record at nPos of an order of nTotal records: the
 * first record goes on the FIRST screen row, the last one on the LAST row and
 * anything else is centred, always inside the window. */
STATIC FUNCTION CoreWindowTop( nPos, nTotal, nRows )
   LOCAL nTop
   IF nPos <= 1
      RETURN 1
   ENDIF
   IF nTotal > 0 .AND. nPos >= nTotal
      RETURN Max( 1, nPos - nRows + 1 )
   ENDIF
   nTop := Max( 1, nPos - Int( nRows / 2 ) )
   IF nPos > nTop + nRows - 1
      nTop := Max( 1, nPos - nRows + 1 )
   ENDIF
RETURN nTop

/* S6/D3 (browse-edit-mouse.md): where the browser stays after a Del that took
 * the current record OUT of the active order (SET DELETED ON and the record has
 * just been marked). The record cannot be reached any more, so its position is
 * KEPT and only CLAMPED to what the order still lists: the cursor does not jump
 * to the last record (CorePosTotal() could not find RecNo() and fell back to the
 * total, which was the bug) and it does not re-centre the window either. The
 * window keeps its first row unless the order has shrunk under it. Answers
 * { nPos, nTop } with the pointer PLACED on that position, because the walk has
 * left it at the end of the order.
 *
 * Only this case pays the walk: with SET DELETED OFF the record keeps its key
 * and therefore its position, so the caller does not call this at all. */
STATIC FUNCTION CoreStayPos( nPos, nTop, nRows )
   LOCAL nTotal := 0
   dbGoTop()
   DO WHILE ! Eof()
      nTotal++
      SKIP 1
   ENDDO
   nPos := Max( 1, Min( nPos, Max( 1, nTotal ) ) )
   nTop := Max( 1, Min( nTop, Max( 1, nTotal - nRows + 1 ) ) )
   IF nTotal > 0
      CoreGotoPos( nPos )
   ENDIF
RETURN { nPos, nTop }

/* U3: position of the record under a click in the record area, or 0 when the
 * click is not on one of the rows of the window. */
STATIC FUNCTION CoreClickWinPos( nRow, nTop, nRows )
   IF ValType( nRow ) != "N"
      RETURN 0
   ENDIF
   IF nRow < BP_ROW_TOP .OR. nRow > BP_ROW_TOP + nRows - 1
      RETURN 0
   ENDIF
RETURN nTop + ( nRow - BP_ROW_TOP )

/* put the pointer on the nPos-th record of the active order; .F. when that
 * position does not exist (the caller keeps its own position). The pointer is
 * left where the caller expects it: on that record, or back at the end. */
STATIC FUNCTION CoreGotoPos( nPos )
   LOCAL l := .T.
   IF ValType( nPos ) != "N" .OR. nPos < 1
      RETURN .F.
   ENDIF
   dbGoTop()
   SKIP ( nPos - 1 )
   IF Eof()
      SKIP -1
      l := .F.
   ENDIF
RETURN l

/* U1: ALT held and CTRL NOT held in a key state word (AltGr is Ctrl+Alt on a
 * Spanish keyboard, trap 38: it is NOT Alt). */
STATIC FUNCTION CoreAltOnly( nShift )
   IF ValType( nShift ) != "N"
      RETURN .F.
   ENDIF
RETURN hb_bitAnd( nShift, HB_GTI_KBD_ALT ) != 0 .AND. ;
       hb_bitAnd( nShift, HB_GTI_KBD_CTRL ) == 0

/* does the current order key use this field? */
STATIC FUNCTION CoreKeyHas( cName )
   LOCAL c := Upper( CoreKeyExpr() )
RETURN ! Empty( c ) .AND. Upper( cName ) $ c

STATIC FUNCTION CoreColumnWidth( aFld )
   LOCAL cName := aFld[ 1 ], nLen := aFld[ 3 ]
   DO CASE
   /* S12/T10 (globalset-date-format.md): a Date column keeps its HISTORICAL ten
    * cells with every picture -HEAD already had `nLen := 10`- because a column
    * that grows or shrinks with the format moves the whole grid nobody asked to
    * move. The picture decides only the buffer, the mask and the painted value
    * of the cell, which are CoreValW() below (S8).
    * This is the ONLY place the grid builds its widths (CoreView() feeds
    * aView[i][6]), so the headers, the click resolution, CoreCellGeom() and the
    * row painter follow from here. The two rules live in bp_ui.prg so the
    * headless bank can assert them. */
   CASE aFld[ 2 ] == "D" ; nLen := UiDateColWidth( nLen )
   CASE aFld[ 2 ] == "N" ; nLen := Max( nLen, 6 )
   CASE aFld[ 2 ] == "L" ; nLen := 4
   CASE aFld[ 2 ] == "M" ; nLen := 6
   ENDCASE
   /* the original does not cut at 30: the width is the larger of the field
    * name and its length (so CLI_NOMBRE, length 35, takes 35) */
RETURN Max( 1, Max( Len( cName ), nLen ) )

/* S8 of globalset-date-format.md: how many cells the VALUE of a field needs on
 * screen. It is the field length for every type except Date, whose .DBF field is
 * 8 bytes while the picture in force can print ten: the row painter and the cell
 * of the Browse edit pad and truncate to THIS width, never to the field length,
 * or the red row of a Date shown as "11/17/2026" would print "11/17/20".
 * It takes the two values and not a row of the view, because the two shapes in
 * play (DbStruct() { name, type, len, dec } and the view
 * { nField, name, type, len, dec, width }) do not put them in the same
 * positions. The COLUMN of a Date is a different rule and stays at its
 * historical ten cells (S12/T10): UiDateColWidth() in CoreColumnWidth(). */
STATIC FUNCTION CoreValW( cType, nLen )
   IF cType == "D"
      RETURN UiDateValWidth( nLen )
   ENDIF
RETURN nLen

/* =======================================================================
 *  Browser drawing, piece by piece (to repaint only what changes)
 * ======================================================================= */

/* number of effective fixed columns */
STATIC FUNCTION CoreLockN( aView )
RETURN Min( CoreLockFields(), Len( aView ) )

/* first column of the scrollable window */
STATIC FUNCTION CoreCol1( aView, nSel )
   LOCAL nLock := CoreLockN( aView ), nCol1 := nLock + 1, nUsedW := 0, i, nW
   LOCAL nAvail := MaxCol() + 1 - BP_COL_BASE
   FOR i := 1 TO nLock
      nUsedW += aView[ i ][ 6 ] + 3
   NEXT
   DO WHILE nCol1 <= nSel
      nW := 0
      FOR i := nCol1 TO nSel
         nW += aView[ i ][ 6 ] + 3
      NEXT
      IF nW > nAvail - nUsedW
         nCol1++
      ELSE
         EXIT
      ENDIF
   ENDDO
   IF nCol1 < nLock + 1
      nCol1 := nLock + 1
   ENDIF
RETURN nCol1

/* is column i visible with the current window */
STATIC FUNCTION CoreColVis( i, nLock, nCol1 )
RETURN ( i <= nLock .OR. i >= nCol1 )

/* row 3: cyan bars (counter, lock, mode, softseek, deleted). The original
 * draws 5 cyan "chips" with black letters on the gray background.
 *
 * On the 120-wide canvas the chips are DISTRIBUTED across the whole row with
 * even gaps instead of sitting in the five fixed columns measured on the 80
 * column original: left-anchored they left 65 empty cells after the last one.
 * The distribution is computed from the sum of the chip widths, so it also
 * works if a chip grows ("Rec. 1020098/1020098") or the canvas shrinks. */
STATIC FUNCTION CoreDrawBars( nPos )
   LOCAL aT, aW, i, nUsed := 0, nGapTot, nBase, nExtra, nCol
   LOCAL nMargin := 2, nSlotW := Len( "<DELETED>" )
   /* the bar shows the RECORD NUMBER, not the position in the order: that is what
    * the original does (measured: after changing the order it still says Rec. 69/400
    * even though the position in the new order is different). The MODE chip shows
    * the REAL mode of the active area, not the setting (otherwise, opening SHARED
    * with the setting in EXCLUSIVE made the bar lie).
    * CAREFUL: no multi-line comment INSIDE this array literal: Harbour does not
    * accept it in an expression continued with ";" (measured: E0020). */
   aT := { "Rec. " + LTrim( Str( RecNo() ) ) + "/" + LTrim( Str( LastRec() ) ), ;
           "<Lock: " + LTrim( Str( CoreLockFields() ) ) + ">", ;
           "<" + CoreModeName() + ">", ;
           iif( CoreSoftSeek(), "<Softseek On>", "<Softseek Off>" ), ;
           iif( Deleted(), "<DELETED>", iif( CoreHideDel(), "<HidDel>", "" ) ) }
   /* The LAST SLOT IS ALWAYS RESERVED, even when it prints nothing: that keeps the
    * other four chips in the SAME columns no matter what happens (reported: adding
    * <DELETED> moved them around, which made the bar harder to read). An empty slot
    * is not painted at all, so it does not leave a cyan chip behind; it only takes
    * part in the width computation. <DELETED> sets the reserved width (9 cells). */
   aW := {}
   FOR i := 1 TO Len( aT )
      AAdd( aW, iif( Empty( aT[ i ] ), nSlotW, Len( aT[ i ] ) ) )
      nUsed += aW[ i ]
   NEXT
   SetColor( UI_C_DESKTOP )
   @ BP_ROW_BARS, 0 SAY Space( MaxCol() + 1 )
   /* even gaps that leave the SAME margin on both sides: the leftover cells go
    * to the first gaps, so the last chip never crowds the right edge (measured:
    * with a plain Int() gap it ended 22 px from the left margin and only 8 px
    * from the right border when the division happened to be exact). */
   nGapTot := UiCols() - 2 * nMargin - nUsed
   nBase := Int( nGapTot / ( Len( aT ) - 1 ) )
   nExtra := nGapTot - nBase * ( Len( aT ) - 1 )
   IF nBase < 1
      nBase := 1 ; nExtra := 0
   ENDIF
   SetColor( UI_C_CHIP )
   nCol := nMargin
   FOR i := 1 TO Len( aT )
      /* never start a chip that would be cut by the right edge: the later ones
       * are simply dropped (a narrow canvas keeps the important ones first) */
      IF nCol + aW[ i ] > UiCols() - nMargin
         EXIT
      ENDIF
      IF ! Empty( aT[ i ] )
         @ BP_ROW_BARS, nCol SAY aT[ i ]
      ENDIF
      nCol += aW[ i ] + nBase + iif( i <= nExtra, 1, 0 )
   NEXT
   SetColor( UI_C_DESKTOP )
RETURN NIL

/* row 2: title (FILE name + order) like the original: white strip
 * with the title in a black box with white letters, centered. NOTE: the original
 * uses the file name, NOT the alias (measured after renaming the alias: the
 * title still reads "CLIENTES Order CLIENTES"). */
STATIC FUNCTION CoreDrawTitle()
   LOCAL cName := iif( Empty( CoreFileName() ), Alias(), CoreFileBase() )
   LOCAL cT := " " + Upper( cName ) + iif( Empty( OrdName() ), "", " Order " + OrdName() ) + " "
   SetColor( UI_C_TITLEBAR )
   @ BP_ROW_TITLE, 0 SAY Replicate( Chr( 219 ), MaxCol() + 1 )
   @ BP_ROW_TITLE, Max( 0, Int( ( MaxCol() + 1 - Len( cT ) ) / 2 ) ) SAY cT
   SetColor( UI_C_DESKTOP )
RETURN NIL

/* rows 4-6 of the browser: single horizontal line, column headers and
 * double horizontal line, exactly like the original BRO.EXE. The headers
 * are black on gray (the original does not highlight the active column). */
STATIC FUNCTION CoreDrawHeader( aView, nSel, nLock, nCol1 )
   LOCAL i, nUsedW := 0, nClr

   /* single horizontal line over the headers */
   SetColor( UI_C_DESKTOP )
   @ BP_ROW_LINE1, 0 SAY Replicate( BP_LINE_SINGLE, MaxCol() + 1 )

   /* clear the WHOLE header row: when scrolling the window horizontally
    * the columns change place and if it is not erased, remains of the previous
    * text stay in the gaps between columns */
   SetColor( UI_C_HDR )
   @ BP_ROW_HDR, 0 SAY Space( MaxCol() + 1 )

   FOR i := 1 TO Len( aView )
      IF ! CoreColVis( i, nLock, nCol1 )
         LOOP
      ENDIF
      IF BP_COL_BASE + nUsedW + aView[ i ][ 6 ] - 1 > MaxCol()
         EXIT
      ENDIF
      SetColor( UI_C_HDR )
      @ BP_ROW_HDR, BP_COL_BASE + nUsedW SAY PadR( Left( aView[ i ][ 2 ], aView[ i ][ 6 ] ), aView[ i ][ 6 ] )
      nUsedW += aView[ i ][ 6 ] + 3
   NEXT
   /* clear what is left over of the row */
   SetColor( UI_C_DESKTOP )
   nClr := Max( 0, BP_COL_BASE + nUsedW - 3 )
   IF nClr <= MaxCol()
      @ BP_ROW_HDR, nClr SAY Space( MaxCol() - nClr + 1 )
   ENDIF

   /* double horizontal line under the headers */
   SetColor( UI_C_DESKTOP )
   @ BP_ROW_LINE2, 0 SAY Replicate( BP_LINE_DOUBLE, MaxCol() + 1 )
   SetColor( UI_C_DESKTOP )
RETURN NIL

/* vertical separators │ between the visible columns. The one of the
 * first visible column is not drawn (same as the original). */
STATIC FUNCTION CoreDrawSep( nRowScr, aView, nLock, nCol1 )
   LOCAL i, nUsedW := 0, lFirst := .T.
   SetColor( UI_C_DESKTOP )
   FOR i := 1 TO Len( aView )
      IF ! CoreColVis( i, nLock, nCol1 )
         LOOP
      ENDIF
      IF BP_COL_BASE + nUsedW + aView[ i ][ 6 ] - 1 > MaxCol()
         EXIT
      ENDIF
      IF ! lFirst
         @ nRowScr, BP_COL_BASE + nUsedW - 2 SAY BP_SEP_VERT
      ENDIF
      lFirst := .F.
      nUsedW += aView[ i ][ 6 ] + 3
   NEXT
RETURN NIL

/* one record row (nRow = 1..nRows inside the window) */
STATIC FUNCTION CoreDrawRow( nRow, aView, nSel, nLock, nCol1, lCur, cRowClr )
   LOCAL nUsedW := 0, i, cTxt, nRowScr := BP_ROW_TOP + nRow - 1, nSeg

   /* clear the row with the desktop color: the gaps between columns and
    * the remains of the cells stay gray, as in the original */
   SetColor( UI_C_DESKTOP )
   @ nRowScr, 0 SAY Space( MaxCol() + 1 )

   FOR i := 1 TO Len( aView )
      IF ! CoreColVis( i, nLock, nCol1 )
         LOOP
      ENDIF
      IF BP_COL_BASE + nUsedW + aView[ i ][ 6 ] - 1 > MaxCol()
         EXIT
      ENDIF
      IF aView[ i ][ 1 ] > 0
         cTxt := UiValToStr( FieldGet( aView[ i ][ 1 ] ), aView[ i ][ 3 ], aView[ i ][ 4 ], aView[ i ][ 5 ] )
      ELSE
         cTxt := ""
      ENDIF
      IF lCur
         /* current record: RED background with white letters, and the column of the
          * cursor in GREEN with black letters. The highlighted width is the LENGTH of the
          * field (not the column width), like the original - except in a Date
          * column, whose length follows the picture in force (S8): the value is
          * printed with Len( DToC( Date() ) ) cells, so highlighting the 8 of the
          * field would TRUNCATE the ten-cell date on the red row. */
         nSeg := Min( CoreValW( aView[ i ][ 3 ], aView[ i ][ 4 ] ), aView[ i ][ 6 ] )
         IF nSeg < 1
            nSeg := 1
         ENDIF
         SetColor( iif( i == nSel, UI_C_CURSEL, UI_C_RECSEL ) )
         @ nRowScr, BP_COL_BASE + nUsedW SAY PadR( Left( cTxt, nSeg ), nSeg )
      ELSE
         /* a record marked as deleted is drawn DIM so the mark is visible: with
          * SET DELETED OFF the row used to stay identical to a live one, which
          * was reported as "the marker is not updated". Deleted() is valid here
          * because the caller leaves the pointer ON the row it is painting. */
         SetColor( iif( Deleted(), UI_C_RECDEL, cRowClr ) )
         @ nRowScr, BP_COL_BASE + nUsedW SAY PadR( Left( cTxt, aView[ i ][ 6 ] ), aView[ i ][ 6 ] )
      ENDIF
      nUsedW += aView[ i ][ 6 ] + 3
   NEXT

   /* vertical separators between columns, over the color of the row */
   CoreDrawSep( nRowScr, aView, nLock, nCol1 )

   SetColor( UI_C_DESKTOP )
RETURN NIL

/* empty row (when there are fewer records than rows) */
STATIC FUNCTION CoreDrawBlankRow( nRow, aView, nLock, nCol1 )
   LOCAL nRowScr := BP_ROW_TOP + nRow - 1
   SetColor( UI_C_REC )
   @ nRowScr, 0 SAY Space( MaxCol() + 1 )
   CoreDrawSep( nRowScr, aView, nLock, nCol1 )
   SetColor( UI_C_DESKTOP )
RETURN NIL

/* row color according to the color condition (AreaSet) */
STATIC FUNCTION CoreRowColor()
   LOCAL lCond := .F.
   IF ! Empty( CoreColorCond() )
      BEGIN SEQUENCE WITH { | e | Break( e ) }
         lCond := &( CoreColorCond() )
      RECOVER
         lCond := .F.
      END SEQUENCE
   ENDIF
RETURN iif( lCond, CoreColorColor(), UI_C_REC )

/* record rows [nFrom..nTo]; leaves the pointer on the current record (nPos) */
STATIC FUNCTION CoreDrawRows( aView, nTop, nPos, nSel, nRows, nLock, nCol1, nFrom, nTo )
   LOCAL nRow, nDrawn := 0, nCur, cRowClr

   dbGoTop()
   SKIP ( nTop - 1 )
   FOR nRow := 1 TO nRows
      IF Eof()
         EXIT
      ENDIF
      nDrawn++
      IF nRow >= nFrom .AND. nRow <= nTo
         cRowClr := CoreRowColor()
         CoreDrawRow( nRow, aView, nSel, nLock, nCol1, ( nTop + nRow - 1 == nPos ), cRowClr )
      ENDIF
      SKIP 1
   NEXT
   /* leftover rows (fewer records than rows) */
   IF nDrawn < nRows
      FOR nRow := Max( nFrom, nDrawn + 1 ) TO Min( nTo, nRows )
         CoreDrawBlankRow( nRow, aView, nLock, nCol1 )
      NEXT
   ENDIF
   /* leave the pointer on the current record: that way the navigation SKIPs and the
    * Eof() checks stay correct */
   IF nDrawn > 0
      nCur := nPos - nTop + 1
      nCur := Max( 1, Min( nCur, nDrawn ) )
      SKIP ( nCur - nDrawn - 1 )
      IF Eof()
         SKIP -1
      ENDIF
   ENDIF
RETURN NIL

/* expression of the current order, without outer parentheses (the original
 * shows it like that) */
FUNCTION CoreKeyExpr()
   LOCAL c := ""
   IF Used() .AND. ! Empty( OrdName() )
      c := hb_CStr( dbOrderInfo( DBOI_EXPRESSION ) )
      IF Len( c ) > 1 .AND. Left( c, 1 ) == "(" .AND. Right( c, 1 ) == ")"
         c := SubStr( c, 2, Len( c ) - 2 )
      ENDIF
   ENDIF
RETURN c

/* second to last row of the browser: white strip with the current order in a cyan
 * chip ("Key: (expression)"), just as the original draws it.
 * S69: cNote is the answer of the last search ("Not found." / "[wrapped]") and
 * goes as one more chip of the same strip, to the right of the Key chip; the
 * strings are the SAME ones the read-only browser prints in its status row. The
 * strip is repainted from its start on every call, so a stale note never stays. */
STATIC PROCEDURE CoreDrawKeyLine( cNote )
   LOCAL cKey, nCol
   DEFAULT cNote TO ""
   IF Used() .AND. ! Empty( OrdName() )
      cKey := "Key: (" + CoreKeyExpr() + ")"
   ELSE
      cKey := "Key: (Natural Order)"
   ENDIF
   SetColor( UI_C_TITLEBAR )
   @ MaxRow() - 1, 0 SAY Replicate( Chr( 219 ), MaxCol() + 1 )
   SetColor( UI_C_CHIP )
   @ MaxRow() - 1, 1 SAY cKey
   IF ! Empty( cNote )
      nCol := 1 + Len( cKey ) + 2
      IF nCol + Len( cNote ) > MaxCol() + 1
         nCol := Max( 0, MaxCol() + 1 - Len( cNote ) )
      ENDIF
      @ MaxRow() - 1, nCol SAY cNote
   ENDIF
   SetColor( UI_C_DESKTOP )
RETURN NIL

/* full browser drawing (menu, bars, title, headers, rows, help and status) */
STATIC FUNCTION CoreDrawFrame( aView, nTop, nPos, nSel, nRows, cNote )
   LOCAL nLock := CoreLockN( aView ), nCol1 := CoreCol1( aView, nSel )
   UiCls()
   BpMenuBar( 0 )
   CoreDrawBars( nPos )
   CoreDrawTitle()
   CoreDrawHeader( aView, nSel, nLock, nCol1 )
   CoreDrawRows( aView, nTop, nPos, nSel, nRows, nLock, nCol1, 1, nRows )
   CoreDrawKeyLine( cNote )
   CoreStatus()
   SetColor( UI_C_DESKTOP )
RETURN NIL
/* -----------------------------------------------------------------------
 *  IN LINE editing of the current cell of the browser
 *  ---------------------------------------------------------------------
 *  The original does NOT open any window: the cell of the current record
 *  itself becomes an edit field (black on yellow) and the cursor
 *  moves inside it. Enter confirms, Esc cancels and Tab confirms.
 *  aFld = { nField, cName, cType, nLen, nDec, nWidth }
 * ----------------------------------------------------------------------- */

/* S2 of browse-edit-mouse.md: what Enter does on the current cell, as ONE
 * helper, because the DOUBLE CLICK of a cell has to do exactly the same: warn
 * when Cell Edit is disabled, refuse the memo fields inside CoreEditCell(),
 * recompute the position when the value changed the key of the order and
 * always leave the edited record visible in the window.
 * S4 of globalset-date-format.md removed the Modify and ReadOnly switches, so
 * Cell Edit is the only guard left: writing is never conditional anymore.
 * Answers { lFrame, lRows, lCurRow, nPos, nTop }: the three flags are the ones
 * the caller's paint block understands, and the position comes back because the
 * edit can move the record inside the active order. */
STATIC FUNCTION CoreEditCellNow( aView, nSel, nPos, nTop, nRows, nLock, nCol1 )
   LOCAL lFrame := .F., lRows := .F., lCurRow := .F.
   IF ! CoreCellEdit()
      UiMsg( "Cell Edit is DISABLED (F6 GlobalSet).", "hwBro" )
      lFrame := .T.
   ELSEIF aView[ nSel ][ 1 ] >= 1
      IF CoreEditCell( aView[ nSel ], nPos - nTop + 1, aView, nSel, nLock, nCol1 )
         /* the value may have changed the order key: recompute the position */
         IF CoreKeyHas( aView[ nSel ][ 2 ] )
            nPos := CorePosFromRec()
         ENDIF
         /* the edited record must ALWAYS stay visible in the window */
         IF nPos < nTop
            nTop := nPos
         ENDIF
         IF nPos > nTop + nRows - 1
            nTop := nPos - nRows + 1
         ENDIF
         IF nTop < 1
            nTop := 1
         ENDIF
         lRows := .T.
      ELSE
         lCurRow := .T.
      ENDIF
   ENDIF
RETURN { lFrame, lRows, lCurRow, nPos, nTop }

STATIC FUNCTION CoreEditCell( aFld, nRowWin, aView, nSel, nLock, nCol1 )
   LOCAL cType := aFld[ 3 ], nLen := aFld[ 4 ], nDec := aFld[ 5 ]
   LOCAL nCol, nWid, nSeg, nBufW, aGeo, nPos, nShift := 0, nKey, cBuf, cOld
   LOCAL lDone := .F., lOk := .F., xVal
   LOCAL cMask := "", cAccept := ""
   LOCAL lInsert := .F., lShift := .F., nSelFrom := 0, nSelTo := 0, nAnchor := 0
   LOCAL nClip, aRes, aKey, nSt
   LOCAL nRowScr := BP_ROW_TOP + nRowWin - 1

   IF aFld[ 1 ] < 1
      RETURN .F.
   ENDIF
   IF cType == "M"
      UiMsg( "Memo field: editing not supported (use APPEND/COPY for memos).", "hwBro" )
      RETURN .F.
   ENDIF
   aGeo := CoreCellGeom( aView, nSel, nLock, nCol1 )
   nCol := aGeo[ 1 ]
   IF nCol < 1
      RETURN .F.
   ENDIF
   nWid := aGeo[ 2 ]
   /* S8: the buffer and the mask of the cell work on the width of the VALUE
    * (CoreValW(), i.e. the picture in force for a Date), never on the 8 bytes of
    * the .DBF field: the ten-cell pictures need ten. The COLUMN of the cell is
    * the historical ten cells (S12) and the two widths are not the same rule.
    * The confirm path below converts the text with CToD(), so FieldPut() still
    * gets a value for the 8-byte field. */
   nBufW := CoreValW( cType, nLen )
   nSeg := Max( 1, Min( nBufW, nWid ) )

   /* the edit buffer has the length of the value (the picture for a Date), like
    * the original. In Date fields the mask comes from the system date format
    * ITSELF (SET DATE FORMAT): DToC() already returns "MM/DD/YY", "DD.MM.YY",
    * "YY/MM/DD"…, so the separators and their position are derived from it and
    * stay FIXED. Since S8 the mask is used with EVERY picture: it used to be
    * handed over only when the picture was as wide as the field, and with the
    * ten-cell pictures the cell was typed without a mask.
    * S3/S4 (browse-edit-mouse.md): the whole rule of the field - the filter, the
    * mask, the mode, the selection and the clipboard - is UiEditKey() of
    * bp_ui.prg, shared with UiLineEdit() and the Create Index form: this loop
    * only paints and decides what CONFIRM and CANCEL mean here. */
   IF cType == "D"
      cMask := DToC( Date() )
   ENDIF
   DO CASE
   CASE cType == "N" ; cAccept := "0123456789.-+"
   CASE cType == "D" ; cAccept := "0123456789"
   CASE cType == "L" ; cAccept := "TFYN"
   ENDCASE
   cOld := UiValToStr( FieldGet( aFld[ 1 ] ), cType, nLen, nDec )
   DO CASE
   CASE cType == "D"
      /* S8: the buffer is as wide as the picture. An EMPTY date is rendered
       * from spaces and the mask stamp below writes its separators, so a blank
       * cell can never keep a separator of another layout. */
      cBuf := PadR( iif( Empty( FieldGet( aFld[ 1 ] ) ), "", DToC( FieldGet( aFld[ 1 ] ) ) ), nBufW )
   CASE cType == "L" ; cBuf := iif( FieldGet( aFld[ 1 ] ), "T", "F" )
   OTHERWISE         ; cBuf := PadR( Left( cOld, nBufW ), nBufW )
   ENDCASE
   IF Len( cMask ) > 0
      cBuf := UiMaskStamp( cBuf, cMask )   /* separators guaranteed */
      nPos := UiMaskNext( -1, cMask )      /* first editable position */
   ELSE
      nPos := 0
   ENDIF
   nSelFrom := nPos ; nSelTo := nPos ; nAnchor := nPos

   SetCursor( 1 )              /* the system cursor is shown INSIDE the cell */
   CoreDrawEditCell( nRowScr, nCol, nSeg, cBuf, nPos, nShift, lInsert, nSelFrom, nSelTo )
   DO WHILE ! lDone
      /* S4: 50 ms instead of a blocking Inkey() so the combos of the window
       * hook (Ctrl-C / Ctrl-X / Shift-Ins) and the wheel can be polled */
      nKey := Inkey( 0.05 )
      /* S3: the modifier state of the stroke just read, IMMEDIATELY after
       * Inkey() and before anything else touches the driver (trap 37). Then the
       * SHIFT answer: the arrows do not carry it in HB_GTI_KBDSHIFTS and do not
       * reach the window hook either, so UiShiftLive() ORs that bit with the
       * live state of the hook (traps 37 and 71). */
      nSt := HcShiftState()
      lShift := UiShiftLive( nSt )
      /* the trace of the cell keys (BP_DEBUG=1 only: BpLog is a no-op without
       * it), the same shape the browser loop uses. It is what showed that SHIFT
       * of an arrow only arrives in the live state of the hook. */
      IF nKey != 0
         BpLog( "CoreEditCell: key=" + LTrim( Str( nKey ) ) + " shift=" + ;
                LTrim( Str( nSt ) ) + " live=" + iif( lShift, "T", "F" ) + ;
                " sel=" + LTrim( Str( nSelFrom ) ) + "-" + LTrim( Str( nSelTo ) ) )
      ENDIF
      /* S1: the WHEEL does nothing inside a cell and is DRAINED here (the hook
       * accumulates the notches and hands them over once), so the notches moved
       * while editing cannot move the browser the moment the cell closes. */
      CoreMouseWheel()
      /* S4: the clipboard chords. Ctrl-C, Ctrl-X and Shift-Insert do NOT arrive
       * with their modifier through Inkey() (trap 58): they come from the
       * window hook, and the copy Inkey() delivers for the same keystroke is
       * DISCARDED so one press does one thing.
       * S5: the RIGHT button of the cell opens the TEXT menu (Copy / Cut /
       * Paste) and its choice comes back as the SAME chord, so this block is the
       * only place where the clipboard of the cell is touched. It is asked only
       * when the keyboard gave nothing. */
      nClip := UiClipChord( nKey )
      IF nClip == 0 .AND. nKey == 0
         nClip := CoreTextCtxChord()
      ENDIF
      IF nClip != 0
         aRes := UiClipApply( nClip, cBuf, nSelFrom, nSelTo, .F., .F., cAccept, cMask )
         IF ! hb_IsNIL( aRes )
            cBuf := aRes[ 1 ] ; nPos := aRes[ 2 ]
            nSelFrom := nPos ; nSelTo := nPos ; nAnchor := nPos
            IF cType == "L"
               cBuf := CoreLogBuf( cBuf )
            ENDIF
         ENDIF
         CoreDrawEditCell( nRowScr, nCol, nSeg, cBuf, nPos, nShift, lInsert, ;
                           nSelFrom, nSelTo )
         LOOP
      ENDIF
      IF nKey == 0
         LOOP
      ENDIF
      /* the whole editing rule (Ins = insert/overwrite included) lives in
       * UiEditKey(), shared with the dialogs of the forms: one copy only. Tab
       * CONFIRMS the cell here, which is what this screen has always done.
       * The LAST argument is the opt-in of the bytes >= 128 (D1): a cell of this
       * screen typed them at baseline, while a dialog field never did, and that
       * is why the wider range is asked for HERE and nowhere else. */
      aKey := UiEditKey( cBuf, nPos, nKey, lInsert, .F., .F., .T., lShift, ;
                         nSelFrom, nSelTo, nAnchor, cAccept, cMask, .T. )
      cBuf := aKey[ 1 ] ; nPos := aKey[ 2 ] ; lInsert := aKey[ 3 ]
      nSelFrom := aKey[ 6 ] ; nSelTo := aKey[ 7 ] ; nAnchor := aKey[ 8 ]
      IF cType == "L"
         /* the buffer of a Logical field keeps T/F (Y and N mean the same) */
         cBuf := CoreLogBuf( cBuf )
      ENDIF
      DO CASE
      CASE aKey[ 5 ] == "ENTER" .OR. aKey[ 5 ] == "TAB"
         lDone := .T. ; lOk := .T.
      CASE aKey[ 5 ] == "ESC"
         lDone := .T. ; lOk := .F.
      ENDCASE
      /* keep the cursor position visible inside the cell */
      IF nPos < nShift
         nShift := nPos
      ENDIF
      IF nPos > nShift + nSeg - 1
         nShift := nPos - nSeg + 1
      ENDIF
      IF ! lDone
         CoreDrawEditCell( nRowScr, nCol, nSeg, cBuf, nPos, nShift, lInsert, ;
                           nSelFrom, nSelTo )
      ENDIF
   ENDDO
   /* at the end it is HIDDEN, not restored: the browser draws its own
    * cell cursor (green) and the system one stayed blinking where the
    * caret had been left, which after repainting the row appeared in ANOTHER column
    * (reported). UiLineEdit()/UiPick() do restore it because they are modals of
    * the forms, where the cursor is the only reference. */
   SetCursor( 0 )
   /* S1: the last notches of the gesture are drained too, or they would jump the
    * browser right after the cell closes */
   CoreMouseWheel()

   IF ! lOk
      RETURN .F.
   ENDIF

   /* convert and save; if the value is not valid the user is warned and nothing is touched */
   DO CASE
   CASE cType == "L" ; xVal := ( Upper( Left( cBuf, 1 ) ) == "T" )
   OTHERWISE         ; xVal := UiStrToVal( RTrim( cBuf ), cType )
   ENDCASE
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      RLock()
      FieldPut( aFld[ 1 ], xVal )
      /* the commit is inside the protected block: a recoverable error of the
       * engine (index, disk, lock) has to be reported and not escape to
       * BpFatal(), which closes the whole program */
      dbCommit()
      dbRUnlock()
      lOk := .T.
   RECOVER USING oErr
      BpLog( "CoreEditCell: FieldPut fallo (" + hb_CStr( oErr:Description ) + ")" )
      UiErr( "Invalid value for " + aFld[ 2 ] + hb_eol() + hb_CStr( oErr:Description ) )
      lOk := .F.
   END SEQUENCE
   IF ! lOk
      /* best effort: a record left locked makes every later edit fail with the
       * same error. Its own block, because the failure is already reported. */
      BEGIN SEQUENCE WITH {| e | Break( e ) }
         dbRUnlock()
      RECOVER
      END SEQUENCE
   ENDIF
RETURN lOk

/* column (1..), column width and field length of column nSel.
 * { 0, 0, 0 } if the column is not visible with the current window */
STATIC FUNCTION CoreCellGeom( aView, nSel, nLock, nCol1 )
   LOCAL i, nUsedW := 0
   FOR i := 1 TO Len( aView )
      IF ! CoreColVis( i, nLock, nCol1 )
         LOOP
      ENDIF
      IF i == nSel
         RETURN { BP_COL_BASE + nUsedW, aView[ i ][ 6 ], aView[ i ][ 4 ] }
      ENDIF
      nUsedW += aView[ i ][ 6 ] + 3
   NEXT
RETURN { 0, 0, 0 }

/* draw the cell being edited (black on yellow) and place the cursor inside.
 * S3/S4: the painting rule is the one of the dialogs (UiEditFieldPaint), so the
 * selection is the INVERTED pair and INSERT mode is a BLOCK cell with the system
 * caret hidden - the same visual language in the cells and in the forms. nShift
 * is the horizontal scroll of the cell and is translated here, because the cell
 * shows nSeg of the nLen cells of the field. */
STATIC PROCEDURE CoreDrawEditCell( nRowScr, nCol, nSeg, cBuf, nPos, nShift, lInsert, ;
                                  nSelFrom, nSelTo )
   LOCAL cWin, nCur, nFrom, nTo
   DEFAULT nShift TO 0 ; DEFAULT lInsert TO .F.
   cWin := PadR( SubStr( cBuf + Space( nSeg ), nShift + 1, nSeg ), nSeg )
   nCur := Max( 0, Min( nSeg - 1, nPos - nShift ) )
   nFrom := iif( ValType( nSelFrom ) == "N", nSelFrom - nShift, nCur )
   nTo   := iif( ValType( nSelTo ) == "N", nSelTo - nShift, nCur )
   UiEditFieldPaint( nRowScr, nCol, cWin, UI_C_EDIT, nCur, lInsert, nFrom, nTo )
   SetCursor( iif( lInsert, 0, 1 ) )
   DevPos( nRowScr, nCol + nCur )
RETURN

/* S4: the buffer of a Logical field keeps the classic T/F, so a typed Y or N
 * means the same value and the filter of the field stays simple. */
STATIC FUNCTION CoreLogBuf( cBuf )
   LOCAL c := Upper( Left( cBuf, 1 ) )
   IF c == "Y" .OR. c == "N"
      c := iif( c == "Y", "T", "F" )
   ENDIF
RETURN c + SubStr( cBuf, 2 )

/* The mask of the Date fields (SET DATE FORMAT) lived here as five CoreDate*
 * helpers; since S3/S4 of browse-edit-mouse.md the ONE copy of that rule is in
 * bp_ui.prg (UiMaskIsSep / UiMaskNext / UiMaskPrev / UiMaskLast / UiMaskStamp),
 * because the cell of the Browse edit and UiEditKey() share the field rule and a
 * second copy would drift apart again. */

FUNCTION CoreAppend()
   LOCAL oErr, lOk := .F.
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      dbAppend()          /* the RDD locks the header in shared mode */
      /* inside the protected block: a recoverable error here used to escape to
       * BpFatal() and close the program */
      dbCommit()
      lOk := .T.
   RECOVER USING oErr
      UiErr( "Could not append record:" + hb_eol() + oErr:Description )
   END SEQUENCE
RETURN lOk

FUNCTION CoreDeleteRecall()
   LOCAL oErr, lOk := .F.
   IF Deleted()
      BEGIN SEQUENCE WITH {| e | Break( e ) }
         dbRLock()
         dbRecall()
         dbCommit()
         dbRUnlock()
         lOk := .T.
      RECOVER USING oErr
         UiErr( "Error in RECALL: " + oErr:Description )
      END SEQUENCE
      IF lOk
         UiInfo( "Record recalled.", "hwBro" )
      ENDIF
   ELSE
      /* no message box after the DELETE (reported as noise): the confirmation
       * was already asked before it and the browser itself shows the result
       * (the row goes DIM and the bar gets the <DELETED> chip). */
      IF ! UiConfirm( "Mark record " + LTrim( Str( RecNo() ) ) + " as deleted?", "Delete" )
         RETURN .F.
      ENDIF
      BEGIN SEQUENCE WITH {| e | Break( e ) }
         dbRLock()
         dbDelete()
         dbCommit()
         dbRUnlock()
         lOk := .T.
      RECOVER USING oErr
         UiErr( "Error in DELETE: " + oErr:Description )
      END SEQUENCE
   ENDIF
RETURN lOk

FUNCTION CoreGotoRec( n )
   LOCAL lOk := .F.
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      GO n
      lOk := .T.
   RECOVER
      UiErr( "Record out of range: " + LTrim( Str( n ) ) )
   END SEQUENCE
RETURN lOk

FUNCTION CoreRunCmd( cCmd, lConfirm )
   LOCAL oErr
   DEFAULT lConfirm TO .F.
   IF Empty( cCmd )
      RETURN NIL
   ENDIF
   IF lConfirm .AND. ! UiConfirm( cCmd + " ?", "Run" )
      RETURN NIL
   ENDIF
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      &( cCmd )
   RECOVER USING oErr
      UiErr( "Error running:" + hb_eol() + cCmd + hb_eol() + oErr:Description )
   END SEQUENCE
RETURN NIL

