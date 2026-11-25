/*
 * hwbro.prg - main program: startup, splash and F1..F9 menu bar
 * hwBro - clone of BroPlus 3.00 (Extrasensory Software) - Harbour + MSVC x64
 */
#include "inkey.ch"
#include "fileio.ch"
#include "hbgtinfo.ch"
#include "bp_def.ch"

/* RDDs and drivers that must stay linked into the executable */
REQUEST DBFCDX
REQUEST DBFFPT
REQUEST DBFNTX
REQUEST DBFNSX
REQUEST HB_GT_WVG_DEFAULT

STATIC s_lExit := .F.
/* S4 (menu-accelerators.md): the GLOBAL accelerator map of the DB manager,
 * built once from the shortcut texts of BpMenus() by BpAccelMap(). */
STATIC s_aBpAccel := {}

FUNCTION BpExiting()
RETURN s_lExit

FUNCTION BpSetExit( l )
   DEFAULT l TO .T.
   s_lExit := l
RETURN NIL

FUNCTION BpExit()
   IF UiConfirm( "Exit hwBro?", "Exit" )
      BpSetExit( .T. )
   ENDIF
RETURN NIL

/* B2 (window-close.md S1/S2/S4): the program-wide consumer of the window's X.
 * The window hook of bp_win32.c CONSUMES WM_CLOSE -re-forwarding it to the
 * driver tumbles the process, S3- and leaves the request in a latch that is only
 * PEEKED here: W32CLOSESTEP() does not clear it, because the request has to
 * survive the several screens that may see it. The first poller is usually a
 * modal box, which can only cancel itself, so the exit has to still be pending
 * when the key loop of the screen behind it comes back (L9). BpSetExit() is what
 * every screen already watches, so the program leaves through its NORMAL exit
 * path -HcZipCleanupAll(), CLOSE ALL, the cursor restore- instead of an abrupt
 * teardown (S2). The comparison is explicit: a bare numeric IF raises and
 * BpFatal() would close the program (traps 59 and 73). */
FUNCTION BpCloseAsk()
   IF W32CLOSESTEP() != 0
      BpSetExit( .T. )
      RETURN .T.
   ENDIF
RETURN .F.

/* F9: dBASE style dot prompt. What the dot cannot resolve (leaving the
 * program) is resolved here. */
FUNCTION BpDot()
   DotSetOpenMode( CoreOpenMode() )
   IF ! BpDotPrompt()
      BpSetExit( .T. )
   ENDIF
RETURN NIL

FUNCTION BpNotImplemented( cWhat )
   UiMsg( cWhat + ": function not included in this reconstruction.", "hwBro" )
RETURN NIL

/* ---------------------------------------------------------------
 *  Startup
 * --------------------------------------------------------------- */

PROCEDURE Main( xArg )
   LOCAL cPick := "", nArea := 0, lFwRule := .F., cStart := ""
   ErrorBlock( {| o | BpFatal( o ) } )
   /* S75/S5: the elevated instance. It is hwBro ITSELF -a GUI program, so no
    * console window appears- and it does its work -add or remove the two
    * firewall rules of the Commander Link- and leaves BEFORE any screen, splash
    * or database exists. Going through `cmd.exe`/`netsh.exe` from the normal
    * process would flash a black window on every one of them. */
   IF HcFwArgsWanted()
      lFwRule := HcFwApplyArgs()
      __Quit( iif( lFwRule, 0, 1 ) )
   ENDIF
   SetMode( BP_SCR_ROWS, BP_SCR_COLS )
   BpSetVgaPalette()
   BpSetFontAttrs()
   /* the click of bp_win32.c is converted to a cell of THIS canvas: the helper
    * defaults to 80x25, so the real grid is handed over once, here (the dot
    * prompt and the Harbour Commander both rely on it) */
   W32SetGrid( MaxRow() + 1, MaxCol() + 1 )
   /* The modals of bp_ui.prg (the Yes/No box first) read the mouse through
    * this hook: that module never calls the W32* helpers, so the headless banks
    * can link it, and here the click of the window hook reaches every
    * confirmation box of the program (S45). */
   UiSetClickHook( {|| BpMouseClick() } )
   /* S10 of odd/tasks/commander-cleanup.md: the other two answers of the same
    * click - the double click and the wheel - for the modals of bp_ui.prg
    * (UiPick and the screens that poll between keys). Same rule: that module
    * never calls the W32* natives, so the headless banks still link it. */
   UiSetDblHook( {|| W32ClickDbl() } )
   UiSetWheelHook( {|| DotMouseWheel() } )
   /* S100 (hc-ctx-menu-clipboard.md): the clipboard, the combos and SHIFT of
    * the inline editor of bp_ui.prg, wired to the natives of bp_win32.c with
    * the same rule - that module never calls W32* itself, so the three headless
    * banks can link it. W32ShiftDown() answers a LOGICAL, so it is handed over
    * as it comes (comparing it with a number would always be false). */
   UiSetClipHook( {| c | W32ClipPut( c ) }, {|| W32ClipGet() } )
   UiSetChordHook( {|| iif( W32ClipKeyStep() != 0, W32ClipKey(), 0 ) } )
   UiSetShiftHook( {|| W32ShiftDown() } )
   /* S13.7 (hc-file-search.md): the Alt chord of the inline editor. This driver
    * hands `Alt+<letter>` to Inkey() as the PLAIN letter, so inside a field
    * editor it was written into the value; the window hook did record it, and
    * HcAltChord() drains that ring and answers the letter. bp_ui.prg never
    * calls the W32 helpers itself, so the bridge is installed here, with the
    * same rule as the click hook; a screen that wants the chord reads
    * UiAltChord(). */
   UiSetAltHook( {|| HcAltChord() } )
   /* right-click-esc (S5 of right-click-esc.md): the plain right click that the
    * screens leaving with Esc use AS that Esc. HcMouseRightClick() drains the
    * right-button channel of bp_win32.c and answers .T. once per click, so a
    * modal or a form only has to ask it on its idle pass; the screens where the
    * right button already does something (the panels, the Text editor, the
    * Browse edit) never ask, which is what keeps those gestures alive. Same rule
    * as the hooks above: bp_ui.prg never calls the natives itself, so the three
    * headless banks keep linking it. */
   UiSetRClickHook( {|| HcMouseRightClick() } )
   /* B2 (window-close.md S1/S4): the X of the window. The hook of bp_win32.c
    * consumes WM_CLOSE and leaves the request latched, so every modal of
    * bp_ui.prg asks it here and cancels itself -instead of being painted over-
    * and the key loops ask BpCloseAsk() directly. Same rule as the other hooks:
    * bp_ui.prg never calls W32*, so the three headless banks keep linking it. */
   UiSetCloseHook( {|| BpCloseAsk() } )
   /* S3 of theme-dark-mode.md: a theme is the PAIRS of bp_ui.prg plus the RGB of
    * the palette, so switching it has to retune the palette of the driver too -
    * otherwise `Dark` is Classic with different letters and the screen keeps the
    * hard 0,0,0 -> 85,85,85 surfaces. bp_ui.prg never calls hb_gtInfo() itself, so
    * the bridge is installed here, with the same rule as the hooks above; the
    * Commander repaints the whole screen after the switch, so the new RGBs are
    * seen at once. Without this hook (every headless bank) the pairs still switch
    * and only the palette stays as it was. */
   UiSetThemeHook( {|| BpSetVgaPalette() } )
   /* "Save configuration" of the Harbour Commander (Commands): the row is drawn
    * by bp_hc.prg, which cannot call bp_cfg.prg (the headless bank links it
    * alone), so the work is handed in as a block. */
   HcSetCfgHook( {|| BpCfgSave() } )
   /* `Commands > Theme Colors...` (S137 of theme-color-overrides.md): the screen
    * is BpThemeColors() of bp_cmds.prg and bp_hc.prg cannot call it (the headless
    * bank links bp_hc.prg alone), so it travels as a block, like the one above. */
   HcSetThemeColorsHook( {|| BpThemeColors() } )
   Set( _SET_SCOREBOARD, .F. )
   /* The CANCEL handler terminates the program on Ctrl+<key>, and on a Spanish
    * keyboard AltGr IS Ctrl+Alt: AltGr+C (and Alt+C on some layouts) closed
    * hwBro from the file manager. This is a GUI program with its own key
    * handling, so the break is disarmed for the whole application. */
   Set( _SET_CANCEL, .F. )
   /* S9 of globalset-date-format.md: the window of the two-digit years. Measured:
    * this build starts with `_SET_EPOCH` = 1900, so a short-year picture resolved
    * "11/20/26" to 1926 - and the cell of the Browse edit writes that value into
    * the .DBF. The rule (base 1950) lives in bp_ui.prg so the headless bank can
    * assert it; here it is only applied, once, with the rest of the startup Set
    * calls. */
   UiDateEpochInit()
   /* S13 of globalset-date-format.md: the session STARTS with `dd/mm/yyyy` in the
    * engine (the user's "El default debe ser DD/MM/YYYY"), installed with the
    * same rule as the epoch: no STATIC, `SET DATE FORMAT` stays the only source.
    * Ten cells, so the cell of the Browse edit is masked with ten and its column
    * (ten, S12) matches the value; the row `Date Format` reads it back from the
    * engine, which is why the select opens on the tenth picture. */
   UiDateFormatInit()
   CoreInit()
   /* hwbro.ini (the file NEXT TO THE EXECUTABLE): the GlobalSet of the DB
    * manager and the theme the program starts with. It is applied AFTER
    * CoreInit() and after the two startup defaults (epoch 1950 and dd/mm/yyyy),
    * so what the user saved wins; with no file - or with a value the screen
    * could not produce - the defaults stay exactly as they were. The theme is
    * switched here too, and the palette hook installed above retunes the RGB of
    * the driver in the act, before the splash is painted. */
   BpCfgLoad()
   /* A6 of odd/tasks/f2-dbmanager.md: A DATABASE DROPPED ON THE EXECUTABLE.
    * Windows runs `hwbro.exe "C:\...\CLIENTES.DBF"` and what the user asked for
    * is that database in the DB manager and NOTHING else: no splash - it waits
    * for a key, and the drag WAS the gesture - and no file manager to come back
    * to, so leaving the manager closes the program. */
   cStart := BpDbFromArgs( xArg )
   IF Empty( cStart )
      /* CAREFUL: the splash waits for a key WITHOUT a timer, so the
       * BP_AUTOKEYS keys have to be queued BEFORE it (otherwise an automatic
       * run gets stuck on the splash): the first key closes the
       * splash and the rest go to the file manager. */
      BpAutoKeys()
      BpSplash()
   ENDIF
   /* Harbour Commander is the start screen: no menu bar and no database
    * selection panel. It returns the FULL PATH of the database picked with
    * <Enter>, or "" once it is finished (a confirmed `Exit hwBro?` sets the
    * exit flag, so the loop ends there). */
   DO WHILE ! BpExiting()
      IF ! Empty( cStart )
         IF CoreOpen( cStart )
            CoreOrdList()
         ELSE
            /* it was dragged, but it is not a database this build can open:
             * say so and go on as a NORMAL start, instead of leaving the user
             * with a dead window after a drag */
            UiErr( "Cannot open " + cStart )
            cStart := ""
            BpSplash()
         ENDIF
         IF ! Empty( cStart )
            /* the manager, and the program ends with it (A6) */
            BpDbManagerSession()
            EXIT
         ENDIF
      ENDIF
      cPick := BpHcScreen()
      IF BpExiting()
         EXIT
      ENDIF
      /* F2 pushed on something that is not a database: the DB manager opens
       * WITHOUT a base (odd/tasks/f2-dbmanager.md, A1). */
      IF HcWantDataManager()
         BpDbManagerSession()
         LOOP
      ENDIF
      IF ! Empty( cPick )
         /* a database that is already open (it can be picked again after Esc
          * from the browser) is only ACTIVATED: reopening it in EXCLUSIVE mode
          * fails with "Open error" and would push the session to SHARED. */
         nArea := CoreAreaByFile( cPick )
         IF nArea > 0
            SELECT ( nArea )
         ELSEIF CoreOpen( cPick )
            CoreOrdList()
         ENDIF
      ENDIF
      /* <Esc> in the browser returns from CoreBrowse() and the loop enters the
       * file manager again. The manager itself is ONE session: it browses while
       * there is a base and, when the base is closed from its own menus - the
       * user did not leave, the database did -, it stays on its base-less face
       * until the user leaves it. */
      BpDbManagerSession()
   ENDDO
   /* S52: the archives that were being browsed are closed and their working
    * trees deleted (the Commander keeps them alive only while the program runs) */
   HcZipCleanupAll()
   /* S2 of window-close.md (B3): the Slave of the Commander Link is shut down
    * HERE so that EVERY exit shape reaches it -Alt-X, F10, the dot `QUIT` and
    * the X of the window- instead of only the `Exit hwBro?` of HcAskQuit().
    * HcLinkShutdown() is STATIC in bp_hc.prg (only that screen used to own the
    * Slave) and Main() cannot reach a STATIC procedure, so it goes through the
    * one public door that sits next to it: HcLinkEnd(). */
   HcLinkEnd()
   CLOSE ALL
   SetColor( "W/N" )
   CLS
RETURN NIL

/* Opens the Harbour Commander file manager and, when the user picks a database
 * there, opens it: this is what the F2 menu item, Alt-F2 and the desktop use
 * (the start screen selects databases through the same screen, in Main()).
 * It returns the opened database full path, or "" when nothing was picked. */
FUNCTION BpDbPickHc()
   LOCAL cFile := BpHcScreen(), nArea := 0
   IF ! Empty( cFile )
      nArea := CoreAreaByFile( cFile )
      IF nArea > 0
         SELECT ( nArea )
      ELSEIF CoreOpen( cFile )
         CoreOrdList()
      ENDIF
   ENDIF
RETURN cFile

/* GTWVG ships a dimmed palette without bright variants: the classic VGA
 * palette the original BroPlus uses is set instead (measured on its screenshots).
 * It is the palette of the theme IN FORCE: this function always builds the
 * measured Classic base and then overlays the RGB overrides of the active theme
 * (UiThemePalette()), so switching the theme retunes the palette of the driver
 * in one call and the whole screen changes with it. `Classic` overrides nothing,
 * so its palette is the measured one byte for byte (S2 of theme-dark-mode.md). */
FUNCTION BpSetVgaPalette()
   LOCAL aVga := { { 0, 0, 0 }, { 0, 0, 170 }, { 0, 170, 0 }, { 0, 170, 170 }, ;
                   { 170, 0, 0 }, { 170, 0, 170 }, { 170, 85, 0 }, { 170, 170, 170 }, ;
                   { 85, 85, 85 }, { 85, 85, 255 }, { 85, 255, 85 }, { 85, 255, 255 }, ;
                   { 255, 85, 85 }, { 255, 85, 255 }, { 255, 255, 85 }, { 255, 255, 255 } }
   LOCAL aPal := {}, aOver, i, n, nRgb
   /* With FONTA_DRAWBOX/FIXMETRIC active, GTWVG resolves the bright background
    * attributes ('+' in the BACKGROUND color) to the BASE entry of the palette, so
    * the 16 colors of the original do not fit in 8 backgrounds. The ones the
    * original uses as a bright BACKGROUND are remapped to their base value:
    *   G  = bright green (85,255,85)   · editable fields
    *   R  = bright red   (255,85,85)   · current record
    *   RB = yellow       (255,255,85)  · list selection / cell
    * and B (blue, which the original does not use as a background except in the forms) =
    * dark gray (85,85,85) for the menu bar, the status line and the
    * interior of the selection screen.
    * The BRIGHT BLUE (85,85,255) of the forms cannot be added on top: another
    * one of the 8 backgrounds would have to go (see AGENTS.md section 4). */
   aVga[ 2 ] := { 85, 85, 85 }
   aVga[ 3 ] := { 85, 255, 85 }
   aVga[ 5 ] := { 255, 85, 85 }
   aVga[ 6 ] := { 255, 255, 85 }
   /* The theme is the LAST word: only the eight base entries above can be a
    * BACKGROUND, so a theme cannot ask for a new letter - it retunes the RGB of
    * the ones that exist, entry 1..16, packed as nR + nG * 256 + nB * 65536. An
    * out-of-range entry or a value that is not a number is skipped instead of
    * breaking the table, so a bad theme can only lose its own colour. */
   aOver := UiThemePalette( UiThemeName() )
   FOR n := 1 TO Len( aOver )
      IF HB_ISARRAY( aOver[ n ] ) .AND. Len( aOver[ n ] ) >= 2 .AND. ;
         ValType( aOver[ n ][ 1 ] ) == "N" .AND. ValType( aOver[ n ][ 2 ] ) == "N" .AND. ;
         aOver[ n ][ 1 ] >= 1 .AND. aOver[ n ][ 1 ] <= 16
         i := aOver[ n ][ 1 ]
         nRgb := aOver[ n ][ 2 ]
         aVga[ i ] := { nRgb % 256, Int( nRgb / 256 ) % 256, Int( nRgb / 65536 ) % 256 }
      ENDIF
   NEXT
   FOR i := 1 TO 16
      AAdd( aPal, aVga[ i ][ 1 ] + aVga[ i ][ 2 ] * 256 + aVga[ i ][ 3 ] * 65536 )
   NEXT
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      hb_gtInfo( HB_GTI_PALETTE, aPal )
   RECOVER
      /* if the driver does not support a palette, continue with the system one */
   END SEQUENCE
RETURN NIL

/* GTWVG draws the box characters (─ │ ╔ ═ ╗ ╚ ╝ ...) with the glyphs of the
 * font, which in TrueType fonts do not reach the cell borders; when combined
 * with █ (which does fill them) the shapes look "shifted". With FONTA_DRAWBOX the
 * driver paints those characters with exact internal patterns and FIXMETRIC
 * forces uniform font metrics (every cell measures the same), which is
 * what keeps the block and the box line aligned. */
FUNCTION BpSetFontAttrs()
   LOCAL nAttr := 0
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      nAttr := hb_gtInfo( HB_GTI_FONTATTRIBUTE )
      IF ValType( nAttr ) != "N"
         nAttr := 0
      ENDIF
      nAttr := hb_bitOr( nAttr, HB_GTI_FONTA_DRAWBOX )
      nAttr := hb_bitOr( nAttr, HB_GTI_FONTA_FIXMETRIC )
      hb_gtInfo( HB_GTI_FONTATTRIBUTE, nAttr )
   RECOVER
      /* driver without support: continue with the normal font */
   END SEQUENCE
RETURN NIL

/* Key injection for automated tests:
 * set BP_AUTOKEYS=F2,ENTER,F8      (names or numeric codes separated by commas) */
FUNCTION BpAutoKeys()
   LOCAL c := hb_GetEnv( "BP_AUTOKEYS" ), a, i, cK, n
   IF Empty( c )
      BpLog( "autokeys: empty variable" )
      RETURN NIL
   ENDIF
   BpLog( "autokeys: " + c )
   a := hb_ATokens( c, "," )
   FOR i := 1 TO Len( a )
      cK := Upper( AllTrim( a[ i ] ) )
      n := 999999
      DO CASE
      CASE cK == "F1"     ; n := K_F1
      CASE cK == "F2"     ; n := K_F2
      CASE cK == "F3"     ; n := K_F3
      CASE cK == "F4"     ; n := K_F4
      CASE cK == "F5"     ; n := K_F5
      CASE cK == "F6"     ; n := K_F6
      CASE cK == "F7"     ; n := K_F7
      CASE cK == "F8"     ; n := K_F8
      CASE cK == "F9"     ; n := K_F9
      CASE cK == "ALT-F2" ; n := K_ALT_F2
      CASE cK == "ALT-F3" ; n := K_ALT_F3
      CASE cK == "ALT-F4" ; n := K_ALT_F4
      CASE cK == "ALT-X"  ; n := K_ALT_X
      CASE cK == "ALT-Y"  ; n := K_ALT_Y
      CASE cK == "ALT-Z"  ; n := K_ALT_Z
      CASE cK == "ALT-N"  ; n := K_ALT_N
      CASE cK == "ALT-MINUS" ; n := K_ALT_MINUS
      CASE cK == "ALT-M"  ; n := K_ALT_M
      CASE cK == "ENTER"  ; n := K_ENTER
      CASE cK == "ESC"    ; n := K_ESC
      CASE cK == "UP"     ; n := K_UP
      CASE cK == "DOWN"   ; n := K_DOWN
      CASE cK == "LEFT"   ; n := K_LEFT
      CASE cK == "RIGHT"  ; n := K_RIGHT
      CASE cK == "PGDN"   ; n := K_PGDN
      CASE cK == "PGUP"   ; n := K_PGUP
      CASE cK == "HOME"   ; n := K_HOME
      CASE cK == "END"    ; n := K_END
      CASE cK == "CTRL-HOME" ; n := K_CTRL_HOME
      CASE cK == "CTRL-END"  ; n := K_CTRL_END
      CASE cK == "CTRL-PGUP" ; n := K_CTRL_PGUP
      CASE cK == "CTRL-PGDN" ; n := K_CTRL_PGDN
      CASE cK == "INS"    ; n := K_INS
      CASE cK == "DEL"    ; n := K_DEL
      CASE cK == "TAB"    ; n := K_TAB
      OTHERWISE           ; n := Val( cK )
      ENDCASE
      IF n != 999999
         hb_keyPut( n )
         BpLog( "  keyput " + cK + " = " + LTrim( Str( n ) ) )
      ELSE
         BpLog( "  unknown key: " + cK )
      ENDIF
   NEXT
RETURN NIL

/* always writes to the error file (independent of BP_DEBUG) */
FUNCTION BpErrLog( cText )
   LOCAL nH, cF := BpLogFile()
   nH := FOpen( cF, FO_READWRITE )
   IF nH == -1
      nH := FCreate( cF )
   ELSE
      FSeek( nH, 0, FS_END )
   ENDIF
   IF nH != -1
      FWrite( nH, cText + hb_eol() )
      FClose( nH )
   ENDIF
RETURN NIL

FUNCTION BpLogFile()
   LOCAL cExe := hb_ProgName()
RETURN Left( cExe, Rat( "\", cExe ) ) + "hwbro.err"

FUNCTION BpLog( cText )
   LOCAL nH, cF := BpLogFile()
   /* it only writes when BP_DEBUG is defined (diagnostics) */
   IF Empty( hb_GetEnv( "BP_DEBUG" ) )
      RETURN NIL
   ENDIF
   nH := FOpen( cF, FO_READWRITE )
   IF nH == -1
      nH := FCreate( cF )
   ELSE
      FSeek( nH, 0, FS_END )
   ENDIF
   IF nH != -1
      FWrite( nH, cText + hb_eol() )
      FClose( nH )
   ENDIF
RETURN NIL

STATIC PROCEDURE BpFatal( oErr )
   LOCAL cMsg, cTxt := "", aSt, i
   IF hb_IsObject( oErr )
      cMsg := oErr:Description
      cTxt += "Description : " + hb_CStr( oErr:Description ) + hb_eol()
      cTxt += "SubSystem   : " + hb_CStr( oErr:SubSystem ) + hb_eol()
      cTxt += "Operation   : " + hb_CStr( oErr:Operation ) + hb_eol()
      cTxt += "Args        : " + hb_ValToStr( oErr:Args ) + hb_eol()
      aSt := oErr:CallStack
      IF ValType( aSt ) == "A"
         FOR i := 1 TO Len( aSt )
            cTxt += "  " + PadR( hb_CStr( aSt[ i ][ 1 ] ), 24 ) + ;
                    "@" + hb_CStr( aSt[ i ][ 2 ] ) + ":" + hb_CStr( aSt[ i ][ 3 ] ) + hb_eol()
         NEXT
      ENDIF
   ELSE
      cMsg := hb_CStr( oErr )
      cTxt := cMsg
   ENDIF
   BpErrLog( "==== ERROR " + DToC( Date() ) + " " + Time() + " ====" + hb_eol() + cTxt )
   SetColor( UI_C_ERR )
   CLS
   @ 2, 2 SAY "Unrecoverable error:"
   @ 4, 2 SAY cMsg
   IF ValType( aSt ) == "A" .AND. Len( aSt ) > 0
      @ 6, 2 SAY "Origin: " + hb_CStr( aSt[ 1 ][ 2 ] ) + " line " + hb_CStr( aSt[ 1 ][ 3 ] )
   ENDIF
   @ 8, 2 SAY "Details in: hwbro.err"
   Inkey( 5 )
   BpSetExit( .T. )
RETURN NIL

/* The click of the window hook of bp_win32.c as { row, column } of the canvas
 * in use, or NIL when there was no click. The C helpers reset both coordinates
 * when they are read, so a click is delivered exactly once (S45: this is what
 * UiSetClickHook() hands to the modals of bp_ui.prg). */
STATIC FUNCTION BpMouseClick()
   LOCAL nRow := DotMouseClickRow(), nCol
   IF nRow < 0
      RETURN NIL
   ENDIF
   nCol := DotMouseClickCol()
   IF nCol < 0
      RETURN NIL
   ENDIF
RETURN { nRow, nCol }

/* Startup logo: the "ANSI Shadow" art of the project (the one the user chose).
 * It is written with ASCII markers and translated into the CP437 block
 * characters so it does not depend on the encoding of the source file:
 *   # = █ (219)   1 = ╔ (201)   2 = ╗ (187)   3 = ╚ (200)
 *   4 = ╝ (188)   5 = ║ (186)   =  = ═ (205) */
STATIC FUNCTION BpLogo()
   LOCAL aRows := { ;
      "##2  ##2##2    ##2######2 ######2  ######2 ", ;
      "##5  ##5##5    ##5##1==##2##1==##2##1===##2", ;
      "#######5##5 #2 ##5######14######14##5   ##5", ;
      "##1==##5##5###2##5##1==##2##1==##2##5   ##5", ;
      "##5  ##53###1###14######14##5  ##53######14", ;
      "3=4  3=4 3==43==4 3=====4 3=4  3=4 3=====4 " }, ;
      aOut := {}, i, c
   FOR i := 1 TO Len( aRows )
      c := aRows[ i ]
      c := StrTran( c, "#", Chr( 219 ) )
      c := StrTran( c, "1", Chr( 201 ) )
      c := StrTran( c, "2", Chr( 187 ) )
      c := StrTran( c, "3", Chr( 200 ) )
      c := StrTran( c, "4", Chr( 188 ) )
      c := StrTran( c, "5", Chr( 186 ) )
      c := StrTran( c, "=", Chr( 205 ) )
      AAdd( aOut, c )
   NEXT
RETURN aOut

/* S4/S5 (splash-mouse.md): the RDD names this build answers at run time, or an
 * empty array when the engine cannot tell. RddList() is RTL and this build
 * links DBFCDX/DBFFPT/DBFNTX/DBFNSX (see the REQUEST block at the top), but the
 * start screen must never die on it: a build without the function falls back to
 * the literal line through UiRddLine(). MEASURED (S4, log L2): this build
 * answers { "DBF", "DBFFPT", "DBFBLOB", "DBFNSX", "DBFCDX", "DBFNTX" }, always
 * the same order and regardless of rddSetDefault() - registration order, not the
 * default one. */
STATIC FUNCTION BpRddList()
   LOCAL a := {}
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      a := RddList()
   RECOVER
      a := {}
   END SEQUENCE
   IF ! HB_ISARRAY( a )
      a := {}
   ENDIF
RETURN a

/* Startup screen. It does NOT reproduce the splash of the original: it is the
 * identity of this port (hwBro) — ANSI Shadow logo, double frame and version.
 * It leaves on any key AND on a mouse click on its OK button (S1): this driver
 * never delivers the mouse through Inkey() (AGENTS traps 34/43), so the loop
 * waits with Inkey( 0.05 ) and polls the click hook Main() installed. */
STATIC PROCEDURE BpSplash()
   LOCAL nKey, cSave, aBan, aMsg, i, nWid, nT, nL, nB, nR, nRow, nBase
   LOCAL nColLogo, nWidLogo, nBtnW, nBl, nBt, cOldCur, aPt

   UiCls()
   /* the status line stays: only the old F1..F9 menu bar is gone from here */
   CoreStatus()

   aBan := BpLogo()
   nWidLogo := 0
   FOR i := 1 TO Len( aBan )
      nWidLogo := Max( nWidLogo, Len( aBan[ i ] ) )
   NEXT
   /* S3: no "native reconstruction" anymore - the version alone. S4: the data
    * engine line is the RDD list of THIS build, read at run time, and it falls
    * back to the old literal when the engine answers nothing. */
   aMsg := { "Version " + BP_VERSION, ;
             "Harbour + MSVC   -   no emulator", ;
             UiRddLine( BpRddList() ), ;
             "Press any key to open the file manager" }
   nWid := nWidLogo
   FOR i := 1 TO Len( aMsg )
      nWid := Max( nWid, Len( aMsg[ i ] ) )
   NEXT

   nR := nWid + 8
   nB := Len( aBan ) + 14
   /* centred on the canvas: the splash carries no menu bar (the old F1..F9 bar
    * is not part of this screen) but keeps the status line at the bottom */
   nT := UiCenterRow( nB )
   nL := UiCenterCol( nR )
   /* S1: this driver never delivers the mouse through Inkey(), so the click
    * comes from the window hook of bp_win32.c. The splash is the FIRST screen
    * of the program and nothing has installed that hook yet (the browsers, the
    * Harbour Commander and the dot install it themselves), so it is installed
    * here and removed on the way out. Without this the click hook Main() wired
    * to UiClick() would answer NIL for ever on the start screen. */
   DotMouseHook( .T. )
   /* S2: no blinking caret on the splash. UiPaintBegin/End only hide it while
    * they paint, so a screen that waits for a key got it back and it blinked
    * next to the OK button (the user's report). Hidden BEFORE the first
    * painting block - so the block saves the already hidden state - and
    * restored after RestScreen(), exactly like the modal boxes of bp_ui.prg. */
   cOldCur := SetCursor( 0 )
   cSave := SaveScreen( nT, nL, nT + nB + 1, Min( nL + nR + 2, MaxCol() ) )

   UiPaintBegin()
   UiShadow( nT, nL, nT + nB, nL + nR )
   UiFillBox( nT, nL, nT + nB, nL + nR, UI_C_SPLASH )
   /* double frame in bright white */
   UiFrame( nT, nL, nT + nB, nL + nR, UI_C_SPLFRM, .T. )

   /* logo (bright white over the green) */
   nColLogo := nL + Int( ( nR - nWidLogo ) / 2 )
   nRow := nT + 2
   SetColor( UI_C_SPLFRM )
   FOR i := 1 TO Len( aBan )
      @ nRow + i, nColLogo SAY PadR( aBan[ i ], nWidLogo )
   NEXT

   /* decorative double line under the logo */
   nBase := nRow + Len( aBan ) + 1
   @ nBase, nL + 2 SAY Replicate( BP_LINE_DOUBLE, nR - 4 )

   /* messages: the version in yellow, the rest normal */
   nBase += 2
   SetColor( UI_C_SPLMSG )
   @ nBase, nL + Int( ( nR - Len( aMsg[ 1 ] ) ) / 2 ) SAY aMsg[ 1 ]
   SetColor( UI_C_SPLASH )
   FOR i := 2 TO Len( aMsg )
      @ nBase + i - 1, nL + Int( ( nR - Len( aMsg[ i ] ) ) / 2 ) SAY aMsg[ i ]
   NEXT

   /* OK button: block frame (like the logo) with a shadow to the right and below,
    * and the text in black on the cyan */
   nBtnW := 10
   nBl := nL + Int( ( nR - nBtnW ) / 2 )
   nBt := nT + nB - 4
   SetColor( UI_C_SPLSHD )
   @ nBt + 1, nBl + 1 SAY Replicate( Chr( 219 ), nBtnW )
   @ nBt + 2, nBl + 1 SAY Chr( 219 ) + Space( nBtnW - 2 ) + Chr( 219 )
   @ nBt + 3, nBl + 1 SAY Replicate( Chr( 219 ), nBtnW )
   SetColor( UI_C_SPLFRM )
   @ nBt,     nBl SAY Replicate( Chr( 219 ), nBtnW )
   @ nBt + 1, nBl SAY Chr( 219 ) + Space( nBtnW - 2 ) + Chr( 219 )
   @ nBt + 2, nBl SAY Replicate( Chr( 219 ), nBtnW )
   SetColor( UI_C_SPLASH )
   @ nBt + 1, nBl + Int( nBtnW / 2 ) - 1 SAY "OK"
   SetColor( UI_C_DESKTOP )
   UiPaintEnd()

   /* Without a timer: the splash stays on screen until the user presses any
    * key, or clicks the OK button with the mouse (S1). Every cell of the ten by
    * three block rectangle of the button counts; the shadow is one row below
    * and one column right of it and is NOT the button, so a click there leaves
    * the splash on screen. */
   DO WHILE .T.
      /* S1/S4 of window-close.md (B3): the X of the window. BpCloseAsk() peeks
       * the latch the hook of bp_win32.c leaves and raises the program's exit
       * flag, so the splash is left through the SAME exit it uses for a key or
       * for the OK button: RestScreen(), the caret and the window hook are all
       * restored below. It never asks `Exit hwBro?` (L7). The hook of this
       * screen (DotMouseHook, a few lines above) is what makes the latch
       * reachable here at all. */
      IF BpCloseAsk()
         EXIT
      ENDIF
      nKey := Inkey( 0.05 )
      IF nKey != 0
         EXIT
      ENDIF
      aPt := UiClick()
      IF HB_ISARRAY( aPt ) .AND. Len( aPt ) >= 2 .AND. ;
         UiCellInBox( aPt[ 1 ], aPt[ 2 ], nBt, nBl, nBt + 2, nBl + nBtnW - 1 )
         EXIT
      ENDIF
   ENDDO
   RestScreen( nT, nL, nT + nB + 1, Min( nL + nR + 2, MaxCol() ), cSave )
   SetCursor( cOldCur )
   DotMouseHook( .F. )
   SetColor( UI_C_DESKTOP )
RETURN NIL
STATIC PROCEDURE BpDesktop()
   /* The original, with no database open, shows no text at all: only the menu
    * bar and the status line. */
   UiPaintBegin()
   UiCls()
   BpMenuBar( 0 )
   CoreStatus()
   SetColor( UI_C_DESKTOP )
   UiPaintEnd()
RETURN NIL

/* ONE session of the DB MANAGER (the record browser and its base-less face).
 *
 * It browses while there is a base. When the base is closed from one of its own
 * menus - `F2 > cLose Database` is an "R" row, so the menu stays open and the
 * Esc that follows only closes the menu - the user has NOT left the manager:
 * `CoreLeftByClosing()` says so and the session shows the base-less face (the
 * desktop: the menu bar and the status line, no browse) and keeps serving keys
 * there until Esc leaves it or a database is opened from its menus, which is
 * then browsed right here. Leaving the browser with Esc is what leaves the
 * manager, and it returns to the file manager. */
/* A6 of odd/tasks/f2-dbmanager.md: the file Windows handed over because it was
 * dropped on the executable, or "" when the program was started on its own.
 * `Main()` of this build does NOT receive the argument array - AGENTS.md trap 56
 * measured it: it gets the FIRST argument as a string -, so the command line is
 * read with hb_argc()/hb_argv(), exactly like HcFwArgsWanted() does for the
 * elevated firewall instance. A switch of the program itself is skipped: those
 * are attended before any screen exists. */
STATIC FUNCTION BpDbFromArgs( xArg )
   LOCAL i, cArg
   /* MEASURED here (2026-11-21, `BP_DEBUG=1`): the GUI executable receives the
    * file as the FIRST PARAMETER of Main() - `mainparam=["C:\...\CLIENTES.DBF"]` -
    * while `hb_argc()` answers **1** and `hb_argv( 1 )` comes back EMPTY. So the
    * parameter is the source and the command line stays only as a fallback for
    * the day the runtime fills it; reading `hb_argv()` alone would silently do
    * nothing at all (AGENTS.md trap 56, corrected with this measurement). */
   BpLog( "BpDbFromArgs: mainparam=[" + hb_ValToExp( xArg ) + "] argc=" + ;
          LTrim( Str( hb_argc() ) ) + " argv1=[" + ;
          iif( hb_argc() > 1, hb_argv( 1 ), "" ) + "]" )
   IF ValType( xArg ) == "C" .AND. ! Empty( xArg )
      cArg := StrTran( xArg, '"', "" )
      IF hb_vfExists( cArg )
         RETURN cArg
      ENDIF
   ENDIF
   FOR i := 1 TO hb_argc() - 1
      cArg := hb_argv( i )
      IF ValType( cArg ) != "C" .OR. Empty( cArg )
         LOOP
      ENDIF
      IF Left( cArg, 1 ) == "-"
         LOOP                       /* a switch of the program, not a file */
      ENDIF
      cArg := StrTran( cArg, '"', "" )   /* the shell may keep the quotes */
      IF hb_vfExists( cArg )
         RETURN cArg
      ENDIF
   NEXT
RETURN ""

STATIC PROCEDURE BpDbManagerSession()
   LOCAL lStay := .T., lArmed := .F.
   DO WHILE lStay .AND. ! BpExiting()
      IF Used()
         CoreBrowse()
         /* <Esc> leaves the browser through CoreBrowse(): every work area is
          * CLOSED here, so the file manager shows the picked row as a plain
          * file again instead of keeping it tinted with UI_C_PICKED, and
          * <Enter> on it reopens it as a fresh session. */
         IF ! BpExiting()
            CoreCloseAll()
         ENDIF
         /* Esc in the browser LEAVES the manager; closing the base does not
          * (A3), so only the second case loops back to the face below */
         lStay := ( ! BpExiting() .AND. CoreLeftByClosing() )
      ELSE
         /* The face serves keys until Esc (A2) and it needs its own CLICKS
          * (A4): a click on the menu bar opens that menu, exactly as in the
          * record browser. The window hook is armed here when it is not - the
          * file manager turns it OFF on its way out, so without this the click
          * channel answers nothing -, and removed on the way out only when this
          * routine was the one that armed it. */
         IF W32MOUSEHOOKON() == 0
            DotMouseHook( .T. )
            lArmed := .T.
         ENDIF
         lStay := .T.
         DO WHILE ! BpExiting() .AND. ! Used()
            BpDesktop()
            IF BpIdle() == K_ESC
               lStay := .F.
               EXIT
            ENDIF
         ENDDO
         IF lArmed .AND. ! Used()
            DotMouseHook( .F. )
            lArmed := .F.
         ENDIF
      ENDIF
   ENDDO
RETURN

STATIC FUNCTION BpIdle()
   LOCAL nKey, nShift := 0, aPt, nMenuAt, xDummy
   /* A2 of odd/tasks/f2-dbmanager.md: it answers the key it handled, because the
    * screen it serves - the DB manager without a base - stays until the user
    * leaves it with Esc, and the caller cannot ask LastKey() for that: DoMenu()
    * reads keys of its own and the last one would be the Esc that closed a menu.
    * `0` means "nothing to answer" (the window close), which the exit flag of
    * BpCloseAsk() already covers. */
   /* S1/S4 of window-close.md (B3): this was the only BLOCKING wait of the
    * program (Inkey( 0 )), so the latch of the window hook could never be seen
    * on the desktop - the screen that shows while no database is open. The
    * wait is the same 50 ms slice the rest of the loops use and the poll sits
    * in the slice, with nothing to lose: the wait keeps no state of its own
    * and the key is handled by the DO CASE below exactly as before, because an
    * idle slice (0) only LOOPs. When the close is the answer the procedure
    * RETURNs - the desktop has saved nothing and its caller (Main()) ends the
    * program through `DO WHILE ! BpExiting()` - and no `Exit hwBro?` is asked
    * (L7). */
   DO WHILE .T.
      nKey := Inkey( 0.05 )
      /* AGENTS.md trap 37: the modifier state is the LIVE one, so it is read
       * IMMEDIATELY after Inkey() and before anything else - the accelerator
       * map of the DB manager needs it (S5/T3 of menu-accelerators.md). */
      nShift := iif( nKey != 0, HcShiftState(), 0 )
      IF nKey != 0
         EXIT
      ENDIF
      IF BpCloseAsk()
         RETURN 0
      ENDIF
      /* A4 of f2-dbmanager.md: THE MOUSE of this face. A click on the menu bar
       * opens that menu, exactly as it does in the record browser (the same
       * BpMenuBarAt()/DoMenu() pair, so the two screens cannot diverge), and
       * the other two channels are drained so a click made here can never act
       * later, inside the file manager. BpDbManagerSession() arms the window
       * hook around this face: the file manager turns it off on its way out. */
      aPt := UiClick()
      xDummy := UiClickDbl()
      xDummy := UiMouseWheel()
      IF HB_ISARRAY( aPt )
         nMenuAt := BpMenuBarAt( aPt[ 1 ], aPt[ 2 ], UiCols() )
         IF nMenuAt > 0
            DoMenu( nMenuAt )
            RETURN 0                   /* handled: the face is repainted and waits */
         ENDIF
      ENDIF
   ENDDO
   BpLog( "BpIdle key=" + LTrim( Str( nKey ) ) + " shift=" + LTrim( Str( nShift ) ) )
   DO CASE
   CASE nKey == K_F1 ; BpHelp()
   CASE nKey == K_F2 ; DoMenu( 2 )      /* A4: the Database menu, as in the browser */
   CASE nKey == K_F3 ; DoMenu( 3 )
   CASE nKey == K_F4 ; DoMenu( 4 )
   CASE nKey == K_F5 ; DoMenu( 5 )
   CASE nKey == K_F6 ; DoMenu( 6 )
   CASE nKey == K_F7 ; DoMenu( 7 )
   CASE nKey == K_F8 ; DoMenu( 8 )
   CASE nKey == K_F9 ; BpDot()
   /* S5/T3 (menu-accelerators.md): the SAME global map the record browser
    * dispatches, so this face and the browser cannot diverge. Alt-X (Exit),
    * Alt-F2 (Database Selection Screen), Alt-Y and Alt-Z used to have a
    * K_ALT_* case here that only Alt-F2 ever reached: the driver hands
    * `Alt+<letter>` as the BARE LETTER plus the ALT bit (trap 37), so those
    * cases are gone and the map runs the same block the menu row runs. */
   CASE BpAccelRun( nKey, nShift )
      /* the row may have opened a database, closed one or left the program:
       * the caller repaints the face and checks the exit flag on its own */
   ENDCASE
RETURN nKey

/* ---------------------------------------------------------------
 *  Menu bar
 * --------------------------------------------------------------- */

/* Positions of the nine menu chips. They stay LEFT-ANCHORED on the wider
 * canvas on purpose: reading order of F1..F9 does not change and the bar keeps
 * the muscle memory of the original. The bar BACKGROUND spans the whole width
 * (see BpMenuBar) and its right end carries the application tag. */
STATIC FUNCTION BpCols()
RETURN { 1, 8, 19, 27, 36, 45, 56, 64, 73 }

/* U2: menu index (1..9) under a click on the menu bar, or 0 when the click is
 * not on one of its labels. Rows 0 (F1..F9 chips) and 1 (the labels) both count:
 * the click lands on the label it is drawn on. A label spans from its own column
 * to the next one; the last one ends after its own text, so clicking the empty
 * right end of the bar is NOT "Dot". */
FUNCTION BpMenuBarAt( nRow, nCol, nCols )
   LOCAL aC, aN, i, n := 0, nEnd
   DEFAULT nCols TO UiCols()
   IF ValType( nRow ) != "N" .OR. ValType( nCol ) != "N"
      RETURN 0
   ENDIF
   IF nRow != 0 .AND. nRow != 1
      RETURN 0
   ENDIF
   aC := BpCols()
   aN := BpNames()
   FOR i := 1 TO Len( aC )
      nEnd := iif( i < Len( aC ), aC[ i + 1 ] - 1, Min( nCols - 1, aC[ i ] + Len( aN[ i ] ) + 2 ) )
      IF nCol >= aC[ i ] .AND. nCol <= nEnd
         RETURN i
      ENDIF
   NEXT
RETURN n

/* U2: option index of the dropdown under a click, or 0 when the click is not on
 * an option row (border, information block, separator line, outside). BpMenuRow()
 * paints item i on row nT2 + i, so that is the mapping here: the first option is
 * one row BELOW nT2, never on the border. */
FUNCTION BpMenuItemAt( nRow, nCol, nT2, nL, nR, nItems )
   LOCAL n
   IF ValType( nRow ) != "N" .OR. ValType( nCol ) != "N"
      RETURN 0
   ENDIF
   IF nCol < nL .OR. nCol > nR
      RETURN 0
   ENDIF
   n := nRow - nT2
   IF n < 1 .OR. n > nItems
      RETURN 0
   ENDIF
RETURN n


STATIC FUNCTION BpNames()
RETURN { "Help", "Database", "Index", "Fields", "AreaSet", "GlobalSet", "Record", "Command", "Dot" }

STATIC FUNCTION BpKeys()
RETURN { "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9" }

/* Menu bar as the original draws it: row 0 = F1..F9 in white
 * on dark gray; row 1 = each label in its cyan "chip" with black text
 * (the active label, in white on red).
 * Both rows now cover the whole canvas (UiCols() columns) and the right end of
 * row 0 carries the application tag, so the 120-wide bar is not a long empty
 * stretch: the Chrome keeps its left-anchored order and the bar reads as a
 * title bar. */
FUNCTION BpMenuBar( nActive )
   LOCAL aC := BpCols(), aN := BpNames(), aK := BpKeys(), i, cTag
   DEFAULT nActive TO 0
   SetColor( UI_C_MENUBAR )
   @ 0, 0 SAY Space( UiCols() )
   @ 1, 0 SAY Space( UiCols() )
   FOR i := 1 TO 9
      SetColor( UI_C_MENUKEY )
      @ 0, aC[ i ] SAY aK[ i ]
      IF i == nActive
         SetColor( UI_C_MENUACT )
      ELSE
         SetColor( UI_C_MENULBL )
      ENDIF
      @ 1, aC[ i ] SAY aN[ i ]
   NEXT
   cTag := BP_APPNAME + " " + BP_VERSION
   IF UiCols() - Len( cTag ) - 1 > aC[ 9 ] + Len( aN[ 9 ] )
      SetColor( UI_C_MENUKEY )
      @ 0, UiCols() - Len( cTag ) - 1 SAY cTag
   ENDIF
   SetColor( UI_C_DESKTOP )
RETURN NIL

/* Definition of the drop-down menus (they are rebuilt on every opening).
 * CAREFUL: <Alt-X> is Exit (F9 opens the dot prompt); the Open Mode is toggled
 * with Enter on the menu items (mark "R" = keeps the menu open and repaints it),
 * so NO item must announce "Alt-X" as Open Mode.
 * CAREFUL: no multi-line comments inside this RETURN: Harbour does not
 * accept them in an expression continued with ";" (measured: E0020). */
STATIC FUNCTION BpMenus()
   LOCAL cMode := iif( CoreOpenMode() == "SHARED", "SHARED    ", "EXCLUSIVE " )
   LOCAL lMulti := ( Len( CoreAreas() ) >= 2 )     /* more than one database open */
   LOCAL lAny := Used()                            /* there is an active database */
   LOCAL cNoDb := iif( lAny, "", "D" )             /* no database: option not available */
   LOCAL cNoMulti := iif( lMulti, "", "D" )
   LOCAL cR := "R"                                 /* keeps the menu open (repaints the value) */
RETURN { ;
   { ;
      { "~H~elp",            "H",       {|| BpHelp() } }, ;
      { "",                 "",        NIL }, ;
      { "Hot-~K~eys",        "K",       {|| BpHotKeys() } } ;
   }, ;
   { ;
      { "~D~atabase Selection Screen", "Alt-F2",   {|| BpDbPickHc() } }, ;
      { "~N~ext Database",             "Alt-N",    {|| BpDbNext() },     cNoMulti }, ;
      { "~P~revious Database",         "Alt-Minus",{|| BpDbPrev() },     cNoMulti }, ;
      { "c~L~ose Database",            "",         {|| BpDbClose() },    iif( lAny, cR, "D" ) }, ;
      { "", "", NIL }, ;
      { "~O~pen Mode:     " + cMode,   "",         {|| BpDbToggleMode() }, cR }, ;
      { "~A~lias Name:    " + iif( Used(), Alias(), "" ), "", {|| BpDbAlias() }, iif( lAny, cR, "D" ) }, ;
      { "Create/~M~odify Structure",   "",       {|| BpDbCreateModify() } }, ;
      { "~G~enerate Structure(.PRG)",   "",       {|| BpDbGenPrg() }, cNoDb }, ;
      { "", "", NIL }, ;
      { "Database ~F~ileSpec:   " + CoreDbfSpec(), "", {|| BpDbFileSpec() }, cR }, ;
      { "~C~hange Directory",          "Alt-Y",  {|| BpDbChangeDir() } }, ;
      { "~S~hell to DOS",              "Alt-Z",  {|| BpDbShell() } } ;
   }, ;
   { ;
      { "~I~ndex File Selection Screen", "Alt-F3",  {|| BpIdxSelectScreen() }, cNoDb }, ;
      { "~N~ext Order",                "Alt-O",   {|| BpIdxNextOrder() },   cNoDb }, ;
      { "~P~revious Order",            "",        {|| BpIdxPrevOrder() },   cNoDb }, ;
      { "~T~ag Selection/Information", "Ctrl-F3", {|| BpIdxTagInfo() },     cNoDb }, ;
      { "Index ~S~cope Top/Bottom",    "Shift-F3",{|| BpIdxScope() },       cNoDb }, ;
      { "d~Y~namic Index Options...",  "",        {|| BpIdxDynOptions() },  cNoDb }, ;
      { "", "", NIL }, ;
      { "~O~pen Mode: " + cMode,       "",        {|| BpDbToggleMode() } }, ;
      { "c~R~eate Index File",         "",        {|| BpIdxCreate() },      cNoDb }, ;
      { "Recre~A~te Index File",       "",        {|| BpIdxRecreate() },    cNoDb }, ;
      { "~V~erify Index File Integrity","",       {|| BpIdxVerify() },      cNoDb }, ;
      { "", "", NIL }, ;
      { "Index ~F~ileSpec: " + CoreIdxSpec(), "", {|| BpIdxFileSpec() } }, ;
      { "~C~hange Directory",          "Alt-Y",   {|| BpDbChangeDir() } }, ;
      { "Sh~E~ll to DOS",              "Alt-Z",   {|| BpDbShell() } } ;
   }, ;
   { ;
      { "~F~ield Selection Screen", "Alt-F4",  {|| BpFldSelectScreen() } }, ;
      { "~C~ut/Delete Column",      "Shift-F5",{|| BpFldCutColumn() } }, ;
      { "~P~aste Column",           "Ctrl-F5", {|| BpFldPasteColumn() } }, ;
      { "~I~nsert Column",          "Alt-F5",  {|| BpFldInsertColumn() } }, ;
      { "~L~ock # of Fields: " + LTrim( Str( CoreLockFields() ) ), "Alt-L", {|| BpFldLockNum() } }, ;
      { "Column ~O~ptions...",      "Alt-H",   {|| BpFldColumnOptions() } }, ;
      { "Create/~M~odify Structure","",        {|| BpDbCreateModify() } }, ;
      { "", "", NIL }, ;
      { "Fl~E~xFile Pointer Field: NO", "", {|| BpFlexFileLink() }, "I" }, ;
      { "Edit ~T~op Pointer",       "",        {|| BpEditTopPointer() }, "I" } ;
   }, ;
   { ;
      { "Range & ~F~ilter",              "Alt-F",  {|| BpAreaRangeFilter() } }, ;
      { "~R~elation",                    "Alt-R",  {|| BpAreaRelation() } }, ;
      { "~C~olor Condition",             "Alt-C",  {|| BpAreaColorCond() } }, ;
      { "~I~ncremental Seek is " + iif( CoreIncrSeek(), "ON", "OFF" ), "Alt-I", {|| BpAreaToggleIncr() } }, ;
      { "Memo ~W~idth: " + LTrim( Str( CoreMemoWidth() ) ), "", {|| BpAreaMemoWidth() } }, ;
      { "~M~emo Pack (Six Driver)",      "",       {|| BpAreaMemoPack() } }, ;
      { "f~L~exFile Link:  NO",          "",       {|| BpFlexFileLink() }, "I" }, ;
      { "R~Y~O Index Link:  NO",         "",       {|| BpRyoLink() }, "I" }, ;
      { "", "", NIL }, ;
      { "~N~ext Select Area",            "",        {|| BpAreaSelect() } }, ;
      { "~P~rev. Select Area",           "",        {|| BpAreaSelect() } }, ;
      { "Next Index ~O~rder",            "",        {|| BpAreaNextOrder() } }, ;
      { "", "", NIL }, ;
      { "Ne~X~t Window",                 "Tab",    {|| BpAreaViewInfo() } }, ;
      { "Pr~E~vious Window",             "Shift-Tab", {|| BpAreaViewInfo() } }, ;
      { "", "", NIL }, ;
      { "Restore ~V~iew",                "Alt-V",  {|| BpAreaViewInfo() } }, ;
      { "~S~ave Current View",           "Alt-W",  {|| BpAreaViewInfo() } }, ;
      { "Curren~T~ View Info",           "",       {|| BpAreaViewInfo() } } ;
   }, ;
   { ;
      { "Database d~R~iver: " + CoreDriver(), "", {|| BpGlobDriver() } }, ;
      { "Default ~O~pen Mode: " + cMode, "", {|| BpDbToggleMode() } }, ;
      { "~D~ate Format: " + UiDateFormatName(), "", {|| BpGlobDateFormat() } }, ;
      { "E~p~och: " + LTrim( Str( UiDateEpoch() ) ), "", {|| BpGlobEpoch() } }, ;
      { "~C~ell Edit: " + iif( CoreCellEdit(), "ON", "OFF" ), "", {|| BpGlobToggleCellEdit() } }, ;
      { "H~I~de Deleted Recs is " + iif( CoreHideDel(), "ON", "OFF" ), "Alt-D", {|| BpGlobToggleHideDel() } }, ;
      { "~S~oftseek is " + iif( CoreSoftSeek(), "ON", "OFF" ), "Alt-Q", {|| BpGlobToggleSoftSeek() } }, ;
      { "", "", NIL }, ;
      { "~T~heme Colors...", "", {|| BpThemeColors() } }, ;
      { "Sa~V~e Configuration", "", {|| BpCfgSave() } } ;
   }, ;
   { ;
      { "~S~eek",          "Alt-S",   {|| BpRecSeek() } }, ;
      { "~G~oto",          "Alt-G",   {|| BpRecGoto() } }, ;
      { "~L~ocate",        "Alt-U",   {|| BpRecLocate() } }, ;
      { "sk~I~p",          "Alt-J",   {|| BpRecSkip() } }, ;
      { "Go ~T~op",        "Alt-T",   {|| BpRecTop() } }, ;
      { "Go ~B~ottom",     "Alt-B",   {|| BpRecBottom() } }, ;
      { "", "", NIL }, ;
      { "Record View/Edit:", "", NIL, "T" }, ;
      { "~A~ll Fields",        "Alt-A",   {|| BpRecViewAll() } }, ;
      { "s~E~lected Flds",     "Alt-E",   {|| BpRecViewSelected() } }, ;
      { "Ap~P~end Record",     "Ins",     {|| CoreAppend() } }, ;
      { "~D~elete/Recall",     "Del",     {|| CoreDeleteRecall() } }, ;
      { "Erase ~M~emo",        "Alt-BSpc",{|| BpRecEraseMemo() } }, ;
      { "", "", NIL }, ;
      { "~C~opy Field",    "Shift-F4", {|| BpRecCopyField() } }, ;
      { "Paste ~F~ield",   "Ctrl-F4",  {|| BpRecPasteField() } }, ;
      { "c~O~py Record",   "Shift-F7", {|| BpRecCopyRecord() } }, ;
      { "Paste ~R~ecord",  "Ctrl-F7",  {|| BpRecPasteRecord() } }, ;
      { "~V~iew Clipboard","Alt-F7",   {|| BpRecViewClip() } } ;
   }, ;
   { ;
      { "~A~ppend From",      "",        {|| BpCmdAppendFrom() } }, ;
      { "~C~opy Structure",   "",        {|| BpCmdCopyStructure() } }, ;
      { "Copy Stru E~X~td",   "",        {|| BpCmdCopyStructure() } }, ;
      { "C~O~py To",          "",        {|| BpCmdCopyTo() } }, ;
      { "Coun~T~",            "",        {|| BpCmdCount() } }, ;
      { "~D~elete",           "",        {|| BpCmdDelete() } }, ;
      { "L~I~st to Print",    "",        {|| BpCmdListToPrint() } }, ;
      { "~P~ack",             "",        {|| BpCmdPack() } }, ;
      { "~R~ecall",           "",        {|| BpCmdRecall() } }, ;
      { "Rei~N~dex",          "",        {|| BpCmdReindex() } }, ;
      { "R~E~place",          "",        {|| BpCmdReplace() } }, ;
      { "~S~um/Average",      "",        {|| BpCmdSumAverage() } }, ;
      { "~Z~ap",              "",        {|| BpCmdZap() } } ;
   }, ;
   { ;
      { "~D~ot Prompt",       "",        {|| BpDot() } }, ;
      { "", "", NIL }, ;
      { "E~X~it hwBro?",   "Alt-X",   {|| BpExit() } } ;
   } ;
}

/* S6(c) of menu-accelerators.md, about the three rows of menu 5 that no longer
 * announce a shortcut: `Alt-N` and `Alt-Minus` belong to Next/Previous Database
 * (S6b says the row that comes first in menu order wins, and that is F2), and
 * `Alt-U` belongs to `Locate` of F7, which already answered it (S6a). The three
 * actions stay reachable from the menu; the screen simply no longer promises a
 * key that opens another action. `Tab`, `Shift-Tab`, `Ins` and `Del` keep their
 * text because those strokes already mean something in this screen (S6a). */

/* =====================================================================
 *  GLOBAL accelerators of the DB manager (menu-accelerators.md, S4-S6)
 *
 *  The right column of the menu rows announces a shortcut ("Alt-F2",
 *  "Shift-F4", ...) and only the F7 block ever answered it: the driver hands
 *  `Alt+<letter>` to Inkey() as the BARE LETTER plus the ALT bit (trap 37), so
 *  the `CASE nKey == K_ALT_X` family never ran. The map below is built from the
 *  shortcut text of the rows THEMSELVES (S4), so a row and its accelerator can
 *  never diverge: change the text of a row and the map changes with it.
 *
 *  Only ONE of these helpers is PUBLIC, and for a reason of the language: the
 *  browser that has to use it is CoreBrowse(), of bp_core.prg, and a STATIC of
 *  this module is unreachable from another module. BpAccelRun() is that single
 *  door; everything else here is STATIC.
 * ===================================================================== */

/* S6(a): the accelerators that ALREADY have a handler of their own -the F7
 * block of the browser plus Ctrl-F3- and therefore KEEP their meaning, even
 * against a row that comes first in menu order. That is what makes Alt-U stay
 * `Locate` (F7) instead of `Next Index Order` (F5). The list does NOT hold any
 * accelerator of its own: it only breaks a tie, while the accelerator-to-action
 * map is still read from BpMenus() (S4). */
STATIC FUNCTION BpAccelKept()
RETURN { "ALT-S", "ALT-G", "ALT-U", "ALT-J", "ALT-T", "ALT-B", "ALT-A", ;
         "ALT-E", "ALT-BSPC", "SHIFT-F4", "CTRL-F4", "SHIFT-F7", "CTRL-F7", ;
         "ALT-F7", "CTRL-F3" }

/* 1-based index of cName in the string list aList, or 0 */
STATIC FUNCTION BpAccelPos( aList, cName )
   LOCAL i
   FOR i := 1 TO Len( aList )
      IF aList[ i ] == cName
         RETURN i
      ENDIF
   NEXT
RETURN 0

/* .T. when the map already has an owner for cName */
STATIC FUNCTION BpAccelOwned( aMap, cName )
   LOCAL i
   FOR i := 1 TO Len( aMap )
      IF aMap[ i ][ 1 ] == cName
         RETURN .T.
      ENDIF
   NEXT
RETURN .F.

/* the map, { { cName, nMenu, nItem }, ... }, built once from BpMenus().
 * The shortcut texts are compile-time constants of the rows (what changes at run
 * time is their VALUE -the open mode, the alias, the record count-), so the map
 * is cached: one keystroke of the browser must not rebuild the nine menus. */
STATIC FUNCTION BpAccelMap()
   LOCAL aMenus, aItems, aKept, i, j, nPass, cName, lKept, oErr, cTok
   IF ! Empty( s_aBpAccel )
      RETURN s_aBpAccel
   ENDIF
   s_aBpAccel := {}
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      aMenus := BpMenus()
   RECOVER USING oErr
      BpLog( "  ERROR in BpMenus (accel map): " + oErr:Description )
      RETURN s_aBpAccel
   END SEQUENCE
   aKept := BpAccelKept()
   /* TWO passes, so the tie is broken the way S6 asks: first the accelerators
    * that already work (S6a), then the rows in menu order F1..F8 (S6b: Alt-N is
    * Next Database of F2 and Alt-Minus is Previous Database of F2, not the
    * Select Area rows of F5). Inside a pass the FIRST owner keeps the name and
    * the rest is told nothing: two rows with the same shortcut and the same
    * action are not a collision (S6d, Alt-Y / Alt-Z of F2 and F3). */
   FOR nPass := 1 TO 2
      /* 1..9: the last one holds `Exit hwBro?` <Alt-X>, which is the very case
       * the dead K_ALT_X of the browser was supposed to serve */
      FOR i := 1 TO Min( 9, Len( aMenus ) )
         aItems := aMenus[ i ]
         FOR j := 1 TO Len( aItems )
            IF Len( aItems[ j ] ) < 2 .OR. ValType( aItems[ j ][ 2 ] ) != "C"
               LOOP
            ENDIF
            cName := UiAccelName( aItems[ j ][ 2 ] )
            IF Empty( cName )
               LOOP
            ENDIF
            lKept := ( BpAccelPos( aKept, cName ) > 0 )
            IF iif( nPass == 1, ! lKept, lKept )
               LOOP
            ENDIF
            /* S6(a): a stroke that this screen ALREADY dispatches keeps its own
             * meaning and never enters the global map - `Tab` and `Shift-Tab`
             * walk the cell cursor, `Ins` appends and `Del` marks the record -, so
             * the five rows of the AreaSet menu that announce `Tab`,
             * `Shift-Tab` and the two of F7 that announce `Ins`/`Del` stay out of
             * it (their actions are in the menu). A function key WITHOUT a
             * modifier has no other use in this screen, so `F10` does enter, and
             * any stroke with ALT/SHIFT/CTRL of another key too. */
            cTok := iif( At( "-", cName ) > 0, SubStr( cName, At( "-", cName ) + 1 ), cName )
            IF cTok == "TAB" .OR. cTok == "INS" .OR. cTok == "DEL"
               LOOP
            ENDIF
            IF At( "-", cName ) == 0 .AND. Left( cName, 1 ) != "F"
               LOOP
            ENDIF
            IF BpAccelOwned( s_aBpAccel, cName )
               LOOP
            ENDIF
            AAdd( s_aBpAccel, { cName, i, j } )
         NEXT
      NEXT
   NEXT
RETURN s_aBpAccel

/* { nMenu, nItem } of the row that owns the accelerator this stroke means, or
 * {} when the stroke is not an accelerator of the manager. */
STATIC FUNCTION BpAccelFind( nKey, nShift )
   LOCAL aMap := BpAccelMap(), i
   FOR i := 1 TO Len( aMap )
      IF UiAccelHit( aMap[ i ][ 1 ], nKey, nShift )
         RETURN { aMap[ i ][ 2 ], aMap[ i ][ 3 ] }
      ENDIF
   NEXT
RETURN {}

/* Runs the row that owns this stroke and answers .T. when it ran something.
 * It runs the SAME block `[3]` the menu runs, with the cFlag discipline of
 * BpNavOk(): a "D" row never fires, a "T" group label never fires and an "I"
 * row does fire. There is no menu open, so neither RestScreen() nor
 * BpMenuBar( 0 ) is needed here. PUBLIC because the browser that dispatches it
 * is CoreBrowse(), of bp_core.prg: a STATIC of this module is unreachable from
 * there, and this is the only door of the map. */
FUNCTION BpAccelRun( nKey, nShift )
   LOCAL aAt := BpAccelFind( nKey, nShift ), aItems, nItem, bAction, cType
   LOCAL cName := "", oErr
   IF Empty( aAt )
      RETURN .F.
   ENDIF
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      aItems := BpMenus()[ aAt[ 1 ] ]
   RECOVER USING oErr
      BpLog( "  ERROR in BpMenus (accel run): " + oErr:Description )
      RETURN .F.
   END SEQUENCE
   nItem := aAt[ 2 ]
   IF nItem < 1 .OR. nItem > Len( aItems )
      RETURN .F.
   ENDIF
   cName := UiAccelName( aItems[ nItem ][ 2 ] )
   cType := iif( Len( aItems[ nItem ] ) >= 4, Upper( aItems[ nItem ][ 4 ] ), "" )
   /* the cFlag discipline is BpNavOk()'s ("D" is skipped), plus the group
    * label "T", which BpNavOk() lets through because the menu never runs it */
   IF cType == "T" .OR. ! BpNavOk( aItems, nItem )
      BpLog( "  accel " + cName + " not available (" + cType + ")" )
      RETURN .F.
   ENDIF
   bAction := aItems[ nItem ][ 3 ]
   IF Empty( bAction ) .OR. ValType( bAction ) != "B"
      RETURN .F.
   ENDIF
   BpLog( "  accel " + cName + " -> " + LTrim( Str( aAt[ 1 ] ) ) + "/" + ;
          LTrim( Str( nItem ) ) )
   Eval( bAction )
RETURN .T.

/* Information block the original shows at the top of some menus
 * (F2 Database, F3 Index, F4 Fields). It returns a list of { label, value } */
STATIC FUNCTION BpMenuHdr( nMenu )
   LOCAL aAreas := CoreAreas(), aV, i, nPos := 0, cFile := ""
   FOR i := 1 TO Len( aAreas )
      IF aAreas[ i ][ 1 ] == Select()
         nPos := i
      ENDIF
   NEXT
   IF Used()
      /* the original shows the FILE name, not the alias (measured: after
       * renaming the alias to XY the header still says CLIENTES.DBF) */
      cFile := Upper( CoreFileBase() ) + ".DBF"
   ENDIF
   DO CASE
   CASE nMenu == 2
      /* header measured on the original:
       *   Selected:  (1/1)  ARTICULO.DBF
       *   Controll. Driver:  DBFCDX / DBT      <- "Controll." is like that in the original */
      RETURN { ;
         { "Selected:  (", LTrim( Str( nPos ) ) + "/" + LTrim( Str( Len( aAreas ) ) ) + ")  " + ;
                           iif( Empty( cFile ), "None", cFile ), 12 }, ;
         { "Controll. Driver:", iif( Empty( cFile ), "", CoreDriver() + " / " + CoreMemoExt() ), 19 } }
   CASE nMenu == 4
      aV := CoreView()
      RETURN { ;
         { "Selected Database:", iif( Empty( cFile ), "None", cFile ) }, ;
         { "Viewing:", iif( CoreShowSelected(), "Selected Flds", "All Fields" ) }, ;
         { "Column:", "(" + LTrim( Str( CoreSelCol() ) ) + "/" + LTrim( Str( Len( aV ) ) ) + ")  " + ;
                     iif( CoreSelCol() >= 1 .AND. CoreSelCol() <= Len( aV ), aV[ CoreSelCol() ][ 2 ], "" ) } }
   CASE nMenu == 3
      /* With no database open the order cannot be asked for: OrdName() throws
       * "Workarea not in use" and BpFatal() closed the whole application
       * (measured: pressing F3 on the Database Selection Screen, with no database). */
      IF ! Used()
         RETURN { ;
            { "Selected Database:", "None" }, ;
            { "Current Index:", "" }, ;
            { "Current Tag:", "" }, ;
            { "Key:", "" } }
      ENDIF
      RETURN { ;
         { "Selected Database:", iif( Empty( cFile ), "None", cFile ) }, ;
         { "Current Index:", BpIdxHeaderText() }, ;
         { "Current Tag:", "(" + LTrim( Str( BpTagPos() ) ) + "/" + LTrim( Str( BpTagCount() ) ) + ") " + OrdName() }, ;
         { "Key:", "(" + CoreKeyExpr() + ")" } }
   ENDCASE
RETURN {}

/* position and number of tags of the current index (for the F3 block) */
STATIC FUNCTION BpTagCount()
   LOCAL n := 0
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      n := dbOrderInfo( DBOI_ORDERCOUNT )
   RECOVER
      n := 0
   END SEQUENCE
RETURN n

STATIC FUNCTION BpTagPos()
   LOCAL n := 1
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      n := OrdNumber()
   RECOVER
      n := 1
   END SEQUENCE
RETURN n

/* Draws one row (option) of the drop-down menu. If i == nSel it is painted with the
 * unavailable options (4th element = "D") and the group labels ("T") are
 * drawn dimmed, and the shortcuts go between "<>", as in the original. */
STATIC PROCEDURE BpMenuRow( aItems, i, nT, nL, nR, nSel )
   LOCAL nWid, cTxt, cShort, cType, lDim
   IF i < 1 .OR. i > Len( aItems )
      RETURN
   ENDIF
   cTxt   := aItems[ i ][ 1 ]
   cShort := iif( Len( aItems[ i ] ) >= 2 .AND. ! Empty( aItems[ i ][ 2 ] ), aItems[ i ][ 2 ], "" )
   cType  := iif( Len( aItems[ i ] ) >= 4, aItems[ i ][ 4 ], "" )
   IF Empty( cTxt )
      /* separator: the original paints it in DARK GRAY over the cyan */
      SetColor( UI_C_BOXDIM )
      @ nT + i, nL + 1 SAY Replicate( Chr( 196 ), nR - nL - 1 )
      SetColor( UI_C_DESKTOP )
      RETURN
   ENDIF
   lDim := ( cType == "D" .OR. cType == "T" .OR. cType == "I" )
   /* nWid is no longer used to cut the text: the width of the box is computed
    * with UiHotLen() (without the ~ marks), so cutting with nWid cut exactly
    * the last characters of "Database Selection Screen". */
   nWid := Max( 1, nR - nL - 3 - iif( Empty( cShort ), 0, Len( cShort ) + 2 ) )
   IF i == nSel
      SetColor( UI_C_BOXSEL )
      @ nT + i, nL + 1 SAY Space( nR - nL - 1 )
      IF lDim
         /* dimmed: everything in gray, but WITHOUT leaving the ~X~ marks
          * in view (before, the raw text was printed) */
         UiDrawHot( nT + i, nL + 1, cTxt, UI_C_BOXSEL, UI_C_BOXSEL )
      ELSE
         UiDrawHot( nT + i, nL + 1, cTxt, UI_C_BOXSEL, UI_C_HOTSEL )
      ENDIF
   ELSE
      SetColor( UI_C_BOX )
      @ nT + i, nL + 1 SAY Space( nR - nL - 1 )
      IF lDim
         UiDrawHot( nT + i, nL + 1, cTxt, UI_C_BOXDIM, UI_C_BOXDIM )
      ELSE
         UiDrawHot( nT + i, nL + 1, cTxt, UI_C_BOX, UI_C_HOT )
      ENDIF
   ENDIF
   IF ! Empty( cShort )
      IF i == nSel
         SetColor( UI_C_BOXSEL )
      ELSE
         SetColor( UI_C_BOX )
      ENDIF
      /* measured on the original: the shortcut ends 1 cell before the inner
       * border (<Alt-F2> takes columns 34..41) */
      @ nT + i, Max( nL + 1, nR - Len( cShort ) - 3 ) SAY "<" + cShort + ">"
   ENDIF
   SetColor( UI_C_DESKTOP )
RETURN NIL

/* When the selection moves only the two affected rows are repainted */
STATIC PROCEDURE BpMenuRows2( aItems, nOld, nNew, nT, nL, nR )
   IF nOld == nNew
      RETURN
   ENDIF
   UiPaintBegin()
   BpMenuRow( aItems, nOld, nT, nL, nR, nNew )
   BpMenuRow( aItems, nNew, nT, nL, nR, nNew )
   UiPaintEnd()
RETURN NIL

/* can row n be selected? (neither a separator nor an unavailable option "D").
 * The original SKIPS the dimmed options with the arrows. */
STATIC FUNCTION BpNavOk( aItems, n )
   LOCAL cType
   IF n < 1 .OR. n > Len( aItems )
      RETURN .F.
   ENDIF
   IF Empty( aItems[ n ][ 1 ] )
      RETURN .F.
   ENDIF
   cType := iif( Len( aItems[ n ] ) >= 4, Upper( aItems[ n ][ 4 ] ), "" )
RETURN ( cType != "D" )

/* first selectable option whose hot key (~x~) is cChr (0 when there is none) */
STATIC FUNCTION BpFindHot( aItems, nItems, cChr )
   LOCAL i, cHot
   FOR i := 1 TO nItems
      IF ! BpNavOk( aItems, i )
         LOOP
      ENDIF
      cHot := UiHotKey( aItems[ i ][ 1 ] )
      IF ! Empty( cHot ) .AND. Left( cHot, 1 ) == cChr
         RETURN i
      ENDIF
   NEXT
RETURN 0

/* Opens the drop-down menu nMenu with full navigation (no recursion) */
FUNCTION DoMenu( nMenu )
   LOCAL aItems, aHdr, aC := BpCols(), aN := BpNames()
   LOCAL nT, nT2, nL, nR, nB, i, nSel, nKey, cSave, nMax, nItems, bAction, oErr, nWid, nO
   LOCAL nHdr, nHdrPad, lExit := .F., lRelayout := .T., lDone, cType, lDo := .F., nHot
   LOCAL aPt, nRow, nMenuAt, nItemAt, nShift := 0

   IF nMenu == 9
      /* F9 opens the dot prompt directly: there is no need to drop down menu 9 */
      BpDot()
      RETURN NIL
   ENDIF
   BpLog( "DoMenu " + LTrim( Str( nMenu ) ) )

   DO WHILE ! lExit
      IF lRelayout
         BpLog( "  building menus for " + LTrim( Str( nMenu ) ) )
         BEGIN SEQUENCE WITH {| e | Break( e ) }
            aItems := BpMenus()[ nMenu ]
         RECOVER USING oErr
            BpLog( "  ERROR in BpMenus: " + oErr:Description + " / " + hb_CStr( oErr:SubSystem ) )
            aItems := { { "(error)", "", NIL } }
         END SEQUENCE
         nItems := Len( aItems )
         aHdr := BpMenuHdr( nMenu )
         nHdr := Len( aHdr )
         BpLog( "  items=" + LTrim( Str( nItems ) ) + " hdr=" + LTrim( Str( nHdr ) ) )
         nMax := 0
         FOR i := 1 TO nItems
            nMax := Max( nMax, UiHotLen( aItems[ i ][ 1 ] ) + ;
                         iif( Empty( aItems[ i ][ 2 ] ), 0, Len( aItems[ i ][ 2 ] ) + 4 ) )
         NEXT
         nHdrPad := 0
         FOR i := 1 TO nHdr
            nMax := Max( nMax, Len( aHdr[ i ][ 1 ] ) + 1 + Len( aHdr[ i ][ 2 ] ) )
            nHdrPad := Max( nHdrPad, Len( aHdr[ i ][ 1 ] ) )
         NEXT
         IF nHdr > 0
            nHdrPad++
         ENDIF
         /* width measured on the original: the F2 box takes columns
          * 7..43 (37 cells) with the longest text of 35 characters
          * ("Database Selection Screen" + "  <Alt-F2>"). */
         nL := Max( 0, aC[ nMenu ] - 1 )
         nR := Min( MaxCol() - 2, nL + nMax + 1 )
         /* with a header block a separator line is added between the
          * header and the options (like the original) and no blank
          * row is left before the bottom border */
         nB := nItems + nHdr + iif( nHdr > 0, 1, 0 ) + 1
         nT := 2
         nT2 := nT + nHdr + iif( nHdr > 0, 1, 0 )
         nSel := 1
         DO WHILE nSel <= nItems .AND. Empty( aItems[ nSel ][ 1 ] )
            nSel++
         ENDDO
         BpLog( "  layout t=" + LTrim( Str( nT ) ) + " l=" + LTrim( Str( nL ) ) + ;
                " b=" + LTrim( Str( nT + nB ) ) + " r=" + LTrim( Str( nR ) ) + ;
                " items=" + LTrim( Str( nItems ) ) + " sel=" + LTrim( Str( nSel ) ) )
         cSave := SaveScreen( nT, nL, nT + nB + 1, Min( nR + 2, MaxCol() ) )
         lRelayout := .F.
      ENDIF

      BpMenuBar( nMenu )
      /* shadow + box + options, all at once (no flicker) */
      UiPaintBegin()
      UiShadow( nT, nL, nT + nB, nR )
      SetColor( UI_C_BOX )
      FOR i := nT TO nT + nB
         @ i, nL SAY Space( nR - nL + 1 )
      NEXT
      UiFrame( nT, nL, nT + nB, nR, UI_C_BOX, .T. )
      /* information block of the menu: dimmed labels + values */
      FOR i := 1 TO nHdr
         nO := iif( Len( aHdr[ i ] ) >= 3, aHdr[ i ][ 3 ], nHdrPad )
         SetColor( UI_C_BOX )
         @ nT + i, nL + 1 SAY Space( nR - nL - 1 )
         SetColor( UI_C_BOXDIM )
         @ nT + i, nL + 1 SAY aHdr[ i ][ 1 ]
         SetColor( UI_C_BOX )
         @ nT + i, nL + 1 + nO SAY aHdr[ i ][ 2 ]
      NEXT
      /* separator line between the header and the options (dark gray,
       * measured on the original: (85,85,85) over the cyan of the box) */
      IF nHdr > 0
         SetColor( UI_C_BOXDIM )
         @ nT + nHdr + 1, nL + 1 SAY Replicate( Chr( 196 ), nR - nL - 1 )
         SetColor( UI_C_DESKTOP )
      ENDIF
      FOR i := 1 TO nItems
         BpMenuRow( aItems, i, nT2, nL, nR, nSel )
      NEXT
      SetColor( UI_C_DESKTOP )
      UiPaintEnd()

      lDone := .F.
      DO WHILE ! lDone
         /* S1/S4 of window-close.md (B3): the X of the window, once per pass
          * of the key wait. The menu cannot finish here: it leaves through the
          * exit shape <Esc> and <F9> already use -lExit plus lDone, so the tail
          * below restores the saved screen and repaints the bar - and the
          * program's exit flag is already raised by BpCloseAsk(), which is what
          * the screen behind this menu (and Main()) watch. No `Exit hwBro?` is
          * asked (L7). The EXIT is what skips the rest of this pass: without it
          * the DO CASE would still act on the key that happened to be next. */
         IF BpCloseAsk()
            lExit := .T.
            lDone := .T.
            EXIT
         ENDIF
         /* U2: the loop waits 50 ms so the MOUSE can be polled. A click is
          * translated into the KEY it stands for, so the DO CASE below is the
          * only place where an option acts (same rule as the manager and the
          * synchronization screen): label of the bar -> that menu, row of the
          * dropdown -> run it, anywhere else -> close. */
         nKey := Inkey( 0.05 )
         /* AGENTS.md trap 37: the modifier state of the key just read is the
          * LIVE one, so it is taken IMMEDIATELY after Inkey() - the accel case
          * of the DO CASE below needs it (S10 of menu-accelerators.md) */
         nShift := iif( nKey != 0, HcShiftState(), 0 )
         /* right-click-esc (S1/S2/S7 of right-click-esc.md): with one of these
          * menus open the right button does nothing at all (the POINTER channel
          * drives the hover and the click channel runs the rows), and Esc closes
          * the menu, so a plain right click closes it the same way. */
         IF nKey == 0 .AND. HcMouseRightClick()
            nKey := K_ESC
         ENDIF
         IF nKey == 0
            aPt := UiClick()
            IF HB_ISARRAY( aPt )
               nRow := aPt[ 1 ]
               BpLog( "  click " + LTrim( Str( nRow ) ) + "," + LTrim( Str( aPt[ 2 ] ) ) )
               nMenuAt := BpMenuBarAt( nRow, aPt[ 2 ] )
               nItemAt := BpMenuItemAt( nRow, aPt[ 2 ], nT2, nL, nR, nItems )
               IF nMenuAt > 0
                  /* another menu: the SAME state the F1..F8 cases set (the key
                   * code is not derived by arithmetic) */
                  RestScreen( nT, nL, nT + nB + 1, Min( nR + 2, MaxCol() ), cSave )
                  nMenu := nMenuAt
                  lRelayout := .T. ; lDone := .T.
               ELSEIF nItemAt > 0
                  IF BpNavOk( aItems, nItemAt )
                     BpMenuRows2( aItems, nSel, nItemAt, nT2, nL, nR )
                     nSel := nItemAt
                     nKey := K_ENTER
                  ENDIF
               ELSEIF nRow >= nT .AND. nRow <= nT + nB .AND. ;
                      aPt[ 2 ] >= nL .AND. aPt[ 2 ] <= nR
                  /* inside the box but not on an option (information block,
                   * separator line): nothing happens, the menu stays open */
                  nKey := 0
               ELSE
                  nKey := K_ESC
               ENDIF
            ENDIF
         ENDIF
         /* S7 of odd/tasks/commander-cleanup.md (user: "en ese menu cuando muevo
          * el puntero del mouse por las diferentes opciones el selector de la
          * opcion no sigue al puntero"): the highlight FOLLOWS the pointer over
          * the options of the dropdown, the same language the dropdowns of the
          * manager speak. A row that cannot act - a separator, a "D" row or a
          * "T" group label - sends it to the nearest row that can, instead of
          * leaving it still; the information block above the options and the
          * rest of the screen change nothing. The CLICK is untouched: it still
          * runs the row under the pointer, in one gesture. */
         IF nKey == 0 .AND. HcMousePointerStep()
            nItemAt := BpMenuItemAt( HcMousePointerRow(), HcMousePointerCol(), ;
                                     nT2, nL, nR, nItems )
            IF nItemAt > 0
               nO := HcCtxHoverSnap( aItems, nItemAt )
               IF nO > 0
                  BpMenuRows2( aItems, nSel, nO, nT2, nL, nR )
                  nSel := nO
               ENDIF
            ENDIF
         ENDIF
         BpLog( "  key=" + LTrim( Str( nKey ) ) )
         DO CASE
         CASE nKey == K_ESC
            lExit := .T. ; lDone := .T.
         CASE nKey == K_LEFT
            RestScreen( nT, nL, nT + nB + 1, Min( nR + 2, MaxCol() ), cSave )
            nMenu := iif( nMenu == 1, 8, nMenu - 1 )
            lRelayout := .T. ; lDone := .T.
         CASE nKey == K_RIGHT
            RestScreen( nT, nL, nT + nB + 1, Min( nR + 2, MaxCol() ), cSave )
            nMenu := iif( nMenu == 8, 1, nMenu + 1 )
            lRelayout := .T. ; lDone := .T.
         CASE nKey == K_UP
            nO := nSel
            nSel--
            DO WHILE nSel >= 1 .AND. ! BpNavOk( aItems, nSel )
               nSel--
            ENDDO
            IF nSel < 1
               nSel := nItems
               DO WHILE nSel >= 1 .AND. ! BpNavOk( aItems, nSel )
                  nSel--
               ENDDO
            ENDIF
            BpMenuRows2( aItems, nO, nSel, nT2, nL, nR )
         CASE nKey == K_DOWN
            nO := nSel
            nSel++
            DO WHILE nSel <= nItems .AND. ! BpNavOk( aItems, nSel )
               nSel++
            ENDDO
            IF nSel > nItems
               nSel := 1
               DO WHILE nSel <= nItems .AND. ! BpNavOk( aItems, nSel )
                  nSel++
               ENDDO
            ENDIF
            BpMenuRows2( aItems, nO, nSel, nT2, nL, nR )
         CASE nKey == K_ENTER .OR. nKey == K_SPACE
            lDo := .T.
         CASE ! Empty( BpAccelFind( nKey, nShift ) )
            /* S10 of menu-accelerators.md: with a dropdown open an accelerator
             * still runs its GLOBAL action, and it is tried BEFORE the ~x~ quick
             * letter below - so <Alt-S> is `Seek` while a plain `s` is the quick
             * letter of a row. The shape is the one <Ctrl-F3> already had: the
             * saved screen goes back and the bar loses the focus before the row
             * acts. A row that is not available right now ("D") runs nothing and
             * the menu is simply closed, because the key belonged to the map. */
            RestScreen( nT, nL, nT + nB + 1, Min( nR + 2, MaxCol() ), cSave )
            BpMenuBar( 0 )
            IF ! BpAccelRun( nKey, nShift )
               BpLog( "  accel not available with the menu open" )
            ENDIF
            RETURN NIL
         CASE nKey >= 32 .AND. nKey <= 255
            /* hot key (~x~) of the options, as in the original */
            nHot := BpFindHot( aItems, nItems, Upper( Chr( nKey ) ) )
            IF nHot > 0
               BpMenuRows2( aItems, nSel, nHot, nT2, nL, nR )
               nSel := nHot
               lDo := .T.
            ENDIF
         CASE nKey == K_F1 ; nMenu := 1 ; lRelayout := .T. ; lDone := .T.
         CASE nKey == K_F2 ; nMenu := 2 ; lRelayout := .T. ; lDone := .T.
         CASE nKey == K_F3 ; nMenu := 3 ; lRelayout := .T. ; lDone := .T.
         CASE nKey == K_F4 ; nMenu := 4 ; lRelayout := .T. ; lDone := .T.
         CASE nKey == K_F5 ; nMenu := 5 ; lRelayout := .T. ; lDone := .T.
         CASE nKey == K_F6 ; nMenu := 6 ; lRelayout := .T. ; lDone := .T.
         CASE nKey == K_F7 ; nMenu := 7 ; lRelayout := .T. ; lDone := .T.
         CASE nKey == K_F8 ; nMenu := 8 ; lRelayout := .T. ; lDone := .T.
         /* <F9> only CLOSES the menu: it does not exit the program (the next
          * keypress opens the dot prompt) */
         CASE nKey == K_F9 ; lExit := .T. ; lDone := .T.
         /* <Ctrl-F3> used to have its own case here (open Tag Selection /
          * Information from any menu). The global map of BpAccelRun() now owns
          * it -the row `~T~ag Selection/Information` of F3, whose action is this
          * very BpIdxTagInfo()-, so the case would be a second place dispatching
          * the same accelerator (S9 of menu-accelerators.md); the accel case
          * above does the same RestScreen() + BpMenuBar( 0 ) before acting. */
         ENDCASE
         IF lDo
            lDo := .F.
            /* "D" = not available: it does nothing.  "T" = group label.
             * "R" = keeps the menu OPEN and rebuilds it (the value of the item
             *        is repainted with the new value, like the original).
             * "I" = dimmed but informative. */
            cType := iif( Len( aItems[ nSel ] ) >= 4, Upper( aItems[ nSel ][ 4 ] ), "" )
            IF cType == "D" .OR. cType == "T"
               BpLog( "  opcion no disponible" )
            ELSEIF cType == "R"
               bAction := aItems[ nSel ][ 3 ]
               IF ! Empty( bAction )
                  Eval( bAction )
               ENDIF
               lRelayout := .T. ; lDone := .T.
            ELSE
               bAction := aItems[ nSel ][ 3 ]
               RestScreen( nT, nL, nT + nB + 1, Min( nR + 2, MaxCol() ), cSave )
               BpMenuBar( 0 )
               IF ! Empty( bAction )
                  Eval( bAction )
               ENDIF
               RETURN NIL
            ENDIF
         ENDIF
      ENDDO
      IF lRelayout
         RestScreen( nT, nL, nT + nB + 1, Min( nR + 2, MaxCol() ), cSave )
      ENDIF
   ENDDO

   RestScreen( nT, nL, nT + nB + 1, Min( nR + 2, MaxCol() ), cSave )
   BpMenuBar( 0 )
RETURN NIL



