/*
 * bp_cmds.prg - Actions of every menu (F1..F8)
 * Clone of BroPlus 3.00 - Harbour + MSVC x64
 */
#include "inkey.ch"
#include "dbinfo.ch"
#include "fileio.ch"
#include "hbgtinfo.ch"
#include "bp_def.ch"

/* last field/scope/conditions of the Replace form (session memory, L of
 * odd/tasks/replace-form.md: nothing goes to disk) */
STATIC s_aRpLast := {}

/* session memory of the Append From form (odd/tasks/append-from-form.md S16):
 * path, file, scope, count, while, for - plus the selection of the last source,
 * which only comes back for THE SAME file (S8) */
STATIC s_aApLast    := {}
STATIC s_aApSel     := {}
STATIC s_cApSelFile := ""
/* the last directory the picker of that form visited (S21 of
 * odd/tasks/append-from-form.md): session memory, nothing goes to disk */
STATIC s_cApPkDir   := ""

/* cut column (Shift-F5) to paste it with Ctrl-F5 */
STATIC s_nCutCol := 0

/* "View Directory List" option of the Change Directory form (F2) */
STATIC s_lViewDirList := .F.

/* folder walk of "Change Directory": bounded so exploring a big Windows
 * drive does not hang the application (the original, on the C: of
 * DOSBox-X, found 151 folders) */
#define BP_DIR_MAX     600
#define BP_DIR_DEPTH     8
/* time budget of the walk, in seconds: a real Windows drive does not look
 * like the C: of DOSBox-X (here there are >100,000 folders), so the walk
 * is cut by time and by count instead of leaving the application
 * blocked */
#define BP_DIR_SECS      3

/* moment the folder walk started (see BP_DIR_SECS) */
STATIC s_nScanT0 := 0

/* last choices of the F8 LIST form (session memory, S11 of
 * odd/tasks/list-to-print.md: nothing goes to disk) */
STATIC s_aLpLast := {}

/* last choices of the F8 SUM/AVERAGE form (session memory, sum-average-form.md
 * S7: nothing goes to disk, like the LIST form) */
STATIC s_aSmLast := {}

/* counter of the temporary files of the LIST printer job, so two jobs in the
 * same second cannot share a name */
STATIC s_nLpSeq := 0

/* =====================================================================
 *  F1 - Help
 * ===================================================================== */

FUNCTION BpHelp()
   UiTextWin( { ;
      BP_APPNAME + " " + BP_VERSION + "  (Harbour/Win32 reconstruction of BroPlus 3.00)", ;
      "", ;
      "Menu bar:", ;
      "  F1 Help               help and hot-keys", ;
      "  F2 Database           open / select / close DBF databases", ;
      "  F3 Index              orders and index files (CDX/NSX/NTX)", ;
      "  F4 Fields             fields and file structure", ;
      "  F5 AreaSet            filters, relations, areas and windows", ;
      "  F6 GlobalSet          global program settings", ;
      "  F7 Record             record navigation and editing", ;
      "  F8 Command            xBase commands (COPY, APPEND, PACK, ...)", ;
      "  F9 Dot                dot prompt (xBase commands)", ;
      "", ;
      "  Alt-X                 exit hwBro", ;
      "", ;
      "In the record window:", ;
      "  Arrows                move through records / columns", ;
      "  PgUp/PgDn             previous / next page", ;
      "  Home/End              first / last record", ;
      "  Enter                 edit current cell", ;
      "  Ins                   append record (APPEND BLANK)", ;
      "  Del                   delete/recall record", ;
      "  Tab / Shift-Tab       next / previous column", ;
      "  Ctrl-F                find in the current field", ;
      "  Ctrl-Shift-F          find in all fields", ;
      "", ;
      "Data engine: DBFCDX (compatible with SIx Driver .CDX indexes).", ;
      "DBFNTX (.NTX) is also supported." }, "Help - hwBro" )
RETURN NIL

FUNCTION BpHotKeys()
   UiTextWin( { ;
      "Hot-Keys", ;
      "", ;
      "  F1..F8                main menus", ;
      "  F9                    dot prompt (xBase commands)", ;
      "  Alt-X                 exit hwBro", ;
      "  Alt-F2                database selection screen", ;
      "  Alt-F3                index file selection screen", ;
      "  Alt-F4                field selection screen", ;
      "  Alt-N                 next database", ;
      "  Alt-Minus             previous database", ;
      "  Alt-Y                 change directory", ;
      "  Alt-Z                 Shell to DOS / run program", ;
      "  Alt-O                 next index order", ;
      "  Alt-U                 next select area", ;
      "  Alt-A / Alt-E         all / selected fields", ;
      "  Alt-S / Alt-G         Seek / Goto", ;
      "  Alt-U / Alt-J         Locate / Skip", ;
      "  Alt-T / Alt-B         first / last record", ;
      "  Alt-D                 hide deleted records", ;
      "  Alt-Q                 SoftSeek on/off", ;
      "  Alt-V / Alt-W         restore / save view", ;
      "  Alt-BSpc              erase record memo" }, "Hot-Keys" )
RETURN NIL

/* =====================================================================
 *  Internal helpers
 * ===================================================================== */

STATIC FUNCTION BpNeedDb()
   IF ! Used()
      UiMsg( "No database is open." + hb_eol() + "Use F2 - Database / Database Selection Screen.", "hwBro" )
      RETURN .F.
   ENDIF
RETURN .T.

/* S1/S4 of window-close.md (B4): wait for ONE key with the X of the window
 * reachable. The screens of this file waited with Inkey( 0 ), which BLOCKS, so
 * the request that the window hook of bp_win32.c leaves latched in WM_CLOSE
 * could never be seen from here. The wait is the same 50 ms slice the rest of
 * the program already polls with, and BpCloseAsk() is asked once per slice: it
 * PEEKS the latch -the request has to survive the several screens that may see
 * it, L9- and raises the program's exit flag, so Main() ends the program after
 * the screen returns. It never asks `Exit hwBro?` (L7). A timeout answers 0,
 * which no real key produces, so the caller leaves through its OWN normal exit
 * for that value; an idle slice never reaches the key handling of any caller,
 * so it does exactly what it did before: keep waiting. */
STATIC FUNCTION BpWaitKey()
   LOCAL nKey
   DO WHILE .T.
      nKey := Inkey( 0.05 )
      IF nKey != 0
         RETURN nKey
      ENDIF
      /* right-click-esc (S1/S7 of right-click-esc.md): a plain right click is
       * handed to the caller AS the Esc key, so every screen of this module
       * that leaves, cancels or abandons with Esc does the same with a right
       * click, through the ONE Esc branch it already has. The rule itself lives
       * in bp_hc.prg; this wait is the single place where those screens ask
       * for a key, which is why none of them needs a line of its own. */
      IF HcMouseRightClick()
         RETURN K_ESC
      ENDIF
      IF BpCloseAsk()
         RETURN 0
      ENDIF
   ENDDO
RETURN 0

/* The same wait as BpWaitKey() but with a BUDGET: it answers 0 when the slice
 * runs out, so the caller can poll the mouse between keys (the Field Selection
 * Screen, S10 of odd/tasks/commander-cleanup.md). The close request is handed
 * over by REFERENCE instead of as 0, because 0 is now "no key yet" and a real
 * key code can be negative in this build (K_F2 = -1). */
STATIC FUNCTION BpWaitKeyMs( nSecs, lClosed )
   LOCAL nKey := Inkey( iif( ValType( nSecs ) == "N", nSecs, 0.05 ) )
   lClosed := .F.
   IF nKey == 0 .AND. BpCloseAsk()
      lClosed := .T.
   ENDIF
   /* right-click-esc (S1/S7): the same rule as BpWaitKey(), and only on a slice
    * that carried no key, so a real key always wins */
   IF nKey == 0 .AND. HcMouseRightClick()
      nKey := K_ESC
   ENDIF
RETURN nKey

STATIC FUNCTION BpDir()
RETURN iif( Empty( CoreDir() ), ".", CoreDir() )

/* File names (strings) matching the mask in the working directory.
 * hb_DirScan() returns arrays {name,size,date,time,attr}, they are normalized here. */
FUNCTION BpDirNames( cMask )
   LOCAL a := hb_DirScan( BpDir(), cMask ), aNames := {}
   AEval( a, {| x | AAdd( aNames, iif( ValType( x ) == "A", x[ 1 ], x ) ) } )
RETURN aNames

/* =====================================================================
 *  F2 - Database
 * ===================================================================== */

/* =====================================================================
 *  F2 - Database : Database Selection Screen (traced from the original)
 *    left panel  = *.DBF files of the current directory
 *    right panel = selected / open databases
 *    <Enter>=Pick  <Esc>=Browse  <Del>=Remove  <Ins>=Add
 * ===================================================================== */

/* Geometry of the TWO panels, derived from the canvas instead of the
 * measurements of the 80x25 original (rules S7/S8): a 2 column left margin, a
 * 4 column gap between the panels, a 2 column right margin, and the two panels
 * splitting the rest EQUALLY.
 *
 * On the 120x44 canvas that gives 56 column panels at 2..57 and 62..117, so
 * the 2 column shadow of BpSelBox lands on 118..119 and never leaves the
 * canvas. The rows run from SEL_T to SEL_B (= MaxRow()-3, i.e. 5..40), with the
 * shadow on SEL_B+1 (41), "Key:"/"Driver:" on MaxRow()-1 (42) and the hints on
 * MaxRow() (43).
 *
 * SEL_MINW keeps a tiny canvas from producing negative coordinates; these are
 * #defines (they are re-evaluated at each use) so they are NEVER mutated. */
#define SEL_T       5              /* top row of both boxes                 */
#define SEL_MARG    2              /* left/right margin of the screen       */
#define SEL_GAP     4              /* blank columns between the two panels   */
#define SEL_MINW    20             /* minimum panel width (small canvases)   */
#define SEL_W       ( Max( SEL_MINW, Int( ( UiCols() - 2 * SEL_MARG - SEL_GAP ) / 2 ) ) )
#define SEL_B       ( MaxRow() - 3 )   /* bottom row of both boxes           */
#define SEL_LL      SEL_MARG           /* left column of the left panel      */
#define SEL_LR      ( SEL_LL + SEL_W - 1 )   /* right column of the left panel */
#define SEL_RL      ( SEL_LR + 1 + SEL_GAP ) /* left column of the right panel */
#define SEL_RR      ( SEL_RL + SEL_W - 1 )   /* right column of the right panel */
#define SEL_ROWS    ( SEL_B - SEL_T - 1 )    /* visible list rows inside a box */
#define SEL_HGAP    2              /* blank columns between two help hints   */

STATIC PROCEDURE BpSelBox( nT, nL, nB, nR, cFrame )
   LOCAL i
   SetColor( UI_C_SHADOWBLK )
   FOR i := nT + 1 TO nB + 1
      @ i, nR + 1 SAY Replicate( Chr( 219 ), 2 )
   NEXT
   @ nB + 1, nL + 2 SAY Replicate( Chr( 219 ), nR - nL )
   SetColor( UI_C_DARK )
   FOR i := nT TO nB
      @ i, nL SAY Space( nR - nL + 1 )
   NEXT
   UiFrame( nT, nL, nB, nR, cFrame, .T. )
   SetColor( UI_C_DESKTOP )
RETURN NIL

/* row 23: current order and driver. The original draws it in gray, with the
 * order in a cyan chip on the left and the driver in another cyan chip on the
 * right; with no open database the row stays empty. */
STATIC PROCEDURE BpSelStatus()
   LOCAL nRow := MaxRow() - 1, cR, cL := ""
   SetColor( UI_C_DESKTOP )
   @ nRow, 0 SAY Space( MaxCol() + 1 )
   IF ! Used()
      RETURN
   ENDIF
   cL := iif( Empty( OrdName() ), "Natural Order", "Key: (" + CoreKeyExpr() + ")" )
   cR := " Driver: " + CoreDriver() + " "
   SetColor( UI_C_CHIP )
   /* the order chip starts on the same column as the help hints: it follows
    * the left panel origin instead of the fixed column 1 */
   @ nRow, Max( 0, SEL_LL - 1 ) SAY cL
   @ nRow, Max( 0, MaxCol() + 1 - Len( cR ) ) SAY cR
   SetColor( UI_C_DESKTOP )
RETURN NIL

/* "<Key>" with the key in a cyan chip and the rest in white on dark gray,
 * like the shortcuts of the original. Returns the first free column AFTER the
 * written text, so a caller can CHAIN the hints (start where the previous one
 * ended) instead of hard coding their columns. cKeyColor is the color of the
 * key text inside the chip (the "Fn" pseudo key is painted yellow). */
STATIC FUNCTION BpHotKey( nRow, nCol, cKey, cAct, cKeyColor )
   DEFAULT cKeyColor TO UI_C_CHIP
   SetColor( UI_C_MENUKEY )
   @ nRow, nCol SAY "<"
   SetColor( cKeyColor )
   @ nRow, nCol + 1 SAY cKey
   SetColor( UI_C_MENUKEY )
   @ nRow, nCol + 1 + Len( cKey ) SAY ">" + cAct
RETURN nCol + Len( cKey ) + Len( cAct ) + 2

/* bottom help bar (white on dark gray, with the keys in cyan chips), traced
 * from the original. The TEXT is the one of the original; the COLUMNS are not
 * absolute anymore (they were 1/14/27/40/50/52/53/55/64 on the 80x25 grid):
 * the bar starts at the left panel origin (SEL_LL - 1) and every hint begins
 * where the previous one ended plus SEL_HGAP, so it tracks the layout. */
STATIC PROCEDURE BpSelHelp()
   LOCAL nRow := MaxRow(), nCol := Max( 0, SEL_LL - 1 )
   SetColor( UI_C_MENUBAR )
   @ nRow, 0 SAY Space( MaxCol() + 1 )
   nCol := BpHotKey( nRow, nCol, "Enter", "=Pick" ) + SEL_HGAP
   nCol := BpHotKey( nRow, nCol, "Esc",   "=Browse" ) + SEL_HGAP
   nCol := BpHotKey( nRow, nCol, "Del",   "=Remove" ) + SEL_HGAP
   nCol := BpHotKey( nRow, nCol, "Ins",   "=Add" ) + SEL_HGAP
   UiWrite( nRow, nCol, "|", UI_C_MENUKEY )
   nCol := BpHotKey( nRow, nCol + SEL_HGAP, "Fn", "Menu", UI_C_HOTON ) + SEL_HGAP
   BpHotKey( nRow, nCol, "Alt-H", "=HotKeys" )
   SetColor( UI_C_DESKTOP )
RETURN NIL

FUNCTION BpDbNext()
   LOCAL a := CoreAreas(), i, n := Select()
   IF Len( a ) < 2 ; RETURN NIL ; ENDIF
   FOR i := 1 TO Len( a )
      IF a[ i ][ 1 ] == n
         SELECT ( a[ iif( i == Len( a ), 1, i + 1 ) ][ 1 ] )
         EXIT
      ENDIF
   NEXT
   CoreStatus()
RETURN NIL

FUNCTION BpDbPrev()
   LOCAL a := CoreAreas(), i, n := Select()
   IF Len( a ) < 2 ; RETURN NIL ; ENDIF
   FOR i := 1 TO Len( a )
      IF a[ i ][ 1 ] == n
         SELECT ( a[ iif( i == 1, Len( a ), i - 1 ) ][ 1 ] )
         EXIT
      ENDIF
   NEXT
   CoreStatus()
RETURN NIL

FUNCTION BpDbClose()
   LOCAL oErr, cAlias, a
   IF ! BpNeedDb() ; RETURN NIL ; ENDIF
   cAlias := Alias()
   /* the original CLOSES WITHOUT ASKING (measured on BRO.EXE) */
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      CLOSE                       /* closes ONLY current area   */
      /* if databases are left open, we go on with the first of them: if none
       * is activated, Used() stays .F. and the application falls to the
       * desktop even though the user has another database open */
      a := CoreAreas()
      IF ! Empty( a )
         SELECT ( a[ 1 ][ 1 ] )
      ENDIF
      CoreStatus()
   RECOVER USING oErr
      UiErr( "Error closing " + Upper( cAlias ) + ":" + hb_eol() + oErr:Description )
   END SEQUENCE
RETURN NIL

/* Reopens the active database keeping position and order (same pattern as
 * BpDbAlias(): CLOSE + CoreOpen() + CoreOrdList() + dbGoto()). The area must
 * already be closed on entry. It leaves the pointer on the SAME record. */
STATIC FUNCTION BpDbReopen( cFile, cAlias, cBase, nRec, cOrd )
   LOCAL lOk := .F.
   IF CoreOpen( cFile, cAlias, .T. )   /* .T. = do not ask: the decider is
                                        * the retry chain of the toggle */
      CoreOrdList( cBase )
      /* ORDLISTADD leaves the bag open, but does not guarantee that the
       * control ORDER is the same as before: set it by name so the record
       * pointer (nPos) and the current record still line up. */
      IF ! Empty( cOrd )
         BEGIN SEQUENCE WITH {| e | Break( e ) }
            OrdSetFocus( cOrd )
         RECOVER
         END SEQUENCE
      ENDIF
      IF nRec > 0
         dbGoto( nRec )
      ENDIF
      lOk := .T.
   ENDIF
RETURN lOk

/* Open Mode: the original TOGGLES without a dialog (Alt-X) and the F2 menu item
 * is repainted with the new value (measured on BRO.EXE). It also AFFECTS THE
 * DATABASE ALREADY OPEN: measured with CLIENTES.DBF open and "Rec. 67/400",
 * Alt-X leaves the browser bar in <Exclusive> and the SAME record is still
 * the current one, that is, the file is closed and reopened on the fly and it
 * is not just the setting for the next open. */
FUNCTION BpDbToggleMode()
   LOCAL cFile, cAlias, cBase, nRec, cOrd, lOk
   IF ! Used()
      CoreToggleMode()
      CoreStatus()
      RETURN NIL
   ENDIF
   cFile  := CoreFileName()      /* real file path: DBF() gives the ALIAS    */
   cAlias := Alias()
   cBase  := CoreFileBase()      /* the .CDX bag has the file name         */
   nRec   := RecNo()
   cOrd   := Upper( OrdName() )
   CoreToggleMode()
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      CLOSE
      lOk := BpDbReopen( cFile, cAlias, cBase, nRec, cOrd )
   RECOVER
      lOk := .F.
   END SEQUENCE
   IF ! lOk
      /* it could not be opened in the new mode (e.g. the file is locked by
       * another process): go back to the previous mode and reopen in it, so
       * the area is not left closed with the database open (CoreOpen told) */
      CoreToggleMode()
      BEGIN SEQUENCE WITH {| e | Break( e ) }
         lOk := BpDbReopen( cFile, cAlias, cBase, nRec, cOrd )
      RECOVER
         lOk := .F.
      END SEQUENCE
      IF ! lOk
         /* last resort: open again in SHARED, which is the mode needing the
          * fewest restrictions, rather than leaving the area empty */
         IF CoreOpenMode() != "SHARED"
            CoreToggleMode()
         ENDIF
         BpDbReopen( cFile, cAlias, cBase, nRec, cOrd )
      ENDIF
   ENDIF
   CoreStatus()
RETURN NIL

/* ---- dialog geometry (native 120x44 canvas) -------------------------
 * Box of 7 rows x 38 columns (rows 13..19 / columns 22..59 measured on the
 * 80x25 original), centred on the canvas: the rows and columns of the content
 * stay the measured ones, written as offsets from the corner of the box. */
#define ALIAS_H          7
#define ALIAS_W         38
#define ALIAS_R( __r )  ( nT + ( __r ) - 13 )
#define ALIAS_C( __c )  ( nL + ( __c ) - 22 )

FUNCTION BpDbAlias()
   LOCAL c, oErr, lOk := .F., cOld, cFile, cBase, nRec, cSave
   LOCAL nT := UiFitRow( UiCenterRow( ALIAS_H ), ALIAS_H + 1 )
   LOCAL nL := UiFitCol( UiCenterCol( ALIAS_W ), ALIAS_W + 2 )
   LOCAL nB := nT + ALIAS_H - 1, nR := nL + ALIAS_W - 1
   IF ! BpNeedDb() ; RETURN NIL ; ENDIF
   cOld  := Alias()
   cFile := CoreFileName()       /* real file path: DBF() gives the ALIAS    */
   cBase := CoreFileBase()      /* the .CDX bag has the file name         */
   cSave := SaveScreen( nT - 1, nL - 1, Min( MaxRow(), nB + 2 ), ;
                        Min( MaxCol(), nR + 2 ) )
   UiPaintBegin()
   UiFormBox( nT, nL, nB, nR )
   UiWrite( ALIAS_R( 15 ), ALIAS_C( 25 ), "Current Alias Name: " + Upper( cOld ), UI_C_DLGINFO )
   UiWrite( ALIAS_R( 17 ), ALIAS_C( 29 ), "New Alias Name:", UI_C_DLG )
   UiPaintEnd()
   c := UiFormEdit( ALIAS_R( 17 ), ALIAS_C( 44 ), 11, cOld, .F. )
   RestScreen( nT - 1, nL - 1, Min( MaxRow(), nB + 2 ), ;
               Min( MaxCol(), nR + 2 ), cSave )
   IF c == NIL .OR. Empty( c ) .OR. Upper( c ) == Upper( cOld )
      RETURN NIL
   ENDIF
   nRec := RecNo()
   /* Harbour does NOT allow renaming the alias "on the fly": Alias( c ) is
    * read only (it takes the argument but does not rename) and dbInfo( DBI_ALIAS, c )
    * does not change it in DBFCDX either. The only way is to close the area and
    * reopen the file with the new alias, recovering position and order. */
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      CLOSE
      IF CoreOpen( cFile, c )
         CoreOrdList( cBase )
         IF nRec > 0
            dbGoto( nRec )
         ENDIF
         lOk := .T.
      ENDIF
   RECOVER USING oErr
      UiErr( "Could not rename the alias:" + hb_eol() + oErr:Description )
   END SEQUENCE
   IF lOk
      CoreStatus()
   ENDIF
RETURN NIL

/* ---- dialog geometry (native 120x44 canvas) -------------------------
 * Box of 10 rows x 67 columns (rows 10..19 / columns 7..73 measured on the
 * 80x25 original), centred on the canvas. The three label lines keep their
 * measured rows (12, 14, 16) and columns, written as offsets from the box:
 * Y/N field in column 35, "Drive:" in 38, drive letter in 45 and the directory
 * field from 31 to 71 with a red background. */
#define BCD_H           10
#define BCD_W           67
#define BCD_R( __r )    ( nT + ( __r ) - 10 )
#define BCD_C( __c )    ( nL + ( __c ) - 7 )

FUNCTION BpDbChangeDir()
   LOCAL cDir := CoreDir(), cEdit := RTrim( CoreDir() ), cList, cDrv
   LOCAL cSave, cDrv0 := Left( cDir, 1 ), cDrvPrev, lOut := .F., lListed := .F.
   LOCAL nT := UiFitRow( UiCenterRow( BCD_H ), BCD_H + 1 )
   LOCAL nL := UiFitCol( UiCenterCol( BCD_W ), BCD_W + 2 )
   LOCAL nB := nT + BCD_H - 1, nR := nL + BCD_W - 1
   /* the saved rectangle follows the box (plus its shadow) and is clamped to the
    * canvas, so a box that grows can neither leave garbage nor wipe a neighbour */
   LOCAL nS := nT - 1, nSL := nL - 1
   LOCAL nSE := Min( MaxRow(), nB + 2 ), nSR := Min( MaxCol(), nR + 2 )
   /* the form repeats until it is accepted: with "View Directory List" =
    * Y the original COMES BACK to the form with the chosen path (it still has
    * to be confirmed) and an invalid directory leaves the form open with what
    * was typed, after the "Invalid Path" box (measured on BRO.EXE). */
   DO WHILE ! lOut
      UiPaintBegin()
      UiFormBox( nT, nL, nB, nR )
      UiWrite( BCD_R( 12 ), BCD_C(  9 ), "Current Directory:", UI_C_DLGINFO )
      UiWrite( BCD_R( 12 ), BCD_C( 29 ), CoreDir(), UI_C_DLGINFO )
      UiWrite( BCD_R( 14 ), BCD_C(  9 ), "View Directory List (Y/N)", UI_C_DLG )
      UiWrite( BCD_R( 14 ), BCD_C( 38 ), "Drive:", UI_C_DLG )
      UiWrite( BCD_R( 16 ), BCD_C(  9 ), "Change to Directory:", UI_C_DLG )
      UiPaintEnd()
      cSave := SaveScreen( nS, nSL, nSE, nSR )
      cList := UiFormEdit( BCD_R( 14 ), BCD_C( 35 ), 1, iif( s_lViewDirList, "Y", "N" ), .F. )
      IF cList == NIL
         RestScreen( nS, nSL, nSE, nSR, cSave )
         RETURN NIL
      ENDIF
      IF ! Empty( cList )
         s_lViewDirList := ( Upper( Left( cList, 1 ) ) == "Y" )
      ENDIF
      cDrvPrev := cDrv0
      cDrv := UiFormEdit( BCD_R( 14 ), BCD_C( 45 ), 1, cDrv0, .F. )
      IF cDrv == NIL
         RestScreen( nS, nSL, nSE, nSR, cSave )
         RETURN NIL
      ENDIF
      IF ! Empty( cDrv )
         cDrv0 := Upper( Left( cDrv, 1 ) )
      ENDIF
      /* the directory field is the one being edited: the focus pair */
      cEdit := UiFormEdit( BCD_R( 16 ), BCD_C( 31 ), 41, cEdit, .F. )
      IF cEdit == NIL
         RestScreen( nS, nSL, nSE, nSR, cSave )
         RETURN NIL
      ENDIF
      /* only if the user CHANGED the drive it starts at the root of that
       * drive (the usual behaviour); otherwise the path is kept as it is */
      IF ! Empty( cDrv0 ) .AND. cDrv0 != cDrvPrev
         cEdit := cDrv0 + ":\"
      ENDIF
      IF s_lViewDirList .AND. ! lListed
         /* <Y>: list of ALL folders of the drive, with the full path.
          * On choosing one it returns to the form with the path set; the
          * directory is NOT changed yet and Enter to confirm does NOT list
          * again (measured on the original). */
         lListed := .T.
         cList := BpDirPick( iif( Empty( cDrv0 ), CoreDir(), cDrv0 ) )
         IF cList != NIL
            cEdit := cList
            RestScreen( nS, nSL, nSE, nSR, cSave )
            LOOP
         ENDIF
      ENDIF
      RestScreen( nS, nSL, nSE, nSR, cSave )
      IF Empty( cEdit )
         RETURN NIL
      ENDIF
      IF BpDirExists( cEdit )
         CoreSetDir( cEdit )
         CoreStatus()
         RETURN NIL
      ENDIF
      /* text of the original for a directory that does not exist (measured):
       * the box is titled "Invalid Path" and then the form stays open */
      UiErr( "Invalid Path" )
   ENDDO
RETURN NIL

/* does the directory exist? hb_DirExists() does not take the trailing slash */
STATIC FUNCTION BpDirExists( cPath )
   LOCAL c := RTrim( cPath )
   IF Len( c ) > 3 .AND. Right( c, 1 ) == "\"
      c := Left( c, Len( c ) - 1 )
   ENDIF
RETURN ( ! Empty( c ) .AND. hb_DirExists( c ) )

/* ---- geometry of the scanning box (native 120x44 canvas) -------------
 * 15 rows x 67 columns, the box of the old 80x25 grid, centred: the whole box
 * is only used while the folders are being scanned; the list itself is the
 * UiPick() box, which opens on the same top-left corner. */
#define DIRP_H          15
#define DIRP_W          67

/* List of ALL folders of the drive with the FULL path and sorted, like the
 * original (measured): first "Scanning Directories on Drive C:  n" with
 * <Esc>=Cancel and then the "Drive C:" list. Returns the chosen path or NIL. */
STATIC FUNCTION BpDirPick( cDrv )
   LOCAL a := {}, cRoot, cSave, nPick, cPrefix
   LOCAL nT := UiFitRow( UiCenterRow( DIRP_H ), DIRP_H + 1 )
   LOCAL nL := UiFitCol( UiCenterCol( DIRP_W ), DIRP_W + 2 )
   LOCAL nB := nT + DIRP_H - 1, nR := nL + DIRP_W - 1
   LOCAL nS := nT, nSE := Min( MaxRow(), nB + 1 ), nSR := Min( MaxCol(), nR + 2 )
   cRoot := Upper( Left( AllTrim( cDrv ), 1 ) )
   IF Empty( cRoot ) .OR. ! IsAlpha( cRoot )
      cRoot := Upper( Left( CoreDir(), 1 ) )
   ENDIF
   cRoot  += ":\"
   cPrefix := "Scanning Directories on Drive " + cRoot + " "
   AAdd( a, cRoot )
   cSave := SaveScreen( nT, nL, nSE, nSR )
   UiPaintBegin()
   UiShadow( nT, nL, nB, nR )
   UiFillBox( nT, nL, nB, nR, UI_C_BOX )
   UiFrame( nT, nL, nB, nR, UI_C_BOX, .T. )
   SetColor( UI_C_BOX )
   @ nT + 1, nL + 2 SAY cPrefix
   @ nB - 1, nL + 2 SAY "<Esc>=Cancel"
   SetColor( UI_C_DESKTOP )
   UiPaintEnd()
   /* the counter is repainted outside the paint block (otherwise it would
    * not be seen advancing) and only every so many folders, not to slow down */
   s_nScanT0 := Seconds()
   BpLog( "BpDirPick: scan " + cRoot )
   BpScanDirs( cRoot, 1, a, nT + 1, nL + 2 + Len( cPrefix ) )
   BpLog( "BpDirPick: dirs=" + LTrim( Str( Len( a ) ) ) + ;
          " seg=" + hb_ValToStr( Seconds() - s_nScanT0 ) )
   SetColor( UI_C_BOX )
   @ nT + 1, nL + 2 + Len( cPrefix ) SAY PadL( LTrim( Str( Len( a ) ) ), 6 )
   SetColor( UI_C_DESKTOP )
   RestScreen( nT, nL, nSE, nSR, cSave )
   /* full paths, sorted (like the original) */
   ASort( a, , , {| x, y | Upper( x ) < Upper( y ) } )
   nPick := UiPick( a, "Drive " + Left( cRoot, 2 ), 1, nT, nL, nB - nT - 2 )
   IF nPick == 0
      RETURN NIL
   ENDIF
RETURN a[ nPick ]

/* Scans the folders of cDir recursively and collects them in aOut with the full
 * path. The walk is BOUNDED (depth and total) so that exploring a big Windows
 * drive does not leave the application hung. */
STATIC FUNCTION BpScanDirs( cDir, nDepth, aOut, nRow, nCol )
   LOCAL aRaw, i, cSub, c, lStop := .F.
   IF nDepth > BP_DIR_DEPTH .OR. Len( aOut ) >= BP_DIR_MAX .OR. ;
      ( s_nScanT0 > 0 .AND. Seconds() - s_nScanT0 > BP_DIR_SECS )
      RETURN Len( aOut )
   ENDIF
   /* NOTE (measured): in this Harbour "D" must be asked in Directory() for it
    * to include folders (without the attribute it only returns files) and ALSO
    * filter the attribute in letters, because with "D" it returns the files too.
    * (hb_DirScan( dir, "*", "D" ) is useless here: it returned 713,131 entries
    * from a directory that has 59.) */
   aRaw := Directory( cDir + "*.*", "D" )
   FOR i := 1 TO Len( aRaw )
      IF ValType( aRaw[ i ] ) != "A" .OR. Len( aRaw[ i ] ) < 5
         LOOP
      ENDIF
      IF ValType( aRaw[ i ][ 5 ] ) != "C" .OR. At( "D", aRaw[ i ][ 5 ] ) == 0
         LOOP
      ENDIF
      c := AllTrim( aRaw[ i ][ 1 ] )
      IF Empty( c ) .OR. c == "." .OR. c == ".."
         LOOP
      ENDIF
      cSub := cDir + c + "\"
      AAdd( aOut, cSub )
      IF nRow > 0 .AND. ( Len( aOut ) % 8 == 0 )
         SetColor( UI_C_BOX )
         @ nRow, nCol SAY PadL( LTrim( Str( Len( aOut ) ) ), 6 )
         SetColor( UI_C_DESKTOP )
      ENDIF
      IF Len( aOut ) >= BP_DIR_MAX .OR. ;
         ( s_nScanT0 > 0 .AND. Seconds() - s_nScanT0 > BP_DIR_SECS )
         lStop := .T.
         EXIT
      ENDIF
      BpScanDirs( cSub, nDepth + 1, aOut, nRow, nCol )
      IF Len( aOut ) >= BP_DIR_MAX .OR. ;
         ( s_nScanT0 > 0 .AND. Seconds() - s_nScanT0 > BP_DIR_SECS )
         lStop := .T.
         EXIT
      ENDIF
   NEXT
   IF lStop .AND. nRow > 0
      SetColor( UI_C_BOX )
      @ nRow, nCol SAY PadL( LTrim( Str( Len( aOut ) ) ), 6 )
      SetColor( UI_C_DESKTOP )
   ENDIF
RETURN Len( aOut )

FUNCTION BpDbShell()
   LOCAL c := UiInput( "DOS command (empty = just return):", "", 50 )
   LOCAL oErr
   IF c == NIL ; RETURN NIL ; ENDIF
   IF ! Empty( c )
      BEGIN SEQUENCE WITH {| e | Break( e ) }
         hb_run( c )
      RECOVER USING oErr
         UiErr( "Could not execute: " + c + hb_eol() + oErr:Description )
      END SEQUENCE
   ENDIF
RETURN NIL

/* =====================================================================
 *  Structure editor (F2 "Create/Modify Structure")
 *  ---------------------------------------------------------------------
 *  Replica of the original (capture _reversing/capturas/34), on the native
 *  120x44 canvas. The BAND STRUCTURE is the one measured on the original:
 *    - outer frame (bright cyan), title row right below its top border
 *    - field table with its own frame: header row, "=" separator row, the
 *      field rows, and its bottom border
 *    - the three hint rows are the last three interior rows of the frame
 *    - the status bar (Directory + mode chip) on the last row of the canvas
 *  What the canvas adds above all is HEIGHT, absorbed by the TABLE rows: on the
 *  horizontal axis the box is sized to its CONTENT and CENTRED, so the frame
 *  hugs what it has to show instead of spanning the screen. The widest content
 *  is not the table (47 cells) but the hint rows (61 cells), so the hint rows
 *  drive the width and the table sits at the LEFT of the interior, on the same
 *  column the chips start on; the chips then cover the columns to the right of
 *  the table. There is no side panel and no extra row of information (see
 *  L10/L11/L16/L17/L19 in odd/tasks/screen-120x44.md).
 *  Keys: <Enter>=Edit  <Esc>=Leave  <Ins>=Insert Row  <Del>=Delete Row
 *          <Alt-P>=Structure to Print          <Alt-X>=Exclusive/Shared
 *          <Alt-M>=Modify Structure    <Alt-E>=Create Empty Structure
 * ===================================================================== */

/* GEOMETRY: every value below is DERIVED from the canvas (MaxRow()/MaxCol()),
 * never a literal of the 80x25 grid the original was measured on.
 * THE CONTENT DRIVES THE BOX (see L16/L17/L19 in odd/tasks/screen-120x44.md):
 *   - the five table columns have FIXED widths; "Field Name" is 12 cells and
 *     not 30 and not 73: a DBF field name is capped at 10 characters and 12 is
 *     already the field's typing width (ST_NAME_EW), so anything wider is air
 *   - the table box is the sum of those columns + the four separators + its two
 *     borders = 47 cells
 *   - the frame CANNOT be that narrow: the three hint rows are 61 cells and
 *     their TEXT does not change, so the HINT ROWS drive the frame width
 *     (interior = ST_HINT_W + 2 = 63, frame = 65), and the frame is CENTRED
 *   - the table is left-aligned inside the frame, its left border on the very
 *     column the chips start on (ST_HC = ST_BOX_L = ST_FRM_L + ST_PAD), so the
 *     15 interior columns to the right of the table (76..90) are covered by
 *     hint text instead of reading as an empty void
 * On the 120x44 canvas (MaxCol() = 119, MaxRow() = 43) this gives:
 *   cols  27..91              outer frame  (65 cells wide, centred)
 *   cols  29..75              field table  (47 cells wide)
 *   cols  30..35              Nr.          (6)
 *   cols  37..48              Field Name   (12)
 *   cols  50..60              Type         (11)
 *   cols  62..68              Len          (7)
 *   cols  70..74              Dec          (5)
 *   cols  76..90              interior right of the table (15), covered by
 *                             the hint rows on rows 37, 38 and 39
 *   row 3                     top border of the frame
 *   row 4                     title "Structure of <file>.DBF"
 *   row 5                     top border of the field table
 *   row 6                     header  " Nr.  Field Name  Type  Len  Dec"
 *   row 7                     separator " ====  ==========  ====  ===  ==="
 *   rows 8..35                the fields (ST_ROWS = 28)
 *   row 36                    bottom border of the field table
 *   rows 37, 38, 39           the three hint rows
 *   row 40                    bottom border of the frame  (MaxRow() - 3)
 *   row 43                    status bar                 (MaxRow())
 * The VERTICAL band structure is changed by none of this. */
#define ST_MARG        4                    /* min blank cols beside the frame */
#define ST_PAD         2                    /* frame border .. table border   */
#define ST_FRM_T       3                    /* top border of the frame        */
#define ST_FRM_B       ( MaxRow() - 3 )     /* bottom border of the frame     */
#define ST_ROW_TITLE   ( ST_FRM_T + 1 )
/* FIXED widths of the table columns (measured on the original). "Field Name"
 * is 12 because a DBF name cannot exceed 10 characters: the column and the
 * cell's typing width are the same number, so the cell never shows trailing
 * air that the user cannot type into. */
#define ST_NUM_W       6                    /* Nr.                            */
#define ST_NAME_W      12                   /* Field Name (= typing width)    */
#define ST_TYPE_W      11                   /* Type                           */
#define ST_LEN_W       7                    /* Len                            */
#define ST_DEC_W       5                    /* Dec                            */
/* outer width of the table box: the five columns + the four separators + its
 * own two borders (6 + 12 + 11 + 7 + 5 + 4 + 2 = 47) */
#define ST_BOX_W       ( ST_NUM_W + ST_NAME_W + ST_TYPE_W + ST_LEN_W + ST_DEC_W + 4 + 2 )
/* HINT CHIPS: the columns measured on the original (10/24/37/55 on row 1,
 * 10/47 on row 2 and 10/41 on row 3, with the frame opening at column 8) are
 * kept as OFFSETS from the first chip column, so they keep their relative
 * layout. A chip is drawn as "<key>act", so its width is Len(key) + Len(act)
 * + 2 (the two angle brackets) - the same arithmetic BpHotKey() uses. The
 * TEXT is the one of the original and must not change. */
#define ST_CHIP_W( cKey, cAct )  ( Len( cKey ) + Len( cAct ) + 2 )
#define ST_HO_ESC      14                   /* Esc   (Enter ends at +11)      */
#define ST_HO_INS      27                   /* Ins   (Esc   ends at +24)      */
#define ST_HO_DEL      45                   /* Del   (Ins   ends at +42)      */
#define ST_HO_ALTX     37                   /* Alt-X (Alt-P ends at +24)      */
#define ST_HO_ALTE     31                   /* Alt-E (Alt-M ends at +23)      */
/* WIDEST HINT ROW in cells, derived from the offsets and the texts so it can
 * never drift when a chip is edited: each of the three rows happens to end on
 * the same column (offset 60), i.e. 61 cells. This - not the table - is the
 * real floor of the frame width. */
#define ST_HINT_W      Max( ST_HO_DEL + ST_CHIP_W( "Del", "=Delete Row" ), ;
                        Max( ST_HO_ALTX + ST_CHIP_W( "Alt-X", "=Exclusive/Shared" ), ;
                             ST_HO_ALTE + ST_CHIP_W( "Alt-E", "=Create Empty Structure" ) ) )
/* outer widths: the frame interior is the widest of the two contents with one
 * free cell on each side (ST_HINT_W + 2 = 63, over a 47-cell table), so the
 * frame is that plus its two borders (65). The Max() keeps the frame valid on
 * a narrow canvas where the table would be the wider one. */
#define ST_FRM_W       Max( ST_BOX_W + 2 * ST_PAD, ST_HINT_W + 4 )
/* the frame is CENTRED on the canvas, never closer than ST_MARG to an edge */
#define ST_FRM_L       ( Max( ST_MARG, Int( ( MaxCol() + 1 - ST_FRM_W ) / 2 ) ) )
#define ST_FRM_R       ( ST_FRM_L + ST_FRM_W - 1 )
/* INNER width of the frame and its first column: the title is clipped to this
 * and the hint chips fill it, so neither leaves the box */
#define ST_TIT_C       ( ST_FRM_L + 1 )
#define ST_TIT_W       ( ST_FRM_R - ST_FRM_L - 1 )
/* field table, LEFT-aligned in the frame (not centred): its left border sits on
 * ST_FRM_L + ST_PAD, which is the column the hint chips start on */
#define ST_BOX_T       ( ST_FRM_T + 2 )
#define ST_BOX_L       ( ST_FRM_L + ST_PAD )
#define ST_BOX_R       ( ST_BOX_L + ST_BOX_W - 1 )
#define ST_ROW_FIRST   ( ST_BOX_T + 3 )     /* first data row (separator + 1)  */
/* the three hint rows are the last three interior rows of the frame */
#define ST_HELP1       ( ST_FRM_B - 3 )
#define ST_HELP2       ( ST_HELP1 + 1 )
#define ST_HELP3       ( ST_HELP1 + 2 )
#define ST_BOX_B       ( ST_HELP1 - 1 )     /* bottom border of the table      */
#define ST_ROWS        ( ST_BOX_B - ST_ROW_FIRST )   /* visible field rows    */
/* first chip column: the table's left border column, so the table and the hint
 * rows share one left edge. CHECKED against the interior: the chips run from
 * ST_HC to ST_HC + ST_HINT_W - 1 (29..89) inside an interior of ST_TIT_W = 63
 * cells (28..90), i.e. one free cell on each side and 61 <= 63. The Alt-E chip
 * ("<Alt-E>=Create Empty Structure", 30 cells) starts at offset 31 and ends at
 * offset 60 = column 89, one cell inside the border (ST_FRM_R - 1 = 90). If a
 * future canvas ever made ST_HINT_W > ST_TIT_W the gaps (not the text) would
 * have to be shortened, the way BpHotKey() chaining already works. */
#define ST_HC          ( ST_FRM_L + ST_PAD )
/* Table columns: the widths come from the fixed column set above, so the chain
 * ends exactly on the right border of the table box:
 *   | Nr. | Field Name | Type | Len | Dec |   (one cell separator each)
 * Invariant: ST_DEC_C + ST_DEC_W - 1 == ST_BOX_R - 1 (Dec ends just before the
 * right border of the box, which is not part of the span). */
#define ST_NUM_C       ( ST_BOX_L + 1 )
#define ST_V1          ( ST_NUM_C + ST_NUM_W )
#define ST_NAME_C      ( ST_V1 + 1 )
#define ST_V2          ( ST_NAME_C + ST_NAME_W )
#define ST_TYPE_C      ( ST_V2 + 1 )
#define ST_V3          ( ST_TYPE_C + ST_TYPE_W )
#define ST_LEN_C       ( ST_V3 + 1 )
#define ST_V4          ( ST_LEN_C + ST_LEN_W )
#define ST_DEC_C       ( ST_V4 + 1 )
/* width of the Field Name cell while it is being EDITED: it IS the column
 * width, because a DBF name cannot exceed 10 characters and the column is 12,
 * so column and typing width agree and the over-long name is still rejected by
 * the "Illegal Field Name" validation, exactly as before */
#define ST_NAME_EW     ST_NAME_W
/* editable columns: the cursor moves with the <-> arrows */
#define ST_C_NAME     1
#define ST_C_TYPE     2
#define ST_C_LEN      3
#define ST_C_DEC      4
#define ST_COLS       4
/* literal header/separator (the printed listing uses them) */
#define ST_HDR        " Nr.   Field Name   Type          Len     Dec"
#define ST_SEP        " ====   ==========   =========   =====   ===== "

/* field types, in the original order (codes "CNDLM") */
STATIC FUNCTION BpStructTypes()
RETURN { { "C", "Character" }, { "N", "Numeric  " }, { "D", "Date     " }, ;
         { "L", "Logical  " }, { "M", "Memo     " } }

STATIC FUNCTION BpStructTypeName( cType )
   LOCAL a := BpStructTypes(), i
   FOR i := 1 TO Len( a )
      IF a[ i ][ 1 ] == cType
         RETURN PadR( a[ i ][ 2 ], 9 )
      ENDIF
   NEXT
RETURN PadR( cType, 9 )

STATIC FUNCTION BpStructTypePos( cType )
   LOCAL a := BpStructTypes(), i
   FOR i := 1 TO Len( a )
      IF a[ i ][ 1 ] == cType
         RETURN i
      ENDIF
   NEXT
RETURN 1

STATIC FUNCTION BpStructTotal( aSt )
   LOCAL n := 0, i
   FOR i := 1 TO Len( aSt )
      n += aSt[ i ][ 3 ]
   NEXT
RETURN n

/* first visible row so that nSel stays inside the box */
STATIC FUNCTION BpStructTop( nSel, nLen )
   IF nLen <= ST_ROWS
      RETURN 1
   ENDIF
RETURN Max( 1, Min( nSel - Int( ST_ROWS / 2 ), nLen - ST_ROWS + 1 ) )

/* valid field name: not empty, only A-Z 0-9 _ (charset of the original) and
 * up to 10 characters. The limit is NOT cosmetic: dbCreate() truncates at 10
 * silently, so two different names can end up DUPLICATED in the new file
 * (measured: "ABCDEFGHIJK" -> "ABCDEFGHIJ"). */
STATIC FUNCTION BpStructNameOk( cName )
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

STATIC FUNCTION BpStructNameUsed( aSt, nSel, cName )
   LOCAL i
   FOR i := 1 TO Len( aSt )
      IF i != nSel .AND. Upper( aSt[ i ][ 1 ] ) == cName
         RETURN .T.
      ENDIF
   NEXT
RETURN .F.

/* does a field take decimals? (only the numeric ones: in C/D/L/M the "Dec"
 * column cannot even be selected) */
STATIC FUNCTION BpStructDecOk( aSt, nSel )
   IF Len( aSt ) < 1 .OR. nSel < 1 .OR. nSel > Len( aSt )
      RETURN .F.
   ENDIF
RETURN ( aSt[ nSel ][ 2 ] == "N" )

/* one field row (no UiPaint*: the caller wraps it, so several rows are
 * repainted at once and without flicker) */
STATIC PROCEDURE BpStructRow( aSt, i, nTop, nCol, nSel )
   LOCAL nRow := ST_ROW_FIRST + ( i - nTop )
   IF i < 1 .OR. i > Len( aSt ) .OR. nRow >= ST_BOX_B
      RETURN
   ENDIF
   /* Nr. : never highlighted (the original leaves it blank) */
   SetColor( UI_C_STROW )
   @ nRow, ST_NUM_C SAY PadL( LTrim( Str( i ) ), ST_NUM_W )
   /* the four editable cells: the cursor one in cyan, the other three of the
    * current record highlighted (the original paints them in magenta) */
   SetColor( BpStructCellColor( i, nSel, nCol, ST_C_NAME ) )
   @ nRow, ST_NAME_C SAY PadR( aSt[ i ][ 1 ], ST_NAME_W )
   SetColor( BpStructCellColor( i, nSel, nCol, ST_C_TYPE ) )
   @ nRow, ST_TYPE_C SAY PadR( BpStructTypeName( aSt[ i ][ 2 ] ), ST_TYPE_W )
   SetColor( BpStructCellColor( i, nSel, nCol, ST_C_LEN ) )
   @ nRow, ST_LEN_C SAY PadL( LTrim( Str( aSt[ i ][ 3 ] ) ), ST_LEN_W )
   SetColor( BpStructCellColor( i, nSel, nCol, ST_C_DEC ) )
   @ nRow, ST_DEC_C SAY PadL( LTrim( Str( aSt[ i ][ 4 ] ) ), ST_DEC_W )
   /* the vertical separators are NOT painted here: they are constant and
    * BpStructDraw draws them once. So repainting a row is 5 SAYs instead of 9
    * and the scroll is not seen "forming". */
   SetColor( UI_C_DESKTOP )
RETURN NIL

/* colour of a cell: the cursor one in cyan, the others of the current record
 * highlighted, the rest normal */
STATIC FUNCTION BpStructCellColor( i, nSel, nCol, nCell )
   IF i != nSel
      RETURN UI_C_STROW
   ENDIF
   IF nCell == nCol
      RETURN UI_C_STCUR
   ENDIF
RETURN UI_C_STSEL

/* vertical scroll of the table: the visible rows are repainted all at
 * once (a single paint block = a single REFRESH).
 * Scroll() of the GT is NOT used: in GTWVG it does not drag the text buffer (it
 * fills with a solid character) and it left the vertical separators as gray
 * bars, because those are only painted once by BpStructDraw. The system
 * cursor is hidden, so repainting ST_ROWS (28) rows does not flicker at all. */
STATIC PROCEDURE BpStructRows( aSt, nTop, nCol, nSel )
   LOCAL i
   UiPaintBegin()
   FOR i := nTop TO Min( Len( aSt ), nTop + ST_ROWS - 1 )
      BpStructRow( aSt, i, nTop, nCol, nSel )
   NEXT
   UiPaintEnd()
RETURN NIL

/* Status bar of the structure editor (last row of the canvas): like
 * CoreStatus(), but with the open mode (<shar>/<exclu>) on the RIGHT. The
 * directory text is clipped so it does not end up under the chip when the path
 * is long. */
STATIC PROCEDURE BpStructStatus( cMode )
   LOCAL nRow := MaxRow(), nCols := MaxCol() + 1
   LOCAL nW := nCols - Len( cMode ) - 1      /* one spare cell before the chip   */
   LOCAL cTxt := "Directory: " + CoreDir()
   IF Len( cTxt ) > nW
      cTxt := Left( cTxt, Max( 0, nW - 3 ) ) + "..."
   ENDIF
   SetColor( UI_C_STATUS )
   @ nRow, 0 SAY Space( nCols )
   @ nRow, 0 SAY PadR( cTxt, nW )
   UiWrite( nRow, nCols - Len( cMode ), cMode, UI_C_STTIT )
RETURN NIL

/* full drawing of the editor screen (only on entry and when the database
 * changes); cursor moves repaint single rows */
STATIC PROCEDURE BpStructDraw( aSt, cFile, nCol, nSel )
   LOCAL nTop := BpStructTop( nSel, Len( aSt ) ), cTit, cMode, cPath, r, nTitCol
   UiPaintBegin()
   SetColor( UI_C_DARK )
   CLS
   BpMenuBar( 0 )
   /* REAL mode of the open database (not the setting for the next open): it
    * goes on the RIGHT of the status bar, so it does not overlap the title
    * when the file path is long (it used to be on the title edge and a long
    * name overflowed it) */
   cMode := iif( CoreRealMode() == "SHARED", "<shar>", "<exclu>" )
   BpStructStatus( cMode )
   UiFrame( ST_FRM_T, ST_FRM_L, ST_FRM_B, ST_FRM_R, UI_C_STBRD, .T. )
   cPath := iif( Empty( cFile ) .OR. Rat( "\", cFile ) > 0, cFile, CoreDir() + cFile )
   cTit := "Structure of " + iif( Empty( cFile ), "<New File>", Upper( cPath ) + ".DBF" )
   /* the title is CLIPPED to the inner width of the frame (ST_TIT_W cells):
    * with a long path it left the box. It is clipped from the START so as not
    * to lose the file name, which is what matters. */
   IF Len( cTit ) > ST_TIT_W
      cTit := Left( cTit, 13 ) + "..." + Right( cTit, ST_TIT_W - 16 )
   ENDIF
   nTitCol := ST_TIT_C + Int( ( ST_TIT_W - Len( cTit ) ) / 2 )
   UiWrite( ST_ROW_TITLE, nTitCol, cTit, UI_C_STTIT )
   UiFrame( ST_BOX_T, ST_BOX_L, ST_BOX_B, ST_BOX_R, UI_C_STBRD, .T. )
   /* vertical separators of the table */
   SetColor( UI_C_STBRD )
   FOR r := ST_BOX_T + 1 TO ST_BOX_B - 1
      @ r, ST_V1 SAY BP_SEP_VERT
      @ r, ST_V2 SAY BP_SEP_VERT
      @ r, ST_V3 SAY BP_SEP_VERT
      @ r, ST_V4 SAY BP_SEP_VERT
   NEXT
   /* header and '=' separator */
   SetColor( UI_C_STTIT )
   @ ST_BOX_T + 1, ST_NUM_C  SAY PadL( "Nr.", ST_NUM_W )
   @ ST_BOX_T + 1, ST_NAME_C SAY PadR( " Field Name", ST_NAME_W )
   @ ST_BOX_T + 1, ST_TYPE_C SAY " Type"
   @ ST_BOX_T + 1, ST_LEN_C  SAY PadL( "Len", ST_LEN_W )
   @ ST_BOX_T + 1, ST_DEC_C  SAY PadL( "Dec", ST_DEC_W )
   @ ST_BOX_T + 2, ST_NUM_C  SAY Replicate( "=", ST_NUM_W )
   @ ST_BOX_T + 2, ST_NAME_C SAY Replicate( "=", ST_NAME_W )
   @ ST_BOX_T + 2, ST_TYPE_C SAY Replicate( "=", ST_TYPE_W )
   @ ST_BOX_T + 2, ST_LEN_C  SAY Replicate( "=", ST_LEN_W )
   @ ST_BOX_T + 2, ST_DEC_C  SAY Replicate( "=", ST_DEC_W )
   SetColor( UI_C_STBRD )
   FOR r := ST_BOX_T + 2 TO ST_BOX_T + 2
      @ r, ST_V1 SAY "="
      @ r, ST_V2 SAY "="
      @ r, ST_V3 SAY "="
      @ r, ST_V4 SAY "="
   NEXT
   SetColor( UI_C_DESKTOP )
   BpStructRows( aSt, BpStructTop( nSel, Len( aSt ) ), nCol, nSel )
   BpHotKey( ST_HELP1, ST_HC,             "Enter", "=Edit" )
   BpHotKey( ST_HELP1, ST_HC + ST_HO_ESC, "Esc",   "=Leave" )
   BpHotKey( ST_HELP1, ST_HC + ST_HO_INS, "Ins",   "=Insert Row" )
   BpHotKey( ST_HELP1, ST_HC + ST_HO_DEL, "Del",   "=Delete Row" )
   BpHotKey( ST_HELP2, ST_HC,              "Alt-P", "=Structure to Print" )
   BpHotKey( ST_HELP2, ST_HC + ST_HO_ALTX, "Alt-X", "=Exclusive/Shared" )
   BpHotKey( ST_HELP3, ST_HC,              "Alt-M", "=Modify Structure" )
   /* NOTE: the chip must fit inside the frame; "<Alt-E>" + "=Create Empty
    * Structure" are 30 characters, so it starts at ST_HC + ST_HO_ALTE and its
    * last cell is ST_HC + ST_HO_ALTE + 29 = ST_HC + 60, which keeps it inside
    * the interior of the frame (see the note on the ST_H* defines) */
   BpHotKey( ST_HELP3, ST_HC + ST_HO_ALTE, "Alt-E", "=Create Empty Structure" )
   /* a single paint pass for the WHOLE screen (a single update) */
   UiPaintEnd()
RETURN

/* F2 > Generate Structure PRG: writes a Harbour program that RECREATES the
 * structure of the open database and its indexes (tags), without data. */
FUNCTION BpDbGenPrg()
   LOCAL aLines, cDef, cAct, cPrg, cText, i, lOk
   IF ! Used()
      UiMsg( "No database is open.", "Generate Structure PRG" )
      RETURN NIL
   ENDIF
   aLines := StructGenPrgText()
   IF Empty( aLines )
      UiErr( "Cannot read the structure of " + Alias() + ".", "Generate Structure PRG" )
      RETURN NIL
   ENDIF
   cDef := "STRUCT_" + Upper( CoreFileBase() ) + ".PRG"
   /* the program is SHOWN and from there it is saved or copied */
   DO WHILE .T.
      cAct := UiTextWin( aLines, "Generated PRG: " + cDef, ;
                         { { "S", "Save file" }, { "C", "Copy" } } )
      IF cAct == "S"
         cPrg := UiInput( "Program file name:", cDef, 40 )
         IF cPrg == NIL .OR. Empty( AllTrim( cPrg ) )
            LOOP
         ENDIF
         cPrg := AllTrim( cPrg )
         IF ! ( "." $ cPrg )
            cPrg += ".PRG"
         ENDIF
         IF File( cPrg )
            IF ! UiConfirm( cPrg + " exists already." + hb_eol() + "Overwrite?", ;
                            "Generate Structure PRG" )
               LOOP
            ENDIF
         ENDIF
         lOk := StructGenPrg( cPrg, aLines )
         BpLog( "BpDbGenPrg: write " + cPrg + " -> " + iif( lOk, "ok", "fail" ) )
         IF lOk
            cDef := cPrg
            UiInfo( "Program written: " + cPrg, "Generate Structure PRG" )
         ELSE
            UiErr( "Cannot write " + cPrg, "Generate Structure PRG" )
         ENDIF
      ELSEIF cAct == "C"
         cText := ""
         FOR i := 1 TO Len( aLines )
            cText += aLines[ i ] + hb_eol()
         NEXT
         IF BpClipPut( cText )
            UiInfo( "Program copied to the clipboard (" + ;
                    LTrim( Str( Len( aLines ) ) ) + " lines).", "Generate Structure PRG" )
         ELSE
            UiErr( "Cannot copy to the clipboard.", "Generate Structure PRG" )
         ENDIF
      ELSE
         EXIT
      ENDIF
   ENDDO
RETURN NIL

/* Windows clipboard: GTWVG does not expose it, bp_win32.c does it */
FUNCTION BpClipPut( cText )
   DEFAULT cText TO ""
RETURN W32ClipPut( cText )

FUNCTION BpDbCreateModify()
   LOCAL aSt, cFile := "", nSel := 1, nCol := ST_C_NAME, nKey, lEdited := .F.
   LOCAL nOld, nOldCol, nTop, nNew, nRowOn, lAll, lCur, lRows, cOldCur
   IF Used()
      aSt := AClone( DbStruct() )
      cFile := DBF()
   ELSE
      /* a new database starts with ONE blank field (like the original:
       * Nr. 1, empty name, Character, 10, 0) */
      aSt := { { "", "C", 10, 0 } }
   ENDIF
   /* the editor paints its own cell cursor: the system cursor is hidden
    * (otherwise it blinks inside a cell and jumps around when repainting) */
   cOldCur := SetCursor( 0 )
   /* S1 of window-close.md (B4): the hook of bp_win32.c is ARMED while this
    * screen owns the display, because it is the only thing that makes WM_CLOSE
    * reach the latch the key loop peeks (the editor has no mouse code of its
    * own, so the hook costs nothing else here). It is NOT disarmed on the way
    * out on purpose: DotMouseHook( .T. ) is idempotent, so a caller that already
    * owns the hook (the Browse edit, which installs it and never re-installs it)
    * is untouched -disarming here would strip its wheel, its clicks and its own
    * X-, and a caller without one (the desktop) simply keeps it armed for the
    * rest of the session, which is harmless: the driver has no use for those
    * mouse messages and every screen that cares polls its own channel. That is
    * also what makes the X reachable from the desktop path. The proper
    * "install only if not mine / remove only if mine" guard needs a hook-state
    * getter in bp_win32.c and is a follow-up, not this task. */
   DotMouseHook( .T. )
   nTop := BpStructTop( nSel, Len( aSt ) )
   BpStructDraw( aSt, cFile, nCol, nSel )   /* full screen only when entering   */
   DO WHILE .T.
      IF Len( aSt ) > 0
         nSel := Max( 1, Min( nSel, Len( aSt ) ) )
      ELSE
         nSel := 1
      ENDIF
      nOld := nSel
      nOldCol := nCol
      /* S1/S4 (window-close.md B4): the X of the window is peeked by the wait
       * itself (BpWaitKey), so it leaves through the SAME exit <Esc> uses below
       * -EXIT, and the tail restores the caret- instead of unwinding in the
       * middle of a pass. An idle slice does not reach the DO CASE, so a pass
       * with no key paints nothing, exactly as before. */
      nKey := BpWaitKey()
      IF nKey == 0
         EXIT
      ENDIF
      lAll := .F.
      lCur := .F.
      lRows := .F.
      DO CASE
      CASE nKey == K_ESC
         /* the original warns if it has been edited */
         IF lEdited .AND. ! UiConfirm( "Structure has been Edited!" + hb_eol() + ;
                                      "Discard Changes?", "Structure" )
            LOOP
         ENDIF
         /* the single exit of the editor: the tail restores the caret (and it
          * is the exit the X of the window takes too, B4) */
         EXIT
      CASE nKey == K_UP
         nSel := Max( 1, nSel - 1 )
      CASE nKey == K_DOWN
         nSel := Min( Max( 1, Len( aSt ) ), nSel + 1 )
      CASE nKey == K_LEFT          /* columns: Name <-> Type <-> Len <-> Dec. */
         nCol := Max( ST_C_NAME, nCol - 1 )
      CASE nKey == K_RIGHT .OR. nKey == K_TAB
         IF nCol < ST_C_DEC
            nCol++
            /* fields without decimals (C/D/L/M) have no "Dec" column */
            IF nCol == ST_C_DEC .AND. ! BpStructDecOk( aSt, nSel )
               nCol := ST_C_LEN
            ENDIF
         ENDIF
      CASE nKey == K_SH_TAB
         nCol := Max( ST_C_NAME, nCol - 1 )
      CASE nKey == K_PGDN .OR. nKey == K_PGUP
         /* one page of fields keeping the screen row of the cursor (just
          * like the browser): the field AND the window move at the same time */
         IF Len( aSt ) > 0
            nRowOn := nSel - nTop
            IF nKey == K_PGDN
               nSel := Min( Len( aSt ), nSel + ST_ROWS )
            ELSE
               nSel := Max( 1, nSel - ST_ROWS )
            ENDIF
            nTop := Max( 1, Min( nSel - nRowOn, Max( 1, Len( aSt ) - ST_ROWS + 1 ) ) )
            lRows := .T.
         ENDIF
      CASE nKey == K_CTRL_HOME
         /* first column (like Ctrl-Home in the browser) */
         nCol := ST_C_NAME
      CASE nKey == K_CTRL_END
         /* last editable column of the current field */
         nCol := iif( BpStructDecOk( aSt, nSel ), ST_C_DEC, ST_C_LEN )
      CASE nKey == K_CTRL_PGUP
         /* start of the field list (cursor on the first field) */
         nSel := 1
      CASE nKey == K_CTRL_PGDN
         /* end of the field list */
         nSel := Max( 1, Len( aSt ) )
      CASE nKey == K_INS
         /* <Ins>=Insert Row. NOTE: AIns() does NOT grow the array in this
          * Harbour, so it has to be done in StructInsertRow() (see AGENTS.md
          * 5.27); otherwise inserting a field SILENTLY DELETED the last (ART_EAM). */
         StructInsertRow( aSt, nSel )
         lEdited := .T. ; lAll := .T.
      CASE nKey == K_DEL
         /* <Del>=Delete Row */
         IF Len( aSt ) > 0
            StructDeleteRow( aSt, nSel )
            lEdited := .T. ; lAll := .T.
         ENDIF
      CASE nKey == K_ENTER
         /* <Enter>=Edit the current cell */
         IF BpStructEditField( aSt, nSel, nCol, cFile )
            lEdited := .T.
         ENDIF
         lCur := .T.
      CASE nKey == K_ALT_M
         IF BpStructApply( cFile, aSt )
            /* the modification was applied: it STAYS in the structure editor
             * (it does not go back to the browser). The REAL structure of the
             * changed file is reloaded (that is what was left on disk) and the
             * "edited" flag is cleared, so Esc does not ask about discarding a
             * change that is already saved. */
            IF Used()
               aSt   := AClone( DbStruct() )
               cFile := DBF()
            ENDIF
            lEdited := .F.
            nSel := Max( 1, Min( nSel, Len( aSt ) ) )
            nCol := ST_C_NAME
            lAll := .T.
         ELSE
            lAll := .T.
         ENDIF
      CASE nKey == K_ALT_E
         IF BpStructCreate( cFile, aSt )
            /* out through the single exit of the editor (caret and the window
             * hook, when it is installed here, are restored by the tail) */
            EXIT
         ENDIF
         lAll := .T.
      CASE nKey == K_ALT_P
         BpStructPrint( aSt, cFile )
         lAll := .T.
      CASE nKey == K_ALT_X
         BpDbToggleMode()
         lAll := .T.
      CASE ( nKey >= 32 .AND. nKey <= 255 ) .OR. nKey == K_BS
         /* the original allows typing DIRECTLY in the cell of the cursor */
         IF Len( aSt ) > 0
            IF BpStructEditField( aSt, nSel, nCol, cFile, iif( nKey >= 32, Chr( nKey ), "" ) )
               lEdited := .T.
            ENDIF
            lCur := .T.
         ENDIF
      ENDCASE
      /* the cursor never stays in the "Dec" column of a field without decimals */
      IF nCol == ST_C_DEC .AND. ! BpStructDecOk( aSt, nSel )
         nCol := ST_C_LEN
      ENDIF
      /* ------- repaint: only what changed (no flicker at all) ------------- */
      IF lAll
         nTop := BpStructTop( nSel, Len( aSt ) )
         BpStructDraw( aSt, cFile, nCol, nSel )
      ELSEIF lRows
         /* page: the window was computed by hand, the rows are painted */
         BpStructRows( aSt, nTop, nCol, nSel )
      ELSE
         nNew := BpStructTop( nSel, Len( aSt ) )
         IF nNew != nTop
            nTop := nNew
            BpStructRows( aSt, nTop, nCol, nSel )
         ELSEIF nSel != nOld
            UiPaintBegin()
            BpStructRow( aSt, nSel, nTop, nCol, nSel )
            BpStructRow( aSt, nOld, nTop, nCol, nSel )
            UiPaintEnd()
         ELSEIF nCol != nOldCol .OR. lCur
            UiPaintBegin()
            BpStructRow( aSt, nSel, nTop, nCol, nSel )
            UiPaintEnd()
         ENDIF
      ENDIF
   ENDDO
   SetCursor( cOldCur )
RETURN NIL

/* <Enter>=Edit: edits THE CELL of column nCol of field nSel.
 * cSeed = character already typed by the user (the original allows writing
 * directly in the cell without pressing Enter first). */
STATIC FUNCTION BpStructEditField( aSt, nSel, nCol, cFile, cSeed )
   LOCAL aTp := BpStructTypes(), aNames := {}, i, n, nRow, cName, cVal, lCh := .F.
   DEFAULT cSeed TO ""
   IF Len( aSt ) < 1
      RETURN .F.
   ENDIF
   nRow := ST_ROW_FIRST + ( nSel - BpStructTop( nSel, Len( aSt ) ) )
   DO CASE
   CASE nCol == ST_C_NAME
      cVal := aSt[ nSel ][ 1 ]
      IF ! Empty( cSeed )
         /* the field name is stored in upper case: the typed character
          * is also passed in upper case */
         cVal := Stuff( PadR( cVal, ST_NAME_EW ), 1, 1, Upper( cSeed ) )
      ENDIF
      /* the Name field is always typed in UPPER CASE (like the original) */
      cName := UiLineEdit( nRow, ST_NAME_C, ST_NAME_EW, cVal, .F., UI_C_STCUR, .T. )
      IF cName == NIL
         RETURN .F.
      ENDIF
      cName := Upper( AllTrim( cName ) )
      IF Empty( cName )
         UiErr( "Blank Field Name" )
         RETURN .F.
      ENDIF
      IF ! BpStructNameOk( cName )
         UiErr( "Illegal Field Name" )
         RETURN .F.
      ENDIF
      IF BpStructNameUsed( aSt, nSel, cName )
         UiErr( "Duplicate Field Name" )
         RETURN .F.
      ENDIF
      /* EXACT comparison (==) on purpose: with SET EXACT OFF `=` pads the
       * LEFT operand with spaces up to Len(right), so comparing
       * against "" is always .T. and `cName != ""` gave .F.: the typed name
       * was SILENTLY DISCARDED when inserting a new field (current name
       * empty). Measured in this build: "NOMBRE" = "" -> .T., "NOMBRE" != "" -> .F.
       * See AGENTS.md, trap 20. */
      IF ! ( cName == Upper( aSt[ nSel ][ 1 ] ) )
         aSt[ nSel ][ 1 ] := cName
         lCh := .T.
      ENDIF

   CASE nCol == ST_C_TYPE
      FOR i := 1 TO Len( aTp )
         AAdd( aNames, aTp[ i ][ 2 ] )
      NEXT
      n := 0
      IF ! Empty( cSeed )
         /* type the initial of the type: C=Character N=Numeric D=Date L=Logical M=Memo */
         FOR i := 1 TO Len( aTp )
            IF Upper( Left( aTp[ i ][ 2 ], 1 ) ) == Upper( Left( cSeed, 1 ) )
               n := i
               EXIT
            ENDIF
         NEXT
      ELSE
         n := UiPick( aNames, "Structure of " + iif( Empty( cFile ), "<New File>", Upper( cFile ) ), ;
                      BpStructTypePos( aSt[ nSel ][ 2 ] ) )
      ENDIF
      IF n > 0 .AND. ! ( aTp[ n ][ 1 ] == aSt[ nSel ][ 2 ] )
         aSt[ nSel ][ 2 ] := aTp[ n ][ 1 ]
         lCh := .T.
      ENDIF
      /* on a type change length and decimals are normalized (like dBASE):
       * Date=8, Logical=1, Memo=10 and no decimals on non numeric */
      IF lCh
         DO CASE
         CASE aSt[ nSel ][ 2 ] == "D" ; aSt[ nSel ][ 3 ] := 8  ; aSt[ nSel ][ 4 ] := 0
         CASE aSt[ nSel ][ 2 ] == "L" ; aSt[ nSel ][ 3 ] := 1  ; aSt[ nSel ][ 4 ] := 0
         CASE aSt[ nSel ][ 2 ] == "M" ; aSt[ nSel ][ 3 ] := 10 ; aSt[ nSel ][ 4 ] := 0
         CASE aSt[ nSel ][ 2 ] != "N" ; aSt[ nSel ][ 4 ] := 0
         ENDCASE
      ENDIF

   CASE nCol == ST_C_LEN
      cVal := LTrim( Str( aSt[ nSel ][ 3 ] ) )
      IF ! Empty( cSeed ) .AND. IsDigit( cSeed )
         cVal := cSeed
      ENDIF
      cName := UiLineEdit( nRow, ST_LEN_C, ST_LEN_W, cVal, .T., UI_C_STCUR )
      IF cName != NIL
         IF Empty( cName ) .OR. Val( cName ) < 1
            UiErr( "Invalid Field Width" )
         ELSEIF Int( Val( cName ) ) != aSt[ nSel ][ 3 ]
            aSt[ nSel ][ 3 ] := Int( Val( cName ) )
            lCh := .T.
         ENDIF
      ENDIF

   CASE nCol == ST_C_DEC
      cVal := LTrim( Str( aSt[ nSel ][ 4 ] ) )
      IF ! Empty( cSeed ) .AND. IsDigit( cSeed )
         cVal := cSeed
      ENDIF
      cName := UiLineEdit( nRow, ST_DEC_C, ST_DEC_W, cVal, .T., UI_C_STCUR )
      IF cName != NIL
         IF ! Empty( cName ) .AND. ( Val( cName ) < 0 .OR. Val( cName ) > 9 )
            UiErr( "Invalid Decimal Width" )
         ELSEIF ! Empty( cName ) .AND. Int( Val( cName ) ) >= aSt[ nSel ][ 3 ]
            /* the decimals of a numeric must be less than its length */
            UiErr( "Invalid Decimal Width" )
         ELSEIF ! Empty( cName ) .AND. Int( Val( cName ) ) != aSt[ nSel ][ 4 ]
            aSt[ nSel ][ 4 ] := Int( Val( cName ) )
            lCh := .T.
         ENDIF
      ENDIF
   ENDCASE
RETURN lCh

/* previous checks: they are delegated to StructValidate() (bp_struct.prg), which
 * is the same one StructApply() applies and the one the headless tests use. Here
 * only what the engine stores the same is normalized (Date=8, Logical=1, Memo=10,
 * no decimals on non numeric) and the message is shown. */
STATIC FUNCTION BpStructCheck( aSt )
   LOCAL cMsg
   StructNormalize( aSt )
   cMsg := StructValidate( aSt )
   IF ! Empty( cMsg )
      UiErr( cMsg )
      RETURN .F.
   ENDIF
RETURN .T.

/* file name for a new database */
STATIC FUNCTION BpStructNewName()
   LOCAL c := BpNewFileBox( "Create New Database", "NEWFILE.DBF" )
   IF Len( c ) == 0
      RETURN NIL
   ENDIF
RETURN c

/* Alt-M: "Modify Structure & Copy Data" — rewrites the structure copying the
 * data by name. The copy and the file change are done by StructApply()
 * (bp_struct.prg): it opens the temp file in its OWN area, copies record by
 * record (reporting progress with a progress bar), checks the number of
 * records and swaps the file leaving a .BAK backup in between.
 *
 * ⚠ The hang the user reported was here: dbCreate() does NOT open the
 * file it creates, so "APPEND FROM ( cOld )" ran with the area of the
 * ORIGINAL database active and copied the database ONTO ITSELF (it grew without
 * end until filling the disk). See AGENTS.md 5. */
STATIC FUNCTION BpStructApply( cFile, aSt )
   LOCAL cFull, cMsg, nTotal, lOk := .F.
   LOCAL cPathX, cBaseX, cExtX, aSum := {}, aImpact := {}, aDec
   LOCAL cSave, cBaseName, lReopen
   IF ! BpStructCheck( aSt )
      RETURN .F.
   ENDIF
   IF Empty( cFile )
      cFull := BpStructNewName()
      IF cFull == NIL
         RETURN .F.
      ENDIF
   ELSE
      /* FULL PATH of the original: the temp file, the .BAK and the .FPT/.DBT
       * have to stay ALWAYS in the same directory as the database. DBF() returns
       * the name WITHOUT PATH or extension, and with a relative name the temp
       * file would end up in the working directory (which may be another one).
       * Note: ".DBF" cannot be appended to CoreFileName(), it has the extension. */
      cFull := CoreFileName()
      IF Empty( cFull )
         /* fallback in case the RDD does not give DBI_FULLPATH: what the
          * editor has is used and the extension is added only if absent */
         cFull := cFile
         hb_FNameSplit( cFull, @cPathX, @cBaseX, @cExtX )
         IF Empty( cExtX )
            cFull += ".DBF"
         ENDIF
      ENDIF
   ENDIF
   IF ! UiConfirm( "Modify Structure & Copy Data" + hb_eol() + Upper( cFull ) + " ?", "Structure" )
      RETURN .F.
   ENDIF
   IF Used()
      IF ! UiConfirm( "WARNING!" + hb_eol() + ;
                      "Content of Removed Fields or of Fields with Changed" + hb_eol() + ;
                      "Field Names will be LOST!!!  Ok to lose Data?", "Structure" )
         RETURN .F.
      ENDIF
   ENDIF
   /* The screen used to stay frozen in the two phases of this option that
    * report NOTHING (measured on a 509,878-record / 249 MB table: the copy
    * itself takes ~52 s and just re-opening the rewritten file with its .CDX
    * takes 21-26 s), so both are wrapped in the SAME progress box as the copy
    * (UiProgBegin()/UiProgUpdate()/UiProgEnd(), bp_ui.prg). Neither of them can
    * be interrupted, so lCancel is .F.
    * UiProgEnd() closes the bar but does NOT erase the box: the rectangle it
    * paints (box + shadow, UiProgRect()) is saved ONCE here, before the first
    * box, and put back after the last one by BpStructProgOff(). Nothing paints
    * that area during the operation (StructApply() does not touch the screen
    * and BpIdxProgress() reuses the same box), so one snapshot is valid for
    * both phases and the dialogs in between never land on the bar. */
   cSave := BpStructProgSave()
   /* the base name of the file that is rewritten (no path, no extension), for
    * the title of the re-open box: hb_FNameName() already drops the extension
    * (AGENTS.md 5.35) */
   cBaseName := Upper( hb_FNameName( cFull ) )
   /* INDEX query: if the change touches the key of some tag the list is shown
    * (UiTextWin) and it asks Order by Order whether to reindex. With "No" on
    * an Order its index is left as it is; if no key is touched, NOTHING is
    * shown and the index files stay untouched. */
   IF Used()
      /* 1. the index-key analysis asks the driver for every tag and used to be
       * the very first thing done, with no feedback at all */
      UiProgBegin( "Checking index tags...", 1, .F. )
      UiProgUpdate( 0, 1 )
      aImpact := StructTagImpact( DbStruct(), aSt, StructTags( Select() ) )
      UiProgEnd()
      /* the box has to be GONE before the decision dialog is painted */
      BpStructProgOff( cSave )
      IF ! Empty( aImpact )
         aDec := BpStructTagDecide( aImpact )
         IF ValType( aDec ) != "A"
            /* cancelled: no box is open here, there is nothing to close */
            RETURN .F.
         ENDIF
      ENDIF
   ENDIF
   /* progress is reported with a progress bar: the total is the number of
    * records of the open database (<Esc> cancels it without touching anything).
    * The index warning was already done above, so StructApply() gets NIL. */
   nTotal := iif( Used(), RecCount(), 0 )
   UiProgBegin( "Altering File Structure...", nTotal )
   cMsg := StructApply( aSt, cFull, {| nDone, nTot | UiProgUpdate( nDone, nTot ) }, ;
                        NIL, {| nDone, nTot | BpIdxProgress( nDone, nTot ) } )
   UiProgEnd()
   IF Empty( cMsg )
      /* 2. the rewritten file is opened again in its own area and its .CDX is
       * added: 21-26 s on a big table, and until now the screen showed the
       * remains of the copy bar while nothing answered. On the error path the
       * original has to be reopened (it is in place or in .BAK) and it costs the
       * same, so it gets the same box; a cancel leaves the base open already. */
      lReopen := .T.
   ELSEIF cMsg == BP_STRUCT_CANCEL
      /* cancelled: the original database was not touched and stays open */
      lReopen := .F.
   ELSE
      lReopen := ( CoreAreaByFile( cFull ) == 0 .AND. hb_FNameExists( cFull ) )
   ENDIF
   IF lReopen
      UiProgBegin( "Reopening " + cBaseName + "...", 1, .F. )
      UiProgUpdate( 0, 1 )
      CoreOpen( cFull )
      CoreOrdList()
      UiProgEnd()
   ENDIF
   /* no box may stay on screen: the editor underneath is put back (UiProgEnd()
    * does not erase it) before any message is shown, also on the cancel path */
   BpStructProgOff( cSave )
   IF Empty( cMsg )
      UiInfo( "File Structure Altered", "Structure" )
      /* index summary (only if the database had tags) */
      aSum := BpStructTagSummary()
      IF ! Empty( aSum )
         UiTextWin( aSum, "Index Tags" )
      ENDIF
      lOk := .T.
   ELSEIF cMsg == BP_STRUCT_CANCEL
      UiInfo( "File Structure NOT Altered" + hb_eol() + "Structure alteration cancelled.", "Structure" )
   ELSE
      UiErr( "Error detected - File Structure Not Altered" + hb_eol() + cMsg )
   ENDIF
RETURN lOk

/* Screen snapshot of the area the progress box paints (box + shadow).
 * UiProgBegin() paints the box but UiProgEnd() does NOT erase it, so a caller
 * that has to show something else afterwards saves this rectangle first and
 * restores it with BpStructProgOff(). UiProgRect() (bp_ui.prg) is the only
 * source of the rectangle: hardcoding it would break if the box moves. */
STATIC FUNCTION BpStructProgSave()
   LOCAL aP := UiProgRect()
RETURN SaveScreen( aP[ 1 ], aP[ 2 ], Min( MaxRow(), aP[ 3 ] + 1 ), ;
                   Min( MaxCol(), aP[ 4 ] + 2 ) )

/* Puts that snapshot back: it is called after EVERY UiProgEnd() of the Alt-M
 * path (index analysis, copy, re-open), so no box is ever left on screen. */
STATIC FUNCTION BpStructProgOff( cSave )
   LOCAL aP := UiProgRect()
   RestScreen( aP[ 1 ], aP[ 2 ], Min( MaxRow(), aP[ 3 ] + 1 ), ;
               Min( MaxCol(), aP[ 4 ] + 2 ), cSave )
RETURN NIL

/* -------------------------------------------------------------------------
 * Previous query of the indexes affected by the structure change (Alt-M).
 *
 * It is shown ONLY if some index key uses a field the modification
 * touches. First the list (UiTextWin) with tag, key expression and the
 * reason; then it asks ORDER BY ORDER whether to reindex:
 *
 *   lCanRebuild = .T. -> the field changes length/type: the tag can be rebuilt
 *                        with the new key, and the user decides Yes/No. "No"
 *                        leaves that index as it is.
 *   lCanRebuild = .F. -> the field disappeared or was renamed: the tag CANNOT be
 *                        kept (the database would not even open), so it is
 *                        dropped; there is nothing to ask.
 *
 * Returns an array of logicals aligned with aImpact (for StructApply) or .F.
 * if the user cancels the whole operation.
 * ------------------------------------------------------------------------- */
STATIC FUNCTION BpStructTagDecide( aImpact )
   LOCAL aLin := {}, aDec := {}, i, j
   AAdd( aLin, "This structure change modifies fields used by index keys." )
   AAdd( aLin, "" )
   FOR i := 1 TO Len( aImpact )
      AAdd( aLin, "Tag " + PadR( aImpact[ i ][ 1 ], 12 ) + "key " + aImpact[ i ][ 2 ] )
      FOR j := 1 TO Len( aImpact[ i ][ 5 ] )
         AAdd( aLin, "    " + aImpact[ i ][ 5 ][ j ] )
      NEXT
      IF aImpact[ i ][ 4 ]
         AAdd( aLin, "    -> you will be asked whether to reindex this order" )
      ELSE
         AAdd( aLin, "    -> cannot be kept: the tag will be DROPPED (the data is not affected)" )
      ENDIF
      AAdd( aLin, "" )
   NEXT
   AAdd( aLin, "Orders whose key is not involved are NOT touched." )
   UiTextWin( aLin, "Index Keys Affected" )

   /* the question is per Order: the user decides each one */
   FOR i := 1 TO Len( aImpact )
      IF aImpact[ i ][ 4 ]
         AAdd( aDec, UiConfirm( "Reindex order " + aImpact[ i ][ 1 ] + " ?" + hb_eol() + ;
                                "key " + aImpact[ i ][ 2 ] + hb_eol() + ;
                                "No = keep the current index of this order.", "Reindex" ) )
      ELSE
         AAdd( aDec, .F. )
      ENDIF
   NEXT
RETURN aDec

/* Reindex progress bar: StructApply() calls it once per tag.
 * The copy box is already on screen, so it is reopened with another title and
 * another total (UiProgBegin is idempotent and paints the box again). */
STATIC FUNCTION BpIdxProgress( nDone, nTotal )
   IF nDone == 1
      UiProgBegin( "Reindexing index tags...", nTotal )
   ENDIF
   UiProgUpdate( nDone, nTotal )
RETURN NIL

/* Index summary after applying (what the user is shown).
 * {} if the database had no tag at all. */
STATIC FUNCTION BpStructTagSummary()
   LOCAL aRes := StructTagResult(), aLin := {}, i, cR := "", cD := ""
   IF Empty( aRes )
      RETURN aLin
   ENDIF
   FOR i := 1 TO Len( aRes )
      IF aRes[ i ][ 2 ] == "REBUILT"
         cR += iif( Empty( cR ), "", ", " ) + aRes[ i ][ 1 ]
      ELSE
         cD += iif( Empty( cD ), "", ", " ) + aRes[ i ][ 1 ]
      ENDIF
   NEXT
   AAdd( aLin, "Index tags rebuilt: " + iif( Empty( cR ), "none", cR ) )
   IF ! Empty( cD )
      AAdd( aLin, "Index tags dropped: " + cD )
      AAdd( aLin, "" )
      FOR i := 1 TO Len( aRes )
         IF aRes[ i ][ 2 ] != "REBUILT"
            AAdd( aLin, "Tag " + PadR( aRes[ i ][ 1 ], 12 ) + aRes[ i ][ 3 ] )
         ENDIF
      NEXT
   ENDIF
RETURN aLin

/* =====================================================================
 *  Alt-E / Alt-M: the box that asks the FILE NAME and shows the DIRECTORY
 * ---------------------------------------------------------------------
 *  It used to be a bare UiInput( "New database name (*.DBF):", "NEWFILE.DBF" )
 *  -and, when the structure editor was opened with no database,
 *  BpStructNewName() asked the same thing-, so the user could not see WHERE the
 *  file was going to appear. This box shows the directory in a `Path:` row and
 *  the whole target file in the row under the name, and BOTH follow what is
 *  being typed: `..\OTHER\X.DBF` shows the directory it really resolves to,
 *  because UiNewFileDir() (bp_ui.prg, pure and pinned by the S136 block of the
 *  bank) resolves `.` and `..` textually.
 *
 *  Form family of the project (skill pantallas-de-formulario): the geometry is
 *  derived from the canvas, every control is REGISTERED as it is painted -so a
 *  click produces the same key as the keyboard-, the focus is a single yellow
 *  band, Alt+F / Alt+A / Alt+C work from anywhere, Ctrl-S accepts, and Esc, the
 *  plain right click and the X of the window cancel. A name that already exists
 *  is reported IN the box, in red, so the user types another one instead of
 *  being thrown out of the structure editor with the structure still unsaved.
 * ===================================================================== */

/* focus stops, in VISUAL order */
#define NF_FOC_FILE    1
#define NF_FOC_OK      2    /* [ ~A~ccept ] */
#define NF_FOC_CANCEL  3    /* [ ~C~ancel ] */

/* the state of the box */
#define NFX_FILE       1
#define NFX_FOCUS      2
#define NFX_MSG        3
#define NFX_ERR        4
#define NFX_MAX        4

/* rows of the box, RELATIVE to its top: one blank row between two controls, so
 * nothing can push the row below it */
#define NF_R_TITLE     1
#define NF_R_PATH      3
#define NF_R_FILE      5
#define NF_R_MSG       7
#define NF_R_BTN       9
#define NF_R_HINT     10
#define NF_H          12

/* geometry slots, all computed by BpNfGeom() from UiCols()/UiRows() */
#define NFG_W          1
#define NFG_L          2
#define NFG_T          3
#define NFG_B          4
#define NFG_R          5
#define NFG_LBL        6
#define NFG_VAL        7
#define NFG_VALW       8
#define NFG_BASE       9
#define NFG_MAX        9

/* ---------- geometry ---------- */

/* the directory a RELATIVE name lands in: the SESSION directory, which is what
 * the F2 file selection reads (BpDir()) and the one `Change Directory` moves, and
 * it is the one the whole path handed to dbCreate() is built from -so what the
 * box shows is where the file really goes, whatever the process working
 * directory is. CurDir() is the last resort: it answers the directory WITHOUT
 * the drive (measured: the row was showing `Users\Admin\...` with no `C:`). */
STATIC FUNCTION BpNewFileBase()
   LOCAL c := CoreDir()
   IF Len( c ) == 0
      RETURN CurDir()
   ENDIF
RETURN c

STATIC FUNCTION BpNfGeom( cBase )
   LOCAL nW := Min( 96, UiCols() - 8 )
   LOCAL nL := UiCenterCol( nW )
   LOCAL nT := UiCenterRow( NF_H )
   LOCAL aG := Array( NFG_MAX )
   aG[ NFG_W ]    := nW
   aG[ NFG_L ]    := nL
   aG[ NFG_T ]    := nT
   aG[ NFG_B ]    := nT + NF_H - 1
   aG[ NFG_R ]    := nL + nW - 1
   aG[ NFG_LBL ]  := nL + 2
   aG[ NFG_VAL ]  := nL + 2 + 6        /* "Path:" / "File:" plus a blank */
   aG[ NFG_VALW ] := nW - 2 - 6 - 2
   aG[ NFG_BASE ] := cBase
RETURN aG

STATIC FUNCTION BpNfStateNew( cSeed )
   LOCAL aSt := Array( NFX_MAX )
   aSt[ NFX_FILE ]  := cSeed
   aSt[ NFX_FOCUS ] := NF_FOC_FILE
   aSt[ NFX_MSG ]   := ""
   aSt[ NFX_ERR ]   := .F.
RETURN aSt

/* the next / previous stop of the ring, and the answer the key loop expects */
STATIC FUNCTION BpNfFocus( aSt, nDir )
   LOCAL n := aSt[ NFX_FOCUS ]
   DO CASE
   CASE nDir > 0 ; n := iif( n >= NF_FOC_CANCEL, NF_FOC_FILE, n + 1 )
   CASE nDir < 0 ; n := iif( n <= NF_FOC_FILE, NF_FOC_CANCEL, n - 1 )
   ENDCASE
   aSt[ NFX_FOCUS ] := n
RETURN "focus"

/* the directory, the name and the WHOLE target the state stands for. The .DBF
 * extension comes from UiNewFileName() (bp_ui.prg, pure and pinned by S136): it
 * is decided by the NAME, not by the whole path, so `my.dir\x` still needs it. */
STATIC FUNCTION BpNfTarget( aSt, cBase )
   LOCAL cName := UiNewFileName( aSt[ NFX_FILE ] )
   LOCAL cDir  := UiNewFileDir( aSt[ NFX_FILE ], cBase )
RETURN { cDir, cName, cDir + cName }

/* a path that does not fit keeps its TAIL: what matters is the file name and
 * the last folder, never the `C:\` at the beginning */
STATIC FUNCTION BpPathTail( cPath, nW )
   LOCAL c := iif( HB_ISSTRING( cPath ), cPath, "" )
   IF nW < 8 .OR. Len( c ) <= nW
      RETURN Left( c, nW )
   ENDIF
RETURN "..." + Right( c, nW - 3 )

/* ---------- the painters (each one REGISTERS its control) ---------- */

/* the ONLY control with a background of its own: the field that is edited */
STATIC PROCEDURE BpNfPaintFld( nRow, nCol, nW, cText, lFoc, nStop )
   SetColor( iif( lFoc, UI_C_LISTSEL, UI_C_FIELDBG ) )
   @ nRow, nCol SAY PadR( Left( iif( ValType( cText ) == "C", cText, "" ), nW ), nW )
   HcSyncCtlAdd( nRow, nCol, nW, "NFFLD", nStop )
RETURN

/* one button: FLAT at rest and brown with the focus, quick letter included */
STATIC PROCEDURE BpNfPaintBtn( nRow, nCol, cLabel, lFoc, nStop )
   LOCAL cPair := iif( lFoc, UI_C_BOXSEL, UI_C_FLATBG )
   LOCAL nW := UiHotLen( cLabel )
   SetColor( cPair )
   @ nRow, nCol SAY Space( nW )
   UiDrawHot( nRow, nCol, cLabel, cPair, iif( lFoc, UI_C_HOTSEL, UI_C_HOT ) )
   HcSyncCtlAdd( nRow, nCol, nW, "NFBTN", nStop )
RETURN

/* the whole box in ONE paint block, and the place where the mouse controls are
 * registered (HcSyncCtlReset() first and one entry per control) */
STATIC PROCEDURE BpNfDraw( aG, aSt, cTitle )
   LOCAL nT := aG[ NFG_T ], nL := aG[ NFG_L ], nB := aG[ NFG_B ], nR := aG[ NFG_R ]
   LOCAL nLbl := aG[ NFG_LBL ], nVal := aG[ NFG_VAL ], nW := aG[ NFG_VALW ]
   LOCAL aTg := BpNfTarget( aSt, aG[ NFG_BASE ] )
   LOCAL cCap := " " + cTitle + " "
   LOCAL nIn := aG[ NFG_W ] - 4
   LOCAL nBx
   HcSyncCtlReset()
   UiPaintBegin()
   UiShadow( nT, nL, nB, nR )
   UiFillBox( nT, nL, nB, nR, UI_C_BOX )
   UiFrame( nT, nL, nB, nR, UI_C_BOXBORD, .T. )
   /* title: the flat chip of the forms of this project, centred on the box */
   SetColor( UI_C_FLATBG )
   @ nT + NF_R_TITLE, nL + Max( 1, Int( ( aG[ NFG_W ] - Len( cCap ) ) / 2 ) ) SAY cCap
   /* the directory where the file IS GOING TO BE CREATED (read only) */
   UiDrawHot( nT + NF_R_PATH, nLbl, "Path:", UI_C_BOX, UI_C_HOT )
   SetColor( UI_C_DIM )
   @ nT + NF_R_PATH, nVal SAY PadR( BpPathTail( iif( Len( aTg[ 1 ] ) == 0, "?", aTg[ 1 ] ), nW ), nW )
   /* the name of the file */
   UiDrawHot( nT + NF_R_FILE, nLbl, "~F~ile:", UI_C_BOX, UI_C_HOT )
   BpNfPaintFld( nT + NF_R_FILE, nVal, nW, aSt[ NFX_FILE ], ;
                 aSt[ NFX_FOCUS ] == NF_FOC_FILE, NF_FOC_FILE )
   /* the whole target -or the reason it cannot be created- in ONE row */
   IF aSt[ NFX_ERR ]
      SetColor( UI_C_ERR )
      @ nT + NF_R_MSG, nLbl SAY PadR( BpPathTail( aSt[ NFX_MSG ], nIn ), nIn )
   ELSE
      SetColor( UI_C_BOXDIM )
      @ nT + NF_R_MSG, nLbl SAY PadR( BpPathTail( "-> " + aTg[ 3 ], nIn ), nIn )
   ENDIF
   /* the two buttons */
   nBx := nL + 2
   BpNfPaintBtn( nT + NF_R_BTN, nBx, "[ ~A~ccept ]", ;
                 aSt[ NFX_FOCUS ] == NF_FOC_OK, NF_FOC_OK )
   nBx += UiHotLen( "[ ~A~ccept ]" ) + 3
   BpNfPaintBtn( nT + NF_R_BTN, nBx, "[ ~C~ancel ]", ;
                 aSt[ NFX_FOCUS ] == NF_FOC_CANCEL, NF_FOC_CANCEL )
   /* the keys of the box */
   SetColor( UI_C_BOXDIM )
   @ nT + NF_R_HINT, nL + 2 SAY PadR( "Tab: Move  Enter: Create  Ctrl-S: Create  Esc: Cancel", nIn )
   UiPaintEnd()
RETURN

/* ---------- the rule of the keys of the box ---------- */

STATIC FUNCTION BpNfKeyAct( nKey, nShift, cAlt, aSt )
   LOCAL lCtrl := hb_bitAnd( nShift, HB_GTI_KBD_CTRL ) != 0
   LOCAL lAlt  := hb_bitAnd( nShift, HB_GTI_KBD_ALT ) != 0
   DO CASE
   CASE Len( cAlt ) > 0
      DO CASE
      CASE cAlt == "F" ; aSt[ NFX_FOCUS ] := NF_FOC_FILE ; RETURN "focus"
      CASE cAlt == "A" ; RETURN "run"
      CASE cAlt == "C" .OR. cAlt == "X" ; RETURN "cancel"
      ENDCASE
      /* a chord nobody serves is DROPPED: it must not type anything later */
      RETURN "none"
   CASE lAlt .AND. ! lCtrl
      /* second channel of the same chords: this driver hands `Alt+<letter>`
       * over as the BARE letter plus the ALT bit of HB_GTI_KBDSHIFTS (trap 37),
       * and the ring of the hook is not always armed (trap 89). ALT together
       * with CTRL is AltGr, which types a character and is not a chord (trap 38) */
      DO CASE
      CASE nKey == Asc( "f" ) .OR. nKey == Asc( "F" )
         aSt[ NFX_FOCUS ] := NF_FOC_FILE ; RETURN "focus"
      CASE nKey == Asc( "a" ) .OR. nKey == Asc( "A" ) ; RETURN "run"
      CASE nKey == Asc( "c" ) .OR. nKey == Asc( "C" ) .OR. ;
           nKey == Asc( "x" ) .OR. nKey == Asc( "X" ) ; RETURN "cancel"
      ENDCASE
      RETURN "none"
   CASE nKey == K_ESC ; RETURN "cancel"
   /* Ctrl-S: this driver hands it over as the code of K_LEFT (19) WITH the CTRL
    * bit (trap 71), so the code alone is not the rule and ALT disqualifies it
    * (AltGr is Ctrl+Alt, trap 38) */
   CASE lCtrl .AND. ! lAlt .AND. ( nKey == K_CTRL_S .OR. nKey == Asc( "s" ) .OR. ;
                                   nKey == Asc( "S" ) )
      RETURN "run"
   CASE nKey == K_ENTER
      IF aSt[ NFX_FOCUS ] == NF_FOC_CANCEL
         RETURN "cancel"
      ENDIF
      RETURN "run"
   CASE nKey == K_SPACE .OR. nKey == K_INS
      IF aSt[ NFX_FOCUS ] == NF_FOC_CANCEL
         RETURN "cancel"
      ENDIF
      IF aSt[ NFX_FOCUS ] == NF_FOC_OK
         RETURN "run"
      ENDIF
      RETURN "edit"
   CASE nKey == K_TAB .OR. nKey == K_DOWN .OR. nKey == K_RIGHT
      RETURN BpNfFocus( aSt, 1 )
   CASE nKey == K_SH_TAB .OR. nKey == K_UP .OR. nKey == K_LEFT
      RETURN BpNfFocus( aSt, -1 )
   ENDCASE
RETURN ""

/* open the field. `lSeed` says the value was seeded by the character the user
 * just typed: then the caret has to continue AFTER it. `lSelAll` is for the
 * field opened with the seed of the box, so the first keystroke REPLACES it
 * (rule 11 of the forms of this project); selecting a typed seed would throw
 * that first keystroke away -measured: typing `ZQX.DBF` created `QX.DBF`-. */
STATIC PROCEDURE BpNfEdit( aG, aSt, lSeed )
   LOCAL cNew := UiLineEdit( aG[ NFG_T ] + NF_R_FILE, aG[ NFG_VAL ], aG[ NFG_VALW ], ;
                             aSt[ NFX_FILE ], .F., UI_C_LISTSEL, .F., .T., "", "", ;
                             ! lSeed )
   IF ! hb_IsNIL( cNew )
      aSt[ NFX_FILE ] := AllTrim( cNew )
      aSt[ NFX_MSG ]  := ""
      aSt[ NFX_ERR ]  := .F.
      aSt[ NFX_FOCUS ] := NF_FOC_OK
   ENDIF
RETURN

/* the full path that [ Accept ] hands to the caller, or "" after leaving the
 * reason in the message row: an empty name, a name that is only dots, and a file
 * that is already there (the last one so the user can type another name WITHOUT
 * losing the structure he was editing) */
STATIC FUNCTION BpNfResolve( aG, aSt )
   LOCAL aTg := BpNfTarget( aSt, aG[ NFG_BASE ] )
   IF Len( aTg[ 2 ] ) == 0
      aSt[ NFX_MSG ] := "Type the name of the file to create:"
      aSt[ NFX_ERR ] := .T.
      RETURN ""
   ENDIF
   IF aTg[ 2 ] == "." .OR. aTg[ 2 ] == ".."
      aSt[ NFX_MSG ] := "That is not a file name: " + aSt[ NFX_FILE ]
      aSt[ NFX_ERR ] := .T.
      RETURN ""
   ENDIF
   IF hb_FNameExists( aTg[ 3 ] )
      aSt[ NFX_MSG ] := "File already exists: " + aTg[ 3 ]
      aSt[ NFX_ERR ] := .T.
      RETURN ""
   ENDIF
   aSt[ NFX_MSG ] := ""
   aSt[ NFX_ERR ] := .F.
RETURN aTg[ 3 ]

/* ---------- the box ---------- */

STATIC FUNCTION BpNewFileBox( cTitle, cSeed )
   LOCAL aG, aSt, lPaint := .T., lDone := .F., cAct := "", cRes := ""
   LOCAL lSeeded := .F.
   LOCAL nKey, nShift, cAlt, aPt, aCtl, cSave, cOldCur
   aG  := BpNfGeom( BpNewFileBase() )
   aSt := BpNfStateNew( cSeed )
   cOldCur := SetCursor( 0 )
   cSave := SaveScreen( aG[ NFG_T ], aG[ NFG_L ], Min( MaxRow(), aG[ NFG_B ] + 1 ), ;
                        Min( MaxCol(), aG[ NFG_R ] + 2 ) )
   DO WHILE ! lDone
      IF lPaint
         BpNfDraw( aG, aSt, cTitle )
         lPaint := .F.
      ENDIF
      cAct := ""
      /* 50 ms slices so the click and the chord of the window hook are seen (the
       * mouse of this driver never arrives through Inkey()) */
      nKey   := Inkey( 0.05 )
      nShift := hb_gtInfo( HB_GTI_KBDSHIFTS )
      cAlt   := HcAltChord()
      /* a chord a FIELD EDITOR left pending: UiLineEdit() asks the Alt hook,
       * keeps the letter pending and closes, so the caller takes it here */
      IF Len( cAlt ) == 0
         cAlt := UiAltChord()
      ENDIF
      IF UiCloseAsk()
         cAct := "cancel"
      ENDIF
      /* right-click-esc: a plain right click cancels the box, as Esc does */
      IF Empty( cAct ) .AND. HcMouseRightClick()
         cAct := "cancel"
      ENDIF
      IF Empty( cAct )
         IF nKey == 0 .AND. Len( cAlt ) == 0
            aPt := UiClick()
            IF HB_ISARRAY( aPt )
               aCtl := HcSyncCtlAt( aPt[ 1 ], aPt[ 2 ] )
               IF ! hb_IsNIL( aCtl )
                  IF aCtl[ 4 ] == "NFBTN"
                     /* a click on a button ACTS, exactly like its key */
                     aSt[ NFX_FOCUS ] := aCtl[ 5 ]
                     cAct := iif( aCtl[ 5 ] == NF_FOC_OK, "run", "cancel" )
                  ELSEIF aCtl[ 5 ] == aSt[ NFX_FOCUS ]
                     /* a second click on the control that already has the
                      * focus OPENS it, exactly like Enter */
                     cAct := "edit"
                  ELSE
                     aSt[ NFX_FOCUS ] := aCtl[ 5 ]
                     lPaint := .T.
                  ENDIF
               ENDIF
            ENDIF
         ELSE
            cAct := BpNfKeyAct( nKey, nShift, cAlt, aSt )
            /* a typed character ENTERS the name field and starts a NEW value
             * there, from any stop of the ring */
            IF Empty( cAct ) .AND. nKey >= 32 .AND. nKey <= 255
               aSt[ NFX_FOCUS ] := NF_FOC_FILE
               aSt[ NFX_FILE ]  := Chr( nKey )
               aSt[ NFX_MSG ]   := ""
               aSt[ NFX_ERR ]   := .F.
               lSeeded := .T.
               cAct := "edit"
            ENDIF
         ENDIF
      ENDIF
      IF Empty( cAct )
         LOOP
      ENDIF
      DO CASE
      CASE cAct == "cancel"
         lDone := .T.
      CASE cAct == "focus"
         lPaint := .T.
      CASE cAct == "edit"
         BpNfEdit( aG, aSt, lSeeded )
         lSeeded := .F.
         lPaint := .T.
      CASE cAct == "run"
         cRes := BpNfResolve( aG, aSt )
         IF Len( cRes ) > 0
            lDone := .T.
         ENDIF
         lPaint := .T.
      ENDCASE
   ENDDO
   RestScreen( aG[ NFG_T ], aG[ NFG_L ], Min( MaxRow(), aG[ NFG_B ] + 1 ), ;
               Min( MaxCol(), aG[ NFG_R ] + 2 ), cSave )
   SetCursor( cOldCur )
   SetColor( UI_C_DESKTOP )
RETURN cRes

/* Alt-E: "Create Empty Structure Database" */
STATIC FUNCTION BpStructCreate( cFile, aSt )
   LOCAL oErr, cName, cMsg := "", lOk := .F.
   DEFAULT cFile TO ""
   IF ! BpStructCheck( aSt )
      RETURN .F.
   ENDIF
   /* Alt-E ALWAYS asks, with or without a database behind: the name of the file
    * and the directory it is going to be created in (the whole target is shown
    * under the name as it is typed) */
   cName := BpNewFileBox( "Create Empty Structure Database", "NEWFILE.DBF" )
   IF Len( cName ) == 0
      RETURN .F.
   ENDIF
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      /* NOTE: dbCreate() does NOT open the file it creates, so there is nothing
       * to close here. There used to be a "CLOSE" that closed the CURRENT AREA,
       * that is the database the user had open (see AGENTS.md 5). */
      IF ! dbCreate( cName, aSt, .T. )
         cMsg := "Unable to create " + cName
         BREAK
      ENDIF
      lOk := .T.
   RECOVER USING oErr
      cMsg := oErr:Description
   END SEQUENCE
   IF lOk
      UiInfo( "File Created" + hb_eol() + Upper( cName ), "Structure" )
   ELSE
      UiErr( "Unable to Create File" + hb_eol() + cMsg )
   ENDIF
RETURN lOk

/* Alt-P: "Send Structure List to" (Printer / File / Cancel) */
STATIC FUNCTION BpStructPrint( aSt, cFile )
   LOCAL n, cOut := "", cLine, i, nH, cName
   IF Empty( aSt )
      UiErr( "No Database Fields specified" )
      RETURN .F.
   ENDIF
   n := UiPick( { "Printer", "File", "Cancel" }, "Send Structure List to" )
   IF n == 0 .OR. n == 3
      RETURN .F.
   ENDIF
   IF n == 2
      cName := UiInput( "Write Output File to (File Name):", Lower( iif( Empty( cFile ), "STRUCT", cFile ) ) + ".TXT", 30 )
      IF cName == NIL .OR. Empty( cName )
         RETURN .F.
      ENDIF
      cOut := cName
   ENDIF
   cLine := "Structure of " + iif( Empty( cFile ), "<new database>", Upper( cFile ) + ".DBF" ) + hb_eol() + ;
            ST_HDR + hb_eol() + ST_SEP + hb_eol()
   FOR i := 1 TO Len( aSt )
      cLine += PadL( LTrim( Str( i ) ), 4 ) + "   " + ;
                PadR( aSt[ i ][ 1 ], 10 ) + "   " + ;
                BpStructTypeName( aSt[ i ][ 2 ] ) + "   " + ;
                PadL( LTrim( Str( aSt[ i ][ 3 ] ) ), 5 ) + "   " + ;
                PadL( LTrim( Str( aSt[ i ][ 4 ] ) ), 5 ) + hb_eol()
   NEXT
   cLine += "        Total Length:" + PadL( LTrim( Str( BpStructTotal( aSt ) ) ), 7 ) + hb_eol()
   IF Empty( cOut )
      /* to the printer: in a Windows application there is no DOS printer;
       * it goes to hwbro.err/console unless the user uses "File" */
      UiInfo( "Send to Printer is not available in this reconstruction." + hb_eol() + ;
              "Use the 'File' option to write the structure to a text file.", "Structure" )
      RETURN .F.
   ENDIF
   nH := FCreate( cOut )
   IF nH == -1
      UiErr( "Unable to Create File:" + hb_eol() + cOut )
      RETURN .F.
   ENDIF
   FWrite( nH, cLine )
   FClose( nH )
   UiInfo( "Printing Completed" + hb_eol() + Upper( cOut ), "Structure" )
RETURN .T.

/* =====================================================================
 *  F3 - Index
 * ===================================================================== */

/* =====================================================================
 *  F3 - Index -> "Index File Selection Screen" (Alt-F3)
 * ---------------------------------------------------------------------
 *  MEASURED on BRO.EXE (_reversing/capturas/o6-idxsel-06-op1.png,
 *  o7-idxhot-06-op2.png and o8-idxpick-06-op1..04.png): it is the SAME screen as
 *  the Database Selection Screen of F2 (boxes rows 5..21 in columns
 *  11..26 and 51..67, black shadow of 2 columns, "Selected" in row 4, row
 *  23 with "Key: (...)" and "Driver: DBFCDX" and row 24 with the helps), with
 *  these MEASURED differences:
 *    - row 3: the ALIAS of the area is CENTERED and in BROWN (170,85,0);
 *    - left panel: the index files of the directory matching the
 *      "Index FileSpec" (cyan chip of row 4, *.CDX by default);
 *    - right panel: the index files OPEN in the area, with frame and
 *      text in BRIGHT CYAN (85,255,255) (in the database screen the frame
 *      is yellow);
 *    - the highlighted item of the left panel is BLACK on BRIGHT CYAN
 *      (in the database screen it is black on yellow).
 *  Keys measured (Alt-H list of the original, capture o7-idxhot):
 *  Enter=Pick  Esc=Browse  Del=Close index  Ins=Add  Tab/Shift-Tab=next order
 *  /previous  Alt-A=Open All  Alt-K=Close All  Alt-F=FileSpec
 *  Alt-M=Create index  Alt-X=mode  Alt-Y=directory
 *  Alt-Z=shell  Alt-N/Alt-Minus=rotate area  Ctrl-F3=Tag info
 *  Ctrl-Enter=Verify.
 * ===================================================================== */

/* mask of the index picker: the "Index FileSpec" of the F3 menu; if it is
 * empty it falls back to "*.CDX" so a blank value does not leave the list empty */
STATIC FUNCTION BpIdxSpec()
   LOCAL c := AllTrim( CoreIdxSpec() )
RETURN iif( Empty( c ), "*.CDX", c )

/* index files of the current directory matching the FileSpec. NOTE:
 * hb_DirScan() ALSO returns the files of the subdirectories
 * ("backup\ARTICULO.CDX"); the original lists only the current directory, so
 * the ones carrying a path are discarded */
STATIC FUNCTION BpIdxFiles()
   LOCAL a := BpDirNames( BpIdxSpec() ), aOut := {}, i, c
   FOR i := 1 TO Len( a )
      c := a[ i ]
      /* NOTE: Harbour does NOT process the C escape, so a backslash
       * inside a string is written ALONE (two slashes would be TWO
       * characters and the $ would never match) */
      IF ! ( "\" $ c ) .AND. ! ( "/" $ c )
         AAdd( aOut, c )
      ENDIF
   NEXT
   ASort( aOut )
RETURN aOut

/* index files OPEN in the active area, WITHOUT repeats: a .CDX is a
 * single file even when it has several tags */
STATIC FUNCTION BpIdxOpenFiles()
   LOCAL a := {}, n := BpTagTotal(), i, c
   FOR i := 1 TO n
      c := BpTagBagFile( i )
      IF ! Empty( c )
         IF AScan( a, {| x | Upper( x ) == Upper( c ) } ) == 0
            AAdd( a, c )
         ENDIF
      ENDIF
   NEXT
RETURN a

/* text of the "Current Index:" line of the F3 header: "(n/total) FILE" of the
 * index FILES open in the area, with the extension the engine really uses
 * (.CDX / .NTX). With no controlling order it is EMPTY: the header used to
 * hardcode "(1/1) <ALIAS>.CDX" and claimed a .CDX even for a database that had
 * NO index at all in its folder (reported by the user). PUBLIC because the
 * header lives in hwbro.prg. */
FUNCTION BpIdxHeaderText()
   LOCAL aOpen := BpIdxOpenFiles(), cCur := "", i, nAt := 0
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      IF Used() .AND. ! Empty( OrdName() )
         cCur := BpTagBagFile( BpTagCur() )
      ENDIF
   RECOVER
      cCur := ""
   END SEQUENCE
   IF Empty( cCur )
      RETURN ""
   ENDIF
   FOR i := 1 TO Len( aOpen )
      IF Upper( aOpen[ i ] ) == Upper( cCur )
         nAt := i
      ENDIF
   NEXT
RETURN "(" + LTrim( Str( Max( 1, nAt ) ) ) + "/" + ;
       LTrim( Str( Max( 1, Len( aOpen ) ) ) ) + ") " + Upper( cCur )
/* full drawing of the screen (all at once, without flicker) */
STATIC PROCEDURE BpIdxSelDraw( aFiles, nSel, nTop, nVis )
   LOCAL cAlias := "", cMode, nCol
   IF Used()
      cAlias := Upper( Alias() )
   ENDIF
   UiPaintBegin()
   UiCls()
   BpMenuBar( 0 )
   /* row 3: directory in cyan chip, alias centered in brown and open
    * mode in cyan chip on the right (measured) */
   SetColor( UI_C_CHIP )
   @ 3, 0 SAY " " + Upper( CoreDir() ) + " "
   SetColor( UI_C_DESKTOP )
   IF ! Empty( cAlias )
      nCol := Int( ( MaxCol() + 1 - Len( cAlias ) ) / 2 )
      UiWrite( 3, Max( 0, nCol ), cAlias, UI_C_IDXALIAS )
   ENDIF
   IF Used()
      cMode := "<" + CoreModeName() + ">"
      SetColor( UI_C_CHIP )
      @ 3, Max( 0, MaxCol() - Len( cMode ) - 4 ) SAY cMode
      SetColor( UI_C_DESKTOP )
   ENDIF
   /* row 4: index FileSpec (cyan chip) and "Selected" of the right panel */
   SetColor( UI_C_CHIP )
   @ 4, SEL_LL + 5 SAY Upper( BpIdxSpec() )
   SetColor( UI_C_DESKTOP )
   @ 4, SEL_RL + 4 SAY "Selected"
   /* boxes: left with a WHITE frame and right with a BRIGHT CYAN
    * frame (measured), dark gray inside and black shadow */
   BpSelBox( SEL_T, SEL_LL, SEL_B, SEL_LR, UI_C_FRAME1 )
   BpSelBox( SEL_T, SEL_RL, SEL_B, SEL_RR, UI_C_IDXFRM )
   BpIdxSelLeft( aFiles, nSel, nTop, nVis )
   BpIdxSelRight()
   BpSelStatus()
   BpSelHelp()
   SetColor( UI_C_DESKTOP )
   UiPaintEnd()
RETURN NIL

/* left panel: index files of the directory. Unlike the database
 * screen, the highlight is CYAN from the very first moment (measured in
 * the entry capture: there is no "gray" cursor like in the database one). */
STATIC PROCEDURE BpIdxSelLeft( aFiles, nSel, nTop, nVis )
   LOCAL i, nRow, nW := SEL_LR - SEL_LL - 3
   SetColor( UI_C_DARK )
   IF Empty( aFiles )
      @ SEL_T + 1, SEL_LL + 2 SAY PadR( "(no " + Upper( BpIdxSpec() ) + " files)", nW )
   ELSE
      FOR i := nTop TO Min( Len( aFiles ), nTop + nVis - 1 )
         nRow := SEL_T + 1 + ( i - nTop )
         IF i == nSel
            SetColor( UI_C_IDXSEL )
         ELSE
            SetColor( UI_C_DARK )
         ENDIF
         @ nRow, SEL_LL + 2 SAY PadR( aFiles[ i ], nW )
      NEXT
   ENDIF
   SetColor( UI_C_DESKTOP )
RETURN NIL

/* right panel: open index files, in bright cyan. The MEASURED original
 * (a single open bag, which is the active one) does NOT draw any arrow
 * in front of the name, so none is drawn. */
STATIC PROCEDURE BpIdxSelRight()
   LOCAL i, nRow, aOpen := BpIdxOpenFiles(), nW := SEL_RR - SEL_RL - 3
   FOR i := 1 TO Min( Len( aOpen ), SEL_ROWS )
      nRow := SEL_T + i
      SetColor( UI_C_IDXITEM )
      @ nRow, SEL_RL + 2 SAY PadR( aOpen[ i ], nW )
   NEXT
   SetColor( UI_C_DESKTOP )
RETURN NIL

/* shortcut list of the original (MEASURED: capture o7-idxhot-06-op2.png: on the
 * 80x25 grid it was a window on rows 0..22 / columns 18..75, with the yellow
 * title on its first row, the keys in yellow three columns in and the actions in
 * white further right). The BACKGROUND of the original is MAGENTA, which does
 * not exist in the port palette (index 5 is remapped to yellow for the lists):
 * the cyan of the boxes is used. The geometry is NOT measured anymore: the box is
 * sized from its content and centred on the canvas. */
STATIC PROCEDURE BpIdxHotKeys()
   LOCAL nT, nL, nB, nR, i, cSave, nRow, nKeyW := 0, nActW := 0, nH, nW
   LOCAL nKeyC, nActC
   LOCAL aList := { ;
      { "Del",        "Close index" }, ;
      { "Ins",        "Add new index to picklist" }, ;
      { "Tab",        "Advance index order by 1" }, ;
      { "Shift-Tab",  "Set index order back by 1" }, ;
      { "Ctrl-F3",    "Tag Selection/Information" }, ;
      { "Alt-F2",     "Proceed to Database Selection" }, ;
      { "Alt-F4",     "Proceed to Field Selection" }, ;
      { "Alt-N",      "Rotate to Index Selection for Next area" }, ;
      { "Alt-Minus",  "Rotate to Index Selection for Prev.area" }, ;
      { "Alt-F",      "Change index FileSpec" }, ;
      { "Alt-A",      "Open All index files in selection list" }, ;
      { "Alt-K",      "Close All open index files in this area" }, ;
      { "Alt-M",      "Create index file" }, ;
      { "Alt-X",      "Exit hwBro" }, ;
      { "Alt-Y",      "Change directory" }, ;
      { "Alt-Z",      "Shell to DOS" }, ;
      { "Character",  "Autoseek" }, ;
      { "Ctrl-BkSpc", "Clear Autoseek string" }, ;
      { "Ctrl-Enter", "Verify index file integrity" } }
   /* the box is SIZED FROM ITS CONTENT and centred on the canvas; it is not the
    * measured 0..22 / 18..75 window of the 80x25 original anymore. The key and
    * action columns are derived from the widest entry of each column. */
   FOR i := 1 TO Len( aList )
      nKeyW := Max( nKeyW, Len( aList[ i ][ 1 ] ) )
      nActW := Max( nActW, Len( aList[ i ][ 2 ] ) )
   NEXT
   nKeyC := 3                       /* key text column, relative to nL        */
   nActC := nKeyC + nKeyW + 4       /* action column, relative to nL          */
   nH    := Len( aList ) + 3        /* title + blank + items + bottom blank   */
   nW    := Max( Len( "Index Selection Hot-Key List" ) + 4, nActC + nActW + 2 )
   nT    := UiCenterRow( nH )
   nB    := nT + nH - 1
   nL    := UiCenterCol( nW )
   nR    := nL + nW - 1
   /* the saved rectangle follows the box; it is clamped to the canvas so a
    * grown box is never clipped (nor reads outside the grid) */
   cSave := SaveScreen( nT, nL, Min( MaxRow(), nB + 1 ), Min( MaxCol(), nR + 2 ) )
   UiPaintBegin()
   UiShadow( nT, nL, nB, nR )
   UiFillBox( nT, nL, nB, nR, UI_C_BOX )
   /* the original draws NO frame: it is a flat window with magenta background */
   UiWrite( nT, nL + Int( ( nW - Len( "Index Selection Hot-Key List" ) ) / 2 ), ;
            "Index Selection Hot-Key List", UI_C_PROGTIT )
   FOR i := 1 TO Len( aList )
      nRow := nT + 1 + i
      UiWrite( nRow, nL + nKeyC - 1, "<", UI_C_SPLFRM )
      UiWrite( nRow, nL + nKeyC, aList[ i ][ 1 ], UI_C_HOT )
      UiWrite( nRow, nL + nKeyC + Len( aList[ i ][ 1 ] ), ">", UI_C_SPLFRM )
      UiWrite( nRow, nL + nActC, aList[ i ][ 2 ], UI_C_SPLFRM )
   NEXT
   UiPaintEnd()
   /* any key closes the box; the X of the window (BpWaitKey) leaves through the
    * same RestScreen() below, so its answer is not looked at (window-close.md
    * B4 S1/S4) */
   BpWaitKey()
   RestScreen( nT, nL, Min( MaxRow(), nB + 1 ), Min( MaxCol(), nR + 2 ), cSave )
   SetColor( UI_C_DESKTOP )
RETURN NIL

/* adds the index file to the current area (or activates its first order if it
 * was already open). Returns .T. if it could be opened/activated. */
STATIC FUNCTION BpIdxAdd( cFile )
   LOCAL cBag := Upper( hb_FNameName( cFile ) ), oErr, lOk := .F.
   LOCAL n, nFound := 0, aOpen
   IF Empty( cBag )
      RETURN .F.
   ENDIF
   aOpen := BpIdxOpenFiles()
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      IF AScan( aOpen, {| x | Upper( hb_FNameName( x ) ) == cBag } ) > 0
         /* already open: it is only ACTIVATED (its first order). No EXIT inside
          * a BEGIN SEQUENCE: nFound is used. */
         FOR n := 1 TO BpTagTotal()
            IF nFound == 0 .AND. Upper( hb_FNameName( BpTagBagFile( n ) ) ) == cBag
               nFound := n
            ENDIF
         NEXT
         IF nFound > 0
            OrdSetFocus( nFound )
         ENDIF
      ELSE
         ORDLISTADD( cBag )
      ENDIF
      lOk := .T.
   RECOVER USING oErr
      lOk := .F.
      UiErr( "Unable to open specified index" + hb_eol() + oErr:Description, "Index Selection" )
   END SEQUENCE
   IF lOk
      BEGIN SEQUENCE WITH {| e | Break( e ) }
         dbGoTop()
      RECOVER
      END SEQUENCE
      CoreStatus()
   ENDIF
RETURN lOk

/* <Del>=Close index: closes the index file of the ACTIVE order (the ones of the
 * other bags are added back). With DBFCDX the bag is glued to the .DBF,
 * so "closing the index" is leaving the area without that order file. */
STATIC PROCEDURE BpIdxCloseIndex()
   LOCAL cBag := "", n, aKeep := {}, cName, oErr
   IF Empty( CoreKeyExpr() )
      RETURN
   ENDIF
   cBag := Upper( hb_FNameName( BpTagBagFile( BpTagCur() ) ) )
   FOR n := 1 TO BpTagTotal()
      cName := Upper( hb_FNameName( BpTagBagFile( n ) ) )
      IF ! ( cName == cBag ) .AND. ! Empty( cName )
         IF AScan( aKeep, {| x | x == cName } ) == 0
            AAdd( aKeep, cName )
         ENDIF
      ENDIF
   NEXT
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      OrdListClear()
      FOR n := 1 TO Len( aKeep )
         ORDLISTADD( aKeep[ n ] )
      NEXT
      dbGoTop()
      CoreStatus()
   RECOVER USING oErr
      UiErr( "Unable to close " + cBag + ": " + oErr:Description, "Index Selection" )
   END SEQUENCE
RETURN NIL

/* <Alt-A>=Open All: adds ALL the files of the list to the current area */
STATIC PROCEDURE BpIdxOpenAll( aFiles )
   LOCAL i, oErr
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      FOR i := 1 TO Len( aFiles )
         ORDLISTADD( Upper( hb_FNameName( aFiles[ i ] ) ) )
      NEXT
      dbGoTop()
      CoreStatus()
   RECOVER USING oErr
      /* an already open file stops the loop: it is reported and it goes on */
      UiErr( "Unable to open specified index" + hb_eol() + oErr:Description, "Index Selection" )
   END SEQUENCE
RETURN NIL

/* <Alt-K>=Close All: leaves the area without index files */
STATIC PROCEDURE BpIdxCloseAll()
   LOCAL oErr
   IF Empty( CoreKeyExpr() )
      RETURN
   ENDIF
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      OrdListClear()
      dbGoTop()
      CoreStatus()
   RECOVER USING oErr
      UiErr( "Unable to close the index files: " + oErr:Description, "Index Selection" )
   END SEQUENCE
RETURN NIL

FUNCTION BpIdxSelectScreen()
   LOCAL aFiles, nSel := 1, nTop := 1, nKey, lExit := .F., lFull := .T.
   LOCAL nVis := SEL_ROWS, cDir, cSpec, cFile, lOk := .F.
   IF ! BpNeedDb() ; RETURN NIL ; ENDIF
   cDir  := CoreDir()
   cSpec := BpIdxSpec()
   aFiles := BpIdxFiles()
   IF Empty( aFiles )
      /* message of the original (dump 03BCC9) */
      UiMsg( "No matching index files in current directory", "Index Selection" )
      RETURN NIL
   ENDIF
   /* S1 of window-close.md (B4): armed here, where the screen takes over the
    * display, because without the hook WM_CLOSE never reaches the latch this
    * loop peeks (the screen has no mouse code of its own, so the hook costs
    * nothing else). It is NOT disarmed on the way out on purpose:
    * DotMouseHook( .T. ) is idempotent, so a caller that already owns the hook
    * (the Browse edit) is untouched -disarming would strip its wheel, its clicks
    * and its own X-, and a caller without one (the desktop) keeps it armed for
    * the rest of the session, harmless because the driver has no use for those
    * mouse messages and every screen that cares polls its own channel. That is
    * what makes the X reachable from the desktop path too. The proper "install
    * only if not mine / remove only if mine" guard needs a hook-state getter in
    * bp_win32.c and is a follow-up, not this task. */
   DotMouseHook( .T. )
   DO WHILE ! lExit
      /* directory or FileSpec change: reload */
      IF cDir != CoreDir() .OR. ! ( Upper( cSpec ) == Upper( BpIdxSpec() ) )
         cDir  := CoreDir()
         cSpec := BpIdxSpec()
         aFiles := BpIdxFiles()
         nSel := 1 ; nTop := 1 ; lFull := .T.
         IF Empty( aFiles )
            UiMsg( "No matching index files in current directory", "Index Selection" )
         ENDIF
      ENDIF
      nSel := Max( 1, Min( nSel, Max( 1, Len( aFiles ) ) ) )
      IF lFull
         BpIdxSelDraw( aFiles, nSel, nTop, nVis )
         lFull := .F.
      ELSE
         UiPaintBegin()
         BpIdxSelLeft( aFiles, nSel, nTop, nVis )
         BpIdxSelRight()
         BpSelStatus()
         UiPaintEnd()
      ENDIF
      /* S1/S4 (window-close.md B4): the X of the window (BpWaitKey) leaves
       * through the SAME exit <Esc> uses -lExit, which falls out of the loop and
       * restores the screen-, never `Exit hwBro?` (L7). An idle slice does not
       * reach the DO CASE, so nothing is repainted per slice. */
      nKey := BpWaitKey()
      IF nKey == 0
         EXIT
      ENDIF
      DO CASE
      CASE nKey == K_ESC
         /* <Esc>=Browse: goes back to the browser with the active area */
         lExit := .T.
      CASE nKey == K_ENTER .OR. nKey == K_INS
         /* <Enter>=Pick: opens the highlighted index and goes back */
         IF ! Empty( aFiles )
            cFile := aFiles[ nSel ]
            lOk := BpIdxAdd( cFile )
            IF lOk
               lExit := .T.
            ELSE
               lFull := .T.
            ENDIF
         ENDIF
      CASE nKey == K_UP
         IF ! Empty( aFiles )
            nSel--
            IF nSel < 1
               nSel := Len( aFiles )
               nTop := Max( 1, Len( aFiles ) - nVis + 1 )
            ENDIF
            IF nSel < nTop
               nTop := nSel
               lFull := .T.
            ENDIF
         ENDIF
      CASE nKey == K_DOWN
         IF ! Empty( aFiles )
            nSel++
            IF nSel > Len( aFiles )
               nSel := 1
               nTop := 1
            ENDIF
            IF nSel > nTop + nVis - 1
               nTop := nSel - nVis + 1
               lFull := .T.
            ENDIF
         ENDIF
      CASE nKey == K_PGUP
         IF ! Empty( aFiles )
            nSel := Max( 1, nSel - nVis )
            nTop := Max( 1, Min( nTop - nVis, nSel ) )
            lFull := .T.
         ENDIF
      CASE nKey == K_PGDN
         IF ! Empty( aFiles )
            nSel := Min( Len( aFiles ), nSel + nVis )
            nTop := Max( 1, Min( nSel, Len( aFiles ) - nVis + 1 ) )
            lFull := .T.
         ENDIF
      CASE nKey == K_HOME
         nSel := 1 ; nTop := 1 ; lFull := .T.
      CASE nKey == K_END
         IF ! Empty( aFiles )
            nSel := Len( aFiles )
            nTop := Max( 1, Len( aFiles ) - nVis + 1 )
            lFull := .T.
         ENDIF
      CASE nKey == K_TAB
         /* <Tab>=Advance index order by 1 (only if there are orders: OrdName()
          * on a database without index blows up and BpFatal closes the app) */
         IF BpTagTotal() > 0
            BpIdxNextOrder()
         ENDIF
         lFull := .T.
      CASE nKey == K_SH_TAB
         IF BpTagTotal() > 0
            BpIdxPrevOrder()
         ENDIF
         lFull := .T.
      CASE nKey == K_DEL
         /* <Del>=Close index */
         BpIdxCloseIndex()
         lFull := .T.
      CASE nKey == K_ALT_A
         BpIdxOpenAll( aFiles )
         lFull := .T.
      CASE nKey == K_ALT_K
         BpIdxCloseAll()
         lFull := .T.
      CASE nKey == K_ALT_H
         BpIdxHotKeys()
         lFull := .T.
      CASE nKey == K_ALT_F
         BpIdxFileSpec()
         lFull := .T.
      CASE nKey == K_ALT_M
         BpIdxCreate()
         lFull := .T.
      CASE nKey == K_ALT_X
         /* <Alt-X> = Exit hwBro (Open Mode stayed in the F2 menu item) */
         BpExit()
         IF BpExiting()
            lExit := .T.
         ELSE
            lFull := .T.
         ENDIF
      CASE nKey == K_ALT_Y
         BpDbChangeDir()
         lFull := .T.
      CASE nKey == K_ALT_Z
         BpDbShell()
         lFull := .T.
      CASE nKey == K_ALT_N
         BpDbNext()
         lFull := .T.
      CASE nKey == K_ALT_MINUS
         BpDbPrev()
         lFull := .T.
      CASE nKey == K_CTRL_ENTER
         BpIdxVerify()
         lFull := .T.
      CASE nKey == K_CTRL_F3
         BpIdxTagInfo()
         lFull := .T.
      CASE nKey == K_ALT_F2
         /* Harbour Commander: the file manager selects databases now (the old
          * two-panel selection screen is gone); leaving this screen returns
          * to whoever called it. */
         BpDbPickHc()
         lExit := .T.
      CASE nKey == K_ALT_F4
         BpFldSelectScreen()
         lFull := .T.
      CASE nKey == K_F1 ; BpHelp() ; lFull := .T.
      CASE nKey == K_F2 ; DoMenu( 2 ) ; lFull := .T.
      CASE nKey == K_F3 ; DoMenu( 3 ) ; lFull := .T.
      CASE nKey == K_F4 ; DoMenu( 4 ) ; lFull := .T.
      CASE nKey == K_F5 ; DoMenu( 5 ) ; lFull := .T.
      CASE nKey == K_F6 ; DoMenu( 6 ) ; lFull := .T.
      CASE nKey == K_F7 ; DoMenu( 7 ) ; lFull := .T.
      CASE nKey == K_F8 ; DoMenu( 8 ) ; lFull := .T.
      CASE nKey == K_F9
         /* <F9> = dot prompt from here too (just like in the browser and in
          * the database selection); <Alt-X> is the exit from this screen. */
         BpDot()
         IF BpExiting()
            lExit := .T.
         ELSE
            lFull := .T.
         ENDIF
      ENDCASE
      IF lExit
         EXIT
      ENDIF
   ENDDO
   SetColor( UI_C_DESKTOP )
RETURN NIL

/* Alt-O: NEXT ORDER. The ring includes the NATURAL order (0) - asked by the
 * user - so it is ... nMax -> natural -> 1 ... . With no index at all (nMax = 0)
 * this is a no-op instead of asking for a tag that does not exist. */
FUNCTION BpIdxNextOrder()
   LOCAL n := OrdNumber(), nMax := dbOrderInfo( DBOI_ORDERCOUNT )
   IF n < nMax
      OrdSetFocus( n + 1 )
   ELSE
      OrdSetFocus( 0 )
   ENDIF
   CoreStatus()
RETURN NIL

/* the same ring backwards: 1 -> natural -> nMax -> ... */
FUNCTION BpIdxPrevOrder()
   LOCAL n := OrdNumber(), nMax := dbOrderInfo( DBOI_ORDERCOUNT )
   IF n > 1
      OrdSetFocus( n - 1 )
   ELSEIF n == 1
      OrdSetFocus( 0 )
   ELSE
      OrdSetFocus( nMax )
   ENDIF
   CoreStatus()
RETURN NIL

/* =====================================================================
 *  F3 - Index -> "Tag Selection/Information" (replica of the original)
 *  ---------------------------------------------------------------------
 *  Geometry MEASURED on BRO.EXE (9x16 px grid, captures
 *  _reversing/capturas/orig-f3*-06..16):
 *
 *    rows 0-1    menu bar (it stays above, the dialog does not touch it)
 *    rows 2..7   panel "Selected Database / Current Index / Current Tag /
 *                Key" (columns 18..55, cyan inside): the original does NOT
 *                clear that zone, so the dialog paints it again
 *                (see BpTagPanel)
 *    row  7..22  dialog box, columns 8..71, SINGLE frame, with a shadow
 *                of 2 columns (72..73) and one row (23)
 *    row  8      "Order Info for <FILE>.DBF" in yellow, centered 9..70
 *    row  9      DOUBLE separator
 *    row 10      header: Nr(10) Tag Name(15) Unique(30) Descending(39)
 *                RYO(52) File Name(58)
 *    row 11      single separator
 *    rows 12..15 the 4 visible tag rows, with vertical separators
 *                in columns 13, 28, 37, 50 and 56
 *    row 16      single separator
 *    row 17      "      Key:" in column 10 and the value in 22
 *    row 18      "Condition:" in 10 and the value in 22
 *    row 19      DOUBLE separator
 *    rows 20-21  helps in cyan "chips"
 *
 *  Keys measured on the original: arrows (1 record), PgUp/PgDn (ONE row,
 *  not a page), Home = first entry, End = last (cursor on the last visible
 *  row), Enter = fixes the order and exits, Esc = exits without change,
 *  Del/Ins/Alt-R = delete/create/reindex (they require EXCLUSIVE use).
 * ===================================================================== */

/* ---- dialog geometry (native 120x44 canvas) -------------------------
 * The dialog keeps the COMPOSITION measured on the 80x25 original: a box of
 * 16 rows x 64 columns (rows 7..22 / columns 8..71 there), the table of tags
 * with its 4 data rows, the Key/Condition rows, the two help rows and the
 * information panel sitting above the box, with its bottom edge on the row just
 * before the box. Nothing is added or removed: only the ORIGIN comes
 * from the canvas, so every constant below is the measured row/column
 * expressed as an offset from the centred box. BpTagGeo() is the single
 * source of that origin. */
#define TG_H           16        /* rows of the box (content)        */
#define TG_W           64        /* columns of the box (content)     */

STATIC FUNCTION BpTagGeo( n )
   LOCAL nT, nL
   nT := UiFitRow( UiCenterRow( TG_H ), TG_H + 1 )
   nL := UiFitCol( UiCenterCol( TG_W ), TG_W + 2 )
   DO CASE
   CASE n == 1 ; RETURN nT
   CASE n == 2 ; RETURN nL
   CASE n == 3 ; RETURN nT + TG_H - 1
   CASE n == 4 ; RETURN nL + TG_W - 1
   ENDCASE
RETURN 0

/* box and rows */
#define TG_T           BpTagGeo( 1 )
#define TG_L           BpTagGeo( 2 )
#define TG_B           BpTagGeo( 3 )
#define TG_R           BpTagGeo( 4 )
#define TG_IN_L        ( TG_L + 1 )   /* first inner column          */
#define TG_IN_R        ( TG_R - 1 )
#define TG_IN_W        ( TG_R - TG_L - 1 )
#define TG_ROW_TITLE   ( TG_T + 1 )
#define TG_ROW_SEP1    ( TG_T + 2 )   /* double sep.      */
#define TG_ROW_HDR     ( TG_T + 3 )
#define TG_ROW_SEP2    ( TG_T + 4 )   /* single sep.       */
#define TG_ROW_FIRST   ( TG_T + 5 )
#define TG_ROWS         4             /* visible data rows             */
#define TG_ROW_SEP3    ( TG_ROW_FIRST + TG_ROWS )   /* single sep.       */
#define TG_ROW_KEY     ( TG_ROW_SEP3 + 1 )
#define TG_ROW_COND    ( TG_ROW_KEY + 1 )
#define TG_ROW_SEP4    ( TG_ROW_COND + 1 )          /* double sep.      */
#define TG_HELP1       ( TG_ROW_SEP4 + 1 )
#define TG_HELP2       ( TG_HELP1 + 1 )
#define TG_HGAP         3             /* gap between hint chips            */
/* columns and widths of the cells (measured cell by cell on the original) */
#define TG_C_NR        ( TG_L + 2 )
#define TG_W_NR         2
#define TG_C_TAG       ( TG_L + 7 )
#define TG_W_TAG       12
#define TG_C_UNI       ( TG_L + 22 )
#define TG_W_UNI        6
#define TG_C_DESC      ( TG_L + 31 )
#define TG_W_DESC      10
#define TG_C_RYO       ( TG_L + 44 )
#define TG_W_RYO        3
#define TG_C_FILE      ( TG_L + 50 )
#define TG_W_FILE      12
/* vertical separators of the table (they only span the data rows) */
#define TG_V1          ( TG_L + 5 )
#define TG_V2          ( TG_L + 20 )
#define TG_V3          ( TG_L + 29 )
#define TG_V4          ( TG_L + 42 )
#define TG_V5          ( TG_L + 48 )
/* Key/Condition labels and values: the label takes 10 cells and the value
 * ALWAYS starts 4 columns later (the original literal is "      Key:  " and
 * "Condition:  ") */
#define TG_C_LBL       ( TG_L + 2 )
#define TG_C_VAL       ( TG_L + 14 )
#define TG_W_VAL       ( TG_IN_R - TG_C_VAL + 1 )
/* solid block measured in the first data row, Descending column */
#define TG_ROW_BLK     TG_ROW_FIRST
#define TG_C_BLK       ( TG_L + 32 )
/* top information panel: its content is FOUR lines (Selected Database, Current
 * Index, Current Tag, Key), so the interior is 4 rows and the panel is 6 rows
 * with its single frame. It sits just ABOVE the dialog box: the bottom edge is
 * the row before the box, never the box's own top row. When the two edges
 * coincided the dialog's top border was painted over the panel's bottom border
 * and the "Key:" line looked cut. It is centred on the canvas on its own. */
#define TG_P_W         38
#define TG_P_H          6
#define TG_P_B         ( TG_T - 1 )
#define TG_P_T         ( TG_P_B - TG_P_H + 1 )
#define TG_P_L         UiFitCol( UiCenterCol( TG_P_W ), TG_P_W + 2 )
#define TG_P_R         ( TG_P_L + TG_P_W - 1 )
#define TG_P_C_LBL     ( TG_P_L + 1 )   /* labels    */
#define TG_P_C_NUM     ( TG_P_L + 18 )  /* "(1/8)" */
#define TG_P_C_VAL     ( TG_P_L + 24 )  /* file / tag name               */
#define TG_P_C_KEY     ( TG_P_L + 6 )   /* value of the Key line  */

/* number of tags of the open index file; 0 if there is no database or if the
 * RDD does not support the query (a database WITHOUT index must show only <None>,
 * never blow up: an uncaught error closes the application) */
STATIC FUNCTION BpTagTotal()
   LOCAL n := 0
   IF ! Used()
      RETURN 0
   ENDIF
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      n := dbOrderInfo( DBOI_ORDERCOUNT )
   RECOVER
      n := 0
   END SEQUENCE
RETURN n

/* number of the active order (0 = natural order), error proof */
STATIC FUNCTION BpTagCur()
   LOCAL n := 0
   IF ! Used()
      RETURN 0
   ENDIF
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      n := OrdNumber()
   RECOVER
      n := 0
   END SEQUENCE
RETURN n

/* dbOrderInfo() of a given order, with a default value (on databases without
 * index some queries fail) */
STATIC FUNCTION BpTagInfo( i, nType, xDef )
   LOCAL x := xDef
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      x := dbOrderInfo( nType, , i )
   RECOVER
      x := xDef
   END SEQUENCE
RETURN x

/* name of the index file of an order: "CLIENTES.CDX" (the original
 * shows the file, without path) */
STATIC FUNCTION BpTagBagFile( i )
   LOCAL cFull := "", cName := ""
   cFull := BpTagInfo( i, DBOI_FULLPATH, "" )
   IF ! Empty( cFull )
      cName := hb_FNameName( cFull ) + hb_FNameExt( cFull )
   ELSE
      cName := BpTagInfo( i, DBOI_BAGNAME, "" )
   ENDIF
RETURN Upper( cName )

/* strips the outer parentheses of a key: the original panel shows
 * "Key: (CLI_NUMERO)" and "Key: (CLI_CODPRO)" over the stored expression */
STATIC FUNCTION BpTagNoParen( c )
   DO WHILE Len( c ) >= 2 .AND. Left( c, 1 ) == "(" .AND. Right( c, 1 ) == ")"
      c := SubStr( c, 2, Len( c ) - 2 )
   ENDDO
RETURN c

/* screen list: { nOrder, cTag, cExpression, cCondition, lDesc, lUni,
 *                cIndexFile } ; entry 1 is ALWAYS <None> */
STATIC FUNCTION BpTagList()
   LOCAL a := {}, n := BpTagTotal(), i
   AAdd( a, { 0, "<None>", "Natural Order", "", .F., .F., "" } )
   FOR i := 1 TO n
      AAdd( a, { i, ;
                 BpTagInfo( i, DBOI_NAME, "" ), ;
                 BpTagInfo( i, DBOI_EXPRESSION, "" ), ;
                 BpTagInfo( i, DBOI_CONDITION, "" ), ;
                 BpTagInfo( i, DBOI_ISDESC, .F. ), ;
                 BpTagInfo( i, DBOI_UNIQUE, .F. ), ;
                 BpTagBagFile( i ) } )
   NEXT
RETURN a

/* first visible row so no gap is left at the end of the list */
STATIC FUNCTION BpTagTop( nLen )
RETURN Max( 1, nLen - TG_ROWS + 1 )

/* one row of the table (no paint block of its own: the caller wraps it, so
 * two rows are repainted in a single REFRESH). Each cell is painted
 * at ITS exact width: the highlight does NOT touch the gaps or the separators. */
STATIC PROCEDURE BpTagRow( aTag, i, nTop, nSel )
   LOCAL nRow := TG_ROW_FIRST + ( i - nTop ), a, cCol, cTag, cUni, cDesc, cFile
   IF nRow < TG_ROW_FIRST .OR. nRow > TG_ROW_FIRST + TG_ROWS - 1
      RETURN
   ENDIF
   IF i >= 1 .AND. i <= Len( aTag )
      a := aTag[ i ]
      cCol  := iif( i == nSel, UI_C_LISTSEL, UI_C_DLG )
      cTag  := PadR( a[ 2 ], TG_W_TAG )
      cUni  := PadR( iif( a[ 6 ], "Unique", "" ), TG_W_UNI )
      cDesc := PadR( iif( a[ 5 ], "Descending", "" ), TG_W_DESC )
      cFile := PadR( Left( a[ 7 ], TG_W_FILE ), TG_W_FILE )
      UiWrite( nRow, TG_C_NR,   PadL( LTrim( Str( a[ 1 ] ) ), TG_W_NR ), cCol )
   ELSE
      /* row without data (e.g. after deleting a tag): it is cleared */
      cCol := UI_C_DLG
      cTag := Space( TG_W_TAG )
      cUni := Space( TG_W_UNI )
      cDesc := Space( TG_W_DESC )
      cFile := Space( TG_W_FILE )
      UiWrite( nRow, TG_C_NR, Space( TG_W_NR ), cCol )
   ENDIF
   UiWrite( nRow, TG_C_TAG,  cTag,  cCol )
   UiWrite( nRow, TG_C_UNI,  cUni,  cCol )
   UiWrite( nRow, TG_C_DESC, cDesc, cCol )
   /* RYO: RYO indexes belong to the SIx Driver of the original; in hwBro that
    * column always stays empty, as in the reference captures */
   UiWrite( nRow, TG_C_RYO,  Space( TG_W_RYO ), cCol )
   UiWrite( nRow, TG_C_FILE, cFile, cCol )
RETURN

/* the 4 visible rows (no paint block of their own) */
STATIC PROCEDURE BpTagRows( aTag, nTop, nSel )
   LOCAL i
   FOR i := nTop TO nTop + TG_ROWS - 1
      BpTagRow( aTag, i, nTop, nSel )
   NEXT
RETURN

/* SOLID block of 1 cell the original ALWAYS leaves at (12,40), the
 * Descending column of the first row: it does not move with the cursor or with
 * the scroll (measured in 9 captures). Its colour changes between databases
 * (brown in CLIENTES, dark blue in ARTICULO) and does not depend on the tag or
 * the order (DBOI_ISDESC gives .F. for the 8 tags of CLIENTES and still the
 * original paints it brown), so it has no known meaning: it is always painted
 * brown, which is the value measured in CLIENTES. */
STATIC PROCEDURE BpTagBlock()
   UiWrite( TG_ROW_BLK, TG_C_BLK, " ", UI_C_TAGDESC )
RETURN

/* "Key:" and "Condition:" rows of the highlighted tag */
STATIC PROCEDURE BpTagKey( aTag, nSel )
   LOCAL cKey := "", cCond := "", a
   IF nSel >= 1 .AND. nSel <= Len( aTag )
      a := aTag[ nSel ]
      cKey  := a[ 3 ]
      cCond := a[ 4 ]
   ENDIF
   UiWrite( TG_ROW_KEY,  TG_C_LBL, "      Key:",  UI_C_DLG )
   UiWrite( TG_ROW_KEY,  TG_C_VAL, PadR( Left( cKey, TG_W_VAL ), TG_W_VAL ), UI_C_DLGINFO )
   UiWrite( TG_ROW_COND, TG_C_LBL, "Condition:",  UI_C_DLG )
   UiWrite( TG_ROW_COND, TG_C_VAL, PadR( Left( cCond, TG_W_VAL ), TG_W_VAL ), UI_C_DLGINFO )
RETURN

/* Panel "Selected Database / Current Index / Current Tag / Key" that the
 * original leaves in sight with the dialog open (rows 2..7, columns
 * 18..55): cyan inside, single frame and gray text (85,85,85). The bottom
 * edge is covered by the dialog box, just like in the original. */
STATIC PROCEDURE BpTagPanel()
   LOCAL cFile := "", cIdxFile := "", cTagName := "", cKey := "", cNum := ""
   LOCAL cTagNum := "", nCur := 0, nTot := 0, nBag := 1, nBags := 1
   nTot := BpTagTotal()
   nCur := BpTagCur()
   IF Used()
      cFile := Upper( CoreFileBase() ) + ".DBF"
   ENDIF
   IF nCur > 0
      cTagName := BpTagInfo( nCur, DBOI_NAME, "" )
      cKey     := "(" + BpTagNoParen( BpTagInfo( nCur, DBOI_EXPRESSION, "" ) ) + ")"
      cIdxFile := BpTagBagFile( nCur )
   ELSE
      cTagName := "<None>"
      cKey     := "Natural Order"
      IF nTot > 0
         cIdxFile := BpTagBagFile( 1 )
      ENDIF
   ENDIF
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      nBags := dbOrderInfo( DBOI_BAGCOUNT )
      nBag  := dbOrderInfo( DBOI_BAGNUMBER )
   RECOVER
      nBags := 1
      nBag  := 1
   END SEQUENCE
   /* with no index the engine reports 0/0: the line is informative, it stays 1/1 */
   nBags := Max( 1, nBags )
   nBag  := Max( 1, nBag )
   cNum    := PadL( "(" + LTrim( Str( nBag ) ) + "/" + LTrim( Str( nBags ) ) + ")", 5 )
   cTagNum := PadL( "(" + LTrim( Str( nCur ) ) + "/" + LTrim( Str( nTot ) ) + ")", 5 )
   UiPaintBegin()
   UiFillBox( TG_P_T, TG_P_L, TG_P_B, TG_P_R, UI_C_BOX )
   UiFrame( TG_P_T, TG_P_L, TG_P_B, TG_P_R, UI_C_BOX, .F. )
   UiWrite( TG_P_T + 1, TG_P_C_LBL, "Selected Database:", UI_C_BOXDIM )
   UiWrite( TG_P_T + 1, TG_P_C_VAL, Left( cFile, TG_P_R - TG_P_C_VAL ), UI_C_BOXDIM )
   UiWrite( TG_P_T + 2, TG_P_C_LBL, "Current Index:", UI_C_BOXDIM )
   UiWrite( TG_P_T + 2, TG_P_C_NUM, cNum, UI_C_BOXDIM )
   UiWrite( TG_P_T + 2, TG_P_C_VAL, Left( cIdxFile, TG_P_R - TG_P_C_VAL ), UI_C_BOXDIM )
   UiWrite( TG_P_T + 3, TG_P_C_LBL, "Current Tag:", UI_C_BOXDIM )
   UiWrite( TG_P_T + 3, TG_P_C_NUM, cTagNum, UI_C_BOXDIM )
   UiWrite( TG_P_T + 3, TG_P_C_VAL, Left( cTagName, TG_P_R - TG_P_C_VAL ), UI_C_BOXDIM )
   UiWrite( TG_P_T + 4, TG_P_C_LBL, "Key:", UI_C_BOXDIM )
   UiWrite( TG_P_T + 4, TG_P_C_KEY, Left( cKey, TG_P_R - TG_P_C_KEY ), UI_C_BOXDIM )
   UiPaintEnd()
RETURN

/* full dialog screen: only on entry and after Del/Ins/Alt-R */
STATIC PROCEDURE BpTagDraw( aTag, nSel, nTop )
   LOCAL r, cTit, nCol
   UiPaintBegin()
   /* the information panel of the original stays in sight (S8) */
   BpTagPanel()
   UiShadow( TG_T, TG_L, TG_B, TG_R )
   UiFillBox( TG_T, TG_L, TG_B, TG_R, UI_C_DLG )
   UiFrame( TG_T, TG_L, TG_B, TG_R, UI_C_DLGBRD, .F. )
   /* title centered in the inner width, like the original */
   cTit := "Order Info for " + iif( Used(), Upper( CoreFileBase() ) + ".DBF", "" )
   nCol := TG_IN_L + Int( ( TG_IN_W - Len( cTit ) ) / 2 )
   UiWrite( TG_ROW_TITLE, Max( TG_IN_L, nCol ), cTit, UI_C_DLGINFO )
   /* horizontal separators (measured: double at 9 and 19, single at 11 and 16):
    * the DIM pair, so they read as rules on the cyan body */
   SetColor( UI_C_BOXDIM )
   @ TG_ROW_SEP1, TG_IN_L SAY Replicate( BP_LINE_DOUBLE, TG_IN_W )
   @ TG_ROW_SEP2, TG_IN_L SAY Replicate( BP_LINE_SINGLE, TG_IN_W )
   @ TG_ROW_SEP3, TG_IN_L SAY Replicate( BP_LINE_SINGLE, TG_IN_W )
   @ TG_ROW_SEP4, TG_IN_L SAY Replicate( BP_LINE_DOUBLE, TG_IN_W )
   /* header of the table (that row does NOT carry vertical separators) */
   SetColor( UI_C_DLG )
   @ TG_ROW_HDR, TG_C_NR   SAY PadL( "Nr", TG_W_NR )
   @ TG_ROW_HDR, TG_C_TAG  SAY "Tag Name"
   @ TG_ROW_HDR, TG_C_UNI  SAY "Unique"
   @ TG_ROW_HDR, TG_C_DESC SAY "Descending"
   @ TG_ROW_HDR, TG_C_RYO  SAY "RYO"
   @ TG_ROW_HDR, TG_C_FILE SAY "File Name"
   /* vertical separators: only the data rows */
   SetColor( UI_C_BOXDIM )
   FOR r := TG_ROW_FIRST TO TG_ROW_FIRST + TG_ROWS - 1
      @ r, TG_V1 SAY BP_SEP_VERT
      @ r, TG_V2 SAY BP_SEP_VERT
      @ r, TG_V3 SAY BP_SEP_VERT
      @ r, TG_V4 SAY BP_SEP_VERT
      @ r, TG_V5 SAY BP_SEP_VERT
   NEXT
   SetColor( UI_C_DESKTOP )
   BpTagRows( aTag, nTop, nSel )
   BpTagKey( aTag, nSel )
   BpTagBlock()
   /* helps: BpHotKey() returns the column AFTER the chip, so the chips are
    * CHAINED with one single gap (TG_HGAP) instead of being placed on absolute
    * columns: the literal pairs of the original left "<Esc>=Leave<Alt-M>=Edit"
    * touching, because 47 + Len( "<Esc>=Leave" ) == 58 was the next start.
    * The first chip of each row keeps its measured column. */
   nCol := TG_L + 13
   nCol := BpHotKey( TG_HELP1, nCol, "<" + Chr( 24 ), "=Select Order" ) + TG_HGAP
   nCol := BpHotKey( TG_HELP1, nCol, "Esc",   "=Leave" ) + TG_HGAP
   BpHotKey( TG_HELP1, nCol, "Alt-M", "=Edit" )
   nCol := TG_L + 4
   nCol := BpHotKey( TG_HELP2, nCol, "Del",   "=Delete Order" ) + TG_HGAP
   nCol := BpHotKey( TG_HELP2, nCol, "Ins",   "=Add Order" ) + TG_HGAP
   BpHotKey( TG_HELP2, nCol, "Alt-R", "=ReIndex" )
   UiPaintEnd()
RETURN

/* is the database open EXCLUSIVE? Del/Ins/Alt-R require it. If it is in
 * SHARED it ASKS with the MEASURED warning of the original (the dump literal
 * "...or to ReIndex;Open Database Exclusive?" uses the ';' as line
 * separator: the ';' is NOT printed) and, if accepted, the database is reopened
 * in EXCLUSIVE keeping record and order (BpDbToggleMode), like the original and
 * like BpIdxNeedExclusive() of "Create Index". Before it was a UiMsg (a single
 * OK button): it said exclusive mode was needed and there was no way to get it.
 * Returns .T. only if the area REALLY ended up in EXCLUSIVE (if another process
 * locks the file and the reopen cannot be done, it warns and does nothing). */
STATIC FUNCTION BpTagExclusive()
   IF ! Used()
      RETURN .F.
   ENDIF
   IF CoreRealMode() != "SHARED"
      RETURN .T.
   ENDIF
   IF ! UiConfirm( "Exclusive Use required to Add/Delete Tags or to ReIndex" + hb_eol() + ;
                   "Open Database Exclusive?", "hwBro" )
      RETURN .F.
   ENDIF
   BpDbToggleMode()
   IF CoreRealMode() == "SHARED"
      /* the setting stayed as it was (the reopen failed or went the other way) */
      IF CoreOpenMode() != "SHARED"
         CoreToggleMode()
         CoreStatus()
      ENDIF
      UiMsg( "Could not open the database in Exclusive Mode.", "hwBro" )
      RETURN .F.
   ENDIF
RETURN .T.

/* Enter: fixes the highlighted order (<None> = natural order) and exits */
STATIC PROCEDURE BpTagSetOrder( nSel )
   LOCAL oErr, nRec := 0
   IF ! Used()
      RETURN
   ENDIF
   nRec := RecNo()
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      IF nSel <= 1
         OrdSetFocus( 0 )
      ELSE
         OrdSetFocus( nSel - 1 )
      ENDIF
      /* OrdSetFocus() leaves the pointer on the first key of the new order;
       * the original KEEPS the current record (measured: Rec. 69/400 after
       * choosing another tag), so it goes back to it. */
      IF nRec > 0 .AND. nRec <= RecCount()
         dbGoto( nRec )
      ENDIF
      CoreStatus()
   RECOVER USING oErr
      UiErr( "Could not set the order:" + hb_eol() + oErr:Description )
   END SEQUENCE
RETURN

/* Del: deletes the highlighted tag (the <None> row is NEVER deleted) */
STATIC FUNCTION BpTagDelete( aTag, nSel )
   LOCAL cTag, oErr, lOk := .F.
   IF nSel < 2 .OR. nSel > Len( aTag )
      RETURN .F.
   ENDIF
   IF ! BpTagExclusive()
      RETURN .F.
   ENDIF
   IF ! UiConfirm( "Delete highlighted Tag?" )
      RETURN .F.
   ENDIF
   cTag := aTag[ nSel ][ 2 ]
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      OrdDestroy( cTag )
      lOk := .T.
   RECOVER USING oErr
      UiErr( "Could not delete the tag:" + hb_eol() + oErr:Description )
   END SEQUENCE
RETURN lOk

/* definition of the tags of the open index file, captured BEFORE
 * touching them so they can be rebuilt as they are:
 * { { cTag, cExpression, cCondition, lUnique, lDesc, cBag }, ... }
 *
 * The last element is the BAG (index file) of the tag, in two flavours:
 *   lFullPath = .F. (default) -> name WITHOUT path, which is what
 *                 BpTagRebuild() needs: it recreates the tags inside the bag
 *                 that is already open.
 *   lFullPath = .T.           -> FULL PATH with extension (DBOI_FULLPATH),
 *                 which is what a process that DELETES that file needs.
 *                 There is NO fallback to CoreFileBase() in this mode: if the
 *                 RDD does not report the path the element is "" and the
 *                 caller must refuse to go on (BpIdxRecreate() does).
 *                 Deleting the wrong file is the worst possible bug here, so
 *                 nothing is guessed. */
STATIC FUNCTION BpTagDefs( lFullPath )
   LOCAL a := {}, i, n := BpTagTotal(), cFull
   DEFAULT lFullPath TO .F.
   FOR i := 1 TO n
      cFull := BpTagInfo( i, DBOI_FULLPATH, "" )
      AAdd( a, { BpTagInfo( i, DBOI_NAME, "" ), ;
                 BpTagInfo( i, DBOI_EXPRESSION, "" ), ;
                 BpTagInfo( i, DBOI_CONDITION, "" ), ;
                 BpTagInfo( i, DBOI_UNIQUE, .F. ), ;
                 BpTagInfo( i, DBOI_ISDESC, .F. ), ;
                 iif( lFullPath, cFull, ;
                      iif( Empty( cFull ), CoreFileBase(), hb_FNameName( cFull ) ) ) } )
   NEXT
RETURN a

/* Alt-R: rebuilds the index file (it requires exclusive use) TAG BY TAG and with
 * a real progress bar.
 *
 * Measured in this Harbour (that is why the REINDEX command is not used, it
 * reports nothing and forced the "Working... please wait" box):
 *   - `REINDEX <tag>` does NOT compile (syntax error): the command redoes all.
 *   - `dbReindex( <tag> )` EXISTS but IGNORES the name: it takes the same as the
 *     full REINDEX (0.08 s per tag with 200,000 records, i.e. it redoes all
 *     every time) and it does not fail even with a nonexistent name.
 *   - `OrdDestroy()` + `OrdCreate()` work on the open area, but the
 *     recreated tag goes TO THE END of the index file: rebuilding a single one
 *     changes the numbering (ARTICULO 1/4 would become 4/4). The same happens
 *     when recreating a tag with `OrdCreate()` over an EXISTING name (measured):
 *     it does not replace it in place, it sends it to the end.
 * That is why ALL of them are destroyed and recreated IN THE SAME ORDER, which
 * leaves the numbering untouched, and the bar advances one step per tag with the
 * original literal in the text line (dump 044C7A: "Indexing Tag ").
 * It cannot be cancelled with <Esc>: stopping halfway through a reindex would
 * leave the index file incomplete (and there are tags already destroyed). */
STATIC FUNCTION BpTagReindex()
   LOCAL aDef
   IF ! BpTagExclusive()
      RETURN .F.
   ENDIF
   IF ! UiConfirm( "ReIndex all Tags?" )
      RETURN .F.
   ENDIF
   aDef := BpTagDefs()
   IF Empty( aDef )
      RETURN .F.
   ENDIF
RETURN BpTagRebuild( aDef, "ReIndexing " )

/* rebuilds ALL the tags of the index file with the definitions of aDef, in
 * that same order (so the numbering of the orders does not change) and with the
 * progress bar. It leaves the area in the same order and record. Used by Alt-R
 * (reindex as it is) and Alt-M (modify the parameters of the highlighted tag). */
STATIC FUNCTION BpTagRebuild( aDef, cTitle )
   LOCAL i, oErr, lOk, nOk := 0, cBad := "", cSave, aP
   LOCAL nOldOrd, nRec
   DEFAULT cTitle TO "ReIndexing "
   /* state of the area to leave it the same: active order number (0 = natural;
    * the orders are recreated in the same order, so the number still holds)
    * and record number */
   nOldOrd := BpTagCur()
   nRec := 0
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      nRec := RecNo()
   RECOVER
      nRec := 0
   END SEQUENCE
   /* the progress box covers the dialog: it is saved and restored at the end,
    * so the area that comes back is exactly the one UiProgBegin() painted over.
    * UiProgRect() (bp_ui.prg) is the only source of that rectangle: it used to
    * be a literal of the old 80x25 grid. */
   aP := UiProgRect()
   cSave := SaveScreen( aP[ 1 ], aP[ 2 ], Min( MaxRow(), aP[ 3 ] + 1 ), ;
                        Min( MaxCol(), aP[ 4 ] + 2 ) )
   UiProgBegin( cTitle + Upper( CoreFileBase() ) + ".DBF", Len( aDef ), .F. )
   /* 1. all out BEFORE creating any (otherwise the numbering changes) */
   FOR i := 1 TO Len( aDef )
      BEGIN SEQUENCE WITH {| e | Break( e ) }
         OrdDestroy( aDef[ i ][ 1 ] )
      RECOVER
      END SEQUENCE
   NEXT
   /* 2. they are recreated in the same order, reporting progress */
   FOR i := 1 TO Len( aDef )
      UiProgUpdate( i - 1, Len( aDef ), "Indexing Tag " + aDef[ i ][ 1 ] )
      oErr := NIL
      lOk := .F.
      BEGIN SEQUENCE WITH {| e | Break( e ) }
         /* same FOR, same UNIQUE and same DESCEND as the original tag.
          * MEASURED in this build: OrdCondSet() only applies the FOR (positions
          * 1 and 2); positions 8/9/10, which in theory carry UNIQUE/DESCEND, do
          * nothing. UNIQUE goes in the 5th parameter of OrdCreate() and DESCEND
          * is applied AFTERWARDS with dbOrderInfo( DBOI_ISDESC, , n, .T. ), which
          * does work (measured with a test tag: the order is reversed). */
         IF Empty( aDef[ i ][ 3 ] )
            OrdCondSet()
         ELSE
            OrdCondSet( aDef[ i ][ 3 ], &( "{|| " + aDef[ i ][ 3 ] + " }" ) )
         ENDIF
         OrdCreate( aDef[ i ][ 6 ], aDef[ i ][ 1 ], aDef[ i ][ 2 ], ;
                    &( "{|| " + aDef[ i ][ 2 ] + " }" ), aDef[ i ][ 4 ] )
         IF aDef[ i ][ 5 ]
            /* the new tag ends up AT THE END of the index file */
            dbOrderInfo( DBOI_ISDESC, , dbOrderInfo( DBOI_ORDERCOUNT ), .T. )
         ENDIF
         lOk := .T.
      RECOVER USING oErr
         lOk := .F.
      END SEQUENCE
      IF lOk
         nOk++
      ELSE
         cBad += iif( Empty( cBad ), "", ", " ) + aDef[ i ][ 1 ]
      ENDIF
   NEXT
   /* 3. leave the area as it was (same order and same record) */
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      OrdSetFocus( nOldOrd )
      IF nRec > 0 .AND. nRec <= RecCount()
         dbGoto( nRec )
      ENDIF
   RECOVER
   END SEQUENCE
   UiProgEnd()
   OrdCondSet()
   RestScreen( aP[ 1 ], aP[ 2 ], Min( MaxRow(), aP[ 3 ] + 1 ), ;
               Min( MaxCol(), aP[ 4 ] + 2 ), cSave )
   SetColor( UI_C_DESKTOP )
   CoreStatus()
   IF ! Empty( cBad )
      UiErr( "Could not reindex:" + hb_eol() + cBad )
   ENDIF
RETURN nOk > 0

FUNCTION BpIdxTagInfo()
   LOCAL aTag, nSel := 1, nTop := 1, nKey, nOld, nOldTop, cSave, cOldCur
   LOCAL lFull, lEnd := .F., lChanged
   IF ! BpNeedDb()
      RETURN NIL
   ENDIF
   aTag := BpTagList()
   /* on entry the cursor is on the active order and the window leaves ONE row
    * of context above (measured on the original) */
   nSel := BpTagCur() + 1
   IF nSel < 1 .OR. nSel > Len( aTag )
      nSel := 1
   ENDIF
   nTop := Max( 1, Min( nSel - 1, BpTagTop( Len( aTag ) ) ) )
   /* the dialog paints its own highlight: the system cursor is hidden
    * (otherwise it blinks inside the table) */
   cOldCur := SetCursor( 0 )
   /* panel + shadow and dialog box + shadow, from the same variables the box
    * is drawn with: a literal here left garbage or wiped a neighbour */
   cSave := SaveScreen( TG_P_T - 1, TG_L - 1, Min( MaxRow(), TG_B + 2 ), ;
                        Min( MaxCol(), TG_R + 2 ) )
   BpTagDraw( aTag, nSel, nTop )
   DO WHILE ! lEnd
      nOld := nSel
      nOldTop := nTop
      /* S1/S4 (window-close.md B4): the X of the window (BpWaitKey) leaves
       * through the same exit <Esc> uses: out of the loop, through the
       * RestScreen()/SetCursor() tail below, without asking anything (L7). An
       * idle slice does not reach the DO CASE, so nothing is repainted. */
      nKey := BpWaitKey()
      IF nKey == 0
         EXIT
      ENDIF
      lFull := .F.
      lChanged := .F.
      DO CASE
      CASE nKey == K_ESC
         lEnd := .T.
      CASE nKey == K_ENTER
         /* Enter fixes the order and exits, with the screen already restored */
         BpTagSetOrder( nSel )
         lEnd := .T.
      CASE nKey == K_UP
         nSel := Max( 1, nSel - 1 )
      CASE nKey == K_DOWN
         nSel := Min( Len( aTag ), nSel + 1 )
      CASE nKey == K_PGUP
         /* the original moves ONE row with PgUp/PgDn, not a page (measured) */
         nSel := Max( 1, nSel - 1 )
      CASE nKey == K_PGDN
         nSel := Min( Len( aTag ), nSel + 1 )
      CASE nKey == K_HOME
         nSel := 1
      CASE nKey == K_END
         nSel := Max( 1, Len( aTag ) )
      CASE nKey == K_DEL
         IF BpTagDelete( aTag, nSel )
            lChanged := .T.
         ENDIF
      CASE nKey == K_INS
         /* <Ins>=Add Order: reuses the tag creation that already exists */
         IF BpTagExclusive()
            BpIdxCreate()
            lChanged := .T.
         ENDIF
      CASE nKey == K_ALT_R
         IF BpTagReindex()
            lChanged := .T.
         ENDIF
      CASE nKey == K_ALT_M
         /* <Alt-M>=Edit: opens the parameter form (the same one of the
          * "Create Index File") PREFILLED with the data of the highlighted tag.
          * On confirming the whole index file is rebuilt with the new
          * definition (OrdCreate over an existing name sends it to the end,
          * measured), so the numbering of the orders does not change. */
         IF nSel > 1
            BpIdxCreate( aTag[ nSel ][ 7 ], aTag[ nSel ][ 2 ], aTag[ nSel ][ 3 ], ;
                         aTag[ nSel ][ 4 ], aTag[ nSel ][ 6 ], aTag[ nSel ][ 5 ] )
            lChanged := .T.
         ENDIF
      ENDCASE
      IF lEnd
         EXIT
      ENDIF
      /* after Del/Ins/Alt-R the list changes: it is reloaded and all repainted */
      IF lChanged
         aTag := BpTagList()
         nSel := Max( 1, Min( nSel, Len( aTag ) ) )
         nTop := Max( 1, Min( nTop, BpTagTop( Len( aTag ) ) ) )
         lFull := .T.
      ENDIF
      /* window: the cursor always visible; when passing the bottom edge the
       * window goes down ONE row (measured on the original) */
      IF nSel < nTop
         nTop := nSel
      ENDIF
      IF nSel > nTop + TG_ROWS - 1
         nTop := nSel - TG_ROWS + 1
      ENDIF
      nTop := Max( 1, Min( nTop, BpTagTop( Len( aTag ) ) ) )
      /* repaint: only what changed (no flicker at all) */
      IF lFull
         BpTagDraw( aTag, nSel, nTop )
      ELSEIF nTop != nOldTop
         UiPaintBegin()
         BpTagRows( aTag, nTop, nSel )
         BpTagKey( aTag, nSel )
         BpTagBlock()
         UiPaintEnd()
      ELSEIF nSel != nOld
         UiPaintBegin()
         BpTagRow( aTag, nOld, nTop, nSel )
         BpTagRow( aTag, nSel, nTop, nSel )
         BpTagKey( aTag, nSel )
         BpTagBlock()
         UiPaintEnd()
      ENDIF
   ENDDO
   RestScreen( TG_P_T - 1, TG_L - 1, Min( MaxRow(), TG_B + 2 ), ;
               Min( MaxCol(), TG_R + 2 ), cSave )
   SetCursor( cOldCur )
   SetColor( UI_C_DESKTOP )
RETURN NIL

/* =====================================================================
 *  F3 - Index -> "Index ScopeTop / ScopeBottom" (Shift-F3)
 * ---------------------------------------------------------------------
 *  NOTE: in BRO.EXE this option appears DIMMED with CLIENTES.DBF open
 *  (measured: _reversing/capturas/o5-scope-06-op5.png; the menu arrows SKIP
 *  it), so its screen could NOT be captured. The texts come from the string
 *  dump (zone 047241..047577):
 *
 *    047241: Index ScopeTop / ScopeBottom      (title)
 *    047284: Key: 
 *    0472BB:    ScopeTop:  
 *    047316: ScopeBottom:  
 *    047577: No Data within Scope
 *
 *  The box follows the already validated pattern of the other dialogs
 *  (AGENTS.md S8) because there is no measured geometry of the original.
 * ===================================================================== */
/* ---- dialog geometry (native 120x44 canvas) -------------------------
 * Box of 8 rows x 54 columns (rows 8..15 / columns 13..66 measured on the
 * 80x25 original), centred on the canvas; every row/column below is the
 * measured one as an offset from the centred box. BpScopeGeo() is the single
 * source of the origin. */
#define SC_H         8
#define SC_W        54

STATIC FUNCTION BpScopeGeo( n )
   LOCAL nT, nL
   nT := UiFitRow( UiCenterRow( SC_H ), SC_H + 1 )
   nL := UiFitCol( UiCenterCol( SC_W ), SC_W + 2 )
   DO CASE
   CASE n == 1 ; RETURN nT
   CASE n == 2 ; RETURN nL
   CASE n == 3 ; RETURN nT + SC_H - 1
   CASE n == 4 ; RETURN nL + SC_W - 1
   ENDCASE
RETURN 0

#define SC_T         BpScopeGeo( 1 )
#define SC_L         BpScopeGeo( 2 )
#define SC_B         BpScopeGeo( 3 )
#define SC_R         BpScopeGeo( 4 )
#define SC_ROW_TIT   ( SC_T + 1 )
#define SC_ROW_SEP   ( SC_T + 2 )
#define SC_ROW_KEY   ( SC_T + 3 )
#define SC_ROW_TOP   ( SC_T + 4 )
#define SC_ROW_BOT   ( SC_T + 5 )
#define SC_ROW_HELP  ( SC_T + 6 )
#define SC_C_LBL     ( SC_L + 3 )
#define SC_C_VAL     ( SC_L + 17 )
#define SC_W_VAL    32

/* date typed in the scope field: CToD() takes MM/DD/YYYY and SToD() the
 * YYYYMMDD format; CToD() does NOT take YYYYMMDD (see AGENTS.md 5.24) */
STATIC FUNCTION BpScopeDate( cText )
   LOCAL c := AllTrim( cText ), d := CToD( "" )
   d := CToD( c )
   IF Empty( d ) .AND. Len( c ) == 8
      d := SToD( c )
   ENDIF
RETURN d

/* TYPE of the KEY of the active order, as reported by the engine. NOTE (measured
 * with a test program on this Harbour): the .CDX created by the SIx
 * Driver of the original declare their keys as "C" even when the expression is a
 * numeric field (CLI_NUMERO: type=C keysize=6), that is, the keys are
 * compared as TEXT. Passing a NUMERIC value to OrdScope() does nothing (no
 * error, no filter); passing the text "120300" does filter (400 -> 281 keys). */
STATIC FUNCTION BpScopeKeyType()
   LOCAL c := "C"
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      c := hb_CStr( dbOrderInfo( DBOI_KEYTYPE ) )
   RECOVER
      c := "C"
   END SEQUENCE
   IF Empty( c )
      c := "C"
   ENDIF
RETURN c

/* scope value from what was TYPED: it is taken to the TYPE of the KEY (not to
 * the one of the field). A wrong type does not blow up: the engine ignores it
 * silently and the range is not applied. */
STATIC FUNCTION BpScopeValue( cText )
   LOCAL x := "", cType := "C"
   IF Empty( cText )
      RETURN NIL
   ENDIF
   cType := BpScopeKeyType()
   DO CASE
   CASE cType == "N"
      x := Val( StrTran( AllTrim( cText ), ",", "." ) )
   CASE cType == "D"
      x := BpScopeDate( cText )
   CASE cType == "L"
      x := ( Upper( Left( AllTrim( cText ), 1 ) ) $ "TY1" )
   OTHERWISE
      /* text keys (the usual thing in the .CDX of the original) */
      x := AllTrim( cText )
   ENDCASE
RETURN x

/* CURRENT value of a scope, as text for the field (empty = no scope). It is read
 * with dbOrderInfo(), which returns the value and does NOT clear the range. */
STATIC FUNCTION BpScopeText( nScope )
   LOCAL x := NIL
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      x := dbOrderInfo( nScope )
   RECOVER
      x := NIL
   END SEQUENCE
   DO CASE
   CASE x == NIL            ; RETURN ""
   CASE ValType( x ) == "C" ; RETURN RTrim( x )
   CASE ValType( x ) == "N" ; RETURN LTrim( Str( x, 20, iif( x == Int( x ), 0, 4 ) ) )
   CASE ValType( x ) == "D" ; RETURN DToC( x )
   CASE ValType( x ) == "L" ; RETURN iif( x, "T", "F" )
   ENDCASE
RETURN ""

/* full dialog screen (a single time, without flicker) */
STATIC PROCEDURE BpScopeDraw()
   LOCAL cTit := "Index ScopeTop / ScopeBottom", cKey, nCol
   cKey := iif( Empty( CoreKeyExpr() ), "Natural Order", "(" + CoreKeyExpr() + ")" )
   UiPaintBegin()
   UiShadow( SC_T, SC_L, SC_B, SC_R )
   UiFillBox( SC_T, SC_L, SC_B, SC_R, UI_C_DLG )
   UiFrame( SC_T, SC_L, SC_B, SC_R, UI_C_DLGBRD, .T. )
   nCol := SC_L + 1 + Int( ( SC_R - SC_L - 1 - Len( cTit ) ) / 2 )
   UiWrite( SC_ROW_TIT, Max( SC_L + 1, nCol ), cTit, UI_C_DLGINFO )
   SetColor( UI_C_BOXDIM )
   @ SC_ROW_SEP, SC_L + 1 SAY Replicate( BP_LINE_DOUBLE, SC_R - SC_L - 1 )
   SetColor( UI_C_DESKTOP )
   /* "Key: (CLI_NUMERO)": the order the range is applied to */
   UiWrite( SC_ROW_KEY, SC_C_LBL, "Key:", UI_C_DLG )
   UiWrite( SC_ROW_KEY, SC_C_VAL, Left( cKey, SC_W_VAL ), UI_C_DLGINFO )
   /* LITERAL labels of the dump (they include the spaces of the original) */
   UiWrite( SC_ROW_TOP, SC_C_LBL, "   ScopeTop:", UI_C_DLG )
   UiWrite( SC_ROW_BOT, SC_C_LBL, "ScopeBottom:", UI_C_DLG )
   BpHotKey( SC_ROW_HELP, SC_C_LBL,      "Enter", "=Accept" )
   BpHotKey( SC_ROW_HELP, SC_C_LBL + 18, "Esc",   "=Leave" )
   SetColor( UI_C_DESKTOP )
   UiPaintEnd()
RETURN NIL

/* applies both ends of the range. Both fields EMPTY = remove the scope
 * (the original lets it be cleared); if the range leaves the database without
 * data, the warning is the one of the dump: "No Data within Scope" */
STATIC PROCEDURE BpScopeApply( cTop, cBot )
   LOCAL oErr, lOk := .F., xTop, xBot, lNoData := .F.
   xTop := BpScopeValue( cTop )
   xBot := BpScopeValue( cBot )
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      IF xTop == NIL .AND. xBot == NIL
         OrdScope( TOPSCOPE, NIL )
         OrdScope( BOTTOMSCOPE, NIL )
      ELSE
         OrdScope( TOPSCOPE, xTop )
         OrdScope( BOTTOMSCOPE, xBot )
      ENDIF
      dbGoTop()
      lNoData := Eof()
      lOk := .T.
   RECOVER USING oErr
      lOk := .F.
      UiErr( "Could not set the index scope:" + hb_eol() + oErr:Description, "Index Scope" )
   END SEQUENCE
   IF lOk
      CoreStatus()
      IF lNoData
         UiMsg( "No Data within Scope", "Index ScopeTop / ScopeBottom" )
      ENDIF
   ENDIF
RETURN NIL

FUNCTION BpIdxScope()
   LOCAL cTop, cBot := "", cSave, lOk := .F.
   IF ! BpNeedDb() ; RETURN NIL ; ENDIF
   IF Empty( CoreKeyExpr() )
      /* with no active order there is no key to apply the range to */
      UiMsg( "No Open Index Files", "Index ScopeTop / ScopeBottom" )
      RETURN NIL
   ENDIF
   cSave := SaveScreen( SC_T, SC_L, Min( MaxRow(), SC_B + 1 ), ;
                        Min( MaxCol(), SC_R + 2 ) )
   BpScopeDraw()
   /* fields IN SEQUENCE (Enter goes to the next one, Esc cancels the option and
    * the scope stays as it was): there is no Tab inside UiLineEdit */
   cTop := UiFormEdit( SC_ROW_TOP, SC_C_VAL, SC_W_VAL, BpScopeText( TOPSCOPE ), .F. )
   IF cTop != NIL
      cBot := UiFormEdit( SC_ROW_BOT, SC_C_VAL, SC_W_VAL, BpScopeText( BOTTOMSCOPE ), .F. )
      IF cBot != NIL
         lOk := .T.
      ENDIF
   ENDIF
   RestScreen( SC_T, SC_L, Min( MaxRow(), SC_B + 1 ), ;
               Min( MaxCol(), SC_R + 2 ), cSave )
   SetColor( UI_C_DESKTOP )
   IF ! lOk
      RETURN NIL
   ENDIF
   BpScopeApply( cTop, cBot )
RETURN NIL

/* =====================================================================
 *  F3 - Index -> "Create Index File"
 * ---------------------------------------------------------------------
 *  Form MEASURED on the original (_reversing/capturas/
 *  oA-createform-06-op7.png): box rows 3..21 / columns 13..68 of the original (here 72 WIDE, see IC_W: the file name box holds a real Windows name), yellow title
 *  centered in row 5 ("Create Index / Tag for <FILE>.DBF"),
 *  separators in rows 10, 15 and 18 and these labels/fields:
 *
 *    row  7  Path: (15)                       [C:\] (green, 21..33)
 *              Index File Name: (36)           [CLIENTES.CDX] (red, 53..83)
 *    row  8  Multi-Order Bag (Y/N): (15) [Y] (39)
 *              Tag Name: (43)                  [CLIENTES] (red, 53..62)
 *    row  9  Non-Compact IDX (Y/N): (15)  [N] (39)
 *  The two boxes above are NOT painted (and the ring skips them) on a
 *  single-order .NTX database, whose file name opens with .NTX instead of .CDX.
 *    row 11  Key Expression: (15)             [(CLI_NUMERO)] (red, 31..64)
 *    row 12  FOR Condition: (16)              [ ] (red, 31..64)
 *    row 14  Unique (Y/N): (17) [N] (31)   Descending (Y/N): (39) [N] (57)
 *    row 16  SCOPE (15)  [ALL] (red, 22..27)
 *    row 17  WHILE (15)  [ ] (red, 22..64)
 *    row 19  Create Empty (RYO) Index (Y/N): (24) [N] (57)
 *    row 20  Create Sub-Index of Current Index (Y/N): (15) [N] (57)
 *
 *  The editable fields are the FOUR that hwBro knows how to apply (file, tag,
 *  expression and FOR condition); the others (multi-order bag, compact IDX,
 *  Unique, Descending, SCOPE, WHILE, RYO and sub-index) are shown with the
 *  value hwBro really uses and are not edited: inventing toggles that do
 *  nothing would be lying about the functionality.
 * ===================================================================== */

/* is the database EXCLUSIVE? The original asks "Database is open in Shared
 * Mode / Open Exclusive?" BEFORE opening the form (MEASURED: captures
 * o9-create-06-op6.png and oA-createform-06-op6.png) and, if accepted, it
 * reopens the database in EXCLUSIVE keeping record and order (BpDbToggleMode) */
STATIC FUNCTION BpIdxNeedExclusive( cTitle )
   LOCAL lShared := .F.
   IF ! Used()
      RETURN .F.
   ENDIF
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      lShared := dbInfo( DBI_SHARED )
   RECOVER
      lShared := .F.
   END SEQUENCE
   IF ! lShared
      RETURN .T.
   ENDIF
   IF ! UiConfirm( "Database is open in Shared Mode" + hb_eol() + "Open Exclusive?", cTitle )
      RETURN .F.
   ENDIF
   BpDbToggleMode()
   lShared := .F.
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      lShared := dbInfo( DBI_SHARED )
   RECOVER
      lShared := .F.
   END SEQUENCE
   IF lShared
      UiMsg( "Exclusive Use required to Add/Delete Tags or to ReIndex" + hb_eol() + ;
             "Open Database Exclusive?", cTitle )
      RETURN .F.
   ENDIF
RETURN .T.

/* does a tag with that name already exist in the area? */
STATIC FUNCTION BpIdxTagExists( cTag )
   LOCAL n, lFound := .F.
   FOR n := 1 TO BpTagTotal()
      IF Upper( BpTagInfo( n, DBOI_NAME, "" ) ) == Upper( cTag )
         lFound := .T.
      ENDIF
   NEXT
RETURN lFound

/* ---- form geometry (native 120x44 canvas) ---------------------------
 * The form keeps its composition: a box of 19 rows x 56 columns (rows 3..21 /
 * columns 13..68 measured on the 80x25 original), a yellow title, three group
 * separators and the 13 boxes. Nothing is added or removed: only the ORIGIN
 * comes from the canvas, so every row/column below is written as the measured
 * value through ICF_R()/ICF_C(), offsets from the centred box. BpIdxCreateGeo()
 * is the single source of that origin. */
#define IC_H            19
/* 72 instead of the 56 of the original: the "Index File Name" box has to hold a
 * real Windows file name (the original's 8.3 fit in 12 cells, a name with 30
 * characters does not). Everything else is written as an offset from the box,
 * so the wider frame only adds room to the right. */
#define IC_W            72

STATIC FUNCTION BpIdxCreateGeo( n )
   LOCAL nT, nL
   nT := UiFitRow( UiCenterRow( IC_H ), IC_H + 1 )
   nL := UiFitCol( UiCenterCol( IC_W ), IC_W + 2 )
   DO CASE
   CASE n == 1 ; RETURN nT
   CASE n == 2 ; RETURN nL
   CASE n == 3 ; RETURN nT + IC_H - 1
   CASE n == 4 ; RETURN nL + IC_W - 1
   ENDCASE
RETURN 0

#define IC_T           BpIdxCreateGeo( 1 )
#define IC_L           BpIdxCreateGeo( 2 )
#define IC_B           BpIdxCreateGeo( 3 )
#define IC_R           BpIdxCreateGeo( 4 )
/* measured row/column of the original -> canvas, from the corner of the box */
#define ICF_R( __r )   ( IC_T + ( __r ) - 3 )
#define ICF_C( __c )   ( IC_L + ( __c ) - 13 )
#define ICF_SEP_W      ( IC_W - 2 )            /* separators span the inside */
#define ICF_ROW_HINT   ICF_R( 13 )             /* free frame row for the warning */
/* width of the "Index File Name" box: up to the frame's inner column, so a real
 * Windows file name fits (the original's 12 cells were for 8.3 names) */
#define ICF_FILE_W     ( ( IC_W - 2 ) - ( 53 - 14 ) )

/* full drawing of the form (a single time). lCdx tells whether the OPEN database
 * works with a multi-order .CDX: the two boxes that only mean something for a
 * .CDX (Multi-Order Bag and Non-Compact IDX) are NOT painted for a single-order
 * .NTX/.IDX, so the form cannot offer CDX options on an NTX database. */
STATIC PROCEDURE BpIdxCreateDraw( cFile, cTag, cExpr, cFor, lCdx )
   LOCAL cTit := "Create Index / Tag for " + Upper( CoreFileBase() ) + ".DBF", nCol
   UiPaintBegin()
   UiShadow( IC_T, IC_L, IC_B, IC_R )
   UiFillBox( IC_T, IC_L, IC_B, IC_R, UI_C_DLG )
   UiFrame( IC_T, IC_L, IC_B, IC_R, UI_C_DLGBRD, .T. )
   nCol := ICF_C( 14 ) + Int( ( ICF_SEP_W - Len( cTit ) ) / 2 )
   UiWrite( ICF_R( 5 ), Max( ICF_C( 14 ), nCol ), cTit, UI_C_DLGINFO )
   /* group separators: the DIM pair of the box, so they read as rules on the
    * cyan body (black lines would not be seen there) */
   SetColor( UI_C_BOXDIM )
   @ ICF_R( 10 ), ICF_C( 14 ) SAY Replicate( BP_LINE_SINGLE, ICF_SEP_W )
   @ ICF_R( 15 ), ICF_C( 14 ) SAY Replicate( BP_LINE_SINGLE, ICF_SEP_W )
   @ ICF_R( 18 ), ICF_C( 14 ) SAY Replicate( BP_LINE_SINGLE, ICF_SEP_W )
   SetColor( UI_C_DESKTOP )
   UiWrite( ICF_R( 7 ), ICF_C( 15 ), "Path:", UI_C_DLG )
   UiWrite( ICF_R( 7 ), ICF_C( 21 ), PadR( Upper( CoreDir() ), 13 ), UI_C_DLGFIELD )
   UiWrite( ICF_R( 7 ), ICF_C( 36 ), "Index File Name:", UI_C_DLG )
   IF lCdx
      UiWrite( ICF_R( 8 ), ICF_C( 15 ), "Multi-Order Bag (Y/N):", UI_C_DLG )
      UiWrite( ICF_R( 8 ), ICF_C( 39 ), "Y", UI_C_DLGRED )
      UiWrite( ICF_R( 9 ), ICF_C( 15 ), "Non-Compact IDX (Y/N):", UI_C_DLG )
      UiWrite( ICF_R( 9 ), ICF_C( 39 ), "N", UI_C_DLGRED )
   ELSE
      /* a single-order .NTX has neither a multi-order bag nor a compact flag:
       * the two boxes are left blank instead of lying with "Y"/"N" */
      UiWrite( ICF_R( 8 ), ICF_C( 15 ), Space( 24 ), UI_C_DLG )
      UiWrite( ICF_R( 8 ), ICF_C( 39 ), " ", UI_C_DLGRED )
      UiWrite( ICF_R( 9 ), ICF_C( 15 ), Space( 24 ), UI_C_DLG )
      UiWrite( ICF_R( 9 ), ICF_C( 39 ), " ", UI_C_DLGRED )
   ENDIF
   UiWrite( ICF_R( 8 ), ICF_C( 43 ), "Tag Name:", UI_C_DLG )
   UiWrite( ICF_R( 11 ), ICF_C( 15 ), "Key Expression:", UI_C_DLG )
   UiWrite( ICF_R( 12 ), ICF_C( 16 ), "FOR Condition:", UI_C_DLG )
   UiWrite( ICF_R( 14 ), ICF_C( 17 ), "Unique (Y/N):", UI_C_DLG )
   UiWrite( ICF_R( 14 ), ICF_C( 31 ), "N", UI_C_DLGRED )
   UiWrite( ICF_R( 14 ), ICF_C( 39 ), "Descending (Y/N):", UI_C_DLG )
   UiWrite( ICF_R( 14 ), ICF_C( 57 ), "N", UI_C_DLGRED )
   UiWrite( ICF_R( 16 ), ICF_C( 15 ), "SCOPE", UI_C_DLG )
   UiWrite( ICF_R( 16 ), ICF_C( 22 ), "ALL   ", UI_C_DLGRED )
   UiWrite( ICF_R( 17 ), ICF_C( 15 ), "WHILE", UI_C_DLG )
   UiWrite( ICF_R( 17 ), ICF_C( 22 ), Space( 43 ), UI_C_DLGRED )
   UiWrite( ICF_R( 19 ), ICF_C( 24 ), "Create Empty (RYO) Index (Y/N):", UI_C_DLG )
   UiWrite( ICF_R( 19 ), ICF_C( 57 ), "N", UI_C_DLGRED )
   UiWrite( ICF_R( 20 ), ICF_C( 15 ), "Create Sub-Index of Current Index (Y/N):", UI_C_DLG )
   UiWrite( ICF_R( 20 ), ICF_C( 57 ), "N", UI_C_DLGRED )
   /* initial values of the editable fields */
   UiWrite( ICF_R( 7 ),  ICF_C( 53 ), PadR( cFile, ICF_FILE_W ), UI_C_DLGRED )
   UiWrite( ICF_R( 8 ),  ICF_C( 53 ), PadR( cTag, 10 ), UI_C_DLGRED )
   UiWrite( ICF_R( 11 ), ICF_C( 31 ), PadR( cExpr, 34 ), UI_C_DLGRED )
   UiWrite( ICF_R( 12 ), ICF_C( 31 ), PadR( cFor, 34 ), UI_C_DLGRED )
   SetColor( UI_C_DESKTOP )
   UiPaintEnd()
RETURN NIL

/* =====================================================================
 *  "Create Index File" form: boxes and navigation
 * ---------------------------------------------------------------------
 *  The original lets you walk ALL the boxes of the form with Enter and
 *  toggles the (Y/N) ones with Y/N. hwBro can only honour six of them
 *  (Index File Name, Tag Name, Key Expression, FOR Condition, Unique and
 *  Descending); the other seven belong to options this port does not have
 *  (Path fixed to the database directory, non compact .IDX files, RYO and
 *  sub-indexes of the SIx Driver, SCOPE/WHILE of a new index), so they are
 *  walked the same and, when focused, they show a warning line in
 *  row 13 (inside the frame) instead of doing nothing silently.
 * ===================================================================== */
#define ICF_NF          13       /* form boxes              */
#define ICF_PATH         1
#define ICF_FILE         2
#define ICF_MOB          3
#define ICF_TAG          4
#define ICF_NC           5
#define ICF_EXPR         6
#define ICF_FOR          7
#define ICF_UNI          8
#define ICF_DESC         9
#define ICF_SCOPE       10
#define ICF_WHILE       11
#define ICF_RYO         12
#define ICF_SUB         13

/* geometry of each box (row, column, width), in the order they are seen */
STATIC FUNCTION BpIdxCreateSlots()
RETURN { { ICF_R(  7 ), ICF_C( 21 ), 13 }, ;   /*  1 Path             (informative)   */
         { ICF_R(  7 ), ICF_C( 53 ), ICF_FILE_W }, ;   /*  2 Index File Name  (text)          */
         { ICF_R(  8 ), ICF_C( 39 ),  1 }, ;   /*  3 Multi-Order Bag  (Y/N, fixes Y)  */
         { ICF_R(  8 ), ICF_C( 53 ), 10 }, ;   /*  4 Tag Name         (text)          */
         { ICF_R(  9 ), ICF_C( 39 ),  1 }, ;   /*  5 Non-Compact IDX  (Y/N, fixes N)  */
         { ICF_R( 11 ), ICF_C( 31 ), 34 }, ;   /*  6 Key Expression   (text)          */
         { ICF_R( 12 ), ICF_C( 31 ), 34 }, ;   /*  7 FOR Condition    (text)          */
         { ICF_R( 14 ), ICF_C( 31 ),  1 }, ;   /*  8 Unique           (Y/N)           */
         { ICF_R( 14 ), ICF_C( 57 ),  1 }, ;   /*  9 Descending       (Y/N)           */
         { ICF_R( 16 ), ICF_C( 22 ),  6 }, ;   /* 10 SCOPE            (fixed ALL)     */
         { ICF_R( 17 ), ICF_C( 22 ), 43 }, ;   /* 11 WHILE            (unsupported)   */
         { ICF_R( 19 ), ICF_C( 57 ),  1 }, ;   /* 12 Create Empty (RYO) Index         */
         { ICF_R( 20 ), ICF_C( 57 ),  1 } }    /* 13 Create Sub-Index                 */

/* warning of the boxes this port cannot honour ("" = it is editable) */
STATIC FUNCTION BpIdxCreateHint( nFld )
   DO CASE
   CASE nFld == ICF_PATH  ; RETURN "Path is the database folder (fixed here)."
   CASE nFld == ICF_FILE
      /* the F6 "Database Driver" only chooses the RDD of the databases opened
       * from then on: an area that is already open keeps its engine, and this
       * form has to say so instead of looking broken */
      IF Upper( CoreDriver() ) == "DBFNTX" .AND. BpIdxBagExt() == ".CDX"
         RETURN "This database is open as DBFCDX: close and reopen it to use DBFNTX."
      ENDIF
      IF Upper( CoreDriver() ) == "DBFCDX" .AND. BpIdxBagExt() != ".CDX"
         RETURN "This database works with " + BpIdxBagExt() + ;
                " files: close and reopen it to use DBFCDX."
      ENDIF
      RETURN ""
   CASE nFld == ICF_MOB   ; RETURN "This port always creates a multi-order .CDX."
   CASE nFld == ICF_NC    ; RETURN "Only compact .CDX files are available here."
   CASE nFld == ICF_SCOPE ; RETURN "Scope of a new index is always ALL."
   CASE nFld == ICF_WHILE ; RETURN "WHILE is not supported for a new index."
   CASE nFld == ICF_RYO   ; RETURN "RYO indexes are not available (SIx Driver)."
   CASE nFld == ICF_SUB   ; RETURN "Sub-indexes are not available in this port."
   ENDCASE
RETURN ""

/* extension of the index file the OPEN AREA really writes (".CDX" for the
 * multi-order bag, ".NTX" for the classic single-order file, whatever the RDD
 * answers). It is read from the AREA and not from the global driver because the
 * F6 "Database Driver" only chooses the RDD of the databases opened from then
 * on: an already-open database keeps its engine. */
STATIC FUNCTION BpIdxBagExt()
   LOCAL c := ""
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      c := dbOrderInfo( DBOI_BAGEXT )
   RECOVER
      c := ""
   END SEQUENCE
   c := Upper( AllTrim( iif( ValType( c ) == "C", c, "" ) ) )
   IF Empty( c )
      c := iif( Upper( CoreDriver() ) == "DBFNTX", ".NTX", ".CDX" )
   ENDIF
RETURN c

/* name of the index file NEXT TO the database (a bare name handed to
 * OrdCreate() would be created in the folder hwBro was started from) */
STATIC FUNCTION BpIdxBagPath( cName )
   LOCAL cFile := CoreFileName(), nSep := Rat( "\", cFile )
RETURN iif( nSep > 0, Left( cFile, nSep ), "" ) + cName

/* next / previous box of the form: the two boxes that only exist for a
 * multi-order .CDX (Multi-Order Bag and Non-Compact IDX) are SKIPPED on a
 * single-order .NTX/.IDX, so the ring never lands on a CDX option there */
STATIC FUNCTION BpIdxStep( nFld, nDir, lCdx )
   nFld += nDir
   DO WHILE nFld >= ICF_PATH .AND. nFld <= ICF_NF
      IF lCdx .OR. ( nFld != ICF_MOB .AND. nFld != ICF_NC )
         EXIT
      ENDIF
      nFld += nDir
   ENDDO
RETURN nFld

/* repaints ONE box (value with or without focus) and the warning line, all in a
 * single paint block: a single REFRESH, no flicker */
STATIC PROCEDURE BpIdxCreateField( nFld, cVal, lFocus, cHint )
   LOCAL aSlot := BpIdxCreateSlots()[ nFld ]
   UiPaintBegin()
   UiWrite( aSlot[ 1 ], aSlot[ 2 ], PadR( cVal, aSlot[ 3 ] ), ;
            iif( lFocus, UI_C_LISTSEL, UI_C_DLGRED ) )
   UiWrite( ICF_ROW_HINT, ICF_C( 15 ), PadR( cHint, ICF_SEP_W ), ;
            iif( Empty( cHint ), UI_C_DLG, UI_C_DLGINFO ) )
   UiPaintEnd()
RETURN

/* navigation action of a key inside the form:
 *   1 = next box, -1 = previous, 2 = cancel, 3 = Ctrl-End (accept
 *   this box and ALL the following ones, ending the form), 0 = edit */
STATIC FUNCTION BpIdxNavKey( nKey )
   DO CASE
   CASE nKey == K_ENTER .OR. nKey == K_TAB .OR. nKey == K_DOWN
      RETURN 1
   CASE nKey == K_SH_TAB .OR. nKey == K_UP
      RETURN -1
   CASE nKey == K_ESC
      RETURN 2
   CASE nKey == K_CTRL_END
      RETURN 3
   ENDCASE
RETURN 0

/* informative box: it only waits for a navigation key */
STATIC FUNCTION BpIdxWaitNav()
   LOCAL nKey, nAct
   DO WHILE .T.
      /* S1/S4 (window-close.md B4): the X of the window cancels the form with
       * the value <Esc> gives (2), so BpIdxCreate() restores the screen through
       * its own normal exit instead of unwinding from here. */
      nKey := BpWaitKey()
      IF nKey == 0
         RETURN 2
      ENDIF
      nAct := BpIdxNavKey( nKey )
      IF nAct != 0
         RETURN nAct
      ENDIF
   ENDDO
RETURN 0

/* inline edit of a text box. Returns { cValue, nAction } with
 * NIL in cValue if it is cancelled. The buffer editing itself (Backspace,
 * Del, arrows, Home/End and Ins = insert/overwrite) is the shared rule of
 * UiEditKey() in bp_ui.prg, the same one UiLineEdit() uses, so the two
 * editors cannot drift apart; the only thing this one adds is the box
 * navigation (Tab/Shift-Tab/vertical arrows and the action codes).
 * The system cursor is only shown INSIDE the box
 * (outside, the focused box is seen by the highlight),
 * which was the other defect: it blinked anywhere.
 * The box is painted WHOLE by UiEditFieldPaint() on every change, and in
 * INSERT mode the cell under the cursor is painted as a BLOCK with the colours
 * inverted (the system caret is hidden meanwhile), so the mode is visible here
 * exactly like in the UiInput dialogs. */
STATIC FUNCTION BpIdxTextEdit( nRow, nCol, nLen, cValue, lUpper )
   LOCAL cBuf, nPos, nKey, nAct, aKey
   LOCAL lInsert := .F.
   cBuf := PadR( Left( cValue, nLen ), nLen )
   nPos := Min( Len( RTrim( cValue ) ), nLen - 1 )
   IF nPos < 0
      nPos := 0
   ENDIF
   SetCursor( 1 )
   UiEditFieldPaint( nRow, nCol, cBuf, UI_C_LISTSEL, nPos, lInsert )
   DO WHILE .T.
      DevPos( nRow, nCol + nPos )
      /* S1/S4 (window-close.md B4): the X of the window cancels the box with the
       * value <Esc> gives -{ NIL, 2 }, painted without focus like the exits
       * below-, so the form restores the screen normally. */
      nKey := BpWaitKey()
      IF nKey == 0
         SetCursor( 0 )
         UiEditFieldPaint( nRow, nCol, cBuf, UI_C_LISTSEL, nPos, .F. )
         RETURN { NIL, 2 }
      ENDIF
      nAct := BpIdxNavKey( nKey )
      IF nAct != 0
         SetCursor( 0 )
         UiEditFieldPaint( nRow, nCol, cBuf, UI_C_LISTSEL, nPos, .F. )
         RETURN { iif( nAct == 2, NIL, RTrim( cBuf ) ), nAct }
      ENDIF
      aKey := UiEditKey( cBuf, nPos, nKey, lInsert, .F., lUpper )
      cBuf := aKey[ 1 ] ; nPos := aKey[ 2 ] ; lInsert := aKey[ 3 ]
      IF aKey[ 5 ] == "ENTER"
         /* box full: it confirms itself and goes to the next one */
         SetCursor( 0 )
         UiEditFieldPaint( nRow, nCol, cBuf, UI_C_LISTSEL, nPos, .F. )
         RETURN { RTrim( cBuf ), 1 }
      ELSEIF aKey[ 5 ] == "ESC"
         SetCursor( 0 )
         UiEditFieldPaint( nRow, nCol, cBuf, UI_C_LISTSEL, nPos, .F. )
         RETURN { NIL, 2 }
      ELSE
         /* the caret only lives in the OVERWRITE look (see UiLineEdit) */
         SetCursor( iif( lInsert, 0, 1 ) )
         UiEditFieldPaint( nRow, nCol, cBuf, UI_C_LISTSEL, nPos, lInsert )
      ENDIF
   ENDDO
RETURN { "", 0 }

/* (Y/N) box: Y/N/Space toggle, Enter/Tab/down arrow go to the
 * next one, Shift-Tab/up arrow to the previous and Esc cancels.
 * Returns { lValue, nAction }. */
STATIC FUNCTION BpIdxYnEdit( nRow, nCol, lVal )
   LOCAL nKey, nAct, cCh
   SetCursor( 0 )
   DO WHILE .T.
      /* S1/S4 (window-close.md B4): the X of the window answers the same
       * { NIL, 2 } <Esc> gives, so the form leaves through its normal exit. */
      nKey := BpWaitKey()
      IF nKey == 0
         RETURN { NIL, 2 }
      ENDIF
      nAct := BpIdxNavKey( nKey )
      IF nAct != 0
         RETURN { iif( nAct == 2, NIL, lVal ), nAct }
      ENDIF
      cCh := iif( nKey > 0 .AND. nKey < 256, Upper( Chr( nKey ) ), "" )
      IF cCh == "Y" .OR. nKey == K_SPACE
         lVal := .T.
      ELSEIF cCh == "N"
         lVal := .F.
      ENDIF
      SetColor( UI_C_LISTSEL )
      @ nRow, nCol SAY iif( lVal, "Y", "N" )
      SetColor( UI_C_DESKTOP )
   ENDDO
RETURN { lVal, 0 }

/* "Create Index File" form. Without arguments it creates a new tag with the
 * values of the active order; with arguments (used by the Alt-M of the tags
 * dialog) it opens the SAME form PREFILLED with the parameters of an
 * existing tag and, on confirming, MODIFIES that tag: the index file is
 * rebuilt with the new definition in its place (see BpTagRebuild). */
FUNCTION BpIdxCreate( cFileIn, cTagIn, cExprIn, cForIn, lUniIn, lDescIn )
   LOCAL cFile, cTag, cExpr, cFor, cSave, lOk := .T., oErr, cErr, cOpen
   LOCAL nT := IC_T, nL := IC_L, nB := IC_B, nR := IC_R
   LOCAL aSlots, aR, nFld, lDone := .F., lUni := .F., lDesc := .F., cVal
   LOCAL cOldCur, nTot := 0, aDef, nIdx
   LOCAL cExt, lCdx, cBag := ""
   LOCAL lModify := ! Empty( cTagIn )
   IF ! BpNeedDb() ; RETURN NIL ; ENDIF
   IF ! BpIdxNeedExclusive( "Create Index File" )
      RETURN NIL
   ENDIF
   /* the file this database really writes: .CDX when it is a multi-order bag,
    * .NTX for the classic single-order driver (read from the OPEN AREA) */
   cExt := BpIdxBagExt()
   lCdx := ( cExt == ".CDX" )
   cFile := Upper( CoreFileBase() ) + cExt
   cTag  := Upper( CoreFileBase() )
   cExpr := CoreKeyExpr()
   IF ! Empty( cExpr )
      cExpr := "(" + cExpr + ")"
   ENDIF
   cFor  := ""
   IF lModify
      /* prefill with the parameters of the tag to be modified */
      cFile  := iif( Empty( cFileIn ), cFile, cFileIn )
      cTag   := Upper( AllTrim( cTagIn ) )
      cExpr  := cExprIn
      cFor   := cForIn
      lUni   := ( lUniIn == .T. )
      lDesc  := ( lDescIn == .T. )
   ENDIF
   cOpen := ""
   IF ! Empty( CoreKeyExpr() )
      cOpen := Upper( hb_FNameNameExt( BpTagBagFile( BpTagCur() ) ) )
   ENDIF
   cSave := SaveScreen( nT - 1, nL - 1, Min( MaxRow(), nB + 2 ), ;
                        Min( MaxCol(), nR + 2 ) )
   BpIdxCreateDraw( cFile, cTag, cExpr, cFor, lCdx )
   BpLog( "BpIdxCreate: formulario file=" + cFile + " tag=" + cTag + " expr=" + cExpr )
   /* ---- navigable form (13 boxes, in the order they are seen):
    * Enter/Tab/down arrow = next, Shift-Tab/up arrow = previous,
    * Esc = leave without creating anything. Enter in the LAST box creates. The
    * system cursor is hidden outside the text boxes: the active box
    * is marked with the highlight (UI_C_LISTSEL). */
   aSlots := BpIdxCreateSlots()
   cOldCur := SetCursor( 0 )
   nFld := ICF_FILE          /* starts at the file name          */
   DO WHILE ! lDone
      /* current value of the box */
      DO CASE
      CASE nFld == ICF_PATH  ; cVal := Upper( CoreDir() )
      CASE nFld == ICF_FILE  ; cVal := cFile
      CASE nFld == ICF_MOB   ; cVal := "Y"
      CASE nFld == ICF_TAG   ; cVal := cTag
      CASE nFld == ICF_NC    ; cVal := "N"
      CASE nFld == ICF_EXPR  ; cVal := cExpr
      CASE nFld == ICF_FOR   ; cVal := cFor
      CASE nFld == ICF_UNI   ; cVal := iif( lUni, "Y", "N" )
      CASE nFld == ICF_DESC  ; cVal := iif( lDesc, "Y", "N" )
      CASE nFld == ICF_SCOPE ; cVal := "ALL"
      CASE nFld == ICF_WHILE ; cVal := ""
      CASE nFld == ICF_RYO   ; cVal := "N"
      OTHERWISE              ; cVal := "N"
      ENDCASE
      BpIdxCreateField( nFld, cVal, .T., BpIdxCreateHint( nFld ) )
      /* edit (or wait for navigation, if it is informative) */
      DO CASE
      CASE nFld == ICF_FILE .OR. nFld == ICF_TAG
         aR := BpIdxTextEdit( aSlots[ nFld ][ 1 ], aSlots[ nFld ][ 2 ], ;
                              aSlots[ nFld ][ 3 ], cVal, .T. )
      CASE nFld == ICF_EXPR .OR. nFld == ICF_FOR
         aR := BpIdxTextEdit( aSlots[ nFld ][ 1 ], aSlots[ nFld ][ 2 ], ;
                              aSlots[ nFld ][ 3 ], cVal, .F. )
      CASE nFld == ICF_UNI
         aR := BpIdxYnEdit( aSlots[ nFld ][ 1 ], aSlots[ nFld ][ 2 ], lUni )
      CASE nFld == ICF_DESC
         aR := BpIdxYnEdit( aSlots[ nFld ][ 1 ], aSlots[ nFld ][ 2 ], lDesc )
      OTHERWISE
         aR := { cVal, BpIdxWaitNav() }
      ENDCASE
      IF aR[ 2 ] == 2                       /* Esc: leave, no creation */
         lOk := .F.
         EXIT
      ENDIF
      /* store the value (an empty box KEEPS the previous value: this is a
       * navigable form, not a chain of mandatory fields) */
      DO CASE
      CASE nFld == ICF_FILE
         IF ! Empty( aR[ 1 ] ) ; cFile := Upper( AllTrim( aR[ 1 ] ) ) ; ENDIF
      CASE nFld == ICF_TAG
         IF ! Empty( aR[ 1 ] ) ; cTag := Upper( AllTrim( aR[ 1 ] ) ) ; ENDIF
      CASE nFld == ICF_EXPR
         IF ! Empty( aR[ 1 ] ) ; cExpr := AllTrim( aR[ 1 ] ) ; ENDIF
      CASE nFld == ICF_FOR
         cFor := AllTrim( aR[ 1 ] )
      CASE nFld == ICF_UNI  ; lUni  := aR[ 1 ]
      CASE nFld == ICF_DESC ; lDesc := aR[ 1 ]
      ENDCASE
      /* repaint the box without focus now (and without the warning line) */
      DO CASE
      CASE nFld == ICF_FILE  ; cVal := cFile
      CASE nFld == ICF_TAG   ; cVal := cTag
      CASE nFld == ICF_EXPR  ; cVal := cExpr
      CASE nFld == ICF_FOR   ; cVal := cFor
      CASE nFld == ICF_UNI   ; cVal := iif( lUni, "Y", "N" )
      CASE nFld == ICF_DESC  ; cVal := iif( lDesc, "Y", "N" )
      ENDCASE
      BpIdxCreateField( nFld, cVal, .F., "" )
      /* next / previous; Ctrl-End accepts the rest and closes the form;
       * Enter in the last box = create the index */
      IF aR[ 2 ] == 3
         lDone := .T.
      ELSE
         nFld := BpIdxStep( nFld, aR[ 2 ], lCdx )
         IF nFld > ICF_NF
            lDone := .T.
         ELSEIF nFld < ICF_PATH
            nFld := ICF_PATH
         ENDIF
      ENDIF
   ENDDO
   SetCursor( cOldCur )
   /* an EMPTY key expression used to reach OrdCreate() with &( "{|| }" ) and
    * come back as a bare "Syntax error": it is refused here, with a message
    */
   IF lOk .AND. Empty( AllTrim( cExpr ) )
      lOk  := .F.
      cErr := "The key expression cannot be empty."
   ENDIF
   IF lOk
      /* the file of THIS database's engine: .CDX or .NTX, never the other one */
      cFile := Upper( hb_FNameName( cFile ) ) + cExt
      /* confirmations with the literals of the dump */
      IF BpIdxTagExists( cTag )
         IF ! UiConfirm( "Tag exists already, Overwrite?", "Create Index File" )
            lOk := .F.
         ENDIF
      ENDIF
   ENDIF
   IF lOk
      cBag := BpIdxBagPath( cFile )
      IF hb_FNameExists( cBag ) .AND. ! ( cOpen == cFile )
         IF ! UiConfirm( "File exists already, Overwrite?", "Create Index File" )
            lOk := .F.
         ENDIF
      ENDIF
   ENDIF
   IF lOk
      IF ! UiConfirm( "Ok to create " + cFile + " Index?", "Create Index File" )
         lOk := .F.
      ENDIF
   ENDIF
   cErr := ""
   IF lOk .AND. lModify
      /* MODIFY a tag that already exists: the WHOLE index file is rebuilt
       * with the new definition in its place. Measured: recreating only that tag
       * does not work because OrdCreate() over an existing name sends it TO THE END
       * and would change the numbering of the orders; BpTagRebuild() recreates
       * them all in the same order (and leaves the area in the same order and record). */
      aDef := BpTagDefs()
      nIdx := 0
      IF ! Empty( aDef )
         nIdx := AScan( aDef, {| a | Upper( a[ 1 ] ) == cTag } )
      ENDIF
      IF nIdx > 0
         aDef[ nIdx ][ 2 ] := cExpr
         aDef[ nIdx ][ 3 ] := cFor
         aDef[ nIdx ][ 4 ] := lUni
         aDef[ nIdx ][ 5 ] := lDesc
         lOk := BpTagRebuild( aDef, "ReIndexing " )
         BpLog( "BpIdxCreate: modify " + cTag + " ok=" + hb_CStr( lOk ) )
      ELSE
         lOk := .F.
         cErr := "Tag " + cTag + " not found."
      ENDIF
   ELSEIF lOk
      /* PROGRESS BAR of the creation: the engine does NOT report progress and
       * does not call the key block per record either (measured with a test
       * program: with 200,000 records the block was evaluated ONCE, and the index
       * ends up sorted by the TEXT of the expression, not by the block), so
       * there is no point to hook onto per record. The bar has,
       * therefore, ONE step (the tag) and the text line says how many records
       * are going to be indexed; rebuilding the index by hand to animate it would be hundreds
       * of times slower and this build has no OrdKeyAdd()/RYO to do it.
       * It does not carry <Esc>=Cancel: OrdCreate() cannot be interrupted. */
      nTot := 0
      BEGIN SEQUENCE WITH {| e | Break( e ) }
         nTot := RecCount()
      RECOVER
         nTot := 0
      END SEQUENCE
      cVal := "Tag " + cTag + ": " + LTrim( Str( nTot ) ) + " records"
      UiProgBegin( "Creating Index " + cFile, 1, .F. )
      UiProgUpdate( 0, 1, cVal )
      BEGIN SEQUENCE WITH {| e | Break( e ) }
         /* same FOR (positions 1 and 2 of OrdCondSet(), the only ones this
          * build applies) and then the flags: UNIQUE in the 5th parameter of
          * OrdCreate() and DESCEND with the dbOrderInfo() setter (see
          * AGENTS.md 5.32) */
         IF Empty( cFor )
            OrdCondSet()
         ELSE
            OrdCondSet( cFor, &( "{|| " + cFor + " }" ) )
         ENDIF
         OrdCreate( cBag, cTag, cExpr, ;
                    &( "{|| " + cExpr + " }" ), lUni )
         IF lDesc
            dbOrderInfo( DBOI_ISDESC, , dbOrderInfo( DBOI_ORDERCOUNT ), .T. )
         ENDIF
      RECOVER USING oErr
         lOk := .F.
         cErr := oErr:Description
      END SEQUENCE
      UiProgUpdate( 1, 1, cVal )
      BpLog( "BpIdxCreate: OrdCreate ok=" + hb_CStr( lOk ) + " err=" + cErr )
      UiProgEnd()
   ENDIF
   RestScreen( nT - 1, nL - 1, Min( MaxRow(), nB + 2 ), ;
               Min( MaxCol(), nR + 2 ), cSave )
   SetColor( UI_C_DESKTOP )
   IF ! lOk
      IF ! Empty( cErr )
         UiErr( cErr, "Create Index File" )
      ENDIF
      RETURN NIL
   ENDIF
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      dbGoTop()
   RECOVER
   END SEQUENCE
   CoreStatus()
RETURN NIL

/* =====================================================================
 *  F3 - Recreate Index File
 * ===================================================================== */

/* distinct index FILES of a definition list (BpTagDefs( .T. )), UPPER CASED
 * and in the order they are first seen: it is exactly the file list
 * StructRecreateIndexes() builds for itself, so the number of steps of the
 * progress bar and the texts of the confirmation and of the result match the
 * engine. */
STATIC FUNCTION BpIdxBagPaths( aDef )
   LOCAL aList := {}, i, c
   FOR i := 1 TO Len( aDef )
      c := aDef[ i ][ 6 ]
      IF ValType( c ) == "C" .AND. ! Empty( c ) .AND. ;
         AScan( aList, {| x | x == Upper( c ) } ) == 0
         AAdd( aList, Upper( c ) )
      ENDIF
   NEXT
RETURN aList

/* "CLIENTES.CDX, OTRO.NTX" of the list above, WITHOUT the path: it is the
 * name the engine shows in its "Deleting " progress line and the one the user
 * has to read in the confirmation and in the result message. */
STATIC FUNCTION BpIdxBagNames( aBags )
   LOCAL c := "", i
   FOR i := 1 TO Len( aBags )
      c += iif( Empty( c ), "", ", " ) + Upper( hb_FNameNameExt( aBags[ i ] ) )
   NEXT
RETURN c

/* F3 > "Recreate Index File": the index FILE of the open database is DELETED
 * and built again from scratch. This is not the Alt-R reindex in place: here
 * the old file is moved aside and a brand new one is created, which is the
 * only way to make an order that is no longer in the definition disappear, and
 * it covers a multi order .CDX and an .NTX through the same path.
 *
 * The work area MUST be closed before calling the engine: Windows does not let
 * an index file that the RDD still holds be renamed or deleted. The engine
 * moves the old files to <index>.IDXBAK, opens the database with no index,
 * creates every order again and, on any failure, gives the old files back byte
 * for byte (see StructRecreateIndexes() in bp_struct.prg). Because of that the
 * progress bar CANNOT be cancelled: stopping halfway would leave the database
 * with a half built index. */
FUNCTION BpIdxRecreate()
   LOCAL aDef, aBags, aRes, i, cFile, cAlias, cBase, cOrd, nRec
   LOCAL lOk, cSave, aP, nSteps, cFiles := "", cTags := ""
   IF ! BpNeedDb()
      RETURN NIL
   ENDIF
   /* "there is no index" is "there is no TAG at all", NOT "there is no
    * control order": CoreKeyExpr() is empty whenever the area is in natural
    * order, which is exactly the state the Index File Selection leaves with
    * Del/Alt-K and the one <None> leaves in the Tag Selection, with the bags
    * STILL attached (AGENTS.md 5.31 and 7.6). Asking DBOI_ORDERCOUNT for the
    * tag count keeps the behaviour of the sibling Alt-R (BpTagReindex()), which
    * never refused in that state. */
   IF BpTagTotal() == 0
      UiMsg( "No Open Index Files", "Recreate Index File" )
      RETURN NIL
   ENDIF
   /* the file cannot be touched while another process holds the database */
   IF ! BpIdxNeedExclusive( "Recreate Index File" )
      RETURN NIL
   ENDIF
   /* FULL paths: the engine deletes and recreates those files, so the bag name
    * without path would be useless (and dangerous) */
   aDef := BpTagDefs( .T. )
   IF Empty( aDef )
      UiMsg( "No Open Index Files", "Recreate Index File" )
      RETURN NIL
   ENDIF
   /* state of the area, to leave it in the same order and record afterwards */
   cFile  := CoreFileName()          /* real file path: DBF() gives the ALIAS */
   cAlias := Alias()
   cBase  := CoreFileBase()          /* the index bag has the file name     */
   cOrd   := Upper( OrdName() )
   nRec   := RecNo()
   /* SAFETY GUARD, before touching anything: a tag whose bag path cannot be
    * resolved, or whose bag path is the database itself, would make the engine
    * delete the wrong file. Nothing is deleted in that case. */
   FOR i := 1 TO Len( aDef )
      IF Empty( aDef[ i ][ 6 ] ) .OR. ;
         Upper( aDef[ i ][ 6 ] ) == Upper( cFile )
         UiErr( "The index file of " + aDef[ i ][ 1 ] + " cannot be resolved." + ;
                hb_eol() + "Nothing was deleted.", "Recreate Index File" )
         RETURN NIL
      ENDIF
   NEXT
   /* the files that are going to be deleted and how many orders come back:
    * the user has to know before the file is destroyed (the records are not
    * touched, which the message says too) */
   aBags  := BpIdxBagPaths( aDef )
   cFiles := BpIdxBagNames( aBags )
   IF ! UiConfirm( "Delete the index file(s) and create them again from scratch?" + ;
                   hb_eol() + "   " + cFiles + hb_eol() + ;
                   LTrim( Str( Len( aDef ) ) ) + " order(s) will be created again. " + ;
                   "The records are not touched.", "Recreate Index File" )
      RETURN NIL
   ENDIF
   /* the area has to be CLOSED: Windows does not let an index file the RDD
    * still holds be renamed or deleted, which is what the engine does first */
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      CLOSE
   RECOVER
   END SEQUENCE
   /* progress box: the rectangle comes from UiProgRect() (bp_ui.prg) and the
    * save/restore is the one of BpIdxVerify(), because UiProgEnd() does not
    * erase the box */
   aP := UiProgRect()
   cSave := SaveScreen( aP[ 1 ], aP[ 2 ], Min( MaxRow(), aP[ 3 ] + 1 ), ;
                        Min( MaxCol(), aP[ 4 ] + 2 ) )
   /* same plan as StructRecreateIndexes(): one step per distinct index file, one
    * to open the database, one per tag and one to finish. OrdCreate() reports
    * no progress per record and OrdKeyAdd() does not exist in this build
    * (AGENTS.md 5.32), so the detail goes in the text line that the engine
    * sends through the codeblock below. It is NOT cancellable (lCancel = .F.). */
   nSteps := Len( aBags ) + 1 + Len( aDef ) + 1
   UiProgBegin( "Recreating " + Upper( cBase ) + ".DBF", nSteps, .F. )
   /* UiProgBegin() paints the text line EMPTY, so the first frame of a step
    * based job would read "0 / 6 records 0%". One update with the real state
    * opens the box with a line that says what is happening. */
   UiProgUpdate( 0, nSteps, "Preparing " + Upper( cBase ) + ".DBF" )
   lOk := StructRecreateIndexes( cFile, aDef, ;
                                 {| nStep, nTotal, cText | UiProgUpdate( nStep, nTotal, cText ) } )
   UiProgEnd()
   RestScreen( aP[ 1 ], aP[ 2 ], Min( MaxRow(), aP[ 3 ] + 1 ), ;
               Min( MaxCol(), aP[ 4 ] + 2 ), cSave )
   SetColor( UI_C_DESKTOP )
   /* the area is closed: open the database again keeping order and record */
   IF ! BpDbReopen( cFile, cAlias, cBase, nRec, cOrd )
      UiErr( "Could not reopen " + Upper( cBase ) + ".DBF" + hb_eol() + ;
             "Open it again from the file manager.", "Recreate Index File" )
      CoreStatus()
      RETURN NIL
   ENDIF
   IF lOk
      UiMsg( "Index file recreated:" + hb_eol() + "   " + cFiles + hb_eol() + ;
             LTrim( Str( Len( aDef ) ) ) + " order(s) created again.", ;
             "Recreate Index File" )
   ELSE
      /* the engine gave the old index files back byte for byte: the tags it
       * could not create are the ones the result reports as DROPPED */
      aRes := StructRecreateResult()
      FOR i := 1 TO Len( aRes )
         IF ValType( aRes[ i ] ) == "A" .AND. Len( aRes[ i ] ) >= 2 .AND. ;
            aRes[ i ][ 2 ] == "DROPPED"
            cTags += iif( Empty( cTags ), "", ", " ) + aRes[ i ][ 1 ]
         ENDIF
      NEXT
      IF Empty( cTags )
         cTags := "no order could be created"
      ENDIF
      UiErr( "Could not recreate the index file(s):" + hb_eol() + cTags + hb_eol() + ;
             "The previous index file was kept.", "Recreate Index File" )
   ENDIF
   CoreStatus()
RETURN NIL

/* "Verify Index File Integrity": walks the active order comparing the number of
 * keys the engine reports with the ones really walked. The texts are
 * the ones of the dump (057AF9 " verified. ", 057E90 "Verifying ", 057F0B
 * " <Esc>=Cancel ", 057FA3 "No problems found", 057DAB "Key mismatch",
 * 057F5A "   Offending record number: "). */
FUNCTION BpIdxVerify()
   LOCAL n := 0, oErr, lOk := .T., nTotal := 0, cBag := "", lCancel := .F.
   LOCAL cErr := "", cSave, aP
   IF ! BpNeedDb() ; RETURN NIL ; ENDIF
   IF Empty( CoreKeyExpr() )
      UiMsg( "No Open Index Files", "Verify Index File Integrity" )
      RETURN NIL
   ENDIF
   cBag := BpTagBagFile( BpTagCur() )
   /* The progress box covers the screen and UiProgEnd() does NOT erase it: the
    * zone is saved to repaint what is under it before showing the result (if
    * not, the message appears over the remains of the bar). The rectangle is
    * the one UiProgBegin() really paints (box + shadow): UiProgRect() is its
    * only source, this used to be a literal of the old 80x25 grid. */
   aP := UiProgRect()
   cSave := SaveScreen( aP[ 1 ], aP[ 2 ], Min( MaxRow(), aP[ 3 ] + 1 ), ;
                        Min( MaxCol(), aP[ 4 ] + 2 ) )
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      nTotal := OrdKeyCount()
      dbGoTop()
      UiProgBegin( "Verifying " + cBag, nTotal )
      DO WHILE ! Eof() .AND. ! lCancel
         n++
         SKIP
         lCancel := UiProgUpdate( n, nTotal )
      ENDDO
   RECOVER USING oErr
      lOk := .F.
      cErr := oErr:Description
   END SEQUENCE
   UiProgEnd()
   RestScreen( aP[ 1 ], aP[ 2 ], Min( MaxRow(), aP[ 3 ] + 1 ), ;
               Min( MaxCol(), aP[ 4 ] + 2 ), cSave )
   SetColor( UI_C_DESKTOP )
   IF ! lOk
      UiErr( "Key mismatch" + hb_eol() + "   Offending record number: " + ;
             LTrim( Str( n ) ) + hb_eol() + cErr, "Verify Index File Integrity" )
      RETURN NIL
   ENDIF
   IF lCancel
      CoreStatus()
      RETURN NIL
   ENDIF
   IF n == nTotal
      UiMsg( cBag + " verified." + hb_eol() + "No problems found", ;
             "Verify Index File Integrity" )
   ELSE
      UiMsg( "Key mismatch" + hb_eol() + "   Offending record number: " + ;
             LTrim( Str( n ) ), "Verify Index File Integrity" )
   ENDIF
   CoreStatus()
RETURN NIL

/* ---- FileSpec form geometry (native 120x44 canvas) -------------------
 * The two FileSpec forms (F2 Database / F3 Index) share the composition
 * measured on the 80x25 original: a box of 8 rows x 47 columns (rows 12..19 /
 * columns 17..63 there), the label in row 15 and the 13-character field in
 * columns 40..52. Nothing is added or removed: only the origin comes from the
 * canvas, so FSPEC_R()/FSPEC_C() translate the measured row/column into the
 * centred box. */
#define FSPEC_H         8
#define FSPEC_W        47
#define FSPEC_R( __r )  ( nT + ( __r ) - 12 )
#define FSPEC_C( __c )  ( nL + ( __c ) - 17 )

/* "Index FileSpec": form of the original, sibling of the F2 one (Database
 * FileSpec). Dump 03B2CD: "Index ~FileSpec:      " */
FUNCTION BpIdxFileSpec()
   LOCAL c, cSave
   LOCAL nT := UiFitRow( UiCenterRow( FSPEC_H ), FSPEC_H + 1 )
   LOCAL nL := UiFitCol( UiCenterCol( FSPEC_W ), FSPEC_W + 2 )
   LOCAL nB := nT + FSPEC_H - 1, nR := nL + FSPEC_W - 1
   cSave := SaveScreen( nT - 1, nL - 1, Min( MaxRow(), nB + 2 ), ;
                        Min( MaxCol(), nR + 2 ) )
   UiPaintBegin()
   UiFormBox( nT, nL, nB, nR )
   UiWrite( FSPEC_R( 15 ), FSPEC_C( 20 ), "Index FileSpec:", UI_C_DLG )
   UiPaintEnd()
   c := UiFormEdit( FSPEC_R( 15 ), FSPEC_C( 40 ), 13, CoreIdxSpec(), .F. )
   RestScreen( nT - 1, nL - 1, Min( MaxRow(), nB + 2 ), ;
               Min( MaxCol(), nR + 2 ), cSave )
   IF c != NIL .AND. ! Empty( c )
      CoreSetIdxSpec( c )
   ENDIF
RETURN NIL

/* =====================================================================
 *  F4 - Fields
 * ===================================================================== */

/* =====================================================================
 *  F4 - Field Selection Screen
 * ---------------------------------------------------------------------
 *  Anti-flicker (AGENTS.md §"Repaint / anti-flicker"): the whole screen
 *  is painted ONLY on entry or when scrolling the window; when moving the cursor
 *  **only the two rows** that change are repainted and with A/N all the rows, but
 *  in a SINGLE paint block (one REFRESH per key). Before, the loop
 *  redrew frame, header, the 18 rows and the help on every key, outside
 *  any block: that is why it flickered when moving between the fields.
 * ===================================================================== */

/* Geometry of the Field Selection Screen, derived from the canvas instead of
 * the 80x25 measurements (rule S15). The composition of the original is kept:
 * the title is painted over the TOP border, then one header row, then the
 * list, and the hints are the LAST interior row, directly above the bottom
 * border.
 *
 * HEIGHT: the canvas rows are used (a 111-field table really needs them and
 * scrolls). WIDTH: the box is sized to what it RENDERS and centred with
 * UiCenterCol() — it does not span the canvas, so it is not a wide box full of
 * empty space. The content width is measured from the three things this box
 * draws (one list line, the column header and the hints line) by
 * BpFldSelectTxtW(), and capped so the centred box always leaves FST_MARG
 * blank columns at each side of the canvas.
 *
 * The list can NEVER reach the hint row: FST_ROWS is exactly the number of
 * rows between FST_TOP and FST_HELP, so the last list row is FST_HELP-1. That
 * is the defect that made the hints disappear when repainting with A/N in the
 * old fixed 17-row version (an 18th row landed on the help line).
 *
 * On the 120x44 canvas (MaxCol()=119, MaxRow()=43) the longest rendered line is
 * the hints line (57 columns; a list line is 38 and the header 43), so the
 * text area is 57 and the box 61 columns wide: 29..89, rows 3..42, header on
 * row 4, list rows 5..40 (36 visible rows, up from 17) and hints on row 41.
 * MaxRow() stays outside the box, so the status line under it keeps showing. */
#define FST_T       3                  /* top row of the box (title)          */
#define FST_B       ( MaxRow() - 1 )   /* bottom row of the box               */
#define FST_TOP     ( FST_T + 2 )      /* first list row (title + header)     */
#define FST_HELP    ( FST_B - 1 )      /* hints: last interior row            */
#define FST_ROWS    ( Max( 1, FST_HELP - FST_TOP ) )
#define FST_MARG    2                  /* min blank columns at each side      */
#define FST_PAD     2                  /* blank columns inside the border     */
#define FST_NAMEW   14                 /* name column of a list line          */
#define FST_HEADER  "  Sel  No   Name           Type  Len    Dec"
#define FST_HINTS   "<Space> check/uncheck   <A>ll   <N>one   <Enter/Esc> exit"

/* Text width of the box: the widest thing it renders — one list line (its fixed
 * columns plus the widest decimals present in the structure), the column header
 * or the hints line — capped so the centred box fits the canvas with FST_MARG
 * blank columns at each side. */
STATIC FUNCTION BpFldSelectTxtW( aSt )
   LOCAL i, nDec := 1, nW
   FOR i := 1 TO Len( aSt )
      nDec := Max( nDec, Len( LTrim( Str( aSt[ i ][ 4 ] ) ) ) )
   NEXT
   /* layout of one line of BpFldSelectRow:
    * "  [X]  " (7) + No (4) + " " + Name + " " + Type + "  " + Len (5) +
    * "  " + Dec */
   nW := Max( Max( Len( FST_HEADER ), Len( FST_HINTS ) ), ;
              7 + 4 + 1 + FST_NAMEW + 1 + 1 + 2 + 5 + 2 + nDec )
RETURN Min( nW, UiCols() - 2 * ( FST_MARG + FST_PAD ) )

/* one row of the table, without its own paint block (the caller opens it) */
STATIC PROCEDURE BpFldSelectRow( aSt, nIdx, nTop, nSel, nL, nTxtW )
   LOCAL lShow := .F., cLine
   IF nIdx < 1 .OR. nIdx > Len( aSt )
      RETURN
   ENDIF
   IF nIdx <= Len( CoreSelFields() )
      lShow := CoreSelFields()[ nIdx ]
   ENDIF
   SetColor( iif( nIdx == nSel, UI_C_BOXSEL, UI_C_BOX ) )
   cLine := "  [" + iif( lShow, "X", " " ) + "]  " + ;
            PadR( LTrim( Str( nIdx ) ), 4 ) + " " + ;
            PadR( aSt[ nIdx ][ 1 ], FST_NAMEW ) + " " + ;
            aSt[ nIdx ][ 2 ] + "  " + ;
            PadR( LTrim( Str( aSt[ nIdx ][ 3 ] ) ), 5 ) + "  " + ;
            LTrim( Str( aSt[ nIdx ][ 4 ] ) )
   @ FST_TOP + nIdx - nTop, nL + FST_PAD SAY PadR( cLine, nTxtW )
   SetColor( UI_C_DESKTOP )
RETURN

/* full screen: frame, header, rows and help in ONE paint block */
STATIC PROCEDURE BpFldSelectDraw( aSt, nSel, nTop, nVis, nL, nR, nTxtW )
   LOCAL i
   UiPaintBegin()
   UiFillBox( FST_T, nL, FST_B, nR, UI_C_BOX )
   UiFrame( FST_T, nL, FST_B, nR, UI_C_BOX, .T. )
   SetColor( UI_C_BOX )
   @ FST_T, nL + FST_PAD SAY " Field Selection Screen "
   @ FST_T + 1, nL + FST_PAD SAY PadR( FST_HEADER, nTxtW )
   FOR i := 1 TO nVis
      IF nTop + i - 1 <= Len( aSt )
         BpFldSelectRow( aSt, nTop + i - 1, nTop, nSel, nL, nTxtW )
      ELSE
         SetColor( UI_C_BOX )
         @ FST_TOP + i - 1, nL + FST_PAD SAY Space( nTxtW )
         SetColor( UI_C_DESKTOP )
      ENDIF
   NEXT
   SetColor( UI_C_HINT )
   @ FST_HELP, nL + FST_PAD SAY PadR( FST_HINTS, nTxtW )
   SetColor( UI_C_DESKTOP )
   UiPaintEnd()
RETURN

FUNCTION BpFldSelectScreen()
   LOCAL aSt, i, nKey, cSave, nSel := 1, nVis, nTop := 1, nPrev
   LOCAL lClosed := .F., nPt, nHit, nWheel
   LOCAL lFull := .T., lRows := .F., nOld := 0, lAll, cOldCur
   LOCAL nL, nR, nTxtW, nST, nSB, nSL, nSR
   IF ! BpNeedDb() ; RETURN NIL ; ENDIF
   aSt := DbStruct()
   IF Empty( CoreSelFields() )
      CoreInitView()
   ENDIF
   /* Visible rows derived from the box, never written down: the list occupies
    * FST_TOP..FST_HELP-1, so its last row can never land on the hint row
    * (FST_HELP), which is what hid the hints with A/N in the fixed 17-row
    * version. */
   nVis := FST_ROWS
   /* Width from the content and centred; the saved rectangle is computed from
    * the SAME variables as the box (and clamped to the canvas), so a box that
    * changes size can never leave half of itself restored. */
   nTxtW := BpFldSelectTxtW( aSt )
   nL := UiCenterCol( nTxtW + 2 * FST_PAD )
   nR := nL + nTxtW + 2 * FST_PAD - 1
   nST := FST_T ; nSL := nL
   nSB := Min( MaxRow(), FST_B ) ; nSR := Min( MaxCol(), nR )
   cSave := SaveScreen( nST, nSL, nSB, nSR )
   /* just like the database selection: the system cursor is hidden while the
    * screen is open (the screen paints its own highlight) */
   cOldCur := SetCursor( 0 )
   DO WHILE .T.
      /* the cursor always visible: if it leaves the window, it scrolls */
      IF nSel < nTop
         nTop := nSel ; lFull := .T.
      ENDIF
      IF nSel > nTop + nVis - 1
         nTop := nSel - nVis + 1 ; lFull := .T.
      ENDIF
      /* ---- painting: a single REFRESH per key ---- */
      IF lFull
         BpFldSelectDraw( aSt, nSel, nTop, nVis, nL, nR, nTxtW )
      ELSEIF lRows
         UiPaintBegin()
         FOR i := 1 TO nVis
            BpFldSelectRow( aSt, nTop + i - 1, nTop, nSel, nL, nTxtW )
         NEXT
         UiPaintEnd()
      ELSEIF nOld > 0
         UiPaintBegin()
         BpFldSelectRow( aSt, nOld, nTop, nSel, nL, nTxtW )
         IF nOld != nSel
            BpFldSelectRow( aSt, nSel, nTop, nSel, nL, nTxtW )
         ENDIF
         UiPaintEnd()
      ENDIF
      lFull := .F. ; lRows := .F. ; nOld := 0
      /* ---- keyboard ---- */
      nPrev := nSel
      /* S1/S4 (window-close.md B4): the X of the window (BpWaitKey) leaves
       * through the SAME exit <Esc> uses -EXIT-, so the tail below still applies
       * its rules and restores the screen; no `Exit hwBro?` is asked (L7). An
       * idle slice does not reach the DO CASE, so nothing is repainted. */
      nKey := BpWaitKeyMs( 0.05, @lClosed )
      IF nKey == 0
         IF lClosed
            EXIT
         ENDIF
         /* S10 of odd/tasks/commander-cleanup.md: the MOUSE, in the idle slice.
          * EVERY click marks or clears that field and leaves the cursor there, so
          * the shading follows the pointer like a cursor and never stays behind on
          * a row that was clicked before (both things asked for by the user).
          * ⚠ The double-click flag is NOT consulted: it used to suppress the
          * second click, and a second click on the same row is exactly how the
          * user puts the X back - it did nothing ("ahi mismo hago click para
          * poner la X y no la pone", reported). Each click is one toggle.
          * The wheel moves one row. `A`/`N` (all/none), `Enter` and `Esc` stay on
          * the keyboard and on the hints. */
         nPt := UiClick()
         IF HB_ISARRAY( nPt )
            IF nPt[ 1 ] >= FST_TOP .AND. nPt[ 1 ] <= FST_TOP + nVis - 1 .AND. ;
               nPt[ 2 ] >= nL .AND. nPt[ 2 ] <= nR
               nHit := nTop + ( nPt[ 1 ] - FST_TOP )
               IF nHit >= 1 .AND. nHit <= Len( aSt )
                  IF nHit <= Len( CoreSelFields() )
                     CoreSelFields()[ nHit ] := ! CoreSelFields()[ nHit ]
                  ENDIF
                  /* the cursor GOES with the click: the row it leaves and the row
                   * it takes are the two that get repainted */
                  nOld := nSel
                  nSel := nHit
               ENDIF
            ENDIF
            LOOP
         ENDIF
         nWheel := UiMouseWheel()
         IF nWheel != 0
            /* ⚠ the repaint is armed HERE: the key path arms it after its DO
             * CASE, and this branch LOOPs before reaching that line, so the
             * wheel moved nSel without painting anything - measured: the wheel
             * "did nothing" (reported by the user). */
            nHit := nSel
            nSel := Min( Max( 1, nSel - nWheel ), Len( aSt ) )
            IF nSel != nHit
               nOld := nHit
            ENDIF
            LOOP
         ENDIF
         LOOP
      ENDIF
      DO CASE
      CASE nKey == K_ESC .OR. nKey == K_ENTER
         EXIT
      CASE nKey == K_UP   ; nSel := Max( 1, nSel - 1 )
      CASE nKey == K_DOWN ; nSel := Min( Len( aSt ), nSel + 1 )
      CASE nKey == K_PGUP ; nSel := Max( 1, nSel - nVis )
      CASE nKey == K_PGDN ; nSel := Min( Len( aSt ), nSel + nVis )
      CASE nKey == K_SPACE
         IF nSel <= Len( CoreSelFields() )
            CoreSelFields()[ nSel ] := ! CoreSelFields()[ nSel ]
         ENDIF
      CASE Upper( Chr( nKey ) ) == "A"
         FOR i := 1 TO Len( CoreSelFields() )
            CoreSelFields()[ i ] := .T.
         NEXT
         lRows := .T.
      CASE Upper( Chr( nKey ) ) == "N"
         FOR i := 1 TO Len( CoreSelFields() )
            CoreSelFields()[ i ] := .F.
         NEXT
         lRows := .T.
      ENDCASE
      IF nSel != nPrev
         nOld := nPrev          /* repaint only the rows that changed */
      ELSEIF ! lRows
         /* Space toggles the mark of the current field: only that row */
         nOld := nSel
      ENDIF
   ENDDO
   /* The selection RULES: on exit, if any field is left unmarked it switches to
    * "Selected Flds" (and if all are marked, to "All Fields"), which is what the
    * user expects when unmarking fields here; before one had to go to F4 ->
    * "Selected Flds" by hand and it looked like the selection was not taken. */
   lAll := .T.
   FOR i := 1 TO Len( CoreSelFields() )
      IF ! CoreSelFields()[ i ]
         lAll := .F.
         EXIT
      ENDIF
   NEXT
   CoreSetShowSelected( ! lAll )
   RestScreen( nST, nSL, nSB, nSR, cSave )
   SetCursor( cOldCur )
   SetColor( UI_C_DESKTOP )
RETURN NIL

FUNCTION BpFldColumnOptions()
   LOCAL aSt, n, c
   IF ! BpNeedDb() ; RETURN NIL ; ENDIF
   aSt := DbStruct()
   c := UiInput( "Field number:", "1", 4 )
   IF c == NIL .OR. Empty( c ) ; RETURN NIL ; ENDIF
   n := Val( c )
   IF n < 1 .OR. n > Len( aSt )
      UiErr( "Field does not exist." )
      RETURN NIL
   ENDIF
   UiInfo( "Field: " + aSt[ n ][ 1 ] + hb_eol() + ;
           "Type: " + aSt[ n ][ 2 ] + hb_eol() + ;
           "Len: " + LTrim( Str( aSt[ n ][ 3 ] ) ) + hb_eol() + ;
           "Dec: " + LTrim( Str( aSt[ n ][ 4 ] ) ), "Column Options" )
RETURN NIL

/* =====================================================================
 *  F5 - AreaSet
 * ===================================================================== */

FUNCTION BpAreaRangeFilter()
   LOCAL c := UiInput( "Filter (SET FILTER):", "", 50 )
   LOCAL oErr
   IF c == NIL ; RETURN NIL ; ENDIF
   IF ! BpNeedDb() ; RETURN NIL ; ENDIF
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      SET FILTER TO &( c )
      GO TOP
      UiInfo( "Filter applied." + hb_eol() + "Visible records: " + LTrim( Str( LastRec() ) ), "Range & Filter" )
   RECOVER USING oErr
      UiErr( "Invalid filter:" + hb_eol() + oErr:Description )
   END SEQUENCE
RETURN NIL

FUNCTION BpAreaRelation()
   LOCAL a := CoreAreas(), aN := {}, i, c
   IF ! BpNeedDb() ; RETURN NIL ; ENDIF
   IF Len( a ) < 2
      UiMsg( "At least two open areas are needed.", "Relation" )
      RETURN NIL
   ENDIF
   FOR i := 1 TO Len( a )
      AAdd( aN, LTrim( Str( a[ i ][ 1 ] ) ) + "  " + a[ i ][ 2 ] )
   NEXT
   i := UiPick( aN, "Related area" )
   IF i == 0 ; RETURN NIL ; ENDIF
   c := UiInput( "Relation expression (e.g. CLI_NUMERO):", "", 40 )
   IF c == NIL .OR. Empty( c ) ; RETURN NIL ; ENDIF
   SET RELATION TO &( c ) INTO ( a[ i ][ 2 ] )
   UiInfo( "Relation set with " + a[ i ][ 2 ], "Relation" )
RETURN NIL

FUNCTION BpAreaColorCond()
   LOCAL c, cc
   IF ! BpNeedDb() ; RETURN NIL ; ENDIF
   c := UiInput( "Color condition (xBase expression, empty = remove):", CoreColorCond(), 50 )
   IF c == NIL ; RETURN NIL ; ENDIF
   IF Empty( c )
      CoreSetColorCond( "" )
      UiInfo( "Color condition removed.", "Color Condition" )
      RETURN NIL
   ENDIF
   cc := UiInput( "Color (e.g. W+/RB, GR+/B, N/W):", CoreColorColor(), 10 )
   IF cc == NIL ; RETURN NIL ; ENDIF
   CoreSetColorCond( c )
   CoreSetColorColor( cc )
   UiInfo( "Active color condition:" + hb_eol() + c + "   ->   " + CoreColorColor(), "Color Condition" )
RETURN NIL

FUNCTION BpAreaToggleIncr()
   UiMsg( "Incremental Seek: " + iif( CoreToggleIncrSeek(), "ON", "OFF" ), "AreaSet" )
RETURN NIL

FUNCTION BpAreaMemoWidth()
   LOCAL c := UiInput( "Memo Width:", LTrim( Str( CoreMemoWidth() ) ), 4 )
   IF c != NIL .AND. ! Empty( c ) ; CoreSetMemoWidth( Val( c ) ) ; ENDIF
RETURN NIL

FUNCTION BpAreaMemoPack()
   LOCAL oErr
   IF ! BpNeedDb() ; RETURN NIL ; ENDIF
   IF ! UiConfirm( "Pack the memo file ?", "Memo Pack" ) ; RETURN NIL ; ENDIF
   UiProgBusy( "Packing memo..." )
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      hb_dbPack()
      UiProgEnd()
      UiInfo( "Memo packed.", "Memo Pack" )
   RECOVER USING oErr
      UiProgEnd()
      UiErr( "Error: " + oErr:Description )
   END SEQUENCE
RETURN NIL

FUNCTION BpAreaSelect()
   LOCAL a := CoreAreas(), aN := {}, i
   FOR i := 1 TO Len( a )
      AAdd( aN, PadR( LTrim( Str( a[ i ][ 1 ] ) ), 3 ) + a[ i ][ 2 ] + "   " + a[ i ][ 3 ] )
   NEXT
   IF Empty( aN )
      UiMsg( "No open areas.", "Select Area" )
      RETURN NIL
   ENDIF
   i := UiPick( aN, "Select Area" )
   IF i > 0
      SELECT ( a[ i ][ 1 ] )
      CoreStatus()
   ENDIF
RETURN NIL

FUNCTION BpAreaNextOrder()
   BpIdxNextOrder()
RETURN NIL

FUNCTION BpAreaViewInfo()
   LOCAL a := CoreAreas(), aL := {}, i
   IF Used()
      AAdd( aL, "Current area     : " + LTrim( Str( Select() ) ) + "   Alias: " + Alias() )
      AAdd( aL, "File             : " + DBF() )
      AAdd( aL, "Records          : " + LTrim( Str( LastRec() ) ) )
      AAdd( aL, "Current record  : " + LTrim( Str( RecNo() ) ) + iif( Deleted(), "  (borrado)", "" ) )
      AAdd( aL, "Fields           : " + LTrim( Str( FCount() ) ) + "   Rec len: " + LTrim( Str( RecSize() ) ) )
      AAdd( aL, "Active order     : " + iif( Empty( OrdName() ), "Natural Order", ;
               OrdName() + "  (" + dbOrderInfo( DBOI_EXPRESSION ) + ")" ) )
      AAdd( aL, "Filter           : " + dbFilter() )
      AAdd( aL, "" )
   ENDIF
   AAdd( aL, "Open areas:" )
   FOR i := 1 TO Len( a )
      AAdd( aL, "   " + PadR( LTrim( Str( a[ i ][ 1 ] ) ), 4 ) + PadR( a[ i ][ 2 ], 12 ) + a[ i ][ 3 ] )
   NEXT
   UiTextWin( aL, "Current View Info" )
RETURN NIL

/* =====================================================================
 *  F6 - GlobalSet
 * ===================================================================== */

FUNCTION BpGlobDriver()
   LOCAL n := UiPick( { "DBFCDX  (CDX/FPT - compatible FoxPro / SIx)", ;
                        "DBFNTX  (NTX/DBT - classic Clipper)" }, "Database Driver" )
   IF n == 1 ; CoreSetDriver( "DBFCDX" ) ; ENDIF
   IF n == 2 ; CoreSetDriver( "DBFNTX" ) ; ENDIF
RETURN NIL

/* S1/S2 of odd/tasks/globalset-date-format.md: the Date Format of the F6
 * GlobalSet. It opens the list of the fourteen pictures of the original with the
 * one IN FORCE highlighted, and Enter installs the chosen one with the SET DATE
 * FORMAT of the engine (S3), which is what the browse cell, every date value on
 * the screen and the date inputs already read - so there is no second rule to
 * keep in step. Esc leaves the format exactly as it was.
 * Everything it touches is a pure helper of bp_ui.prg (the list, the picture in
 * force, its index and the setter), so the bank pins the model without a window. */
FUNCTION BpGlobDateFormat()
   LOCAL aPics := UiDateFormats()
   LOCAL n := UiPick( aPics, "Date Format", UiDateFormatIdx( UiDateFormatName(), aPics ) )
   IF n >= 1 .AND. n <= Len( aPics )
      UiDateFormatSet( aPics[ n ] )
   ENDIF
RETURN NIL

/* S11 of odd/tasks/globalset-date-format.md: the Epoch of the F6 GlobalSet, the
 * base year of the window of the two-digit dates. The row shows the value LIVE
 * from the engine (UiDateEpoch()), and this asks for a new one with the same
 * shape as the other UiInput() rows of this menu: Esc leaves the value as it was
 * and an EMPTY answer is not a year either.
 * The rule is the pure UiDateEpochParse() of bp_ui.prg -a whole year between 1
 * and 9999, and nothing else- so the bank pins it without a window: when it
 * answers 0 nothing is written and the user is told why with UiErr(), which is
 * the same answer an empty, a non-numeric or an out-of-range entry gets. */
FUNCTION BpGlobEpoch()
   LOCAL c := UiInput( "Epoch (base year of two-digit dates):", ;
                       LTrim( Str( UiDateEpoch() ) ), 4 )
   LOCAL n
   IF ValType( c ) != "C"           /* Esc: the menu value does not change */
      RETURN NIL
   ENDIF
   n := UiDateEpochParse( c )
   IF n <= 0
      UiErr( "The epoch has to be a year between 1 and 9999." + ;
             iif( Empty( AllTrim( c ) ), "", hb_eol() + "Typed: " + AllTrim( c ) ), ;
             "Epoch" )
      RETURN NIL
   ENDIF
   UiDateEpochSet( n )
RETURN NIL

/* =====================================================================
 *  S137 - F6 > Theme Colors (odd/tasks/theme-color-overrides.md)
 *
 *  The user asked for "exceptions to the selected theme": pick one of the colour
 *  slots the program has (body, cursor, input, header...) and one of the colours
 *  of the palette, see it applied AT ONCE, and keep only that exception in
 *  hwbro.ini. So:
 *
 *   - the exception is a PAIR "text/background" and it wins over whichever theme
 *     is active (UiC() of bp_ui.prg). Text offers the 16 letters of the palette;
 *     the background offers the EIGHT surfaces of a VGA text mode cell - the
 *     eight base letters, which are the only surfaces the themes define (see
 *     UiPaletteBg()). A star in a background is still READ (gtwvg paints it) so
 *     an ini of the previous build keeps working, but the screen does not offer
 *     it.
 *   - choosing a colour APPLIES it in the act: the screen is painted with the
 *     UI_C_* pairs, so it changes as the user picks, and the preview block shows
 *     the pair on its own.
 *   - [ Accept ] keeps the exceptions for the SESSION and [ Cancel ] (Esc, the X
 *     of the window, a plain right click) puts back the snapshot taken on entry.
 *     Nothing is written to disk here: persistence is Save Configuration (F6, or
 *     Commander > Commands), which writes the exception lines of hwbro.ini.
 *
 *  Layout (120x44): the list of the 89 slots on the left - grouped, with the
 *  heading of each group and a scroll window -, the detail of the selected
 *  element on the right (the 16 x 16 MATRIX of the whole colour space, the pair line, the
 *  preview and the mock), the message row and the key chips at the bottom. No
 *  literal of the canvas: everything comes from MaxRow()/MaxCol() through
 *  BpTcGeom().
 * ===================================================================== */

/* state of the screen: aSt = { nFocus, nRow, nTop, nFg, nBg, cMsg, lErr } */
#define THX_FOCUS     1
#define THX_ROW       2
#define THX_TOP       3
#define THX_FG        4
#define THX_BG        5
#define THX_MSG       6
#define THX_ERR       7

/* stops of the focus ring, in the VISUAL order */
#define THF_LIST      1
#define THF_GRID      2
#define THF_ACCEPT    3
#define THF_CANCEL    4

/* geometry: { maxRow, maxCol, rule, msg, key1, key2, first, last, split,
 *             listL, listR, detL, detR, lbl, theme, now, flag, pal,
 *             gcol, gink, gtop, ghdr } */
#define THG_MAXR      1
#define THG_MAXC      2
#define THG_RULE      3
#define THG_MSG       4
#define THG_KEY1      5
#define THG_KEY2      6
#define THG_FIRST     7
#define THG_LAST      8
#define THG_SPLIT     9
#define THG_LISTL    10
#define THG_LISTR    11
#define THG_DETL     12
#define THG_DETR     13
#define THG_LBL      14
#define THG_THEME    15
#define THG_NOW      16
#define THG_FLAG     17
#define THG_GCOL     18          /* first column of the matrix              */
#define THG_GINK     19          /* column of the ink labels of the matrix  */
#define THG_GTOP     20          /* first row of the matrix                 */
#define THG_GHDR     21          /* row of the surface headers              */

#define TH_LBLW      40          /* cells of the element name in the list     */

/* The columns are derived, one from the next: the marker+label, then THEME (5),
 * then NOW (4) and the exception mark, all of them inside the left panel.
 * The last four are the 16 x 16 MATRIX of the detail panel: a 5-cell row-label
 * column (the INKS) and one 3-cell column per SURFACE, with a blank cell between
 * the 8 base ones and the 8 bright ones. */
STATIC FUNCTION BpTcGeom()
   LOCAL nMaxR := MaxRow(), nMaxC := MaxCol()
   LOCAL nRule  := nMaxR - 4
   LOCAL nSplit := Int( nMaxC / 2 ) + 2
   LOCAL nListL := 1
   LOCAL nListR := nSplit - 2
   LOCAL nDetL  := nSplit + 2
   LOCAL nLbl   := nListL + 1

RETURN { nMaxR, nMaxC, nRule, nRule + 1, nRule + 2, nRule + 3, ;
         4, nRule - 1, nSplit, nListL, nListR, nDetL, nMaxC - 2, ;
         nLbl, nLbl + TH_LBLW + 1, nLbl + TH_LBLW + 7, nLbl + TH_LBLW + 12, ;
         nDetL + 6, nDetL + 1, 7, 6 }

/* the row the cursor starts on: the first element that already carries an
 * exception (the screen opens where the work is), then the body of the panel,
 * then the first element. */
STATIC FUNCTION BpTcStart( aRows )
   LOCAL i

   FOR i := 1 TO Len( aRows )
      IF aRows[ i ][ 1 ] == 2 .AND. UiOvHas( aRows[ i ][ 2 ] )
         RETURN i
      ENDIF
   NEXT
   FOR i := 1 TO Len( aRows )
      IF aRows[ i ][ 1 ] == 2 .AND. aRows[ i ][ 2 ] == TC_DARK
         RETURN i
      ENDIF
   NEXT

RETURN UiSlotRowEdge( aRows, .F. )

/* slot of a row of the list, or 0 for the heading of a group */
STATIC FUNCTION BpTcSlot( aRows, nRow )
   IF ! HB_ISARRAY( aRows ) .OR. nRow < 1 .OR. nRow > Len( aRows )
      RETURN 0
   ENDIF
   IF aRows[ nRow ][ 1 ] != 2
      RETURN 0
   ENDIF
RETURN aRows[ nRow ][ 2 ]

/* puts the matrix cursor on the pair in force of the selected element, so the
 * screen always shows where that element stands. A pair outside the palette (it
 * cannot be one: the bank checks both theme tables) leaves the cursor where it
 * was instead of moving it to a lie. */
STATIC PROCEDURE BpTcSync( aSt, aRows )
   LOCAL nSlot := BpTcSlot( aRows, aSt[ THX_ROW ] )
   LOCAL aFg, aBg, a, i

   IF nSlot == 0
      RETURN
   ENDIF
   a := UiPairSplit( UiC( nSlot ) )
   IF Empty( a )
      RETURN
   ENDIF

   aFg := UiPaletteFg()
   aBg := UiPaletteBg()

   aSt[ THX_FG ] := 1
   FOR i := 1 TO Len( aFg )
      IF aFg[ i ][ 1 ] == a[ 1 ]
         aSt[ THX_FG ] := i
      ENDIF
   NEXT

   aSt[ THX_BG ] := 1
   FOR i := 1 TO Len( aBg )
      IF aBg[ i ][ 1 ] == a[ 2 ]
         aSt[ THX_BG ] := i
      ENDIF
   NEXT
RETURN

/* next stop of the ring (1 = forward, -1 = back), wrapping at both ends */
STATIC FUNCTION BpTcFocus( aSt, nDir )
   aSt[ THX_FOCUS ] += nDir
   IF aSt[ THX_FOCUS ] > THF_CANCEL
      aSt[ THX_FOCUS ] := THF_LIST
   ENDIF
   IF aSt[ THX_FOCUS ] < THF_LIST
      aSt[ THX_FOCUS ] := THF_CANCEL
   ENDIF
RETURN "paint"

/* <nCount> elements forward/back from <nRow> (one step at a time, so the group
 * headings are never a stop) */
STATIC FUNCTION BpTcMove( aRows, nRow, nCount )
   LOCAL i, n := nRow
   FOR i := 1 TO Abs( nCount )
      n := UiSlotRowStep( aRows, n, iif( nCount > 0, 1, -1 ) )
   NEXT
RETURN n

/* <n> brought into 1..<nMax> (the wheel of the matrix and the arrows share the
 * rule: the ends wrap instead of clamping) */
STATIC FUNCTION BpTcWrap( n, nMax )
   IF nMax < 1
      RETURN 1
   ENDIF
   DO WHILE n < 1
      n += nMax
   ENDDO
   DO WHILE n > nMax
      n -= nMax
   ENDDO
RETURN n

/* ---------- painting ---------- */

/* a button of the family of the forms: FLAT at rest, brown with the focus, and
 * the quick letter inside its own label */
STATIC PROCEDURE BpTcBtn( nRow, nCol, cLabel, lFoc, nId )
   LOCAL cPair := iif( lFoc, UI_C_BOXSEL, UI_C_FLATBG )
   LOCAL nW := UiHotLen( cLabel )
   SetColor( cPair )
   @ nRow, nCol SAY Space( nW )
   UiDrawHot( nRow, nCol, cLabel, cPair, iif( lFoc, UI_C_HOTSEL, UI_C_HOT ) )
   HcSyncCtlAdd( nRow, nCol, nW, "TBTN", nId )
RETURN

/* one <key>=action chip of the footer, registered as the KEY it announces */
STATIC FUNCTION BpTcChip( nRow, nCol, cKey, cAct )
   SetColor( UI_C_MENUKEY )
   @ nRow, nCol SAY "<" + cKey + ">"
   HcSyncCtlAdd( nRow, nCol, Len( cKey ) + 2, "KEY", cKey )
   SetColor( UI_C_MENUBAR )
   @ nRow, nCol + Len( cKey ) + 2 SAY cAct
RETURN nCol + Len( cKey ) + 2 + Len( cAct ) + 2

/* the whole screen, in ONE paint block */
STATIC PROCEDURE BpTcDraw( aG, aSt, aRows )
   LOCAL nFirst := aG[ THG_FIRST ], nLast := aG[ THG_LAST ]
   LOCAL nMaxC := aG[ THG_MAXC ], nDetL := aG[ THG_DETL ]
   LOCAL nDetW := aG[ THG_DETR ] - nDetL + 1
   LOCAL nListW := aG[ THG_LISTR ] - aG[ THG_LISTL ] + 1
   LOCAL nSlot, nIdx, nRow, nI, nJ, nR, aR, cTh, aFg, aBg, cPair, a, cMsg
   LOCAL nCol

   HcSyncCtlReset()
   UiPaintBegin()

   UiCls()

   /* row 0: the name of the screen and the theme in force */
   SetColor( UI_C_CHIP )
   @ 0, 1 SAY " Theme Colors "
   cTh := " Theme: " + UiThemeName() + " "
   @ 0, nMaxC - Len( cTh ) + 1 SAY cTh

   /* row 1: what an exception is, and row 2: the rule */
   SetColor( UI_C_DESKTOP )
   @ 1, 1 SAY "Exceptions win over the active theme; they follow it and stay when it changes."
   @ 2, 0 SAY Replicate( BP_LINE_SINGLE, nMaxC + 1 )

   /* the header of the list, on the band of every table of this program */
   SetColor( UI_C_HDR )
   @ 3, aG[ THG_LISTL ] SAY PadR( "  ELEMENT", nListW )
   @ 3, aG[ THG_THEME ] SAY "THEME"
   @ 3, aG[ THG_NOW ]   SAY "NOW "
   @ 3, aG[ THG_FLAG ]  SAY " "
   @ 3, nDetL SAY PadR( " SELECTED ELEMENT", nDetW )

   /* ---- the list, scrolled so the cursor is always visible ---- */
   IF aSt[ THX_ROW ] < aSt[ THX_TOP ]
      aSt[ THX_TOP ] := aSt[ THX_ROW ]
   ENDIF
   IF aSt[ THX_ROW ] > aSt[ THX_TOP ] + ( nLast - nFirst )
      aSt[ THX_TOP ] := aSt[ THX_ROW ] - ( nLast - nFirst )
   ENDIF
   IF aSt[ THX_TOP ] < 1
      aSt[ THX_TOP ] := 1
   ENDIF

   FOR nI := 0 TO nLast - nFirst
      nRow := nFirst + nI
      nIdx := aSt[ THX_TOP ] + nI
      SetColor( UI_C_DESKTOP )
      @ nRow, aG[ THG_LISTL ] SAY Space( nListW )
      IF nIdx >= 1 .AND. nIdx <= Len( aRows )
         aR := aRows[ nIdx ]
         IF aR[ 1 ] == 1
            /* the heading of a group: a rule with its name, in the pair of the
             * screen (no band: a group is a separator, not a control) */
            SetColor( UI_C_DESKTOP )
            @ nRow, aG[ THG_LISTL ] SAY PadR( " " + UiSlotGroupName( aR[ 2 ] ) + " ", ;
                                             nListW, BP_LINE_SINGLE )
         ELSE
            nSlot := aR[ 2 ]
            IF nIdx == aSt[ THX_ROW ]
               SetColor( UI_C_LISTSEL )
               @ nRow, aG[ THG_LISTL ] SAY Space( nListW )
            ENDIF
            /* the label: the cursor row is marked with "> ". Left() because PadR()
             * does NOT cut a string that is already longer (AGENTS trap: a label
             * that outgrows its column would push the pairs out of the row) */
            SetColor( iif( nIdx == aSt[ THX_ROW ], UI_C_LISTSEL, UI_C_DESKTOP ) )
            @ nRow, aG[ THG_LBL ] SAY PadR( Left( iif( nIdx == aSt[ THX_ROW ], "> ", "  " ) + ;
                                           UiSlotLabel( nSlot ), TH_LBLW ), TH_LBLW )
            @ nRow, aG[ THG_THEME ] SAY PadR( UiThemePair( nSlot ), 5 )
            @ nRow, aG[ THG_NOW ]   SAY PadR( UiC( nSlot ), 4 )
            IF UiOvHas( nSlot )
               @ nRow, aG[ THG_FLAG ] SAY "*"
            ENDIF
         ENDIF
      ENDIF
   NEXT

   /* ---- the detail of the selected element ---- */
   nSlot := BpTcSlot( aRows, aSt[ THX_ROW ] )
   SetColor( UI_C_DESKTOP )
   @ 4, nDetL SAY PadR( Left( UiSlotLabel( nSlot ), nDetW ), nDetW )
   @ 5, nDetL SAY Replicate( BP_LINE_SINGLE, nDetW )

   /* ---- the detail of the selected element: the 16 x 16 MATRIX ---- */
   /* header: the 16 SURFACES as columns, each one printed with a readable ink
    * over its own colour (its swatch pair), so `N` and `N*` are told apart at a
    * glance; the blank cell before the ninth column separates the 8 base
    * surfaces from the 8 bright ones */
   aBg := UiPaletteBg()
   SetColor( UI_C_DESKTOP )
   @ aG[ THG_GHDR ], aG[ THG_GINK ] SAY PadR( "Fg\Bg", 5 )
   FOR nI := 1 TO Len( aBg )
      nCol := aG[ THG_GCOL ] + ( nI - 1 ) * 3 + iif( nI > 8, 1, 0 )
      SetColor( UiPalSwatchPair( aBg[ nI ][ 1 ] ) )
      @ aG[ THG_GHDR ], nCol SAY PadC( aBg[ nI ][ 1 ], 3 )
   NEXT

   /* the matrix: EVERY cell is painted with its own pair, so what is under the
    * cursor is exactly what the element will look like, and the cells whose ink
    * and surface are the same read as a solid block (as the 16 x 16 table says). The
    * row label of the cursor carries the focus band - one focus, one colour -
    * and the cursor cell is painted with its pair SWAPPED, the language of every
    * editor of this program, so it is found on top of any colour */
   aFg := UiPaletteFg()
   FOR nI := 1 TO Len( aFg )
      nR := aG[ THG_GTOP ] + nI - 1
      SetColor( iif( aSt[ THX_FOCUS ] == THF_GRID .AND. aSt[ THX_FG ] == nI, ;
                     UI_C_LISTSEL, UI_C_DESKTOP ) )
      @ nR, aG[ THG_GINK ] SAY PadR( aFg[ nI ][ 1 ], 4 )
      FOR nJ := 1 TO Len( aBg )
         nCol := aG[ THG_GCOL ] + ( nJ - 1 ) * 3 + iif( nJ > 8, 1, 0 )
         cPair := aFg[ nI ][ 1 ] + "/" + aBg[ nJ ][ 1 ]
         SetColor( cPair )
         @ nR, nCol SAY PadC( aBg[ nJ ][ 1 ], 3 )
         IF nI == aSt[ THX_FG ] .AND. nJ == aSt[ THX_BG ]
            SetColor( UiSwapColor( cPair ) )
            @ nR, nCol SAY PadC( aBg[ nJ ][ 1 ], 3 )
         ENDIF
         /* every cell is registered, so a click means THAT combination */
         HcSyncCtlAdd( nR, nCol, 3, "TCEL", ( nI - 1 ) * 16 + nJ )
      NEXT
   NEXT

   /* every rule and every label sets its own pair: the last cell of the matrix
    * leaves the colour of ITS pair, and a rule painted with it would draw a band
    * of that colour across the panel (measured with the old strips) */
   nR := aG[ THG_GTOP ] + Len( aFg )
   SetColor( UI_C_DESKTOP )
   @ nR, nDetL SAY Replicate( BP_LINE_SINGLE, nDetW )

   /* the pair in force and the one of the theme, in one line */
   a := UiPairSplit( UiC( nSlot ) )
   cPair := iif( Empty( a ), UiC( nSlot ), a[ 1 ] + "/" + a[ 2 ] )
   @ nR + 1, nDetL SAY PadR( " Pair: " + cPair + "   Theme: " + UiThemePair( nSlot ) + ;
                            iif( UiOvHas( nSlot ), "  *", "" ), nDetW )

   @ nR + 2, nDetL SAY Replicate( BP_LINE_SINGLE, nDetW )

   /* the preview: the selected pair applied to text and to a block of cells */
   @ nR + 3, nDetL SAY PadR( " Preview", nDetW )
   SetColor( cPair )
   @ nR + 4, nDetL SAY PadR( " Aa Bb Cc 0123    ", nDetW )
   @ nR + 5, nDetL SAY Space( nDetW )

   SetColor( UI_C_DESKTOP )
   @ nR + 6, nDetL SAY Replicate( BP_LINE_SINGLE, nDetW )

   /* a small mock of the screens the elements belong to, each row with the pairs
    * it really uses: changing the menu bar, a record or an input is seen here at
    * once even when that element is not the selected one */
   SetColor( UI_C_MENUBAR )
   @ nR + 8, nDetL SAY PadR( "  Menu bar ", 22 )
   SetColor( UI_C_MENULBL )
   @ nR + 8, nDetL + 22 SAY " Label "
   SetColor( UI_C_MENUKEY )
   @ nR + 8, nDetL + 30 SAY " F1 "

   SetColor( UI_C_HDR )
   @ nR + 9, nDetL SAY PadR( "  Column header ", 22 )
   SetColor( UI_C_REC )
   @ nR + 9, nDetL + 22 SAY PadR( " record ", 14 )
   SetColor( UI_C_RECSEL )
   @ nR + 9, nDetL + 36 SAY " curr "
   SetColor( UI_C_CURSEL )
   @ nR + 9, nDetL + 42 SAY " cell "

   SetColor( UI_C_FIELDBG )
   @ nR + 10, nDetL SAY PadR( "  Input field ", 22 )
   SetColor( UI_C_ERR )
   @ nR + 10, nDetL + 22 SAY PadR( " error ", 14 )
   SetColor( UI_C_CHIP )
   @ nR + 10, nDetL + 36 SAY PadR( " chip ", 12 )

   SetColor( UI_C_DESKTOP )
   @ nR + 11, nDetL SAY Replicate( BP_LINE_SINGLE, nDetW )

   /* the whole contract of the screen, in the room the mock leaves free */
   @ nR + 13, nDetL SAY PadR( "Session only: Accept keeps them for this run.", nDetW )
   @ nR + 14, nDetL SAY PadR( "Save Configuration (F6) writes hwbro.ini.", nDetW )
   @ nR + 15, nDetL SAY PadR( "Reset (Alt-R) returns one to the theme.", nDetW )

   /* ---- the message row, and the two buttons at its right ---- */
   cMsg := aSt[ THX_MSG ]
   IF Empty( cMsg )
      cMsg := iif( UiOvCount() == 0, "No exception: every element follows the theme.", ;
                  LTrim( Str( UiOvCount() ) ) + " exception(s) in this session." )
   ENDIF
   SetColor( iif( aSt[ THX_ERR ], UI_C_ERR, UI_C_HDR ) )
   @ aG[ THG_MSG ], 0 SAY PadR( " " + Left( cMsg, nMaxC - 30 ), nMaxC - 27 )
   BpTcBtn( aG[ THG_MSG ], nMaxC - 25, "[ ~A~ccept ]", aSt[ THX_FOCUS ] == THF_ACCEPT, THF_ACCEPT )
   BpTcBtn( aG[ THG_MSG ], nMaxC - 12, "[ ~C~ancel ]", aSt[ THX_FOCUS ] == THF_CANCEL, THF_CANCEL )

   /* ---- the key chips ---- */
   SetColor( UI_C_MENUBAR )
   @ aG[ THG_KEY1 ], 0 SAY Space( nMaxC + 1 )
   @ aG[ THG_KEY2 ], 0 SAY Space( nMaxC + 1 )
   nCol := 1
   nCol := BpTcChip( aG[ THG_KEY1 ], nCol, "Enter", "Apply" )
   nCol := BpTcChip( aG[ THG_KEY1 ], nCol, "Tab", "Ring" )
   nCol := BpTcChip( aG[ THG_KEY1 ], nCol, "Alt-T", "Matrix" )
   nCol := BpTcChip( aG[ THG_KEY1 ], nCol, "Alt-R", "Reset" )
   nCol := BpTcChip( aG[ THG_KEY1 ], nCol, "Alt-L", "Reset all" )
   nCol := BpTcChip( aG[ THG_KEY1 ], nCol, "Ctrl-S", "Accept" )
   nCol := BpTcChip( aG[ THG_KEY1 ], nCol, "Esc", "Cancel" )

   nCol := 1
   nCol := BpTcChip( aG[ THG_KEY2 ], nCol, "F1", "Help" )
   SetColor( UI_C_MENUBAR )
   @ aG[ THG_KEY2 ], nCol SAY "Up/Down Inks  Left/Right Surfaces  Home/End   Wheel Rows   Click Pick"

   SetColor( UI_C_DESKTOP )
   UiPaintEnd()
RETURN

/* ---------- the actions ---------- */

/* pins the pair UNDER THE MATRIX CURSOR (ink + surface) on the selected element */
STATIC PROCEDURE BpTcApply( aSt, aRows )
   LOCAL nSlot := BpTcSlot( aRows, aSt[ THX_ROW ] )
   LOCAL cFg, cBg, cPair

   IF nSlot == 0
      RETURN
   ENDIF

   cFg := UiPaletteFg()[ aSt[ THX_FG ] ][ 1 ]
   cBg := UiPaletteBg()[ aSt[ THX_BG ] ][ 1 ]
   cPair := UiPairMake( cFg, cBg )

   IF Empty( cPair )
      aSt[ THX_MSG ] := "That pair cannot be painted: " + cFg + "/" + cBg
      aSt[ THX_ERR ] := .T.
      RETURN
   ENDIF
   IF UiOvSet( nSlot, cPair )
      aSt[ THX_MSG ] := "Exception: " + UiSlotLabel( nSlot ) + " = " + cPair
      aSt[ THX_ERR ] := .F.
   ELSE
      aSt[ THX_MSG ] := "That pair cannot be painted: " + cPair
      aSt[ THX_ERR ] := .T.
   ENDIF
RETURN

/* goes back to the pair of the theme in force */
STATIC PROCEDURE BpTcReset( aSt, aRows )
   LOCAL nSlot := BpTcSlot( aRows, aSt[ THX_ROW ] )
   IF nSlot == 0
      RETURN
   ENDIF
   IF ! UiOvHas( nSlot )
      aSt[ THX_MSG ] := "That element has no exception."
      aSt[ THX_ERR ] := .T.
      RETURN
   ENDIF
   UiOvClear( nSlot )
   aSt[ THX_MSG ] := UiSlotLabel( nSlot ) + " follows the theme again."
   aSt[ THX_ERR ] := .F.
   BpTcSync( aSt, aRows )
RETURN

STATIC PROCEDURE BpTcResetAll( aSt, aRows )
   LOCAL n := UiOvCount()
   IF n == 0
      aSt[ THX_MSG ] := "There is no exception to reset."
      aSt[ THX_ERR ] := .T.
      RETURN
   ENDIF
   IF UiConfirm( "Reset " + LTrim( Str( n ) ) + " exception(s) and let every element" + ;
                 hb_eol() + "follow the theme in force?", "Theme Colors" )
      UiOvClearAll()
      aSt[ THX_MSG ] := "Every element follows the theme again."
      aSt[ THX_ERR ] := .F.
      BpTcSync( aSt, aRows )
   ENDIF
RETURN

STATIC PROCEDURE BpTcHelp()
   UiTextWin( { ;
      "Theme Colors - keys", ;
      "", ;
      "  Up / Down     move the cursor through the elements", ;
      "  PgUp / PgDn   a page of elements;  Home / End  the first / last", ;
      "  Tab / S-Tab   list -> colour matrix -> buttons", ;
      "  Arrows        in the matrix: Up/Down the ink, Left/Right the surface", ;
      "  Home / End    first / last surface of the row", ;
      "  Ctrl-Home/End first ink + first surface / last ink + last surface", ;
      "  Enter         apply the pair under the cursor (also Space, or a click)", ;
      "  Alt-T         go to the colour matrix", ;
      "  Alt-R         Reset: the element follows the theme again", ;
      "  Alt-L         Reset all the exceptions (asks first)", ;
      "  Ctrl-S        Accept (same as the Accept button)", ;
      "  Esc           Cancel: puts back what there was when the screen opened", ;
      "  F1            this help", ;
      "", ;
      "The matrix is the whole colour space of the driver: 16 inks (rows) by", ;
      "16 surfaces (columns) = 256 attributes, and every cell is painted with", ;
      "its own pair. '+' brightens the ink and '*' the surface, and the two bits", ;
      "are position-free, so N+/B and N/B+ are the same pair. An exception wins", ;
      "over the theme in force; it is kept for the SESSION only - use Save", ;
      "Configuration (F6 > GlobalSet, or Commander > Commands) to write hwbro.ini." }, ;
      "Theme Colors - keys" )
RETURN

/* The rule of the keys. It MUTATES the state (the cursor and the focus) and
 * answers the action to run, exactly like the other forms of this program:
 * "" = nothing, "paint" = state only. */
STATIC FUNCTION BpTcKeyAct( aG, aSt, aRows, nKey, nShift, cAlt )
   LOCAL lCtrl := hb_bitAnd( nShift, HB_GTI_KBD_CTRL ) != 0
   LOCAL lAlt  := hb_bitAnd( nShift, HB_GTI_KBD_ALT ) != 0
   LOCAL nPage := aG[ THG_LAST ] - aG[ THG_FIRST ] + 1
   LOCAL nFg, nBg

   /* 1) the Alt chords: the ring of the hook first (trap 61), then the bare
    * letter plus the ALT bit of the driver (trap 37). ALT together with CTRL is
    * AltGr, which types a character and is not a chord (trap 38). */
   IF Empty( cAlt ) .AND. lAlt .AND. ! lCtrl .AND. nKey >= 32 .AND. nKey <= 255
      cAlt := Upper( Chr( nKey ) )
   ENDIF
   IF Len( cAlt ) > 0
      DO CASE
      CASE cAlt == "A" ; RETURN "accept"
      CASE cAlt == "C" ; RETURN "cancel"
      CASE cAlt == "R" ; RETURN "reset"
      CASE cAlt == "L" ; RETURN "resetall"
      CASE cAlt == "T" ; aSt[ THX_FOCUS ] := THF_GRID ; RETURN "paint"
      ENDCASE
      /* a chord nobody serves is DROPPED: it must not act later */
      RETURN "none"
   ENDIF

   DO CASE
   CASE nKey == K_ESC
      RETURN "cancel"
   CASE nKey == K_F1
      RETURN "help"
   /* Ctrl-S = Accept. This driver hands it over as the code of K_LEFT (19) WITH
    * the CTRL bit (trap 71), so the code alone is not the rule */
   CASE lCtrl .AND. ! lAlt .AND. ( nKey == K_CTRL_S .OR. nKey == Asc( "s" ) .OR. ;
                                   nKey == Asc( "S" ) )
      RETURN "accept"
   CASE nKey == K_TAB .OR. nKey == K_SH_TAB
      RETURN BpTcFocus( aSt, iif( nKey == K_TAB, 1, -1 ) )
   ENDCASE

   DO CASE
   CASE aSt[ THX_FOCUS ] == THF_LIST
      DO CASE
      CASE nKey == K_UP
         aSt[ THX_ROW ] := UiSlotRowStep( aRows, aSt[ THX_ROW ], -1 )
         BpTcSync( aSt, aRows )
         RETURN "paint"
      CASE nKey == K_DOWN
         aSt[ THX_ROW ] := UiSlotRowStep( aRows, aSt[ THX_ROW ], 1 )
         BpTcSync( aSt, aRows )
         RETURN "paint"
      CASE nKey == K_PGUP
         aSt[ THX_ROW ] := BpTcMove( aRows, aSt[ THX_ROW ], -nPage )
         BpTcSync( aSt, aRows )
         RETURN "paint"
      CASE nKey == K_PGDN
         aSt[ THX_ROW ] := BpTcMove( aRows, aSt[ THX_ROW ], nPage )
         BpTcSync( aSt, aRows )
         RETURN "paint"
      CASE nKey == K_HOME
         aSt[ THX_ROW ] := UiSlotRowEdge( aRows, .F. )
         BpTcSync( aSt, aRows )
         RETURN "paint"
      CASE nKey == K_END
         aSt[ THX_ROW ] := UiSlotRowEdge( aRows, .T. )
         BpTcSync( aSt, aRows )
         RETURN "paint"
      CASE nKey == K_ENTER .OR. nKey == K_SPACE .OR. nKey == K_INS
         /* Enter on an element walks to its pair in the matrix, like opening a
          * field: the cursor lands on the combination that element uses now */
         BpTcSync( aSt, aRows )
         aSt[ THX_FOCUS ] := THF_GRID
         RETURN "paint"
      ENDCASE

   CASE aSt[ THX_FOCUS ] == THF_GRID
      /* the two axes of the matrix: Up/Down walks the 16 INKS, Left/Right the 16
       * SURFACES. The ends are what the palette answers, never a literal, so the
       * ring follows a palette that grows. Enter APPLIES the combination under
       * the cursor (also Space, and a click, which is the same action) */
      nFg := Len( UiPaletteFg() )
      nBg := Len( UiPaletteBg() )
      DO CASE
      CASE nKey == K_UP
         aSt[ THX_FG ] := iif( aSt[ THX_FG ] <= 1, nFg, aSt[ THX_FG ] - 1 )
         RETURN "paint"
      CASE nKey == K_DOWN
         aSt[ THX_FG ] := iif( aSt[ THX_FG ] >= nFg, 1, aSt[ THX_FG ] + 1 )
         RETURN "paint"
      CASE nKey == K_LEFT
         aSt[ THX_BG ] := iif( aSt[ THX_BG ] <= 1, nBg, aSt[ THX_BG ] - 1 )
         RETURN "paint"
      CASE nKey == K_RIGHT
         aSt[ THX_BG ] := iif( aSt[ THX_BG ] >= nBg, 1, aSt[ THX_BG ] + 1 )
         RETURN "paint"
      CASE nKey == K_HOME
         aSt[ THX_BG ] := 1
         RETURN "paint"
      CASE nKey == K_END
         aSt[ THX_BG ] := nBg
         RETURN "paint"
      CASE nKey == K_CTRL_HOME
         aSt[ THX_FG ] := 1
         aSt[ THX_BG ] := 1
         RETURN "paint"
      CASE nKey == K_CTRL_END
         aSt[ THX_FG ] := nFg
         aSt[ THX_BG ] := nBg
         RETURN "paint"
      CASE nKey == K_ENTER .OR. nKey == K_SPACE
         RETURN "pair"
      ENDCASE

   CASE aSt[ THX_FOCUS ] == THF_ACCEPT
      IF nKey == K_ENTER .OR. nKey == K_SPACE
         RETURN "accept"
      ENDIF

   CASE aSt[ THX_FOCUS ] == THF_CANCEL
      IF nKey == K_ENTER .OR. nKey == K_SPACE
         RETURN "cancel"
      ENDIF
   ENDCASE

RETURN ""

/* one click, resolved against the controls the painter registered: the same
 * actions the keyboard runs, never a second implementation (the control table is
 * the ONLY copy of the geometry). */
STATIC FUNCTION BpTcClick( aG, aSt, aRows, nRow, nCol )
   LOCAL aC, nIdx, cNm

   /* a row of the list: the cursor goes there (a heading is not a stop) */
   IF nRow >= aG[ THG_FIRST ] .AND. nRow <= aG[ THG_LAST ] .AND. ;
      nCol >= aG[ THG_LISTL ] .AND. nCol <= aG[ THG_LISTR ]
      nIdx := aSt[ THX_TOP ] + ( nRow - aG[ THG_FIRST ] )
      IF nIdx >= 1 .AND. nIdx <= Len( aRows ) .AND. aRows[ nIdx ][ 1 ] == 2
         IF aSt[ THX_ROW ] != nIdx
            aSt[ THX_ROW ] := nIdx
            aSt[ THX_FOCUS ] := THF_LIST
            BpTcSync( aSt, aRows )
            RETURN "paint"
         ENDIF
      ENDIF
      RETURN "none"
   ENDIF

   aC := HcSyncCtlAt( nRow, nCol )
   IF hb_IsNIL( aC )
      RETURN "none"
   ENDIF

   DO CASE
   CASE aC[ 4 ] == "TBTN"
      aSt[ THX_FOCUS ] := aC[ 5 ]
      RETURN iif( aC[ 5 ] == THF_ACCEPT, "accept", "cancel" )
   CASE aC[ 4 ] == "TCEL"
      /* a matrix cell: the cursor goes there AND the combination is applied -
       * one gesture, like the swatch of the old strips */
      aSt[ THX_FOCUS ] := THF_GRID
      aSt[ THX_FG ] := Int( ( aC[ 5 ] - 1 ) / 16 ) + 1
      aSt[ THX_BG ] := ( ( aC[ 5 ] - 1 ) % 16 ) + 1
      RETURN "pair"
   CASE aC[ 4 ] == "KEY"
      cNm := aC[ 5 ]
      IF cNm == "Ctrl-S"
         RETURN "accept"
      ENDIF
      IF Left( cNm, 4 ) == "Alt-" .AND. Len( cNm ) == 5
         RETURN BpTcKeyAct( aG, aSt, aRows, 0, 0, Upper( SubStr( cNm, 5, 1 ) ) )
      ENDIF
      aC := HcSyncChipInput( cNm )
      RETURN BpTcKeyAct( aG, aSt, aRows, aC[ 1 ], 0, "" )
   ENDCASE

RETURN "none"

/* F6 > Theme Colors */
FUNCTION BpThemeColors()
   LOCAL aG, aSt, aRows, aSave, aPt
   LOCAL lPaint := .T., lDone := .F., lHook := .F.
   LOCAL nKey, nShift, cAlt, cAct, cOldCur, nNotch

   aG    := BpTcGeom()
   aRows := UiSlotRows()
   aSt   := { THF_LIST, 1, 1, 1, 1, "", .F. }
   aSt[ THX_ROW ] := BpTcStart( aRows )
   BpTcSync( aSt, aRows )
   aSave := UiOvSnapshot()

   cOldCur := SetCursor( 0 )
   /* the window hook is what gives this driver a mouse and the Alt chords of the
    * ring; it is asked (not assumed) and re-tried while it answers that it is not
    * in place (trap 89: arming it before the window exists leaves it unarmed) */
   lHook := DotMouseHookOn()
   IF ! lHook
      DotMouseHook( .T. )
      lHook := DotMouseHookOn()
   ENDIF
   /* a chord left pending by another screen is not a gesture of this one */
   cAlt := HcAltChord()
   cAlt := UiAltChord()

   DO WHILE ! lDone
      /* trap 89: the hook is armed for real only when the window exists, so a
       * screen entered before the first paint re-tries until it answers that it is
       * in place. Without it there is no mouse and no Alt chord of the ring. */
      IF ! lHook
         lHook := DotMouseHookOn()
         IF ! lHook
            DotMouseHook( .T. )
            lHook := DotMouseHookOn()
         ENDIF
      ENDIF
      IF lPaint
         BpTcDraw( aG, aSt, aRows )
         lPaint := .F.
      ENDIF
      cAct := ""
      nKey   := Inkey( 0.05 )
      nShift := iif( nKey != 0, HcShiftState(), 0 )
      cAlt   := HcAltChord()
      IF Len( cAlt ) == 0
         cAlt := UiAltChord()
      ENDIF
      IF UiCloseAsk()
         cAct := "cancel"
      ENDIF
      IF Empty( cAct ) .AND. HcMouseRightClick()
         cAct := "cancel"
      ENDIF
      IF Empty( cAct )
         IF nKey == 0 .AND. Len( cAlt ) == 0
            aPt := UiClick()
            IF HB_ISARRAY( aPt )
               cAct := BpTcClick( aG, aSt, aRows, aPt[ 1 ], aPt[ 2 ] )
            ELSE
               nNotch := UiMouseWheel()
               IF nNotch != 0
                  DO CASE
                  CASE aSt[ THX_FOCUS ] == THF_LIST
                     aSt[ THX_ROW ] := BpTcMove( aRows, aSt[ THX_ROW ], -nNotch )
                     BpTcSync( aSt, aRows )
                     cAct := "paint"
                  CASE aSt[ THX_FOCUS ] == THF_GRID
                     /* one notch = one row of INKS, the same way Up/Down walks */
                     aSt[ THX_FG ] := BpTcWrap( aSt[ THX_FG ] - nNotch, ;
                                                Len( UiPaletteFg() ) )
                     cAct := "paint"
                  ENDCASE
               ENDIF
            ENDIF
         ELSE
            cAct := BpTcKeyAct( aG, aSt, aRows, nKey, nShift, cAlt )
         ENDIF
      ENDIF
      IF Empty( cAct ) .OR. cAct == "none"
         LOOP
      ENDIF
      DO CASE
      CASE cAct == "cancel"
         /* Cancel puts back exactly what the store had when the screen opened:
          * the changes were applied live, so this is the only way back */
         UiOvRestore( aSave )
         lDone := .T.
      CASE cAct == "accept"
         lDone := .T.
      CASE cAct == "pair"
         BpTcApply( aSt, aRows )
         lPaint := .T.
      CASE cAct == "reset"
         BpTcReset( aSt, aRows )
         lPaint := .T.
      CASE cAct == "resetall"
         BpTcResetAll( aSt, aRows )
         lPaint := .T.
      CASE cAct == "help"
         BpTcHelp()
         lPaint := .T.
      CASE cAct == "paint"
         lPaint := .T.
      ENDCASE
   ENDDO

   SetCursor( cOldCur )
   SetColor( UI_C_DESKTOP )
RETURN NIL


/* =====================================================================
 *  F7 - Record
 * ===================================================================== */

FUNCTION BpRecSeek()
   LOCAL c, x
   IF ! BpNeedDb() ; RETURN NIL ; ENDIF
   IF Empty( OrdName() )
      UiMsg( "No active order (use F3 - Index).", "Seek" )
      RETURN NIL
   ENDIF
   c := UiInput( "Value to seek (" + dbOrderInfo( DBOI_EXPRESSION ) + "):", "", 30 )
   IF c == NIL ; RETURN NIL ; ENDIF
   /* S4.1: the value is TYPED to the key type and handed to dbSeek(). The old
    * version built a "SEEK '<value>'" command and ran it with &(): any value
    * carrying a quote broke the search, and the usual key here is TEXT. */
   IF Empty( AllTrim( c ) )
      UiInfo( "Not found.", "Seek" )
      RETURN NIL
   ENDIF
   x := BpScopeValue( c )
   dbSeek( x )
   IF Found()
      UiInfo( "Found: record " + LTrim( Str( RecNo() ) ), "Seek" )
   ELSE
      UiInfo( "Not found.", "Seek" )
   ENDIF
RETURN NIL

FUNCTION BpRecGoto()
   LOCAL c, n
   IF ! BpNeedDb() ; RETURN NIL ; ENDIF
   c := UiInput( "Record number:", "", 10 )
   IF c == NIL .OR. Empty( AllTrim( c ) ) ; RETURN NIL ; ENDIF
   /* S4.2: Val() answers 0 for anything that is not a number, so junk is
    * rejected here instead of being run as "GO 0" */
   n := Val( c )
   IF n < 1
      UiErr( "Record out of range: " + AllTrim( c ) )
      RETURN NIL
   ENDIF
   CoreGotoRec( n )
RETURN NIL

FUNCTION BpRecLocate()
   LOCAL c := UiInput( "Condition (FOR):", "", 50 )
   LOCAL b, nFrom, lFound := .F., oErr
   IF c == NIL .OR. Empty( AllTrim( c ) ) ; RETURN NIL ; ENDIF
   IF ! BpNeedDb() ; RETURN NIL ; ENDIF
   nFrom := RecNo()
   /* trap 33: &() compiles an EXPRESSION, not a command, so the old
    * CoreRunCmd( "LOCATE FOR " + c ) never ran anything. The condition is
    * compiled here and the records are walked by hand. CAREFUL with the types:
    * the keys of the SIx Driver .CDX are TEXT even when they look numeric
    * (trap 31), so a condition on them needs quotes ("CLI_NUMERO = '700050'");
    * a mismatched comparison raises "Argument error", which is reported. */
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      b := &( "{|| " + c + " }" )
   RECOVER USING oErr
      UiErr( "Invalid condition:" + hb_eol() + oErr:Description, "Locate" )
      RETURN NIL
   END SEQUENCE
   IF Empty( b )
      UiErr( "Invalid condition.", "Locate" )
      RETURN NIL
   ENDIF
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      dbGoTop()
      DO WHILE ! Eof()
         IF Eval( b )
            lFound := .T.
            EXIT
         ENDIF
         SKIP 1
      ENDDO
   RECOVER USING oErr
      dbGoto( nFrom )
      BpLog( "Locate: [" + c + "] " + oErr:Description + " op=" + hb_ValToStr( oErr:Operation ) )
      UiErr( "Error in the condition:" + hb_eol() + oErr:Description, "Locate" )
      RETURN NIL
   END SEQUENCE
   IF lFound
      UiInfo( "Found at record " + LTrim( Str( RecNo() ) ), "Locate" )
   ELSE
      /* not found: the pointer goes BACK to where it was (at EOF the browser
       * would show the last record as if the locate had found something) */
      dbGoto( nFrom )
      UiInfo( "No record found.", "Locate" )
   ENDIF
RETURN NIL

FUNCTION BpRecSkip()
   LOCAL c, n, i
   IF ! BpNeedDb() ; RETURN NIL ; ENDIF
   c := UiInput( "Skip N records (may be negative):", "", 8 )
   IF c == NIL .OR. Empty( AllTrim( c ) ) ; RETURN NIL ; ENDIF
   n := Val( c )
   IF n == 0
      /* S4.2: Val( "abc" ) is 0, and the old code skipped 0 in silence */
      UiErr( "Invalid number of records: " + AllTrim( c ) )
      RETURN NIL
   ENDIF
   /* one record at a time so the ends of the file stop the walk: Bof()/Eof()
    * are PHYSICAL (trap 18), so a single SKIP n past the end would leave the
    * pointer out of the order */
   FOR i := 1 TO Abs( n )
      SKIP iif( n > 0, 1, -1 )
      IF Eof()
         SKIP -1
         EXIT
      ENDIF
      IF Bof()
         SKIP 1
         EXIT
      ENDIF
   NEXT
RETURN NIL

FUNCTION BpRecTop()
   IF BpNeedDb() ; GO TOP ; ENDIF
RETURN NIL

FUNCTION BpRecBottom()
   IF BpNeedDb() ; GO BOTTOM ; ENDIF
RETURN NIL

/* S71: Copy Field copies ONLY the field under the cell cursor (CoreSelCol()
 * mirrors it every pass of the browser) and it also puts the value in the
 * WINDOWS clipboard. Before this it wrote the whole record into the record
 * clipboard, so it was the same thing Copy Record did. */
FUNCTION BpRecCopyField()
   LOCAL aV, aF, xVal
   IF ! BpNeedDb() ; RETURN NIL ; ENDIF
   aV := CoreView()
   IF Empty( aV ) .OR. CoreSelCol() < 1 .OR. CoreSelCol() > Len( aV ) .OR. ;
      aV[ CoreSelCol() ][ 1 ] < 1
      UiMsg( "There is no field under the cursor to copy.", "Copy Field" )
      RETURN NIL
   ENDIF
   aF := aV[ CoreSelCol() ]
   xVal := FieldGet( aF[ 1 ] )
   CoreSetClipField( { aF[ 2 ], xVal, aF[ 3 ] } )
   IF .NOT. BpClipPut( hb_CStr( xVal ) )
      UiErr( "The value was copied inside hwBro, but not to the Windows clipboard.", "Copy Field" )
      RETURN NIL
   ENDIF
   /* the message NAMES the field: Copy Field copies ONE field and Copy Record
    * copies the whole record, and saying which one was copied is the only way
    * for the user to tell them apart (they used to be the same action) */
   UiInfo( "Field " + aF[ 2 ] + " copied (one field)." + hb_eol() + ;
           "Use Copy Record (Shift-F7) for the whole record.", "Copy Field" )
RETURN NIL

/* S6.2: Paste Field writes the copied value into the field under the cell
 * cursor, converted to the type and width of its destination (StructConvert(),
 * trap 22) and with the record locked, like every other write. */
FUNCTION BpRecPasteField()
   LOCAL x := CoreClipField(), aV, aF, nFld, xVal, oErr, lOk := .F.
   IF hb_IsNIL( x )
      UiMsg( "Clipboard empty (use F7 - Copy Field first).", "Paste Field" )
      RETURN NIL
   ENDIF
   IF ! BpNeedDb() ; RETURN NIL ; ENDIF
   aV := CoreView()
   IF Empty( aV ) .OR. CoreSelCol() < 1 .OR. CoreSelCol() > Len( aV ) .OR. ;
      aV[ CoreSelCol() ][ 1 ] < 1
      UiMsg( "There is no field under the cursor to paste into.", "Paste Field" )
      RETURN NIL
   ENDIF
   aF := aV[ CoreSelCol() ]
   nFld := aF[ 1 ]
   xVal := StructConvert( x[ 2 ], { aF[ 2 ], aF[ 3 ], aF[ 4 ], aF[ 5 ] } )
   /* StructConvert() answers NIL for a type it does not know (bp_struct.prg):
    * writing that would raise a data type error, so it is refused here */
   IF hb_IsNIL( xVal )
      UiErr( "Field " + aF[ 2 ] + ": value of type " + x[ 3 ] + " cannot be pasted.", "Paste Field" )
      RETURN NIL
   ENDIF
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      dbRLock()
      FieldPut( nFld, xVal )
      dbCommit()
      dbRUnlock()
      lOk := .T.
   RECOVER USING oErr
      UiErr( "Error pasting: " + oErr:Description )
   END SEQUENCE
   IF lOk
      UiInfo( "Field pasted.", "Paste Field" )
   ENDIF
RETURN NIL

/* S6.4: the value of any field as TEXT, for the WINDOWS clipboard: a date as
 * MM/DD/YY, a logical as T/F and a number without padding. */
STATIC FUNCTION BpClipValue( x )
   DO CASE
   CASE ValType( x ) == "C" .OR. ValType( x ) == "M" ; RETURN AllTrim( x )   /* the DBF pads the text */
   CASE ValType( x ) == "N" ; RETURN LTrim( Str( x ) )
   CASE ValType( x ) == "D" ; RETURN iif( Empty( x ), "", DToC( x ) )
   CASE ValType( x ) == "L" ; RETURN iif( x, "T", "F" )
   ENDCASE
RETURN ""

/* S6.1: Copy Record REPLACES the record snapshot the internal clipboard keeps
 * (the old code ADDED to it on every call, so Paste Record replayed old
 * snapshots and the last field name won). S6.4: the whole record ALSO goes to
 * the WINDOWS clipboard as text, one field per line ("NAME = value"), which is
 * what "copy the record" means when the target is Notepad or another program:
 * the internal snapshot is invisible outside hwBro (reported by the user). */
FUNCTION BpRecCopyRecord()
   LOCAL aSt, a, i, cTxt := ""
   IF ! BpNeedDb() ; RETURN NIL ; ENDIF
   aSt := DbStruct()
   a := { { Alias(), dbOrderInfo( DBOI_EXPRESSION ), RecNo() } }
   FOR i := 1 TO Len( aSt )
      AAdd( a, { aSt[ i ][ 1 ], FieldGet( i ), aSt[ i ][ 2 ] } )
      cTxt += iif( i > 1, hb_eol(), "" ) + PadR( aSt[ i ][ 1 ], 12 ) + " = " + ;
              BpClipValue( a[ i + 1 ][ 2 ] )
   NEXT
   CoreSetClip( a )
   IF ! BpClipPut( cTxt )
      UiErr( "The record was copied inside hwBro, but not to the Windows clipboard.", ;
             "Copy Record" )
      RETURN NIL
   ENDIF
   UiInfo( "Record " + LTrim( Str( RecNo() ) ) + " copied (" + ;
           LTrim( Str( Len( a ) - 1 ) ) + " of " + LTrim( Str( Len( aSt ) ) ) + ;
           " fields) to the Windows clipboard.", "Copy Record" )
RETURN NIL

/* S5: writing data, so it needs Modify (and not ReadOnly), every value is
 * converted to its destination field BEFORE anything is written and the record
 * is locked. A value that does not fit can no longer leave a half written
 * record behind (the old version did APPEND BLANK first). */
FUNCTION BpRecPasteRecord()
   LOCAL a := CoreClip(), aVal := {}, i, nFld, xVal, oErr, lOk := .F.
   IF Empty( a ) ; UiMsg( "Clipboard empty.", "Paste Record" ) ; RETURN NIL ; ENDIF
   IF ! BpNeedDb() ; RETURN NIL ; ENDIF
   FOR i := 1 TO Len( a )
      IF HB_ISARRAY( a[ i ] ) .AND. Len( a[ i ] ) == 3 .AND. IsCharacter( a[ i ][ 1 ] ) ;
         .AND. ( nFld := FieldPos( a[ i ][ 1 ] ) ) > 0
         xVal := StructConvert( a[ i ][ 2 ], { FieldName( nFld ), ;
                        FieldType( nFld ), FieldLen( nFld ), FieldDec( nFld ) } )
         /* a field whose type StructConvert() does not know answers NIL: it
          * is SKIPPED, because FieldPut( NIL ) would throw with the record
          * already appended */
         IF ! hb_IsNIL( xVal )
            AAdd( aVal, { nFld, xVal } )
         ENDIF
      ENDIF
   NEXT
   IF Empty( aVal )
      UiMsg( "The clipboard has no field of this database.", "Paste Record" )
      RETURN NIL
   ENDIF
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      dbAppend()
      dbRLock()
      FOR i := 1 TO Len( aVal )
         FieldPut( aVal[ i ][ 1 ], aVal[ i ][ 2 ] )
      NEXT
      dbCommit()
      dbRUnlock()
      lOk := .T.
   RECOVER USING oErr
      UiErr( "Error pasting: " + oErr:Description )
   END SEQUENCE
   IF lOk
      UiInfo( "Record pasted (" + LTrim( Str( Len( aVal ) ) ) + " fields).", "Paste Record" )
   ENDIF
RETURN NIL

FUNCTION BpRecViewClip()
   LOCAL a := CoreClip(), aL := {}, i
   IF Empty( a ) ; UiMsg( "Clipboard empty.", "View Clipboard" ) ; RETURN NIL ; ENDIF
   FOR i := 1 TO Len( a )
      /* S6.3: the FIRST element is the internal header { alias, key, recno },
       * not a field: it is used for the title line and never listed as a row */
      IF i > 1 .AND. HB_ISARRAY( a[ i ] ) .AND. Len( a[ i ] ) == 3 .AND. ;
         IsCharacter( a[ i ][ 1 ] )
         AAdd( aL, PadR( a[ i ][ 1 ], 14 ) + " = " + hb_CStr( a[ i ][ 2 ] ) )
      ENDIF
   NEXT
   IF HB_ISARRAY( a[ 1 ] ) .AND. Len( a[ 1 ] ) == 3
      AAdd( aL, "" )
      AAdd( aL, "Record " + LTrim( Str( a[ 1 ][ 3 ] ) ) + "   (" + ;
                AllTrim( hb_CStr( a[ 1 ][ 1 ] ) ) + ")   -   " + ;
                LTrim( Str( Len( a ) - 1 ) ) + " fields" )
   ENDIF
   AAdd( aL, "" )
   AAdd( aL, "PgDn/PgUp scroll: the whole record is here (Copy Record)." )
   UiTextWin( aL, "Clipboard" )
RETURN NIL

/* S7: real implementation. It blanks the MEMO fields of the current record
 * (the old version only showed a fixed message, even in a base with memos). */
FUNCTION BpRecEraseMemo()
   LOCAL aSt, i, nMemo := 0, oErr, lOk := .F.
   IF ! BpNeedDb() ; RETURN NIL ; ENDIF
   aSt := DbStruct()
   FOR i := 1 TO Len( aSt )
      IF aSt[ i ][ 2 ] == "M"
         nMemo++
      ENDIF
   NEXT
   IF nMemo == 0
      UiMsg( "There are no memo fields in this database.", "Erase Memo" )
      RETURN NIL
   ENDIF
   /* the memo content is destroyed and there is no undo (the .FPT block is
    * overwritten): ask first, like the DELETE of a record does */
   IF ! UiConfirm( "Erase the memo fields of record " + LTrim( Str( RecNo() ) ) + "?", "Erase Memo" )
      RETURN NIL
   ENDIF
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      dbRLock()
      FOR i := 1 TO Len( aSt )
         IF aSt[ i ][ 2 ] == "M"
            FieldPut( i, "" )
         ENDIF
      NEXT
      dbCommit()
      dbRUnlock()
      lOk := .T.
   RECOVER USING oErr
      UiErr( "Error erasing the memo: " + oErr:Description )
   END SEQUENCE
   IF lOk
      UiInfo( "Memo fields erased.", "Erase Memo" )
   ENDIF
RETURN NIL

/* =====================================================================
 *  F8 - Command
 * ===================================================================== */

/* BpCmdAppendFrom() is the FORM screen of the "Append From" row: it lives
 * with the other forms of this family further down in this file
 * (odd/tasks/append-from-form.md). */

FUNCTION BpCmdCopyStructure()
   LOCAL c := UiInput( "Target structure file:", "", 30 )
   IF c == NIL .OR. Empty( c ) ; RETURN NIL ; ENDIF
   IF ! BpNeedDb() ; RETURN NIL ; ENDIF
   CoreRunCmd( "COPY STRUCTURE TO " + c, .T. )
RETURN NIL

FUNCTION BpCmdCopyTo()
   LOCAL c := UiInput( "Target file (*.DBF):", "", 30 )
   IF c == NIL .OR. Empty( c ) ; RETURN NIL ; ENDIF
   IF ! BpNeedDb() ; RETURN NIL ; ENDIF
   UiProgBusy( "Copying records..." )
   CoreRunCmd( "COPY TO " + c, .T. )
   UiProgEnd()
RETURN NIL

FUNCTION BpCmdCount()
   IF ! BpNeedDb() ; RETURN NIL ; ENDIF
   COUNT TO nCount
   UiInfo( "Records: " + LTrim( Str( nCount ) ), "Count" )
RETURN NIL

FUNCTION BpCmdDelete()
   LOCAL c := UiInput( "FOR condition (empty = all):", "", 50 )
   IF c == NIL ; RETURN NIL ; ENDIF
   IF ! BpNeedDb() ; RETURN NIL ; ENDIF
   UiProgBusy( "Marking records as deleted..." )
   IF Empty( c )
      IF UiConfirm( "Mark ALL records as deleted ?", "Delete" )
         DELETE ALL
      ENDIF
   ELSE
      CoreRunCmd( "DELETE FOR " + c, .T. )
   ENDIF
   UiProgEnd()
RETURN NIL

/* =====================================================================
 *  F8 - CommandTools -> "List to Print"   (odd/tasks/list-to-print.md)
 * ---------------------------------------------------------------------
 *  A FORM screen of the family of the Replace form (skill
 *  pantallas-de-formulario), not a UiInput: the title LIST of the original,
 *  one row per datum of the LIST command -the shape of the listing, the
 *  destination, the file name and its field separator, the printer, SCOPE with
 *  its Count, WHILE and FOR-, the two buttons Accept/Cancel and a message row.
 *
 *  Every rule that can be decided without a window lives in bp_ui.prg (Lp*),
 *  because the headless bank links that module and never this one; here there
 *  is only the screen. Both destinations walk the records through the same
 *  code, so SCOPE, FOR and WHILE mean exactly the same thing for a file and
 *  for a printer - which is what the old `LIST OFF [TO FILE]` of this menu row
 *  did NOT do (it ignored all three).
 * ===================================================================== */

/* focus stops, in VISUAL order (the ring walks this order, and the two
 * destination rows are exclusive: the FILE ones and the printer one never
 * exist at the same time) */
#define LP_FOC_LIST    1
#define LP_FOC_FLD     2    /* [ Fields ( n ) ] */
#define LP_FOC_TO      3
#define LP_FOC_FILE    4    /* only with TO = FILE   */
#define LP_FOC_SEP     5    /* only with TO = FILE   */
#define LP_FOC_PRT     6    /* only with TO = PRINT  */
#define LP_FOC_SCOPE   7
#define LP_FOC_CNT     8
#define LP_FOC_WHILE   9
#define LP_FOC_FOR    10
#define LP_FOC_OK     11    /* [ ~A~ccept ] */
#define LP_FOC_CANCEL 12    /* [ ~C~ancel ] */
#define LP_FOC_MAX    12

/* SCOPE, in the order of LpScopeList() */
#define LP_SC_ALL      1
#define LP_SC_NEXT     2
#define LP_SC_REST     3
#define LP_SC_REC      4

/* the shape of the listing, in the order of LpShapeList() */
#define LP_SH_COLS     1
#define LP_SH_PAGE     2
#define LP_SH_MEMO     3

/* the destination, in the order of LpToList() */
#define LP_TO_PRINT    1
#define LP_TO_FILE     2

/* rows of the box, RELATIVE to its top: the screen is derived from the canvas
 * and these offsets are what keeps the painter, the editors and the click
 * rectangles of one control in one place */
#define LP_R_TITLE     1
#define LP_R_LIST      3
#define LP_R_TO        5
#define LP_R_DEST      7
#define LP_R_SEP       8
#define LP_R_SCOPE    10
#define LP_R_WHILE    12
#define LP_R_FOR      14
#define LP_R_MSG      16
#define LP_R_BTN      18
#define LP_R_HINT     19
#define LP_H          21

/* geometry slots, all computed by LpGeom() from UiCols()/UiRows() */
#define LPG_W          1
#define LPG_L          2
#define LPG_T          3
#define LPG_B          4
#define LPG_R          5
#define LPG_LBL        6     /* column of every label              */
#define LPG_VAL        7     /* column of every value              */
#define LPG_WLIST      8     /* width of the LIST select           */
#define LPG_FLDBTN     9     /* column of the [ Fields ( n ) ] one */
#define LPG_WFILE     10     /* width of the file name             */
#define LPG_WBIG      11     /* width of the printer and of FOR/WHILE */
#define LPG_SCW       12     /* width of the SCOPE select          */
#define LPG_CBLBL     13     /* column of the "Count:" label       */
#define LPG_CVAL      14     /* column of the Count field          */
#define LPG_WCNT      15
#define LPG_MAX       15

/* the state of the form */
#define LPX_SHAPE      1
#define LPX_TO         2
#define LPX_FILE       3
#define LPX_SEP        4     /* ONE character, "" means one space */
#define LPX_PRT        5     /* the printer in force               */
#define LPX_PRTN       6     /* every printer of Windows           */
#define LPX_PRTI       7     /* its index in that list             */
#define LPX_SCOPE      8
#define LPX_COUNT      9
#define LPX_WHILE     10
#define LPX_FOR       11
#define LPX_SEL       12     /* field numbers, in the order picked */
#define LPX_FIELDS    13     /* every field name, in .DBF order    */
#define LPX_TYPES     14
#define LPX_LENS      15
#define LPX_DECS      16
#define LPX_FOCUS     17
#define LPX_MSG       18
#define LPX_ERR       19
#define LPX_MAX       19

/* ---------- geometry ---------- */

STATIC FUNCTION LpGeom()
   LOCAL nW := Min( 84, UiCols() - 8 )
   LOCAL nL := UiCenterCol( nW )
   LOCAL nR := nL + nW - 1
   LOCAL nT := UiCenterRow( LP_H )
   LOCAL nVal := nL + 18
   LOCAL aG := Array( LPG_MAX )
   aG[ LPG_W ]      := nW
   aG[ LPG_L ]      := nL
   aG[ LPG_T ]      := nT
   aG[ LPG_B ]      := nT + LP_H - 1
   aG[ LPG_R ]      := nR
   aG[ LPG_LBL ]    := nL + 2
   aG[ LPG_VAL ]    := nVal
   aG[ LPG_WLIST ]  := Min( 26, nR - 4 - nVal )
   aG[ LPG_FLDBTN ] := nVal + aG[ LPG_WLIST ] + 2
   aG[ LPG_WFILE ]  := Min( 44, nR - 2 - nVal + 1 )
   aG[ LPG_WBIG ]   := Max( 20, nR - 2 - nVal + 1 )
   aG[ LPG_SCW ]    := 10
   aG[ LPG_CBLBL ]  := nVal + 12
   aG[ LPG_CVAL ]   := nVal + 19
   aG[ LPG_WCNT ]   := 6
RETURN aG

/* ---------- the printers of Windows (S6, hbwin) ----------
 * hbwin is linked into the PRODUCT only: the two calls are guarded with
 * hb_IsFunction() so a build without it -the headless banks never get here-
 * still runs and simply says there is no printer. */

STATIC FUNCTION LpPrinters()
   LOCAL a := {}, x, i
   IF hb_IsFunction( "win_printerList" )
      BEGIN SEQUENCE WITH {| e | Break( e ) }
         x := win_printerList()
      RECOVER
         x := NIL
      END SEQUENCE
      IF HB_ISARRAY( x )
         FOR i := 1 TO Len( x )
            IF ValType( x[ i ] ) == "C" .AND. Len( AllTrim( x[ i ] ) ) > 0
               AAdd( a, AllTrim( x[ i ] ) )
            ENDIF
         NEXT
      ENDIF
   ENDIF
RETURN a

/* the printer Windows has by default, as an index in aPrinters (1 when it is
 * not there or when the engine cannot say it). win_printerGetDefault() may
 * answer the PORT of the printer, so win_printerPortToName() is the second
 * chance before giving up. */
STATIC FUNCTION LpDefaultPrinter( aPrinters )
   LOCAL cDef := "", cName, i
   IF ! hb_IsFunction( "win_printerGetDefault" ) .OR. ! HB_ISARRAY( aPrinters )
      RETURN 1
   ENDIF
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      cDef := win_printerGetDefault()
   RECOVER
      cDef := ""
   END SEQUENCE
   IF ValType( cDef ) != "C" .OR. Len( AllTrim( cDef ) ) == 0
      RETURN 1
   ENDIF
   cDef := AllTrim( cDef )
   FOR i := 1 TO Len( aPrinters )
      IF aPrinters[ i ] == cDef
         RETURN i
      ENDIF
   NEXT
   IF hb_IsFunction( "win_printerPortToName" )
      BEGIN SEQUENCE WITH {| e | Break( e ) }
         cName := win_printerPortToName( cDef )
      RECOVER
         cName := ""
      END SEQUENCE
      IF ValType( cName ) == "C"
         FOR i := 1 TO Len( aPrinters )
            IF aPrinters[ i ] == cName
               RETURN i
            ENDIF
         NEXT
      ENDIF
   ENDIF
RETURN 1

/* ---------- the state, with the session memory of the last form ---------- */

STATIC FUNCTION LpStateNew()
   LOCAL aSt := Array( LPX_MAX )
   LOCAL aFld := RpFieldList(), aTyp := {}, aLen := {}, aDec := {}, i
   LOCAL aPrn
   FOR i := 1 TO Len( aFld )
      AAdd( aTyp, Upper( FieldType( i ) ) )
      AAdd( aLen, FieldLen( i ) )
      AAdd( aDec, FieldDec( i ) )
   NEXT
   aPrn := LpPrinters()
   aSt[ LPX_SHAPE ]  := LP_SH_COLS
   aSt[ LPX_TO ]     := LP_TO_PRINT
   aSt[ LPX_FILE ]   := "LIST.TXT"
   aSt[ LPX_SEP ]    := ""
   aSt[ LPX_PRTN ]   := aPrn
   aSt[ LPX_PRTI ]   := LpDefaultPrinter( aPrn )
   aSt[ LPX_PRT ]    := iif( Empty( aPrn ), "", aPrn[ aSt[ LPX_PRTI ] ] )
   aSt[ LPX_SCOPE ]  := LP_SC_ALL
   aSt[ LPX_COUNT ]  := 1
   aSt[ LPX_WHILE ]  := ""
   aSt[ LPX_FOR ]    := ""
   /* the selection starts with EVERY field, in file order: that is what the
    * row of this menu did before (`LIST OFF`) and it is the least surprising
    * starting point - the field screen is the way to cut it down */
   aSt[ LPX_SEL ]    := LpSelAll( Len( aFld ) )
   aSt[ LPX_FIELDS ] := aFld
   aSt[ LPX_TYPES ]  := aTyp
   aSt[ LPX_LENS ]   := aLen
   aSt[ LPX_DECS ]   := aDec
   aSt[ LPX_FOCUS ]  := LP_FOC_LIST
   aSt[ LPX_MSG ]    := ""
   aSt[ LPX_ERR ]    := .F.
   /* session memory, element by element (an array is a REFERENCE, trap 67).
    * The field SELECTION is NOT remembered: its numbers belong to the file
    * that was open and would point at other fields here. */
   IF HB_ISARRAY( s_aLpLast ) .AND. Len( s_aLpLast ) == 8
      IF ValType( s_aLpLast[ 1 ] ) == "N" .AND. s_aLpLast[ 1 ] >= 1 .AND. s_aLpLast[ 1 ] <= 3
         aSt[ LPX_SHAPE ] := s_aLpLast[ 1 ]
      ENDIF
      IF ValType( s_aLpLast[ 2 ] ) == "N" .AND. s_aLpLast[ 2 ] >= 1 .AND. s_aLpLast[ 2 ] <= 2
         aSt[ LPX_TO ] := s_aLpLast[ 2 ]
      ENDIF
      IF ValType( s_aLpLast[ 3 ] ) == "C" .AND. Len( AllTrim( s_aLpLast[ 3 ] ) ) > 0
         aSt[ LPX_FILE ] := s_aLpLast[ 3 ]
      ENDIF
      IF ValType( s_aLpLast[ 4 ] ) == "C"
         aSt[ LPX_SEP ] := s_aLpLast[ 4 ]
      ENDIF
      IF ValType( s_aLpLast[ 5 ] ) == "N" .AND. s_aLpLast[ 5 ] >= 1 .AND. s_aLpLast[ 5 ] <= 4
         aSt[ LPX_SCOPE ] := s_aLpLast[ 5 ]
      ENDIF
      IF ValType( s_aLpLast[ 6 ] ) == "N"
         aSt[ LPX_COUNT ] := s_aLpLast[ 6 ]
      ENDIF
      IF ValType( s_aLpLast[ 7 ] ) == "C"
         aSt[ LPX_WHILE ] := s_aLpLast[ 7 ]
      ENDIF
      IF ValType( s_aLpLast[ 8 ] ) == "C"
         aSt[ LPX_FOR ] := s_aLpLast[ 8 ]
      ENDIF
   ENDIF
RETURN aSt

STATIC PROCEDURE LpSaveState( aSt )
   s_aLpLast := { aSt[ LPX_SHAPE ], aSt[ LPX_TO ], aSt[ LPX_FILE ], aSt[ LPX_SEP ], ;
                  aSt[ LPX_SCOPE ], aSt[ LPX_COUNT ], aSt[ LPX_WHILE ], aSt[ LPX_FOR ] }
RETURN

/* ---------- the skip rule and the ring (ONE table, ONE rule) ---------- */

/* a stop exists right now? The two destination blocks are exclusive, so the
 * ring, the quick letters and the click all read this one rule */
FUNCTION LpFocusOk( nFoc, nTo, nScope )
   DEFAULT nScope TO 0
   DO CASE
   CASE nFoc == LP_FOC_FILE ; RETURN nTo == LP_TO_FILE
   CASE nFoc == LP_FOC_SEP  ; RETURN nTo == LP_TO_FILE
   CASE nFoc == LP_FOC_PRT  ; RETURN nTo == LP_TO_PRINT
   /* the Count is frozen with ALL and REST: painted dim and NOT reachable. It
    * used to be skipped by the click table only, so Tab parked the focus on a
    * value that is not an input (measured: the windowed probe ended up there).
    * nScope = 0 means "the caller does not know the scope" and keeps the old
    * answer, so a caller of the two-argument form behaves exactly as before. */
   CASE nFoc == LP_FOC_CNT  ; RETURN nScope == 0 .OR. LpScopeNeedsCount( nScope )
   ENDCASE
RETURN .T.

/* the next reachable stop, wrapping at both ends; .F. when the focus did not
 * move (nothing reachable, which cannot happen but must not loop) */
STATIC FUNCTION LpFocus( aSt, nDir )
   LOCAL n := aSt[ LPX_FOCUS ], i
   FOR i := 1 TO LP_FOC_MAX
      n += iif( nDir < 0, -1, 1 )
      IF n > LP_FOC_MAX
         n := 1
      ENDIF
      IF n < 1
         n := LP_FOC_MAX
      ENDIF
      IF LpFocusOk( n, aSt[ LPX_TO ], aSt[ LPX_SCOPE ] )
         IF n == aSt[ LPX_FOCUS ]
            RETURN .F.
         ENDIF
         aSt[ LPX_FOCUS ] := n
         RETURN .T.
      ENDIF
   NEXT
RETURN .F.

/* when TO changes, the stop the focus is standing on may stop existing: it
 * walks forward to the next reachable one, so the user is never parked on a
 * control that is not painted */
STATIC PROCEDURE LpFixFocus( aSt )
   IF ! LpFocusOk( aSt[ LPX_FOCUS ], aSt[ LPX_TO ], aSt[ LPX_SCOPE ] )
      LpFocus( aSt, 1 )
   ENDIF
RETURN

/* is the stop a text INPUT? (the ones that carry their own background and are
 * entered by typing a character) */
STATIC FUNCTION LpIsText( nFoc )
   DO CASE
   CASE nFoc == LP_FOC_FILE ; RETURN .T.
   CASE nFoc == LP_FOC_SEP  ; RETURN .T.
   CASE nFoc == LP_FOC_CNT  ; RETURN .T.
   CASE nFoc == LP_FOC_WHILE; RETURN .T.
   CASE nFoc == LP_FOC_FOR  ; RETURN .T.
   ENDCASE
RETURN .F.

/* ---------- the painters (each one REGISTERS its control) ---------- */

STATIC PROCEDURE LpLabel( nRow, nCol, cText )
   UiDrawHot( nRow, nCol, cText, UI_C_BOX, UI_C_HOT )
RETURN

/* an INPUT: the only control with a background of its own (UI_C_FIELDBG at
 * rest, UI_C_LISTSEL with the focus) */
STATIC PROCEDURE LpPaintFld( nRow, nCol, nW, cText, lFoc, nStop, cKind )
   SetColor( iif( lFoc, UI_C_LISTSEL, UI_C_FIELDBG ) )
   @ nRow, nCol SAY PadR( Left( iif( ValType( cText ) == "C", cText, "" ), nW ), nW )
   HcSyncCtlAdd( nRow, nCol, nW, cKind, nStop )
RETURN

/* a SELECT / value chip: FLAT at rest (UI_C_FLATBG, the cyan of the box) and
 * yellow with the focus. It never spends a second background. */
STATIC PROCEDURE LpPaintVal( nRow, nCol, nW, cText, lFoc, nStop, cKind )
   SetColor( iif( lFoc, UI_C_LISTSEL, UI_C_FLATBG ) )
   @ nRow, nCol SAY PadR( Left( iif( ValType( cText ) == "C", cText, "" ), nW ), nW )
   HcSyncCtlAdd( nRow, nCol, nW, cKind, nStop )
RETURN

/* a control that does not exist right now: dimmed and NOT registered, so
 * neither a click nor Tab reaches it */
STATIC PROCEDURE LpPaintDim( nRow, nCol, nW, cText )
   SetColor( UI_C_BOXDIM )
   @ nRow, nCol SAY PadR( Left( iif( ValType( cText ) == "C", cText, "" ), nW ), nW )
RETURN

/* one button of the form: `[ ~A~ccept ]`. Flat at rest, brown with the focus
 * and the quick letter in UI_C_HOTSEL (the same rendering as the buttons of
 * the Replace form and of the Add to zip box). */
STATIC PROCEDURE LpPaintBtn( nRow, nCol, cLabel, lFoc, nStop, cKind )
   LOCAL cPair := iif( lFoc, UI_C_BOXSEL, UI_C_FLATBG )
   LOCAL nW := UiHotLen( cLabel )
   SetColor( cPair )
   @ nRow, nCol SAY Space( nW )
   UiDrawHot( nRow, nCol, cLabel, cPair, iif( lFoc, UI_C_HOTSEL, UI_C_HOT ) )
   HcSyncCtlAdd( nRow, nCol, nW, cKind, nStop )
RETURN

/* the whole box, in ONE paint block. This is where the controls of the mouse
 * are registered: HcSyncCtlReset() first and one entry per control, so a click
 * can never drift from what is painted. */
STATIC PROCEDURE LpDraw( aG, aSt )
   LOCAL nT := aG[ LPG_T ], nL := aG[ LPG_L ]
   LOCAL nB := aG[ LPG_B ], nR := aG[ LPG_R ]
   LOCAL nLbl := aG[ LPG_LBL ], nVal := aG[ LPG_VAL ]
   LOCAL lFile := aSt[ LPX_TO ] == LP_TO_FILE
   LOCAL cFldBtn, cCnt
   cFldBtn := "[ ~F~ields ( " + LTrim( Str( LpSelCount( aSt[ LPX_SEL ] ) ) ) + " ) ]"
   cCnt := LTrim( Str( aSt[ LPX_COUNT ] ) )
   HcSyncCtlReset()
   UiPaintBegin()
   UiShadow( nT, nL, nB, nR )
   UiFillBox( nT, nL, nB, nR, UI_C_BOX )
   UiFrame( nT, nL, nB, nR, UI_C_BOXBORD, .T. )
   /* title: the white chip inside the box, centered */
   SetColor( UI_C_FLATBG )
   @ nT + LP_R_TITLE, nL + Int( ( aG[ LPG_W ] - 6 ) / 2 ) SAY " LIST "
   /* row 1: the shape of the listing and the field screen */
   LpLabel( nT + LP_R_LIST, nLbl, "~L~IST:" )
   LpPaintVal( nT + LP_R_LIST, nVal, aG[ LPG_WLIST ], LpShapeText( aSt[ LPX_SHAPE ] ), ;
               aSt[ LPX_FOCUS ] == LP_FOC_LIST, LP_FOC_LIST, "LPFLD" )
   LpPaintBtn( nT + LP_R_LIST, aG[ LPG_FLDBTN ], cFldBtn, ;
               aSt[ LPX_FOCUS ] == LP_FOC_FLD, LP_FOC_FLD, "LPBTN" )
   /* row 2: the destination */
   LpLabel( nT + LP_R_TO, nLbl, "~T~O:" )
   LpPaintVal( nT + LP_R_TO, nVal, aG[ LPG_SCW ], LpToText( aSt[ LPX_TO ] ), ;
               aSt[ LPX_FOCUS ] == LP_FOC_TO, LP_FOC_TO, "LPFLD" )
   /* rows 3 and 4: the two destination blocks. Only the one in force exists
    * (S5/S6): File + Separator with TO = FILE, Printer with TO = PRINT */
   IF lFile
      LpLabel( nT + LP_R_DEST, nLbl, "Fil~e~:" )
      LpPaintFld( nT + LP_R_DEST, nVal, aG[ LPG_WFILE ], aSt[ LPX_FILE ], ;
                  aSt[ LPX_FOCUS ] == LP_FOC_FILE, LP_FOC_FILE, "LPFLD" )
      LpLabel( nT + LP_R_SEP, nLbl, "Sepa~r~ator:" )
      LpPaintFld( nT + LP_R_SEP, nVal, 1, aSt[ LPX_SEP ], ;
                  aSt[ LPX_FOCUS ] == LP_FOC_SEP, LP_FOC_SEP, "LPFLD" )
   ELSE
      LpLabel( nT + LP_R_DEST, nLbl, "Pr~i~nter:" )
      LpPaintVal( nT + LP_R_DEST, nVal, aG[ LPG_WBIG ], aSt[ LPX_PRT ], ;
                  aSt[ LPX_FOCUS ] == LP_FOC_PRT, LP_FOC_PRT, "LPFLD" )
   ENDIF
   /* row 5: SCOPE and its Count (S7: Count only with NEXT and RECORD) */
   LpLabel( nT + LP_R_SCOPE, nLbl, "~S~COPE:" )
   LpPaintVal( nT + LP_R_SCOPE, nVal, aG[ LPG_SCW ], LpScopeText( aSt[ LPX_SCOPE ] ), ;
               aSt[ LPX_FOCUS ] == LP_FOC_SCOPE, LP_FOC_SCOPE, "LPFLD" )
   LpLabel( nT + LP_R_SCOPE, aG[ LPG_CBLBL ], "Cou~n~t:" )
   IF LpScopeNeedsCount( aSt[ LPX_SCOPE ] )
      LpPaintFld( nT + LP_R_SCOPE, aG[ LPG_CVAL ], aG[ LPG_WCNT ], cCnt, ;
                  aSt[ LPX_FOCUS ] == LP_FOC_CNT, LP_FOC_CNT, "LPFLD" )
   ELSE
      LpPaintDim( nT + LP_R_SCOPE, aG[ LPG_CVAL ], aG[ LPG_WCNT ], cCnt )
   ENDIF
   /* rows 6 and 7: the two xBase conditions */
   LpLabel( nT + LP_R_WHILE, nLbl, "~W~HILE:" )
   LpPaintFld( nT + LP_R_WHILE, nVal, aG[ LPG_WBIG ], aSt[ LPX_WHILE ], ;
               aSt[ LPX_FOCUS ] == LP_FOC_WHILE, LP_FOC_WHILE, "LPFLD" )
   LpLabel( nT + LP_R_FOR, nLbl, "F~O~R:" )
   LpPaintFld( nT + LP_R_FOR, nVal, aG[ LPG_WBIG ], aSt[ LPX_FOR ], ;
               aSt[ LPX_FOCUS ] == LP_FOC_FOR, LP_FOC_FOR, "LPFLD" )
   /* message row: the summary of the form, or why nothing was listed */
   IF aSt[ LPX_ERR ]
      SetColor( UI_C_ERR )
      @ nT + LP_R_MSG, nLbl SAY PadR( Left( aSt[ LPX_MSG ], nR - 2 - nLbl + 1 ), ;
                                     nR - 2 - nLbl + 1 )
   ELSE
      SetColor( UI_C_FLATBG )
      @ nT + LP_R_MSG, nLbl SAY PadR( Left( iif( Len( AllTrim( aSt[ LPX_MSG ] ) ) > 0, ;
                                               aSt[ LPX_MSG ], LpSummary( aSt ) ), ;
                                           nR - 2 - nLbl + 1 ), nR - 2 - nLbl + 1 )
   ENDIF
   /* the two buttons, side by side like the rest of the forms */
   LpPaintBtn( nT + LP_R_BTN, nLbl, "[ ~A~ccept ]", ;
               aSt[ LPX_FOCUS ] == LP_FOC_OK, LP_FOC_OK, "LPBTN" )
   LpPaintBtn( nT + LP_R_BTN, nLbl + 14, "[ ~C~ancel ]", ;
               aSt[ LPX_FOCUS ] == LP_FOC_CANCEL, LP_FOC_CANCEL, "LPBTN" )
   /* the hint row: only the keys this screen really has */
   SetColor( UI_C_BOX )
   @ nT + LP_R_HINT, nLbl SAY PadR( "Tab: Move   Enter: Select/Edit   Ctrl-S: List   " + ;
                                     "F1: Help   Esc: Cancel", nR - 2 - nLbl + 1 )
   UiPaintEnd()
RETURN

/* the summary of the message row: what the form is about to do */
STATIC FUNCTION LpSummary( aSt )
   LOCAL c := "Fields: " + LTrim( Str( LpSelCount( aSt[ LPX_SEL ] ) ) ) + ;
                iif( aSt[ LPX_TO ] == LP_TO_FILE, ;
                     "   To file: " + AllTrim( aSt[ LPX_FILE ] ), ;
                     "   To printer: " + AllTrim( aSt[ LPX_PRT ] ) )
RETURN c

/* ---------- keys of the form ---------- */

STATIC FUNCTION LpAct( lOk, cAct )
RETURN iif( lOk, cAct, "" )

/* move the focus to a stop, unless that stop does not exist right now */
STATIC FUNCTION LpSetFocus( aSt, nFoc )
   IF ! LpFocusOk( nFoc, aSt[ LPX_TO ], aSt[ LPX_SCOPE ] )
      RETURN .F.
   ENDIF
   aSt[ LPX_FOCUS ] := nFoc
RETURN .T.

/* the key -> action table of the form. It MUTATES the focus (a ring step is not
 * an action) and answers the action the loop runs, "" for a key that does
 * nothing here. `Alt+<letter>` comes from the ring of the window hook (trap 61)
 * and the letter is already upper case; a chord nobody serves is DROPPED so it
 * cannot type anything later. */
STATIC FUNCTION LpKeyAct( nKey, nShift, cAlt, aSt )
   LOCAL lCtrl := hb_bitAnd( nShift, HB_GTI_KBD_CTRL ) != 0
   LOCAL lAlt  := hb_bitAnd( nShift, HB_GTI_KBD_ALT ) != 0
   LOCAL nFoc  := aSt[ LPX_FOCUS ]
   DO CASE
   CASE Len( cAlt ) > 0
      DO CASE
      CASE cAlt == "L" ; RETURN LpAct( LpSetFocus( aSt, LP_FOC_LIST ),  "focus" )
      CASE cAlt == "F" ; RETURN LpAct( LpSetFocus( aSt, LP_FOC_FLD  ),  "focus" )
      CASE cAlt == "T" ; RETURN LpAct( LpSetFocus( aSt, LP_FOC_TO   ),  "focus" )
      CASE cAlt == "E" ; RETURN LpAct( LpSetFocus( aSt, LP_FOC_FILE ),  "focus" )
      CASE cAlt == "R" ; RETURN LpAct( LpSetFocus( aSt, LP_FOC_SEP  ),  "focus" )
      CASE cAlt == "I" ; RETURN LpAct( LpSetFocus( aSt, LP_FOC_PRT  ),  "focus" )
      CASE cAlt == "S" ; RETURN LpAct( LpSetFocus( aSt, LP_FOC_SCOPE ), "focus" )
      CASE cAlt == "N" ; RETURN LpAct( LpSetFocus( aSt, LP_FOC_CNT  ),  "focus" )
      CASE cAlt == "W" ; RETURN LpAct( LpSetFocus( aSt, LP_FOC_WHILE ), "focus" )
      CASE cAlt == "O" ; RETURN LpAct( LpSetFocus( aSt, LP_FOC_FOR  ),  "focus" )
      CASE cAlt == "A" ; RETURN "run"
      CASE cAlt == "C" .OR. cAlt == "X" ; RETURN "cancel"
      ENDCASE
      RETURN ""
   CASE nKey == K_ESC ; RETURN "cancel"
   CASE nKey == K_F1  ; RETURN "help"
   /* Ctrl-S: this driver hands it over as the code of K_LEFT (19) WITH the CTRL
    * bit (trap 71), so the code alone is not the rule; ALT disqualifies it
    * because AltGr IS Ctrl+Alt (trap 38). ONE worker: the same LpRun() the
    * Accept button runs. */
   CASE lCtrl .AND. ! lAlt .AND. ( nKey == K_CTRL_S .OR. nKey == Asc( "s" ) .OR. ;
                                   nKey == Asc( "S" ) )
      RETURN "run"
   CASE nKey == K_ENTER .OR. nKey == K_INS .OR. nKey == K_SPACE
      DO CASE
      CASE nFoc == LP_FOC_OK     ; RETURN "run"
      CASE nFoc == LP_FOC_CANCEL ; RETURN "cancel"
      CASE nFoc == LP_FOC_FLD    ; RETURN "fields"
      ENDCASE
      RETURN "edit"
   CASE nKey == K_TAB .OR. nKey == K_DOWN .OR. nKey == K_RIGHT
      RETURN LpAct( LpFocus( aSt, 1 ), "focus" )
   CASE nKey == K_SH_TAB .OR. nKey == K_UP .OR. nKey == K_LEFT
      RETURN LpAct( LpFocus( aSt, -1 ), "focus" )
   ENDCASE
RETURN ""

/* a typed character ENTERS the input it is standing on and SEEDS it (the rule
 * of the forms of this program): Enter stays free for "do" */
STATIC FUNCTION LpSeed( aSt, cCh )
   DO CASE
   CASE aSt[ LPX_FOCUS ] == LP_FOC_FILE  ; aSt[ LPX_FILE ]  := cCh
   CASE aSt[ LPX_FOCUS ] == LP_FOC_SEP   ; aSt[ LPX_SEP ]   := cCh
   CASE aSt[ LPX_FOCUS ] == LP_FOC_CNT   ; aSt[ LPX_COUNT ] := Int( Val( cCh ) )
   CASE aSt[ LPX_FOCUS ] == LP_FOC_WHILE ; aSt[ LPX_WHILE ] := cCh
   CASE aSt[ LPX_FOCUS ] == LP_FOC_FOR   ; aSt[ LPX_FOR ]   := cCh
   OTHERWISE ; RETURN .F.
   ENDCASE
RETURN .T.

/* S8: a condition is checked when its editor closes; a bad one keeps the focus
 * on the field and says why in the message row */
STATIC FUNCTION LpCheckCond( aSt, cExpr, nFoc )
   LOCAL cErr
   LpCondBlock( cExpr, @cErr )
   IF ! hb_IsNIL( cErr )
      aSt[ LPX_MSG ] := cErr
      aSt[ LPX_ERR ] := .T.
      aSt[ LPX_FOCUS ] := nFoc
      RETURN .F.
   ENDIF
   aSt[ LPX_MSG ] := ""
   aSt[ LPX_ERR ] := .F.
RETURN .T.

/* open the control that has the focus (a SELECT for the fixed sets of values,
 * the inline editor for the free text) and MOVE THE RING when it is confirmed:
 * Enter, Tab and a choice in a list all leave the focus on the NEXT control
 * (Shift-Tab goes back), which is the rule of the forms of this project. A
 * value that does not validate keeps the focus and says why. */
STATIC PROCEDURE LpEdit( aG, aSt )
   LOCAL nT := aG[ LPG_T ]
   LOCAL nFoc := aSt[ LPX_FOCUS ], cNew, n, lStay := .F., lText := .F.
   DO CASE
   CASE nFoc == LP_FOC_LIST
      n := UiPick( LpShapeList(), "LIST", aSt[ LPX_SHAPE ] )
      IF ValType( n ) == "N" .AND. n >= 1 .AND. n <= 3
         aSt[ LPX_SHAPE ] := n
         aSt[ LPX_MSG ] := ""
         aSt[ LPX_ERR ] := .F.
      ELSE
         lStay := .T.
      ENDIF
   CASE nFoc == LP_FOC_TO
      n := UiPick( LpToList(), "TO", aSt[ LPX_TO ] )
      IF ValType( n ) == "N" .AND. n >= 1 .AND. n <= 2
         IF n != aSt[ LPX_TO ]
            aSt[ LPX_TO ] := n
            LpFixFocus( aSt )
         ENDIF
         aSt[ LPX_MSG ] := ""
         aSt[ LPX_ERR ] := .F.
      ELSE
         lStay := .T.
      ENDIF
   CASE nFoc == LP_FOC_SCOPE
      n := UiPick( LpScopeList(), "SCOPE", aSt[ LPX_SCOPE ] )
      IF ValType( n ) == "N" .AND. n >= 1 .AND. n <= 4
         IF ! LpScopeNeedsCount( n ) .AND. aSt[ LPX_FOCUS ] == LP_FOC_CNT
            aSt[ LPX_FOCUS ] := LP_FOC_SCOPE
         ENDIF
         aSt[ LPX_SCOPE ] := n
         aSt[ LPX_MSG ] := ""
         aSt[ LPX_ERR ] := .F.
      ELSE
         lStay := .T.
      ENDIF
   CASE nFoc == LP_FOC_PRT
      IF Empty( aSt[ LPX_PRTN ] )
         aSt[ LPX_MSG ] := "There is no printer installed."
         aSt[ LPX_ERR ] := .T.
         lStay := .T.
      ELSE
         n := UiPick( aSt[ LPX_PRTN ], "Printer", aSt[ LPX_PRTI ] )
         IF ValType( n ) == "N" .AND. n >= 1 .AND. n <= Len( aSt[ LPX_PRTN ] )
            aSt[ LPX_PRTI ] := n
            aSt[ LPX_PRT ] := aSt[ LPX_PRTN ][ n ]
            aSt[ LPX_MSG ] := ""
            aSt[ LPX_ERR ] := .F.
         ELSE
            lStay := .T.
         ENDIF
      ENDIF
   CASE nFoc == LP_FOC_FILE
      lText := .T.
      cNew := UiLineEdit( nT + LP_R_DEST, aG[ LPG_VAL ], aG[ LPG_WFILE ], ;
                          aSt[ LPX_FILE ], .F., UI_C_LISTSEL, .F., .T. )
      IF ! hb_IsNIL( cNew )
         IF Len( AllTrim( cNew ) ) == 0
            aSt[ LPX_MSG ] := "Enter the file name of the listing."
            aSt[ LPX_ERR ] := .T.
            lStay := .T.
         ELSE
            aSt[ LPX_FILE ] := AllTrim( cNew )
            aSt[ LPX_MSG ] := ""
            aSt[ LPX_ERR ] := .F.
         ENDIF
      ENDIF
   CASE nFoc == LP_FOC_SEP
      lText := .T.
      cNew := UiLineEdit( nT + LP_R_SEP, aG[ LPG_VAL ], 1, aSt[ LPX_SEP ], ;
                          .F., UI_C_LISTSEL, .F., .T. )
      IF ! hb_IsNIL( cNew )
         aSt[ LPX_SEP ] := Left( cNew, 1 )
      ENDIF
   CASE nFoc == LP_FOC_CNT
      lText := .T.
      cNew := UiLineEdit( nT + LP_R_SCOPE, aG[ LPG_CVAL ], aG[ LPG_WCNT ], ;
                          LTrim( Str( aSt[ LPX_COUNT ] ) ), .T., UI_C_LISTSEL, .F., .T. )
      IF ! hb_IsNIL( cNew )
         n := Val( cNew )
         aSt[ LPX_COUNT ] := iif( n > 0, Int( n ), 1 )
      ENDIF
   CASE nFoc == LP_FOC_WHILE
      lText := .T.
      cNew := UiLineEdit( nT + LP_R_WHILE, aG[ LPG_VAL ], aG[ LPG_WBIG ], ;
                          aSt[ LPX_WHILE ], .F., UI_C_LISTSEL, .F., .T. )
      IF ! hb_IsNIL( cNew )
         aSt[ LPX_WHILE ] := cNew
         IF ! LpCheckCond( aSt, cNew, LP_FOC_WHILE )
            lStay := .T.
         ENDIF
      ENDIF
   CASE nFoc == LP_FOC_FOR
      lText := .T.
      cNew := UiLineEdit( nT + LP_R_FOR, aG[ LPG_VAL ], aG[ LPG_WBIG ], ;
                          aSt[ LPX_FOR ], .F., UI_C_LISTSEL, .F., .T. )
      IF ! hb_IsNIL( cNew )
         aSt[ LPX_FOR ] := cNew
         IF ! LpCheckCond( aSt, cNew, LP_FOC_FOR )
            lStay := .T.
         ENDIF
      ENDIF
   ENDCASE
   IF lStay
      RETURN
   ENDIF
   IF lText .AND. UiEditExit() == K_SH_TAB
      LpFocus( aSt, -1 )
   ELSE
      LpFocus( aSt, 1 )
   ENDIF
RETURN

/* ---------- the two builders of the listing body ---------- */

/* the columns the listing prints, in the ORDER of the selection: { field
 * number, name, type, column width } */
STATIC FUNCTION LpCols( aSt )
   LOCAL a := {}, aWanted, i, n
   IF aSt[ LPX_SHAPE ] == LP_SH_MEMO
      aWanted := LpMemoFields( aSt[ LPX_SEL ], aSt[ LPX_TYPES ] )
   ELSE
      aWanted := aSt[ LPX_SEL ]
   ENDIF
   FOR i := 1 TO Len( aWanted )
      n := aWanted[ i ]
      IF n >= 1 .AND. n <= Len( aSt[ LPX_FIELDS ] )
         AAdd( a, { n, aSt[ LPX_FIELDS ][ n ], aSt[ LPX_TYPES ][ n ], ;
                    LpColWidth( aSt[ LPX_FIELDS ][ n ], aSt[ LPX_LENS ][ n ] ) } )
      ENDIF
   NEXT
RETURN a

/* the text of one field of the current record, as the listing prints it */
STATIC FUNCTION LpCellText( nField, cType )
   LOCAL x := FieldGet( nField ), aLin, c := ""
   DO CASE
   CASE Upper( cType ) == "N"
      RETURN LTrim( Str( x, FieldLen( nField ), FieldDec( nField ) ) )
   CASE Upper( cType ) == "D"
      RETURN DToC( x )
   CASE Upper( cType ) == "L"
      RETURN iif( x, "T", "F" )
   CASE Upper( cType ) == "M"
      /* a memo in a COLUMN shows only its first line: the column is as wide as
       * the field name and the whole content would be cut anyway. The whole
       * memo is what the "Memo Field" shape is for. */
      aLin := hb_ATokens( iif( ValType( x ) == "C", x, "" ), Chr( 10 ) )
      IF Len( aLin ) > 0
         c := AllTrim( StrTran( aLin[ 1 ], Chr( 13 ), "" ) )
      ENDIF
      RETURN c
   ENDCASE
RETURN AllTrim( iif( ValType( x ) == "C", x, "" ) )

/* the whole content of a memo field of the current record */
STATIC FUNCTION LpMemoText( nField )
   LOCAL x := FieldGet( nField )
RETURN iif( ValType( x ) == "C", x, "" )

/* S6: the ONE walk of the records of this program - "List to Print" and
 * "SUM/AVERAGE" both come through here, so SCOPE, WHILE, FOR, SET DELETED,
 * the cancel of the progress bar and the restored record pointer cannot drift
 * between the two screens. It moves inside the ACTIVE ORDER (dbGoTop() and
 * dbSkip() follow the controlling order, and RECORD n is the n-th record OF
 * THAT ORDER - dbGoto() would take the PHYSICAL RecNo, which under an index has
 * no relation to the position the user counted), and for every record the scope
 * accepts it runs bEach (NIL when the caller only wants the count), so the
 * caller decides what to do with the record and this loop decides WHICH records
 * there are.
 * Answers 0 = it finished, 1 = the user cancelled it, 2 = it failed (cErr then
 * carries the engine's reason); nRecs is the number of accepted records. */
STATIC FUNCTION LpWalkCore( nScope, nCount, bFor, bWhile, bEach, cProg, cErr, nRecs )
   LOCAL nWalk := 0, nSave := RecNo(), xRes, lDel := Set( _SET_DELETED )
   LOCAL lCancel := .F., oErr, nRes := 0, nTot, nStep, nSeen := 0, nProgTot
   DEFAULT nCount TO 1
   cErr  := NIL
   nRecs := 0
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      IF nScope == LP_SC_REC
         dbGoTop()
         IF nCount > 1
            dbSkip( nCount - 1 )
         ENDIF
      ELSEIF nScope == LP_SC_ALL
         dbGoTop()
      ENDIF
      nTot := Max( 1, LastRec() )
      /* one sync before walking: the record buffer reflects the record the loop
       * starts on (it used to be a dbSkip( 0 ) on EVERY record, which was one of
       * the costs that made the walks crawl) */
      dbSkip( 0 )
      /* the bar counts the records the walk has VISITED, never RecNo(): with an
       * index the physical record numbers jump all over the file and the counter
       * went from one number to another (reported by the user). RECORD n is one
       * record, NEXT n is n records and the rest is the whole table. */
      nProgTot := nTot
      DO CASE
      CASE nScope == LP_SC_REC
         nProgTot := 1
      CASE nScope == LP_SC_NEXT
         nProgTot := Min( Max( 1, nCount ), nTot )
      ENDCASE
      /* SPEED: the bar is only touched (and the keyboard polled) every nStep
       * records - 50,000 records give a step of 100 - not on every record */
      nStep := UiProgStep( nProgTot )
      UiProgBegin( cProg, nProgTot, .T. )
      DO WHILE ! Eof()
         IF nScope == LP_SC_NEXT
            nWalk++
            IF nWalk > nCount
               EXIT
            ENDIF
         ENDIF
         nSeen++
         IF nSeen % nStep == 0
            IF UiProgUpdate( nSeen, nProgTot )
               lCancel := .T.
               EXIT
            ENDIF
         ENDIF
         IF ! hb_IsNIL( bWhile )
            xRes := Eval( bWhile )
            IF ValType( xRes ) == "L" .AND. ! xRes
               EXIT
            ENDIF
         ENDIF
         xRes := .T.
         IF ! hb_IsNIL( bFor )
            xRes := Eval( bFor )
         ENDIF
         IF ValType( xRes ) != "L" .OR. xRes
            IF ! ( lDel .AND. Deleted() )
               /* the answer of the forms counts RECORDS, not lines: the
                * Columnar header is a line too, so Len( aLines ) told "2" for a
                * single listed record and the user rightly read it as two */
               nRecs := nRecs + 1
               IF ! hb_IsNIL( bEach )
                  Eval( bEach )
               ENDIF
            ENDIF
         ENDIF
         dbSkip()
         IF nScope == LP_SC_REC
            EXIT
         ENDIF
      ENDDO
      /* the last partial step: the bar ends full (one extra repaint, nothing) */
      IF ! lCancel
         UiProgUpdate( nProgTot, nProgTot )
      ENDIF
      UiProgEnd()
   RECOVER USING oErr
      UiProgEnd()
      cErr := oErr:Description
      nRes := 2
   END SEQUENCE
   /* the record pointer goes back to where the user had it: a listing or a sum
    * only READS the table and must not move the cursor of the browser */
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      IF nSave >= 1 .AND. nSave <= LastRec()
         dbGoto( nSave )
      ENDIF
   RECOVER
   END SEQUENCE
   IF nRes == 0 .AND. lCancel
      nRes := 1
   ENDIF
RETURN nRes

/* one record of the listing: the per-record half of the walk, kept OUT of the
 * loop so the loop is shared. It MUTATES the lines and the two flags it is
 * given - an array is a REFERENCE - so the block that calls it never has to
 * assign a captured variable. aFlg is { header already written, a record was
 * already listed }. */
STATIC PROCEDURE LpLineAdd( aLines, aCols, aNames, aWids, aFTy, aHTy, cSep, nShape, aFlg )
   LOCAL aVal, aPage, i
   DO CASE
   CASE nShape == LP_SH_COLS
      IF ! aFlg[ 1 ]
         AAdd( aLines, LpColLine( aNames, aWids, cSep, aHTy ) )
         aFlg[ 1 ] := .T.
      ENDIF
      aVal := {}
      FOR i := 1 TO Len( aCols )
         AAdd( aVal, LpCellText( aCols[ i ][ 1 ], aCols[ i ][ 3 ] ) )
      NEXT
      AAdd( aLines, LpColLine( aVal, aWids, cSep, aFTy ) )
   CASE nShape == LP_SH_PAGE
      aVal := {}
      FOR i := 1 TO Len( aCols )
         AAdd( aVal, LpCellText( aCols[ i ][ 1 ], aCols[ i ][ 3 ] ) )
      NEXT
      IF aFlg[ 2 ]
         AAdd( aLines, "" )
      ENDIF
      aPage := LpPageLines( aNames, aVal )
      FOR i := 1 TO Len( aPage )
         AAdd( aLines, aPage[ i ] )
      NEXT
      aFlg[ 2 ] := .T.
   OTHERWISE
      aVal := {}
      FOR i := 1 TO Len( aCols )
         AAdd( aVal, LpMemoText( aCols[ i ][ 1 ] ) )
      NEXT
      IF aFlg[ 2 ]
         AAdd( aLines, "" )
      ENDIF
      aPage := LpMemoLines( aNames, aVal )
      FOR i := 1 TO Len( aPage )
         AAdd( aLines, aPage[ i ] )
      NEXT
      aFlg[ 2 ] := .T.
   ENDCASE
RETURN

/* S8/S10: the listing. SCOPE, FOR and WHILE are the shared walk of
 * LpWalkCore(); here there is only what a LINE of the listing is, so the two
 * screens of this menu cannot read the table differently. The two conditions
 * arrive COMPILED (S8) and are evaluated per record. */
STATIC FUNCTION LpWalk( aSt, aCols, bFor, bWhile, cErr, nRecs )
   LOCAL aLines := {}, aNames := {}, aWids := {}, aFTy := {}, aHTy := {}
   LOCAL aFlg := { .F., .F. }
   LOCAL i, nRes, cSep := LpSepText( aSt[ LPX_SEP ] ), nShape := aSt[ LPX_SHAPE ]
   cErr := NIL
   FOR i := 1 TO Len( aCols )
      AAdd( aNames, aCols[ i ][ 2 ] )
      AAdd( aWids, aCols[ i ][ 4 ] )
      AAdd( aFTy, aCols[ i ][ 3 ] )
      /* a header is text: it is never right aligned */
      AAdd( aHTy, "C" )
   NEXT
   /* the header of the Columnar shape is a line like any other, built with the
    * SAME helper, so the column starts of the header and of the records cannot
    * drift. It is written with the FIRST record that is listed: a condition that
    * filters every record out has to leave an EMPTY listing, not a page with a
    * header and nothing under it. */
   nRes := LpWalkCore( aSt[ LPX_SCOPE ], Int( aSt[ LPX_COUNT ] ), bFor, bWhile, ;
                       {|| LpLineAdd( aLines, aCols, aNames, aWids, aFTy, aHTy, ;
                                      cSep, nShape, aFlg ) }, ;
                       "Listing " + Upper( Alias() ), @cErr, @nRecs )
   IF nRes == 2
      cErr := "Error while building the listing:" + hb_eol() + cErr
      aLines := {}
   ELSEIF nRes == 1
      cErr := "The listing was cancelled."
   ENDIF
RETURN aLines

/* S5/S6: the output. The two destinations write the SAME lines, so a file and a
 * printer cannot diverge. */
STATIC FUNCTION LpToFile( aLines, cFile, cErr )
   LOCAL nOut, i
   cErr := NIL
   nOut := FCreate( cFile )
   IF nOut < 0
      cErr := "Cannot create " + cFile + "."
      RETURN .F.
   ENDIF
   FOR i := 1 TO Len( aLines )
      FWrite( nOut, aLines[ i ] + hb_eol() )
   NEXT
   FClose( nOut )
RETURN .T.

/* S6: the job goes to a temporary file that is sent RAW to the printer chosen
 * in the form and erased right after; nothing of it stays on disk. */
STATIC FUNCTION LpToPrinter( aLines, cPrinter, cErr )
   LOCAL cTxt := "", lOk := .F., i
   cErr := NIL
   IF ! hb_IsFunction( "W32PrintText" )
      cErr := "This build has no printer support (W32PRINTTEXT is missing)."
      RETURN .F.
   ENDIF
   /* S6 of list-to-print.md: the listing is RENDERED by the printer driver, it
    * is NOT spooled as raw bytes. Measured: the raw path gives an EMPTY page on
    * GDI class drivers ("Microsoft Print to PDF", PDFCreator), which is exactly
    * what the user reported. W32PRINTTEXT() in bp_win32.c carries the whole
    * explanation; hbwin keeps doing what it does well, enumerating the printers. */
   FOR i := 1 TO Len( aLines )
      cTxt += aLines[ i ] + hb_eol()
   NEXT
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      lOk := W32PrintText( cPrinter, cTxt, "hwBro LIST" )
   RECOVER
      lOk := .F.
   END SEQUENCE
   IF ! lOk
      cErr := "The printer " + cPrinter + " did not accept the job."
   ENDIF
RETURN lOk

/* THE worker of Accept and of Ctrl-S: validate, build, write. It answers .T.
 * when the form has to CLOSE (the listing was produced) and .F. when the user
 * still has something to fix, with the message row already carrying why. */
STATIC FUNCTION LpRun( aG, aSt )
   LOCAL bFor, bWhile, cErr, aLines, aCols, cFile, lOk := .F., nRecs := 0
   LOCAL nCount := Int( aSt[ LPX_COUNT ] )
   DEFAULT aG TO NIL
   /* S8: both conditions are compiled BEFORE the run starts, so a typo cannot
    * leave a half-written listing behind */
   bFor := LpCondBlock( aSt[ LPX_FOR ], @cErr )
   IF ! hb_IsNIL( cErr )
      aSt[ LPX_MSG ] := cErr
      aSt[ LPX_ERR ] := .T.
      aSt[ LPX_FOCUS ] := LP_FOC_FOR
      RETURN .F.
   ENDIF
   bWhile := LpCondBlock( aSt[ LPX_WHILE ], @cErr )
   IF ! hb_IsNIL( cErr )
      aSt[ LPX_MSG ] := cErr
      aSt[ LPX_ERR ] := .T.
      aSt[ LPX_FOCUS ] := LP_FOC_WHILE
      RETURN .F.
   ENDIF
   IF LpSelCount( aSt[ LPX_SEL ] ) == 0
      aSt[ LPX_MSG ] := "No field is selected for the listing."
      aSt[ LPX_ERR ] := .T.
      aSt[ LPX_FOCUS ] := LP_FOC_FLD
      RETURN .F.
   ENDIF
   IF LpScopeNeedsCount( aSt[ LPX_SCOPE ] ) .AND. nCount < 1
      aSt[ LPX_MSG ] := "Count has to be 1 or more."
      aSt[ LPX_ERR ] := .T.
      aSt[ LPX_FOCUS ] := LP_FOC_CNT
      RETURN .F.
   ENDIF
   IF aSt[ LPX_SCOPE ] == LP_SC_REC .AND. ;
      ( nCount < 1 .OR. nCount > LastRec() )
      aSt[ LPX_MSG ] := "Record " + LTrim( Str( nCount ) ) + " is not in the database."
      aSt[ LPX_ERR ] := .T.
      aSt[ LPX_FOCUS ] := LP_FOC_CNT
      RETURN .F.
   ENDIF
   IF aSt[ LPX_TO ] == LP_TO_FILE
      cFile := AllTrim( aSt[ LPX_FILE ] )
      IF Len( cFile ) == 0
         aSt[ LPX_MSG ] := "Enter the file name of the listing."
         aSt[ LPX_ERR ] := .T.
         aSt[ LPX_FOCUS ] := LP_FOC_FILE
         RETURN .F.
      ENDIF
   ELSEIF Len( AllTrim( aSt[ LPX_PRT ] ) ) == 0
      aSt[ LPX_MSG ] := "There is no printer installed."
      aSt[ LPX_ERR ] := .T.
      aSt[ LPX_FOCUS ] := LP_FOC_PRT
      RETURN .F.
   ENDIF
   aCols := LpCols( aSt )
   aLines := LpWalk( aSt, aCols, bFor, bWhile, @cErr, @nRecs )
   IF ! hb_IsNIL( cErr )
      aSt[ LPX_MSG ] := cErr
      aSt[ LPX_ERR ] := .T.
      RETURN .F.
   ENDIF
   IF Len( aLines ) == 0
      aSt[ LPX_MSG ] := "No record matches the scope."
      aSt[ LPX_ERR ] := .T.
      RETURN .F.
   ENDIF
   IF aSt[ LPX_TO ] == LP_TO_FILE
      lOk := LpToFile( aLines, cFile, @cErr )
      IF lOk
         aSt[ LPX_MSG ] := LTrim( Str( nRecs ) ) + " record(s) written to " + cFile + "."
      ENDIF
   ELSE
      lOk := LpToPrinter( aLines, aSt[ LPX_PRT ], @cErr )
      IF lOk
         aSt[ LPX_MSG ] := LTrim( Str( nRecs ) ) + " record(s) sent to " + ;
                           aSt[ LPX_PRT ] + "."
      ENDIF
   ENDIF
   IF ! lOk
      aSt[ LPX_MSG ] := cErr
      aSt[ LPX_ERR ] := .T.
      RETURN .F.
   ENDIF
   aSt[ LPX_ERR ] := .F.
RETURN .T.

STATIC PROCEDURE LpHelp()
   UiTextWin( { ;
      "List to Print - keys", ;
      "", ;
      "  Tab / Shift-Tab    next / previous control", ;
      "  Up / Down          same as Tab / Shift-Tab", ;
      "  Enter              open the control (a list, or the field editor),", ;
      "                     and when it closes the focus moves to the NEXT one", ;
      "  Space / Ins        same as Enter", ;
      "  Ctrl-S / Alt-A     Accept: build the listing", ;
      "  Alt-F              the field selection screen", ;
      "  Alt-L T S W O      jump to LIST / TO / SCOPE / WHILE / FOR", ;
      "  Alt-E R I          jump to File / Separator / Printer", ;
      "  Alt-N              jump to Count", ;
      "  Alt-C / Alt-X      leave without listing", ;
      "  F1 / Esc           this help / cancel", ;
      "", ;
      "LIST is the shape of the listing and TO the destination: both are", ;
      "LISTS, and the value that is in force is the highlighted one.", ;
      "", ;
      "With TO = FILE the form asks for the file name (LIST.TXT) and for the", ;
      "separator between fields: ONE character, and an EMPTY box means one", ;
      "space. With a separator the line comes out like CSV.", ;
      "With TO = PRINT it lists the printers of Windows and sends the listing", ;
      "raw to the one chosen.", ;
      "", ;
      "SCOPE is ALL / NEXT / REST / RECORD and Count only exists with NEXT", ;
      "and RECORD. WHILE and FOR are xBase expressions evaluated on every", ;
      "record: FOR filters (the record is skipped) and WHILE CUTS the listing", ;
      "at the first false. Both are compiled before anything is written, and", ;
      "one that does not compile keeps the focus on its field.", ;
      "", ;
      "The field screen lists every field in file order; Space or a click", ;
      "adds it and shows its ORDER NUMBER, which is the column order of the", ;
      "listing. Removing one renumbers the rest.", ;
      "" }, "List to Print" )
RETURN

/* =====================================================================
 *  the field selection screen (S3)
 * ---------------------------------------------------------------------
 *  Every field of the area in FILE order, the order number of the chosen ones
 *  at the left (the order of the COLS), Space/Enter/click to add or remove and
 *  Accept/Cancel. Its own focus ring of three stops and its own painter, with
 *  the same rules as the form behind it.
 * ===================================================================== */

#define LPF_FOC_LIST    1
#define LPF_FOC_OK      2
#define LPF_FOC_CANCEL  3
#define LPF_FOC_MAX     3

#define LPFG_W          1
#define LPFG_L          2
#define LPFG_T          3
#define LPFG_B          4
#define LPFG_R          5
#define LPFG_ROWS       6
#define LPFG_MAX        6

#define LFX_FIELDS      1
#define LFX_TYPES       2
#define LFX_LENS        3
#define LFX_DECS        4
#define LFX_SEL         5
#define LFX_CUR         6
#define LFX_TOP         7
#define LFX_FOCUS       8
#define LFX_ROWS        9
#define LFX_MAX         9

/* the columns of a row, relative to the left inside of the box */
#define LPF_C_NR        2
#define LPF_C_NAME      6
#define LPF_C_TYPE     19
#define LPF_C_LEN      22
#define LPF_C_DEC      27
#define LPF_BTN1       34
#define LPF_BTN2       48

STATIC FUNCTION LpFieldsGeom( nFields )
   LOCAL nH := Min( Max( 14, nFields + 7 ), UiRows() - 4 )
   LOCAL nW := Min( 62, UiCols() - 8 )
   LOCAL aG := Array( LPFG_MAX )
   aG[ LPFG_W ]    := nW
   aG[ LPFG_L ]    := UiCenterCol( nW )
   aG[ LPFG_R ]    := aG[ LPFG_L ] + nW - 1
   aG[ LPFG_T ]    := UiCenterRow( nH )
   aG[ LPFG_B ]    := aG[ LPFG_T ] + nH - 1
   aG[ LPFG_ROWS ] := Max( 3, nH - 6 )
RETURN aG

STATIC PROCEDURE LpFieldsDraw( aG, aEd, cTitle )
   LOCAL nT := aG[ LPFG_T ], nL := aG[ LPFG_L ], nB := aG[ LPFG_B ], nR := aG[ LPFG_R ]
   LOCAL nIn := nR - nL - 3
   LOCAL i, nF, nOrd, cRow, lFoc, cCap := " " + cTitle + " Fields "
   HcSyncCtlReset()
   UiPaintBegin()
   UiShadow( nT, nL, nB, nR )
   UiFillBox( nT, nL, nB, nR, UI_C_BOX )
   UiFrame( nT, nL, nB, nR, UI_C_BOXBORD, .T. )
   SetColor( UI_C_FLATBG )
   @ nT + 1, nL + Max( 1, Int( ( aG[ LPFG_W ] - Len( cCap ) ) / 2 ) ) SAY cCap
   SetColor( UI_C_BOX )
   @ nT + 2, nL + LPF_C_NR SAY PadR( " Nr Field Name     T  Len  Dec", nIn )
   FOR i := 1 TO aG[ LPFG_ROWS ]
      nF := aEd[ LFX_TOP ] + i - 1
      IF nF < 1 .OR. nF > Len( aEd[ LFX_FIELDS ] )
         SetColor( UI_C_BOX )
         @ nT + 2 + i, nL + LPF_C_NR SAY Space( nIn )
         LOOP
      ENDIF
      nOrd := LpSelOrder( aEd[ LFX_SEL ], nF )
      cRow := iif( nOrd > 0, PadL( LTrim( Str( nOrd ) ), 3 ), "   " ) + " " + ;
              PadR( aEd[ LFX_FIELDS ][ nF ], 12 ) + " " + ;
              PadR( aEd[ LFX_TYPES ][ nF ], 2 ) + " " + ;
              PadL( LTrim( Str( aEd[ LFX_LENS ][ nF ] ) ), 3 ) + " " + ;
              PadL( LTrim( Str( aEd[ LFX_DECS ][ nF ] ) ), 3 )
      lFoc := aEd[ LFX_FOCUS ] == LPF_FOC_LIST .AND. nF == aEd[ LFX_CUR ]
      /* three states, each one a pair the program already had: the row of the
       * cursor is the FOCUS colour, a field that is in the listing carries the
       * "picked" band of a marked record, and the rest sits on the box. In the
       * Dark theme UI_C_BOX and UI_C_FLATBG are the SAME pair, so the picked
       * rows need a band of their own or a selected field could not be told
       * from an unselected one but by its number. */
      SetColor( iif( lFoc, UI_C_LISTSEL, iif( nOrd > 0, UI_C_RECSEL, UI_C_BOX ) ) )
      @ nT + 2 + i, nL + LPF_C_NR SAY PadR( cRow, nIn )
      HcSyncCtlAdd( nT + 2 + i, nL + LPF_C_NR, nIn, "LPFROW", nF )
   NEXT
   SetColor( UI_C_FLATBG )
   @ nB - 2, nL + LPF_C_NR SAY " " + LTrim( Str( LpSelCount( aEd[ LFX_SEL ] ) ) ) + ;
                               " field(s) "
   LpPaintBtn( nB - 2, nL + LPF_BTN1, "[ ~A~ccept ]", ;
               aEd[ LFX_FOCUS ] == LPF_FOC_OK, LPF_FOC_OK, "LPBTN" )
   LpPaintBtn( nB - 2, nL + LPF_BTN2, "[ ~C~ancel ]", ;
               aEd[ LFX_FOCUS ] == LPF_FOC_CANCEL, LPF_FOC_CANCEL, "LPBTN" )
   SetColor( UI_C_BOX )
   @ nB - 1, nL + LPF_C_NR SAY PadR( "Space/Enter: Add-Remove   Up/Down   PgUp/PgDn   " + ;
                                     "Tab: Move   F1: Help   Esc: Cancel", nIn )
   UiPaintEnd()
RETURN

STATIC PROCEDURE LpFieldsMove( aEd, nTo )
   LOCAL n := Len( aEd[ LFX_FIELDS ] ), nRows := aEd[ LFX_ROWS ]
   IF n < 1
      RETURN
   ENDIF
   aEd[ LFX_CUR ] := Max( 1, Min( nTo, n ) )
   IF aEd[ LFX_CUR ] < aEd[ LFX_TOP ]
      aEd[ LFX_TOP ] := aEd[ LFX_CUR ]
   ENDIF
   IF aEd[ LFX_CUR ] > aEd[ LFX_TOP ] + nRows - 1
      aEd[ LFX_TOP ] := aEd[ LFX_CUR ] - nRows + 1
   ENDIF
   IF aEd[ LFX_TOP ] < 1
      aEd[ LFX_TOP ] := 1
   ENDIF
RETURN

STATIC FUNCTION LpFieldsKey( nKey, nShift, cAlt, aEd )
   LOCAL lCtrl := hb_bitAnd( nShift, HB_GTI_KBD_CTRL ) != 0
   LOCAL lAlt  := hb_bitAnd( nShift, HB_GTI_KBD_ALT ) != 0
   LOCAL nRows := aEd[ LFX_ROWS ]
   DO CASE
   CASE Len( cAlt ) > 0
      DO CASE
      CASE cAlt == "A" ; RETURN "ok"
      CASE cAlt == "C" .OR. cAlt == "X" ; RETURN "cancel"
      ENDCASE
      RETURN ""
   CASE nKey == K_ESC ; RETURN "cancel"
   CASE nKey == K_F1  ; RETURN "help"
   CASE nKey == K_ENTER .OR. nKey == K_SPACE
      IF aEd[ LFX_FOCUS ] == LPF_FOC_OK
         RETURN "ok"
      ENDIF
      IF aEd[ LFX_FOCUS ] == LPF_FOC_CANCEL
         RETURN "cancel"
      ENDIF
      RETURN "toggle"
   CASE nKey == K_TAB .OR. nKey == K_RIGHT
      RETURN "next"
   CASE nKey == K_SH_TAB .OR. nKey == K_LEFT
      RETURN "prev"
   CASE aEd[ LFX_FOCUS ] == LPF_FOC_LIST
      DO CASE
      CASE nKey == K_UP   ; RETURN "up"
      CASE nKey == K_DOWN ; RETURN "down"
      CASE nKey == K_PGUP ; RETURN "pgup"
      CASE nKey == K_PGDN ; RETURN "pgdn"
      CASE nKey == K_HOME ; RETURN "home"
      CASE nKey == K_END  ; RETURN "end"
      ENDCASE
      /* the wheel is read by the loop: it moves one row per notch */
   ENDCASE
RETURN ""

STATIC PROCEDURE LpFieldsHelp( cTitle )
   UiTextWin( { ;
      cTitle + " Fields - keys", ;
      "", ;
      "  Up / Down          one field", ;
      "  PgUp / PgDn        one page of fields", ;
      "  Home / End         first / last field", ;
      "  Space / Enter      add or remove the field under the cursor", ;
      "  click              the same on the row clicked", ;
      "  Tab / Shift-Tab    move between the list and the two buttons", ;
      "  Alt-A / Alt-C      Accept / Cancel", ;
      "  F1 / Esc           this help / cancel", ;
      "", ;
      "The number at the left IS the order number of the field: the first", ;
      "field picked is number 1. Removing a field from the middle renumbers", ;
      "the ones behind it, and a field that is not picked shows no number.", ;
      "" }, cTitle + " Fields" )
RETURN

/* S3: the field screen, shared by "List to Print" and "SUM/AVERAGE" - ONE
 * picker, because a second copy would drift. It gets the parallel arrays of the
 * fields it may offer (its own filter is already applied: the LIST screen hands
 * over every field, the SUM one only the numeric ones) and the selection it
 * starts with, and answers the NEW selection in the order the fields were
 * picked, or NIL when the screen was cancelled. */
STATIC FUNCTION LpFieldPick( aFld, aTyp, aLen, aDec, aSel, cTitle )
   LOCAL aG, aEd, aNew := NIL, lDone := .F., lPaint := .T., cAct := ""
   LOCAL nKey, nShift, cAlt, aPt, aCtl, cSave, cOldCur, nF
   IF ! HB_ISARRAY( aFld ) .OR. Len( aFld ) == 0
      RETURN NIL
   ENDIF
   aG := LpFieldsGeom( Len( aFld ) )
   aEd := Array( LFX_MAX )
   aEd[ LFX_FIELDS ] := aFld
   aEd[ LFX_TYPES ]  := aTyp
   aEd[ LFX_LENS ]   := aLen
   aEd[ LFX_DECS ]   := aDec
   aEd[ LFX_SEL ]    := aSel
   aEd[ LFX_CUR ]    := 1
   aEd[ LFX_TOP ]    := 1
   aEd[ LFX_FOCUS ]  := LPF_FOC_LIST
   aEd[ LFX_ROWS ]   := aG[ LPFG_ROWS ]
   cOldCur := SetCursor( 0 )
   cSave := SaveScreen( aG[ LPFG_T ], aG[ LPFG_L ], Min( MaxRow(), aG[ LPFG_B ] + 1 ), ;
                        Min( MaxCol(), aG[ LPFG_R ] + 2 ) )
   DO WHILE ! lDone
      IF lPaint
         LpFieldsDraw( aG, aEd, cTitle )
         lPaint := .F.
      ENDIF
      cAct := ""
      nKey   := Inkey( 0.05 )
      nShift := hb_gtInfo( HB_GTI_KBDSHIFTS )
      cAlt   := HcAltChord()
      /* a chord a FIELD EDITOR left pending: UiLineEdit() asks the Alt hook,
       * keeps the letter pending and closes, so the caller has to take it with
       * UiAltChord() - draining only the ring loses the keystroke. */
      IF Len( cAlt ) == 0
         cAlt := UiAltChord()
      ENDIF
      IF UiCloseAsk()
         cAct := "cancel"
      ENDIF
      /* right-click-esc (S1/S7): a plain right click cancels the picker, the
       * same as Esc and as the Cancel button */
      IF Empty( cAct ) .AND. HcMouseRightClick()
         cAct := "cancel"
      ENDIF
      IF Empty( cAct )
         IF nKey == 0 .AND. Len( cAlt ) == 0
            aPt := UiClick()
            IF HB_ISARRAY( aPt )
               aCtl := HcSyncCtlAt( aPt[ 1 ], aPt[ 2 ] )
               IF ! hb_IsNIL( aCtl )
                  DO CASE
                  CASE aCtl[ 4 ] == "LPBTN"
                     aEd[ LFX_FOCUS ] := aCtl[ 5 ]
                     cAct := iif( aCtl[ 5 ] == LPF_FOC_OK, "ok", "cancel" )
                  CASE aCtl[ 4 ] == "LPFROW"
                     /* S3: a click on a row adds or removes it */
                     nF := aCtl[ 5 ]
                     LpFieldsMove( aEd, nF )
                     aEd[ LFX_FOCUS ] := LPF_FOC_LIST
                     aEd[ LFX_SEL ] := LpSelToggle( aEd[ LFX_SEL ], nF )
                     cAct := "paint"
                  ENDCASE
               ENDIF
            ENDIF
         ELSE
            cAct := LpFieldsKey( nKey, nShift, cAlt, aEd )
         ENDIF
      ENDIF
      IF Empty( cAct )
         LOOP
      ENDIF
      DO CASE
      CASE cAct == "cancel"
         lDone := .T.
      CASE cAct == "ok"
         aNew := aEd[ LFX_SEL ]
         lDone := .T.
      CASE cAct == "help"
         LpFieldsHelp( cTitle )
         lPaint := .T.
      CASE cAct == "paint"
         lPaint := .T.
      CASE cAct == "toggle"
         IF aEd[ LFX_FOCUS ] == LPF_FOC_LIST
            aEd[ LFX_SEL ] := LpSelToggle( aEd[ LFX_SEL ], aEd[ LFX_CUR ] )
         ENDIF
         lPaint := .T.
      CASE cAct == "up"
         LpFieldsMove( aEd, aEd[ LFX_CUR ] - 1 )
         lPaint := .T.
      CASE cAct == "down"
         LpFieldsMove( aEd, aEd[ LFX_CUR ] + 1 )
         lPaint := .T.
      CASE cAct == "pgup"
         LpFieldsMove( aEd, aEd[ LFX_CUR ] - aEd[ LFX_ROWS ] )
         lPaint := .T.
      CASE cAct == "pgdn"
         LpFieldsMove( aEd, aEd[ LFX_CUR ] + aEd[ LFX_ROWS ] )
         lPaint := .T.
      CASE cAct == "home"
         LpFieldsMove( aEd, 1 )
         lPaint := .T.
      CASE cAct == "end"
         LpFieldsMove( aEd, Len( aEd[ LFX_FIELDS ] ) )
         lPaint := .T.
      CASE cAct == "next"
         aEd[ LFX_FOCUS ] := iif( aEd[ LFX_FOCUS ] == LPF_FOC_LIST, LPF_FOC_OK, ;
                               iif( aEd[ LFX_FOCUS ] == LPF_FOC_OK, LPF_FOC_CANCEL, ;
                                    LPF_FOC_LIST ) )
         lPaint := .T.
      CASE cAct == "prev"
         aEd[ LFX_FOCUS ] := iif( aEd[ LFX_FOCUS ] == LPF_FOC_LIST, LPF_FOC_CANCEL, ;
                               iif( aEd[ LFX_FOCUS ] == LPF_FOC_OK, LPF_FOC_LIST, ;
                                    LPF_FOC_OK ) )
         lPaint := .T.
      ENDCASE
   ENDDO
   RestScreen( aG[ LPFG_T ], aG[ LPFG_L ], Min( MaxRow(), aG[ LPFG_B ] + 1 ), ;
               Min( MaxCol(), aG[ LPFG_R ] + 2 ), cSave )
   SetCursor( cOldCur )
   SetColor( UI_C_DESKTOP )
RETURN aNew

/* the "List to Print" side of the shared field screen: it offers EVERY field of
 * the file in file order, and only replaces the selection when the user
 * accepted it */
STATIC FUNCTION LpFields( aSt )
   LOCAL aSel := LpFieldPick( aSt[ LPX_FIELDS ], aSt[ LPX_TYPES ], aSt[ LPX_LENS ], ;
                              aSt[ LPX_DECS ], aSt[ LPX_SEL ], "LIST" )
   IF ! hb_IsNIL( aSel )
      aSt[ LPX_SEL ] := aSel
      aSt[ LPX_MSG ] := ""
      aSt[ LPX_ERR ] := .F.
   ENDIF
RETURN NIL

/* the row of the menu: open the form over the browser */
FUNCTION BpCmdListToPrint()
   LOCAL aG, aSt, lPaint := .T., lDone := .F., lListed := .F., cAct := ""
   LOCAL nKey, nShift, cAlt, aPt, aCtl, cSave, cOldCur
   IF ! BpNeedDb()
      RETURN NIL
   ENDIF
   aG  := LpGeom()
   aSt := LpStateNew()
   IF Empty( aSt[ LPX_FIELDS ] )
      UiMsg( "No database fields.", "List to Print" )
      RETURN NIL
   ENDIF
   cOldCur := SetCursor( 0 )
   cSave := SaveScreen( aG[ LPG_T ], aG[ LPG_L ], Min( MaxRow(), aG[ LPG_B ] + 1 ), ;
                        Min( MaxCol(), aG[ LPG_R ] + 2 ) )
   DO WHILE ! lDone
      IF lPaint
         LpDraw( aG, aSt )
         lPaint := .F.
      ENDIF
      cAct := ""
      /* 50 ms slices so the click and the chord of the window hook are seen
       * (the mouse of this driver never arrives through Inkey()) */
      nKey   := Inkey( 0.05 )
      nShift := hb_gtInfo( HB_GTI_KBDSHIFTS )
      cAlt   := HcAltChord()
      /* a chord a FIELD EDITOR left pending: UiLineEdit() asks the Alt hook,
       * keeps the letter pending and closes, so the caller has to take it with
       * UiAltChord() - draining only the ring loses the keystroke. */
      IF Len( cAlt ) == 0
         cAlt := UiAltChord()
      ENDIF
      IF UiCloseAsk()
         cAct := "cancel"
      ENDIF
      /* right-click-esc (S1/S7): a plain right click cancels the form, exactly
       * as Esc and the X of the window do above */
      IF Empty( cAct ) .AND. HcMouseRightClick()
         cAct := "cancel"
      ENDIF
      IF Empty( cAct )
         IF nKey == 0 .AND. Len( cAlt ) == 0
            aPt := UiClick()
            IF HB_ISARRAY( aPt )
               aCtl := HcSyncCtlAt( aPt[ 1 ], aPt[ 2 ] )
               IF ! hb_IsNIL( aCtl )
                  IF aCtl[ 4 ] == "LPBTN"
                     /* a click on a button ACTS, exactly like its key */
                     aSt[ LPX_FOCUS ] := aCtl[ 5 ]
                     DO CASE
                     CASE aCtl[ 5 ] == LP_FOC_OK     ; cAct := "run"
                     CASE aCtl[ 5 ] == LP_FOC_CANCEL ; cAct := "cancel"
                     OTHERWISE                       ; cAct := "fields"
                     ENDCASE
                  ELSEIF aCtl[ 5 ] == aSt[ LPX_FOCUS ]
                     /* a second click on the control that already has the
                      * focus OPENS it, exactly like Enter */
                     cAct := "edit"
                  ELSE
                     aSt[ LPX_FOCUS ] := aCtl[ 5 ]
                     lPaint := .T.
                  ENDIF
               ENDIF
            ENDIF
         ELSE
            cAct := LpKeyAct( nKey, nShift, cAlt, aSt )
            /* typing enters the input it is standing on (rule of the forms of
             * this program) and seeds a NEW value there */
            IF Empty( cAct ) .AND. nKey >= 32 .AND. nKey <= 126 .AND. ;
               LpIsText( aSt[ LPX_FOCUS ] ) .AND. LpSeed( aSt, Chr( nKey ) )
               aSt[ LPX_ERR ] := .F.
               aSt[ LPX_MSG ] := ""
               cAct := "edit"
            ENDIF
         ENDIF
      ENDIF
      IF Empty( cAct )
         LOOP
      ENDIF
      DO CASE
      CASE cAct == "cancel"
         lDone := .T.
      CASE cAct == "help"
         LpHelp()
         lPaint := .T.
      CASE cAct == "focus"
         lPaint := .T.
      CASE cAct == "fields"
         LpFields( aSt )
         lPaint := .T.
      CASE cAct == "edit"
         LpEdit( aG, aSt )
         lPaint := .T.
      CASE cAct == "run"
         IF LpRun( aG, aSt )
            lListed := .T.
            lDone := .T.
         ENDIF
         lPaint := .T.
      ENDCASE
   ENDDO
   LpSaveState( aSt )
   RestScreen( aG[ LPG_T ], aG[ LPG_L ], Min( MaxRow(), aG[ LPG_B ] + 1 ), ;
               Min( MaxCol(), aG[ LPG_R ] + 2 ), cSave )
   SetCursor( cOldCur )
   SetColor( UI_C_DESKTOP )
   /* the result is told ONCE, over the restored screen: the message row of a
    * form that has just closed would not be read */
   IF lListed
      UiInfo( aSt[ LPX_MSG ], "List to Print" )
   ENDIF
RETURN NIL

FUNCTION BpCmdPack()
   LOCAL oErr
   IF ! BpNeedDb() ; RETURN NIL ; ENDIF
   IF ! UiConfirm( "PACK: permanently remove marked records ?", "Pack" )
      RETURN NIL
   ENDIF
   UiProgBusy( "Packing..." )
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      hb_dbPack()
      UiProgEnd()
      UiInfo( "PACK done. Records: " + LTrim( Str( LastRec() ) ), "Pack" )
   RECOVER USING oErr
      UiProgEnd()
      UiErr( "Error in PACK: " + oErr:Description )
   END SEQUENCE
RETURN NIL

FUNCTION BpCmdRecall()
   LOCAL oErr
   IF ! BpNeedDb() ; RETURN NIL ; ENDIF
   IF UiConfirm( "RECALL ALL: recall all deleted records ?", "Recall" )
      UiProgBusy( "Recalling records..." )
      BEGIN SEQUENCE WITH {| e | Break( e ) }
         RECALL ALL
         UiProgEnd()
      RECOVER USING oErr
         UiProgEnd()
         UiErr( "Error in RECALL: " + oErr:Description )
      END SEQUENCE
   ENDIF
RETURN NIL

FUNCTION BpCmdReindex()
   LOCAL oErr
   IF ! BpNeedDb() ; RETURN NIL ; ENDIF
   IF ! UiConfirm( "Reindex all open index files ?", "ReIndex" )
      RETURN NIL
   ENDIF
   /* long process: ALWAYS with the progress box (user request) */
   UiProgBusy( "Reindexing..." )
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      REINDEX
      UiProgEnd()
      UiInfo( "Reindex done.", "ReIndex" )
   RECOVER USING oErr
      UiProgEnd()
      UiErr( "Error in REINDEX: " + oErr:Description )
   END SEQUENCE
RETURN NIL

/* =====================================================================
 *  F8 - CommandTools -> "Replace"   (odd/tasks/replace-form.md)
 * ---------------------------------------------------------------------
 *  The form of the original: the yellow title REPLACE, the GREEN "REPLACE
 *  Field", the RED expression boxes (WITH / WHILE / FOR) and the SCOPE chip.
 *  The interior is dark gray instead of the bright blue of BRO.EXE -with
 *  FONTA_DRAWBOX this driver only gives eight BACKGROUNDS and the clone already
 *  spends all of them (AGENTS.md 4)- but the green of the field and the red of
 *  the expressions ARE the measured pairs (UI_C_DLGFIELD / UI_C_DLGRED).
 *
 *  The value is captured BY TYPE: text for C/M, digits and signs for N, the
 *  DToC( Date() ) PICTURE (the SET DATE FORMAT of F6 GlobalSet) for D and a
 *  checkbox for L. Nothing is written until the value and the scope are
 *  validated, and the record numbers are collected FIRST: replacing a KEY field
 *  changes the order under the dbSkip() of the walk, so the walk cannot write
 *  and navigate at the same time.
 * ===================================================================== */

#define RP_FOC_FLD    1     /* focus stops, in VISUAL order */
#define RP_FOC_WITH   2
#define RP_FOC_SCOPE  3
#define RP_FOC_CNT    4
#define RP_FOC_WHILE  5
#define RP_FOC_FOR    6
#define RP_FOC_OK     7     /* [ Accept ]  */
#define RP_FOC_CANCEL 8     /* [ Cancel ]  */
#define RP_FOC_MAX    8

#define RP_SC_ALL     1     /* SCOPE chip */
#define RP_SC_NEXT    2
#define RP_SC_REST    3
#define RP_SC_REC     4
#define RP_SC_MAX     4

#define RP_G_W        1     /* geometry, computed by RpGeom() */
#define RP_G_L        2
#define RP_G_T        3
#define RP_G_B        4
#define RP_G_R        5
#define RP_G_LBL      6
#define RP_G_VAL      7
#define RP_G_WFLD     8
#define RP_G_WLBL     9
#define RP_G_WVAL    10
#define RP_G_WWITH   11
#define RP_G_CBLBL   12
#define RP_G_CVAL    13
#define RP_G_CW      14
#define RP_G_BIG     15
#define RP_G_SCW     16
#define RP_G_MAX     16

#define RPX_FIELDS    1     /* the form state */
#define RPX_FLD       2
#define RPX_VAL       3
#define RPX_SCOPE     4
#define RPX_COUNT     5
#define RPX_WHILE     6
#define RPX_FOR       7
#define RPX_FOCUS     8
#define RPX_TYPE      9
#define RPX_LEN      10
#define RPX_DEC      11
#define RPX_MSG      12
#define RPX_ERR      13
#define RPX_MAX      13

/* every field name of the open database, in .DBF order */
FUNCTION RpFieldList()
   LOCAL a := {}, i
   IF ! Used()
      RETURN a
   ENDIF
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      FOR i := 1 TO FCount()
         AAdd( a, FieldName( i ) )
      NEXT
   RECOVER
      a := {}
   END SEQUENCE
RETURN a

/* type/length/decimals of a field, .F. when the name is not one of this file */
FUNCTION BpRpFieldInfo( cField, cType, nLen, nDec )
   LOCAL n
   DEFAULT cType TO "" ; DEFAULT nLen TO 0 ; DEFAULT nDec TO 0
   cType := "" ; nLen := 0 ; nDec := 0
   IF ! Used()
      RETURN .F.
   ENDIF
   n := FieldPos( cField )
   IF n <= 0
      RETURN .F.
   ENDIF
   cType := Upper( FieldType( n ) )
   nLen  := FieldLen( n )
   nDec  := FieldDec( n )
RETURN .T.

/* "N(8,2)", "C(20)": the type as the form shows it */
FUNCTION RpTypeText( cType, nLen, nDec )
RETURN cType + "(" + LTrim( Str( nLen ) ) + ;
       iif( nDec > 0, "," + LTrim( Str( nDec ) ), "" ) + ")"

/* SCOPE: label of the chip, whether it takes a count, and the cycle */
FUNCTION RpScopeText( nScope )
   DO CASE
   CASE nScope == RP_SC_NEXT ; RETURN "NEXT"
   CASE nScope == RP_SC_REST ; RETURN "REST"
   CASE nScope == RP_SC_REC  ; RETURN "RECORD"
   ENDCASE
RETURN "ALL"

/* the Count of the SCOPE exists only with NEXT and RECORD. The rule is ONE and
 * it lives in bp_ui.prg (ApScopeNeedsCount(), with the ring of the Append From
 * form), so this door and that form cannot disagree */
FUNCTION RpScopeNeedsCount( nScope )
RETURN ApScopeNeedsCount( nScope )

FUNCTION RpFocusStep( nFrom, nDir, nScope )
   LOCAL n := nFrom, i
   DEFAULT nDir TO 1
   IF ValType( n ) != "N" .OR. n < 1 .OR. n > RP_FOC_MAX
      n := RP_FOC_FLD
   ENDIF
   FOR i := 1 TO RP_FOC_MAX
      n += iif( nDir < 0, -1, 1 )
      IF n > RP_FOC_MAX
         n := RP_FOC_FLD
      ENDIF
      IF n < RP_FOC_FLD
         n := RP_FOC_MAX
      ENDIF
      IF n == RP_FOC_CNT .AND. ! RpScopeNeedsCount( nScope )
         LOOP
      ENDIF
      RETURN n
   NEXT
RETURN nFrom

/* ---------- the form ---------- */

STATIC FUNCTION RpGeom()
   LOCAL nW := Min( 96, UiCols() - 8 )
   LOCAL nL := UiCenterCol( nW )
   LOCAL nR := nL + nW - 1
   LOCAL nT := UiCenterRow( 18 )
   LOCAL nV := nL + 18
   LOCAL nWith := nL + 54
   LOCAL aG := Array( RP_G_MAX )
   aG[ RP_G_W ]     := nW
   aG[ RP_G_L ]     := nL
   aG[ RP_G_T ]     := nT
   aG[ RP_G_B ]     := nT + 17
   aG[ RP_G_R ]     := nR
   aG[ RP_G_LBL ]   := nL + 2
   aG[ RP_G_VAL ]   := nV
   aG[ RP_G_WFLD ]  := 26
   aG[ RP_G_WLBL ]  := nL + 46
   aG[ RP_G_WVAL ]  := nWith
   aG[ RP_G_WWITH ] := Max( 12, nR - 2 - nWith + 1 )
   aG[ RP_G_CBLBL ] := nV + 18
   aG[ RP_G_CVAL ]  := nV + 25
   aG[ RP_G_CW ]    := 8
   aG[ RP_G_BIG ]   := Max( 20, nR - 2 - nV + 1 )
   aG[ RP_G_SCW ]   := 14
RETURN aG

STATIC FUNCTION RpStateNew()
   LOCAL aSt := Array( RPX_MAX )
   LOCAL aFld := RpFieldList()
   aSt[ RPX_FIELDS ] := aFld
   aSt[ RPX_FLD ]    := iif( Empty( aFld ), "", aFld[ 1 ] )
   aSt[ RPX_VAL ]    := ""
   aSt[ RPX_SCOPE ]  := RP_SC_ALL
   aSt[ RPX_COUNT ]  := 0
   aSt[ RPX_WHILE ]  := ""
   aSt[ RPX_FOR ]    := ""
   aSt[ RPX_FOCUS ]  := RP_FOC_FLD
   aSt[ RPX_MSG ]    := ""
   aSt[ RPX_ERR ]    := .F.
   /* session memory: field, scope and conditions come back (in Harbour an
    * array is a REFERENCE, so they are copied element by element - trap 67) */
   IF HB_ISARRAY( s_aRpLast ) .AND. Len( s_aRpLast ) == 5
      IF ValType( s_aRpLast[ 1 ] ) == "C" .AND. ;
         FieldPos( s_aRpLast[ 1 ] ) > 0
         aSt[ RPX_FLD ] := s_aRpLast[ 1 ]
      ENDIF
      IF ValType( s_aRpLast[ 2 ] ) == "N" .AND. ;
         s_aRpLast[ 2 ] >= RP_SC_ALL .AND. s_aRpLast[ 2 ] <= RP_SC_MAX
         aSt[ RPX_SCOPE ] := s_aRpLast[ 2 ]
      ENDIF
      IF ValType( s_aRpLast[ 3 ] ) == "N"
         aSt[ RPX_COUNT ] := s_aRpLast[ 3 ]
      ENDIF
      IF ValType( s_aRpLast[ 4 ] ) == "C"
         aSt[ RPX_WHILE ] := s_aRpLast[ 4 ]
      ENDIF
      IF ValType( s_aRpLast[ 5 ] ) == "C"
         aSt[ RPX_FOR ] := s_aRpLast[ 5 ]
      ENDIF
   ENDIF
   RpSyncType( aSt )
RETURN aSt

STATIC PROCEDURE RpSaveState( aSt )
   s_aRpLast := { aSt[ RPX_FLD ], aSt[ RPX_SCOPE ], aSt[ RPX_COUNT ], ;
                  aSt[ RPX_WHILE ], aSt[ RPX_FOR ] }
RETURN

/* the type of the selected field drives how its VALUE is captured */
STATIC PROCEDURE RpSyncType( aSt )
   LOCAL cType, nLen, nDec
   IF BpRpFieldInfo( aSt[ RPX_FLD ], @cType, @nLen, @nDec )
      aSt[ RPX_TYPE ] := cType
      aSt[ RPX_LEN ]  := nLen
      aSt[ RPX_DEC ]  := nDec
   ELSE
      aSt[ RPX_TYPE ] := "C"
      aSt[ RPX_LEN ]  := 10
      aSt[ RPX_DEC ]  := 0
   ENDIF
RETURN

/* move the focus one stop; .T. when it really moved */
STATIC FUNCTION RpFocus( aSt, nDir )
   LOCAL n := RpFocusStep( aSt[ RPX_FOCUS ], nDir, aSt[ RPX_SCOPE ] )
   IF n == aSt[ RPX_FOCUS ]
      RETURN .F.
   ENDIF
   aSt[ RPX_FOCUS ] := n
RETURN .T.

STATIC FUNCTION RpAct( lOk, cAct )
RETURN iif( lOk, cAct, "" )

/* ONE text field: the INPUT carries its own background (green for the field
 * chip, red for the expressions) and the FOCUS is painted on the input itself,
 * which is the only band a control of this program has. It REGISTERS the
 * control while it paints it, so a click and the keyboard cannot disagree. */
STATIC PROCEDURE RpPaintFld( nRow, nCol, nW, cText, cRest, lFoc, nStop, cKind )
   SetColor( iif( lFoc, UI_C_LISTSEL, cRest ) )
   @ nRow, nCol SAY PadR( Left( iif( ValType( cText ) == "C", cText, "" ), nW ), nW )
   HcSyncCtlAdd( nRow, nCol, nW, cKind, nStop )
RETURN

/* a control that is NOT available right now: dimmed and NOT registered, so
 * neither a click nor Tab reaches it (the rule of the File search form) */
STATIC PROCEDURE RpPaintDim( nRow, nCol, nW, cText )
   SetColor( UI_C_BOXDIM )
   @ nRow, nCol SAY PadR( Left( cText, nW ), nW )
RETURN

STATIC PROCEDURE RpLabel( nRow, nCol, cText )
   UiDrawHot( nRow, nCol, cText, UI_C_BOX, UI_C_HOT )
RETURN

/* one button of the form: `[ ~A~ccept ]`. Flat at rest (`UI_C_FLATBG`, the cyan
 * of the box: the brackets are what make it read as a button), brown with the
 * focus (`UI_C_BOXSEL`) and the quick letter in `UI_C_HOTSEL`. */
STATIC PROCEDURE RpPaintBtn( nRow, nCol, cLabel, lFoc, nStop )
   LOCAL cPair := iif( lFoc, UI_C_BOXSEL, UI_C_FLATBG )
   LOCAL nW := UiHotLen( cLabel )
   SetColor( cPair )
   @ nRow, nCol SAY Space( nW )
   UiDrawHot( nRow, nCol, cLabel, cPair, iif( lFoc, UI_C_HOTSEL, UI_C_HOT ) )
   HcSyncCtlAdd( nRow, nCol, nW, "RPBTN", nStop )
RETURN

/* the whole box: shadow, frame, title, the four rows, the message and the hint
 * row. Painted INSIDE one paint block, and it is where the controls of the
 * mouse are registered (HcSyncCtlReset() first, one entry per control). */
STATIC PROCEDURE RpDraw( aG, aSt )
   LOCAL nT := aG[ RP_G_T ], nL := aG[ RP_G_L ]
   LOCAL nB := aG[ RP_G_B ], nR := aG[ RP_G_R ]
   LOCAL nLbl := aG[ RP_G_LBL ]
   LOCAL nRowSc := nT + 5, nRowWhile := nT + 7, nRowFor := nT + 9
   LOCAL nRowMsg := nT + 11
   LOCAL nRowBtn := nT + 13
   LOCAL cCnt
   LOCAL lFocSc := aSt[ RPX_FOCUS ] == RP_FOC_SCOPE
   HcSyncCtlReset()
   UiPaintBegin()
   /* the box of the forms of the Commander: shadow, cyan body, cyan frame
    * (skill pantallas-de-formulario) */
   UiShadow( nT, nL, nB, nR )
   UiFillBox( nT, nL, nB, nR, UI_C_BOX )
   UiFrame( nT, nL, nB, nR, UI_C_BOXBORD, .T. )
   /* title: a white chip inside the box, centered */
   SetColor( UI_C_FLATBG )
   @ nT + 1, nL + Int( ( aG[ RP_G_W ] - 9 ) / 2 ) SAY " REPLACE "
   /* row 1: the field picker and the WITH EXPRESSION (one input pair) */
   RpLabel( nT + 3, nLbl, "REPLACE ~F~ield:" )
   RpPaintFld( nT + 3, aG[ RP_G_VAL ], aG[ RP_G_WFLD ], aSt[ RPX_FLD ], ;
               UI_C_FIELDBG, aSt[ RPX_FOCUS ] == RP_FOC_FLD, RP_FOC_FLD, "RPFLD" )
   RpLabel( nT + 3, aG[ RP_G_WLBL ], "~W~ITH:" )
   RpPaintFld( nT + 3, aG[ RP_G_WVAL ], aG[ RP_G_WWITH ], aSt[ RPX_VAL ], ;
               UI_C_FIELDBG, aSt[ RPX_FOCUS ] == RP_FOC_WITH, RP_FOC_WITH, "RPFLD" )
   /* row 2: SCOPE (a SELECT of the four values, like the field picker) */
   RpLabel( nRowSc, nLbl, "~S~COPE:" )
   RpPaintFld( nRowSc, aG[ RP_G_VAL ], aG[ RP_G_SCW ], RpScopeText( aSt[ RPX_SCOPE ] ), ;
               UI_C_FIELDBG, lFocSc, RP_FOC_SCOPE, "RPFLD" )
   RpLabel( nRowSc, aG[ RP_G_CBLBL ], "Count:" )
   cCnt := LTrim( Str( aSt[ RPX_COUNT ] ) )
   IF RpScopeNeedsCount( aSt[ RPX_SCOPE ] )
      RpPaintFld( nRowSc, aG[ RP_G_CVAL ], aG[ RP_G_CW ], cCnt, UI_C_FIELDBG, ;
                  aSt[ RPX_FOCUS ] == RP_FOC_CNT, RP_FOC_CNT, "RPFLD" )
   ELSE
      RpPaintDim( nRowSc, aG[ RP_G_CVAL ], aG[ RP_G_CW ], cCnt )
   ENDIF
   /* rows 3 and 4: WHILE and FOR */
   RpLabel( nRowWhile, nLbl, "WHI~L~E:" )
   RpPaintFld( nRowWhile, aG[ RP_G_VAL ], aG[ RP_G_BIG ], aSt[ RPX_WHILE ], ;
               UI_C_FIELDBG, aSt[ RPX_FOCUS ] == RP_FOC_WHILE, RP_FOC_WHILE, "RPFLD" )
   RpLabel( nRowFor, nLbl, "FO~R~:" )
   RpPaintFld( nRowFor, aG[ RP_G_VAL ], aG[ RP_G_BIG ], aSt[ RPX_FOR ], ;
               UI_C_FIELDBG, aSt[ RPX_FOCUS ] == RP_FOC_FOR, RP_FOC_FOR, "RPFLD" )
   /* message: the type of the field, or why nothing was written */
   IF aSt[ RPX_ERR ]
      SetColor( UI_C_ERR )
      @ nRowMsg, nLbl SAY PadR( Left( aSt[ RPX_MSG ], aG[ RP_G_BIG ] ), aG[ RP_G_BIG ] )
   ELSE
      SetColor( UI_C_FLATBG )
      @ nRowMsg, nLbl SAY PadR( "Field " + aSt[ RPX_FLD ] + "  " + ;
            RpTypeText( aSt[ RPX_TYPE ], aSt[ RPX_LEN ], aSt[ RPX_DEC ] ) + "   " + ;
            Left( aSt[ RPX_MSG ], aG[ RP_G_BIG ] ), aG[ RP_G_BIG ] )
   ENDIF
   /* the two buttons, side by side like the rest of the forms */
   RpPaintBtn( nRowBtn, nLbl, "[ ~A~ccept ]", aSt[ RPX_FOCUS ] == RP_FOC_OK, RP_FOC_OK )
   RpPaintBtn( nRowBtn, nLbl + 14, "[ ~C~ancel ]", aSt[ RPX_FOCUS ] == RP_FOC_CANCEL, RP_FOC_CANCEL )
   /* hint row: only the keys this screen really has */
   SetColor( UI_C_BOX )
   @ nT + 15, nLbl SAY "Tab: Move   Enter: Select   Ctrl-S: Replace   " + ;
                       "F1: Help   Esc: Cancel"
   UiPaintEnd()
RETURN

/* the key -> action table of the form. It MUTATES the focus/scope (a ring step
 * is not an action) and answers the action the loop runs, "" for a key that
 * does nothing here. `Alt+<letter>` comes from the ring of the window hook only
 * (trap 61) and the letter is already upper case. */
STATIC FUNCTION RpKeyAct( nKey, nShift, cAlt, aSt )
   LOCAL lCtrl := hb_bitAnd( nShift, HB_GTI_KBD_CTRL ) != 0
   LOCAL lAlt  := hb_bitAnd( nShift, HB_GTI_KBD_ALT ) != 0
   DO CASE
   CASE Len( cAlt ) > 0
      DO CASE
      CASE cAlt == "F" ; aSt[ RPX_FOCUS ] := RP_FOC_FLD   ; RETURN "focus"
      CASE cAlt == "W" ; aSt[ RPX_FOCUS ] := RP_FOC_WITH  ; RETURN "focus"
      CASE cAlt == "S" ; aSt[ RPX_FOCUS ] := RP_FOC_SCOPE ; RETURN "focus"
      CASE cAlt == "L" ; aSt[ RPX_FOCUS ] := RP_FOC_WHILE ; RETURN "focus"
      CASE cAlt == "R" ; aSt[ RPX_FOCUS ] := RP_FOC_FOR   ; RETURN "focus"
      CASE cAlt == "A" ; RETURN "run"
      CASE cAlt == "C" .OR. cAlt == "X" ; RETURN "cancel"
      ENDCASE
      /* a chord nobody serves is DROPPED: it must not type anything later */
      RETURN ""
   CASE nKey == K_ESC ; RETURN "cancel"
   CASE nKey == K_F1  ; RETURN "help"
   /* Ctrl-S: this driver hands it over as the code of K_LEFT (19) WITH the CTRL
    * bit (trap 71), so the code alone is not the rule and ALT disqualifies it
    * (AltGr is Ctrl+Alt, trap 38) */
   CASE lCtrl .AND. ! lAlt .AND. ( nKey == K_CTRL_S .OR. nKey == Asc( "s" ) .OR. ;
                                   nKey == Asc( "S" ) )
      RETURN "run"
   CASE nKey == K_ENTER
      DO CASE
      CASE aSt[ RPX_FOCUS ] == RP_FOC_OK     ; RETURN "run"
      CASE aSt[ RPX_FOCUS ] == RP_FOC_CANCEL ; RETURN "cancel"
      CASE aSt[ RPX_FOCUS ] == RP_FOC_FOR    ; RETURN "run"
      ENDCASE
      RETURN "edit"
   CASE nKey == K_INS .OR. nKey == K_SPACE
      IF aSt[ RPX_FOCUS ] == RP_FOC_OK
         RETURN "run"
      ENDIF
      IF aSt[ RPX_FOCUS ] == RP_FOC_CANCEL
         RETURN "cancel"
      ENDIF
      RETURN "edit"
   CASE nKey == K_TAB .OR. nKey == K_DOWN .OR. nKey == K_RIGHT
      RETURN RpAct( RpFocus( aSt, 1 ), "focus" )
   CASE nKey == K_SH_TAB .OR. nKey == K_UP .OR. nKey == K_LEFT
      RETURN RpAct( RpFocus( aSt, -1 ), "focus" )
   ENDCASE
RETURN ""

/* open the control that has the focus and MOVE THE RING when it is confirmed:
 * Enter, Tab and a selection in a list all leave the focus on the NEXT control
 * (Shift-Tab goes back), which is the rule of the forms of this project
 * ("completar avanza"). Esc keeps the focus where it is. The WITH is VALIDATED
 * when its editor closes: if the expression does not compile or its result is
 * not of the type of the field, the message row says why and the form does NOT
 * advance. */
STATIC PROCEDURE RpEdit( aG, aSt )
   LOCAL nFoc := aSt[ RPX_FOCUS ], cNew, n, nIdx
   LOCAL lStay := .F.
   DO CASE
   CASE nFoc == RP_FOC_FLD
      nIdx := 1
      n := FieldPos( aSt[ RPX_FLD ] )
      IF n > 0 .AND. n <= Len( aSt[ RPX_FIELDS ] )
         nIdx := n
      ENDIF
      n := UiPick( aSt[ RPX_FIELDS ], "Replace Field", nIdx )
      IF ValType( n ) == "N" .AND. n > 0 .AND. n <= Len( aSt[ RPX_FIELDS ] )
         IF ! ( aSt[ RPX_FIELDS ][ n ] == aSt[ RPX_FLD ] )
            aSt[ RPX_FLD ] := aSt[ RPX_FIELDS ][ n ]
            aSt[ RPX_VAL ] := ""
         ENDIF
         aSt[ RPX_MSG ] := ""
         aSt[ RPX_ERR ] := .F.
         RpSyncType( aSt )
      ELSE
         /* the list was closed with Esc (UiPick answers 0): nothing moves */
         lStay := .T.
      ENDIF
   CASE nFoc == RP_FOC_SCOPE
      /* a SELECT of the four values, like the field picker above */
      n := UiPick( { RpScopeText( RP_SC_ALL ), RpScopeText( RP_SC_NEXT ), ;
                     RpScopeText( RP_SC_REST ), RpScopeText( RP_SC_REC ) }, ;
                   "SCOPE", aSt[ RPX_SCOPE ] )
      IF ValType( n ) == "N" .AND. n >= RP_SC_ALL .AND. n <= RP_SC_MAX
         aSt[ RPX_SCOPE ] := n
         aSt[ RPX_ERR ] := .F.
         aSt[ RPX_MSG ] := ""
      ELSE
         lStay := .T.
      ENDIF
   CASE nFoc == RP_FOC_CNT
      cNew := UiLineEdit( aG[ RP_G_T ] + 5, aG[ RP_G_CVAL ], aG[ RP_G_CW ], ;
                          LTrim( Str( aSt[ RPX_COUNT ] ) ), .T., UI_C_LISTSEL, .F., .T. )
      IF ! hb_IsNIL( cNew )
         n := Val( cNew )
         aSt[ RPX_COUNT ] := iif( n > 0, Int( n ), 1 )
      ENDIF
   CASE nFoc == RP_FOC_WHILE
      cNew := UiLineEdit( aG[ RP_G_T ] + 7, aG[ RP_G_VAL ], aG[ RP_G_BIG ], ;
                          aSt[ RPX_WHILE ], .F., UI_C_LISTSEL, .F., .T. )
      IF ! hb_IsNIL( cNew )
         aSt[ RPX_WHILE ] := cNew
      ENDIF
   CASE nFoc == RP_FOC_FOR
      cNew := UiLineEdit( aG[ RP_G_T ] + 9, aG[ RP_G_VAL ], aG[ RP_G_BIG ], ;
                          aSt[ RPX_FOR ], .F., UI_C_LISTSEL, .F., .T. )
      IF ! hb_IsNIL( cNew )
         aSt[ RPX_FOR ] := cNew
      ENDIF
   CASE nFoc == RP_FOC_WITH
      /* the value is an EXPRESSION: whatever it answers is evaluated per
       * record and has to be of the type of the field. No mask and no digits
       * filter here, or `Upper( "Hola" )` could not be typed. */
      cNew := UiLineEdit( aG[ RP_G_T ] + 3, aG[ RP_G_WVAL ], aG[ RP_G_WWITH ], ;
                          aSt[ RPX_VAL ], .F., UI_C_LISTSEL, .F., .T. )
      IF ! hb_IsNIL( cNew )
         aSt[ RPX_VAL ] := cNew
         aSt[ RPX_ERR ] := .F.
         aSt[ RPX_MSG ] := ""
         /* L4: validated ON LEAVING the input; a bad one keeps the focus here */
         IF ! RpCheckWith( aSt )
            lStay := .T.
         ENDIF
      ENDIF
   ENDCASE
   IF lStay
      RETURN
   ENDIF
   /* confirmed: the ring moves (Enter and Tab forward, Shift-Tab back) */
   IF UiEditExit() == K_SH_TAB
      RpFocus( aSt, -1 )
   ELSE
      RpFocus( aSt, 1 )
   ENDIF
RETURN

/* L4: the WITH is checked WHEN THE FIELD IS LEFT. It has to compile and the
 * result on the current record has to be of the type of the field; when it is
 * not, the message row carries the reason and the form does NOT advance. */
STATIC FUNCTION RpCheckWith( aSt )
   LOCAL b, cErr, oErr, lOk := .F.
   b := RpWithBlock( aSt[ RPX_VAL ], @cErr )
   IF ! hb_IsNIL( cErr )
      aSt[ RPX_MSG ] := cErr ; aSt[ RPX_ERR ] := .T.
      RETURN .F.
   ENDIF
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      RpAsType( Eval( b ), aSt[ RPX_TYPE ], aSt[ RPX_LEN ], aSt[ RPX_DEC ], @cErr )
      lOk := hb_IsNIL( cErr )
   RECOVER USING oErr
      cErr := "The WITH expression failed:" + hb_eol() + oErr:Description
      lOk := .F.
   END SEQUENCE
   IF ! lOk
      aSt[ RPX_MSG ] := cErr ; aSt[ RPX_ERR ] := .T.
   ENDIF
RETURN lOk


/* the WITH expression, compiled ONCE before touching a single record. cErr comes
 * back NIL when it compiles and with the reason when it does not. */
FUNCTION RpWithBlock( cExpr, cErr )
   LOCAL b := NIL, oErr
   cErr := NIL
   IF Len( AllTrim( cExpr ) ) == 0
      cErr := "Enter a value or an expression for WITH."
      RETURN NIL
   ENDIF
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      b := &( "{|| " + cExpr + " }" )
   RECOVER USING oErr
      cErr := "The WITH expression does not compile:" + hb_eol() + oErr:Description
      b := NIL
   END SEQUENCE
RETURN b

/* the RESULT of the expression has to BE of the type of the destination (L3);
 * StructConvert() then fits it to the width and the decimals. cErr comes back
 * NIL when the value is good and with the reason when it is not, and then the
 * caller writes nothing. */
FUNCTION RpAsType( xVal, cType, nLen, nDec, cErr )
   LOCAL cGot := ValType( xVal ), cWant
   cErr := NIL
   DO CASE
   CASE cType == "C" .OR. cType == "M" ; cWant := "C"
   CASE cType == "N"                  ; cWant := "N"
   CASE cType == "D"                  ; cWant := "D"
   CASE cType == "L"                  ; cWant := "L"
   OTHERWISE                           ; cWant := cType
   ENDCASE
   IF ! ( cGot == cWant ) .AND. ! hb_IsNIL( xVal )
      cErr := "The expression has to answer a " + RpTypeName( cWant ) + ;
              " for " + RpTypeText( cType, nLen, nDec ) + ", and it answered " + ;
              RpTypeName( cGot ) + "."
      RETURN NIL
   ENDIF
   IF hb_IsNIL( xVal )
      cErr := "The expression answered NIL, which is not a " + RpTypeName( cWant ) + "."
      RETURN NIL
   ENDIF
   IF cWant == "N" .AND. Len( AllTrim( Str( xVal, nLen + 24, nDec ) ) ) > nLen
      cErr := "The number does not fit in " + RpTypeText( cType, nLen, nDec ) + "."
      RETURN NIL
   ENDIF
RETURN StructConvert( xVal, { "", cType, nLen, nDec } )

/* the name of a ValType() as the message reads it */
FUNCTION RpTypeName( cType )
   LOCAL c := Upper( iif( ValType( cType ) == "C", cType, "" ) )
   DO CASE
   CASE c == "C" ; RETURN "Character"
   CASE c == "N" ; RETURN "Number"
   CASE c == "D" ; RETURN "Date"
   CASE c == "L" ; RETURN "Logical"
   CASE c == "M" ; RETURN "Memo"
   CASE c == "A" ; RETURN "Array"
   CASE c == "B" ; RETURN "Block"
   CASE c == "U" ; RETURN "NIL"
   ENDCASE
RETURN c

/* the records the operation touches, as RecNo() numbers. They are collected
 * BEFORE writing anything: a REPLACE on a key field reorders the index under
 * the dbSkip() of the walk, so walking and writing at the same time would skip
 * or repeat records. */
STATIC FUNCTION RpTargets( aSt, cErr )
   LOCAL aRecs := {}, bFor, bWhile, oErr, nWalk := 0
   LOCAL nScope := aSt[ RPX_SCOPE ], nCount := Int( aSt[ RPX_COUNT ] )
   LOCAL xRes, lDeleted := Set( _SET_DELETED )
   cErr := NIL
   /* S5: the conditions are compiled BEFORE touching a single record */
   bFor := NIL ; bWhile := NIL
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      IF Len( AllTrim( aSt[ RPX_FOR ] ) ) > 0
         bFor := &( "{|| " + aSt[ RPX_FOR ] + " }" )
      ENDIF
      IF Len( AllTrim( aSt[ RPX_WHILE ] ) ) > 0
         bWhile := &( "{|| " + aSt[ RPX_WHILE ] + " }" )
      ENDIF
   RECOVER USING oErr
      cErr := "The FOR/WHILE condition does not compile:" + hb_eol() + oErr:Description
      RETURN aRecs
   END SEQUENCE
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      IF nScope == RP_SC_REC
         IF nCount > 0 .AND. nCount <= LastRec()
            AAdd( aRecs, nCount )
         ENDIF
      ELSE
         IF nScope == RP_SC_ALL
            dbGoTop()
         ENDIF
         DO WHILE ! Eof()
            IF nScope == RP_SC_NEXT
               nWalk++
               IF nWalk > nCount
                  EXIT
               ENDIF
            ENDIF
            IF ! hb_IsNIL( bWhile )
               xRes := Eval( bWhile )
               IF ValType( xRes ) == "L" .AND. ! xRes
                  EXIT
               ENDIF
            ENDIF
            IF ! ( lDeleted .AND. Deleted() )
               IF hb_IsNIL( bFor )
                  AAdd( aRecs, RecNo() )
               ELSE
                  xRes := Eval( bFor )
                  IF ValType( xRes ) == "L" .AND. xRes
                     AAdd( aRecs, RecNo() )
                  ENDIF
               ENDIF
            ENDIF
            dbSkip()
         ENDDO
      ENDIF
   RECOVER USING oErr
      cErr := "Error reading the scope:" + hb_eol() + oErr:Description
      aRecs := {}
   END SEQUENCE
RETURN aRecs

/* validate, confirm, write. It answers .T. when the form has to CLOSE: the
 * operation ran to the end (or was cancelled by the user, who has already been
 * told what was written). */
STATIC FUNCTION RpApply( aG, aSt )
   LOCAL cField := aSt[ RPX_FLD ], cType := aSt[ RPX_TYPE ]
   LOCAL xVal, cErr, aRecs, nFld, i, nDone := 0, oErr, lCancel := .F., bWith
   LOCAL nLen := aSt[ RPX_LEN ], nDec := aSt[ RPX_DEC ], nTot, nStep
   DEFAULT aG TO NIL
   /* L3: the WITH is an EXPRESSION. It is COMPILED first, and the result of its
    * first evaluation has to be of the type of the destination: both things
    * happen before a single record is written */
   bWith := RpWithBlock( aSt[ RPX_VAL ], @cErr )
   IF ! hb_IsNIL( cErr )
      aSt[ RPX_MSG ] := cErr ; aSt[ RPX_ERR ] := .T.
      RETURN .F.
   ENDIF
   aRecs := RpTargets( aSt, @cErr )
   IF ! hb_IsNIL( cErr )
      aSt[ RPX_MSG ] := cErr ; aSt[ RPX_ERR ] := .T.
      RETURN .F.
   ENDIF
   IF Empty( aRecs )
      aSt[ RPX_MSG ] := "No record matches the scope." ; aSt[ RPX_ERR ] := .T.
      RETURN .F.
   ENDIF
   nFld := FieldPos( cField )
   IF nFld <= 0
      aSt[ RPX_MSG ] := "The field " + cField + " is not in the database." ; aSt[ RPX_ERR ] := .T.
      RETURN .F.
   ENDIF
   /* the dry run on the first target, so a wrong TYPE is told BEFORE writing */
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      dbGoto( aRecs[ 1 ] )
      xVal := RpAsType( Eval( bWith ), cType, nLen, nDec, @cErr )
   RECOVER USING oErr
      cErr := "The WITH expression failed:" + hb_eol() + oErr:Description
   END SEQUENCE
   IF ! hb_IsNIL( cErr )
      aSt[ RPX_MSG ] := cErr ; aSt[ RPX_ERR ] := .T.
      RETURN .F.
   ENDIF
   IF ! UiConfirm( "Replace " + cField + " in " + LTrim( Str( Len( aRecs ) ) ) + ;
                   " record(s)?", "Replace" )
      aSt[ RPX_MSG ] := "Replace cancelled." ; aSt[ RPX_ERR ] := .F.
      RETURN .F.
   ENDIF
   cErr := NIL
   nTot := Len( aRecs )
   nStep := UiProgStep( nTot )
   UiProgBegin( "Replacing " + cField, nTot, .T. )
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      FOR i := 1 TO nTot
         /* SPEED: the bar and the keyboard are touched every nStep records */
         IF i % nStep == 0 .OR. i == nTot
            IF UiProgUpdate( i, nTot )
               lCancel := .T.
               EXIT
            ENDIF
         ENDIF
         dbGoto( aRecs[ i ] )
         /* the expression is evaluated ON EVERY RECORD (that is what lets
          * `Upper( nombre )` or `precio * 1.21` mean something) */
         xVal := RpAsType( Eval( bWith ), cType, nLen, nDec, @cErr )
         IF ! hb_IsNIL( cErr )
            EXIT
         ENDIF
         dbRLock()
         FieldPut( nFld, xVal )
         dbCommit()
         dbRUnlock()
         nDone++
      NEXT
   RECOVER USING oErr
      dbRUnlock()
      cErr := "Error after " + LTrim( Str( nDone ) ) + " record(s): " + oErr:Description
   END SEQUENCE
   UiProgEnd()
   IF ! hb_IsNIL( cErr )
      aSt[ RPX_MSG ] := cErr + iif( nDone > 0, " (" + LTrim( Str( nDone ) ) + ;
                                    " already written)", "" )
      aSt[ RPX_ERR ] := .T.
      RETURN .F.
   ENDIF
   aSt[ RPX_ERR ] := .F.
   aSt[ RPX_MSG ] := LTrim( Str( nDone ) ) + " record(s) replaced" + ;
                     iif( lCancel, ", cancelled.", "." )
RETURN ! lCancel

STATIC PROCEDURE RpHelp()
   UiTextWin( { ;
      "Replace - keys", ;
      "", ;
      "  Tab / Shift-Tab    next / previous control", ;
      "  Up / Down          same as Tab / Shift-Tab", ;
      "  Enter              edit the control, and when the editor closes the", ;
      "                     focus moves to the NEXT control", ;
      "  Space / Ins        same as Enter", ;
      "  Ctrl-S / Alt-A     Accept: replace", ;
      "  Alt-C / Alt-X      leave without writing", ;
      "  Alt-F W S L R      jump to Field / With / Scope / While / For", ;
      "  F1 / Esc           this help / cancel", ;
      "", ;
      "REPLACE Field and SCOPE are LISTS: Enter or a click opens them and the", ;
      "focus moves on when one is chosen. The WITH is checked when you leave", ;
      "it: it has to compile and its result has to be of the type of the", ;
      "field, or the message row says why and the form does not advance.", ;
      "", ;
      "With / While / For are xBase EXPRESSIONS evaluated on every record,", ;
      "and they are compiled before anything is written. The RESULT of With", ;
      "has to be of the TYPE of the field. For example:", ;
      "", ;
      "  Upper( 'Hola' )      case for a Character field", ;
      "  precio * 1.21        arithmetic for a Numeric field", ;
      "  Date() + 30          a Date field", ;
      "  .T.                  a Logical field", ;
      "", ;
      "A result of another type is refused and nothing is written.", ;
      "" }, "Replace" )
RETURN

FUNCTION BpCmdReplace()
   LOCAL aG, aSt, lPaint := .T., lDone := .F., cAct := ""
   LOCAL nKey, nShift, cAlt, aPt, aCtl, cSave, cOldCur
   IF ! BpNeedDb()
      RETURN NIL
   ENDIF
   aG  := RpGeom()
   aSt := RpStateNew()
   IF Empty( aSt[ RPX_FIELDS ] )
      UiMsg( "No database fields.", "Replace" )
      RETURN NIL
   ENDIF
   cOldCur := SetCursor( 0 )
   cSave := SaveScreen( aG[ RP_G_T ], aG[ RP_G_L ], Min( MaxRow(), aG[ RP_G_B ] + 1 ), ;
                        Min( MaxCol(), aG[ RP_G_R ] + 2 ) )
   DO WHILE ! lDone
      IF lPaint
         RpDraw( aG, aSt )
         lPaint := .F.
      ENDIF
      cAct := ""
      /* 50 ms slices so the click and the chord of the window hook are seen
       * (the mouse of this driver never arrives through Inkey()) */
      nKey   := Inkey( 0.05 )
      nShift := hb_gtInfo( HB_GTI_KBDSHIFTS )
      cAlt   := HcAltChord()
      /* a chord a FIELD EDITOR left pending: UiLineEdit() asks the Alt hook,
       * keeps the letter pending and closes, so the caller has to take it with
       * UiAltChord() - draining only the ring loses the keystroke. */
      IF Len( cAlt ) == 0
         cAlt := UiAltChord()
      ENDIF
      IF UiCloseAsk()
         cAct := "cancel"
      ENDIF
      /* right-click-esc (S1/S7): a plain right click cancels the form, exactly
       * as Esc and the X of the window do above */
      IF Empty( cAct ) .AND. HcMouseRightClick()
         cAct := "cancel"
      ENDIF
      IF Empty( cAct )
         IF nKey == 0 .AND. Len( cAlt ) == 0
            aPt := UiClick()
            IF HB_ISARRAY( aPt )
               aCtl := HcSyncCtlAt( aPt[ 1 ], aPt[ 2 ] )
               IF ! hb_IsNIL( aCtl )
                  IF aCtl[ 4 ] == "RPBTN"
                     /* a click on a button ACTS, exactly like its key */
                     aSt[ RPX_FOCUS ] := aCtl[ 5 ]
                     cAct := iif( aCtl[ 5 ] == RP_FOC_OK, "run", "cancel" )
                  ELSEIF aCtl[ 5 ] == aSt[ RPX_FOCUS ]
                     /* a second click on the control that already has the
                      * focus OPENS it, exactly like Enter */
                     cAct := "edit"
                  ELSE
                     aSt[ RPX_FOCUS ] := aCtl[ 5 ]
                     lPaint := .T.
                  ENDIF
               ENDIF
            ENDIF
         ELSE
            cAct := RpKeyAct( nKey, nShift, cAlt, aSt )
            /* a typed character ENTERS the value field it is standing on and
             * starts a NEW value there (the rule of the forms of this project):
             * the value is seeded and the editor opens on it */
            IF Empty( cAct ) .AND. nKey >= 32 .AND. nKey <= 126 .AND. ;
               aSt[ RPX_FOCUS ] == RP_FOC_WITH
               aSt[ RPX_VAL ] := Chr( nKey )
               aSt[ RPX_ERR ] := .F.
               cAct := "edit"
            ENDIF
         ENDIF
      ENDIF
      IF Empty( cAct )
         LOOP
      ENDIF
      DO CASE
      CASE cAct == "cancel"
         lDone := .T.
      CASE cAct == "help"
         RpHelp()
         lPaint := .T.
      CASE cAct == "focus"
         lPaint := .T.
      CASE cAct == "edit"
         RpEdit( aG, aSt )
         lPaint := .T.
      CASE cAct == "run"
         IF RpApply( aG, aSt )
            lDone := .T.
         ENDIF
         lPaint := .T.
      ENDCASE
   ENDDO
   RpSaveState( aSt )
   RestScreen( aG[ RP_G_T ], aG[ RP_G_L ], Min( MaxRow(), aG[ RP_G_B ] + 1 ), ;
               Min( MaxCol(), aG[ RP_G_R ] + 2 ), cSave )
   SetCursor( cOldCur )
   SetColor( UI_C_DESKTOP )
RETURN NIL

/* =====================================================================
 *  F8 - Append -> "Append From"   (odd/tasks/append-from-form.md)
 * ---------------------------------------------------------------------
 *  The row used to ask one UiInput() and run `APPEND FROM` as text. It is now
 *  a FORM screen of the same family as the Replace form above (skill
 *  pantallas-de-formulario): the title APPEND FROM of the user's capture, the
 *  two information lines of the TARGET database, the FIELDS chip on its OWN
 *  row UNDER the FROM row (S7/L7), FROM with its Path:/File: inputs and the
 *  [ Browse ] button, SCOPE with its Count, WHILE and FOR, a message row, the
 *  two buttons Accept / Cancel and a footer of key chips.
 *
 *  The chip opens the SELECTOR of the SOURCE fields; the structure of that
 *  file is read from its own .DBF header, WITHOUT opening it in a work area.
 *  The engine never uses the APPEND FROM command: the source is opened in its
 *  own free work area and every qualifying record is appended to the TARGET
 *  -the area that was current-, matching each SELECTED field BY NAME and
 *  writing it through StructConvert() (trap 22: FieldPut() neither converts
 *  nor clamps), inside BEGIN SEQUENCE with dbCommit() (trap 57).
 * ===================================================================== */

/* focus stops, in VISUAL order. The NUMBERING lives in bp_ui.prg, with the
 * rule ApFocusStep() that walks it (the headless bank pins it there); it is
 * repeated here because a .prg does not see the #define of another one */
#define AP_FOC_PATH    1
#define AP_FOC_FILE    2
#define AP_FOC_BROWSE  3    /* [ ~B~rowse ]    */
#define AP_FOC_FIELDS  4    /* the FIELDS chip */
#define AP_FOC_SCOPE   5
#define AP_FOC_CNT     6
#define AP_FOC_WHILE   7
#define AP_FOC_FOR     8
#define AP_FOC_OK      9    /* [ ~A~ccept ]    */
#define AP_FOC_CANCEL 10    /* [ ~C~ancel ]    */
#define AP_FOC_MAX    10

/* the state of the form */
#define APX_PATH      1
#define APX_FILE      2
#define APX_SCOPE     3
#define APX_COUNT     4
#define APX_WHILE     5
#define APX_FOR       6
#define APX_FOCUS     7
#define APX_SRCFLDS   8     /* { { cName, cType, nLen, nDec }, ... } of the SOURCE */
#define APX_SEL       9     /* one LOGICAL per field of the source               */
#define APX_SRCNAME  10     /* "CLIENTES.DBF" of the source, for the selector title */
#define APX_MSG      11
#define APX_ERR      12
#define APX_MAX      12

/* rows of the box, RELATIVE to its top: one blank row between two controls, so
 * a row that grows cannot push the one below. The FIELDS chip has a row of its
 * own UNDER the FROM row (S7 of odd/tasks/append-from-form.md, the user's L7) */
#define AP_R_TITLE     1
#define AP_R_INFO1     3
#define AP_R_INFO2     4
#define AP_R_FROM      6
#define AP_R_FIELDS    8
#define AP_R_SCOPE    10
#define AP_R_WHILE    12
#define AP_R_FOR      14
#define AP_R_MSG      16
#define AP_R_BTN      18
#define AP_R_HINT     19
#define AP_H          21

/* geometry slots, all computed by ApGeom() from UiCols()/UiRows() */
#define APG_W          1
#define APG_L          2
#define APG_T          3
#define APG_B          4
#define APG_R          5
#define APG_LBL        6
#define APG_PATHL      7
#define APG_PATH       8
#define APG_PATHW      9
#define APG_FILELBL   10
#define APG_FILE      11
#define APG_FILEW     12
#define APG_BROWSE    13
#define APG_CHIP      14
#define APG_CHIPW     15
#define APG_VAL       16
#define APG_SCW       17
#define APG_CBLBL     18
#define APG_CVAL      19
#define APG_WCNT      20
#define APG_BIG       21
#define APG_MAX       21

/* the field selector of the source */
#define APFG_W         1
#define APFG_L         2
#define APFG_R         3
#define APFG_T         4
#define APFG_B         5
#define APFG_ROWS      6
#define APFG_MAX       6

/* ---------- geometry ---------- */

STATIC FUNCTION ApGeom()
   LOCAL nW := Min( 100, UiCols() - 8 )
   LOCAL nL := UiCenterCol( nW )
   LOCAL nR := nL + nW - 1
   LOCAL nT := UiCenterRow( AP_H )
   LOCAL nLbl := nL + 2
   LOCAL nFrom := 7              /* "FROM " plus the arrow and a blank */
   LOCAL nBw := UiHotLen( "[ ~B~rowse ]" )
   LOCAL nAvail, nPathW, nFileW, aG
   /* the FROM row: FROM > | Path: | input | File: | input | [ Browse ] */
   nAvail := ( nR - 2 ) - ( nLbl + nFrom + 7 ) + 1
   nAvail -= 7 + nBw + 4
   nPathW := Max( 10, Int( nAvail * 6 / 10 ) )
   nFileW := Max( 8, nAvail - nPathW )
   aG := Array( APG_MAX )
   aG[ APG_W ]       := nW
   aG[ APG_L ]       := nL
   aG[ APG_T ]       := nT
   aG[ APG_B ]       := nT + AP_H - 1
   aG[ APG_R ]       := nR
   aG[ APG_LBL ]     := nLbl
   aG[ APG_PATHL ]   := nLbl + nFrom
   aG[ APG_PATH ]    := aG[ APG_PATHL ] + 7
   aG[ APG_PATHW ]   := nPathW
   aG[ APG_FILELBL ] := aG[ APG_PATH ] + nPathW + 2
   aG[ APG_FILE ]    := aG[ APG_FILELBL ] + 7
   aG[ APG_FILEW ]   := nFileW
   aG[ APG_BROWSE ]  := aG[ APG_FILE ] + nFileW + 2
   aG[ APG_CHIPW ]   := ApFieldsWidth()
   /* S7: the FIELDS chip lives on ITS OWN ROW below FROM, so its column is the
    * left one of the box and nothing else has to make room for it */
   aG[ APG_CHIP ]    := nLbl + 9
   aG[ APG_VAL ]     := nLbl + 7
   aG[ APG_SCW ]     := 10
   aG[ APG_CBLBL ]   := aG[ APG_VAL ] + 12
   aG[ APG_CVAL ]    := aG[ APG_CBLBL ] + 7
   aG[ APG_WCNT ]    := 6
   aG[ APG_BIG ]     := Max( 20, ( nR - 2 ) - ( nLbl + 7 ) + 1 )
RETURN aG

/* ---------- the state ---------- */

STATIC FUNCTION ApStateNew()
   LOCAL aSt := Array( APX_MAX )
   aSt[ APX_PATH ]    := ""
   aSt[ APX_FILE ]    := ""
   aSt[ APX_SCOPE ]   := RP_SC_ALL
   aSt[ APX_COUNT ]   := 0
   aSt[ APX_WHILE ]   := ""
   aSt[ APX_FOR ]     := ""
   aSt[ APX_FOCUS ]   := AP_FOC_PATH
   aSt[ APX_SRCFLDS ] := {}
   aSt[ APX_SEL ]     := {}
   aSt[ APX_SRCNAME ] := ""
   aSt[ APX_MSG ]     := ""
   aSt[ APX_ERR ]     := .F.
   /* S16: the form reopens with the source, the scope and the conditions of the
    * last time. Nothing goes to disk, and the array comes back element by
    * element because in Harbour it is a REFERENCE (trap 67) */
   IF HB_ISARRAY( s_aApLast ) .AND. Len( s_aApLast ) == 6
      IF ValType( s_aApLast[ 1 ] ) == "C"
         aSt[ APX_PATH ] := s_aApLast[ 1 ]
      ENDIF
      IF ValType( s_aApLast[ 2 ] ) == "C"
         aSt[ APX_FILE ] := s_aApLast[ 2 ]
      ENDIF
      IF ValType( s_aApLast[ 3 ] ) == "N" .AND. s_aApLast[ 3 ] >= RP_SC_ALL .AND. ;
         s_aApLast[ 3 ] <= RP_SC_MAX
         aSt[ APX_SCOPE ] := Int( s_aApLast[ 3 ] )
      ENDIF
      IF ValType( s_aApLast[ 4 ] ) == "N"
         aSt[ APX_COUNT ] := Int( s_aApLast[ 4 ] )
      ENDIF
      IF ValType( s_aApLast[ 5 ] ) == "C"
         aSt[ APX_WHILE ] := s_aApLast[ 5 ]
      ENDIF
      IF ValType( s_aApLast[ 6 ] ) == "C"
         aSt[ APX_FOR ] := s_aApLast[ 6 ]
      ENDIF
   ENDIF
   ApLoadSrc( aSt )
RETURN aSt

STATIC PROCEDURE ApSaveState( aSt )
   LOCAL a := {}, i
   s_aApLast := { aSt[ APX_PATH ], aSt[ APX_FILE ], aSt[ APX_SCOPE ], ;
                  aSt[ APX_COUNT ], aSt[ APX_WHILE ], aSt[ APX_FOR ] }
   FOR i := 1 TO Len( aSt[ APX_SEL ] )
      AAdd( a, ValType( aSt[ APX_SEL ][ i ] ) == "L" .AND. aSt[ APX_SEL ][ i ] )
   NEXT
   s_aApSel     := a
   s_cApSelFile := aSt[ APX_SRCNAME ]
RETURN

/* reads the structure of the file named in FROM and rebuilds the selection:
 * every box ticked for a NEW file, the remembered one when it is the SAME file
 * with the same number of fields (S8) */
STATIC PROCEDURE ApLoadSrc( aSt )
   LOCAL cFull, aSrc := {}, aSel := {}, i, lKeep
   cFull := HcJoinPath( aSt[ APX_PATH ], aSt[ APX_FILE ] )
   IF Len( AllTrim( aSt[ APX_FILE ] ) ) > 0
      aSrc := ApReadStruct( cFull )
   ENDIF
   aSt[ APX_SRCFLDS ] := aSrc
   IF Len( aSrc ) == 0
      aSt[ APX_SRCNAME ] := ""
      aSt[ APX_SEL ] := {}
      RETURN
   ENDIF
   aSt[ APX_SRCNAME ] := Upper( hb_FNameNameExt( cFull ) )
   lKeep := s_cApSelFile == aSt[ APX_SRCNAME ] .AND. HB_ISARRAY( s_aApSel ) .AND. ;
            Len( s_aApSel ) == Len( aSrc )
   FOR i := 1 TO Len( aSrc )
      IF lKeep
         AAdd( aSel, ValType( s_aApSel[ i ] ) == "L" .AND. s_aApSel[ i ] )
      ELSE
         AAdd( aSel, .T. )
      ENDIF
   NEXT
   aSt[ APX_SEL ] := aSel
RETURN

/* the two information lines of the TARGET, built like the header block of the
 * F2 menu (S4) */
STATIC FUNCTION ApInfoLine( nWhich )
   LOCAL aArea := CoreAreas(), i, nPos := 0, nTot := Len( aArea ), cFile := ""
   FOR i := 1 TO Len( aArea )
      IF aArea[ i ][ 1 ] == Select()
         nPos := i
      ENDIF
   NEXT
   IF Used()
      cFile := Upper( CoreFileBase() ) + ".DBF"
   ENDIF
   IF nWhich == 1
      RETURN "Selected:  (" + LTrim( Str( Max( nPos, 1 ) ) ) + "/" + ;
             LTrim( Str( Max( nTot, 1 ) ) ) + ")  " + ;
             iif( Len( cFile ) == 0, "None", cFile )
   ENDIF
RETURN "Controll. Driver:  " + iif( Len( cFile ) == 0, "", CoreDriver() + " / " + CoreMemoExt() )

/* what the message row says when nothing went wrong. A message that carries
 * hb_eol() -the reason a condition did not compile- is CUT to its first line:
 * an @..SAY does not wrap, so the control characters would be painted as two
 * symbols in the middle of the row (trap 19) */
STATIC FUNCTION ApMsgRow( aSt )
   LOCAL c
   IF Len( AllTrim( aSt[ APX_MSG ] ) ) > 0
      c := aSt[ APX_MSG ]
      IF Chr( 10 ) $ c
         c := Left( c, At( Chr( 10 ), c ) - 1 )
      ENDIF
      IF Chr( 13 ) $ c
         c := Left( c, At( Chr( 13 ), c ) - 1 )
      ENDIF
      RETURN c
   ENDIF
   IF Len( aSt[ APX_SRCFLDS ] ) == 0
      RETURN "Pick the source file with [ Browse ] (Alt-B) or type Path: and File:."
   ENDIF
RETURN "Source: " + LTrim( Str( Len( aSt[ APX_SRCFLDS ] ) ) ) + " field(s) in " + ;
       aSt[ APX_SRCNAME ]

/* one chip of the footer of a form: the key between `<>`, its action, and the
 * PAIR REGISTERED for the click - the same rendering as the hint bars of the
 * panels, so the mouse and the keyboard cannot disagree about a chip. The name
 * of the key is the one HcSyncChipInput() resolves ("Enter", "Alt-B", ...).
 * Answers the column where the next chip starts. */
STATIC FUNCTION ApHintKey( nRow, nCol, cKey, cAct, nMax )
   LOCAL nW := Len( cKey ) + 2 + 1 + Len( cAct )
   IF nCol + nW > nMax
      RETURN nCol
   ENDIF
   SetColor( UI_C_MENUKEY )
   @ nRow, nCol SAY "<" + cKey + ">"
   SetColor( UI_C_MENUBAR )
   @ nRow, nCol + Len( cKey ) + 2 SAY " " + cAct
   HcSyncCtlAdd( nRow, nCol, nW, "KEY", cKey )
RETURN nCol + nW + 2

/* the whole box in ONE paint block, and it is where the controls of the mouse
 * are registered (HcSyncCtlReset() first, one entry per control) */
STATIC PROCEDURE ApDraw( aG, aSt )
   LOCAL nT := aG[ APG_T ], nL := aG[ APG_L ], nR := aG[ APG_R ], nB := aG[ APG_B ]
   LOCAL nLbl := aG[ APG_LBL ], nFoc := aSt[ APX_FOCUS ]
   LOCAL cCnt, nInfoW, nCol
   HcSyncCtlReset()
   UiPaintBegin()
   UiShadow( nT, nL, nB, nR )
   UiFillBox( nT, nL, nB, nR, UI_C_BOX )
   UiFrame( nT, nL, nB, nR, UI_C_BOXBORD, .T. )
   /* title: the white chip of the family, centered */
   SetColor( UI_C_FLATBG )
   @ nT + AP_R_TITLE, nL + Int( ( aG[ APG_W ] - 13 ) / 2 ) SAY " APPEND FROM "
   /* the two lines of the TARGET, dim like the header block of the menus */
   nInfoW := Max( 10, nR - 2 - nLbl + 1 )
   SetColor( UI_C_DIM )
   @ nT + AP_R_INFO1, nLbl SAY PadR( Left( ApInfoLine( 1 ), nInfoW ), nInfoW )
   @ nT + AP_R_INFO2, nLbl SAY PadR( Left( ApInfoLine( 2 ), nInfoW ), nInfoW )
   /* FROM: the two halves of the source and the browser */
   LpLabel( nT + AP_R_FROM, nLbl, "FROM " + Chr( 16 ) )
   LpLabel( nT + AP_R_FROM, aG[ APG_PATHL ], "~P~ath:" )
   LpPaintFld( nT + AP_R_FROM, aG[ APG_PATH ], aG[ APG_PATHW ], aSt[ APX_PATH ], ;
               nFoc == AP_FOC_PATH, AP_FOC_PATH, "APFLD" )
   LpLabel( nT + AP_R_FROM, aG[ APG_FILELBL ], "Fi~l~e:" )
   LpPaintFld( nT + AP_R_FROM, aG[ APG_FILE ], aG[ APG_FILEW ], aSt[ APX_FILE ], ;
               nFoc == AP_FOC_FILE, AP_FOC_FILE, "APFLD" )
   LpPaintBtn( nT + AP_R_FROM, aG[ APG_BROWSE ], "[ ~B~rowse ]", ;
               nFoc == AP_FOC_BROWSE, AP_FOC_BROWSE, "APBTN" )
   /* S7: FIELDS on the row BELOW FROM, opening the selector of the SOURCE */
   LpLabel( nT + AP_R_FIELDS, nLbl, "~F~ields:" )
   LpPaintVal( nT + AP_R_FIELDS, aG[ APG_CHIP ], aG[ APG_CHIPW ], ;
               ApFieldsText( aSt[ APX_SEL ], Len( aSt[ APX_SRCFLDS ] ) ), ;
               nFoc == AP_FOC_FIELDS, AP_FOC_FIELDS, "APCHIP" )
   /* SCOPE -a SELECT of the four values- and its Count */
   LpLabel( nT + AP_R_SCOPE, nLbl, "~S~COPE:" )
   LpPaintVal( nT + AP_R_SCOPE, aG[ APG_VAL ], aG[ APG_SCW ], ;
               RpScopeText( aSt[ APX_SCOPE ] ), nFoc == AP_FOC_SCOPE, ;
               AP_FOC_SCOPE, "APFLD" )
   LpLabel( nT + AP_R_SCOPE, aG[ APG_CBLBL ], "Count:" )
   cCnt := LTrim( Str( aSt[ APX_COUNT ] ) )
   IF RpScopeNeedsCount( aSt[ APX_SCOPE ] )
      LpPaintFld( nT + AP_R_SCOPE, aG[ APG_CVAL ], aG[ APG_WCNT ], cCnt, ;
                  nFoc == AP_FOC_CNT, AP_FOC_CNT, "APFLD" )
   ELSE
      LpPaintDim( nT + AP_R_SCOPE, aG[ APG_CVAL ], aG[ APG_WCNT ], cCnt )
   ENDIF
   /* the two conditions, which filter the SOURCE */
   LpLabel( nT + AP_R_WHILE, nLbl, "~W~HILE:" )
   LpPaintFld( nT + AP_R_WHILE, aG[ APG_VAL ], aG[ APG_BIG ], aSt[ APX_WHILE ], ;
               nFoc == AP_FOC_WHILE, AP_FOC_WHILE, "APFLD" )
   LpLabel( nT + AP_R_FOR, nLbl, "F~O~R:" )
   LpPaintFld( nT + AP_R_FOR, aG[ APG_VAL ], aG[ APG_BIG ], aSt[ APX_FOR ], ;
               nFoc == AP_FOC_FOR, AP_FOC_FOR, "APFLD" )
   /* the message row: red when the form refuses something */
   SetColor( iif( aSt[ APX_ERR ], UI_C_ERR, UI_C_FLATBG ) )
   @ nT + AP_R_MSG, nLbl SAY PadR( Left( ApMsgRow( aSt ), aG[ APG_BIG ] ), aG[ APG_BIG ] )
   /* the two buttons, side by side like the rest of the forms */
   LpPaintBtn( nT + AP_R_BTN, nLbl, "[ ~A~ccept ]", nFoc == AP_FOC_OK, ;
               AP_FOC_OK, "APBTN" )
   LpPaintBtn( nT + AP_R_BTN, nLbl + 14, "[ ~C~ancel ]", nFoc == AP_FOC_CANCEL, ;
               AP_FOC_CANCEL, "APBTN" )
   /* the footer: ONE chip per key this screen really has, each painted by the
    * helper that registers it, so a click is the same keystroke (the mouse rule
    * of the project) */
   nCol := ApHintKey( nT + AP_R_HINT, nLbl, "Tab", "Move", nR - 1 )
   nCol := ApHintKey( nT + AP_R_HINT, nCol, "Ctrl-S", "Append", nR - 1 )
   nCol := ApHintKey( nT + AP_R_HINT, nCol, "Alt-B", "Browse", nR - 1 )
   nCol := ApHintKey( nT + AP_R_HINT, nCol, "Alt-F", "Fields", nR - 1 )
   nCol := ApHintKey( nT + AP_R_HINT, nCol, "F1", "Help", nR - 1 )
   nCol := ApHintKey( nT + AP_R_HINT, nCol, "Esc", "Cancel", nR - 1 )
   UiPaintEnd()
RETURN

/* ---------- keys of the form ---------- */

/* move the focus to a stop, repainting only when it really moved */
STATIC FUNCTION ApFocusTo( aSt, nTo )
   IF nTo == aSt[ APX_FOCUS ]
      RETURN ""
   ENDIF
   aSt[ APX_FOCUS ] := nTo
RETURN "focus"

/* the stops a typed character can enter */
STATIC FUNCTION ApIsText( nFoc )
RETURN nFoc == AP_FOC_PATH .OR. nFoc == AP_FOC_FILE .OR. ;
       nFoc == AP_FOC_CNT .OR. nFoc == AP_FOC_WHILE .OR. nFoc == AP_FOC_FOR

/* a typed character ENTERS the input it is standing on and SEEDS a new value
 * there (the rule of the forms of this program), so Enter stays free for "do" */
STATIC FUNCTION ApSeed( aSt, cCh )
   LOCAL lDig := cCh >= "0" .AND. cCh <= "9"
   DO CASE
   CASE aSt[ APX_FOCUS ] == AP_FOC_PATH  ; aSt[ APX_PATH ]  := cCh ; RETURN .T.
   CASE aSt[ APX_FOCUS ] == AP_FOC_FILE  ; aSt[ APX_FILE ]  := cCh ; RETURN .T.
   CASE aSt[ APX_FOCUS ] == AP_FOC_WHILE ; aSt[ APX_WHILE ] := cCh ; RETURN .T.
   CASE aSt[ APX_FOCUS ] == AP_FOC_FOR   ; aSt[ APX_FOR ]   := cCh ; RETURN .T.
   CASE aSt[ APX_FOCUS ] == AP_FOC_CNT
      IF ! lDig
         RETURN .F.
      ENDIF
      aSt[ APX_COUNT ] := Int( Val( cCh ) )
      RETURN .T.
   ENDCASE
RETURN .F.

/* the key -> action table. It MUTATES the focus (a ring step is not an action)
 * and answers the action the loop runs, "" for a key that does nothing here.
 * `Alt+<letter>` comes from the ring of the window hook (trap 61) and the letter
 * is already upper case; a chord nobody serves is DROPPED so it cannot type
 * anything later. The action chords come FIRST, before any case that could type
 * them (rule 7 of the skill). */
STATIC FUNCTION ApKeyAct( nKey, nShift, cAlt, aSt )
   LOCAL lCtrl := hb_bitAnd( nShift, HB_GTI_KBD_CTRL ) != 0
   LOCAL lAlt  := hb_bitAnd( nShift, HB_GTI_KBD_ALT ) != 0
   DO CASE
   CASE Len( cAlt ) > 0
      DO CASE
      CASE cAlt == "P" ; RETURN ApFocusTo( aSt, AP_FOC_PATH )
      CASE cAlt == "L" ; RETURN ApFocusTo( aSt, AP_FOC_FILE )
      CASE cAlt == "S" ; RETURN ApFocusTo( aSt, AP_FOC_SCOPE )
      CASE cAlt == "W" ; RETURN ApFocusTo( aSt, AP_FOC_WHILE )
      CASE cAlt == "O" ; RETURN ApFocusTo( aSt, AP_FOC_FOR )
      CASE cAlt == "B" ; aSt[ APX_FOCUS ] := AP_FOC_BROWSE ; RETURN "browse"
      CASE cAlt == "F" ; aSt[ APX_FOCUS ] := AP_FOC_FIELDS ; RETURN "fields"
      CASE cAlt == "A" ; RETURN "run"
      CASE cAlt == "C" .OR. cAlt == "X" ; RETURN "cancel"
      ENDCASE
      RETURN ""
   CASE nKey == K_ESC ; RETURN "cancel"
   CASE nKey == K_F1  ; RETURN "help"
   /* Ctrl-S: this driver hands it over as the code of K_LEFT (19) WITH the CTRL
    * bit (trap 71), so the code alone is not the rule; ALT disqualifies it
    * because AltGr IS Ctrl+Alt (trap 38). ONE worker: the very ApApply() the
    * [ Accept ] button runs. */
   CASE lCtrl .AND. ! lAlt .AND. ( nKey == K_CTRL_S .OR. nKey == Asc( "s" ) .OR. ;
                                   nKey == Asc( "S" ) )
      RETURN "run"
   CASE nKey == K_ENTER .OR. nKey == K_INS .OR. nKey == K_SPACE
      DO CASE
      CASE aSt[ APX_FOCUS ] == AP_FOC_OK     ; RETURN "run"
      CASE aSt[ APX_FOCUS ] == AP_FOC_CANCEL ; RETURN "cancel"
      CASE aSt[ APX_FOCUS ] == AP_FOC_BROWSE ; RETURN "browse"
      CASE aSt[ APX_FOCUS ] == AP_FOC_FIELDS ; RETURN "fields"
      ENDCASE
      RETURN "edit"
   CASE nKey == K_TAB .OR. nKey == K_DOWN .OR. nKey == K_RIGHT
      RETURN ApFocusTo( aSt, ApFocusStep( aSt[ APX_FOCUS ], 1, aSt[ APX_SCOPE ] ) )
   CASE nKey == K_SH_TAB .OR. nKey == K_UP .OR. nKey == K_LEFT
      RETURN ApFocusTo( aSt, ApFocusStep( aSt[ APX_FOCUS ], -1, aSt[ APX_SCOPE ] ) )
   ENDCASE
RETURN ""

/* S11: the condition is checked when its editor closes as well, so a typo keeps
 * the focus on that field and says why; an empty box is not an error (it means
 * "no condition") */
STATIC FUNCTION ApCheckCond( aSt, lWhile )
   LOCAL cErr, cName := iif( lWhile, "WHILE", "FOR" )
   ApCondBlock( iif( lWhile, aSt[ APX_WHILE ], aSt[ APX_FOR ] ), @cErr, cName )
   IF ! hb_IsNIL( cErr )
      aSt[ APX_MSG ] := cErr
      aSt[ APX_ERR ] := .T.
      RETURN .F.
   ENDIF
   aSt[ APX_MSG ] := ""
   aSt[ APX_ERR ] := .F.
RETURN .T.

/* open the control that has the focus and MOVE THE RING when it is confirmed:
 * Enter, Tab and a selection in a list all leave the focus on the NEXT control
 * (Shift-Tab goes back), which is the rule of the forms of this project; Esc
 * keeps the focus where it is and a condition that does not compile does not
 * let it move on. */
STATIC PROCEDURE ApEdit( aG, aSt )
   LOCAL nFoc := aSt[ APX_FOCUS ], cNew, n, i, lStay := .F.
   LOCAL aSc := {}
   DO CASE
   CASE nFoc == AP_FOC_PATH
      cNew := UiLineEdit( aG[ APG_T ] + AP_R_FROM, aG[ APG_PATH ], aG[ APG_PATHW ], ;
                          aSt[ APX_PATH ], .F., UI_C_LISTSEL, .F., .T. )
      IF ! hb_IsNIL( cNew )
         aSt[ APX_PATH ] := AllTrim( cNew )
         ApLoadSrc( aSt )
         aSt[ APX_MSG ] := ""
         aSt[ APX_ERR ] := .F.
      ENDIF
   CASE nFoc == AP_FOC_FILE
      cNew := UiLineEdit( aG[ APG_T ] + AP_R_FROM, aG[ APG_FILE ], aG[ APG_FILEW ], ;
                          aSt[ APX_FILE ], .F., UI_C_LISTSEL, .F., .T. )
      IF ! hb_IsNIL( cNew )
         aSt[ APX_FILE ] := AllTrim( cNew )
         ApLoadSrc( aSt )
         aSt[ APX_MSG ] := ""
         aSt[ APX_ERR ] := .F.
      ENDIF
   CASE nFoc == AP_FOC_SCOPE
      /* a SELECT of the four values, like the field picker of Replace */
      FOR i := RP_SC_ALL TO RP_SC_MAX
         AAdd( aSc, RpScopeText( i ) )
      NEXT
      n := UiPick( aSc, "SCOPE", aSt[ APX_SCOPE ] )
      IF ValType( n ) == "N" .AND. n >= RP_SC_ALL .AND. n <= RP_SC_MAX
         aSt[ APX_SCOPE ] := n
         aSt[ APX_MSG ] := ""
         aSt[ APX_ERR ] := .F.
      ELSE
         lStay := .T.
      ENDIF
   CASE nFoc == AP_FOC_CNT
      cNew := UiLineEdit( aG[ APG_T ] + AP_R_SCOPE, aG[ APG_CVAL ], aG[ APG_WCNT ], ;
                          LTrim( Str( aSt[ APX_COUNT ] ) ), .T., UI_C_LISTSEL, .F., .T. )
      IF ! hb_IsNIL( cNew )
         n := Val( cNew )
         aSt[ APX_COUNT ] := iif( n > 0, Int( n ), 1 )
      ENDIF
   CASE nFoc == AP_FOC_WHILE
      cNew := UiLineEdit( aG[ APG_T ] + AP_R_WHILE, aG[ APG_VAL ], aG[ APG_BIG ], ;
                          aSt[ APX_WHILE ], .F., UI_C_LISTSEL, .F., .T. )
      IF ! hb_IsNIL( cNew )
         aSt[ APX_WHILE ] := cNew
         IF ! ApCheckCond( aSt, .T. )
            lStay := .T.
         ENDIF
      ENDIF
   CASE nFoc == AP_FOC_FOR
      cNew := UiLineEdit( aG[ APG_T ] + AP_R_FOR, aG[ APG_VAL ], aG[ APG_BIG ], ;
                          aSt[ APX_FOR ], .F., UI_C_LISTSEL, .F., .T. )
      IF ! hb_IsNIL( cNew )
         aSt[ APX_FOR ] := cNew
         IF ! ApCheckCond( aSt, .F. )
            lStay := .T.
         ENDIF
      ENDIF
   ENDCASE
   IF lStay
      RETURN
   ENDIF
   IF UiEditExit() == K_SH_TAB
      ApFocusTo( aSt, ApFocusStep( aSt[ APX_FOCUS ], -1, aSt[ APX_SCOPE ] ) )
   ELSE
      ApFocusTo( aSt, ApFocusStep( aSt[ APX_FOCUS ], 1, aSt[ APX_SCOPE ] ) )
   ENDIF
RETURN

/* ---------- the selector of the SOURCE fields (S7) ---------- */

STATIC FUNCTION ApFpGeom( nFields )
   LOCAL nH := Min( Max( 14, iif( ValType( nFields ) == "N", Int( nFields ), 0 ) + 6 ), ;
                    UiRows() - 4 )
   LOCAL nW := Min( 62, UiCols() - 8 )
   LOCAL aG := Array( APFG_MAX )
   aG[ APFG_W ]    := nW
   aG[ APFG_L ]    := UiCenterCol( nW )
   aG[ APFG_R ]    := aG[ APFG_L ] + nW - 1
   aG[ APFG_T ]    := UiCenterRow( nH )
   aG[ APFG_B ]    := aG[ APFG_T ] + nH - 1
   aG[ APFG_ROWS ] := Max( 3, nH - 5 )
RETURN aG

/* keeps the cursor inside the window of the list */
STATIC FUNCTION ApFpTop( nTop, nCur, nRows, nTotal )
   LOCAL n := Max( 1, iif( ValType( nTop ) == "N", Int( nTop ), 1 ) )
   n := Min( n, nCur )
   IF nCur > n + nRows - 1
      n := nCur - nRows + 1
   ENDIF
   n := Min( n, Max( 1, nTotal - nRows + 1 ) )
RETURN Max( 1, n )

STATIC PROCEDURE ApFpDraw( aG, aSrc, aSel, nCur, nTop, cTitle )
   LOCAL nT := aG[ APFG_T ], nL := aG[ APFG_L ], nB := aG[ APFG_B ]
   LOCAL nR := aG[ APFG_R ], nIn := aG[ APFG_W ] - 4
   LOCAL i, nF, cRow, lFoc
   HcSyncCtlReset()
   UiPaintBegin()
   UiShadow( nT, nL, nB, nR )
   UiFillBox( nT, nL, nB, nR, UI_C_BOX )
   UiFrame( nT, nL, nB, nR, UI_C_BOXBORD, .T. )
   SetColor( UI_C_FLATBG )
   @ nT + 1, nL + Max( 1, Int( ( aG[ APFG_W ] - Len( cTitle ) - 2 ) / 2 ) ) SAY ;
                " " + cTitle + " "
   SetColor( UI_C_BOXDIM )
   @ nT + 2, nL + 2 SAY PadR( "    Field Name   Type", nIn )
   FOR i := 1 TO aG[ APFG_ROWS ]
      nF := nTop + i - 1
      IF nF < 1 .OR. nF > Len( aSrc )
         SetColor( UI_C_BOX )
         @ nT + 2 + i, nL + 2 SAY Space( nIn )
         LOOP
      ENDIF
      lFoc := nF == nCur
      cRow := "[" + iif( nF <= Len( aSel ) .AND. ValType( aSel[ nF ] ) == "L" .AND. ;
                         aSel[ nF ], "X", " " ) + "] " + ;
              PadR( aSrc[ nF ][ 1 ], 12 ) + " " + ;
              RpTypeText( aSrc[ nF ][ 2 ], aSrc[ nF ][ 3 ], aSrc[ nF ][ 4 ] )
      SetColor( iif( lFoc, UI_C_LISTSEL, UI_C_BOX ) )
      @ nT + 2 + i, nL + 2 SAY PadR( Left( cRow, nIn ), nIn )
      HcSyncCtlAdd( nT + 2 + i, nL + 2, nIn, "APFROW", nF )
   NEXT
   SetColor( UI_C_FLATBG )
   @ nB - 1, nL + 2 SAY " " + LTrim( Str( ApSelCount( aSel ) ) ) + " of " + ;
                          LTrim( Str( Len( aSrc ) ) ) + " field(s) "
   SetColor( UI_C_BOX )
   @ nB - 1, nL + 24 SAY PadR( "Alt-A: All  Alt-N: None  Space: Toggle  Enter: Accept  Esc: Cancel", ;
                               nIn - 22 )
   UiPaintEnd()
RETURN

STATIC FUNCTION ApFpKey( nKey, cAlt )
   DO CASE
   CASE Len( cAlt ) > 0
      DO CASE
      CASE cAlt == "A" ; RETURN "all"
      CASE cAlt == "N" ; RETURN "none"
      ENDCASE
      RETURN ""
   CASE nKey == K_ESC   ; RETURN "cancel"
   CASE nKey == K_F1    ; RETURN "help"
   CASE nKey == K_ENTER ; RETURN "ok"
   CASE nKey == K_SPACE .OR. nKey == K_INS ; RETURN "toggle"
   CASE nKey == K_UP    ; RETURN "up"
   CASE nKey == K_DOWN  ; RETURN "down"
   CASE nKey == K_PGUP  ; RETURN "pgup"
   CASE nKey == K_PGDN  ; RETURN "pgdn"
   CASE nKey == K_HOME  ; RETURN "home"
   CASE nKey == K_END   ; RETURN "end"
   ENDCASE
RETURN ""

STATIC PROCEDURE ApFpHelp( cTitle )
   UiTextWin( { ;
      cTitle + " - keys", ;
      "", ;
      "  Up / Down          one field", ;
      "  PgUp / PgDn        one page of fields", ;
      "  Home / End         first / last field", ;
      "  Space / Ins        tick or untick the field under the cursor", ;
      "  click              the same on the row clicked", ;
      "  wheel              one field per notch", ;
      "  Alt-A / Alt-N      tick every field / untick them all", ;
      "  Enter              accept the selection", ;
      "  F1 / Esc           this help / cancel", ;
      "", ;
      "The list is the structure of the SOURCE file, read from the file itself.", ;
      "A field that the TARGET database does not have is skipped when the", ;
      "records are appended.", ;
      "" }, cTitle )
RETURN

/* the selector itself: it answers the NEW selection, or NIL when it was
 * cancelled. Its boxes are flat (Skill rule 4): the only band is the cursor row */
STATIC FUNCTION ApFieldPick( aSrc, aSel, cTitle )
   LOCAL aG, aNew := NIL, lDone := .F., lPaint := .T., cAct := ""
   LOCAL nKey, nShift, cAlt, aPt, aCtl, cSave, cOldCur, nCur := 1, nTop := 1
   LOCAL nRows, nWheel
   IF ! HB_ISARRAY( aSrc ) .OR. Len( aSrc ) == 0
      RETURN NIL
   ENDIF
   DEFAULT cTitle TO "Fields"
   aG := ApFpGeom( Len( aSrc ) )
   nRows := aG[ APFG_ROWS ]
   cOldCur := SetCursor( 0 )
   cSave := SaveScreen( aG[ APFG_T ], aG[ APFG_L ], Min( MaxRow(), aG[ APFG_B ] + 1 ), ;
                        Min( MaxCol(), aG[ APFG_R ] + 2 ) )
   DO WHILE ! lDone
      IF lPaint
         ApFpDraw( aG, aSrc, aSel, nCur, nTop, cTitle )
         lPaint := .F.
      ENDIF
      cAct := ""
      nKey   := Inkey( 0.05 )
      nShift := hb_gtInfo( HB_GTI_KBDSHIFTS )
      cAlt   := HcAltChord()
      /* a chord a field editor left pending is taken here too (rule 7) */
      IF Len( cAlt ) == 0
         cAlt := UiAltChord()
      ENDIF
      IF UiCloseAsk()
         cAct := "cancel"
      ENDIF
      IF Empty( cAct ) .AND. HcMouseRightClick()
         cAct := "cancel"
      ENDIF
      IF Empty( cAct )
         IF nKey == 0 .AND. Len( cAlt ) == 0
            aPt := UiClick()
            IF HB_ISARRAY( aPt )
               aCtl := HcSyncCtlAt( aPt[ 1 ], aPt[ 2 ] )
               IF ! hb_IsNIL( aCtl ) .AND. aCtl[ 4 ] == "APFROW"
                  nCur := aCtl[ 5 ]
                  nTop := ApFpTop( nTop, nCur, nRows, Len( aSrc ) )
                  aSel := ApSelToggle( aSel, nCur )
                  lPaint := .T.
               ENDIF
            ENDIF
            nWheel := UiMouseWheel()
            IF nWheel != 0
               /* ONE notch is ONE field, and the run the hook accumulated is
                * honoured as a whole and clamped at both edges - exactly what
                * the picker of this same form does. Before this the cursor moved
                * one field per RUN, so a fast roll of the wheel barely moved the
                * band while the picker moved it notch by notch. */
               nCur := Max( 1, Min( nCur - nWheel, Len( aSrc ) ) )
               nTop := ApFpTop( nTop, nCur, nRows, Len( aSrc ) )
               lPaint := .T.
            ENDIF
         ELSE
            cAct := ApFpKey( nKey, cAlt )
         ENDIF
      ENDIF
      IF Empty( cAct )
         LOOP
      ENDIF
      DO CASE
      CASE cAct == "cancel"
         lDone := .T.
      CASE cAct == "ok"
         aNew := aSel
         lDone := .T.
      CASE cAct == "help"
         ApFpHelp( cTitle )
         lPaint := .T.
      CASE cAct == "all"
         aSel := ApSelAll( aSel, Len( aSrc ) )
         lPaint := .T.
      CASE cAct == "none"
         aSel := ApSelNone( aSel, Len( aSrc ) )
         lPaint := .T.
      CASE cAct == "toggle"
         aSel := ApSelToggle( aSel, nCur )
         lPaint := .T.
      CASE cAct == "up"
         nCur := Max( 1, nCur - 1 )
         lPaint := .T.
      CASE cAct == "down"
         nCur := Min( Len( aSrc ), nCur + 1 )
         lPaint := .T.
      CASE cAct == "pgup"
         nCur := Max( 1, nCur - nRows )
         lPaint := .T.
      CASE cAct == "pgdn"
         nCur := Min( Len( aSrc ), nCur + nRows )
         lPaint := .T.
      CASE cAct == "home"
         nCur := 1
         lPaint := .T.
      CASE cAct == "end"
         nCur := Len( aSrc )
         lPaint := .T.
      ENDCASE
      nTop := ApFpTop( nTop, nCur, nRows, Len( aSrc ) )
   ENDDO
   RestScreen( aG[ APFG_T ], aG[ APFG_L ], Min( MaxRow(), aG[ APFG_B ] + 1 ), ;
               Min( MaxCol(), aG[ APFG_R ] + 2 ), cSave )
   SetCursor( cOldCur )
   SetColor( UI_C_DESKTOP )
RETURN aNew

/* the chip of the form: it opens the selector of the SOURCE fields */
STATIC PROCEDURE ApFields( aSt )
   LOCAL aSel
   IF Len( AllTrim( aSt[ APX_FILE ] ) ) == 0 .OR. Len( aSt[ APX_SRCFLDS ] ) == 0
      aSt[ APX_MSG ] := "Pick the source file first."
      aSt[ APX_ERR ] := .T.
      RETURN
   ENDIF
   aSel := ApFieldPick( aSt[ APX_SRCFLDS ], aSt[ APX_SEL ], ;
                        "Fields of " + aSt[ APX_SRCNAME ] )
   IF ! hb_IsNIL( aSel )
      aSt[ APX_SEL ] := aSel
      aSt[ APX_MSG ] := ""
      aSt[ APX_ERR ] := .F.
   ENDIF
RETURN

/* =====================================================================
 *  The SIMPLE picker of this form (S21, the user's L7)
 * ---------------------------------------------------------------------
 *  `[ Browse ]` used to nest the Harbour Commander. L7 asked for a plain
 *  browser of the drives: a dialog of the same family as this form, with the
 *  drive chip, the directory, `[..]`, the directories and the `*.DBF` files.
 *  It only builds PATHS: it never opens the file and never touches a work area,
 *  so nothing can move the TARGET area out from under the engine (S12).
 *  The rules it decides without a window (filter, order, parent, row text) are
 *  in bp_ui.prg, where the headless bank pins them; here there is the dialog.
 * ===================================================================== */

/* session memory of the last directory visited (S21). Nothing goes to disk: it
 * is a STATIC like every other memory of this program - declared at the top of
 * the module, because a STATIC cannot follow an executable statement (trap 7) */

/* rows of the picker, RELATIVE to the top of its box */
#define APPK_R_TITLE   1
#define APPK_R_DRV     2
#define APPK_R_PATH    3
#define APPK_R_HDR     4
#define APPK_R_SEP     5
#define APPK_R_LIST    6
#define APPK_H        24

#define APPKG_W        1
#define APPKG_L        2
#define APPKG_T        3
#define APPKG_B        4
#define APPKG_R        5
#define APPKG_NROWS    6
#define APPKG_NAMEL    7
#define APPKG_NAMEW    8
#define APPKG_SIZEC    9
#define APPKG_SIZEW   10
#define APPKG_DATEC   11
#define APPKG_DATEW   12
#define APPKG_DRVL    13
#define APPKG_DRV     14
#define APPKG_DRVW    15
#define APPKG_PATH    16
#define APPKG_PATHW   17
#define APPKG_ROWM    18    /* row of the message */
#define APPKG_ROWH    19    /* row of the chips  */
#define APPKG_MAX     19

STATIC FUNCTION ApPkGeom()
   LOCAL nW := Min( 96, UiCols() - 8 )
   LOCAL nH := Min( APPK_H, UiRows() - 8 )
   LOCAL aG := Array( APPKG_MAX )
   aG[ APPKG_W ]     := nW
   aG[ APPKG_L ]     := UiCenterCol( nW )
   aG[ APPKG_R ]     := aG[ APPKG_L ] + nW - 1
   aG[ APPKG_T ]     := UiCenterRow( nH )
   aG[ APPKG_B ]     := aG[ APPKG_T ] + nH - 1
   aG[ APPKG_ROWM ]  := nH - 5
   aG[ APPKG_ROWH ]  := nH - 4
   aG[ APPKG_NROWS ] := aG[ APPKG_ROWM ] - APPK_R_LIST
   aG[ APPKG_NAMEL ] := aG[ APPKG_L ] + 2
   aG[ APPKG_SIZEW ] := 10
   aG[ APPKG_DATEW ] := 8
   aG[ APPKG_NAMEW ] := Max( 12, nW - 4 - 1 - aG[ APPKG_SIZEW ] - 1 - ;
                                  aG[ APPKG_DATEW ] - 1 )
   aG[ APPKG_SIZEC ] := aG[ APPKG_NAMEL ] + aG[ APPKG_NAMEW ] + 1
   aG[ APPKG_DATEC ] := aG[ APPKG_SIZEC ] + aG[ APPKG_SIZEW ] + 1
   aG[ APPKG_DRVL ]  := aG[ APPKG_L ] + 2
   aG[ APPKG_DRV ]   := aG[ APPKG_DRVL ] + 9
   aG[ APPKG_DRVW ]  := 8
   aG[ APPKG_PATH ]  := aG[ APPKG_L ] + 8
   aG[ APPKG_PATHW ] := aG[ APPKG_R ] - 2 - aG[ APPKG_PATH ] + 1
RETURN aG

/* the drive of a directory, upper case, for the chip */
STATIC FUNCTION ApPkDrive( cDir )
   LOCAL c := AllTrim( iif( HB_ISSTRING( cDir ), cDir, "" ) )
   IF Len( c ) >= 2 .AND. SubStr( c, 2, 1 ) == ":"
      RETURN Upper( Left( c, 2 ) )
   ENDIF
RETURN "C:"

/* keeps the cursor inside the window of the list */
STATIC FUNCTION ApPkTop( nTop, nCur, nRows, nTotal )
   LOCAL n := Max( 1, iif( ValType( nTop ) == "N", Int( nTop ), 1 ) )
   n := Min( n, nCur )
   IF nCur > n + nRows - 1
      n := nCur - nRows + 1
   ENDIF
RETURN Min( n, Max( 1, nTotal - nRows + 1 ) )

/* the identity of the entry of a row, for the pair of clicks: the NAME and not
 * the row number, because a directory change turns the same row into another
 * entry (trap 48). "" when the row is not on the list. */
STATIC FUNCTION ApPkRowId( aRows, nRow )
   IF ! HB_ISARRAY( aRows ) .OR. ValType( nRow ) != "N" .OR. ;
      nRow < 1 .OR. nRow > Len( aRows )
      RETURN ""
   ENDIF
RETURN Upper( AllTrim( aRows[ nRow ][ 1 ] ) )

/* the listing of one directory: the rows plus the message that goes with them.
 * A directory that cannot be read KEEPS the rows that were on screen and says
 * why (S21) - never an empty screen.
 *
 * hb_vfDirectory() does NOT throw on an unreadable directory and its FError() is
 * useless as a signal, MEASURED on this build: a successful enumeration ends with
 * FError() 18 (ERROR_NO_MORE_FILES) and the unreadable "C:\System Volume
 * Information" answered FError() 0 inside this screen. The signal that does work
 * is the RESULT: a readable directory always brings at least "." and ".." (2
 * entries for an empty one) and an unreadable one brings NOTHING (0 entries), so
 * Len() == 0 is the failure. The length is asked with Len() and never with
 * Empty(), which is also true for a run of spaces (trap 46). */
STATIC FUNCTION ApPkLoad( cDir, aRows, cMsg, lErr )
   LOCAL aRaw, aNew, lUp := ApPkUpOk( cDir )
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      aRaw := hb_vfDirectory( cDir, "HSD" )
      IF ! HB_ISARRAY( aRaw )
         aRaw := {}
      ENDIF
      IF Len( aRaw ) == 0
         aNew := aRows
         cMsg := "Cannot read " + AllTrim( cDir )
         lErr := .T.
      ELSE
         aNew := ApPkRows( aRaw, lUp )
         cMsg := LTrim( Str( Max( 0, Len( aNew ) - iif( lUp, 1, 0 ) ) ) ) + " item(s)"
         lErr := .F.
      ENDIF
   RECOVER
      aNew := aRows
      cMsg := "Cannot read " + AllTrim( cDir )
      lErr := .T.
   END SEQUENCE
RETURN aNew

STATIC PROCEDURE ApPkDraw( aG, cDir, aRows, nCur, nTop, cMsg, lErr, lFocDrv )
   LOCAL nT := aG[ APPKG_T ], nL := aG[ APPKG_L ], nB := aG[ APPKG_B ]
   LOCAL nR := aG[ APPKG_R ], i, nIdx, cRow, nCol, nRowW
   HcSyncCtlReset()
   UiPaintBegin()
   UiShadow( nT, nL, nB, nR )
   UiFillBox( nT, nL, nB, nR, UI_C_BOX )
   UiFrame( nT, nL, nB, nR, UI_C_BOXBORD, .T. )
   /* the title, as the cyan chip of the family */
   SetColor( UI_C_CHIP )
   @ nT + APPK_R_TITLE, nL + 2 SAY " Database file "
   /* the drive chip (it opens the list of drives) and the directory, which is
    * read only and dim */
   LpLabel( nT + APPK_R_DRV, aG[ APPKG_DRVL ], "~D~rives:" )
   LpPaintVal( nT + APPK_R_DRV, aG[ APPKG_DRV ], aG[ APPKG_DRVW ], ;
               "[" + ApPkDrive( cDir ) + "]", lFocDrv, 0, "DRV" )
   LpLabel( nT + APPK_R_PATH, nL + 2, "Path:" )
   SetColor( UI_C_DIM )
   @ nT + APPK_R_PATH, aG[ APPKG_PATH ] SAY ;
        PadR( Left( AllTrim( cDir ), aG[ APPKG_PATHW ] ), aG[ APPKG_PATHW ] )
   /* the header of the three columns and the rule under it */
   SetColor( UI_C_HDR )
   @ nT + APPK_R_HDR, aG[ APPKG_NAMEL ] SAY PadR( "Name", aG[ APPKG_NAMEW ] )
   @ nT + APPK_R_HDR, aG[ APPKG_SIZEC ] SAY PadL( "Size", aG[ APPKG_SIZEW ] )
   @ nT + APPK_R_HDR, aG[ APPKG_DATEC ] SAY PadR( "Date", aG[ APPKG_DATEW ] )
   SetColor( UI_C_BOXDIM )
   nRowW := nR - nL - 3
   @ nT + APPK_R_SEP, nL + 2 SAY PadR( Replicate( BP_LINE_SINGLE, nRowW ), nRowW )
   /* the list: the band of the cursor only when the LIST has the focus */
   FOR i := 1 TO aG[ APPKG_NROWS ]
      nIdx := nTop + i - 1
      IF nIdx < 1 .OR. nIdx > Len( aRows )
         SetColor( UI_C_BOX )
         @ nT + APPK_R_LIST + i - 1, aG[ APPKG_NAMEL ] SAY Space( nRowW )
         LOOP
      ENDIF
      cRow := ApPkRowText( aRows[ nIdx ], aG[ APPKG_NAMEW ] )
      SetColor( iif( nIdx == nCur .AND. ! lFocDrv, UI_C_LISTSEL, UI_C_BOX ) )
      @ nT + APPK_R_LIST + i - 1, aG[ APPKG_NAMEL ] SAY PadR( Left( cRow, nRowW ), nRowW )
      HcSyncCtlAdd( nT + APPK_R_LIST + i - 1, aG[ APPKG_NAMEL ], nRowW, "ROW", nIdx )
   NEXT
   /* the message row (red when the directory could not be read) and the chips */
   SetColor( iif( lErr, UI_C_ERR, UI_C_FLATBG ) )
   @ nT + aG[ APPKG_ROWM ], nL + 2 SAY PadR( Left( cMsg, nRowW ), nRowW )
   nCol := ApHintKey( nT + aG[ APPKG_ROWH ], nL + 2, "Enter", "Open", nR - 1 )
   nCol := ApHintKey( nT + aG[ APPKG_ROWH ], nCol, "Esc", "Cancel", nR - 1 )
   nCol := ApHintKey( nT + aG[ APPKG_ROWH ], nCol, "F1", "Help", nR - 1 )
   nCol := ApHintKey( nT + aG[ APPKG_ROWH ], nCol, "Alt-D", "Drives", nR - 1 )
   UiPaintEnd()
RETURN

/* the keys of the picker. "open" means "Enter on the row": a directory changes
 * directory and a file is accepted - the loop decides which */
STATIC FUNCTION ApPkKey( nKey, cAlt, lFocDrv )
   DO CASE
   CASE Len( cAlt ) > 0
      IF cAlt == "D"
         RETURN "drives"
      ENDIF
      RETURN ""
   CASE nKey == K_ESC  ; RETURN "cancel"
   CASE nKey == K_F1   ; RETURN "help"
   CASE nKey == K_TAB .OR. nKey == K_SH_TAB ; RETURN "focus"
   CASE nKey == K_ENTER .OR. nKey == K_SPACE
      RETURN iif( lFocDrv, "drives", "open" )
   CASE nKey == K_UP   ; RETURN "up"
   CASE nKey == K_DOWN ; RETURN "down"
   CASE nKey == K_PGUP ; RETURN "pgup"
   CASE nKey == K_PGDN ; RETURN "pgdn"
   CASE nKey == K_HOME ; RETURN "home"
   CASE nKey == K_END  ; RETURN "end"
   ENDCASE
RETURN ""

STATIC PROCEDURE ApPkHelp()
   UiTextWin( { ;
      "Database file - keys", ;
      "", ;
      "  Up / Down          one entry", ;
      "  PgUp / PgDn        one page of entries", ;
      "  Home / End         first / last entry", ;
      "  Enter              a directory ([..] included) changes directory,", ;
      "                     a .DBF file is picked and the form gets its path", ;
      "  click              the entry under the pointer", ;
      "  double click       the same as Enter on that entry", ;
      "  wheel              one entry per notch", ;
      "  Tab / Shift-Tab    the list and the Drives chip", ;
      "  Alt-D              the list of drives, from anywhere", ;
      "  F1 / Esc           this help / cancel the dialog", ;
      "", ;
      "A click outside this dialog does nothing: it does not close it and it", ;
      "does not touch the form behind. Only Esc and its chip cancel.", ;
      "" }, "Database file" )
RETURN

/* the picker itself: answers the FULL path of the chosen *.DBF, or "" when it
 * was cancelled (S21). Nothing is opened here. */
STATIC FUNCTION ApPickFile( cSeed )
   LOCAL aG, aRows := {}, cDir, cMsg := "", cRes := "", cAct := ""
   LOCAL lErr := .F., lDone := .F., lPaint := .T., lFocDrv := .F., lDbl := .F.
   LOCAL nCur := 1, nTop := 1, nKey, nShift, cAlt, nWheel, n, aDrv
   LOCAL aPt, aCtl, aIn, cSave, cOldCur, cLast := "", cName, cPrev := ""
   DEFAULT cSeed TO ""
   /* the directory: the seed of the form when it is real, otherwise the last one
    * visited in this session, otherwise the process directory */
   cDir := AllTrim( iif( HB_ISSTRING( cSeed ), cSeed, "" ) )
   IF ! hb_DirExists( cDir )
      cDir := iif( hb_DirExists( s_cApPkDir ), s_cApPkDir, hb_cwd() )
   ENDIF
   IF Right( cDir, 1 ) != "\" .AND. Right( cDir, 1 ) != "/"
      cDir += "\"
   ENDIF
   aG := ApPkGeom()
   aRows := ApPkLoad( cDir, aRows, @cMsg, @lErr )
   s_cApPkDir := cDir
   cOldCur := SetCursor( 0 )
   cSave := SaveScreen( aG[ APPKG_T ], aG[ APPKG_L ], Min( MaxRow(), aG[ APPKG_B ] + 1 ), ;
                        Min( MaxCol(), aG[ APPKG_R ] + 2 ) )
   DO WHILE ! lDone
      IF lPaint
         ApPkDraw( aG, cDir, aRows, nCur, nTop, cMsg, lErr, lFocDrv )
         lPaint := .F.
      ENDIF
      cAct := ""
      nKey   := Inkey( 0.05 )
      nShift := hb_gtInfo( HB_GTI_KBDSHIFTS )
      cAlt   := HcAltChord()
      IF Len( cAlt ) == 0
         cAlt := UiAltChord()
      ENDIF
      IF UiCloseAsk()
         cAct := "cancel"
      ENDIF
      /* a plain right click is the Esc of THIS dialog: it cancels the picker
       * and the form behind stays open (right-click-esc rule) */
      IF Empty( cAct ) .AND. HcMouseRightClick()
         cAct := "cancel"
      ENDIF
      IF Empty( cAct )
         IF nKey == 0 .AND. Len( cAlt ) == 0
            aPt := UiClick()
            IF HB_ISARRAY( aPt )
               /* OUTSIDE the box: nothing at all. A modal does not take a
                * stray click as an answer (UiConfirm's rule), and it must not
                * close the form behind by accident either */
               IF aPt[ 1 ] >= aG[ APPKG_T ] .AND. aPt[ 1 ] <= aG[ APPKG_B ] .AND. ;
                  aPt[ 2 ] >= aG[ APPKG_L ] .AND. aPt[ 2 ] <= aG[ APPKG_R ]
                  aCtl := HcSyncCtlAt( aPt[ 1 ], aPt[ 2 ] )
                  IF ! hb_IsNIL( aCtl )
                     DO CASE
                     CASE aCtl[ 4 ] == "KEY"
                        /* a chip is its key, through the ONE table of names */
                        aIn := HcSyncChipInput( aCtl[ 5 ] )
                        cAct := ApPkKey( aIn[ 1 ], aIn[ 2 ], lFocDrv )
                     CASE aCtl[ 4 ] == "DRV"
                        cAct := "drives"
                     CASE aCtl[ 4 ] == "ROW"
                        nCur := aCtl[ 5 ]
                        lFocDrv := .F.
                        /* the pair of clicks is decided by the IDENTITY of the
                         * entry and not by the row (trap 48) */
                        cName  := ApPkRowId( aRows, nCur )
                        lDbl   := UiClickDbl() .AND. Len( cName ) > 0 .AND. cName == cLast
                        cLast  := cName
                        IF lDbl
                           cAct := "open"
                        ENDIF
                        lPaint := .T.
                     ENDCASE
                  ENDIF
               ENDIF
            ENDIF
            nWheel := UiMouseWheel()
            IF nWheel != 0
               /* the hook answers the notches ACCUMULATED since the last read and
                * a positive notch is "up" (the rule of the panels), so the cursor
                * moves by the whole run and not by one row per message */
               nCur := Max( 1, Min( nCur - nWheel, Max( 1, Len( aRows ) ) ) )
               /* the wheel moves the LIST, so the band has to go with it: a notch
                * taken while the Drives: chip had the focus moved the cursor
                * where nobody could see it */
               lFocDrv := .F.
               lPaint := .T.
            ENDIF
         ELSE
            cAct := ApPkKey( nKey, cAlt, lFocDrv )
         ENDIF
      ENDIF
      /* the WINDOW of the list follows the cursor on EVERY pass that moved it,
       * including the ones that ask for no action (the wheel, a click on a row):
       * the early LOOP used to skip the update at the bottom and the cursor
       * walked out of the window - the trap the List form documents. The update
       * is done once more after the DO CASE, because a key that MOVES the cursor
       * (Down, End, PgDn) changes it below. */
      nTop := ApPkTop( nTop, nCur, aG[ APPKG_NROWS ], Len( aRows ) )
      IF Empty( cAct )
         LOOP
      ENDIF
      DO CASE
      CASE cAct == "cancel"
         cRes := ""
         lDone := .T.
      CASE cAct == "help"
         ApPkHelp()
         lPaint := .T.
      CASE cAct == "focus"
         lFocDrv := ! lFocDrv
         lPaint := .T.
      CASE cAct == "drives"
         aDrv := LinkDrives()
         IF Len( aDrv ) > 0
            n := UiPick( aDrv, "Choose drive", 1 )
            IF ValType( n ) == "N" .AND. n >= 1 .AND. n <= Len( aDrv )
               cPrev := cDir
               cDir  := aDrv[ n ] + "\"
               aRows := ApPkLoad( cDir, aRows, @cMsg, @lErr )
               IF lErr
                  /* an unreadable root (a drive with no media) leaves the
                   * listing, the directory and the cursor as they were (S21) */
                  cDir := cPrev
               ELSE
                  s_cApPkDir := cDir
                  nCur := 1
                  nTop := 1
               ENDIF
            ENDIF
         ENDIF
         lFocDrv := .F.
         lPaint := .T.
      CASE cAct == "open"
         IF nCur >= 1 .AND. nCur <= Len( aRows )
            IF ValType( aRows[ nCur ][ 4 ] ) == "L" .AND. aRows[ nCur ][ 4 ]
               /* a directory: [..] goes up (never above the root) and any
                * other one is entered */
               cPrev := cDir
               IF AllTrim( aRows[ nCur ][ 1 ] ) == ".."
                  cDir := ApPkParent( cDir )
               ELSE
                  cDir := HcJoinPath( cDir, aRows[ nCur ][ 1 ] )
                  IF Right( cDir, 1 ) != "\" .AND. Right( cDir, 1 ) != "/"
                     cDir += "\"
                  ENDIF
               ENDIF
               aRows := ApPkLoad( cDir, aRows, @cMsg, @lErr )
               IF lErr
                  /* the directory could not be read: the listing, the cursor,
                   * the window and the directory on the chip stay EXACTLY as
                   * they were, and the message row says why (S21) */
                  cDir := cPrev
               ELSE
                  s_cApPkDir := cDir
                  nCur := 1
                  nTop := 1
               ENDIF
            ELSE
               cRes := HcJoinPath( cDir, aRows[ nCur ][ 1 ] )
               lDone := .T.
            ENDIF
         ENDIF
         lPaint := .T.
      CASE cAct == "up"
         nCur := Max( 1, nCur - 1 )
         lPaint := .T.
      CASE cAct == "down"
         nCur := Min( Max( 1, Len( aRows ) ), nCur + 1 )
         lPaint := .T.
      CASE cAct == "pgup"
         nCur := Max( 1, nCur - aG[ APPKG_NROWS ] )
         lPaint := .T.
      CASE cAct == "pgdn"
         nCur := Min( Max( 1, Len( aRows ) ), nCur + aG[ APPKG_NROWS ] )
         lPaint := .T.
      CASE cAct == "home"
         nCur := 1
         lPaint := .T.
      CASE cAct == "end"
         nCur := Max( 1, Len( aRows ) )
         lPaint := .T.
      ENDCASE
      nTop := ApPkTop( nTop, nCur, aG[ APPKG_NROWS ], Len( aRows ) )
   ENDDO
   RestScreen( aG[ APPKG_T ], aG[ APPKG_L ], Min( MaxRow(), aG[ APPKG_B ] + 1 ), ;
               Min( MaxCol(), aG[ APPKG_R ] + 2 ), cSave )
   SetCursor( cOldCur )
   SetColor( UI_C_DESKTOP )
RETURN cRes

/* S6/S21: the [ Browse ] of this form opens the SIMPLE picker - not the Harbour
 * Commander (L7) - and splits the path it answers into Path: and File:. It asks
 * for the path ONLY: nothing is opened in a work area, so the TARGET area of the
 * engine cannot move. The dialog saves and restores its OWN rectangle, so there
 * is no whole-canvas SaveScreen() here any more; the caller repaints the form. */
STATIC PROCEDURE ApBrowse( aSt )
   LOCAL cFile, aSplit
   cFile := ApPickFile( aSt[ APX_PATH ] )
   IF HB_ISSTRING( cFile ) .AND. Len( AllTrim( cFile ) ) > 0
      aSplit := ApSplitPath( cFile )
      aSt[ APX_PATH ] := AllTrim( aSplit[ 1 ] )
      aSt[ APX_FILE ] := AllTrim( aSplit[ 2 ] )
      ApLoadSrc( aSt )
      aSt[ APX_MSG ] := ""
      aSt[ APX_ERR ] := .F.
      /* L11: a file was PICKED, so the FROM row is done and the flow goes on:
       * the focus lands on the next stop after [ Browse ], which is the FIELDS
       * chip (the screen walks itself, as every form of this program does).
       * The same one step the keyboard takes when a control is confirmed. */
      aSt[ APX_FOCUS ] := ApFocusStep( AP_FOC_BROWSE, 1, aSt[ APX_SCOPE ] )
   ENDIF
RETURN

/* ---------- the engine (S12..S15) ---------- */

/* close the area the SOURCE was opened in, whatever its state (the pattern of
 * StructCloseArea(): SELECT inside a SEQUENCE and ask with Used()) */
STATIC PROCEDURE ApCloseSrc( nArea )
   IF ValType( nArea ) != "N" .OR. nArea < 1
      RETURN
   ENDIF
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      SELECT ( nArea )
      IF Used()
         dbCloseArea()
      ENDIF
   RECOVER
   END SEQUENCE
RETURN

/* the walk of the SOURCE: SCOPE, WHILE and FOR in its NATURAL order (S10), with
 * SET DELETED respected exactly as it is -this function never changes it-. bEach
 * runs on every qualifying record and answers .F. to STOP; the answer is the
 * number of records the walk looked at */
STATIC FUNCTION ApWalkSrc( nScope, nCount, bWhile, bFor, bEach )
   LOCAL nPos := 0, xRes, lStop := .F., lRun, lDeleted := Set( _SET_DELETED )
   dbGoTop()
   DO WHILE ! Eof() .AND. ! lStop
      nPos++
      IF ! ApQualify( nPos, nScope, nCount )
         /* outside the scope: NEXT and RECORD stop as soon as their window is
          * behind, ALL and REST never do (ApQualify() is the one rule) */
         IF ( nScope == RP_SC_NEXT .OR. nScope == RP_SC_REC ) .AND. nPos > nCount
            EXIT
         ENDIF
         dbSkip()
         LOOP
      ENDIF
      IF ! hb_IsNIL( bWhile )
         xRes := Eval( bWhile )
         IF ValType( xRes ) == "L" .AND. ! xRes
            EXIT
         ENDIF
      ENDIF
      IF ! ( lDeleted .AND. Deleted() )
         lRun := .T.
         IF ! hb_IsNIL( bFor )
            xRes := Eval( bFor )
            lRun := ( ValType( xRes ) == "L" .AND. xRes )
         ENDIF
         IF lRun .AND. ! Eval( bEach )
            lStop := .T.
         ENDIF
      ENDIF
      IF ! lStop
         dbSkip()
      ENDIF
   ENDDO
RETURN nPos

/* ONE appended record: the progress, dbAppend() in the TARGET, one FieldPut()
 * per SELECTED field with the value taken from the SOURCE and fitted to the
 * type and width of the DESTINATION (trap 22), all inside BEGIN SEQUENCE so a
 * commit that fails cannot reach BpFatal() (trap 57). It answers .F. to STOP the
 * walk (cancelled or failed) */
STATIC FUNCTION ApWriteRec( aMap, nTgt, nSrc, aCtx )
   LOCAL i, xVal, oErr, lOk := .T., nStep, nNow
   IF ! hb_IsNIL( aCtx[ 3 ] )
      RETURN .F.
   ENDIF
   /* SPEED: the bar and the keyboard are touched every nStep records, not on
    * every one (50,000 records give a step of 100) */
   nNow  := aCtx[ 1 ] + 1
   nStep := UiProgStep( aCtx[ 4 ] )
   IF ( nNow % nStep == 0 .OR. nNow == aCtx[ 4 ] ) .AND. ;
      UiProgUpdate( nNow, aCtx[ 4 ] )
      aCtx[ 3 ] := "cancelled"
      RETURN .F.
   ENDIF
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      SELECT ( nTgt )
      dbAppend()
      FOR i := 1 TO Len( aMap )
         SELECT ( nSrc )
         xVal := FieldGet( aMap[ i ][ 1 ] )
         SELECT ( nTgt )
         FieldPut( aMap[ i ][ 2 ], StructConvert( xVal, aMap[ i ][ 3 ] ) )
      NEXT
      dbCommit()
      dbRUnlock()
      aCtx[ 1 ] := aCtx[ 1 ] + 1
      aCtx[ 2 ] := RecNo()
   RECOVER USING oErr
      dbRUnlock()
      lOk := .F.
      aCtx[ 3 ] := "Error after " + LTrim( Str( aCtx[ 1 ] ) ) + " record(s): " + ;
                   oErr:Description
   END SEQUENCE
   /* the walk continues on the SOURCE, so this is the area it leaves selected */
   SELECT ( nSrc )
RETURN lOk

/* validate, count, confirm, write. It answers { lClose, cMsg }: the form stays
 * open when nothing was written (and the message row says why) and closes with
 * the result otherwise */
STATIC FUNCTION ApApply( aSt )
   LOCAL cFile, cPath, aSrc, aSel, aMap := {}, aTgt := {}, aFld
   LOCAL i, nDst, nMissing := 0, cName, cErr := NIL, bFor := NIL, bWhile := NIL
   LOCAL nTgt := Select(), nSrc := 0, oErr, nTotal := 0, aCtx, nDone, cMsg, lOk
   LOCAL bCount
   cFile := AllTrim( aSt[ APX_FILE ] )
   IF Len( cFile ) == 0
      aSt[ APX_MSG ] := "Pick the file to append from."
      aSt[ APX_ERR ] := .T.
      aSt[ APX_FOCUS ] := AP_FOC_FILE
      RETURN { .F., "" }
   ENDIF
   cPath := HcJoinPath( aSt[ APX_PATH ], cFile )
   IF ! hb_FNameExists( cPath )
      aSt[ APX_MSG ] := "File not found: " + cPath
      aSt[ APX_ERR ] := .T.
      aSt[ APX_FOCUS ] := AP_FOC_FILE
      RETURN { .F., "" }
   ENDIF
   aSrc := ApReadStruct( cPath )
   IF Len( aSrc ) == 0
      aSt[ APX_MSG ] := "Cannot read the structure of " + cPath
      aSt[ APX_ERR ] := .T.
      RETURN { .F., "" }
   ENDIF
   aSel := aSt[ APX_SEL ]
   IF ApSelCount( aSel ) == 0
      aSt[ APX_MSG ] := "No field is selected."
      aSt[ APX_ERR ] := .T.
      aSt[ APX_FOCUS ] := AP_FOC_FIELDS
      RETURN { .F., "" }
   ENDIF
   /* S11: the conditions are compiled BEFORE a single record is touched */
   bFor := ApCondBlock( aSt[ APX_FOR ], @cErr, "FOR" )
   IF ! hb_IsNIL( cErr )
      aSt[ APX_MSG ] := cErr
      aSt[ APX_ERR ] := .T.
      aSt[ APX_FOCUS ] := AP_FOC_FOR
      RETURN { .F., "" }
   ENDIF
   bWhile := ApCondBlock( aSt[ APX_WHILE ], @cErr, "WHILE" )
   IF ! hb_IsNIL( cErr )
      aSt[ APX_MSG ] := cErr
      aSt[ APX_ERR ] := .T.
      aSt[ APX_FOCUS ] := AP_FOC_WHILE
      RETURN { .F., "" }
   ENDIF
   /* S13: the selected fields, matched BY NAME against the target */
   aTgt := RpFieldList()
   FOR i := 1 TO Len( aSrc )
      IF i <= Len( aSel ) .AND. ValType( aSel[ i ] ) == "L" .AND. aSel[ i ]
         cName := ApFieldNameOk( aSrc[ i ][ 1 ], aTgt )
         nDst  := iif( Len( cName ) > 0, FieldPos( cName ), 0 )
         IF nDst > 0
            /* the type and width of the DESTINATION travel with the map: the
             * value of the source is fitted to them, never the other way round */
            aFld := { cName, FieldType( nDst ), FieldLen( nDst ), FieldDec( nDst ) }
            AAdd( aMap, { i, nDst, aFld } )
         ELSE
            nMissing++
         ENDIF
      ENDIF
   NEXT
   IF Len( aMap ) == 0
      aSt[ APX_MSG ] := "None of the selected fields exists in " + Alias() + "."
      aSt[ APX_ERR ] := .T.
      RETURN { .F., "" }
   ENDIF
   /* S12: the SOURCE is opened in its OWN free area, read only and shared, and
    * the TARGET -the area that was current- stays where it is */
   nSrc := CoreFreeArea()
   IF nSrc == 0
      aSt[ APX_MSG ] := "No free work areas (16 maximum in use)."
      aSt[ APX_ERR ] := .T.
      RETURN { .F., "" }
   ENDIF
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      SELECT ( nSrc )
      dbUseArea( .T., NIL, cPath, "APSRC", .T., .T. )
      /* S10: the SCOPE of the source counts in its NATURAL order */
      OrdSetFocus( 0 )
   RECOVER USING oErr
      cErr := "Could not open " + cPath + ":" + hb_eol() + oErr:Description
   END SEQUENCE
   IF ! hb_IsNIL( cErr )
      ApCloseSrc( nSrc )
      SELECT ( nTgt )
      aSt[ APX_MSG ] := cErr
      aSt[ APX_ERR ] := .T.
      RETURN { .F., "" }
   ENDIF
   /* S14: the records are COUNTED first, so the confirmation carries the real
    * number -and a walk that fails says so before anything is written */
   aCtx := { 0, 0, NIL, 0 }
   bCount := {|| nTotal := nTotal + 1, .T. }
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      SELECT ( nSrc )
      ApWalkSrc( aSt[ APX_SCOPE ], aSt[ APX_COUNT ], bWhile, bFor, bCount )
   RECOVER USING oErr
      cErr := "Error reading the source:" + hb_eol() + oErr:Description
   END SEQUENCE
   IF ! hb_IsNIL( cErr )
      ApCloseSrc( nSrc )
      SELECT ( nTgt )
      aSt[ APX_MSG ] := cErr
      aSt[ APX_ERR ] := .T.
      RETURN { .F., "" }
   ENDIF
   IF nTotal == 0
      ApCloseSrc( nSrc )
      SELECT ( nTgt )
      aSt[ APX_MSG ] := "No record of the source matches the SCOPE, the WHILE and the FOR."
      aSt[ APX_ERR ] := .T.
      RETURN { .F., "" }
   ENDIF
   IF ! UiConfirm( "Append " + LTrim( Str( nTotal ) ) + " record(s) from " + ;
                   aSt[ APX_SRCNAME ] + "?", "Append From" )
      ApCloseSrc( nSrc )
      SELECT ( nTgt )
      aSt[ APX_MSG ] := "Append cancelled."
      aSt[ APX_ERR ] := .F.
      RETURN { .F., "" }
   ENDIF
   /* S15: the bar is cancelable and what was already appended STAYS -this is a
    * real append, not a transaction- */
   aCtx[ 4 ] := nTotal
   UiProgBegin( "Appending from " + aSt[ APX_SRCNAME ], nTotal, .T. )
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      SELECT ( nSrc )
      ApWalkSrc( aSt[ APX_SCOPE ], aSt[ APX_COUNT ], bWhile, bFor, ;
                 {|| ApWriteRec( aMap, nTgt, nSrc, aCtx ) } )
   RECOVER USING oErr
      aCtx[ 3 ] := "Error after " + LTrim( Str( aCtx[ 1 ] ) ) + " record(s): " + ;
                   oErr:Description
   END SEQUENCE
   UiProgEnd()
   ApCloseSrc( nSrc )
   SELECT ( nTgt )
   /* S14: the target is left on the LAST appended record, so the browser shows
    * what arrived (the CASE of F8 in CoreBrowse() resyncs its position) */
   nDone := aCtx[ 1 ]
   IF nDone > 0 .AND. aCtx[ 2 ] > 0
      BEGIN SEQUENCE WITH {| e | Break( e ) }
         dbGoto( aCtx[ 2 ] )
      RECOVER
      END SEQUENCE
   ENDIF
   cMsg := LTrim( Str( nDone ) ) + " record(s) appended"
   IF nMissing > 0
      cMsg += ", " + LTrim( Str( nMissing ) ) + " field(s) not in the target"
   ENDIF
   aSt[ APX_MSG ] := cMsg
   IF ! hb_IsNIL( aCtx[ 3 ] )
      lOk := ( aCtx[ 3 ] == "cancelled" )
      IF lOk
         aSt[ APX_MSG ] := cMsg + ", cancelled."
         aSt[ APX_ERR ] := .F.
      ELSE
         aSt[ APX_MSG ] := cMsg + "." + hb_eol() + aCtx[ 3 ]
         aSt[ APX_ERR ] := .T.
      ENDIF
      RETURN { lOk, aSt[ APX_MSG ] }
   ENDIF
   aSt[ APX_MSG ] := cMsg + "."
   aSt[ APX_ERR ] := .F.
RETURN { .T., aSt[ APX_MSG ] }

STATIC PROCEDURE ApHelp()
   UiTextWin( { ;
      "Append From - keys", ;
      "", ;
      "  Tab / Shift-Tab    next / previous control", ;
      "  Up / Down          the same as Tab / Shift-Tab", ;
      "  Enter              edit the control; on Accept, Cancel, Browse and", ;
      "                     Fields it runs that control", ;
      "  Space / Ins        the same as Enter", ;
      "  Ctrl-S / Alt-A     Accept: append the records", ;
      "  Alt-C / Alt-X      leave without writing", ;
      "  Alt-B              browse for the source .DBF", ;
      "  Alt-F              the fields of the source to append", ;
      "  Alt-P / Alt-L      jump to Path / File", ;
      "  Alt-S W O          jump to SCOPE / WHILE / FOR", ;
      "  F1 / Esc           this help / cancel", ;
      "", ;
      "The TARGET is the database the browser is on: its name and its driver", ;
      "are the two dim lines of the form. FROM is the file the records come", ;
      "from, and its structure is read from that file.", ;
      "", ;
      "SCOPE, WHILE and FOR apply to the SOURCE, in its natural order, and are", ;
      "compiled before a single record is appended. The records are counted", ;
      "first, the form asks once -'Append N record(s) from FILE.DBF?'- and then", ;
      "writes. A selected field that the target does not have is skipped, and a", ;
      "field that is not ticked is not copied.", ;
      "", ;
      "What was already appended STAYS if the progress box is cancelled.", ;
      "" }, "Append From" )
RETURN

/* the row of the menu: open the form over the browser. It is the only door to
 * this screen (S18) */
FUNCTION BpCmdAppendFrom()
   LOCAL aG, aSt, lPaint := .T., lDone := .F., cAct := "", aRes
   LOCAL nKey, nShift, cAlt, aPt, aCtl, aIn, cSave, cOldCur, cInfo := ""
   IF ! BpNeedDb()
      RETURN NIL
   ENDIF
   aG  := ApGeom()
   aSt := ApStateNew()
   /* a chord left pending by another screen belongs to nobody: it is dropped
    * here so it cannot fire an action of this form (rule 7 of the skill) */
   HcAltChord()
   UiAltChord()
   cOldCur := SetCursor( 0 )
   cSave := SaveScreen( aG[ APG_T ], aG[ APG_L ], Min( MaxRow(), aG[ APG_B ] + 1 ), ;
                        Min( MaxCol(), aG[ APG_R ] + 2 ) )
   DO WHILE ! lDone
      IF lPaint
         ApDraw( aG, aSt )
         lPaint := .F.
      ENDIF
      cAct := ""
      /* 50 ms slices so the click and the chord of the window hook are seen
       * (the mouse of this driver never arrives through Inkey()) */
      nKey   := Inkey( 0.05 )
      nShift := hb_gtInfo( HB_GTI_KBDSHIFTS )
      cAlt   := HcAltChord()
      /* a chord a FIELD EDITOR left pending: UiLineEdit() asks the Alt hook,
       * keeps the letter pending and closes, so the caller has to take it with
       * UiAltChord() - draining only the ring loses the keystroke */
      IF Len( cAlt ) == 0
         cAlt := UiAltChord()
      ENDIF
      IF UiCloseAsk()
         cAct := "cancel"
      ENDIF
      /* right-click-esc (S1/S7): a plain right click cancels the form, exactly
       * as Esc and the X of the window do above */
      IF Empty( cAct ) .AND. HcMouseRightClick()
         cAct := "cancel"
      ENDIF
      IF Empty( cAct )
         /* the chord is dispatched on a 0-key pass too: with Alt held this
          * driver may answer NOTHING through Inkey() and deliver the letter
          * only through the hook ring (rule 7 of the skill) */
         IF nKey == 0 .AND. Len( cAlt ) == 0
            aPt := UiClick()
            IF HB_ISARRAY( aPt )
               aCtl := HcSyncCtlAt( aPt[ 1 ], aPt[ 2 ] )
               IF ! hb_IsNIL( aCtl )
                  DO CASE
                  CASE aCtl[ 4 ] == "KEY"
                     /* a chip of the footer IS the ACTION it announces, and it
                      * is asked for BY NAME (ApHintAct()): a chip name is not
                      * always a key this screen can resolve by its code -
                      * `Ctrl-S` arrives as code 19, which is also K_LEFT (trap
                      * 71), so the key table would step the focus BACKWARDS
                      * instead of running the Accept the chip announces. The
                      * action that comes back is the very one the keyboard and
                      * the [ Accept ] button answer, so there is still a single
                      * place where it runs (the DO CASE below). A name the form
                      * does not know falls back to the one table of chip names. */
                     cAct := ApHintAct( aCtl[ 5 ] )
                     IF Empty( cAct )
                        aIn := HcSyncChipInput( aCtl[ 5 ] )
                        cAct := ApKeyAct( aIn[ 1 ], 0, aIn[ 2 ], aSt )
                     ENDIF
                     /* the click-only path: what runs is the action above and
                      * nothing else, so no key can act twice on this pass */
                     nKey := 0
                  CASE aCtl[ 4 ] == "APBTN" .OR. aCtl[ 4 ] == "APCHIP"
                     /* a button or the chip ACTS: the focus goes to that stop
                      * and its ENTER is the action, so there is no second table
                      * of what a control does (before this, a click on [ Browse ]
                      * cancelled the form because every button that was not
                      * Accept was read as Cancel) */
                     aSt[ APX_FOCUS ] := aCtl[ 5 ]
                     cAct := ApKeyAct( K_ENTER, 0, "", aSt )
                  CASE aCtl[ 5 ] == aSt[ APX_FOCUS ]
                     /* a second click on the control that already has the focus
                      * OPENS it, exactly like Enter */
                     cAct := "edit"
                  OTHERWISE
                     aSt[ APX_FOCUS ] := aCtl[ 5 ]
                     lPaint := .T.
                  ENDCASE
               ENDIF
            ENDIF
         ELSE
            cAct := ApKeyAct( nKey, nShift, cAlt, aSt )
            /* typing enters the input it is standing on and seeds a NEW value
             * there (the rule of the forms of this program) */
            IF Empty( cAct ) .AND. nKey >= 32 .AND. nKey <= 126 .AND. ;
               ApIsText( aSt[ APX_FOCUS ] ) .AND. ApSeed( aSt, Chr( nKey ) )
               aSt[ APX_ERR ] := .F.
               aSt[ APX_MSG ] := ""
               cAct := "edit"
            ENDIF
         ENDIF
      ENDIF
      IF Empty( cAct )
         LOOP
      ENDIF
      DO CASE
      CASE cAct == "cancel"
         lDone := .T.
      CASE cAct == "help"
         ApHelp()
         lPaint := .T.
      CASE cAct == "focus"
         lPaint := .T.
      CASE cAct == "fields"
         ApFields( aSt )
         lPaint := .T.
      CASE cAct == "browse"
         ApBrowse( aSt )
         lPaint := .T.
      CASE cAct == "edit"
         ApEdit( aG, aSt )
         lPaint := .T.
      CASE cAct == "run"
         aRes := ApApply( aSt )
         IF aRes[ 1 ]
            lDone := .T.
            cInfo := aRes[ 2 ]
         ENDIF
         lPaint := .T.
      ENDCASE
   ENDDO
   ApSaveState( aSt )
   RestScreen( aG[ APG_T ], aG[ APG_L ], Min( MaxRow(), aG[ APG_B ] + 1 ), ;
               Min( MaxCol(), aG[ APG_R ] + 2 ), cSave )
   SetCursor( cOldCur )
   SetColor( UI_C_DESKTOP )
   /* the result is told ONCE, over the restored screen: the message row of a form
    * that has just closed would not be read */
   IF Len( AllTrim( cInfo ) ) > 0
      UiInfo( cInfo, "Append From" )
   ENDIF
RETURN NIL

/* =====================================================================
 *  F8 - CommandTools -> "Sum/Average"   (odd/tasks/sum-average-form.md)
 * ---------------------------------------------------------------------
 *  A FORM screen of the same family as "List to Print" (skill
 *  pantallas-de-formulario), not a UiInput with a macro: the title
 *  SUM/AVERAGE of the capture, `Field/Expression to SUM/AVERAGE` and its
 *  input with the [ Fields... ] button that opens the SAME field screen the
 *  LIST form uses, SCOPE with its Count, WHILE, FOR, the two buttons
 *  Accept/Cancel and a message row.
 *
 *  Every rule that can be decided without a window lives in bp_ui.prg (Sm*),
 *  because the headless bank links that module and never this one; here there
 *  is only the screen. The records are read by LpWalkCore(), the ONE walk of
 *  this program, so SCOPE, WHILE, FOR, SET DELETED, the cancel of the progress
 *  bar and the restored record pointer mean exactly what they mean for the
 *  listing - which is what the old `SUM &( c )` of this menu row did NOT do.
 * ===================================================================== */

/* focus stops, in VISUAL order. The Count exists only with NEXT and RECORD
 * (SmFocusOk() is the one rule that says so, and the painter, the ring, the
 * quick letters and the click all read it) */
#define SM_FOC_EXPR    1
#define SM_FOC_FLD     2    /* [ Fi~e~lds... ] */
#define SM_FOC_SCOPE   3
#define SM_FOC_CNT     4
#define SM_FOC_WHILE   5
#define SM_FOC_FOR     6
#define SM_FOC_OK      7    /* [ ~A~ccept ] */
#define SM_FOC_CANCEL  8    /* [ ~C~ancel ] */
#define SM_FOC_MAX     8

/* rows of the box, RELATIVE to its top: one blank row between two controls, so
 * a row that grows (a message with two lines) cannot push the one below */
#define SM_R_TITLE     1
#define SM_R_EXPR      3
#define SM_R_SCOPE     5
#define SM_R_WHILE     7
#define SM_R_FOR       9
#define SM_R_MSG      11
#define SM_R_BTN      12
#define SM_R_HINT     13
#define SM_H          15

/* geometry slots, all computed by SmGeom() from UiCols()/UiRows() */
#define SMG_W          1
#define SMG_L          2
#define SMG_T          3
#define SMG_B          4
#define SMG_R          5
#define SMG_LBL        6     /* column of every label                */
#define SMG_VAL        7     /* column of every value                */
#define SMG_WEXPR      8     /* width of the expression input        */
#define SMG_FLDBTN     9     /* column of the [ Fields... ] button   */
#define SMG_WBIG      10     /* width of WHILE and FOR               */
#define SMG_SCW       11     /* width of the SCOPE select            */
#define SMG_CBLBL     12     /* column of the "Count:" label         */
#define SMG_CVAL      13     /* column of the Count field            */
#define SMG_WCNT      14
#define SMG_MAX       14

/* the widest label of the form: it is what fixes the column of the values, so
 * a label that grows cannot run over its input */
#define SM_LBL_EXPR   "~F~ield/Expression to SUM/AVERAGE:"

/* ---------- geometry ---------- */

STATIC FUNCTION SmGeom()
   LOCAL nWid := UiHotLen( SM_LBL_EXPR ) + 1
   LOCAL nW := Min( 96, UiCols() - 8 )
   LOCAL nL := UiCenterCol( nW )
   LOCAL nR := nL + nW - 1
   LOCAL nT := UiCenterRow( SM_H )
   LOCAL nVal := nL + 2 + nWid + 2
   LOCAL nRoom := nR - 2 - nVal + 1
   LOCAL aG := Array( SMG_MAX )
   aG[ SMG_W ]      := nW
   aG[ SMG_L ]      := nL
   aG[ SMG_T ]      := nT
   aG[ SMG_B ]      := nT + SM_H - 1
   aG[ SMG_R ]      := nR
   aG[ SMG_LBL ]    := nL + 2
   aG[ SMG_VAL ]    := nVal
   aG[ SMG_WBIG ]   := Max( 20, nRoom )
   aG[ SMG_SCW ]    := 10
   aG[ SMG_CBLBL ]  := nVal + 12
   aG[ SMG_CVAL ]   := nVal + 19
   aG[ SMG_WCNT ]   := 6
   /* the expression shares its row with the field button, so it is as wide as
    * the row minus the button and the two columns between them */
   aG[ SMG_WEXPR ]  := Max( 12, nRoom - UiHotLen( "[ Fi~e~lds... ]" ) - 2 )
   aG[ SMG_FLDBTN ] := nVal + aG[ SMG_WEXPR ] + 2
RETURN aG

/* ---------- the state, with the session memory of the last form ---------- */

STATIC FUNCTION SmStateNew()
   LOCAL aSt := Array( SMX_MAX )
   LOCAL aFld := RpFieldList(), aTyp := {}, aLen := {}, aDec := {}, aNum
   LOCAL aN := {}, aT := {}, aL := {}, aD := {}
   LOCAL i, n
   FOR i := 1 TO Len( aFld )
      AAdd( aTyp, Upper( FieldType( i ) ) )
      AAdd( aLen, FieldLen( i ) )
      AAdd( aDec, FieldDec( i ) )
   NEXT
   /* S3: the field screen may only offer what can be added up, and the filter
    * is the pure SmNumFields(), so the rule lives in one place */
   aNum := SmNumFields( aTyp )
   FOR i := 1 TO Len( aNum )
      n := aNum[ i ]
      AAdd( aN, aFld[ n ] )
      AAdd( aT, aTyp[ n ] )
      AAdd( aL, aLen[ n ] )
      AAdd( aD, aDec[ n ] )
   NEXT
   aSt[ SMX_EXPR ]   := ""
   aSt[ SMX_SCOPE ]  := LP_SC_ALL
   aSt[ SMX_COUNT ]  := 1
   aSt[ SMX_WHILE ]  := ""
   aSt[ SMX_FOR ]    := ""
   /* nothing is picked: the expression is the control of this form and the
    * field screen is the helper, so the screen does not guess what to sum */
   aSt[ SMX_SEL ]    := {}
   aSt[ SMX_FIELDS ] := aN
   aSt[ SMX_TYPES ]  := aT
   aSt[ SMX_LENS ]   := aL
   aSt[ SMX_DECS ]   := aD
   aSt[ SMX_FOCUS ]  := SM_FOC_EXPR
   aSt[ SMX_MSG ]    := ""
   aSt[ SMX_ERR ]    := .F.
   /* session memory, element by element (an array is a REFERENCE, trap 67).
    * The field SELECTION is NOT remembered: its numbers belong to the file that
    * was open and would point at other fields here. */
   IF HB_ISARRAY( s_aSmLast ) .AND. Len( s_aSmLast ) == 5
      IF ValType( s_aSmLast[ 1 ] ) == "C"
         aSt[ SMX_EXPR ] := s_aSmLast[ 1 ]
      ENDIF
      IF ValType( s_aSmLast[ 2 ] ) == "N" .AND. s_aSmLast[ 2 ] >= 1 .AND. ;
         s_aSmLast[ 2 ] <= 4
         aSt[ SMX_SCOPE ] := s_aSmLast[ 2 ]
      ENDIF
      IF ValType( s_aSmLast[ 3 ] ) == "N"
         aSt[ SMX_COUNT ] := s_aSmLast[ 3 ]
      ENDIF
      IF ValType( s_aSmLast[ 4 ] ) == "C"
         aSt[ SMX_WHILE ] := s_aSmLast[ 4 ]
      ENDIF
      IF ValType( s_aSmLast[ 5 ] ) == "C"
         aSt[ SMX_FOR ] := s_aSmLast[ 5 ]
      ENDIF
   ENDIF
RETURN aSt

STATIC PROCEDURE SmSaveState( aSt )
   s_aSmLast := { aSt[ SMX_EXPR ], aSt[ SMX_SCOPE ], aSt[ SMX_COUNT ], ;
                  aSt[ SMX_WHILE ], aSt[ SMX_FOR ] }
RETURN

/* ---------- the skip rule and the ring (ONE table, ONE rule) ---------- */

/* S2/S7: does the stop exist right now? The Count is frozen with ALL and REST:
 * it is painted dim and is neither tabbed to nor clicked, exactly like the
 * LIST form (LpFocusOk()). nScope = 0 means "the caller does not know the
 * scope" and keeps the old answer, so the two-argument form behaves as before */
FUNCTION SmFocusOk( nFoc, nScope )
   DEFAULT nScope TO 0
   IF nFoc == SM_FOC_CNT
      RETURN nScope == 0 .OR. LpScopeNeedsCount( nScope )
   ENDIF
RETURN .T.

/* the next reachable stop, wrapping at both ends; .F. when the focus did not
 * move (nothing reachable, which cannot happen but must not loop) */
STATIC FUNCTION SmFocus( aSt, nDir )
   LOCAL n := aSt[ SMX_FOCUS ], i
   FOR i := 1 TO SM_FOC_MAX
      n += iif( nDir < 0, -1, 1 )
      IF n > SM_FOC_MAX
         n := 1
      ENDIF
      IF n < 1
         n := SM_FOC_MAX
      ENDIF
      IF SmFocusOk( n, aSt[ SMX_SCOPE ] )
         IF n == aSt[ SMX_FOCUS ]
            RETURN .F.
         ENDIF
         aSt[ SMX_FOCUS ] := n
         RETURN .T.
      ENDIF
   NEXT
RETURN .F.

/* when SCOPE changes the focus may be standing on the Count, which no longer
 * exists: it walks forward to the next reachable stop */
STATIC PROCEDURE SmFixFocus( aSt )
   IF ! SmFocusOk( aSt[ SMX_FOCUS ], aSt[ SMX_SCOPE ] )
      SmFocus( aSt, 1 )
   ENDIF
RETURN

/* is the stop a text INPUT? (the ones that carry their own background and are
 * entered by typing a character) */
STATIC FUNCTION SmIsText( nFoc )
   DO CASE
   CASE nFoc == SM_FOC_EXPR ; RETURN .T.
   CASE nFoc == SM_FOC_CNT  ; RETURN .T.
   CASE nFoc == SM_FOC_WHILE; RETURN .T.
   CASE nFoc == SM_FOC_FOR  ; RETURN .T.
   ENDCASE
RETURN .F.

/* ---------- the summary and the message row ---------- */

STATIC FUNCTION SmSummary( aSt )
   LOCAL c := "Expression(s): " + LTrim( Str( Len( SmExprList( aSt[ SMX_EXPR ] ) ) ) )
   c += "   SCOPE: " + LpScopeText( aSt[ SMX_SCOPE ] )
   IF LpScopeNeedsCount( aSt[ SMX_SCOPE ] )
      c += " " + LTrim( Str( aSt[ SMX_COUNT ] ) )
   ENDIF
   c += "   Numeric fields: " + LTrim( Str( Len( aSt[ SMX_FIELDS ] ) ) )
RETURN c

/* the message row as ONE line: a compile error carries hb_eol() inside and a
 * SAY does not break lines in GTWVG - it paints the control characters (trap
 * 19), so they are folded into spaces here */
STATIC FUNCTION SmMsgRow( aSt )
   LOCAL c := aSt[ SMX_MSG ]
   IF ValType( c ) != "C"
      c := ""
   ENDIF
   c := StrTran( StrTran( StrTran( c, Chr( 13 ), " " ), Chr( 10 ), " " ), "  ", " " )
RETURN c

/* ---------- the painter (it REGISTERS every control) ---------- */

STATIC PROCEDURE SmDraw( aG, aSt )
   LOCAL nT := aG[ SMG_T ], nL := aG[ SMG_L ]
   LOCAL nB := aG[ SMG_B ], nR := aG[ SMG_R ]
   LOCAL nLbl := aG[ SMG_LBL ], nVal := aG[ SMG_VAL ]
   LOCAL nTxt := nR - 2 - nLbl + 1
   LOCAL cTitle := " SUM/AVERAGE "
   LOCAL cBtn := "[ Fi~e~lds... ]"
   LOCAL cCnt := LTrim( Str( aSt[ SMX_COUNT ] ) )
   HcSyncCtlReset()
   UiPaintBegin()
   UiShadow( nT, nL, nB, nR )
   UiFillBox( nT, nL, nB, nR, UI_C_BOX )
   UiFrame( nT, nL, nB, nR, UI_C_BOXBORD, .T. )
   /* title: the white chip inside the box, centered */
   SetColor( UI_C_FLATBG )
   @ nT + SM_R_TITLE, nL + Max( 1, Int( ( aG[ SMG_W ] - Len( cTitle ) ) / 2 ) ) SAY cTitle
   /* row 1: the expression and the field screen (the same one the LIST form
    * opens, with only the numeric fields in it) */
   LpLabel( nT + SM_R_EXPR, nLbl, SM_LBL_EXPR )
   LpPaintFld( nT + SM_R_EXPR, nVal, aG[ SMG_WEXPR ], aSt[ SMX_EXPR ], ;
               aSt[ SMX_FOCUS ] == SM_FOC_EXPR, SM_FOC_EXPR, "SMFLD" )
   LpPaintBtn( nT + SM_R_EXPR, aG[ SMG_FLDBTN ], cBtn, ;
               aSt[ SMX_FOCUS ] == SM_FOC_FLD, SM_FOC_FLD, "SMBTN" )
   /* row 2: SCOPE and its Count (S2: Count only with NEXT and RECORD) */
   LpLabel( nT + SM_R_SCOPE, nLbl, "~S~COPE:" )
   LpPaintVal( nT + SM_R_SCOPE, nVal, aG[ SMG_SCW ], LpScopeText( aSt[ SMX_SCOPE ] ), ;
               aSt[ SMX_FOCUS ] == SM_FOC_SCOPE, SM_FOC_SCOPE, "SMFLD" )
   LpLabel( nT + SM_R_SCOPE, aG[ SMG_CBLBL ], "Cou~n~t:" )
   IF LpScopeNeedsCount( aSt[ SMX_SCOPE ] )
      LpPaintFld( nT + SM_R_SCOPE, aG[ SMG_CVAL ], aG[ SMG_WCNT ], cCnt, ;
                  aSt[ SMX_FOCUS ] == SM_FOC_CNT, SM_FOC_CNT, "SMFLD" )
   ELSE
      LpPaintDim( nT + SM_R_SCOPE, aG[ SMG_CVAL ], aG[ SMG_WCNT ], cCnt )
   ENDIF
   /* rows 3 and 4: the two xBase conditions */
   LpLabel( nT + SM_R_WHILE, nLbl, "~W~HILE:" )
   LpPaintFld( nT + SM_R_WHILE, nVal, aG[ SMG_WBIG ], aSt[ SMX_WHILE ], ;
               aSt[ SMX_FOCUS ] == SM_FOC_WHILE, SM_FOC_WHILE, "SMFLD" )
   LpLabel( nT + SM_R_FOR, nLbl, "F~O~R:" )
   LpPaintFld( nT + SM_R_FOR, nVal, aG[ SMG_WBIG ], aSt[ SMX_FOR ], ;
               aSt[ SMX_FOCUS ] == SM_FOC_FOR, SM_FOC_FOR, "SMFLD" )
   /* the message row: the summary of the form, or why nothing was summed */
   IF aSt[ SMX_ERR ]
      SetColor( UI_C_ERR )
      @ nT + SM_R_MSG, nLbl SAY PadR( Left( SmMsgRow( aSt ), nTxt ), nTxt )
   ELSE
      SetColor( UI_C_FLATBG )
      @ nT + SM_R_MSG, nLbl SAY PadR( Left( iif( Len( AllTrim( SmMsgRow( aSt ) ) ) > 0, ;
                                                SmMsgRow( aSt ), SmSummary( aSt ) ), nTxt ), nTxt )
   ENDIF
   /* the two buttons, side by side like the rest of the forms */
   LpPaintBtn( nT + SM_R_BTN, nLbl, "[ ~A~ccept ]", ;
               aSt[ SMX_FOCUS ] == SM_FOC_OK, SM_FOC_OK, "SMBTN" )
   LpPaintBtn( nT + SM_R_BTN, nLbl + 14, "[ ~C~ancel ]", ;
               aSt[ SMX_FOCUS ] == SM_FOC_CANCEL, SM_FOC_CANCEL, "SMBTN" )
   /* the hint row: only the keys this screen really has */
   SetColor( UI_C_BOX )
   @ nT + SM_R_HINT, nLbl SAY PadR( "Tab: Move   Enter: Select/Edit   Ctrl-S: Sum   " + ;
                                     "F1: Help   Esc: Cancel", nTxt )
   UiPaintEnd()
RETURN

/* ---------- keys of the form ---------- */

STATIC FUNCTION SmAct( lOk, cAct )
RETURN iif( lOk, cAct, "" )

/* move the focus to a stop, unless that stop does not exist right now */
STATIC FUNCTION SmSetFocus( aSt, nFoc )
   IF ! SmFocusOk( nFoc, aSt[ SMX_SCOPE ] )
      RETURN .F.
   ENDIF
   aSt[ SMX_FOCUS ] := nFoc
RETURN .T.

/* the key -> action table of the form. It MUTATES the focus (a ring step is not
 * an action) and answers the action the loop runs, "" for a key that does
 * nothing here. `Alt+<letter>` comes from the ring of the window hook (trap 61)
 * and the letter is already upper case; a chord nobody serves is DROPPED so it
 * cannot type anything later. The action chords come FIRST, before any case
 * that could type the letter (rule 7 of the skill). */
STATIC FUNCTION SmKeyAct( nKey, nShift, cAlt, aSt )
   LOCAL lCtrl := hb_bitAnd( nShift, HB_GTI_KBD_CTRL ) != 0
   LOCAL lAlt  := hb_bitAnd( nShift, HB_GTI_KBD_ALT ) != 0
   LOCAL nFoc  := aSt[ SMX_FOCUS ]
   DO CASE
   CASE Len( cAlt ) > 0
      DO CASE
      CASE cAlt == "F" ; RETURN SmAct( SmSetFocus( aSt, SM_FOC_EXPR ),  "focus" )
      CASE cAlt == "E" ; RETURN SmAct( SmSetFocus( aSt, SM_FOC_FLD   ),  "focus" )
      CASE cAlt == "S" ; RETURN SmAct( SmSetFocus( aSt, SM_FOC_SCOPE ),  "focus" )
      CASE cAlt == "N" ; RETURN SmAct( SmSetFocus( aSt, SM_FOC_CNT   ),  "focus" )
      CASE cAlt == "W" ; RETURN SmAct( SmSetFocus( aSt, SM_FOC_WHILE ),  "focus" )
      CASE cAlt == "O" ; RETURN SmAct( SmSetFocus( aSt, SM_FOC_FOR   ),  "focus" )
      CASE cAlt == "A" ; RETURN "run"
      CASE cAlt == "C" .OR. cAlt == "X" ; RETURN "cancel"
      ENDCASE
      RETURN ""
   CASE nKey == K_ESC ; RETURN "cancel"
   CASE nKey == K_F1  ; RETURN "help"
   /* Ctrl-S: this driver hands it over as the code of K_LEFT (19) WITH the CTRL
    * bit (trap 71), so the code alone is not the rule; ALT disqualifies it
    * because AltGr IS Ctrl+Alt (trap 38). ONE worker: the same SmRun() the
    * Accept button runs. */
   CASE lCtrl .AND. ! lAlt .AND. ( nKey == K_CTRL_S .OR. nKey == Asc( "s" ) .OR. ;
                                   nKey == Asc( "S" ) )
      RETURN "run"
   CASE nKey == K_ENTER .OR. nKey == K_INS .OR. nKey == K_SPACE
      DO CASE
      CASE nFoc == SM_FOC_OK     ; RETURN "run"
      CASE nFoc == SM_FOC_CANCEL ; RETURN "cancel"
      CASE nFoc == SM_FOC_FLD    ; RETURN "fields"
      ENDCASE
      RETURN "edit"
   CASE nKey == K_TAB .OR. nKey == K_DOWN .OR. nKey == K_RIGHT
      RETURN SmAct( SmFocus( aSt, 1 ), "focus" )
   CASE nKey == K_SH_TAB .OR. nKey == K_UP .OR. nKey == K_LEFT
      RETURN SmAct( SmFocus( aSt, -1 ), "focus" )
   ENDCASE
RETURN ""

/* a typed character ENTERS the input it is standing on and SEEDS it (the rule
 * of the forms of this program): Enter stays free for "do" */
STATIC FUNCTION SmSeed( aSt, cCh )
   DO CASE
   CASE aSt[ SMX_FOCUS ] == SM_FOC_EXPR  ; aSt[ SMX_EXPR ]  := cCh
   CASE aSt[ SMX_FOCUS ] == SM_FOC_CNT   ; aSt[ SMX_COUNT ] := Int( Val( cCh ) )
   CASE aSt[ SMX_FOCUS ] == SM_FOC_WHILE ; aSt[ SMX_WHILE ] := cCh
   CASE aSt[ SMX_FOCUS ] == SM_FOC_FOR   ; aSt[ SMX_FOR ]   := cCh
   OTHERWISE ; RETURN .F.
   ENDCASE
RETURN .T.

/* S4: the expression is checked when its editor closes as well, so a typo
 * keeps the focus on the field and says why. An EMPTY box is not an error YET
 * (the user may be on the way to the field screen) - only Accept complains. */
STATIC FUNCTION SmCheckExpr( aSt )
   LOCAL cErr
   IF Len( AllTrim( aSt[ SMX_EXPR ] ) ) == 0
      aSt[ SMX_MSG ] := ""
      aSt[ SMX_ERR ] := .F.
      RETURN .T.
   ENDIF
   SmExprBlocks( aSt[ SMX_EXPR ], @cErr )
   IF ! hb_IsNIL( cErr )
      aSt[ SMX_MSG ] := cErr
      aSt[ SMX_ERR ] := .T.
      aSt[ SMX_FOCUS ] := SM_FOC_EXPR
      RETURN .F.
   ENDIF
   aSt[ SMX_MSG ] := ""
   aSt[ SMX_ERR ] := .F.
RETURN .T.

/* the two xBase conditions, checked the same way the LIST form does it */
STATIC FUNCTION SmCheckCond( aSt, cExpr, nFoc )
   LOCAL cErr
   LpCondBlock( cExpr, @cErr )
   IF ! hb_IsNIL( cErr )
      aSt[ SMX_MSG ] := cErr
      aSt[ SMX_ERR ] := .T.
      aSt[ SMX_FOCUS ] := nFoc
      RETURN .F.
   ENDIF
   aSt[ SMX_MSG ] := ""
   aSt[ SMX_ERR ] := .F.
RETURN .T.

/* open the control that has the focus and MOVE THE RING when it is confirmed:
 * Enter, Tab and a choice in a list all leave the focus on the NEXT control
 * (Shift-Tab goes back). A value that does not validate keeps the focus and
 * says why. */
STATIC PROCEDURE SmEdit( aG, aSt )
   LOCAL nFoc := aSt[ SMX_FOCUS ], cNew, n, lStay := .F., lText := .F.
   DO CASE
   CASE nFoc == SM_FOC_SCOPE
      n := UiPick( LpScopeList(), "SCOPE", aSt[ SMX_SCOPE ] )
      IF ValType( n ) == "N" .AND. n >= 1 .AND. n <= 4
         IF ! LpScopeNeedsCount( n ) .AND. aSt[ SMX_FOCUS ] == SM_FOC_CNT
            aSt[ SMX_FOCUS ] := SM_FOC_SCOPE
         ENDIF
         aSt[ SMX_SCOPE ] := n
         aSt[ SMX_MSG ] := ""
         aSt[ SMX_ERR ] := .F.
      ELSE
         lStay := .T.
      ENDIF
   CASE nFoc == SM_FOC_EXPR
      lText := .T.
      cNew := UiLineEdit( aG[ SMG_T ] + SM_R_EXPR, aG[ SMG_VAL ], aG[ SMG_WEXPR ], ;
                          aSt[ SMX_EXPR ], .F., UI_C_LISTSEL, .F., .T. )
      IF ! hb_IsNIL( cNew )
         aSt[ SMX_EXPR ] := cNew
         IF ! SmCheckExpr( aSt )
            lStay := .T.
         ENDIF
      ENDIF
   CASE nFoc == SM_FOC_CNT
      lText := .T.
      cNew := UiLineEdit( aG[ SMG_T ] + SM_R_SCOPE, aG[ SMG_CVAL ], aG[ SMG_WCNT ], ;
                          LTrim( Str( aSt[ SMX_COUNT ] ) ), .T., UI_C_LISTSEL, .F., .T. )
      IF ! hb_IsNIL( cNew )
         n := Val( cNew )
         aSt[ SMX_COUNT ] := iif( n > 0, Int( n ), 1 )
      ENDIF
   CASE nFoc == SM_FOC_WHILE
      lText := .T.
      cNew := UiLineEdit( aG[ SMG_T ] + SM_R_WHILE, aG[ SMG_VAL ], aG[ SMG_WBIG ], ;
                          aSt[ SMX_WHILE ], .F., UI_C_LISTSEL, .F., .T. )
      IF ! hb_IsNIL( cNew )
         aSt[ SMX_WHILE ] := cNew
         IF ! SmCheckCond( aSt, cNew, SM_FOC_WHILE )
            lStay := .T.
         ENDIF
      ENDIF
   CASE nFoc == SM_FOC_FOR
      lText := .T.
      cNew := UiLineEdit( aG[ SMG_T ] + SM_R_FOR, aG[ SMG_VAL ], aG[ SMG_WBIG ], ;
                          aSt[ SMX_FOR ], .F., UI_C_LISTSEL, .F., .T. )
      IF ! hb_IsNIL( cNew )
         aSt[ SMX_FOR ] := cNew
         IF ! SmCheckCond( aSt, cNew, SM_FOC_FOR )
            lStay := .T.
         ENDIF
      ENDIF
   ENDCASE
   IF lStay
      RETURN
   ENDIF
   IF lText .AND. UiEditExit() == K_SH_TAB
      SmFocus( aSt, -1 )
   ELSE
      SmFocus( aSt, 1 )
   ENDIF
RETURN

/* S3: the field screen of this form. It is the SAME screen the LIST form opens
 * (LpFieldPick()), with the numeric fields it was handed in its own state, and
 * accepting it puts the chosen names in the expression input, comma separated
 * and in the order they were picked. */
STATIC PROCEDURE SmFields( aSt )
   LOCAL aSel := LpFieldPick( aSt[ SMX_FIELDS ], aSt[ SMX_TYPES ], aSt[ SMX_LENS ], ;
                              aSt[ SMX_DECS ], aSt[ SMX_SEL ], "SUM/AVERAGE" )
   LOCAL c
   IF hb_IsNIL( aSel )
      RETURN
   ENDIF
   aSt[ SMX_SEL ] := aSel
   c := SmExprText( aSel, aSt[ SMX_FIELDS ] )
   IF Len( c ) > 0
      aSt[ SMX_EXPR ] := c
   ENDIF
   aSt[ SMX_MSG ] := ""
   aSt[ SMX_ERR ] := .F.
   aSt[ SMX_FOCUS ] := SM_FOC_EXPR
RETURN

/* one record of the sum: the per-record half of the walk, kept out of the loop
 * so the loop itself is the shared LpWalkCore(). It MUTATES the array of totals
 * - an array is a REFERENCE - so the block that calls it never assigns a
 * captured variable. */
STATIC PROCEDURE SmAccum( aSum, aBlk )
   LOCAL i, x
   FOR i := 1 TO Len( aBlk )
      x := Eval( aBlk[ i ] )
      IF ValType( x ) == "N"
         aSum[ i ] += x
      ENDIF
   NEXT
RETURN

/* THE worker of Accept and of Ctrl-S. It answers the report to show when the
 * form has to CLOSE, and NIL when the user still has something to fix - the
 * message row then already carries why, and nothing has been read. */
STATIC FUNCTION SmRun( aG, aSt )
   LOCAL bFor, bWhile, aBlk, aTxt, aSum, cErr, nRecs := 0, nRes, i
   LOCAL nCount := Int( aSt[ SMX_COUNT ] )
   DEFAULT aG TO NIL
   /* S6: both conditions are compiled BEFORE the walk starts, so a typo cannot
    * leave a table half read */
   bFor := LpCondBlock( aSt[ SMX_FOR ], @cErr )
   IF ! hb_IsNIL( cErr )
      aSt[ SMX_MSG ] := cErr
      aSt[ SMX_ERR ] := .T.
      aSt[ SMX_FOCUS ] := SM_FOC_FOR
      RETURN NIL
   ENDIF
   bWhile := LpCondBlock( aSt[ SMX_WHILE ], @cErr )
   IF ! hb_IsNIL( cErr )
      aSt[ SMX_MSG ] := cErr
      aSt[ SMX_ERR ] := .T.
      aSt[ SMX_FOCUS ] := SM_FOC_WHILE
      RETURN NIL
   ENDIF
   /* S4: the expressions are compiled (and checked to be numeric) before
    * anything is walked */
   aTxt := SmExprList( aSt[ SMX_EXPR ] )
   aBlk := SmExprBlocks( aSt[ SMX_EXPR ], @cErr )
   IF ! hb_IsNIL( cErr )
      aSt[ SMX_MSG ] := cErr
      aSt[ SMX_ERR ] := .T.
      aSt[ SMX_FOCUS ] := SM_FOC_EXPR
      RETURN NIL
   ENDIF
   IF LpScopeNeedsCount( aSt[ SMX_SCOPE ] ) .AND. nCount < 1
      aSt[ SMX_MSG ] := "Count has to be 1 or more."
      aSt[ SMX_ERR ] := .T.
      aSt[ SMX_FOCUS ] := SM_FOC_CNT
      RETURN NIL
   ENDIF
   IF aSt[ SMX_SCOPE ] == LP_SC_REC .AND. ;
      ( nCount < 1 .OR. nCount > LastRec() )
      aSt[ SMX_MSG ] := "Record " + LTrim( Str( nCount ) ) + " is not in the database."
      aSt[ SMX_ERR ] := .T.
      aSt[ SMX_FOCUS ] := SM_FOC_CNT
      RETURN NIL
   ENDIF
   aSum := Array( Len( aBlk ) )
   AFill( aSum, 0 )
   /* S6: the SAME walk as the listing, so SCOPE, WHILE, FOR, SET DELETED and
    * the restored pointer cannot mean something else here */
   nRes := LpWalkCore( aSt[ SMX_SCOPE ], nCount, bFor, bWhile, ;
                       {|| SmAccum( aSum, aBlk ) }, ;
                       "Summing " + Upper( Alias() ), @cErr, @nRecs )
   IF nRes == 2
      aSt[ SMX_MSG ] := cErr
      aSt[ SMX_ERR ] := .T.
      RETURN NIL
   ENDIF
   IF nRes == 1
      aSt[ SMX_MSG ] := "The SUM/AVERAGE was cancelled."
      aSt[ SMX_ERR ] := .T.
      RETURN NIL
   ENDIF
   IF nRecs < 1
      aSt[ SMX_MSG ] := "No record matches the scope."
      aSt[ SMX_ERR ] := .T.
      RETURN NIL
   ENDIF
   aSt[ SMX_ERR ] := .F.
   aSt[ SMX_MSG ] := LTrim( Str( nRecs ) ) + " record(s) summed."
   cErr := ""
   aTxt := SmResultLines( aTxt, aSum, nRecs )
   FOR i := 1 TO Len( aTxt )
      cErr += iif( i > 1, hb_eol(), "" ) + aTxt[ i ]
   NEXT
RETURN cErr

STATIC PROCEDURE SmHelp()
   UiTextWin( { ;
      "SUM/AVERAGE - keys", ;
      "", ;
      "  Tab / Shift-Tab    next / previous control", ;
      "  Up / Down          same as Tab / Shift-Tab", ;
      "  Enter              open the control (a list, or the field editor),", ;
      "                     and when it closes the focus moves to the NEXT one", ;
      "  Space / Ins        same as Enter", ;
      "  Ctrl-S / Alt-A     Accept: sum the records", ;
      "  Alt-E              the field selection screen", ;
      "  Alt-F S N W O      jump to Expression / SCOPE / Count / WHILE / FOR", ;
      "  Alt-C / Alt-X      leave without summing", ;
      "  F1 / Esc           this help / cancel", ;
      "", ;
      "Field/Expression is SUMmed and AVERAGEd over the records the scope", ;
      "selects, and several comma-separated expressions are allowed:", ;
      "  ART_COSTO, ART_COSTO * 1.21", ;
      "The expression is compiled before anything is read, and one that does", ;
      "not compile - or that is not numeric - keeps the focus on the field and", ;
      "says why in the message row.", ;
      "", ;
      "SCOPE is ALL / NEXT / REST / RECORD and Count only exists with NEXT", ;
      "and RECORD. ALL starts at the top of the ACTIVE ORDER, RECORD n is the", ;
      "n-th record of that order, FOR filters and WHILE CUTS the reading at", ;
      "the first false; SET DELETED is respected and the record pointer is", ;
      "left where it was.", ;
      "", ;
      "The field screen lists only the NUMERIC fields: Space or a click adds", ;
      "one and shows its ORDER NUMBER, removing it renumbers the rest, and", ;
      "accepting puts the chosen names in the expression box, comma separated.", ;
      "" }, "SUM/AVERAGE" )
RETURN

/* the row of the menu: open the form over the browser */
FUNCTION BpCmdSumAverage()
   LOCAL aG, aSt, lPaint := .T., lDone := .F., cText := NIL, cAct := ""
   LOCAL nKey, nShift, cAlt, aPt, aCtl, cSave, cOldCur
   IF ! BpNeedDb()
      RETURN NIL
   ENDIF
   aG  := SmGeom()
   aSt := SmStateNew()
   IF Empty( aSt[ SMX_FIELDS ] )
      UiMsg( "There is no numeric field in this database.", "SUM/AVERAGE" )
      RETURN NIL
   ENDIF
   cOldCur := SetCursor( 0 )
   cSave := SaveScreen( aG[ SMG_T ], aG[ SMG_L ], Min( MaxRow(), aG[ SMG_B ] + 1 ), ;
                        Min( MaxCol(), aG[ SMG_R ] + 2 ) )
   DO WHILE ! lDone
      IF lPaint
         SmDraw( aG, aSt )
         lPaint := .F.
      ENDIF
      cAct := ""
      /* 50 ms slices so the click and the chord of the window hook are seen
       * (the mouse of this driver never arrives through Inkey()) */
      nKey   := Inkey( 0.05 )
      nShift := hb_gtInfo( HB_GTI_KBDSHIFTS )
      cAlt   := HcAltChord()
      /* a chord a FIELD EDITOR left pending: UiLineEdit() asks the Alt hook,
       * keeps the letter pending and closes, so the caller has to take it with
       * UiAltChord() - draining only the ring loses the keystroke. */
      IF Len( cAlt ) == 0
         cAlt := UiAltChord()
      ENDIF
      IF UiCloseAsk()
         cAct := "cancel"
      ENDIF
      /* right-click-esc (S1/S7): a plain right click cancels the form, exactly
       * as Esc and the X of the window do above */
      IF Empty( cAct ) .AND. HcMouseRightClick()
         cAct := "cancel"
      ENDIF
      IF Empty( cAct )
         /* the chord is dispatched on a 0-key pass too: with Alt held this
          * driver may answer NOTHING through Inkey() and deliver the letter
          * only through the hook ring (rule 7 of the skill) */
         IF nKey == 0 .AND. Len( cAlt ) == 0
            aPt := UiClick()
            IF HB_ISARRAY( aPt )
               aCtl := HcSyncCtlAt( aPt[ 1 ], aPt[ 2 ] )
               IF ! hb_IsNIL( aCtl )
                  IF aCtl[ 4 ] == "SMBTN"
                     /* a click on a button ACTS, exactly like its key */
                     aSt[ SMX_FOCUS ] := aCtl[ 5 ]
                     DO CASE
                     CASE aCtl[ 5 ] == SM_FOC_OK     ; cAct := "run"
                     CASE aCtl[ 5 ] == SM_FOC_CANCEL ; cAct := "cancel"
                     OTHERWISE                       ; cAct := "fields"
                     ENDCASE
                  ELSEIF aCtl[ 5 ] == aSt[ SMX_FOCUS ]
                     /* a second click on the control that already has the
                      * focus OPENS it, exactly like Enter */
                     cAct := "edit"
                  ELSE
                     aSt[ SMX_FOCUS ] := aCtl[ 5 ]
                     lPaint := .T.
                  ENDIF
               ENDIF
            ENDIF
         ELSE
            cAct := SmKeyAct( nKey, nShift, cAlt, aSt )
            /* typing enters the input it is standing on (rule of the forms of
             * this program) and seeds a NEW value there */
            IF Empty( cAct ) .AND. nKey >= 32 .AND. nKey <= 126 .AND. ;
               SmIsText( aSt[ SMX_FOCUS ] ) .AND. SmSeed( aSt, Chr( nKey ) )
               aSt[ SMX_ERR ] := .F.
               aSt[ SMX_MSG ] := ""
               cAct := "edit"
            ENDIF
         ENDIF
      ENDIF
      IF Empty( cAct )
         LOOP
      ENDIF
      DO CASE
      CASE cAct == "cancel"
         lDone := .T.
      CASE cAct == "help"
         SmHelp()
         lPaint := .T.
      CASE cAct == "focus"
         lPaint := .T.
      CASE cAct == "fields"
         SmFields( aSt )
         lPaint := .T.
      CASE cAct == "edit"
         SmEdit( aG, aSt )
         lPaint := .T.
      CASE cAct == "run"
         cText := SmRun( aG, aSt )
         IF ValType( cText ) == "C"
            lDone := .T.
         ENDIF
         lPaint := .T.
      ENDCASE
   ENDDO
   SmSaveState( aSt )
   RestScreen( aG[ SMG_T ], aG[ SMG_L ], Min( MaxRow(), aG[ SMG_B ] + 1 ), ;
               Min( MaxCol(), aG[ SMG_R ] + 2 ), cSave )
   SetCursor( cOldCur )
   SetColor( UI_C_DESKTOP )
   /* the result is told ONCE, over the restored screen: the message row of a
    * form that has just closed would not be read */
   IF ValType( cText ) == "C" .AND. Len( AllTrim( cText ) ) > 0
      UiInfo( cText, "SUM/AVERAGE" )
   ENDIF
RETURN NIL

FUNCTION BpCmdZap()
   LOCAL oErr
   IF ! BpNeedDb() ; RETURN NIL ; ENDIF
   IF ! UiConfirm( "ZAP: EMPTY the database " + Upper( Alias() ) + " ? (irreversible)", "Zap" )
      RETURN NIL
   ENDIF
   UiProgBusy( "Emptying database..." )
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      ZAP
      UiProgEnd()
      UiInfo( "Database emptied.", "Zap" )
   RECOVER USING oErr
      UiProgEnd()
      UiErr( "Error in ZAP: " + oErr:Description )
   END SEQUENCE
RETURN NIL

/* =====================================================================
 *  Helper functions referenced by the menus
 * ===================================================================== */

/* Database FileSpec: same form as the Index one (see FSPEC_*), with the label
 * and the 13-character field measured on the original at row 15,
 * columns 20 and 40; black on bright green) */
FUNCTION BpDbFileSpec()
   LOCAL c, cSave
   LOCAL nT := UiFitRow( UiCenterRow( FSPEC_H ), FSPEC_H + 1 )
   LOCAL nL := UiFitCol( UiCenterCol( FSPEC_W ), FSPEC_W + 2 )
   LOCAL nB := nT + FSPEC_H - 1, nR := nL + FSPEC_W - 1
   cSave := SaveScreen( nT - 1, nL - 1, Min( MaxRow(), nB + 2 ), ;
                        Min( MaxCol(), nR + 2 ) )
   UiPaintBegin()
   UiFormBox( nT, nL, nB, nR )
   UiWrite( FSPEC_R( 15 ), FSPEC_C( 20 ), "Database FileSpec:", UI_C_DLG )
   UiPaintEnd()
   c := UiFormEdit( FSPEC_R( 15 ), FSPEC_C( 40 ), 13, CoreDbfSpec(), .F. )
   RestScreen( nT - 1, nL - 1, Min( MaxRow(), nB + 2 ), ;
               Min( MaxCol(), nR + 2 ), cSave )
   IF c != NIL .AND. ! Empty( c )
      CoreSetDbfSpec( c )
   ENDIF
RETURN NIL

/* =====================================================================
 *  F3 - Index -> "Dynamic Index Options..."
 * ---------------------------------------------------------------------
 *  NOTE: in BRO.EXE this option appears DIMMED (measured: captures
 *  o5-scope-06-op5.png, o6-idxsel-06-op1.png: it is seen in gray and the menu
 *  arrows SKIP it), so its submenu could NOT be captured. The three entries
 *  and their shortcuts come from the string dump (zone 03D71B..03D7E4, which keeps
 *  the pieces with their hot-key marks):
 *
 *    "Show ~Unique Keys is " + "ON " / "OFF" + " <Shift-F6>"
 *    "De" / "A" + "scending ~Order" + " is ON    <Alt-F6>"
 *    "Make ~Custom Index" + " <Ctrl-F6>"
 *
 *  and the warnings of the third one are from the same dump (03DEAA):
 *  "Warning: This Process is NOT reversible!" / "Turn this Index into a
 *  Custom Index?", plus 056EA4 "Not a RYO / Custom Index". THE DBFCDX ENGINE OF
 *  hwBro DOES NOT KNOW HOW TO TURN A TAG INTO A "custom"/RYO INDEX, so the third
 *  option does not fake it: it says so with the message of the original.
 * ===================================================================== */
/* ---- submenu geometry (native 120x44 canvas) -------------------------
 * The submenu is 8 rows high and as wide as its longest entry plus the margin
 * of its box; only the origin and the width limits come from the canvas, so
 * BpDynRect() is their single source. */
#define DY_H         8

STATIC FUNCTION BpDynRect( aItems )
   LOCAL nT, nL, nW, nMax := 0, i
   FOR i := 1 TO Len( aItems )
      nMax := Max( nMax, UiHotLen( aItems[ i ] ) )
   NEXT
   /* width from the CONTENT (longest entry plus margin); the old
    * Min( 78, ... ) was the right edge of the 80x25 grid */
   nW := Min( UiCols() - 2, Max( nMax + 5, 34 ) )
   nT := UiFitRow( UiCenterRow( DY_H ), DY_H + 1 )
   nL := UiFitCol( UiCenterCol( nW ), nW + 2 )
RETURN { nT, nL, nT + DY_H - 1, nL + nW - 1 }

/* REAL state of the active tag (always re-read; a copy is never kept).
 * NOTE (measured with a test program on this Harbour): OrdIsUnique() and
 * OrdDescend() as SETTERS do nothing on the .CDX of the original (their
 * tags are "SIx compatible" and the call returns .F. without changing the order);
 * the one that DOES work is dbOrderInfo() with the new value as 4th parameter. */
STATIC FUNCTION BpDynUnique()
   LOCAL l := .F.
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      l := dbOrderInfo( DBOI_UNIQUE )
   RECOVER
      l := .F.
   END SEQUENCE
RETURN ( ValType( l ) == "L" .AND. l )

STATIC FUNCTION BpDynDesc()
   LOCAL l := .F.
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      l := dbOrderInfo( DBOI_ISDESC )
   RECOVER
      l := .F.
   END SEQUENCE
RETURN ( ValType( l ) == "L" .AND. l )

/* texts of the three entries, with the literals of the dump and the same
 * hot-key mark (~X~) the menus of hwBro use */
STATIC FUNCTION BpDynItems()
   LOCAL lUni := BpDynUnique(), lDesc := BpDynDesc()
RETURN { ;
   "Show ~Unique Keys is " + iif( lUni, "ON ", "OFF" ) + " <Shift-F6>", ;
   iif( lDesc, "Descending", "Ascending" ) + " ~Order is ON    <Alt-F6>", ;
   "Make ~Custom Index" + "    <Ctrl-F6>" }

/* position (1..3) of the entry whose hot key is cKey (0 if none) */
STATIC FUNCTION BpDynHot( aItems, cKey )
   LOCAL i, n := 0
   FOR i := 1 TO Len( aItems )
      IF n == 0 .AND. UiHotKey( aItems[ i ] ) == cKey
         n := i
      ENDIF
   NEXT
RETURN n

/* submenu: cyan box with the title in yellow, the entries with their hot
 * key and the highlighted one in white on brown, like the menus. The bar of the
 * highlighted entry is painted cell by cell (the text carries ~ marks that
 * are not drawn, so the width is computed with UiHotLen) */
STATIC PROCEDURE BpDynDraw( aItems, nSel, aB )
   LOCAL i, nMax := 0, nW, nL, nR, nB, nT, cTxt
   FOR i := 1 TO Len( aItems )
      nMax := Max( nMax, UiHotLen( aItems[ i ] ) )
   NEXT
   /* NOTE: the rectangle comes from BpDynRect(), the same one the caller used
    * for its SaveScreen: the width used to be computed here as
    * Min(76, nMax+5) and used as the RIGHT COLUMN, so the box went from nL to
    * ~40 and the text (35 cells) overflowed outside the frame. */
   nT := aB[ 1 ] ; nL := aB[ 2 ] ; nB := aB[ 3 ] ; nR := aB[ 4 ]
   nW := nR - nL + 1
   UiPaintBegin()
   UiShadow( nT, nL, nB, nR )
   UiFillBox( nT, nL, nB, nR, UI_C_BOX )
   UiFrame( nT, nL, nB, nR, UI_C_BOX, .T. )
   UiWrite( nT, nL + 2, " Dynamic Index Options ", UI_C_BOX )
   FOR i := 1 TO Len( aItems )
      cTxt := aItems[ i ] + Space( nMax - UiHotLen( aItems[ i ] ) )
      IF i == nSel
         UiDrawHot( nT + 1 + i, nL + 2, cTxt, UI_C_BOXSEL, UI_C_HOTSEL )
         UiWrite( nT + 1 + i, nL + 2 + nMax, ;
                  Space( nR - nL - 3 - nMax ), UI_C_BOXSEL )
      ELSE
         UiDrawHot( nT + 1 + i, nL + 2, cTxt, UI_C_BOX, UI_C_HOT )
      ENDIF
   NEXT
   BpHotKey( nT + 6, nL + 2,  "Enter", "=Select" )
   BpHotKey( nT + 6, nL + 20, "Esc",   "=Leave" )
   SetColor( UI_C_DESKTOP )
   UiPaintEnd()
RETURN NIL

/* runs one of the three entries. The first two really toggle the ACTIVE tag
 * (OrdIsUnique/OrdDescend) and the submenu is repainted with the state the
 * engine returns; the third warns that it is not reversible and, if accepted,
 * tells the truth: hwBro does not know how to do it. */
STATIC PROCEDURE BpDynRun( nSel )
   LOCAL oErr, lNew := .F.
   DO CASE
   CASE nSel == 1
      lNew := ! BpDynUnique()
      BEGIN SEQUENCE WITH {| e | Break( e ) }
         dbOrderInfo( DBOI_UNIQUE, , , lNew )
         dbGoTop()
      RECOVER USING oErr
         UiErr( "Could not change Unique: " + oErr:Description, "Dynamic Index Options" )
      END SEQUENCE
   CASE nSel == 2
      lNew := ! BpDynDesc()
      BEGIN SEQUENCE WITH {| e | Break( e ) }
         dbOrderInfo( DBOI_ISDESC, , , lNew )
         dbGoTop()
      RECOVER USING oErr
         UiErr( "Could not reverse the order: " + oErr:Description, "Dynamic Index Options" )
      END SEQUENCE
   CASE nSel == 3
      IF UiConfirm( "Warning: This Process is NOT reversible!" + hb_eol() + ;
                    "Turn this Index into a Custom Index?", "Dynamic Index Options" )
         UiMsg( "Not a RYO / Custom Index" + hb_eol() + ;
                "This reconstruction cannot turn an existing Index" + hb_eol() + ;
                "into a Custom Index.", "Dynamic Index Options" )
      ENDIF
   ENDCASE
   CoreStatus()
RETURN NIL

FUNCTION BpIdxDynOptions()
   LOCAL aItems, nSel := 1, nKey, lExit := .F., n, cSave, aB
   IF ! BpNeedDb() ; RETURN NIL ; ENDIF
   IF Empty( CoreKeyExpr() )
      /* with no active order there is no tag to toggle */
      UiMsg( "No Open Index Files", "Dynamic Index Options" )
      RETURN NIL
   ENDIF
   /* the rectangle is computed ONCE and used for both the SaveScreen and the
    * drawing: the entries change their text ("Ascending"/"Descending"), so a
    * rectangle that followed them on every repaint would leave garbage */
   aB := BpDynRect( BpDynItems() )
   cSave := SaveScreen( aB[ 1 ], aB[ 2 ], Min( MaxRow(), aB[ 3 ] + 1 ), ;
                        Min( MaxCol(), aB[ 4 ] + 2 ) )
   DO WHILE ! lExit
      aItems := BpDynItems()
      BpDynDraw( aItems, nSel, aB )
      /* S1/S4 (window-close.md B4): the X of the window (BpWaitKey) closes the
       * submenu through the same exit <Esc> uses -out of the loop, whose tail
       * restores the box-. An idle slice does not reach the DO CASE, so the box
       * is NOT repainted every 50 ms. */
      nKey := BpWaitKey()
      IF nKey == 0
         EXIT
      ENDIF
      DO CASE
      CASE nKey == K_ESC
         lExit := .T.
      CASE nKey == K_UP
         nSel := iif( nSel <= 1, Len( aItems ), nSel - 1 )
      CASE nKey == K_DOWN
         nSel := iif( nSel >= Len( aItems ), 1, nSel + 1 )
      CASE nKey == K_ENTER .OR. nKey == K_SPACE
         BpDynRun( nSel )
      CASE nKey == K_SH_F6
         BpDynRun( 1 )
      CASE nKey == K_ALT_F6
         BpDynRun( 2 )
      CASE nKey == K_CTRL_F6
         BpDynRun( 3 )
      CASE nKey >= 32 .AND. nKey <= 126
         n := BpDynHot( aItems, Upper( Chr( nKey ) ) )
         IF n > 0
            BpDynRun( n )
         ENDIF
      ENDCASE
   ENDDO
   RestScreen( aB[ 1 ], aB[ 2 ], Min( MaxRow(), aB[ 3 ] + 1 ), ;
               Min( MaxCol(), aB[ 4 ] + 2 ), cSave )
   SetColor( UI_C_DESKTOP )
RETURN NIL

/* Functions that in the original depend on third party libraries not included */
FUNCTION BpFlexFileLink()
   UiMsg( "FlexFile Link: NO" + hb_eol() + hb_eol() + ;
          "FlexFile is a third-party library of the original product and" + hb_eol() + ;
          "is linked in this reconstruction (same as in BroPlus" + hb_eol() + ;
          "original without the driver linked).", "FlexFile" )
RETURN NIL

FUNCTION BpRyoLink()
   UiMsg( "RYO Index Link: NO" + hb_eol() + hb_eol() + ;
          "The 'Roll Your Own' RDD is not linked in this reconstruction.", "RYO Index" )
RETURN NIL

FUNCTION BpEditTopPointer()
   UiMsg( "Edit Top Pointer: requires FlexFile Link." + hb_eol() + ;
          "FlexFile is not linked in this reconstruction.", "Top Pointer" )
RETURN NIL

FUNCTION BpFldLockNum()
   LOCAL c := UiInput( "Lock # of Fields (fixed columns):", LTrim( Str( CoreLockFields() ) ), 5 )
   IF c == NIL ; RETURN NIL ; ENDIF
   CoreSetLockFields( Val( c ) )
   UiInfo( "Locked columns: " + LTrim( Str( CoreLockFields() ) ), "Fields" )
RETURN NIL

/* --- Cut / Paste / Insert column on the display order --- */
FUNCTION BpFldCutColumn()
   LOCAL c, n
   IF ! BpNeedDb() ; RETURN NIL ; ENDIF
   c := UiInput( "VISIBLE column number to cut:", "1", 4 )
   IF c == NIL .OR. Empty( c ) ; RETURN NIL ; ENDIF
   n := CoreCutColumn( Val( c ) )
   IF n == 0
      UiErr( "Column out of range." )
   ELSE
      s_nCutCol := n
      UiInfo( "Column " + c + " cut (" + DbStruct()[ n ][ 1 ] + ")." + hb_eol() + ;
              "Paste with Paste Column or Insert Column.", "Cut Column" )
   ENDIF
RETURN NIL

FUNCTION BpFldPasteColumn()
   LOCAL c, n
   IF ! BpNeedDb() ; RETURN NIL ; ENDIF
   IF s_nCutCol == 0
      UiMsg( "No column is cut (use Cut/Delete Column).", "Paste Column" )
      RETURN NIL
   ENDIF
   c := UiInput( "Position to paste:", "1", 4 )
   IF c == NIL .OR. Empty( c ) ; RETURN NIL ; ENDIF
   n := CoreInsertColumn( s_nCutCol, Val( c ) )
   IF n > 0
      UiInfo( "Column pasted at position " + LTrim( Str( n ) ), "Paste Column" )
   ENDIF
RETURN NIL

FUNCTION BpFldInsertColumn()
   LOCAL c, n
   IF ! BpNeedDb() ; RETURN NIL ; ENDIF
   c := UiInput( "FIELD number to insert:", "1", 4 )
   IF c == NIL .OR. Empty( c ) ; RETURN NIL ; ENDIF
   n := Val( c )
   c := UiInput( "Position to insert:", "1", 4 )
   IF c == NIL .OR. Empty( c ) ; RETURN NIL ; ENDIF
   IF CoreInsertColumn( n, Val( c ) ) > 0
      UiInfo( "Field inserted in the view.", "Insert Column" )
   ELSE
      UiErr( "Invalid field number." )
   ENDIF
RETURN NIL

FUNCTION BpGlobToggleCellEdit()
   UiMsg( "Cell Edit: " + iif( CoreToggleCellEdit(), "ON", "OFF" ), "GlobalSet" )
RETURN NIL

FUNCTION BpGlobToggleHideDel()
   UiMsg( "Hide Deleted Recs: " + iif( CoreToggleHideDel(), "ON", "OFF" ), "GlobalSet" )
RETURN NIL

FUNCTION BpGlobToggleSoftSeek()
   UiMsg( "Softseek: " + iif( CoreToggleSoftSeek(), "ON", "OFF" ), "GlobalSet" )
RETURN NIL

FUNCTION BpRecViewAll()
   LOCAL a, i
   IF ! BpNeedDb() ; RETURN NIL ; ENDIF
   a := CoreSelFields()
   FOR i := 1 TO Len( a )
      a[ i ] := .T.
   NEXT
   IF CoreShowSelected()
      CoreToggleShowSelected()
   ENDIF
   UiInfo( "View: ALL fields.", "Record View/Edit" )
RETURN NIL

FUNCTION BpRecViewSelected()
   IF ! BpNeedDb() ; RETURN NIL ; ENDIF
   IF ! CoreShowSelected()
      CoreToggleShowSelected()
   ENDIF
   UiInfo( "View: SELECTED fields." + hb_eol() + ;
          "Check/uncheck fields with F4 - Field Selection Screen.", "Record View/Edit" )
RETURN NIL
