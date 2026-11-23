/*
 * bp_link.prg - Commander Link: the LAN master/slave file link.
 *
 * Three layers, all of them in PRG (this Harbour build exposes the socket API
 * to PRG: odd/tasks/commander-link.md L4):
 *
 *   1. TRANSPORT  thin wrappers over hb_socket*() with an EXPLICIT millisecond
 *                 budget on every waiting call. A timeout of -1 means "wait
 *                 forever" and would freeze the single threaded GTWVG loop, so
 *                 it is never used from here (S9).
 *   2. PROTOCOL   pure functions, no sockets: framing (S12), path confinement
 *                 (S11), directory listing, entry lines and address parsing.
 *                 All of it is testable without a window and without a network.
 *   3. SERVER     the Slave (S9/S10) plus the client primitives the Master
 *                 needs: a session table, a non blocking pump and one request /
 *                 one reply exchange.
 *   Plus the UDP discovery of S4/S8.
 *
 * WHAT A PATH MEANS (S14, L7): every path that travels is an ABSOLUTE path of
 * the machine that serves it ("C:\Users\Public", "\\SERVER\SHARE"). The scope
 * the Slave exports decides what is accepted: the sentinel LINK_ROOT_DISK ("*")
 * means the WHOLE DISK and takes any valid absolute path; anything else is one
 * directory and a request outside it is refused by LinkSafePath(), which stays
 * the ONLY gate (S11). There is no root relative wire path any more: that is
 * why LINK_VERSION is 2.
 *
 * Wire format (S12): one message is
 *
 *    <decimal length> ":" [ "B" ] LF <payload>
 *
 * where the "B" only appears on a binary frame and the length counts the
 * payload ONLY. A text payload is the list of arguments joined with LF, the
 * verb first. A binary payload is raw bytes (a GET body, a PUT chunk), so a
 * binary frame carries no arguments.
 *
 * Nothing here knows about the panel or about colours: bp_link.prg must
 * compile on its own (src/tests/test_link.prg) and therefore never includes
 * bp_def.ch, bp_ui.prg or bp_hc.prg.
 *
 * MEASURED in this build (do not "fix" these):
 *   - hb_vfDirectory() hands the date over as a "T" timestamp and the time as
 *     a "HH:MM:SS" string;
 *   - hb_vfRename() and hb_vfErase() answer 0 on success, not .T.;
 *   - a formal parameter only updates the caller's variable when the call site
 *     writes `@` (measured: `LinkTake( @cBuf )`);
 *   - hb_idleSleep() takes SECONDS.
 */
#include "common.ch"
#include "fileio.ch"
#include "hbsocket.ch"

#define LINK_VERSION      2          /* protocol version (HELLO checks it)     */
#define LINK_PORT         31000      /* default TCP port and UDP discovery port */
#define LINK_MAX_FRAME    8388608    /* 8 MB: a bigger declared length is junk  */
#define LINK_CHUNK        65536      /* same spirit as HC_COPY_CHUNK            */
#define LINK_PAGE_MAX     1000       /* entries of a LIST page when not asked   */
#define LINK_BACKLOG      8          /* pending connections                     */
#define LINK_TMP          ".$$$"     /* temporary of an atomic write (S10)      */
#define LINK_ANY          "0.0.0.0"  /* bind address of a server                */
#define LINK_BROADCAST    "255.255.255.255"
#define LINK_LOOPBACK     "127.0.0.1"
#define LINK_ROOT_DISK    "*"        /* exported scope (S14): the WHOLE disk.  A
                                      * path can never be "*", so it cannot
                                      * collide with a real served root        */

#define LINK_TIMEOUT_DEF  5000       /* ms of the default request budget        */
#define LINK_MAX_DIGITS   10         /* digits of the frame length header       */
#define LINK_LIST_PAGE    500        /* entries per LIST frame (the Master pages) */
#define LINK_GET_CHUNK    16384      /* bytes per GET frame: it has to fit in a
                                      * socket buffer, because the peer may be
                                      * the same process (LinkSetPumpHook())   */
#define LINK_TX_SLICE     16384      /* biggest single hb_socketSend() slice    */
#define LINK_POLL_MS      10         /* step of the wait when a pump hook is on */

/* discovery datagrams (S4) */
#define LINK_DISC_REQ     "HWBRO-DISCOVER/1"
#define LINK_DISC_RSP     "HWBRO-HERE/1"

/* server error codes (S11) */
#define LINK_E_BAD        400
#define LINK_E_OUTSIDE    403
#define LINK_E_NOTFOUND   404
#define LINK_E_CONFLICT   409
#define LINK_E_IO         500
#define LINK_E_VERSION    426

/* session record: { socket, input buffer, peer text, pending PUT } */
#define LS_SOCK   1
#define LS_BUF    2
#define LS_PEER   3
#define LS_PUT    4

/* pending PUT: { file handle, temporary, destination, total, done } */
#define LP_HANDLE 1
#define LP_TMP    2
#define LP_DEST   3
#define LP_TOTAL  4
#define LP_DONE   5

/* entry record, the exact shape of HcEntryNew() in bp_hc.prg:
 * { name, size, date, attr, .F., time } */
#define LE_NAME   1
#define LE_SIZE   2
#define LE_DATE   3
#define LE_ATTR   4
#define LE_MARK   5
#define LE_TIME   6

/* module STATIC declarations go on top (AGENTS.md section 5, trap 7) */
STATIC s_aLinkSess   := {}     /* session table of the Slave (S9)             */
STATIC s_cLinkName   := ""     /* name announced by HELLO and by discovery    */
STATIC s_nLinkServed := 0      /* requests answered since the program started */
STATIC s_aLinkIn     := {}     /* { hSocket, cBuf } of every CLIENT read      */
STATIC s_bLinkPump   := NIL    /* peer pump installed with LinkSetPumpHook()  */
STATIC s_lLinkInPump := .F.    /* reentrancy guard: the hook never nests      */

/* =====================================================================
 *  1. TRANSPORT
 * ===================================================================== */

/* Opens the listening socket of the Slave. <nPort> = 0 lets the OS pick one
 * (the tests do that and read the real port with hb_socketGetSockName()).
 * Answers { hSocket, cError }; hSocket is NIL when cError is not empty. */
FUNCTION LinkListen( nPort, cBind )
   LOCAL hSock, cErr := ""
   DEFAULT nPort TO LINK_PORT
   DEFAULT cBind TO LINK_ANY
   IF ValType( nPort ) != "N" .OR. nPort < 0 .OR. nPort > 65535
      RETURN { NIL, "invalid port" }
   ENDIF
   hSock := hb_socketOpen( HB_SOCKET_AF_INET, HB_SOCKET_PT_STREAM, HB_SOCKET_IPPROTO_TCP )
   IF ! LinkIsSock( hSock )
      RETURN { NIL, "cannot open a socket" }
   ENDIF
   IF ! hb_socketBind( hSock, { HB_SOCKET_AF_INET, cBind, nPort } )
      hb_socketClose( hSock )
      RETURN { NIL, "cannot bind " + cBind + ":" + LinkIntToStr( nPort ) }
   ENDIF
   IF ! hb_socketListen( hSock, LINK_BACKLOG )
      hb_socketClose( hSock )
      RETURN { NIL, "cannot listen on " + cBind + ":" + LinkIntToStr( nPort ) }
   ENDIF
RETURN { hSock, cErr }

/* Opens a client socket connected to <cHost>:<nPort>. Same shape as
 * LinkListen(): { hSocket, cError }. */
FUNCTION LinkConnect( cHost, nPort, nMs )
   LOCAL hSock
   DEFAULT cHost TO LINK_LOOPBACK
   DEFAULT nPort TO LINK_PORT
   DEFAULT nMs TO LINK_TIMEOUT_DEF
   hSock := hb_socketOpen( HB_SOCKET_AF_INET, HB_SOCKET_PT_STREAM, HB_SOCKET_IPPROTO_TCP )
   IF ! LinkIsSock( hSock )
      RETURN { NIL, "cannot open a socket" }
   ENDIF
   IF ! hb_socketConnect( hSock, { HB_SOCKET_AF_INET, cHost, nPort }, LinkBudget( nMs ) )
      hb_socketClose( hSock )
      RETURN { NIL, "cannot connect to " + AllTrim( cHost ) + ":" + LinkIntToStr( nPort ) }
   ENDIF
RETURN { hSock, "" }

/* closes a socket opened here (a NIL handle is not an error: hb_socketClose()
 * only empties the item) and forgets the bytes read from it but not consumed.
 * MEASURED: closing a handle that was already closed THROWS (the item keeps a
 * stale, non empty pointer, so LinkIsSock() cannot tell), so the close goes
 * through the same guard as the other socket calls. */
FUNCTION LinkClose( hSock )
   IF LinkIsSock( hSock )
      LinkForgetBuf( hSock )
      LinkSockClose( hSock )
   ENDIF
RETURN NIL

/* name announced by HELLO and by the discovery replies. Empty answers the
 * machine name, which is what a LAN peer recognizes. */
FUNCTION LinkServerName()
   LOCAL c := s_cLinkName
   IF Len( c ) == 0
      c := AllTrim( hb_GetEnv( "COMPUTERNAME" ) )
   ENDIF
   IF Len( c ) == 0
      c := "hwBro"
   ENDIF
RETURN c

FUNCTION LinkSetServerName( cName )
   IF ValType( cName ) == "C"
      s_cLinkName := AllTrim( cName )
   ENDIF
RETURN LinkServerName()

/* =====================================================================
 *  2. PROTOCOL - framing (S12)
 * ===================================================================== */

/* One wire frame. With <cBinary> the payload IS those bytes (a binary frame
 * carries no arguments); without it the payload is the arguments joined with
 * LF, the verb first. */
FUNCTION LinkFrame( aArgs, cBinary )
   LOCAL cPayload, i, lBin := ValType( cBinary ) == "C"
   IF lBin
      cPayload := cBinary
   ELSE
      cPayload := ""
      IF HB_ISARRAY( aArgs )
         FOR i := 1 TO Len( aArgs )
            cPayload += iif( i == 1, "", Chr( 10 ) ) + LinkArgText( aArgs[ i ] )
         NEXT
      ENDIF
   ENDIF
RETURN LinkIntToStr( Len( cPayload ) ) + ":" + iif( lBin, "B", "" ) + Chr( 10 ) + cPayload

/* Takes the next COMPLETE frame out of <cBuf> - which the caller MUST pass as
 * `@cBuf` (measured: without the `@` the caller's variable is not updated) -
 * consuming exactly that frame and leaving the rest in the buffer. Answers
 * { aArgs, cBinary }, where cBinary is "" for a text frame, or NIL when the
 * buffer does not hold a whole frame yet.
 *
 * A header that can never become a frame (a non digit, a length over
 * LINK_MAX_FRAME, a broken separator) makes the whole buffer be DROPPED and
 * NIL returned: nothing behind it can be trusted and the 8 MB is never
 * allocated. The caller keeps waiting and its own budget closes the session. */
FUNCTION LinkTake( cBuf )
   LOCAL cDigits, nColon, c, lBin := .F., nHead, nLen, cPayload, aArgs
   IF ValType( cBuf ) != "C" .OR. Len( cBuf ) == 0
      RETURN NIL
   ENDIF

   /* ---- header: digits, ':', optional 'B', LF ---- */
   nColon := At( ":", cBuf )
   IF nColon == 0
      /* no separator yet: it is only a problem when what arrived is not a
       * number either, because a number can still grow into a header; a run
       * of digits longer than any legal length is junk too */
      IF ! LinkAllDigits( cBuf ) .OR. Len( cBuf ) > LINK_MAX_DIGITS
         cBuf := ""
      ENDIF
      RETURN NIL
   ENDIF
   cDigits := Left( cBuf, nColon - 1 )
   IF ! LinkAllDigits( cDigits ) .OR. Len( cDigits ) > LINK_MAX_DIGITS
      cBuf := ""
      RETURN NIL
   ENDIF
   nLen := Val( cDigits )
   IF nLen > LINK_MAX_FRAME
      cBuf := ""
      RETURN NIL
   ENDIF
   c := SubStr( cBuf, nColon + 1, 1 )
   DO CASE
   CASE c == "B"
      lBin := .T.
      nHead := nColon + 2
      IF Len( cBuf ) < nHead
         RETURN NIL
      ENDIF
      IF ! ( SubStr( cBuf, nHead, 1 ) == Chr( 10 ) )
         cBuf := ""
         RETURN NIL
      ENDIF
   CASE c == Chr( 10 )
      nHead := nColon + 1
   CASE Len( cBuf ) <= nColon
      /* the header stops right after the ':' : not complete yet */
      RETURN NIL
   OTHERWISE
      cBuf := ""
      RETURN NIL
   ENDCASE

   /* ---- payload ---- */
   IF Len( cBuf ) < nHead + nLen
      RETURN NIL
   ENDIF
   cPayload := SubStr( cBuf, nHead + 1, nLen )
   cBuf := SubStr( cBuf, nHead + nLen + 1 )

   IF lBin
      RETURN { {}, cPayload }
   ENDIF
   IF nLen == 0
      aArgs := {}
   ELSE
      aArgs := LinkSplit( cPayload, Chr( 10 ) )
   ENDIF
RETURN { aArgs, "" }

/* =====================================================================
 *  2. PROTOCOL - paths (S11)
 * ===================================================================== */

/* One canonical form of a path, PURELY TEXTUAL (no filesystem access):
 * backslashes, no empty, "." or ".." component and no trailing separator (a
 * root keeps its own). ".." never climbs over the drive root or over the UNC
 * prefix, so "C:\.." stays "C:\". The case is PRESERVED: the callers that
 * compare uppercase the result, so a path handed to the filesystem keeps
 * looking like the user typed it. */
STATIC FUNCTION LinkNormPath( cPath )
   LOCAL c, cPrefix := "", aPart, aOut := {}, i, cPart
   IF ValType( cPath ) != "C"
      RETURN ""
   ENDIF
   c := AllTrim( cPath )
   IF Len( c ) == 0
      RETURN ""
   ENDIF
   c := StrTran( c, "/", "\" )
   IF Left( c, 2 ) == "\\"
      cPrefix := "\\"
      c := SubStr( c, 3 )
   ELSEIF Len( c ) >= 2 .AND. SubStr( c, 2, 1 ) == ":"
      cPrefix := Upper( Left( c, 2 ) ) + "\"
      c := SubStr( c, 3 )
   ENDIF
   aPart := hb_ATokens( c, "\" )
   FOR i := 1 TO Len( aPart )
      cPart := aPart[ i ]
      DO CASE
      CASE Len( cPart ) == 0 .OR. cPart == "."
         /* the current directory vanishes */
      CASE cPart == ".."
         IF Len( aOut ) > 0
            ASize( aOut, Len( aOut ) - 1 )
         ENDIF
      OTHERWISE
         AAdd( aOut, cPart )
      ENDCASE
   NEXT
   c := ""
   FOR i := 1 TO Len( aOut )
      c += iif( Len( c ) == 0, "", "\" ) + aOut[ i ]
   NEXT
   IF Len( c ) == 0
      RETURN cPrefix
   ENDIF
RETURN cPrefix + c

/* "C:\" / "C:" / a bare "\\" : a root, which is never a request target */
STATIC FUNCTION LinkIsRoot( cNorm )
   IF ValType( cNorm ) != "C"
      RETURN .F.
   ENDIF
   IF Len( cNorm ) == 3 .AND. SubStr( cNorm, 2, 1 ) == ":" .AND. Right( cNorm, 1 ) == "\"
      RETURN .T.
   ENDIF
   IF Len( cNorm ) == 2 .AND. SubStr( cNorm, 2, 1 ) == ":"
      RETURN .T.
   ENDIF
RETURN cNorm == "\\"

/* "C:\x" or "\\srv\share": the input names a place on its own */
STATIC FUNCTION LinkIsAbs( cPath )
   LOCAL c := AllTrim( cPath )
   IF Len( c ) >= 2 .AND. SubStr( c, 2, 1 ) == ":" .AND. IsAlpha( Left( c, 1 ) )
      RETURN .T.
   ENDIF
RETURN Left( c, 2 ) == "\\"

/* <cDir> + <cName> with exactly one separator in the middle */
STATIC FUNCTION LinkJoinDir( cDir, cName )
   LOCAL c := cDir
   IF Len( c ) == 0
      RETURN cName
   ENDIF
   IF ! ( Right( c, 1 ) == "\" )
      c += "\"
   ENDIF
RETURN c + cName

/* a directory argument hb_vfDirectory() accepts (measured: without the
 * trailing separator the listing comes back with ONE element) */
STATIC FUNCTION LinkDirArg( cDir )
   LOCAL c := AllTrim( cDir )
   IF Len( c ) == 0
      RETURN ""
   ENDIF
   IF ! ( Right( c, 1 ) == "\" ) .AND. ! ( Right( c, 1 ) == "/" )
      c += "\"
   ENDIF
RETURN c

/* .T. when <cRoot> is the sentinel that exports the WHOLE disk (S14): the
 * default of the Slave dialog, so a Master may navigate the entire filesystem
 * of the peer. PURE. */
FUNCTION LinkIsDiskScope( cRoot )
   IF ValType( cRoot ) != "C"
      RETURN .F.
   ENDIF
RETURN cRoot == LINK_ROOT_DISK

/* The drives of the machine that runs this code, as "C:" strings. ONE
 * implementation: the DRIVES verb answers it over the wire and the local
 * Alt-F1/Alt-F2 picker shows the same list, so a linked panel can never offer
 * a different set than a local one. */
FUNCTION LinkDrives()
   LOCAL a := {}, i, cDrv
   FOR i := 1 TO 26
      cDrv := Chr( i + 64 )
      IF hb_DirExists( cDrv + ":\" )
         AAdd( a, cDrv + ":" )
      ENDIF
   NEXT
RETURN a

/* THE ONLY function that turns wire data into a filesystem path (S11).
 * Answers the absolute path confined inside <cRoot>, or NIL when the request
 * escapes. With the WHOLE DISK exported (LinkIsDiskScope) any valid absolute
 * path is accepted - roots included, because a Master lists the root of a
 * drive - and only a relative, empty or ".." request is refused. With a
 * directory exported nothing may leave it: a normalised "..", a path above
 * the root, another drive, an absolute path outside the root or a drive root
 * are all refused. Nothing touches the disk. */
FUNCTION LinkSafePath( cRoot, cPath )
   LOCAL cRootN, cIn, cOut, cRU, cOU, cSep
   IF ValType( cRoot ) != "C" .OR. ValType( cPath ) != "C"
      RETURN NIL
   ENDIF
   cIn := AllTrim( cPath )
   IF LinkIsDiskScope( cRoot )
      /* S14: the whole disk of the Slave. A relative name has no base here, so
       * it is refused instead of being resolved against this process */
      IF Len( cIn ) == 0 .OR. cIn == "." .OR. cIn == ".."
         RETURN NIL
      ENDIF
      IF Left( cIn, 1 ) == "\" .AND. ! ( Left( cIn, 2 ) == "\\" )
         RETURN NIL
      ENDIF
      IF ! LinkIsAbs( cIn )
         RETURN NIL
      ENDIF
      cOut := LinkNormPath( cIn )
      IF Len( cOut ) == 0
         RETURN NIL
      ENDIF
      RETURN cOut
   ENDIF
   cRootN := LinkNormPath( cRoot )
   IF Len( cRootN ) == 0 .OR. ! LinkIsAbs( cRootN ) .OR. LinkIsRoot( cRootN )
      RETURN NIL
   ENDIF
   IF cIn == "." .OR. cIn == ".."
      RETURN NIL
   ENDIF
   /* a rooted name without a drive ("\x") is ambiguous: refused */
   IF Left( cIn, 1 ) == "\" .AND. ! ( Left( cIn, 2 ) == "\\" )
      RETURN NIL
   ENDIF
   IF Len( cIn ) == 0
      cOut := cRootN
   ELSEIF LinkIsAbs( cIn )
      cOut := LinkNormPath( cIn )
   ELSE
      cOut := LinkNormPath( LinkJoinDir( cRootN, cIn ) )
   ENDIF
   IF Len( cOut ) == 0
      RETURN NIL
   ENDIF
   /* containment on whole components, case-insensitively */
   cRU := Upper( cRootN )
   cOU := Upper( cOut )
   cSep := iif( Right( cRU, 1 ) == "\", "", "\" )
   IF ! ( cOU == cRU ) .AND. ! ( Left( cOU, Len( cRU ) + Len( cSep ) ) == cRU + cSep )
      RETURN NIL
   ENDIF
   IF LinkIsRoot( cOut )
      RETURN NIL
   ENDIF
RETURN cOut

/* parent of a normalised path, without a trailing separator (a root is its own
 * parent, so walking up can never leave the drive) */
STATIC FUNCTION LinkParentOf( cPath )
   LOCAL c := AllTrim( cPath ), n
   IF Len( c ) > 3 .AND. Right( c, 1 ) == "\"
      c := Left( c, Len( c ) - 1 )
   ENDIF
   n := Rat( "\", c )
   IF n > 1
      RETURN Left( c, n - 1 )
   ENDIF
   IF n == 1
      RETURN Left( c, 1 )
   ENDIF
RETURN c

/* =====================================================================
 *  2. PROTOCOL - directory entries and listing
 * ===================================================================== */

/* one entry out of one element of hb_vfDirectory(), the exact shape and slot
 * order of HcEntryNew() in bp_hc.prg: { name, size, date, attr, .F., time }.
 * The "T" timestamp is reduced to its Date so a local entry and one that came
 * over the wire are identical. */
FUNCTION LinkEntryNew( aRaw )
   LOCAL xDate := NIL, cAttr := "A", xTime := NIL
   IF ! HB_ISARRAY( aRaw ) .OR. Len( aRaw ) < 1
      RETURN { "", 0, NIL, "A", .F., NIL }
   ENDIF
   IF Len( aRaw ) >= 3
      xDate := aRaw[ 3 ]
      IF ValType( xDate ) == "T"
         xDate := hb_TToD( xDate )
      ENDIF
   ENDIF
   IF Len( aRaw ) >= 5
      cAttr := aRaw[ 5 ]
   ENDIF
   IF Len( aRaw ) >= 4
      xTime := aRaw[ 4 ]
   ENDIF
RETURN { aRaw[ 1 ], iif( Len( aRaw ) >= 2, aRaw[ 2 ], 0 ), xDate, cAttr, .F., xTime }

/* sort key of a listing: `..` above everything, then the directories, then the
 * files, every group by name and case-insensitively. PURE. */
STATIC FUNCTION LinkEntryKey( aEntry )
   LOCAL cName, cAttr
   IF ! HB_ISARRAY( aEntry ) .OR. Len( aEntry ) < LE_NAME
      RETURN "3"
   ENDIF
   cName := iif( ValType( aEntry[ LE_NAME ] ) == "C", aEntry[ LE_NAME ], "" )
   cAttr := iif( Len( aEntry ) >= LE_ATTR .AND. ValType( aEntry[ LE_ATTR ] ) == "C", ;
                 aEntry[ LE_ATTR ], "A" )
   IF cName == ".."
      RETURN "0"
   ENDIF
RETURN iif( "D" $ Upper( cAttr ), "1", "2" ) + Upper( cName )

/* the date of an entry as the 8 digits of the wire ("YYYYMMDD") */
STATIC FUNCTION LinkDate8( xDate )
   LOCAL d := xDate
   IF ValType( d ) == "T"
      d := hb_TToD( d )
   ENDIF
   IF ValType( d ) != "D" .OR. Empty( d )
      RETURN ""
   ENDIF
RETURN StrZero( Year( d ), 4 ) + StrZero( Month( d ), 2 ) + StrZero( Day( d ), 2 )

/* one entry as the single wire line `name|size|date|time|attr`. "|" cannot
 * appear in a Windows file name, so it is a safe separator. */
FUNCTION LinkEntryLine( aEntry )
   LOCAL cTime
   IF ! HB_ISARRAY( aEntry ) .OR. Len( aEntry ) < LE_NAME
      RETURN ""
   ENDIF
   cTime := iif( Len( aEntry ) >= LE_TIME .AND. ValType( aEntry[ LE_TIME ] ) == "C", ;
                 aEntry[ LE_TIME ], "" )
RETURN LinkArgText( aEntry[ LE_NAME ] ) + "|" + ;
       LinkArgText( iif( Len( aEntry ) >= LE_SIZE, aEntry[ LE_SIZE ], 0 ) ) + "|" + ;
       LinkDate8( iif( Len( aEntry ) >= LE_DATE, aEntry[ LE_DATE ], NIL ) ) + "|" + ;
       cTime + "|" + ;
       LinkArgText( iif( Len( aEntry ) >= LE_ATTR, aEntry[ LE_ATTR ], "A" ) )

/* the entry of a wire line (the inverse of LinkEntryLine()), or NIL when the
 * line is not one. PURE. */
FUNCTION LinkParseEntry( cLine )
   LOCAL aF, cDate, nDate := 0
   IF ValType( cLine ) != "C" .OR. Len( cLine ) == 0
      RETURN NIL
   ENDIF
   aF := LinkSplit( cLine, "|" )
   IF Len( aF ) != 5 .OR. Len( aF[ 1 ] ) == 0
      RETURN NIL
   ENDIF
   cDate := aF[ 3 ]
   IF Len( cDate ) == 8 .AND. LinkAllDigits( cDate )
      nDate := Val( cDate )
   ENDIF
RETURN { aF[ 1 ], ;
         iif( LinkAllDigits( aF[ 2 ] ), Val( aF[ 2 ] ), 0 ), ;
         iif( nDate > 0, SToD( cDate ), NIL ), ;
         iif( Len( aF[ 5 ] ) == 0, "A", aF[ 5 ] ), ;
         .F., ;
         aF[ 4 ] }

/* `..` above everything, then the directories and the files by name, both
 * case-insensitively: the same order for every page of a batched read. */
STATIC FUNCTION LinkSortEntries( aList )
   IF HB_ISARRAY( aList ) .AND. Len( aList ) > 1
      ASort( aList, 1, Len( aList ), {| x, y | LinkEntryKey( x ) < LinkEntryKey( y ) } )
   ENDIF
RETURN aList

/* Listing of <cDir> (a wire path, confined with LinkSafePath()) in pages:
 * answers { nTotal, aEntries } where aEntries is the page that starts at the 1
 * based <nStart>, or NIL when the path escapes the root or is not a directory.
 * Every entry has the shape of LinkEntryNew(). */
FUNCTION LinkListDir( cRoot, cDir, nStart, nCount )
   LOCAL cFull, aRaw, aAll := {}, aPage := {}, i, aE, nTotal, nFrom, nTo
   cFull := LinkSafePath( cRoot, cDir )
   IF cFull == NIL .OR. ! hb_DirExists( cFull )
      RETURN NIL
   ENDIF
   aRaw := hb_vfDirectory( LinkDirArg( cFull ), "HSD" )
   IF ! HB_ISARRAY( aRaw )
      aRaw := {}
   ENDIF
   FOR i := 1 TO Len( aRaw )
      aE := aRaw[ i ]
      IF ValType( aE[ 1 ] ) == "C" .AND. aE[ 1 ] == "."
         /* "." is the directory itself: never listed */
      ELSE
         /* `..` is listed like any other directory, as HcReadDir() does */
         AAdd( aAll, LinkEntryNew( aE ) )
      ENDIF
   NEXT
   LinkSortEntries( aAll )
   nTotal := Len( aAll )
   nFrom := Max( 1, iif( ValType( nStart ) == "N", nStart, 1 ) )
   nTo := iif( ValType( nCount ) == "N", nCount, nTotal )
   nTo := Min( nTotal, nFrom + Max( 0, nTo ) - 1 )
   FOR i := nFrom TO nTo
      AAdd( aPage, aAll[ i ] )
   NEXT
RETURN { nTotal, aPage }

/* { kind, size, date, time, attr } of one path inside the root, or NIL when it
 * escapes or does not exist. kind is "D" for a directory and "F" for a file. */
FUNCTION LinkStat( cRoot, cPath )
   LOCAL cFull, aRaw, aE, i, cParent, cName
   cFull := LinkSafePath( cRoot, cPath )
   IF cFull == NIL
      RETURN NIL
   ENDIF
   IF hb_DirExists( cFull )
      RETURN { "D", 0, NIL, "", "D" }
   ENDIF
   IF ! hb_vfExists( cFull )
      RETURN NIL
   ENDIF
   cParent := LinkParentOf( cFull )
   cName := SubStr( cFull, Len( cParent ) + 2 )
   aRaw := hb_vfDirectory( LinkDirArg( cParent ), "HSD" )
   IF HB_ISARRAY( aRaw )
      FOR i := 1 TO Len( aRaw )
         aE := aRaw[ i ]
         IF ValType( aE[ 1 ] ) == "C" .AND. Upper( aE[ 1 ] ) == Upper( cName )
            aE := LinkEntryNew( aE )
            RETURN { "F", aE[ LE_SIZE ], aE[ LE_DATE ], aE[ LE_TIME ], aE[ LE_ATTR ] }
         ENDIF
      NEXT
   ENDIF
RETURN { "F", hb_vfSize( cFull ), NIL, "", "A" }

/* =====================================================================
 *  2. PROTOCOL - addresses (S5)
 * ===================================================================== */

/* Parses `host:port`, `host` and a bare IPv4 address. Answers { cHost, nPort }
 * or NIL on garbage. Without a port the default LINK_PORT is used; a literal
 * IPv6 address is not supported (it carries more than one colon). */
FUNCTION LinkSplitAddr( cText )
   LOCAL c, nAt, cHost, cPort, nPort, i
   IF ValType( cText ) != "C"
      RETURN NIL
   ENDIF
   c := AllTrim( cText )
   IF Len( c ) == 0
      RETURN NIL
   ENDIF
   nAt := At( ":", c )
   DO CASE
   CASE nAt == 0
      cHost := c
      nPort := LINK_PORT
   CASE At( ":", SubStr( c, nAt + 1 ) ) > 0
      /* more than one colon: an IPv6 literal this protocol does not address,
       * or plain garbage */
      RETURN NIL
   OTHERWISE
      cHost := AllTrim( Left( c, nAt - 1 ) )
      cPort := AllTrim( SubStr( c, nAt + 1 ) )
      IF ! LinkAllDigits( cPort )
         RETURN NIL
      ENDIF
      nPort := Val( cPort )
   ENDCASE
   IF Len( cHost ) == 0 .OR. Len( cHost ) > 255
      RETURN NIL
   ENDIF
   IF " " $ cHost .OR. Chr( 9 ) $ cHost
      RETURN NIL
   ENDIF
   /* letters, digits, '.' '-' and '_' : anything else is not a host */
   FOR i := 1 TO Len( cHost )
      IF ! ( SubStr( cHost, i, 1 ) $ "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-_" )
         RETURN NIL
      ENDIF
   NEXT
   IF nPort < 1 .OR. nPort > 65535
      RETURN NIL
   ENDIF
RETURN { cHost, nPort }

/* =====================================================================
 *  3. SERVER (Slave)
 * ===================================================================== */

/* number of clients the Slave has open right now */
FUNCTION LinkSessionCount()
RETURN Len( s_aLinkSess )

/* peer of the session <n> as "ip:port" ("" when there is no session) */
FUNCTION LinkSessionPeer( n )
   IF ValType( n ) != "N" .OR. n < 1 .OR. n > Len( s_aLinkSess )
      RETURN ""
   ENDIF
RETURN s_aLinkSess[ n ][ LS_PEER ]

/* Closes every session of the Slave (used when the Slave mode is turned off
 * and by the tests). A pending PUT is aborted, which leaves the destination
 * untouched (S10). */
FUNCTION LinkCloseAll()
   DO WHILE Len( s_aLinkSess ) > 0
      LinkDropSession( 1 )
   ENDDO
RETURN NIL

/* requests answered by LinkPump() since the program started */
FUNCTION LinkServed()
RETURN s_nLinkServed

/* Serves the Slave for at most <nMs> milliseconds and answers how many
 * requests were answered. ONE accept per pass at most and never a blocking
 * call: <nMs> = 0 is a plain "look once", which is what the Harbour Commander
 * needs between two keystrokes (S9). The call returns as soon as it did some
 * work, so a big transfer needs one call per frame instead of freezing the
 * caller. */
FUNCTION LinkPump( hListen, cRoot, nMs )
   LOCAL nDead, nServed := 0, nPass
   DEFAULT nMs TO 0
   IF ! LinkIsSock( hListen )
      RETURN 0
   ENDIF
   nDead := hb_MilliSeconds() + LinkBudget( nMs )
   DO WHILE .T.
      nPass := LinkPumpPass( hListen, cRoot )
      nServed += nPass
      s_nLinkServed += nPass
      IF nPass > 0
         EXIT
      ENDIF
      IF hb_MilliSeconds() >= nDead
         EXIT
      ENDIF
      LinkSleep( 1 )
   ENDDO
RETURN nServed

STATIC FUNCTION LinkPumpPass( hListen, cRoot )
   LOCAL hNew, aAddr := NIL, i := 1, nServed := 0, lKeep
   /* one pending connection per pass, never waiting for it */
   hNew := LinkSockAccept( hListen, @aAddr, 0 )
   IF LinkIsSock( hNew )
      AAdd( s_aLinkSess, { hNew, "", LinkPeerText( aAddr ), NIL } )
   ENDIF
   DO WHILE i <= Len( s_aLinkSess )
      lKeep := LinkServiceSession( s_aLinkSess[ i ], cRoot, @nServed )
      IF lKeep
         i++
      ELSE
         LinkDropSession( i )
      ENDIF
   ENDDO
RETURN nServed

/* Reads whatever is available (never blocking) and dispatches every complete
 * frame. Answers .T. to keep the session, .F. on EOF, on a socket error or
 * when the session must be dropped. */
STATIC FUNCTION LinkServiceSession( aSess, cRoot, nServed )
   LOCAL hSock := aSess[ LS_SOCK ], cTmp, nRead, nGot := 0, aMsg, lEof := .F.
   LOCAL cBuf := aSess[ LS_BUF ]
   DO WHILE nGot < LINK_CHUNK * 4
      IF hb_socketSelectRead( hSock, 0 ) != 1
         EXIT
      ENDIF
      cTmp := Space( LINK_CHUNK )
      nRead := hb_socketRecv( hSock, @cTmp, LINK_CHUNK, 0, 0 )
      IF ValType( nRead ) != "N" .OR. nRead < 0
         /* socket error: nothing of this session can be trusted */
         RETURN .F.
      ENDIF
      IF nRead == 0
         /* EOF: the peer closed. The bytes that already arrived are still
          * dispatched; a PUT in progress is aborted when the session drops. */
         lEof := .T.
         EXIT
      ENDIF
      cBuf += Left( cTmp, nRead )
      nGot += nRead
   ENDDO
   DO WHILE .T.
      aMsg := LinkTake( @cBuf )
      IF aMsg == NIL
         EXIT
      ENDIF
      LinkHandle( aSess, aMsg[ 1 ], aMsg[ 2 ], cRoot )
      nServed++
   ENDDO
   aSess[ LS_BUF ] := cBuf
RETURN ! lEof

/* closes one session, aborting a pending PUT (the temporary is removed and the
 * destination is left exactly as it was: S10) */
STATIC PROCEDURE LinkDropSession( n )
   LOCAL aSess
   IF n < 1 .OR. n > Len( s_aLinkSess )
      RETURN
   ENDIF
   aSess := s_aLinkSess[ n ]
   LinkPutAbort( aSess )
   LinkClose( aSess[ LS_SOCK ] )
   ADel( s_aLinkSess, n )
   ASize( s_aLinkSess, Len( s_aLinkSess ) - 1 )
RETURN

/* ---- one request ---- */

STATIC PROCEDURE LinkHandle( aSess, aArgs, cBinary, cRoot )
   LOCAL hSock := aSess[ LS_SOCK ], cVerb
   /* a PUT in progress: every frame that arrives is data */
   IF aSess[ LS_PUT ] != NIL
      LinkPutData( aSess, cBinary )
      RETURN
   ENDIF
   IF ! HB_ISARRAY( aArgs ) .OR. Len( aArgs ) < 1
      LinkErr( hSock, LINK_E_BAD, "bad request" )
      RETURN
   ENDIF
   IF ValType( aArgs[ 1 ] ) != "C" .OR. Len( aArgs[ 1 ] ) == 0
      LinkErr( hSock, LINK_E_BAD, "bad request" )
      RETURN
   ENDIF
   cVerb := Upper( aArgs[ 1 ] )
   DO CASE
   CASE cVerb == "HELLO"
      LinkVerbHello( hSock, aArgs, cRoot )
   CASE cVerb == "PING"
      LinkReply( hSock, { "OK", "PONG" }, NIL )
   CASE cVerb == "DRIVES"
      LinkVerbDrives( hSock, aArgs, cRoot )
   CASE cVerb == "LIST"
      LinkVerbList( hSock, aArgs, cRoot )
   CASE cVerb == "STAT"
      LinkVerbStat( hSock, aArgs, cRoot )
   CASE cVerb == "GET"
      LinkVerbGet( hSock, aArgs, cRoot )
   CASE cVerb == "PUT"
      LinkVerbPut( aSess, aArgs, cRoot )
   CASE cVerb == "MKDIR"
      LinkVerbMkdir( hSock, aArgs, cRoot )
   CASE cVerb == "RENAME"
      LinkVerbRename( hSock, aArgs, cRoot )
   CASE cVerb == "DELFILE"
      LinkVerbDelFile( hSock, aArgs, cRoot )
   CASE cVerb == "DELTREE"
      LinkVerbDelTree( hSock, aArgs, cRoot )
   OTHERWISE
      LinkErr( hSock, LINK_E_BAD, "unknown verb " + Left( cVerb, 32 ) )
   ENDCASE
RETURN

/* HELLO <nVersion> -> OK <cName> <nVersion> <cStartDir> <cScopeTop> (S7/S12).
 * <cStartDir> is the absolute directory a Master starts in and <cScopeTop> is
 * the top of the exported scope ("" when the whole disk is exported and there
 * is nothing to stop the climb: S14). */
STATIC PROCEDURE LinkVerbHello( hSock, aArgs, cRoot )
   LOCAL nVer
   IF Len( aArgs ) < 2 .OR. ! LinkAllDigits( aArgs[ 2 ] )
      LinkErr( hSock, LINK_E_BAD, "bad request" )
      RETURN
   ENDIF
   nVer := Val( aArgs[ 2 ] )
   IF nVer != LINK_VERSION
      LinkErr( hSock, LINK_E_VERSION, "protocol mismatch" )
      RETURN
   ENDIF
   LinkReply( hSock, { "OK", LinkServerName(), LinkIntToStr( LINK_VERSION ), ;
                       LinkScopeStart( cRoot ), LinkScopeTop( cRoot ) }, NIL )
RETURN

/* the absolute directory a Master starts in: the exported folder itself, or the
 * working directory of this machine when the whole disk is exported. PURE. */
STATIC FUNCTION LinkScopeStart( cRoot )
   IF LinkIsDiskScope( cRoot )
      RETURN LinkNormPath( hb_cwd() )
   ENDIF
RETURN LinkNormPath( cRoot )

/* the top of the exported scope: the folder (a Master never climbs above it),
 * or "" when the whole disk is exported. PURE. */
STATIC FUNCTION LinkScopeTop( cRoot )
   IF LinkIsDiskScope( cRoot )
      RETURN ""
   ENDIF
RETURN LinkNormPath( cRoot )

/* DRIVES -> OK and one line per drive of the Slave ("C:"), the same separator
 * style as LIST. It is what Alt-F1/Alt-F2 list on a linked panel (S15), so a
 * Master can jump to a drive of the peer that the served folder does not show.
 * Nothing is confined here: a drive list carries no path. */
STATIC PROCEDURE LinkVerbDrives( hSock, aArgs, cRoot )
   LOCAL aDrv := LinkDrives(), aOut := { "OK" }, i
   FOR i := 1 TO Len( aDrv )
      AAdd( aOut, LinkArgText( aDrv[ i ] ) )
   NEXT
   LinkReply( hSock, aOut, NIL )
RETURN

/* LIST <cPath> <nStart> <nCount> -> OK <nTotal> and one `name|size|date|time|
 * attr` line per entry of the page */
STATIC PROCEDURE LinkVerbList( hSock, aArgs, cRoot )
   LOCAL cPath, aRes, aOut, i, nStart, nCount
   IF Len( aArgs ) < 2
      LinkErr( hSock, LINK_E_BAD, "bad request" )
      RETURN
   ENDIF
   cPath := LinkFromWire( aArgs[ 2 ] )
   IF LinkSafePath( cRoot, cPath ) == NIL
      LinkErr( hSock, LINK_E_OUTSIDE, "path outside the served root" )
      RETURN
   ENDIF
   nStart := iif( Len( aArgs ) >= 3 .AND. LinkAllDigits( aArgs[ 3 ] ), Val( aArgs[ 3 ] ), 1 )
   nCount := iif( Len( aArgs ) >= 4 .AND. LinkAllDigits( aArgs[ 4 ] ), ;
                  Val( aArgs[ 4 ] ), LINK_PAGE_MAX )
   nCount := Min( nCount, LINK_PAGE_MAX )
   aRes := LinkListDir( cRoot, cPath, nStart, nCount )
   IF aRes == NIL
      LinkErr( hSock, LINK_E_NOTFOUND, "not found" )
      RETURN
   ENDIF
   aOut := { "OK", LinkIntToStr( aRes[ 1 ] ) }
   FOR i := 1 TO Len( aRes[ 2 ] )
      AAdd( aOut, LinkEntryLine( aRes[ 2 ][ i ] ) )
   NEXT
   LinkReply( hSock, aOut, NIL )
RETURN

/* STAT <cPath> -> OK <kind> <size> <date> <time> <attr> */
STATIC PROCEDURE LinkVerbStat( hSock, aArgs, cRoot )
   LOCAL cPath, aSt
   IF Len( aArgs ) < 2
      LinkErr( hSock, LINK_E_BAD, "bad request" )
      RETURN
   ENDIF
   cPath := LinkFromWire( aArgs[ 2 ] )
   IF LinkSafePath( cRoot, cPath ) == NIL
      LinkErr( hSock, LINK_E_OUTSIDE, "path outside the served root" )
      RETURN
   ENDIF
   aSt := LinkStat( cRoot, cPath )
   IF aSt == NIL
      LinkErr( hSock, LINK_E_NOTFOUND, "not found" )
      RETURN
   ENDIF
   LinkReply( hSock, { "OK", aSt[ 1 ], LinkIntToStr( aSt[ 2 ] ), LinkDate8( aSt[ 3 ] ), ;
                       iif( ValType( aSt[ 4 ] ) == "C", aSt[ 4 ], "" ), ;
                       iif( ValType( aSt[ 5 ] ) == "C", aSt[ 5 ], "A" ) }, NIL )
RETURN

/* GET <cPath> <nOffset> <nCount> -> OK <nBytes> and then ONE binary frame with
 * exactly those bytes. At most LINK_CHUNK bytes per call: the Master advances
 * with <nOffset>, so a big file is read in chunks and no frame grows. */
STATIC PROCEDURE LinkVerbGet( hSock, aArgs, cRoot )
   LOCAL cFull, nOffset, nCount, cBuf, nRead, nHandle
   IF Len( aArgs ) < 4
      LinkErr( hSock, LINK_E_BAD, "bad request" )
      RETURN
   ENDIF
   cFull := LinkSafePath( cRoot, LinkFromWire( aArgs[ 2 ] ) )
   IF cFull == NIL
      LinkErr( hSock, LINK_E_OUTSIDE, "path outside the served root" )
      RETURN
   ENDIF
   IF hb_DirExists( cFull )
      LinkErr( hSock, LINK_E_CONFLICT, "is a directory" )
      RETURN
   ENDIF
   IF ! hb_vfExists( cFull )
      LinkErr( hSock, LINK_E_NOTFOUND, "not found" )
      RETURN
   ENDIF
   nOffset := iif( LinkAllDigits( aArgs[ 3 ] ), Val( aArgs[ 3 ] ), 0 )
   nCount := iif( LinkAllDigits( aArgs[ 4 ] ), Val( aArgs[ 4 ] ), LINK_CHUNK )
   nOffset := Max( 0, nOffset )
   nCount := Max( 0, Min( nCount, LINK_CHUNK ) )
   nHandle := FOpen( cFull, FO_READ )
   IF nHandle < 0
      LinkErr( hSock, LINK_E_IO, "cannot read the file" )
      RETURN
   ENDIF
   IF nOffset > 0
      FSeek( nHandle, nOffset )
   ENDIF
   cBuf := Space( nCount )
   nRead := FRead( nHandle, @cBuf, nCount )
   FClose( nHandle )
   IF ValType( nRead ) != "N" .OR. nRead < 0
      LinkErr( hSock, LINK_E_IO, "cannot read the file" )
      RETURN
   ENDIF
   LinkReply( hSock, { "OK", LinkIntToStr( nRead ) }, NIL )
   IF nRead > 0
      LinkReply( hSock, {}, Left( cBuf, nRead ) )
   ENDIF
RETURN

/* PUT <cPath> <nTotal> -> OK <nOffset> and then raw binary frames until the
 * total arrives. The bytes go to <dest>.$$$ and the destination is only
 * replaced at the very end (S10); the answer to the last chunk is
 * `OK <nWritten>`. */
STATIC PROCEDURE LinkVerbPut( aSess, aArgs, cRoot )
   LOCAL hSock := aSess[ LS_SOCK ], cFull, cTmp, nTotal, nHandle
   IF Len( aArgs ) < 3 .OR. ! LinkAllDigits( aArgs[ 3 ] )
      LinkErr( hSock, LINK_E_BAD, "bad request" )
      RETURN
   ENDIF
   cFull := LinkSafePath( cRoot, LinkFromWire( aArgs[ 2 ] ) )
   IF cFull == NIL
      LinkErr( hSock, LINK_E_OUTSIDE, "path outside the served root" )
      RETURN
   ENDIF
   IF hb_DirExists( cFull )
      LinkErr( hSock, LINK_E_CONFLICT, "is a directory" )
      RETURN
   ENDIF
   IF ! hb_DirExists( LinkParentOf( cFull ) )
      LinkErr( hSock, LINK_E_NOTFOUND, "no such directory" )
      RETURN
   ENDIF
   nTotal := Val( aArgs[ 3 ] )
   IF nTotal < 0 .OR. nTotal > LINK_MAX_FRAME * 1024
      LinkErr( hSock, LINK_E_BAD, "bad request" )
      RETURN
   ENDIF
   cTmp := cFull + LINK_TMP
   IF hb_vfExists( cTmp )
      hb_vfErase( cTmp )
   ENDIF
   nHandle := FCreate( cTmp )
   IF nHandle < 0
      LinkErr( hSock, LINK_E_IO, "cannot create the temporary file" )
      RETURN
   ENDIF
   aSess[ LS_PUT ] := { nHandle, cTmp, cFull, nTotal, 0 }
   LinkReply( hSock, { "OK", "0" }, NIL )
   IF nTotal == 0
      LinkPutFinish( aSess )
   ENDIF
RETURN

/* one chunk of a PUT in progress */
STATIC PROCEDURE LinkPutData( aSess, cData )
   LOCAL aPut := aSess[ LS_PUT ], nLen, nWritten
   IF ValType( cData ) != "C"
      LinkErr( aSess[ LS_SOCK ], LINK_E_BAD, "expected a binary frame" )
      LinkPutAbort( aSess )
      RETURN
   ENDIF
   nLen := Len( cData )
   IF aPut[ LP_DONE ] + nLen > aPut[ LP_TOTAL ]
      LinkErr( aSess[ LS_SOCK ], LINK_E_BAD, "more bytes than announced" )
      LinkPutAbort( aSess )
      RETURN
   ENDIF
   nWritten := FWrite( aPut[ LP_HANDLE ], cData )
   IF ValType( nWritten ) != "N" .OR. nWritten != nLen
      LinkErr( aSess[ LS_SOCK ], LINK_E_IO, "cannot write the temporary file" )
      LinkPutAbort( aSess )
      RETURN
   ENDIF
   aPut[ LP_DONE ] += nWritten
   IF aPut[ LP_DONE ] >= aPut[ LP_TOTAL ]
      LinkPutFinish( aSess )
   ENDIF
RETURN

/* the whole file arrived: close the temporary and replace the destination,
 * which is the only moment the destination is touched (S10) */
STATIC PROCEDURE LinkPutFinish( aSess )
   LOCAL aPut := aSess[ LS_PUT ], nDone
   IF aPut == NIL
      RETURN
   ENDIF
   nDone := aPut[ LP_DONE ]
   FClose( aPut[ LP_HANDLE ] )
   aSess[ LS_PUT ] := NIL
   IF hb_vfExists( aPut[ LP_DEST ] )
      /* hb_vfErase() answers 0 on success, not .T. (measured) */
      hb_vfErase( aPut[ LP_DEST ] )
   ENDIF
   IF hb_vfRename( aPut[ LP_TMP ], aPut[ LP_DEST ] ) != 0
      hb_vfErase( aPut[ LP_TMP ] )
      LinkErr( aSess[ LS_SOCK ], LINK_E_IO, "cannot replace the destination" )
      RETURN
   ENDIF
   LinkReply( aSess[ LS_SOCK ], { "OK", LinkIntToStr( nDone ) }, NIL )
RETURN

/* aborts a PUT in progress: closes and removes the temporary, so the
 * destination stays byte-identical (S10) */
STATIC PROCEDURE LinkPutAbort( aSess )
   LOCAL aPut := aSess[ LS_PUT ]
   IF aPut == NIL
      RETURN
   ENDIF
   aSess[ LS_PUT ] := NIL
   FClose( aPut[ LP_HANDLE ] )
   hb_vfErase( aPut[ LP_TMP ] )
RETURN

STATIC PROCEDURE LinkVerbMkdir( hSock, aArgs, cRoot )
   LOCAL cFull
   IF Len( aArgs ) < 2
      LinkErr( hSock, LINK_E_BAD, "bad request" )
      RETURN
   ENDIF
   cFull := LinkSafePath( cRoot, LinkFromWire( aArgs[ 2 ] ) )
   IF cFull == NIL
      LinkErr( hSock, LINK_E_OUTSIDE, "path outside the served root" )
      RETURN
   ENDIF
   IF hb_DirExists( cFull ) .OR. hb_vfExists( cFull )
      LinkErr( hSock, LINK_E_CONFLICT, "already exists" )
      RETURN
   ENDIF
   IF hb_DirCreate( cFull ) != 0
      LinkErr( hSock, LINK_E_IO, "cannot create the directory" )
      RETURN
   ENDIF
   LinkReply( hSock, { "OK", cFull }, NIL )
RETURN

/* RENAME <cOld> <cNew>, both confined inside the root */
STATIC PROCEDURE LinkVerbRename( hSock, aArgs, cRoot )
   LOCAL cOld, cNew
   IF Len( aArgs ) < 3
      LinkErr( hSock, LINK_E_BAD, "bad request" )
      RETURN
   ENDIF
   cOld := LinkSafePath( cRoot, LinkFromWire( aArgs[ 2 ] ) )
   cNew := LinkSafePath( cRoot, LinkFromWire( aArgs[ 3 ] ) )
   IF cOld == NIL .OR. cNew == NIL
      LinkErr( hSock, LINK_E_OUTSIDE, "path outside the served root" )
      RETURN
   ENDIF
   IF ! hb_vfExists( cOld ) .AND. ! hb_DirExists( cOld )
      LinkErr( hSock, LINK_E_NOTFOUND, "not found" )
      RETURN
   ENDIF
   IF hb_DirExists( cNew ) .OR. ( hb_DirExists( cOld ) .AND. hb_vfExists( cNew ) )
      LinkErr( hSock, LINK_E_CONFLICT, "the destination already exists" )
      RETURN
   ENDIF
   IF ! hb_DirExists( LinkParentOf( cNew ) )
      LinkErr( hSock, LINK_E_NOTFOUND, "no such directory" )
      RETURN
   ENDIF
   /* hb_vfRename() answers 0 on success (measured) */
   IF hb_vfRename( cOld, cNew ) != 0
      LinkErr( hSock, LINK_E_IO, "cannot rename" )
      RETURN
   ENDIF
   LinkReply( hSock, { "OK", cNew }, NIL )
RETURN

STATIC PROCEDURE LinkVerbDelFile( hSock, aArgs, cRoot )
   LOCAL cFull
   IF Len( aArgs ) < 2
      LinkErr( hSock, LINK_E_BAD, "bad request" )
      RETURN
   ENDIF
   cFull := LinkSafePath( cRoot, LinkFromWire( aArgs[ 2 ] ) )
   IF cFull == NIL
      LinkErr( hSock, LINK_E_OUTSIDE, "path outside the served root" )
      RETURN
   ENDIF
   IF hb_DirExists( cFull )
      LinkErr( hSock, LINK_E_CONFLICT, "is a directory" )
      RETURN
   ENDIF
   IF ! hb_vfExists( cFull )
      LinkErr( hSock, LINK_E_NOTFOUND, "not found" )
      RETURN
   ENDIF
   IF hb_vfErase( cFull ) != 0
      LinkErr( hSock, LINK_E_IO, "cannot delete the file" )
      RETURN
   ENDIF
   LinkReply( hSock, { "OK", cFull }, NIL )
RETURN

/* DELTREE <cPath>: the served root is never deleted, and neither is the root
 * of a drive when the whole disk is exported (S14) */
STATIC PROCEDURE LinkVerbDelTree( hSock, aArgs, cRoot )
   LOCAL cFull, cRootN
   IF Len( aArgs ) < 2
      LinkErr( hSock, LINK_E_BAD, "bad request" )
      RETURN
   ENDIF
   cFull := LinkSafePath( cRoot, LinkFromWire( aArgs[ 2 ] ) )
   IF cFull == NIL
      LinkErr( hSock, LINK_E_OUTSIDE, "path outside the served root" )
      RETURN
   ENDIF
   /* the served root itself is never deleted */
   cRootN := LinkNormPath( cRoot )
   IF ! LinkIsDiskScope( cRoot ) .AND. Upper( cFull ) == Upper( cRootN )
      LinkErr( hSock, LINK_E_OUTSIDE, "path outside the served root" )
      RETURN
   ENDIF
   /* a drive root (or the root of a UNC share) is a place, not an entry */
   IF LinkIsRoot( cFull )
      LinkErr( hSock, LINK_E_OUTSIDE, "path outside the served root" )
      RETURN
   ENDIF
   IF ! hb_DirExists( cFull )
      LinkErr( hSock, LINK_E_NOTFOUND, "not found" )
      RETURN
   ENDIF
   IF ! hb_DirRemoveAll( cFull )
      LinkErr( hSock, LINK_E_IO, "cannot delete the directory" )
      RETURN
   ENDIF
   LinkReply( hSock, { "OK", cFull }, NIL )
RETURN

/* ---- replies ---- */

STATIC PROCEDURE LinkErr( hSock, nCode, cText )
   LinkReply( hSock, { "ERR", LinkIntToStr( nCode ), cText }, NIL )
RETURN

/* sends one reply; the caller never sees a timeout of -1 */
STATIC PROCEDURE LinkReply( hSock, aArgs, cBinary )
   LinkSendAll( hSock, LinkFrame( aArgs, cBinary ), LINK_TIMEOUT_DEF )
RETURN

STATIC FUNCTION LinkSendAll( hSock, cData, nMs )
   LOCAL nSent := 0, nLen := Len( cData ), n
   IF ! LinkIsSock( hSock ) .OR. nLen == 0
      RETURN 0
   ENDIF
   DO WHILE nSent < nLen
      /* in slices, so one send never has to fit a whole 64 KB chunk plus its
       * header in the socket buffer, and so a peer pump gets turns in
       * between (LinkPumpHook()) */
      n := LinkSockSend( hSock, SubStr( cData, nSent + 1 ), Min( LINK_TX_SLICE, nLen - nSent ), ;
                          LinkBudget( nMs ) )
      IF ValType( n ) != "N" .OR. n <= 0
         RETURN -1
      ENDIF
      nSent += n
      LinkPumpHook()
   ENDDO
RETURN nSent

/* =====================================================================
 *  3. CLIENT (Master)
 * ===================================================================== */

/* Sends one frame and answers the bytes written, or -1 on failure. */
FUNCTION LinkSendFrame( hSock, aArgs, cBinary, nMs )
   DEFAULT nMs TO LINK_TIMEOUT_DEF
RETURN LinkSendAll( hSock, LinkFrame( aArgs, cBinary ), nMs )

/* Waits for the next reply frame (without sending anything) and answers its
 * arguments, with the payload of a binary frame appended as the last element,
 * so a binary reply is never confused with an empty text reply. NIL on EOF, on
 * a socket error or when the budget runs out. */
FUNCTION LinkAwait( hSock, nMs )
   LOCAL cBuf, nDead, aMsg
   DEFAULT nMs TO LINK_TIMEOUT_DEF
   IF ! LinkIsSock( hSock )
      RETURN NIL
   ENDIF
   nDead := hb_MilliSeconds() + LinkBudget( nMs )
   /* the bytes that arrived with the previous frame and were not consumed yet
    * live in the per socket buffer: a single recv() can bring two frames */
   cBuf := LinkGetBuf( hSock )
   DO WHILE .T.
      aMsg := LinkTake( @cBuf )
      IF aMsg != NIL
         LinkSetBuf( hSock, cBuf )
         IF Len( aMsg[ 2 ] ) > 0
            AAdd( aMsg[ 1 ], aMsg[ 2 ] )
         ENDIF
         RETURN aMsg[ 1 ]
      ENDIF
      IF ! LinkReadMore( hSock, @cBuf, nDead )
         LinkSetBuf( hSock, cBuf )
         RETURN NIL
      ENDIF
   ENDDO
RETURN NIL

/* One request and its reply: sends <aArgs> and answers the reply arguments, or
 * NIL on failure/timeout. aReply[ 1 ] is "OK" or "ERR".
 *
 * GET is the one verb whose reply has a body: the server sends the text reply
 * {"OK", nBytes} and then one binary frame, so the bytes come back appended as
 * the last element of the returned array ({"OK", nBytes, cBytes}). */
FUNCTION LinkRequest( hSock, aArgs, nMs )
   LOCAL aReply, aBody, nDead
   DEFAULT nMs TO LINK_TIMEOUT_DEF
   nDead := hb_MilliSeconds() + LinkBudget( nMs )
   IF LinkSendFrame( hSock, aArgs, NIL, nMs ) < 0
      RETURN NIL
   ENDIF
   aReply := LinkAwait( hSock, LinkRemain( nDead ) )
   IF aReply == NIL
      RETURN NIL
   ENDIF
   IF HB_ISARRAY( aArgs ) .AND. Len( aArgs ) >= 1 .AND. ValType( aArgs[ 1 ] ) == "C" .AND. ;
      Upper( aArgs[ 1 ] ) == "GET" .AND. aReply[ 1 ] == "OK"
      aBody := LinkAwait( hSock, LinkRemain( nDead ) )
      IF HB_ISARRAY( aBody ) .AND. Len( aBody ) > 0
         AAdd( aReply, aBody[ Len( aBody ) ] )
      ENDIF
   ENDIF
RETURN aReply

/* =====================================================================
 *  3b. MASTER SESSION (T4)
 *
 * The facade bp_hc.prg talks to: it never sees the protocol. Every call takes
 * its own millisecond budget and never blocks longer than that IN TOTAL (the
 * remaining budget travels to each of the round trips it needs), and none of
 * them draws, prints or waits on a key: all the decisions are testable without
 * a window.
 *
 * The paths that travel are ABSOLUTE paths of the peer (S14/L7), so a Master
 * works on the same strings the Slave sends: no relative form has to be built
 * or undone anywhere. "cErr" is an output parameter: the call site writes
 * `@cErr` and gets the reason of a failure in English, or "" when it worked.
 * ===================================================================== */

/* Installs (or removes, with NIL) the block this module calls WHILE a Master
 * call waits for its Slave. It is how the bank drives a Master against a Slave
 * that lives in the same process - nothing else can pump the listener while a
 * request is in flight - and it also lets a program that is Master and Slave at
 * once serve its own listener from inside its own wait.
 * The block must only LOOK once (a LinkPump() with no budget): it is never
 * allowed to wait, and the module never calls it from inside itself. Answers
 * the previous hook. */
FUNCTION LinkSetPumpHook( bHook )
   LOCAL bOld := s_bLinkPump
   IF ValType( bHook ) == "B" .OR. ValType( bHook ) == "U"
      s_bLinkPump := bHook
   ENDIF
RETURN bOld

/* Opens a Master session with <cHost>:<nPort>: connects (LinkConnect()) and
 * performs the HELLO handshake. Answers { hSocket, cStartDir, cServerName,
 * cScopeTop } or NIL, and <cErr> carries the reason (an address that does not
 * answer, a refused connection, `ERR 426 protocol mismatch`, ...).
 *
 * <cStartDir> is the ABSOLUTE directory the Slave serves from and <cScopeTop>
 * the top of the scope it exported ("" when that is the whole disk): the panel
 * starts in the first and `..` never climbs above the second (S14/L7). */
FUNCTION LinkRemoteOpen( cHost, nPort, nMs, cErr )
   LOCAL aCon, hSock, aReply, nDead
   DEFAULT nMs TO LINK_TIMEOUT_DEF
   cErr := ""
   nDead := hb_MilliSeconds() + LinkBudget( nMs )
   aCon := LinkConnect( cHost, nPort, LinkRemain( nDead ) )
   IF ! LinkIsSock( aCon[ 1 ] )
      cErr := aCon[ 2 ]
      RETURN NIL
   ENDIF
   hSock := aCon[ 1 ]
   aReply := LinkRequest( hSock, { "HELLO", LinkIntToStr( LINK_VERSION ) }, LinkRemain( nDead ) )
   IF ! HB_ISARRAY( aReply )
      cErr := "no answer from the Slave"
      LinkClose( hSock )
      RETURN NIL
   ENDIF
   IF ! ( aReply[ 1 ] == "OK" )
      cErr := LinkErrText( aReply )
      LinkClose( hSock )
      RETURN NIL
   ENDIF
   IF Len( aReply ) < 5
      cErr := "bad handshake from the Slave"
      LinkClose( hSock )
      RETURN NIL
   ENDIF
RETURN { hSock, aReply[ 4 ], aReply[ 2 ], aReply[ 5 ] }

/* Listing of the ABSOLUTE remote directory <cPath> in the shape LinkEntryNew()
 * produces (the exact shape of HcEntryNew(), so the panel does not have to
 * convert anything). It pages on its own with LIST <path> <nStart> <nCount>: a
 * big directory is never one giant frame. An empty directory answers an EMPTY
 * ARRAY, never NIL; NIL means failure and then <cErr> tells why.
 * The `..` row of a filesystem listing is NOT part of the answer: the panel
 * builds its own `..` from the path it is showing (a bare `..` would be refused
 * by the confinement of S11 anyway). What is left is exactly the entries that
 * live in the directory. */
FUNCTION LinkRemoteList( hSock, cPath, nMs, cErr )
   LOCAL aOut := {}, aReply, aE, i, nStart := 1, nTotal := 0, nGot, cWire, nDead
   DEFAULT nMs TO LINK_TIMEOUT_DEF
   cErr := ""
   cWire := LinkWirePath( cPath )
   nDead := hb_MilliSeconds() + LinkBudget( nMs )
   DO WHILE .T.
      aReply := LinkRequest( hSock, { "LIST", cWire, LinkIntToStr( nStart ), ;
                                     LinkIntToStr( LINK_LIST_PAGE ) }, LinkRemain( nDead ) )
      IF ! HB_ISARRAY( aReply )
         cErr := "no answer from the Slave"
         RETURN NIL
      ENDIF
      IF ! ( aReply[ 1 ] == "OK" )
         cErr := LinkErrText( aReply )
         RETURN NIL
      ENDIF
      nTotal := iif( Len( aReply ) >= 2 .AND. LinkAllDigits( aReply[ 2 ] ), Val( aReply[ 2 ] ), 0 )
      nGot := 0
      FOR i := 3 TO Len( aReply )
         aE := LinkParseEntry( aReply[ i ] )
         IF aE != NIL
            nGot++
            IF ! ( aE[ LE_NAME ] == ".." )
               AAdd( aOut, aE )
            ENDIF
         ENDIF
      NEXT
      /* the page tells how many entries the SERVER listed, which is not how
       * many came back (`..` does not): the offset advances by the former.
       * An empty page, or a page that already reached the total, ends it. */
      IF nGot == 0
         EXIT
      ENDIF
      nStart += nGot
      IF nStart > nTotal
         EXIT
      ENDIF
      IF hb_MilliSeconds() >= nDead
         cErr := "timeout"
         RETURN NIL
      ENDIF
   ENDDO
RETURN aOut

/* { kind, size, date, time, attr } of one ABSOLUTE remote path ("D" for a
 * directory and "F" for a file), or NIL with <cErr> set. */
FUNCTION LinkRemoteStat( hSock, cPath, nMs, cErr )
   LOCAL aReply
   DEFAULT nMs TO LINK_TIMEOUT_DEF
   cErr := ""
   aReply := LinkRequest( hSock, { "STAT", LinkWirePath( cPath ) }, LinkBudget( nMs ) )
   IF ! HB_ISARRAY( aReply )
      cErr := "no answer from the Slave"
      RETURN NIL
   ENDIF
   IF ! ( aReply[ 1 ] == "OK" )
      cErr := LinkErrText( aReply )
      RETURN NIL
   ENDIF
   IF Len( aReply ) < 6
      cErr := "bad STAT reply"
      RETURN NIL
   ENDIF
RETURN { aReply[ 2 ], ;
         iif( LinkAllDigits( aReply[ 3 ] ), Val( aReply[ 3 ] ), 0 ), ;
         iif( Len( aReply[ 4 ] ) == 8 .AND. LinkAllDigits( aReply[ 4 ] ), ;
              SToD( aReply[ 4 ] ), NIL ), ;
         aReply[ 5 ], aReply[ 6 ] }

/* The drives of the SLAVE as "C:" strings, or NIL with <cErr> set: what
 * Alt-F1/Alt-F2 list on a linked panel (S15). An empty answer is an empty
 * array, never NIL. */
FUNCTION LinkRemoteDrives( hSock, nMs, cErr )
   LOCAL aReply, aOut := {}, i
   DEFAULT nMs TO LINK_TIMEOUT_DEF
   cErr := ""
   aReply := LinkRequest( hSock, { "DRIVES" }, LinkBudget( nMs ) )
   IF ! HB_ISARRAY( aReply )
      cErr := "no answer from the Slave"
      RETURN NIL
   ENDIF
   IF ! ( aReply[ 1 ] == "OK" )
      cErr := LinkErrText( aReply )
      RETURN NIL
   ENDIF
   FOR i := 2 TO Len( aReply )
      IF ValType( aReply[ i ] ) == "C" .AND. Len( AllTrim( aReply[ i ] ) ) > 0
         AAdd( aOut, AllTrim( aReply[ i ] ) )
      ENDIF
   NEXT
RETURN aOut

/* size in bytes of one remote FILE, or -1 when it is not one (a directory) or
 * cannot be asked: it is the total of the copy progress. */
FUNCTION LinkRemoteSize( hSock, cPath, nMs, cErr )
   LOCAL aSt
   DEFAULT nMs TO LINK_TIMEOUT_DEF
   aSt := LinkRemoteStat( hSock, cPath, nMs, cErr )
   IF aSt == NIL .OR. ! ( aSt[ 1 ] == "F" )
      RETURN -1
   ENDIF
RETURN aSt[ 2 ]

/* Downloads <cRelPath> into the LOCAL file <cLocalFile> with offset driven GET
 * chunks. The local file is written ATOMICALLY, with the pattern of
 * HcCopyOneFile() (bp_hc.prg): the bytes go to <cLocalFile>.$$$ and the
 * destination is only replaced at the very end, so a failure - or a cancel -
 * leaves an existing destination BYTE IDENTICAL and no temporary behind.
 * <bProgress> is {| nDone, nTotal | } or NIL and is called after each chunk: it
 * answers .T. to cancel. Answers { lOk, nBytes } and sets <cErr> ("cancelled"
 * on a cancel). A cancelled download keeps the session: after a GET the Slave
 * holds nothing. */
FUNCTION LinkRemoteGet( hSock, cRelPath, cLocalFile, bProgress, nMs, cErr )
   LOCAL aSt, nTotal, nDone := 0, nHandle, cTmp, aReply, cBody, nWant, nDead
   DEFAULT nMs TO LINK_TIMEOUT_DEF
   cErr := ""
   IF ValType( cLocalFile ) != "C" .OR. Len( AllTrim( cLocalFile ) ) == 0
      cErr := "no local file name"
      RETURN { .F., 0 }
   ENDIF
   nDead := hb_MilliSeconds() + LinkBudget( nMs )
   aSt := LinkRemoteStat( hSock, cRelPath, LinkRemain( nDead ), @cErr )
   IF aSt == NIL
      RETURN { .F., 0 }
   ENDIF
   IF aSt[ 1 ] == "D"
      cErr := "is a directory"
      RETURN { .F., 0 }
   ENDIF
   nTotal := aSt[ 2 ]
   cTmp := cLocalFile + LINK_TMP
   IF hb_vfExists( cTmp )
      hb_vfErase( cTmp )
   ENDIF
   nHandle := FCreate( cTmp )
   IF nHandle < 0
      cErr := "cannot create " + cTmp
      RETURN { .F., 0 }
   ENDIF
   DO WHILE nDone < nTotal
      nWant := Min( LINK_GET_CHUNK, nTotal - nDone )
      aReply := LinkRequest( hSock, { "GET", LinkWirePath( cRelPath ), LinkIntToStr( nDone ), ;
                                     LinkIntToStr( nWant ) }, LinkRemain( nDead ) )
      IF ! HB_ISARRAY( aReply )
         FClose( nHandle )
         hb_vfErase( cTmp )
         cErr := "no answer from the Slave"
         RETURN { .F., nDone }
      ENDIF
      IF ! ( aReply[ 1 ] == "OK" )
         FClose( nHandle )
         hb_vfErase( cTmp )
         cErr := LinkErrText( aReply )
         RETURN { .F., nDone }
      ENDIF
      cBody := iif( Len( aReply ) >= 3 .AND. ValType( aReply[ 3 ] ) == "C", aReply[ 3 ], "" )
      IF Len( cBody ) == 0 .OR. FWrite( nHandle, cBody ) != Len( cBody )
         FClose( nHandle )
         hb_vfErase( cTmp )
         cErr := "cannot write " + cTmp
         RETURN { .F., nDone }
      ENDIF
      nDone += Len( cBody )
      IF LinkCancelled( bProgress, nDone, nTotal )
         FClose( nHandle )
         hb_vfErase( cTmp )
         cErr := "cancelled"
         RETURN { .F., nDone }
      ENDIF
      IF hb_MilliSeconds() >= nDead
         FClose( nHandle )
         hb_vfErase( cTmp )
         cErr := "timeout"
         RETURN { .F., nDone }
      ENDIF
   ENDDO
   FClose( nHandle )
   /* the whole file is on disk: replace the destination with it (S10 in
    * spirit). hb_vfErase()/hb_vfRename() answer 0 on success (measured). */
   IF hb_vfExists( cLocalFile ) .AND. hb_vfErase( cLocalFile ) != 0
      hb_vfErase( cTmp )
      cErr := "cannot replace " + AllTrim( cLocalFile )
      RETURN { .F., nDone }
   ENDIF
   IF hb_vfRename( cTmp, cLocalFile ) != 0
      hb_vfErase( cTmp )
      cErr := "cannot rename " + cTmp
      RETURN { .F., nDone }
   ENDIF
RETURN { .T., nDone }

/* Uploads the LOCAL file <cLocalFile> to <cRelDest> with PUT, reading it in
 * 64 KB chunks (LINK_CHUNK). Same cancellation and error contract as
 * LinkRemoteGet(), and the same atomic write on the far side (S10: the Slave
 * writes <dest>.$$$ and only replaces the destination at the end).
 * There is no CANCEL verb, so a cancel DROPS THE SESSION: that is what makes
 * the Slave abort the PUT and remove its temporary, and it is the only way an
 * interrupted upload can leave the destination untouched. A failure in the
 * middle of the stream drops it too (the Slave is left waiting for bytes). A
 * PUT the Slave refuses up front (404, 403, ...) leaves the session usable, so
 * a refusal is not the end of it. The caller must open a new session after a
 * cancelled (or broken) PUT: LinkRemotePing() answers .F. from then on. */
FUNCTION LinkRemotePut( hSock, cLocalFile, cRelDest, bProgress, nMs, cErr )
   LOCAL nSize, nHandle, cBuf, nRead, nDone := 0, aReply, nDead
   DEFAULT nMs TO LINK_TIMEOUT_DEF
   cErr := ""
   IF ValType( cLocalFile ) != "C" .OR. ! hb_vfExists( cLocalFile )
      cErr := "not found: " + iif( ValType( cLocalFile ) == "C", AllTrim( cLocalFile ), "?" )
      RETURN { .F., 0 }
   ENDIF
   nDead := hb_MilliSeconds() + LinkBudget( nMs )
   nSize := hb_vfSize( cLocalFile )
   IF ValType( nSize ) != "N" .OR. nSize < 0
      nSize := 0
   ENDIF
   aReply := LinkRequest( hSock, { "PUT", LinkWirePath( cRelDest ), LinkIntToStr( nSize ) }, ;
                          LinkRemain( nDead ) )
   IF ! HB_ISARRAY( aReply ) .OR. ! ( aReply[ 1 ] == "OK" )
      cErr := iif( HB_ISARRAY( aReply ), LinkErrText( aReply ), "no answer from the Slave" )
      RETURN { .F., 0 }
   ENDIF
   IF nSize > 0
      nHandle := FOpen( cLocalFile, FO_READ )
      IF nHandle < 0
         /* the Slave is waiting for bytes that will never come: drop it */
         LinkClose( hSock )
         cErr := "cannot open " + AllTrim( cLocalFile )
         RETURN { .F., 0 }
      ENDIF
      cBuf := Space( LINK_CHUNK )
      DO WHILE nDone < nSize
         nRead := FRead( nHandle, @cBuf, Min( LINK_CHUNK, nSize - nDone ) )
         IF ValType( nRead ) != "N" .OR. nRead <= 0
            EXIT
         ENDIF
         IF LinkSendFrame( hSock, {}, Left( cBuf, nRead ), LinkRemain( nDead ) ) < 0
            FClose( nHandle )
            LinkClose( hSock )
            cErr := "cannot send the file"
            RETURN { .F., nDone }
         ENDIF
         nDone += nRead
         IF LinkCancelled( bProgress, nDone, nSize )
            FClose( nHandle )
            LinkClose( hSock )
            cErr := "cancelled"
            RETURN { .F., nDone }
         ENDIF
         IF hb_MilliSeconds() >= nDead
            FClose( nHandle )
            LinkClose( hSock )
            cErr := "timeout"
            RETURN { .F., nDone }
         ENDIF
      ENDDO
      FClose( nHandle )
      IF nDone != nSize
         LinkClose( hSock )
         cErr := "cannot read " + AllTrim( cLocalFile )
         RETURN { .F., nDone }
      ENDIF
   ENDIF
   /* the Slave answers once more when the whole file arrived */
   aReply := LinkAwait( hSock, LinkRemain( nDead ) )
   IF ! HB_ISARRAY( aReply )
      /* the stream is in an unknown state: the session is not usable */
      LinkClose( hSock )
      cErr := "no answer from the Slave"
      RETURN { .F., nDone }
   ENDIF
   IF ! ( aReply[ 1 ] == "OK" )
      cErr := LinkErrText( aReply )
      RETURN { .F., nDone }
   ENDIF
RETURN { .T., nDone }

FUNCTION LinkRemoteMkDir( hSock, cPath, nMs, cErr )
   DEFAULT nMs TO LINK_TIMEOUT_DEF
RETURN LinkRemoteOk( hSock, { "MKDIR", LinkWirePath( cPath ) }, nMs, @cErr )

FUNCTION LinkRemoteRename( hSock, cFrom, cTo, nMs, cErr )
   DEFAULT nMs TO LINK_TIMEOUT_DEF
RETURN LinkRemoteOk( hSock, { "RENAME", LinkWirePath( cFrom ), LinkWirePath( cTo ) }, ;
                     nMs, @cErr )

FUNCTION LinkRemoteDelFile( hSock, cPath, nMs, cErr )
   DEFAULT nMs TO LINK_TIMEOUT_DEF
RETURN LinkRemoteOk( hSock, { "DELFILE", LinkWirePath( cPath ) }, nMs, @cErr )

FUNCTION LinkRemoteDelTree( hSock, cPath, nMs, cErr )
   DEFAULT nMs TO LINK_TIMEOUT_DEF
RETURN LinkRemoteOk( hSock, { "DELTREE", LinkWirePath( cPath ) }, nMs, @cErr )

/* is the session still alive? It asks the Slave, so a dropped connection is
 * reported as .F. instead of waiting for the next request to fail. */
FUNCTION LinkRemotePing( hSock, nMs )
   LOCAL aReply
   DEFAULT nMs TO LINK_TIMEOUT_DEF
   aReply := LinkRequest( hSock, { "PING" }, LinkBudget( nMs ) )
   IF ! HB_ISARRAY( aReply )
      RETURN .F.
   ENDIF
RETURN aReply[ 1 ] == "OK"

/* =====================================================================
 *  4. DISCOVERY (UDP, S4/S8)
 * ===================================================================== */

/* Opens the discovery socket of the Slave (the same port as TCP by default). */
FUNCTION LinkUdpOpen( nPort, cBind )
   LOCAL hSock
   DEFAULT nPort TO LINK_PORT
   DEFAULT cBind TO LINK_ANY
   IF ValType( nPort ) != "N" .OR. nPort < 0 .OR. nPort > 65535
      RETURN NIL
   ENDIF
   hSock := hb_socketOpen( HB_SOCKET_AF_INET, HB_SOCKET_PT_DGRAM, 0 )
   IF ! LinkIsSock( hSock )
      RETURN NIL
   ENDIF
   IF ! hb_socketBind( hSock, { HB_SOCKET_AF_INET, cBind, nPort } )
      hb_socketClose( hSock )
      RETURN NIL
   ENDIF
   hb_socketSetBroadcast( hSock, .T. )
RETURN hSock

/* Answers the HWBRO-DISCOVER/1 datagrams of the LAN for at most <nMs>
 * milliseconds. Answers how many were served; <nMs> = 0 looks once (S9). */
FUNCTION LinkPumpUdp( hUdp, cServerName, nTcpPort, nMs )
   LOCAL nDead, nServed := 0, nPass
   DEFAULT cServerName TO ""
   DEFAULT nTcpPort TO LINK_PORT
   DEFAULT nMs TO 0
   IF ! LinkIsSock( hUdp )
      RETURN 0
   ENDIF
   IF Len( AllTrim( cServerName ) ) == 0
      cServerName := LinkServerName()
   ENDIF
   nDead := hb_MilliSeconds() + LinkBudget( nMs )
   DO WHILE .T.
      nPass := LinkPumpUdpPass( hUdp, cServerName, nTcpPort )
      nServed += nPass
      IF nPass > 0
         EXIT
      ENDIF
      IF hb_MilliSeconds() >= nDead
         EXIT
      ENDIF
      LinkSleep( 1 )
   ENDDO
RETURN nServed

STATIC FUNCTION LinkPumpUdpPass( hUdp, cServerName, nTcpPort )
   LOCAL cBuf, aFrom, nRead, nServed := 0, cText
   DO WHILE hb_socketSelectRead( hUdp, 0 ) == 1
      cBuf := Space( 512 )
      aFrom := NIL
      nRead := hb_socketRecvFrom( hUdp, @cBuf, 512, 0, @aFrom, 0 )
      IF ValType( nRead ) != "N" .OR. nRead <= 0 .OR. ! HB_ISARRAY( aFrom )
         EXIT
      ENDIF
      cText := AllTrim( Left( cBuf, nRead ) )
      IF Left( cText, Len( LINK_DISC_REQ ) ) == LINK_DISC_REQ
         hb_socketSendTo( hUdp, LINK_DISC_RSP + " " + LinkNoSpace( cServerName ) + " " + ;
                          LinkIntToStr( nTcpPort ) + " " + LinkIntToStr( LINK_VERSION ), ;
                          NIL, 0, aFrom, 1000 )
         nServed++
      ENDIF
   ENDDO
RETURN nServed

/* Broadcasts HWBRO-DISCOVER/1 and collects the answers for <nMs>: an array of
 * { cName, cIp, nPort }. The request goes to the broadcast address AND to the
 * loopback, so a Slave running on this same machine is found too. <cTarget>
 * overrides both (the tests point it at 127.0.0.1). */
FUNCTION LinkDiscover( nPort, nMs, cTarget )
   LOCAL hSock, nDead, aOut := {}, cBuf, aFrom, nRead, aReply
   DEFAULT nPort TO LINK_PORT
   DEFAULT nMs TO 800
   DEFAULT cTarget TO ""
   hSock := hb_socketOpen( HB_SOCKET_AF_INET, HB_SOCKET_PT_DGRAM, 0 )
   IF ! LinkIsSock( hSock )
      RETURN aOut
   ENDIF
   hb_socketSetBroadcast( hSock, .T. )
   IF Len( AllTrim( cTarget ) ) > 0
      hb_socketSendTo( hSock, LINK_DISC_REQ, NIL, 0, ;
                       { HB_SOCKET_AF_INET, AllTrim( cTarget ), nPort }, 1000 )
   ELSE
      hb_socketSendTo( hSock, LINK_DISC_REQ, NIL, 0, ;
                       { HB_SOCKET_AF_INET, LINK_BROADCAST, nPort }, 1000 )
      hb_socketSendTo( hSock, LINK_DISC_REQ, NIL, 0, ;
                       { HB_SOCKET_AF_INET, LINK_LOOPBACK, nPort }, 1000 )
   ENDIF
   nDead := hb_MilliSeconds() + LinkBudget( nMs )
   DO WHILE .T.
      IF hb_socketSelectRead( hSock, Max( 0, nDead - hb_MilliSeconds() ) ) == 1
         cBuf := Space( 512 )
         aFrom := NIL
         nRead := hb_socketRecvFrom( hSock, @cBuf, 512, 0, @aFrom, 0 )
         IF ValType( nRead ) == "N" .AND. nRead > 0
            aReply := LinkParseHere( Left( cBuf, nRead ), aFrom )
            IF aReply != NIL .AND. ! LinkFound( aOut, aReply )
               AAdd( aOut, aReply )
            ENDIF
         ENDIF
         LOOP
      ENDIF
      IF hb_MilliSeconds() >= nDead
         EXIT
      ENDIF
   ENDDO
   hb_socketClose( hSock )
RETURN aOut

/* "HWBRO-HERE/1 <name> <port> <version>" -> { cName, cIp, nPort }, or NIL when
 * the datagram is not one of ours. PURE (it is what LinkDiscover() calls for
 * every answer, and what the bank can drive without a second process). */
FUNCTION LinkParseHere( cText, aFrom )
   LOCAL aPart, cName
   IF ValType( cText ) != "C" .OR. ! HB_ISARRAY( aFrom ) .OR. Len( aFrom ) < 3
      RETURN NIL
   ENDIF
   aPart := hb_ATokens( AllTrim( cText ), " " )
   IF Len( aPart ) < 4
      RETURN NIL
   ENDIF
   IF ! ( aPart[ 1 ] == LINK_DISC_RSP ) .OR. ! LinkAllDigits( aPart[ 3 ] )
      RETURN NIL
   ENDIF
   cName := aPart[ 2 ]
RETURN { cName, aFrom[ 2 ], Val( aPart[ 3 ] ) }

STATIC FUNCTION LinkFound( aOut, aNew )
   LOCAL i
   FOR i := 1 TO Len( aOut )
      IF aOut[ i ][ 1 ] == aNew[ 1 ] .AND. aOut[ i ][ 2 ] == aNew[ 2 ] .AND. ;
         aOut[ i ][ 3 ] == aNew[ 3 ]
         RETURN .T.
      ENDIF
   NEXT
RETURN .F.

/* =====================================================================
 *  helpers
 * ===================================================================== */

/* the read buffer of one CLIENT socket: a recv() can bring more than one
 * frame, so the leftover travels with the socket and not with the call */
STATIC FUNCTION LinkBufIndex( hSock )
   LOCAL i
   FOR i := 1 TO Len( s_aLinkIn )
      /* measured: `==` on two pointers compares the handles themselves */
      IF s_aLinkIn[ i ][ 1 ] == hSock
         RETURN i
      ENDIF
   NEXT
RETURN 0

STATIC FUNCTION LinkGetBuf( hSock )
   LOCAL n := LinkBufIndex( hSock )
RETURN iif( n > 0, s_aLinkIn[ n ][ 2 ], "" )

STATIC PROCEDURE LinkSetBuf( hSock, cBuf )
   LOCAL n := LinkBufIndex( hSock )
   IF n == 0
      AAdd( s_aLinkIn, { hSock, "" } )
      n := Len( s_aLinkIn )
   ENDIF
   s_aLinkIn[ n ][ 2 ] := cBuf
RETURN

STATIC PROCEDURE LinkForgetBuf( hSock )
   LOCAL n := LinkBufIndex( hSock )
   IF n > 0
      ADel( s_aLinkIn, n )
      ASize( s_aLinkIn, Len( s_aLinkIn ) - 1 )
   ENDIF
RETURN

/* reads whatever the socket already has, waiting at most until <nDead>
 * (absolute milliseconds). Answers .F. on EOF, on error or when nothing
 * arrives inside the budget.
 * Without a pump hook it is ONE blocking wait (the behaviour the Slave and the
 * panel have always had). With one installed, the wait goes in LINK_POLL_MS
 * steps and the hook runs in between: that is the only way a peer that lives in
 * this same process can work while a request is in flight. */
STATIC FUNCTION LinkReadMore( hSock, cBuf, nDead )
   LOCAL nWait, nRead, cTmp, lReady := .F.
   DO WHILE .T.
      nWait := Max( 0, nDead - hb_MilliSeconds() )
      IF s_bLinkPump == NIL
         lReady := hb_socketSelectRead( hSock, nWait ) == 1
      ELSE
         lReady := hb_socketSelectRead( hSock, Min( nWait, LINK_POLL_MS ) ) == 1
      ENDIF
      IF lReady
         EXIT
      ENDIF
      IF s_bLinkPump == NIL .OR. hb_MilliSeconds() >= nDead
         RETURN .F.
      ENDIF
      LinkPumpHook()
   ENDDO
   cTmp := Space( LINK_CHUNK )
   nRead := hb_socketRecv( hSock, @cTmp, LINK_CHUNK, 0, 0 )
   IF ValType( nRead ) != "N" .OR. nRead <= 0
      RETURN .F.
   ENDIF
   cBuf += Left( cTmp, nRead )
RETURN .T.

/* Runs the installed peer pump once, if there is one and we are not already
 * inside it: the hook itself serves requests, and those serve replies, and a
 * reply must never re-enter the hook. */
STATIC PROCEDURE LinkPumpHook()
   IF ValType( s_bLinkPump ) != "B" .OR. s_lLinkInPump
      RETURN
   ENDIF
   s_lLinkInPump := .T.
   Eval( s_bLinkPump )
   s_lLinkInPump := .F.
RETURN

/* the pending budget of a call that has several round trips: <nDead> is an
 * absolute millisecond stamp, so the total never stretches past what the caller
 * asked for. */
STATIC FUNCTION LinkRemain( nDead )
RETURN Max( 0, nDead - hb_MilliSeconds() )

/* one request whose only answer that matters is "did it work": .T. on OK, .F.
 * with <cErr> on an ERR reply, on silence or on a broken session. It is the
 * shape of MKDIR, RENAME, DELFILE and DELTREE. */
STATIC FUNCTION LinkRemoteOk( hSock, aArgs, nMs, cErr )
   LOCAL aReply
   cErr := ""
   aReply := LinkRequest( hSock, aArgs, nMs )
   IF ! HB_ISARRAY( aReply )
      cErr := "no answer from the Slave"
      RETURN .F.
   ENDIF
   IF ! ( aReply[ 1 ] == "OK" )
      cErr := LinkErrText( aReply )
      RETURN .F.
   ENDIF
RETURN .T.

/* a progress block that says "stop". Anything that is not a block is "carry
 * on", and so is a block that answers something that is not .T. */
STATIC FUNCTION LinkCancelled( bProgress, nDone, nTotal )
   LOCAL xRet
   IF ValType( bProgress ) != "B"
      RETURN .F.
   ENDIF
   xRet := Eval( bProgress, nDone, nTotal )
RETURN ValType( xRet ) == "L" .AND. xRet

/* the reason of an ERR reply as one readable line: "ERR 403 path outside the
 * served root" */
STATIC FUNCTION LinkErrText( aReply )
   LOCAL c := "", i
   IF ! HB_ISARRAY( aReply )
      RETURN "ERR"
   ENDIF
   FOR i := 1 TO Len( aReply )
      IF ValType( aReply[ i ] ) == "C" .AND. Len( AllTrim( aReply[ i ] ) ) > 0
         c += iif( Len( c ) == 0, "", " " ) + AllTrim( aReply[ i ] )
      ENDIF
   NEXT
   IF Len( c ) == 0
      c := "ERR"
   ENDIF
RETURN c

/* a path as it travels: no stray blanks and no control characters. The module
 * accepts "\" and "/" the same way and LinkSafePath() normalises it, so an
 * absolute path of the peer goes through untouched. */
STATIC FUNCTION LinkWirePath( cPath )
   IF ValType( cPath ) != "C"
      RETURN ""
   ENDIF
RETURN LinkFromWire( cPath )

/* ---- guarded socket primitives ----
 * MEASURED: hb_socketSend(), hb_socketRecv(), hb_socketSelectRead(),
 * hb_socketAccept(), hb_socketGetSockName() and hb_socketClose() all THROW
 * "Argument error" on a handle that was already closed, and the item still
 * looks like a live pointer to LinkIsSock(). An exception escaping from here
 * would take the whole program down through BpFatal(), so the calls the wire
 * depends on answer their failure value instead of letting it out: a stale
 * session then reads as "the transfer failed", which is the truth. */
STATIC FUNCTION LinkSockSend( hSock, cData, nLen, nMs )
   LOCAL n := -1
   BEGIN SEQUENCE WITH {| oErr | Break( oErr ) }
      n := hb_socketSend( hSock, cData, nLen, 0, nMs )
   RECOVER
      n := -1
   END
RETURN n

STATIC FUNCTION LinkSockAccept( hSock, aAddr, nMs )
   LOCAL hNew := NIL
   BEGIN SEQUENCE WITH {| oErr | Break( oErr ) }
      hNew := hb_socketAccept( hSock, @aAddr, nMs )
   RECOVER
      hNew := NIL
   END
RETURN hNew

STATIC PROCEDURE LinkSockClose( hSock )
   BEGIN SEQUENCE WITH {| oErr | Break( oErr ) }
      hb_socketClose( hSock )
   RECOVER
   END
RETURN

/* .T. for a live socket handle. MEASURED: hb_socketOpen()/hb_socketAccept()
 * answer a NULL pointer when they fail, and that value still has ValType()
 * "P", so the only reliable test is Empty() (a NULL pointer is empty, a real
 * one is not; hb_IsNIL() answers .F. for both). A handle that was closed is NOT
 * detected here - hb_socketClose() leaves a stale pointer behind - and that is
 * why the primitives above are guarded. */
STATIC FUNCTION LinkIsSock( hSock )
RETURN ValType( hSock ) == "P" .AND. ! Empty( hSock )

/* a millisecond budget as this API wants it: never negative, never -1 (which
 * would wait forever and freeze the UI) */
STATIC FUNCTION LinkBudget( nMs )
   IF ValType( nMs ) != "N"
      RETURN LINK_TIMEOUT_DEF
   ENDIF
RETURN Max( 0, Int( nMs ) )

/* hb_idleSleep() takes SECONDS (measured: `void hb_idleSleep( double
 * dSeconds )`), so the millisecond budget is scaled here */
STATIC FUNCTION LinkSleep( nMs )
   IF ValType( nMs ) == "N" .AND. nMs > 0
      hb_idleSleep( nMs / 1000 )
   ENDIF
RETURN NIL

STATIC FUNCTION LinkAllDigits( cText )
   LOCAL i
   IF ValType( cText ) != "C" .OR. Len( cText ) == 0
      RETURN .F.
   ENDIF
   FOR i := 1 TO Len( cText )
      IF ! ( SubStr( cText, i, 1 ) $ "0123456789" )
         RETURN .F.
      ENDIF
   NEXT
RETURN .T.

STATIC FUNCTION LinkIntToStr( n )
   IF ValType( n ) != "N"
      RETURN "0"
   ENDIF
RETURN LTrim( Str( Int( n ), 20, 0 ) )

/* one argument as text on the wire */
STATIC FUNCTION LinkArgText( xVal )
   DO CASE
   CASE ValType( xVal ) == "C"
      RETURN xVal
   CASE ValType( xVal ) == "N"
      RETURN LinkIntToStr( xVal )
   CASE ValType( xVal ) == "L"
      RETURN iif( xVal, "1", "0" )
   CASE ValType( xVal ) == "D"
      RETURN LinkDate8( xVal )
   ENDCASE
RETURN ""

/* splits keeping the empty tokens (At() has no start offset in this build, so
 * the tail is taken and the scan restarts on it) */
STATIC FUNCTION LinkSplit( cText, cSep )
   LOCAL aOut := {}, c := cText, n
   IF ValType( cText ) != "C"
      RETURN aOut
   ENDIF
   DO WHILE .T.
      n := At( cSep, c )
      IF n == 0
         AAdd( aOut, c )
         EXIT
      ENDIF
      AAdd( aOut, Left( c, n - 1 ) )
      c := SubStr( c, n + Len( cSep ) )
   ENDDO
RETURN aOut

/* a path that came over the wire loses any stray control character and its
 * blanks before it is confined */
STATIC FUNCTION LinkFromWire( cPath )
   LOCAL c
   IF ValType( cPath ) != "C"
      RETURN ""
   ENDIF
   c := StrTran( cPath, Chr( 13 ), "" )
   c := StrTran( c, Chr( 10 ), "" )
RETURN AllTrim( c )

/* the name of a discovery reply cannot carry a blank: it is one token in the
 * middle of the datagram */
STATIC FUNCTION LinkNoSpace( cName )
   LOCAL c := AllTrim( cName )
   c := StrTran( c, " ", "_" )
   c := StrTran( c, Chr( 9 ), "_" )
   IF Len( c ) == 0
      c := "hwBro"
   ENDIF
RETURN c

/* textual peer of a session, for logs and for the panel */
STATIC FUNCTION LinkPeerText( aAddr )
   IF ! HB_ISARRAY( aAddr ) .OR. Len( aAddr ) < 3
      RETURN ""
   ENDIF
RETURN AllTrim( iif( ValType( aAddr[ 2 ] ) == "C", aAddr[ 2 ], "" ) ) + ":" + ;
       LinkIntToStr( aAddr[ 3 ] )
