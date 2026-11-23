/*
 * bp_dot.prg - dBASE-style dot prompt (F9): xBase command interface.
 *
 * The dot does NOT delegate on the Harbour macro compiler to run commands:
 * measured in this build (see odd/tasks/dot-prompt.md, L3), `&( "USE X" )` and
 * `&( "SET ORDER TO 1" )` give "Syntax error"; only `&( <expression> )` compiles.
 * That is why each verb is parsed here and translated into Harbour functions
 * (dbUseArea, OrdSetFocus, dbSkip, ...); EXPRESSIONS are evaluated with `&()`.
 *
 * The module is self-contained: it only depends on bp_def.ch (colors/constants) and on the
 * paint helpers of bp_ui.prg. It does not call Core*()/Bp*(), so the headless
 * tests (tests/test_dot.prg) compile with:
 *     test_dot.prg bp_dot.prg bp_ui.prg
 *
 * The output goes to a buffer (s_aOut); on screen BpDotPrompt() paints it and in the
 * tests DotOutputLines() reads it. The confirmation of the destructive commands
 * goes through s_bConfirm, which the test replaces with DotSetConfirmHook().
 */
#include "inkey.ch"
#include "hbgtinfo.ch"
#include "dbinfo.ch"
#include "ord.ch"
#include "bp_def.ch"

#define DOT_MAX_OUT   500       /* output lines that are kept */
#define DOT_MAX_HIST  200       /* commands remembered (DOSKEY) */
#define DOT_ERR       "*** "
#define DOT_PROMPT    ". "

/* dot state */
STATIC s_aOut := {}             /* output buffer (already split into lines) */
STATIC s_nWidth := 78           /* splitting width of the output */
STATIC s_nScroll := 0           /* lines scrolled back in the output */
STATIC s_nVisible := 0         /* output lines that fit on screen */
STATIC s_aHist := {}            /* command history */
STATIC s_nHist := 0             /* 0 = the history is not being browsed */
STATIC s_cHistEdit := ""        /* half-typed line when entering the history */
STATIC s_cOpenMode := "EXCLUSIVE"
STATIC s_lQuit := .F.           /* the user asked to close hwBro (QUIT) */
STATIC s_lPainted := .F.        /* the current command already repainted (via DotOutput) */
STATIC s_bConfirm := NIL        /* {| cText | lYes } destructive confirmation */
STATIC s_bPaint := NIL          /* repaint of the dot screen */
STATIC s_cLocate := ""          /* last LOCATE condition (for CONTINUE) */
STATIC s_nInRow := 0            /* prompt row (to return the caret there) */
STATIC s_nInPos := 0            /* caret column inside the line */
STATIC s_nOutT := 0             /* first row of the output region */
STATIC s_nOutB := 0             /* last row of the output region */
STATIC s_nThumbT := 0           /* scroll bar: first row of the thumb */
STATIC s_nThumbB := 0           /* scroll bar: last row of the thumb */

/* ---------------------------------------------------------------- API ------ */

/* Runs one dot line. Returns .T. to continue and .F. to leave the dot. */
FUNCTION DotExec( cLine )
   LOCAL lOk := .T.
   IF ValType( cLine ) != "C"
      cLine := ""
   ENDIF
   cLine := AllTrim( cLine )
   IF Empty( cLine )
      RETURN .T.
   ENDIF
   DotHistAdd( cLine )
   s_nScroll := 0
   s_lPainted := .F.
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      lOk := DotDispatch( cLine )
   RECOVER USING oErr
      /* an uncaught error from the commands cannot bring down the dot */
      DotErr( oErr:Description )
      lOk := .T.
   END SEQUENCE
   /* The status bar has to reflect the REAL state of the area after
    * EVERY command: GO TOP/BOTTOM, SKIP and SET write no output, so without
    * this the Rec. (and the Ord) stayed frozen until the next command
    * that did print something. If the command already painted via DotOutput it is
    * not repainted again. */
   IF lOk .AND. ! s_lPainted .AND. s_bPaint != NIL
      Eval( s_bPaint )
   ENDIF
RETURN lOk

FUNCTION DotSetOpenMode( cMode )
   DEFAULT cMode TO "EXCLUSIVE"
   s_cOpenMode := iif( Upper( cMode ) == "SHARED", "SHARED", "EXCLUSIVE" )
RETURN NIL

FUNCTION DotOpenMode()
RETURN s_cOpenMode

FUNCTION DotSetQuitRequest( l )
   DEFAULT l TO .F.
   s_lQuit := l
RETURN NIL

FUNCTION DotQuitRequested()
RETURN s_lQuit

FUNCTION DotSetConfirmHook( b )
   s_bConfirm := b
RETURN NIL

FUNCTION DotSetPaintHook( b )
   s_bPaint := b
RETURN NIL

FUNCTION DotSetWidth( n )
   DEFAULT n TO 78
   s_nWidth := Max( 20, n )
RETURN NIL

/* Appends text to the output (respects line breaks and splits by words). */
FUNCTION DotOutput( cText )
   LOCAL aLin, i, aWrap, j
   IF ValType( cText ) != "C"
      cText := hb_ValToExp( cText )
   ENDIF
   cText := StrTran( cText, Chr( 13 ), "" )
   aLin := hb_ATokens( cText, Chr( 10 ) )
   IF Empty( aLin )
      aLin := { "" }
   ENDIF
   FOR i := 1 TO Len( aLin )
      aWrap := DotWrapLine( aLin[ i ] )
      FOR j := 1 TO Len( aWrap )
         AAdd( s_aOut, aWrap[ j ] )
      NEXT
   NEXT
   DO WHILE Len( s_aOut ) > DOT_MAX_OUT
      s_aOut := DotArrayTail( s_aOut, Len( s_aOut ) - DOT_MAX_OUT + 1 )
   ENDDO
   IF s_bPaint != NIL
      Eval( s_bPaint )
      s_lPainted := .T.
   ENDIF
RETURN NIL

FUNCTION DotClearOutput()
   s_aOut := {}
   s_nScroll := 0
   IF s_bPaint != NIL
      Eval( s_bPaint )
   ENDIF
RETURN NIL

FUNCTION DotOutputLines()
RETURN DotArrayCopy( s_aOut )

FUNCTION DotOutputScroll()
RETURN s_nScroll

/* Scrolls the output. nDelta > 0 goes BACK (older lines) and
 * nDelta < 0 towards the end. The limit takes into account the lines that fit in the
 * visible region, so when the output fits on screen nothing moves
 * (before, a 3-line output could be "scrolled" and the text jumped to the
 * bottom of the region, which looked like a bug). */
FUNCTION DotScroll( nDelta )
   LOCAL nVisible := iif( s_nVisible > 0, s_nVisible, 1 )
   LOCAL nMax := Max( 0, Len( s_aOut ) - nVisible )
   DEFAULT nDelta TO 0
   s_nScroll := Min( nMax, Max( 0, s_nScroll + nDelta ) )
   IF s_bPaint != NIL
      Eval( s_bPaint )
   ENDIF
RETURN s_nScroll

/* output lines that fit in the visible region (DotPaintScreen sets it; the
 * tests set it by hand with DotSetVisible() to check the limits) */
FUNCTION DotSetVisible( n )
   DEFAULT n TO 0
   s_nVisible := Max( 0, n )
RETURN NIL

/* -------------------------------------------------------------- history ---- */

/* NOTE: ACopy( a, {} ) copies NOTHING (it copies min(srcLen, dstLen)); so
 * every array copy of the dot goes through these two helpers. */
STATIC FUNCTION DotArrayCopy( a )
RETURN ACopy( a, Array( Len( a ) ) )

STATIC FUNCTION DotArrayTail( a, nFrom )
   LOCAL aNew := Array( Max( 0, Len( a ) - nFrom + 1 ) )
RETURN ACopy( a, aNew, nFrom )

FUNCTION DotHistory()
RETURN DotArrayCopy( s_aHist )

FUNCTION DotHistClear()
   s_aHist := {}
   s_nHist := 0
   s_cHistEdit := ""
RETURN NIL

/* only resets the browsing (the history is kept) */
FUNCTION DotHistReset()
   s_nHist := 0
   s_cHistEdit := ""
RETURN NIL

FUNCTION DotHistUp( cEdit )
   DEFAULT cEdit TO ""
   IF Empty( s_aHist )
      RETURN cEdit
   ENDIF
   IF s_nHist == 0
      s_cHistEdit := cEdit
      s_nHist := Len( s_aHist )
   ELSEIF s_nHist > 1
      s_nHist--
   ENDIF
RETURN s_aHist[ s_nHist ]

FUNCTION DotHistDown( cEdit )
   DEFAULT cEdit TO ""
   IF s_nHist == 0
      RETURN cEdit
   ENDIF
   IF s_nHist < Len( s_aHist )
      s_nHist++
      RETURN s_aHist[ s_nHist ]
   ENDIF
   s_nHist := 0
RETURN s_cHistEdit

STATIC PROCEDURE DotHistAdd( cLine )
   IF Empty( cLine )
      RETURN
   ENDIF
   IF ! Empty( s_aHist ) .AND. s_aHist[ Len( s_aHist ) ] == cLine
      RETURN
   ENDIF
   AAdd( s_aHist, cLine )
   DO WHILE Len( s_aHist ) > DOT_MAX_HIST
      ADel( s_aHist, 1 )
      ASize( s_aHist, Len( s_aHist ) - 1 )
   ENDDO
   s_nHist := 0
   s_cHistEdit := ""
RETURN

/* ----------------------------------------------------------- status bar ---- */

/* What the bottom bar of the dot paints: CURRENT area (Alias, Order, Rec., mode)
 * and, if more databases are open, in which areas they are. Without that the user sees
 * "Alias: ARTICULO" believing no database is selected, when in
 * fact it is open in ANOTHER work area: the bar says which one. */
FUNCTION DotStatusLine( nWidth )
   LOCAL cArea, cInfo, cMore := "", cOrder := "", nRec := 0, nTot := 0, aOther, cOther := ""
   DEFAULT nWidth TO 0
   cArea := "Area " + LTrim( Str( Select() ) )
   IF Used()
      cOrder := DotOrdName()
      BEGIN SEQUENCE WITH {| e | Break( e ) }
         nRec := RecNo()
         nTot := LastRec()
      RECOVER
         nRec := 0
      END SEQUENCE
      cInfo := "  Alias: " + Alias() + "  Ord: " + iif( Empty( cOrder ), "(none)", cOrder )
      cMore := "  Rec. " + LTrim( Str( nRec ) ) + "/" + LTrim( Str( nTot ) )
   ELSE
      cInfo := "  Alias: (none)  Ord: (none)"
   ENDIF
   aOther := DotOtherAreas( Select() )
   IF ! Empty( aOther )
      cOther := "  |  open: " + DotAreaList( aOther )
   ENDIF
   IF nWidth <= 0
      RETURN cArea + cInfo + cMore + cOther
   ENDIF
   /* Everything important has to fit in the bar: Alias and Order first, and
    * then the other open areas. If it does not fit, Rec./mode is sacrificed (it
    * is still in STATUS and AREAS) before cutting the area list in half. */
   IF Len( cArea + cInfo + cMore + cOther ) <= nWidth
      RETURN Left( cArea + cInfo + cMore + cOther, nWidth )
   ENDIF
   IF Len( cArea + cInfo + cOther ) <= nWidth
      RETURN Left( cArea + cInfo + cOther, nWidth )
   ENDIF
   cOther := iif( Empty( aOther ), "", "  |  +" + LTrim( Str( Len( aOther ) ) ) + " area(s)" )
RETURN Left( cArea + cInfo + cOther, nWidth )

/* open mode of the current area (or the setting, if there is no database). It goes
 * separately because the bar aligns it against the RIGHT edge. */
FUNCTION DotStatusMode()
RETURN iif( DotIsShared(), "Shared", "Excl" )

/* areas that are NOT the current one and have a database open: { { nArea, cAlias }, ... } */
STATIC FUNCTION DotOtherAreas( nSkip )
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
      IF Used() .AND. n != nSkip
         AAdd( a, { n, Alias() } )
      ENDIF
   NEXT
   SELECT ( nOld )
RETURN a

STATIC FUNCTION DotAreaList( a )
   LOCAL c := "", i
   FOR i := 1 TO Len( a )
      c += iif( i == 1, "", " " ) + LTrim( Str( a[ i ][ 1 ] ) ) + "=" + a[ i ][ 2 ]
   NEXT
RETURN c

/* OrdName() blows up if the area has no controlling order; not wanted here */
STATIC FUNCTION DotOrdName()
   LOCAL c := ""
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      c := OrdName()
   RECOVER
      c := ""
   END SEQUENCE
RETURN c

/* -------------------------------------------------------- formatting ----- */

/* Value of an expression as the dot shows it. */
FUNCTION DotShowValue( xVal )
   LOCAL cType := ValType( xVal )
   DO CASE
   CASE cType == "C" .OR. cType == "M"
      RETURN xVal
   CASE cType == "N"
      RETURN DotNumStr( xVal )
   CASE cType == "D"
      RETURN iif( Empty( xVal ), "  /  /  ", DToC( xVal ) )
   CASE cType == "L"
      RETURN iif( xVal, ".T.", ".F." )
   CASE cType == "U"
      RETURN "NIL"
   ENDCASE
RETURN hb_ValToExp( xVal )

STATIC FUNCTION DotNumStr( n )
   LOCAL c := LTrim( Str( n, 20, 10 ) )
   IF "." $ c
      DO WHILE Right( c, 1 ) == "0"
         c := Left( c, Len( c ) - 1 )
      ENDDO
      IF Right( c, 1 ) == "."
         c := Left( c, Len( c ) - 1 )
      ENDIF
   ENDIF
RETURN c

/* ------------------------------------------------------------ dispatch ----- */

STATIC FUNCTION DotDispatch( cLine )
   LOCAL cVerb, cRest, cFull := cLine

   /* ? and ??  (first of all: they are not identifiers) */
   IF Left( cLine, 1 ) == "?"
      IF Left( cLine, 2 ) == "??"
         RETURN DotEvalShow( SubStr( cLine, 3 ), .T. )
      ENDIF
      cRest := AllTrim( SubStr( cLine, 2 ) )
      IF Empty( cRest )
         DotShowHelp()
         RETURN .T.
      ENDIF
      RETURN DotEvalShow( cRest, .F. )
   ENDIF

   /* !<command> = shell out, as in dBASE */
   IF Left( cLine, 1 ) == "!"
      DotCmdRun( SubStr( cLine, 2 ) )
      RETURN .T.
   ENDIF

   cVerb := DotNextWord( @cLine )
   cRest := AllTrim( cLine )
   cVerb := Upper( cVerb )

   DO CASE
   CASE cVerb == "EXIT" .OR. cVerb == "ESC" .OR. cVerb == "CANCEL"
      RETURN .F.
   CASE cVerb == "QUIT"
      IF DotConfirm( "Exit hwBro?" )
         s_lQuit := .T.
         RETURN .F.
      ENDIF
   CASE cVerb == "CLEAR" .OR. cVerb == "CLS"
      IF Upper( cRest ) == "HISTORY"
         DotHistClear()
         DotOutput( "Command history cleared." )
      ELSE
         DotClearOutput()
      ENDIF
   CASE cVerb == "HELP"
      DotShowHelp()
   CASE cVerb == "HISTORY"
      DotShowHistory()
   CASE cVerb == "SELECT"
      DotCmdSelect( cRest )
   CASE cVerb == "USE"
      DotCmdUse( cRest )
   CASE cVerb == "CLOSE"
      DotCmdClose( cRest )
   CASE cVerb == "SET"
      DotCmdSet( cRest )
   CASE cVerb == "GO" .OR. cVerb == "GOTO"
      DotCmdGo( cRest )
   CASE cVerb == "SKIP"
      DotCmdSkip( cRest )
   CASE cVerb == "SEEK" .OR. cVerb == "FIND"
      DotCmdSeek( cRest, cVerb == "FIND" )
   CASE cVerb == "LOCATE"
      DotCmdLocate( cRest )
   CASE cVerb == "CONTINUE"
      DotCmdContinue()
   CASE cVerb == "COUNT"
      DotCmdCount( cRest )
   CASE cVerb == "SUM"
      DotCmdSum( cRest, .F. )
   CASE cVerb == "AVERAGE"
      DotCmdSum( cRest, .T. )
   CASE cVerb == "REPLACE"
      DotCmdReplace( cRest )
   CASE cVerb == "DELETE"
      DotCmdDelete( cRest, .F. )
   CASE cVerb == "RECALL"
      DotCmdDelete( cRest, .T. )
   CASE cVerb == "APPEND"
      DotCmdAppend( cRest )
   CASE cVerb == "PACK"
      DotCmdPack()
   CASE cVerb == "ZAP"
      DotCmdZap()
   CASE cVerb == "REINDEX"
      DotCmdReindex()
   CASE cVerb == "INDEX"
      DotCmdIndex( cRest )
   CASE cVerb == "LIST"
      DotCmdList( cRest, .F. )
   CASE cVerb == "DISPLAY"
      DotCmdList( cRest, .T. )
   CASE cVerb == "RUN"
      DotCmdRun( cRest )
   CASE cVerb == "STATUS"
      DotOutput( DotStatusLine() + "  " + DotStatusMode() )
   CASE cVerb == "AREAS" .OR. cVerb == "WORKAREAS"
      DotCmdAreas()
   OTHERWISE
      /* not a known verb: it may be a standalone expression (S3) */
      IF ! DotEvalBare( cFull )
         DotErr( "Unknown command or expression: " + Upper( DotFirstWord( cFull ) ) )
      ENDIF
   ENDCASE
RETURN .T.

/* ---------------------------------------------------- expression evaluation */

/* ? <list> / ?? <list>: evaluates each comma-separated expression. */
STATIC FUNCTION DotEvalShow( cList, lAppend )
   LOCAL aPart, i, aRes, cOut := ""
   aPart := DotSplitTop( cList )
   IF Empty( aPart )
      DotLine( "", lAppend )
      RETURN .T.
   ENDIF
   FOR i := 1 TO Len( aPart )
      aRes := DotEvalRaw( aPart[ i ] )
      IF ! aRes[ 1 ]
         DotErr( aRes[ 3 ] )
         RETURN .T.
      ENDIF
      cOut += iif( i == 1, "", " " ) + DotShowValue( aRes[ 2 ] )
   NEXT
   DotLine( cOut, lAppend )
RETURN .T.

/* bare line: if it can be evaluated it is shown; otherwise the output is untouched */
STATIC FUNCTION DotEvalBare( cLine )
   LOCAL aRes := DotEvalRaw( cLine )
   IF ! aRes[ 1 ]
      RETURN .F.
   ENDIF
   DotOutput( DotShowValue( aRes[ 2 ] ) )
RETURN .T.

/* { lOk, xValue, cError } */
STATIC FUNCTION DotEvalRaw( cExpr )
   LOCAL xVal, cErr := ""
   cExpr := AllTrim( cExpr )
   IF Empty( cExpr )
      RETURN { .F., NIL, "Empty expression" }
   ENDIF
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      xVal := &( "(" + cExpr + ")" )
   RECOVER USING oErr
      cErr := oErr:Description
   END SEQUENCE
RETURN { Empty( cErr ), xVal, cErr }

/* condition of a FOR: .T./.F.; an error is reported and treated as .F. */
STATIC FUNCTION DotCond( cCond )
   LOCAL aRes := DotEvalRaw( cCond )
   IF ! aRes[ 1 ]
      DotErr( aRes[ 3 ] )
      RETURN .F.
   ENDIF
RETURN ! Empty( aRes[ 2 ] )

/* ------------------------------------------------------------- commands ---- */

STATIC PROCEDURE DotCmdSelect( cRest )
   LOCAL c := AllTrim( cRest ), n, lOk := .T.
   IF Empty( c )
      DotOutput( DotStatusLine() )
      RETURN
   ENDIF
   IF DotIsNumber( c )
      n := Int( Val( c ) )
      IF n == 0
         n := DotFreeArea()
         IF n == 0
            DotErr( "No free work areas." )
            RETURN
         ENDIF
      ENDIF
      IF n < 1 .OR. n > 64
         DotErr( "Work area must be in the range 1-64." )
         RETURN
      ENDIF
      BEGIN SEQUENCE WITH {| e | Break( e ) }
         SELECT ( n )
      RECOVER
         lOk := .F.
      END SEQUENCE
      IF ! lOk
         DotErr( "Cannot select work area " + LTrim( Str( n ) ) + "." )
         RETURN
      ENDIF
   ELSE
      BEGIN SEQUENCE WITH {| e | Break( e ) }
         dbSelectArea( c )
      RECOVER
         lOk := .F.
      END SEQUENCE
      IF ! lOk
         DotErr( "Alias not in use: " + c )
         RETURN
      ENDIF
   ENDIF
   IF Used()
      DotOutput( "Area " + LTrim( Str( Select() ) ) + ": " + Alias() )
   ELSE
      DotOutput( "Area " + LTrim( Str( Select() ) ) + ": (no database open)" )
   ENDIF
RETURN

STATIC PROCEDURE DotCmdUse( cRest )
   LOCAL aTok := DotTokens( cRest ), i, cTok, cFile := "", cAlias := "", cIndex := ""
   LOCAL lShared := ( s_cOpenMode == "SHARED" ), lNew := .F., lAgain := .F., nIn := 0
   LOCAL nArea, lOk := .F., cErr := "", aIdx, cBase

   IF Empty( aTok )
      /* USE with no arguments: close the current area (dBASE) */
      IF Used()
         cFile := Alias()
         CLOSE
         DotOutput( "Database closed: " + cFile )
      ELSE
         DotOutput( "No database is in use." )
      ENDIF
      RETURN
   ENDIF

   i := 1
   DO WHILE i <= Len( aTok )
      cTok := Upper( aTok[ i ] )
      DO CASE
      CASE cTok == "ALIAS"
         IF i < Len( aTok )
            i++
            cAlias := DotUnquote( aTok[ i ] )
         ENDIF
      CASE cTok == "INDEX"
         DO WHILE i < Len( aTok ) .AND. ! DotIsUseKeyword( Upper( aTok[ i + 1 ] ) )
            i++
            cIndex += iif( Empty( cIndex ), "", "," ) + DotUnquote( aTok[ i ] )
         ENDDO
      CASE cTok == "EXCLUSIVE"
         lShared := .F.
      CASE cTok == "SHARED"
         lShared := .T.
      CASE cTok == "NEW"
         lNew := .T.
      CASE cTok == "AGAIN"
         lAgain := .T.
      CASE cTok == "IN"
         IF i < Len( aTok )
            i++
            nIn := Int( Val( aTok[ i ] ) )
         ENDIF
      CASE cTok == "VIA"
         IF i < Len( aTok )
            i++
         ENDIF
      OTHERWISE
         IF Empty( cFile )
            cFile := DotUnquote( aTok[ i ] )
         ENDIF
      ENDCASE
      i++
   ENDDO

   IF Empty( cFile )
      DotErr( "USE: missing database file name." )
      RETURN
   ENDIF
   cFile := DotResolveDbf( cFile )
   IF ! File( cFile )
      DotErr( "File not found: " + cFile )
      RETURN
   ENDIF
   cBase := DotBaseName( cFile )
   IF Empty( cAlias )
      cAlias := cBase
   ENDIF
   /* target area: IN <n>, or a free one with NEW, or the current one */
   IF nIn > 0
      nArea := nIn
   ELSEIF lNew
      nArea := DotFreeArea()
      IF nArea == 0
         DotErr( "No free work areas." )
         RETURN
      ENDIF
   ELSE
      nArea := Select()
   ENDIF
   IF nArea < 1 .OR. nArea > 64
      DotErr( "Work area must be in the range 1-64." )
      RETURN
   ENDIF

   /* the alias cannot already be in use in ANOTHER area (same trap as in
    * BpAreaByFile(): it is compared with Alias(), not with the file name) */
   IF DotAliasArea( cAlias ) != 0 .AND. DotAliasArea( cAlias ) != nArea
      DotErr( "Alias already in use: " + cAlias + " (use SELECT " + ;
              LTrim( Str( DotAliasArea( cAlias ) ) ) + ", ALIAS or NEW)" )
      RETURN
   ENDIF

   BEGIN SEQUENCE WITH {| e | Break( e ) }
      SELECT ( nArea )
      IF Used()
         /* USE replaces whatever was in the area */
         CLOSE
      ENDIF
#ifndef BP_DOT_STANDALONE
      StructRememberDbfLang( cFile )
#endif
      dbUseArea( .F., NIL, cFile, cAlias, lShared )
      lOk := .T.
   RECOVER USING oErr
      cErr := oErr:Description
   END SEQUENCE

   IF ! lOk
      DotErr( "Cannot open " + cFile + iif( Empty( cErr ), "", ": " + cErr ) )
      RETURN
   ENDIF

   /* indexes: the order bag is named after the FILE, without extension */
   IF ! Empty( cIndex )
      aIdx := hb_ATokens( cIndex, "," )
      FOR i := 1 TO Len( aIdx )
         IF ! Empty( AllTrim( aIdx[ i ] ) )
            OrdListAdd( DotBagName( DotUnquote( aIdx[ i ] ) ) )
         ENDIF
      NEXT
   ENDIF

   DotOutput( "Area " + LTrim( Str( Select() ) ) + ": " + Alias() + "  (" + ;
              DotBaseName( cFile ) + ", " + iif( lShared, "Shared", "Exclusive" ) + ;
              iif( lAgain, ", again", "" ) + ")" )
RETURN

STATIC PROCEDURE DotCmdClose( cRest )
   LOCAL c := Upper( AllTrim( cRest ) )
   DO CASE
   CASE Empty( c ) .OR. c == "DATABASES" .OR. c == "TABLES"
      CLOSE DATABASES
      DotOutput( "All databases closed." )
   CASE c == "ALL"
      CLOSE ALL
      DotOutput( "All databases closed." )
   CASE c == "INDEXES" .OR. c == "INDEX"
      IF ! DotNeedDb()
         RETURN
      ENDIF
      /* NOTE: with DBFCDX the .CDX cannot be detached without closing the database (see
       * AGENTS.md trap 31); this leaves the area in natural order. */
      OrdListClear()
      DotOutput( "Index order released (natural order)." )
   OTHERWISE
      DotErr( "CLOSE: unknown option " + c + "." )
   ENDCASE
RETURN

STATIC PROCEDURE DotCmdSet( cRest )
   LOCAL cWhat, cVal, n, c
   IF Empty( AllTrim( cRest ) )
      DotOutput( "EXACT: " + DotOnOff( Set( _SET_EXACT ) ) + ;
                 "   DELETED: " + DotOnOff( Set( _SET_DELETED ) ) + ;
                 "   SOFTSEEK: " + DotOnOff( Set( _SET_SOFTSEEK ) ) )
      DotOutput( "CENTURY: " + DotOnOff( Set( _SET_CENTURY ) ) + ;
                 "   DECIMALS: " + LTrim( Str( Set( _SET_DECIMALS ) ) ) + ;
                 "   DATE: " + Set( _SET_DATEFORMAT ) )
      RETURN
   ENDIF
   cWhat := Upper( DotNextWord( @cRest ) )
   cVal := AllTrim( cRest )
   /* both "SET ORDER TO x" and "SET ORDER x" are accepted */
   IF Upper( Left( cVal, 3 ) ) == "TO "
      cVal := AllTrim( SubStr( cVal, 4 ) )
   ENDIF

   DO CASE
   CASE cWhat == "ORDER"
      IF ! DotNeedDb()
         RETURN
      ENDIF
      c := ""
      BEGIN SEQUENCE WITH {| e | Break( e ) }
         IF Empty( cVal ) .OR. Val( cVal ) == 0 .AND. DotIsNumber( cVal )
            OrdSetFocus( 0 )
         ELSEIF DotIsNumber( cVal )
            OrdSetFocus( Int( Val( cVal ) ) )
         ELSE
            OrdSetFocus( Upper( DotUnquote( cVal ) ) )
         ENDIF
         c := OrdName()
      RECOVER
         DotErr( "Order not found: " + cVal )
         RETURN
      END SEQUENCE
      DotOutput( "Order: " + iif( Empty( c ), "(none)", c ) )
   CASE cWhat == "INDEX"
      IF ! DotNeedDb()
         RETURN
      ENDIF
      IF Empty( cVal )
         OrdListClear()
         DotOutput( "Index order released (natural order)." )
      ELSE
         BEGIN SEQUENCE WITH {| e | Break( e ) }
            OrdListAdd( DotBagName( DotUnquote( cVal ) ) )
            n := dbOrderInfo( DBOI_ORDERCOUNT )
         RECOVER
            DotErr( "Cannot open index " + cVal + "." )
            RETURN
         END SEQUENCE
         DotOutput( LTrim( Str( n ) ) + " tag(s) available." )
      ENDIF
   CASE cWhat == "FILTER"
      IF ! DotNeedDb()
         RETURN
      ENDIF
      IF Empty( cVal )
         dbClearFilter()
         DotOutput( "Filter cleared." )
      ELSE
         BEGIN SEQUENCE WITH {| e | Break( e ) }
            dbSetFilter( &( "{|| " + cVal + " }" ), cVal )
         RECOVER USING oErr
            DotErr( "Invalid filter: " + oErr:Description )
            RETURN
         END SEQUENCE
         DotOutput( "Filter: " + cVal )
      ENDIF
   CASE cWhat == "RELATION"
      IF ! DotNeedDb()
         RETURN
      ENDIF
      IF Empty( cVal )
         dbClearRelation()
         DotOutput( "Relations cleared." )
      ELSE
         DotErr( "SET RELATION: use the Field menu in hwBro." )
      ENDIF
   CASE cWhat == "EXACT"
      Set( _SET_EXACT, DotToBool( cVal ) )
      DotOutput( "EXACT: " + DotOnOff( Set( _SET_EXACT ) ) )
   CASE cWhat == "UNIQUE"
      Set( _SET_UNIQUE, DotToBool( cVal ) )
      DotOutput( "UNIQUE: " + DotOnOff( Set( _SET_UNIQUE ) ) )
   CASE cWhat == "DELETED"
      Set( _SET_DELETED, DotToBool( cVal ) )
      DotOutput( "DELETED: " + DotOnOff( Set( _SET_DELETED ) ) )
   CASE cWhat == "SOFTSEEK"
      Set( _SET_SOFTSEEK, DotToBool( cVal ) )
      DotOutput( "SOFTSEEK: " + DotOnOff( Set( _SET_SOFTSEEK ) ) )
   CASE cWhat == "CENTURY"
      Set( _SET_CENTURY, DotToBool( cVal ) )
      DotOutput( "CENTURY: " + DotOnOff( Set( _SET_CENTURY ) ) )
   CASE cWhat == "CONFIRM"
      Set( _SET_CONFIRM, DotToBool( cVal ) )
      DotOutput( "CONFIRM: " + DotOnOff( Set( _SET_CONFIRM ) ) )
   CASE cWhat == "BELL"
      Set( _SET_BELL, DotToBool( cVal ) )
      DotOutput( "BELL: " + DotOnOff( Set( _SET_BELL ) ) )
   CASE cWhat == "DECIMALS"
      Set( _SET_DECIMALS, Int( Val( cVal ) ) )
      DotOutput( "DECIMALS: " + LTrim( Str( Set( _SET_DECIMALS ) ) ) )
   CASE cWhat == "DATE"
      IF Upper( Left( cVal, 6 ) ) == "FORMAT"
         cVal := AllTrim( SubStr( cVal, 7 ) )
      ENDIF
      Set( _SET_DATEFORMAT, cVal )
      DotOutput( "DATE: " + Set( _SET_DATEFORMAT ) )
   CASE cWhat == "DEFAULT"
      Set( _SET_DEFAULT, cVal )
      DotOutput( "DEFAULT: " + CurDir() )
   CASE cWhat == "OPEN"
      DotOutput( "Open Mode is the F2 menu setting: " + s_cOpenMode )
   OTHERWISE
      DotErr( "SET: not supported from the dot prompt: " + cWhat )
   ENDCASE
RETURN

STATIC PROCEDURE DotCmdGo( cRest )
   LOCAL c := Upper( AllTrim( cRest ) ), lOk := .T.
   IF ! DotNeedDb()
      RETURN
   ENDIF
   DO CASE
   CASE Empty( c ) .OR. c == "TOP"
      dbGoTop()
   CASE c == "BOTTOM"
      dbGoBottom()
   CASE DotIsNumber( AllTrim( cRest ) )
      lOk := dbGoto( Int( Val( cRest ) ) )
      IF ! lOk
         DotErr( "Record out of range: " + AllTrim( cRest ) )
      ENDIF
   OTHERWISE
      DotErr( "GO: expected TOP, BOTTOM or a record number." )
   ENDCASE
RETURN

STATIC PROCEDURE DotCmdSkip( cRest )
   LOCAL n := 1
   IF ! DotNeedDb()
      RETURN
   ENDIF
   IF ! Empty( AllTrim( cRest ) )
      IF ! DotIsNumber( AllTrim( cRest ) )
         DotErr( "SKIP: expected a number." )
         RETURN
      ENDIF
      n := Int( Val( cRest ) )
   ENDIF
   dbSkip( n )
   IF Eof()
      DotOutput( "End of file." )
   ELSEIF Bof()
      DotOutput( "Beginning of file." )
   ENDIF
RETURN

STATIC PROCEDURE DotCmdSeek( cRest, lFind )
   LOCAL aRes, lFound, cWhat
   IF ! DotNeedDb()
      RETURN
   ENDIF
   IF Empty( AllTrim( cRest ) )
      DotErr( iif( lFind, "FIND", "SEEK" ) + ": missing search value." )
      RETURN
   ENDIF
   IF lFind
      /* FIND takes the text as it is (as in dBASE) */
      cWhat := DotUnquote( AllTrim( cRest ) )
      lFound := dbSeek( cWhat, Set( _SET_SOFTSEEK ) )
      DotOutput( iif( lFound, "Found " + cWhat + " -> Rec. " + ;
                 LTrim( Str( RecNo() ) ), "Not found: " + cWhat ) )
      RETURN
   ENDIF
   aRes := DotEvalRaw( cRest )
   IF ! aRes[ 1 ]
      DotErr( aRes[ 3 ] )
      RETURN
   ENDIF
   lFound := dbSeek( aRes[ 2 ], Set( _SET_SOFTSEEK ) )
   DotOutput( iif( lFound, "Found " + DotShowValue( aRes[ 2 ] ) + " -> Rec. " + ;
              LTrim( Str( RecNo() ) ), "Not found: " + DotShowValue( aRes[ 2 ] ) ) )
RETURN

STATIC PROCEDURE DotCmdLocate( cRest )
   LOCAL aHead, cFor, nStart, lFound := .F.
   IF ! DotNeedDb()
      RETURN
   ENDIF
   aHead := AllTrim( cRest )
   IF Upper( Left( aHead, 3 ) ) == "FOR"
      aHead := AllTrim( SubStr( aHead, 4 ) )
   ENDIF
   IF Empty( aHead )
      DotErr( "LOCATE: missing condition (LOCATE FOR <condition>)." )
      RETURN
   ENDIF
   cFor := aHead
   s_cLocate := cFor
   nStart := RecNo()
   dbGoTop()
   DO WHILE ! Eof()
      IF DotCond( cFor )
         lFound := .T.
         EXIT
      ENDIF
      dbSkip()
   ENDDO
   IF lFound
      DotOutput( "Found -> Rec. " + LTrim( Str( RecNo() ) ) )
   ELSE
      dbGoto( nStart )
      DotOutput( "No record matched the condition." )
   ENDIF
RETURN

STATIC PROCEDURE DotCmdContinue()
   LOCAL lFound := .F.
   IF ! DotNeedDb()
      RETURN
   ENDIF
   IF Empty( s_cLocate )
      DotErr( "CONTINUE: no previous LOCATE." )
      RETURN
   ENDIF
   dbSkip()
   DO WHILE ! Eof()
      IF DotCond( s_cLocate )
         lFound := .T.
         EXIT
      ENDIF
      dbSkip()
   ENDDO
   DotOutput( iif( lFound, "Found -> Rec. " + LTrim( Str( RecNo() ) ), ;
              "No more records matched." ) )
RETURN

STATIC PROCEDURE DotCmdCount( cRest )
   LOCAL aHead := DotSplitFor( cRest ), cFor := aHead[ 2 ], n := 0, nStart
   IF ! DotNeedDb()
      RETURN
   ENDIF
   nStart := RecNo()
   dbGoTop()
   DO WHILE ! Eof()
      IF Empty( cFor ) .OR. DotCond( cFor )
         n++
      ENDIF
      dbSkip()
   ENDDO
   dbGoto( nStart )
   DotOutput( LTrim( Str( n ) ) + " record(s)" + iif( Empty( cFor ), "", " matching " + cFor ) )
RETURN

STATIC PROCEDURE DotCmdSum( cRest, lAvg )
   LOCAL aHead := DotSplitFor( cRest ), cFor := aHead[ 2 ], cExpr := AllTrim( aHead[ 1 ] )
   LOCAL xSum := 0, n := 0, nStart, aRes
   IF ! DotNeedDb()
      RETURN
   ENDIF
   IF Empty( cExpr )
      DotErr( iif( lAvg, "AVERAGE", "SUM" ) + ": missing expression." )
      RETURN
   ENDIF
   nStart := RecNo()
   dbGoTop()
   DO WHILE ! Eof()
      IF Empty( cFor ) .OR. DotCond( cFor )
         aRes := DotEvalRaw( cExpr )
         IF ! aRes[ 1 ]
            DotErr( aRes[ 3 ] )
            dbGoto( nStart )
            RETURN
         ENDIF
         xSum += aRes[ 2 ]
         n++
      ENDIF
      dbSkip()
   ENDDO
   dbGoto( nStart )
   DotOutput( iif( lAvg, "Average: ", "Sum: " ) + ;
              DotShowValue( iif( lAvg, iif( n == 0, 0, xSum / n ), xSum ) ) + ;
              "  (" + LTrim( Str( n ) ) + " record(s))" )
RETURN

STATIC PROCEDURE DotCmdReplace( cRest )
   LOCAL aHead := DotSplitFor( cRest ), cFor := aHead[ 2 ], aPair, i, n
   LOCAL aFld := {}, aExp := {}, nStart, nDone := 0
   IF ! DotNeedDb()
      RETURN
   ENDIF
   aPair := DotSplitTop( aHead[ 1 ] )
   IF Empty( aPair )
      DotErr( "REPLACE: expected <field> WITH <expression>." )
      RETURN
   ENDIF
   /* EVERYTHING is validated first and then written: a misspelled field cannot
    * leave half the list applied */
   FOR i := 1 TO Len( aPair )
      n := DotFindTop( aPair[ i ], "WITH" )
      IF n == 0
         DotErr( "REPLACE: expected WITH in: " + aPair[ i ] )
         RETURN
      ENDIF
      AAdd( aFld, AllTrim( Left( aPair[ i ], n - 1 ) ) )
      AAdd( aExp, AllTrim( SubStr( aPair[ i ], n + 4 ) ) )
      IF FieldPos( aFld[ i ] ) == 0
         DotErr( "Field not found: " + Upper( aFld[ i ] ) )
         RETURN
      ENDIF
   NEXT
   nStart := RecNo()
   IF ! Empty( cFor )
      dbGoTop()
   ENDIF
   DO WHILE ! Eof()
      IF Empty( cFor ) .OR. DotCond( cFor )
         IF ! DotWritePairs( aFld, aExp )
            dbGoto( nStart )
            RETURN
         ENDIF
         nDone++
      ENDIF
      IF Empty( cFor )
         EXIT
      ENDIF
      dbSkip()
   ENDDO
   dbGoto( nStart )
   DotOutput( LTrim( Str( nDone ) ) + " record(s) replaced" )
RETURN

STATIC PROCEDURE DotCmdDelete( cRest, lRecall )
   LOCAL c := Upper( AllTrim( cRest ) ), aHead, cFor, n, nDone := 0, nStart
   IF ! DotNeedDb()
      RETURN
   ENDIF
   IF c == "RECORD" .OR. Upper( Left( c, 7 ) ) == "RECORD "
      n := Int( Val( SubStr( c, 7 ) ) )
      IF n < 1 .OR. ! dbGoto( n )
         DotErr( "Record out of range: " + LTrim( Str( n ) ) )
         RETURN
      ENDIF
      IF DotMarkRecord( lRecall )
         DotOutput( iif( lRecall, "Record recalled.", "Record deleted." ) )
      ENDIF
      RETURN
   ENDIF
   aHead := DotSplitFor( AllTrim( cRest ) )
   cFor := aHead[ 2 ]
   IF Empty( cFor ) .AND. Empty( AllTrim( aHead[ 1 ] ) )
      /* DELETE / RECALL with no arguments: only the current record */
      IF DotMarkRecord( lRecall )
         DotOutput( iif( lRecall, "Record recalled.", "Record deleted." ) )
      ENDIF
      RETURN
   ENDIF
   IF ! Empty( cFor )
      /* massive delete: always confirmed */
      IF ! DotConfirm( iif( lRecall, "Recall all records matching: ", ;
                        "Delete all records matching: " ) + cFor + "?" )
         DotOutput( "Cancelled." )
         RETURN
      ENDIF
   ELSE
      IF Upper( AllTrim( aHead[ 1 ] ) ) != "ALL"
         DotErr( "DELETE|RECALL: expected ALL, RECORD <n> or FOR <cond>." )
         RETURN
      ENDIF
      IF ! DotConfirm( iif( lRecall, "Recall ALL records?", "Delete ALL records?" ) )
         DotOutput( "Cancelled." )
         RETURN
      ENDIF
   ENDIF
   nStart := RecNo()
   dbGoTop()
   DO WHILE ! Eof()
      IF Empty( cFor ) .OR. DotCond( cFor )
         IF DotMarkRecord( lRecall )
            nDone++
         ENDIF
      ENDIF
      dbSkip()
   ENDDO
   dbGoto( nStart )
   DotOutput( LTrim( Str( nDone ) ) + " record(s) " + ;
              iif( lRecall, "recalled.", "deleted." ) )
RETURN

/* Marks/recalls the current record. NOTE: in SHARED the record MUST be
 * locked (dbRLock) before writing, just like CoreDeleteRecall(); without the
 * lock dbDelete() fails with *record is not locked* and the dot would delete
 * nothing in SHARED. Returns .T. if the mark was made. */
STATIC FUNCTION DotMarkRecord( lRecall )
   LOCAL lOk := .F., cErr := ""
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      dbRLock()
      IF lRecall
         dbRecall()
      ELSE
         dbDelete()
      ENDIF
      dbCommit()
      dbRUnlock()
      lOk := .T.
   RECOVER USING oErr
      cErr := oErr:Description
   END SEQUENCE
   IF ! lOk
      DotErr( "Cannot " + iif( lRecall, "recall", "delete" ) + " the record: " + cErr )
   ENDIF
RETURN lOk

/* REPLACE of one record: ALL expressions are evaluated before locking and
 * writing, and the write is locked (SHARED) and in a single commit so
 * that no half-applied REPLACE is left. */
STATIC FUNCTION DotWritePairs( aFld, aExp )
   LOCAL i, aRes, lOk := .F., cErr := ""
   LOCAL aVal := {}
   FOR i := 1 TO Len( aFld )
      aRes := DotEvalRaw( aExp[ i ] )
      IF ! aRes[ 1 ]
         DotErr( aRes[ 3 ] )
         RETURN .F.
      ENDIF
      AAdd( aVal, aRes[ 2 ] )
   NEXT
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      dbRLock()
      FOR i := 1 TO Len( aFld )
         FieldPut( FieldPos( aFld[ i ] ), aVal[ i ] )
      NEXT
      dbCommit()
      dbRUnlock()
      lOk := .T.
   RECOVER USING oErr
      cErr := oErr:Description
   END SEQUENCE
   IF ! lOk
      DotErr( "Cannot replace: " + cErr )
   ENDIF
RETURN lOk

STATIC PROCEDURE DotCmdAppend( cRest )
   LOCAL c := Upper( AllTrim( cRest ) ), n
   IF ! DotNeedDb()
      RETURN
   ENDIF
   IF c == "BLANK" .OR. Empty( c )
      dbAppend()
      DotOutput( "New record: " + LTrim( Str( RecNo() ) ) )
   ELSEIF c == "FROM"
      DotErr( "APPEND FROM: use the F8 menu (Append From)." )
   ELSE
      DotErr( "APPEND: only APPEND BLANK is supported." )
   ENDIF
RETURN

STATIC PROCEDURE DotCmdPack()
   IF ! DotNeedDb()
      RETURN
   ENDIF
   IF DotIsShared()
      DotErr( "Exclusive use is required for PACK." )
      RETURN
   ENDIF
   IF ! DotConfirm( "Pack " + Alias() + "? (deleted records will be lost)" )
      DotOutput( "Cancelled." )
      RETURN
   ENDIF
   PACK
   DotOutput( "Pack done: " + LTrim( Str( LastRec() ) ) + " record(s)." )
RETURN

STATIC PROCEDURE DotCmdZap()
   IF ! DotNeedDb()
      RETURN
   ENDIF
   IF DotIsShared()
      DotErr( "Exclusive use is required for ZAP." )
      RETURN
   ENDIF
   IF ! DotConfirm( "Zap " + Alias() + "? (ALL records will be lost)" )
      DotOutput( "Cancelled." )
      RETURN
   ENDIF
   ZAP
   DotOutput( "Zap done: database is empty." )
RETURN

STATIC PROCEDURE DotCmdReindex()
   LOCAL n := 0
   IF ! DotNeedDb()
      RETURN
   ENDIF
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      n := dbOrderInfo( DBOI_ORDERCOUNT )
   RECOVER
      n := 0
   END SEQUENCE
   IF n == 0
      DotOutput( "No index file is in use." )
      RETURN
   ENDIF
   dbReindex()
   DotOutput( LTrim( Str( n ) ) + " tag(s) reindexed." )
RETURN

STATIC PROCEDURE DotCmdIndex( cRest )
   LOCAL aHead := DotSplitFor( cRest ), cKey, cRight, aTok, i, cBag := "", cTag := ""
   LOCAL lUnique := .F., lDesc := .F., cFor := aHead[ 2 ], n, lOk := .F., cErr := ""
   LOCAL bKey := NIL
   IF ! DotNeedDb()
      RETURN
   ENDIF
   IF DotIsShared()
      DotErr( "Exclusive use is required to create an index." )
      RETURN
   ENDIF
   n := DotFindTop( aHead[ 1 ], "ON" )
   IF n == 0
      DotErr( "INDEX: expected INDEX ON <key> TO <file> [TAG <tag>]." )
      RETURN
   ENDIF
   cKey := AllTrim( SubStr( aHead[ 1 ], n + 2 ) )
   n := DotFindTop( cKey, "TO" )
   IF n == 0 .OR. Empty( cKey )
      DotErr( "INDEX: expected INDEX ON <key> TO <file>." )
      RETURN
   ENDIF
   cRight := AllTrim( SubStr( cKey, n + 2 ) )
   cKey := AllTrim( Left( cKey, n - 1 ) )
   aTok := DotTokens( cRight )
   IF ! Empty( aTok )
      cBag := DotUnquote( aTok[ 1 ] )
   ENDIF
   i := 2
   DO WHILE i <= Len( aTok )
      IF Upper( aTok[ i ] ) == "TAG" .AND. i < Len( aTok )
         i++
         cTag := DotUnquote( aTok[ i ] )
      ELSEIF Upper( aTok[ i ] ) == "UNIQUE"
         lUnique := .T.
      ELSEIF Upper( aTok[ i ] ) == "DESCENDING"
         lDesc := .T.
      ENDIF
      i++
   ENDDO
   IF Empty( cBag )
      DotErr( "INDEX: missing index file name." )
      RETURN
   ENDIF
   cBag := DotBagName( cBag )
   IF Empty( cTag )
      cTag := DotBaseName( cBag )
   ENDIF
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      IF ! Empty( cFor )
         OrdCondSet( cFor, &( "{|| " + cFor + " }" ) )
      ENDIF
      bKey := &( "{|| " + cKey + " }" )
      /* NOTE (AGENTS.md trap 32): the engine compiles the key TEXT and
       * discards the block; UNIQUE goes in the 5th parameter and DESCEND is applied
       * afterwards with DBOI_ISDESC. */
      OrdCreate( cBag, Upper( cTag ), cKey, bKey, lUnique )
      IF lDesc
         dbOrderInfo( DBOI_ISDESC, , Upper( cTag ), .T. )
      ENDIF
      lOk := .T.
   RECOVER USING oErr
      cErr := oErr:Description
   END SEQUENCE
   IF ! lOk
      DotErr( "Cannot create index: " + cErr )
      RETURN
   ENDIF
   DotOutput( "Tag " + Upper( cTag ) + " created in " + cBag + "." )
RETURN

STATIC PROCEDURE DotCmdList( cRest, lDisp )
   LOCAL aHead := DotSplitFor( cRest ), cFor := aHead[ 2 ], aExpr := {}, i
   LOCAL cLine, nRec := 0, nStart, aRes, lEsc := .F., nKey
   IF ! DotNeedDb()
      RETURN
   ENDIF
   IF Empty( AllTrim( aHead[ 1 ] ) )
      FOR i := 1 TO FCount()
         AAdd( aExpr, FieldName( i ) )
      NEXT
   ELSE
      aExpr := DotSplitTop( aHead[ 1 ] )
   ENDIF
   nStart := RecNo()
   IF ! lDisp
      dbGoTop()
   ENDIF
   DO WHILE ! Eof()
      IF Empty( cFor ) .OR. DotCond( cFor )
         cLine := LTrim( Str( RecNo() ) ) + ":"
         FOR i := 1 TO Len( aExpr )
            aRes := DotEvalRaw( aExpr[ i ] )
            cLine += " " + iif( aRes[ 1 ], DotShowValue( aRes[ 2 ] ), "?" )
         NEXT
         DotOutput( cLine )
         nRec++
         IF lDisp
            EXIT
         ENDIF
      ENDIF
      dbSkip()
      /* <Esc> cancels the list, but ANY other key is pushed back to the queue:
       * before, `IF Inkey() == K_ESC` ate the key and that is why it was impossible to
       * scroll (or recall from the history) while a LIST was coming out. */
      nKey := Inkey()
      IF nKey != 0
         IF nKey == K_ESC
            lEsc := .T.
            EXIT
         ENDIF
         hb_keyPut( nKey )
      ENDIF
   ENDDO
   dbGoto( nStart )
   DotOutput( LTrim( Str( nRec ) ) + " record(s)" + iif( lEsc, " (cancelled)", "" ) )
RETURN

STATIC PROCEDURE DotCmdAreas()
   LOCAL a, i, nCur := Select()
   /* it looks area by area, including the current one (DotOtherAreas(0) skips
    * none), so the user sees EVERYTHING that is open and in which area */
   a := DotOtherAreas( 0 )
   IF Empty( a )
      DotOutput( "No database is open." )
      RETURN
   ENDIF
   FOR i := 1 TO Len( a )
      SELECT ( a[ i ][ 1 ] )
      DotOutput( iif( a[ i ][ 1 ] == nCur, "> ", "  " ) + "Area " + ;
                 LTrim( Str( a[ i ][ 1 ] ) ) + ": " + a[ i ][ 2 ] + ;
                 "  Order: " + iif( Empty( DotOrdName() ), "(none)", DotOrdName() ) + ;
                 "  Rec. " + LTrim( Str( RecNo() ) ) + "/" + LTrim( Str( LastRec() ) ) + ;
                 "  " + iif( DotIsShared(), "Shared", "Exclusive" ) )
   NEXT
   SELECT ( nCur )
RETURN

STATIC PROCEDURE DotCmdRun( cRest )
   LOCAL c := AllTrim( cRest ), n
   IF Empty( c )
      DotErr( "RUN: missing command." )
      RETURN
   ENDIF
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      n := hb_run( c )
   RECOVER USING oErr
      DotErr( "Cannot run: " + oErr:Description )
      RETURN
   END SEQUENCE
   DotOutput( "Exit code: " + LTrim( Str( n ) ) )
RETURN

STATIC PROCEDURE DotShowHelp()
   DotOutput( "hwBro dot prompt - xBase commands" )
   DotOutput( "  ? <expr>[, <expr>]     display expressions     ?? <expr>   continue line" )
   DotOutput( "  SELECT <n>|<alias>|0   select work area        USE <file> [ALIAS x] [INDEX i]" )
   DotOutput( "  USE                    close current area      [EXCLUSIVE|SHARED] [NEW] [IN n]" )
   DotOutput( "  CLOSE [DATABASES|ALL]  close databases         SET ORDER TO <n>|<tag>|0" )
   DotOutput( "  SET INDEX TO <file>    open index file         SET FILTER TO <cond>" )
   DotOutput( "  SET EXACT|DELETED|SOFTSEEK|CENTURY ON|OFF      SET DATE FORMAT TO <fmt>" )
   DotOutput( "  GO TOP|BOTTOM|<n>      move record pointer      SKIP [<n>]" )
   DotOutput( "  SEEK <expr> / FIND <c> seek in the active order  LOCATE FOR <cond> / CONTINUE" )
   DotOutput( "  COUNT [FOR <cond>]     count records            SUM|AVERAGE <expr> [FOR c]" )
   DotOutput( "  REPLACE <f> WITH <e> [,...] [FOR <cond>]       APPEND BLANK" )
   DotOutput( "  DELETE|RECALL [ALL|RECORD n|FOR <cond>]        PACK / ZAP" )
   DotOutput( "  INDEX ON <key> TO <bag> [TAG <tag>] [FOR c] [UNIQUE] [DESCENDING]" )
   DotOutput( "  REINDEX                rebuild all tags         LIST|DISPLAY [<expr list>] [FOR c]" )
   DotOutput( "  STATUS                 status bar line           AREAS     open work areas" )
   DotOutput( "  RUN <cmd> / !<cmd>     run a program            CLEAR / CLEAR HISTORY" )
   DotOutput( "  HELP                   this list                HISTORY   command history" )
   DotOutput( "  EXIT / Esc             back to hwBro            QUIT      leave hwBro" )
   DotOutput( "  Up/Down                command history (DOSKEY)  PgUp/PgDn  scroll output" )
   DotOutput( "  Ctrl-PgUp/Ctrl-PgDn    output top / end         Ctrl-Up/Down  one line" )
   DotOutput( "Anything else is evaluated as a Harbour expression or function call." )
RETURN

STATIC PROCEDURE DotShowHistory()
   LOCAL i
   IF Empty( s_aHist )
      DotOutput( "No commands in history." )
      RETURN
   ENDIF
   FOR i := 1 TO Len( s_aHist )
      DotOutput( LTrim( Str( i ) ) + ": " + s_aHist[ i ] )
   NEXT
RETURN

/* ------------------------------------------------------------- utilities -- */

STATIC FUNCTION DotNeedDb()
   LOCAL lOk := Used()
   IF ! lOk
      DotErr( "No database is in use." )
   ENDIF
RETURN lOk

STATIC FUNCTION DotConfirm( cText )
   IF s_bConfirm == NIL
      RETURN .F.          /* no interface: the destructive part is not executed */
   ENDIF
RETURN Eval( s_bConfirm, cText )

STATIC PROCEDURE DotErr( cText )
   DotOutput( DOT_ERR + cText )
RETURN

STATIC PROCEDURE DotLine( cText, lAppend )
   LOCAL c
   IF lAppend .AND. ! Empty( s_aOut )
      c := s_aOut[ Len( s_aOut ) ] + cText
      ADel( s_aOut, Len( s_aOut ) )
      ASize( s_aOut, Len( s_aOut ) - 1 )
      DotOutput( c )
   ELSE
      DotOutput( cText )
   ENDIF
RETURN

/* split by words so nothing goes outside the output area */
STATIC FUNCTION DotWrapLine( cLine )
   LOCAL a := {}, c := cLine, n
   DO WHILE Len( c ) > s_nWidth
      n := s_nWidth
      DO WHILE n > 1 .AND. SubStr( c, n + 1, 1 ) != " "
         n--
      ENDDO
      IF n <= 1
         n := s_nWidth
      ENDIF
      AAdd( a, RTrim( Left( c, n ) ) )
      c := AllTrim( SubStr( c, n + 1 ) )
   ENDDO
   AAdd( a, c )
RETURN a

/* first word of cLine; it takes the word and the spaces away */
STATIC FUNCTION DotNextWord( cLine )
   LOCAL c, n
   cLine := LTrim( cLine )
   n := At( " ", cLine )
   IF n == 0
      c := cLine
      cLine := ""
   ELSE
      c := Left( cLine, n - 1 )
      cLine := AllTrim( SubStr( cLine, n + 1 ) )
   ENDIF
RETURN c

STATIC FUNCTION DotFirstWord( cLine )
   LOCAL c := AllTrim( cLine ), n
   n := At( " ", c )
RETURN iif( n == 0, c, Left( c, n - 1 ) )

/* splits a top-level comma list (respects quotes and brackets) */
STATIC FUNCTION DotSplitTop( cText )
   LOCAL a := {}, i, n := Len( cText ), c := "", nDepth := 0, nQ := 0, ch
   FOR i := 1 TO n
      ch := SubStr( cText, i, 1 )
      DO CASE
      CASE nQ != 0
         c += ch
         IF Asc( ch ) == nQ
            nQ := 0
         ENDIF
      CASE ch == '"' .OR. ch == "'" .OR. ch == "`"
         nQ := Asc( ch )
         c += ch
      CASE ch == "(" .OR. ch == "[" .OR. ch == "{"
         nDepth++
         c += ch
      CASE ch == ")" .OR. ch == "]" .OR. ch == "}"
         nDepth--
         c += ch
      CASE ch == "," .AND. nDepth == 0
         IF ! Empty( AllTrim( c ) )
            AAdd( a, AllTrim( c ) )
         ENDIF
         c := ""
      OTHERWISE
         c += ch
      ENDCASE
   NEXT
   IF ! Empty( AllTrim( c ) )
      AAdd( a, AllTrim( c ) )
   ENDIF
RETURN a

/* { header, forCondition } : separates "<head> FOR <cond>" */
STATIC FUNCTION DotSplitFor( cText )
   LOCAL n := DotFindTop( cText, "FOR" )
   IF n > 0
      RETURN { AllTrim( Left( cText, n - 1 ) ), AllTrim( SubStr( cText, n + 3 ) ) }
   ENDIF
RETURN { AllTrim( cText ), "" }

/* position of the word cWord in cText (top level, outside quotes) or 0 */
STATIC FUNCTION DotFindTop( cText, cWord )
   LOCAL i := 1, n := Len( cText ), nQ := 0, nDepth := 0, ch
   LOCAL cUp := Upper( cText ), nLen := Len( cWord )
   DO WHILE i <= n
      ch := SubStr( cText, i, 1 )
      DO CASE
      CASE nQ != 0
         IF Asc( ch ) == nQ
            nQ := 0
         ENDIF
      CASE ch == '"' .OR. ch == "'" .OR. ch == "`"
         nQ := Asc( ch )
      CASE ch == "(" .OR. ch == "[" .OR. ch == "{"
         nDepth++
      CASE ch == ")" .OR. ch == "]" .OR. ch == "}"
         nDepth--
      CASE nDepth == 0
         IF SubStr( cUp, i, nLen ) == cWord
            IF ( i == 1 .OR. SubStr( cText, i - 1, 1 ) == " " ) .AND. ;
               ( i + nLen > n .OR. SubStr( cText, i + nLen, 1 ) == " " )
               RETURN i
            ENDIF
         ENDIF
      ENDCASE
      i++
   ENDDO
RETURN 0

/* splits by spaces respecting quotes */
STATIC FUNCTION DotTokens( cText )
   LOCAL a := {}, i, n := Len( cText ), c := "", nQ := 0, ch
   FOR i := 1 TO n
      ch := SubStr( cText, i, 1 )
      DO CASE
      CASE nQ != 0
         c += ch
         IF Asc( ch ) == nQ
            nQ := 0
         ENDIF
      CASE ch == '"' .OR. ch == "'" .OR. ch == "`"
         nQ := Asc( ch )
         c += ch
      CASE ch == " " .OR. ch == Chr( 9 ) .OR. ch == ","
         IF ! Empty( c )
            AAdd( a, c )
            c := ""
         ENDIF
      OTHERWISE
         c += ch
      ENDCASE
   NEXT
   IF ! Empty( c )
      AAdd( a, c )
   ENDIF
RETURN a

STATIC FUNCTION DotUnquote( c )
   IF Len( c ) >= 2
      IF ( Left( c, 1 ) == '"' .AND. Right( c, 1 ) == '"' ) .OR. ;
         ( Left( c, 1 ) == "'" .AND. Right( c, 1 ) == "'" ) .OR. ;
         ( Left( c, 1 ) == "`" .AND. Right( c, 1 ) == "`" )
         RETURN SubStr( c, 2, Len( c ) - 2 )
      ENDIF
   ENDIF
RETURN c

/* full .DBF file name (adds the extension if missing) */
STATIC FUNCTION DotResolveDbf( cFile )
   IF ! ( "." $ cFile )
      cFile += ".DBF"
   ENDIF
RETURN cFile

/* file name without path or extension, in upper case (alias and order bag) */
STATIC FUNCTION DotBaseName( cFile )
   LOCAL c := cFile, n
   n := Rat( "\", c )
   IF n > 0
      c := SubStr( c, n + 1 )
   ENDIF
   n := Rat( "/", c )
   IF n > 0
      c := SubStr( c, n + 1 )
   ENDIF
   n := Rat( ".", c )
   IF n > 0
      c := Left( c, n - 1 )
   ENDIF
RETURN Upper( c )

/* index order bag name: without extension (DBFCDX adds it) */
STATIC FUNCTION DotBagName( cFile )
   LOCAL c := DotBaseName( cFile )
   IF ! Empty( c )
      RETURN c
   ENDIF
RETURN Upper( cFile )

STATIC FUNCTION DotFreeArea()
   LOCAL n, nOld := Select(), nFree := 0, lOk
   FOR n := 1 TO 64
      /* NOTE (trap 4): no EXIT/RETURN inside BEGIN SEQUENCE...RECOVER;
       * a flag is used, just like CoreAreas() */
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

STATIC FUNCTION DotAliasArea( cAlias )
   LOCAL n, nOld := Select(), nFound := 0, lOk
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
      IF Used() .AND. Upper( Alias() ) == Upper( cAlias )
         nFound := n
         EXIT
      ENDIF
   NEXT
   SELECT ( nOld )
RETURN nFound

STATIC FUNCTION DotIsShared()
   LOCAL lShared := .F.
   IF ! Used()
      RETURN ( s_cOpenMode == "SHARED" )
   ENDIF
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      lShared := dbInfo( DBI_SHARED )
   RECOVER
      lShared := ( s_cOpenMode == "SHARED" )
   END SEQUENCE
RETURN lShared

STATIC FUNCTION DotIsNumber( c )
   LOCAL i
   c := AllTrim( c )
   IF Empty( c )
      RETURN .F.
   ENDIF
   FOR i := 1 TO Len( c )
      IF ! IsDigit( SubStr( c, i, 1 ) ) .AND. SubStr( c, i, 1 ) != "-" .AND. ;
         SubStr( c, i, 1 ) != "."
         RETURN .F.
      ENDIF
   NEXT
RETURN .T.

STATIC FUNCTION DotToBool( c )
   c := Upper( AllTrim( c ) )
RETURN ( c == "ON" .OR. c == ".T." .OR. c == "T" .OR. c == "YES" .OR. c == "1" )

STATIC FUNCTION DotOnOff( l )
RETURN iif( l, "ON", "OFF" )

STATIC FUNCTION DotIsUseKeyword( c )
RETURN ( c == "ALIAS" .OR. c == "INDEX" .OR. c == "EXCLUSIVE" .OR. c == "SHARED" .OR. ;
         c == "NEW" .OR. c == "AGAIN" .OR. c == "IN" .OR. c == "VIA" )

/* --------------------------------------------------------------- screen ---- */

/* Dot prompt screen. Returns .T. to go back to hwBro and .F. if the user
 * asked to leave the program (QUIT). It does NOT repaint hwBro: the caller does. */
FUNCTION BpDotPrompt()
   LOCAL cLine := "", nKey, cOldCur, lLeave := .F., lHadHook := .F.
   LOCAL nOutT := 2, nOutB := MaxRow() - 3, nInRow := MaxRow() - 1

   s_bConfirm := {| c | DotAskYesNo( c, nInRow ) }
   DotSetWidth( MaxCol() )
   /* mouse active: GTWVG delivers the wheel as K_MWFORWARD/K_MWBACKWARD through
    * Inkey(). If the driver does not support the extension, hb_gtInfo() throws an error and
    * it goes on anyway (page keys always work). */
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      hb_gtInfo( HB_GTI_MOUSESTATUS, 1 )
   RECOVER
   END SEQUENCE
   s_lQuit := .F.
   DotHistReset()
   s_nScroll := 0
   cOldCur := SetCursor( 0 )

   UiPaintBegin()
   UiCls()
   DotDrawHeader()
   DotPaintScreen( nOutT, nOutB )
   UiPaintEnd()
   /* the caret is visible ONLY in the command line (same idea as the browser,
    * which hides it outside the cell being edited). UiPaintBegin/End hide it
    * while they paint and restore it at the end, so it is enough to leave it
    * on before entering the loop. */
   SetCursor( 1 )
   /* wheel and bar clicks: native hook on the driver window.
    * S8 of odd/tasks/commander-cleanup.md: the hook may ALREADY be the one of the
    * screen behind (the Browse edit installs it when it opens), so whether it was
    * ours is asked FIRST and the exit only takes it off when this screen put it
    * there. Before, leaving the dot tore the hook off the browser and the mouse
    * stopped working there (pending 24 of AGENTS.md). */
   lHadHook := DotMouseHookOn()
   DotMouseHook( .T. )

   DO WHILE ! lLeave
      /* S1/S4 of window-close.md (B3): the X of the window, once per pass. The
       * dot leaves through the shape it already has for `EXIT`, <Esc> and a
       * `QUIT` -lLeave, and the tail below removes the window hook and restores
       * the caret- so nothing of this screen survives the close; BpCloseAsk()
       * raises the program's exit flag and Main() ends the program when this
       * procedure returns. No `Exit hwBro?` is asked (L7). The poll is repeated
       * inside DotInputLine(), which is where the program actually waits for
       * the user: between commands this loop only runs once. The headless bank
       * of T2 links this module without hwbro.prg, so it is compiled out. */
#ifndef BP_DOT_STANDALONE
      IF BpCloseAsk()
         lLeave := .T.
         EXIT
      ENDIF
#endif
      s_bPaint := {|| DotPaintScreen( nOutT, nOutB ) }
      cLine := DotInputLine( nInRow, cLine )
      IF cLine == NIL
         lLeave := .T.
      ELSEIF ! DotExec( cLine )
         lLeave := .T.
      ELSE
         cLine := ""
      ENDIF
   ENDDO

   s_bPaint := NIL
   s_bConfirm := NIL
   /* S8 of odd/tasks/commander-cleanup.md: only the hook THIS screen installed
    * goes away. If it was already installed - the Browse edit installs it when it
    * opens - it is left alone, which is what keeps the mouse working after coming
    * back. Before, leaving the dot tore it off the browser and the mouse died
    * there (pending 24 of AGENTS.md). */
   IF ! lHadHook
      DotMouseHook( .F. )
   ENDIF
   SetCursor( 0 )
   SetCursor( cOldCur )
   SetColor( UI_C_DESKTOP )
RETURN ! s_lQuit

STATIC PROCEDURE DotDrawHeader()
   LOCAL cChip := " Dot Prompt "
   SetColor( UI_C_MENUBAR )
   @ 0, 0 SAY Space( MaxCol() + 1 )
   @ 1, 0 SAY Replicate( BP_LINE_DOUBLE, MaxCol() + 1 )
   SetColor( UI_C_MENULBL )
   @ 0, 1 SAY cChip
   SetColor( UI_C_MENUKEY )
   /* the hot keys follow the title chip instead of sitting on the literal
    * column 14 that only worked for this exact chip text */
   @ 0, 1 + Len( cChip ) SAY "<F1>=Help <Esc>=Exit <Alt-X>=Quit Up/Down=History PgUp/PgDn=Scroll"
   SetColor( UI_C_DESKTOP )
RETURN

/* scroll bar of the output: right column, only if not everything fits.
 * ░ = track, █ = the visible part. No new colors (N/W). */
STATIC PROCEDURE DotDrawScrollBar( nOutT, nOutB, nVisible, nTotal, nFirst )
   LOCAL nCol := MaxCol(), i, nH, nThumbT, nThumbB
   s_nThumbT := 0
   s_nThumbB := -1
   SetColor( UI_C_DESKTOP )
   FOR i := nOutT TO nOutB
      @ i, nCol SAY " "
   NEXT
   IF nTotal <= nVisible .OR. nTotal <= 1
      RETURN
   ENDIF
   nH := Max( 1, Int( nVisible * nVisible / nTotal ) )
   nThumbT := nOutT + Int( ( nFirst - 1 ) * ( nVisible - nH ) / Max( 1, nTotal - nVisible ) )
   nThumbB := Min( nOutB, nThumbT + nH - 1 )
   FOR i := nOutT TO nOutB
      @ i, nCol SAY iif( i >= nThumbT .AND. i <= nThumbB, Chr( 219 ), Chr( 176 ) )
   NEXT
   /* thumb geometry for the clicks on the bar (DotMousePoll) */
   s_nThumbT := nThumbT
   s_nThumbB := nThumbB
   SetColor( UI_C_DESKTOP )
RETURN

/* paints the output region (and the status bar) */
STATIC PROCEDURE DotPaintScreen( nOutT, nOutB )
   LOCAL nVisible := nOutB - nOutT + 1, nTotal := Len( s_aOut ), nEnd, i, nLine
   LOCAL c, nFirst, cMode, nW
   s_nVisible := nVisible
   s_nOutT := nOutT
   s_nOutB := nOutB
   s_nScroll := Min( s_nScroll, Max( 0, nTotal - nVisible ) )
   nEnd := nTotal - s_nScroll
   nFirst := Max( 1, nEnd - nVisible + 1 )
   UiPaintBegin()
   SetColor( UI_C_DESKTOP )
   FOR i := nOutT TO nOutB
      @ i, 0 SAY Space( MaxCol() + 1 )
   NEXT
   FOR i := 1 TO nVisible
      nLine := nEnd - nVisible + i
      IF nLine >= 1 .AND. nLine <= nTotal
         c := s_aOut[ nLine ]
         IF Left( c, 4 ) == DOT_ERR
            SetColor( UI_C_ERR )
            @ nOutT + i - 1, 0 SAY PadR( c, MaxCol() + 1 )
         ELSE
            SetColor( UI_C_DESKTOP )
            @ nOutT + i - 1, 0 SAY c
         ENDIF
      ENDIF
   NEXT
   DotDrawScrollBar( nOutT, nOutB, nVisible, nTotal, nFirst )
   /* separator between the output and the command line */
   SetColor( UI_C_MENUBAR )
   @ MaxRow() - 2, 0 SAY Replicate( BP_LINE_SINGLE, MaxCol() + 1 )
   /* status bar, AT THE VERY BOTTOM (the command line goes above) */
   /* status bar in BLACK ON CYAN, like the status bar of the original
    * dBASE, with the open mode (Excl/Shared) glued to the RIGHT edge */
   cMode := DotStatusMode()
   nW := MaxCol() + 1 - Len( cMode )
   SetColor( UI_C_CHIP )
   @ MaxRow(), 0 SAY " " + PadR( DotStatusLine( nW - 2 ), nW - 2 ) + " "
   @ MaxRow(), nW SAY cMode
   SetColor( UI_C_DESKTOP )
   /* the caret must ALWAYS stay in the command line: the @ SAY calls
    * above would leave the text cursor (and with it the GTWVG caret) in the
    * status bar or at the end of the output */
   IF s_nInRow > 0
      DevPos( s_nInRow, Len( DOT_PROMPT ) + s_nInPos )
   ENDIF
   UiPaintEnd()
RETURN

/* S8 of odd/tasks/commander-cleanup.md: is the window hook installed already?
 * It is asked BEFORE installing it, so leaving the dot does not tear off the hook
 * of the screen behind (the Browse edit). PUBLIC and in its own function so the
 * headless bank of T2 can pin it: without a window there is no hook, and the
 * answer is .F. - which is exactly what makes the dot remove its own. */
FUNCTION DotMouseHookOn()
RETURN ( W32MOUSEHOOKON() != 0 )

/* Native mouse polling (bp_win32.c). This GTWVG delivers neither the wheel nor the
 * clicks through Inkey(), so the window WndProc records them and here they are
 * collected. Returns .T. if there was something to repaint. */
STATIC FUNCTION DotMousePoll()
   LOCAL nNotch := DotMouseWheel(), nRow, nCol, lDone := .F.
   IF nNotch != 0
      /* wheel: 3 lines per notch, like any terminal */
      DotScroll( nNotch * 3 )
      lDone := .T.
   ENDIF
   nRow := DotMouseClickRow()
   nCol := DotMouseClickCol()
   IF nRow >= 0 .AND. nCol >= 0
      /* click on the scroll bar (last column): above the thumb = one
       * page back, below = one page forward */
      IF nCol == MaxCol() .AND. s_nVisible > 0 .AND. ;
         nRow >= s_nOutT .AND. nRow <= s_nOutB .AND. s_nThumbB >= s_nThumbT
         IF nRow < s_nThumbT
            DotScroll( Max( 1, s_nVisible - 1 ) )
            lDone := .T.
         ELSEIF nRow > s_nThumbB
            DotScroll( -Max( 1, s_nVisible - 1 ) )
            lDone := .T.
         ENDIF
      ENDIF
   ENDIF
RETURN lDone

/* command line editor: insertion, history with Up/Down.
 * Returns the typed line, "" if the user left it empty, or NIL if the user asked
 * to leave the dot (Esc). */
STATIC FUNCTION DotInputLine( nRow, cValue )
   LOCAL cBuf, nPos, nKey, c
   LOCAL nMax := MaxCol() - Len( DOT_PROMPT )
   DEFAULT cValue TO ""
   cBuf := PadR( Left( cValue, nMax ), nMax )
   nPos := Min( Len( RTrim( cValue ) ), nMax - 1 )
   DotDrawInput( nRow, cBuf, nPos )
   DO WHILE .T.
      DevPos( nRow, Len( DOT_PROMPT ) + nPos )
      /* Inkey with a short wait: while there are no keys the wheel and the
       * scroll bar are polled (the message is captured by bp_win32.c) */
      nKey := Inkey( 0.05 )
      IF nKey == 0
         /* S1/S4 of window-close.md (B3): the idle slice of the command line
          * is the pass the program spends waiting for the user, so the X is
          * polled here too -once per slice, next to the mouse-. The answer is
          * the SAME NIL that <Esc> gives, so the line editor closes and
          * BpDotPrompt() leaves through its normal exit (window hook off,
          * caret restored) instead of unwinding from inside the editor. The
          * headless bank of T2 links this module without hwbro.prg. */
#ifndef BP_DOT_STANDALONE
         IF BpCloseAsk()
            RETURN NIL
         ENDIF
#endif
         DotMousePoll()
         /* right-click-esc (S1/S7 of right-click-esc.md): a plain right click
          * leaves the dot prompt, the same as Esc. bp_dot.prg is linked by its
          * own bank without bp_hc.prg, so the question is asked through the hook
          * of bp_ui.prg (Main() wires it to the same detector). */
         IF UiRightClick()
            RETURN NIL
         ENDIF
         LOOP
      ENDIF
      DO CASE
      CASE nKey == K_ENTER
         EXIT
      CASE nKey == K_ESC
         RETURN NIL
      CASE nKey == K_UP .OR. nKey == K_CTRL_P
         c := DotHistUp( RTrim( cBuf ) )
         cBuf := PadR( Left( c, nMax ), nMax )
         nPos := Min( Len( RTrim( c ) ), nMax - 1 )
      CASE nKey == K_DOWN .OR. nKey == K_CTRL_N
         c := DotHistDown( RTrim( cBuf ) )
         cBuf := PadR( Left( c, nMax ), nMax )
         nPos := Min( Len( RTrim( c ) ), nMax - 1 )
      CASE nKey == K_LEFT
         nPos := Max( 0, nPos - 1 )
      CASE nKey == K_RIGHT
         nPos := Min( Len( RTrim( cBuf ) ), nMax - 1 )
      CASE nKey == K_HOME
         nPos := 0
      CASE nKey == K_END
         nPos := Min( Len( RTrim( cBuf ) ), nMax - 1 )
      CASE nKey == K_BS
         IF nPos > 0
            cBuf := Stuff( cBuf, nPos, 1, "" ) + " "
            nPos--
         ENDIF
      CASE nKey == K_DEL
         cBuf := Left( cBuf, nPos ) + SubStr( cBuf, nPos + 2 ) + " "
      CASE nKey == K_PGUP
         DotScroll( Max( 1, s_nVisible - 1 ) )
      CASE nKey == K_PGDN
         DotScroll( -Max( 1, s_nVisible - 1 ) )
      CASE nKey == K_CTRL_UP
         DotScroll( 1 )
      CASE nKey == K_CTRL_DOWN
         DotScroll( -1 )
      CASE nKey == K_MWFORWARD
         /* mouse wheel: forward = older lines */
         DotScroll( 3 )
      CASE nKey == K_MWBACKWARD
         DotScroll( -3 )
      CASE nKey == K_MOUSEMOVE .OR. nKey == K_NCMOUSEMOVE
         /* with the mouse active the driver reports every movement: repainting the
          * command line on every event would flicker, and there is nothing to do */
         LOOP
      CASE nKey == K_CTRL_PGUP
         DotScroll( 100000 )
      CASE nKey == K_CTRL_PGDN
         DotScroll( -100000 )
      CASE nKey == K_F1
         DotHintLine( nRow, "HELP" )
         DotShowHelp()
      CASE nKey == K_ALT_X
         IF DotAskYesNo( "Exit hwBro?", nRow )
            s_lQuit := .T.
            RETURN NIL
         ENDIF
      CASE nKey >= 32 .AND. nKey <= 255
         IF Len( AllTrim( cBuf ) ) < nMax - 1 .OR. nPos < Len( RTrim( cBuf ) )
            cBuf := Stuff( cBuf, nPos + 1, 0, Chr( nKey ) )
            cBuf := Left( cBuf, nMax )
            nPos++
         ENDIF
      ENDCASE
      DotDrawInput( nRow, cBuf, nPos )
      DevPos( nRow, Len( DOT_PROMPT ) + nPos )
   ENDDO
RETURN RTrim( cBuf )

STATIC PROCEDURE DotDrawInput( nRow, cBuf, nPos )
   s_nInRow := nRow
   s_nInPos := nPos
   UiPaintBegin()
   SetColor( UI_C_MENUBAR )
   @ nRow, 0 SAY Space( MaxCol() + 1 )
   /* the prompt dot goes in yellow on the SAME background of the line, without
    * the cyan block it had before (it looked like a greenish box) */
   SetColor( UI_C_HOTON )
   @ nRow, 0 SAY DOT_PROMPT
   SetColor( UI_C_MENUKEY )
   @ nRow, Len( DOT_PROMPT ) SAY cBuf
   SetColor( UI_C_DESKTOP )
   UiPaintEnd()
   DevPos( nRow, Len( DOT_PROMPT ) + nPos )
RETURN

/* echoes on the input line (e.g. when pressing F1) */
STATIC PROCEDURE DotHintLine( nRow, cText )
   UiPaintBegin()
   SetColor( UI_C_CHIP )
   @ nRow, Len( DOT_PROMPT ) SAY "[" + cText + "]"
   UiPaintEnd()
RETURN

/* confirmation on the input line itself: Y/Enter = Yes, N/Esc = No */
STATIC FUNCTION DotAskYesNo( cText, nRow )
   LOCAL nKey, cOld := PadR( " " + Left( cText, MaxCol() - 4 ) + " (Y/N) ", MaxCol() + 1 )
   /* it is asked on the command line (the status bar stays at the very bottom) */
   nRow := MaxRow() - 1
   UiPaintBegin()
   SetColor( UI_C_ERR )
   @ nRow, 0 SAY cOld
   UiPaintEnd()
   DO WHILE .T.
      nKey := Inkey( 0 )
      DO CASE
      CASE nKey == K_ENTER .OR. nKey == Asc( "Y" ) .OR. nKey == Asc( "y" )
         UiPaintBegin()
         SetColor( UI_C_MENUBAR )
         @ nRow, 0 SAY Space( MaxCol() + 1 )
         UiPaintEnd()
         RETURN .T.
      CASE nKey == K_ESC .OR. nKey == Asc( "N" ) .OR. nKey == Asc( "n" )
         UiPaintBegin()
         SetColor( UI_C_MENUBAR )
         @ nRow, 0 SAY Space( MaxCol() + 1 )
         UiPaintEnd()
         RETURN .F.
      ENDCASE
   ENDDO
RETURN .F.
