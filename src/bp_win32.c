/*
 * bp_mouse.c - rueda y clicks del mouse para la ventana de GTWVG.
 *
 * POR QUE EXISTE: medido sobre este Harbour (ver AGENTS.md trampa 34), el driver
 * GTWVG NO soporta mouse: hb_gtInfo( HB_GTI_MOUSESTATUS ) devuelve NIL y ni la
 * rueda ni los clicks llegan por Inkey(). El mensaje WM_MOUSEWHEEL llega a la
 * ventana y el driver lo descarta. Como no hay API en PRG para verlo, se
 * engancha la ventana del driver (subclassing del WndProc) y se dejan los
 * eventos contados/anotados para que el dot prompt los recoja sondeando:
 *
 *    DotMouseHook( lOn )  -> instala / quita el enganche en la ventana de hwBro
 *    DotMouseWheel()      -> notches acumulados (+ arriba / - abajo) y los pone a 0
 *    DotMouseClick()      -> { fila, columna } (grilla 80x25) del ultimo click
 *                            izquierdo, o NIL; lo pone a 0 al leerlo
 *
 * El WndProc NO consume WM_LBUTTONDOWN (GTWVG sigue viendo el click: foco,
 * activacion de la ventana); si consume WM_MOUSEWHEEL, que el driver ignora.
 * Todo se mide sobre la grilla de 80x25 celdas, que es la que pinta el driver.
 *
 * S37: ademas se sigue el BOTON DERECHO mientras se arrastra (pulsar, mover con
 * el boton apretado y soltar), que es como el gestor de ficheros marca entradas
 * de una pasada: W32RMOUSESTEP() / W32RMOUSEUP() / W32RMOUSEROW() /
 * W32RMOUSECOL(). El boton derecho tambien se consume y el gesto toma captura
 * de mouse (SetCapture) para no quedar a medias si el puntero sale de la
 * ventana.
 *
 * S6 de hc-ctx-menu-clipboard.md: ademas de lo anterior, TODOS los movimientos
 * del puntero se anotan en su propia celda (con boton o sin el) para que el
 * resaltado del menu contextual siga al mouse aunque el boton ya este suelto:
 * W32POINTERSTEP() / W32POINTERROW() / W32POINTERCOL(). Esos movimientos NO se
 * consumen: el driver los sigue viendo.
 *
 * S1 de hc-editor-mouse.md: ademas se sigue el BOTON IZQUIERDO mientras esta
 * apretado (W32LMOUSEDOWN()), para que el editor de texto sepa distinguir un
 * arrastre en curso de un click terminado. El estado se pone en
 * WM_LBUTTONDOWN/WM_LBUTTONDBLCLK (con SetCapture, para no perder el UP si el
 * puntero sale de la ventana) y se limpia en WM_LBUTTONUP, WM_CAPTURECHANGED y
 * DotMouseHook(). El click se sigue consumiendo, como siempre.
 */
#define _CRT_SECURE_NO_WARNINGS
#include <windows.h>
#include <shellapi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "hbapi.h"

#pragma comment( lib, "user32.lib" )
#pragma comment( lib, "shell32.lib" )
#pragma comment( lib, "advapi32.lib" )

#define BP_GRID_COLS   80
#define BP_GRID_ROWS   25

/* S39: the double click window is the one Windows has configured
 * (GetDoubleClickTime(), read on every click so a change in the Mouse settings
 * applies without restarting) PLUS BP_DBLCLK_EXTRA: the user asked for "a bit
 * more time" between the two clicks that select a file, and the bare system
 * value felt short. BP_DBLCLK_MS is only the fallback when the system reports nothing usable. */
#define BP_DBLCLK_MS      500
#define BP_DBLCLK_EXTRA   250

/* The grid the click is converted to. It is NOT a constant: the clone runs on a
 * 120x44 canvas, so hwbro.prg sets the real size once at startup with
 * W32SetGrid( MaxRow()+1, MaxCol()+1 ). With the fixed 80x25 grid a click was
 * quantised twice (pixels -> 25 rows -> 44 rows) and landed a row above or
 * below the file the user pointed at. */
static int      s_iGridCols = BP_GRID_COLS;
static int      s_iGridRows = BP_GRID_ROWS;

/* Characters typed while ALT was held. The incremental search of the Harbour
 * Commander (bp_hc.prg) needs them because this GTWVG may swallow Alt+<letter>
 * before Inkey() sees it. WM_SYSCHAR / WM_SYSKEYDOWN are NOT consumed: the
 * driver and Windows must keep receiving them (Alt+F1/F2/F4, drag & drop...). */
#define BP_ALTQ_SIZE   16

static HWND     s_hWnd     = NULL;
static WNDPROC  s_pOldProc = NULL;
static int      s_iWheel   = 0;     /* notches acumulados */
static int      s_iClickR  = -1;    /* fila del ultimo click, -1 = ninguna */
static int      s_iClickC  = -1;    /* columna del ultimo click */
static HB_BOOL  s_lClickDbl   = HB_FALSE;  /* the last click was a DOUBLE one */
static DWORD    s_dwClickTick = 0;        /* GetTickCount() of the last click */
/* STICKY memory of the row of the last click: s_iClickR/s_iClickC are read ONCE
 * (the read sets them to -1), so they cannot recognise a double click - that
 * comparison needs a value that survives the read. The ROW is compared and not
 * the cell, because the entry of a panel IS the row: a cell is only ~9 px wide
 * and the slightest horizontal wobble between the two clicks would throw the
 * double click away. */
static int      s_iLastR = -1;
static HB_BOOL  s_lClickShift = HB_FALSE;  /* SHIFT apretado en ese click */
static HB_BOOL  s_lClickCtrl  = HB_FALSE;  /* CTRL apretado en ese click  */
static HB_BOOL  s_lKeyShift   = HB_FALSE;  /* SHIFT apretado en la ultima tecla */

/* Right button DRAG (S37 of the commander): the panels mark entries by
 * sweeping them with the right button held. The press and every move while the
 * button is down are ONE "step" each, and the release is collected separately,
 * so a gesture that ends between two polls cannot lose its UP. */
static HB_BOOL  s_lRDown   = HB_FALSE;  /* the right button is being held */
static HB_BOOL  s_lRStep   = HB_FALSE;  /* a press or a move not yet read   */
static HB_BOOL  s_lRUp     = HB_FALSE;  /* the release not yet read         */
static int      s_iRRow    = -1;        /* cell of the last step, -1 = none */
static int      s_iRCol    = -1;
static DWORD    s_dwRDown  = 0;         /* GetTickCount() of the press      */
/* right-click-esc (S3/S6 de right-click-esc.md): TRUE mientras el gesto sigue
 * siendo un CLICK LIMPIO - la pulsacion y su liberacion sin un solo movimiento
 * en medio -. El canal de arriba guarda UN solo par de celdas para todo el
 * gesto (la pulsacion la escribe y cada movimiento la pisa), asi que desde PRG
 * un arrastre que vuelve a la celda de la pulsacion es indistinguible de un
 * click: este es el unico dato que solo sabe este lado. Lo pone la pulsacion
 * (WM_RBUTTONDOWN/WM_RBUTTONDBLCLK), lo limpia cualquier WM_MOUSEMOVE con el
 * boton abajo, lo limpia el WM_CAPTURECHANGED que cierra el gesto a la fuerza
 * (una captura robada NUNCA puede cancelar un formulario) y lo resetea
 * DOTMOUSEHOOK. W32RMOUSEPLAIN() es un PEEK: leerlo no lo limpia. */
static HB_BOOL  s_lRPlain  = HB_FALSE;  /* el gesto sigue siendo un click    */

/* The POINTER cell, with NO button pressed (S6 of hc-ctx-menu-clipboard.md).
 * The gesture above only sees the moves of the right button, and the context
 * menu of the panels stays open after the release, so its highlight froze as
 * soon as the button went up. Every WM_MOUSEMOVE is recorded here as well, in
 * these own statics, while the driver keeps receiving the message untouched.
 * s_lPtrStep means "the pointer is at a DIFFERENT cell than the last one
 * handed over" and is cleared when it is read. */
static HB_BOOL  s_lPtrStep = HB_FALSE;  /* the pointer is on a new cell      */
static int      s_iPtrR    = -1;        /* pointer cell, -1 = none yet       */
static int      s_iPtrC    = -1;

/* The LEFT button, held or not (S1 of hc-editor-mouse.md). The click channel
 * above only says WHERE a press was; the Text editor also needs to know whether
 * the gesture is still going, so it can tell a live drag from a finished click.
 * Set by WM_LBUTTONDOWN/WM_LBUTTONDBLCLK, cleared by WM_LBUTTONUP,
 * WM_CAPTURECHANGED and DotMouseHook(). */
static HB_BOOL  s_lLDown   = HB_FALSE;  /* the left button is being held     */
/* el boton X de la ventana (WM_CLOSE) se CONSUME y queda pedido en esta
 * bandera: el driver no tiene que destruir la ventana, porque eso se saltaria
 * el cierre ordenado del programa (HcZipCleanupAll(), CLOSE ALL,
 * HcLinkShutdown()). Es un PEEK: leerla no la limpia, para que el pedido
 * sobreviva a varias pantallas hasta que el programa termine de verdad;
 * solo W32CLOSERESET() la limpia. */
static HB_BOOL  s_lCloseReq = HB_FALSE;

static char     s_altQ[ BP_ALTQ_SIZE ];  /* ring of the Alt characters seen   */
static int      s_iAltHead  = 0;         /* next slot to write                */
static int      s_iAltTotal = 0;         /* monotonic count since the reset   */
static char     s_cAltPend  = 0;         /* letter recorded by WM_SYSKEYDOWN  */
/* hc-clipboard-files.md S7: the combos Inkey() does NOT report with their
 * modifier (measured with BP_DEBUG: Ctrl+C arrives as the plain letter 'c' with
 * no CTRL bit, Shift+Ins as a plain Ins with no SHIFT bit). 1 = copy, 2 = paste,
 * 3 = cut. Shift+Del used to be recorded here as 4 (read as a paste by the
 * panels); it is its own channel now, see s_lHardDel. */
static int      s_nClipKey   = 0;
/* S2/S3 of recycle-bin-delete.md: Shift+Del deletes for real, with no Recycle
 * Bin. It is NOT a clipboard chord: the hook only says the stroke happened and
 * the panel loop drops the Inkey() copy of it. Set on WM_KEYDOWN, cleared by
 * the first read (and by W32HardDelReset()). */
static HB_BOOL  s_lHardDel   = HB_FALSE;
/* editor-ctrl-chords.md S2/S4: the word chords of the Text editor. Ctrl+Left
 * arrives as the code of Ctrl+Z (26, measured), so Inkey() alone cannot tell
 * them apart; the hook records which ARROW was pressed with CTRL held.
 * 1 = Ctrl+Left, 2 = Ctrl+Right; read once, then 0. */
static int      s_nWordKey   = 0;
static char     s_cAltLast  = 0;         /* last recorded char, upper case    */
static DWORD    s_dwAltTick = 0;         /* when it was recorded              */

static void BpAltRecord( char ch )
{
   DWORD dwNow;
   char  cUp;

   if( ch == 0 )
      return;
   /* AltGr is Ctrl+Alt on a Spanish keyboard: it is not Alt+<letter> */
   if( GetKeyState( VK_CONTROL ) < 0 )
      return;
   dwNow = GetTickCount();
   cUp = ( ch >= 'a' && ch <= 'z' ) ? ( char ) ( ch - 32 ) : ch;
   /* ONE KEYSTROKE, ONE CHARACTER: the WM_SYSKEYDOWN and the WM_SYSCHAR of the
    * same stroke (or an odd message order between two strokes) must not both be
    * stored. Two presses of the same letter by a human are > 60 ms apart. */
   if( cUp == s_cAltLast && ( dwNow - s_dwAltTick ) < 60 )
      return;
   s_cAltLast  = cUp;
   s_dwAltTick = dwNow;
   s_altQ[ s_iAltHead ] = ch;
   s_iAltHead = ( s_iAltHead + 1 ) % BP_ALTQ_SIZE;
   s_iAltTotal++;
}

static void BpAltReset( void )
{
   int i;
   for( i = 0; i < BP_ALTQ_SIZE; i++ )
      s_altQ[ i ] = 0;
   s_iAltHead  = 0;
   s_iAltTotal = 0;
   s_cAltPend  = 0;
   s_cAltLast  = 0;
   s_dwAltTick = 0;
}

/* Client pixels of a mouse message -> cell of the grid the caller paints.
 * The SHIFT/CTRL state is NOT read here: it belongs to the click. */
static void BpCellFromPoint( HWND hWnd, LPARAM lParam, int * piRow, int * piCol )
{
   RECT r;
   int  x = ( int ) ( short ) LOWORD( lParam );
   int  y = ( int ) ( short ) HIWORD( lParam );

   if( ! GetClientRect( hWnd, &r ) || r.right <= 0 || r.bottom <= 0 )
      return;                         /* keep the cell we already had */
   *piCol = ( x * s_iGridCols ) / r.right;
   *piRow = ( y * s_iGridRows ) / r.bottom;
   if( *piCol >= s_iGridCols ) *piCol = s_iGridCols - 1;
   if( *piRow >= s_iGridRows ) *piRow = s_iGridRows - 1;
   if( *piCol < 0 ) *piCol = 0;
   if( *piRow < 0 ) *piRow = 0;
}

static void BpPointerNote( int iR, int iC )
{
   if( iR != s_iPtrR || iC != s_iPtrC )
   {
      s_iPtrR = iR;
      s_iPtrC = iC;
      s_lPtrStep = HB_TRUE;
   }
}

static LRESULT CALLBACK BpMouseProc( HWND hWnd, UINT uMsg, WPARAM wParam, LPARAM lParam )
{
   switch( uMsg )
   {
      case WM_CLOSE:
         /* el boton X de la ventana, y tambien Alt+F4 (que llega como
          * WM_SYSCOMMAND/SC_CLOSE y Windows convierte en este mismo mensaje):
          * se CONSUME y NO se reenvia con CallWindowProc, porque dejar que el
          * driver destruya la ventana se saltaria el cierre ordenado del
          * programa. El pedido queda anotado y lo atiende el bucle de teclas
          * de la pantalla que este arriba (BpCloseAsk(), bp_hc.prg). */
         s_lCloseReq = HB_TRUE;
         return 0;
      case WM_MOUSEWHEEL:
      {
         int iNotch = ( int ) ( ( ( short ) HIWORD( wParam ) ) / WHEEL_DELTA );
         if( iNotch == 0 )
            iNotch = ( HIWORD( wParam ) > 0 ) ? 1 : -1;
         s_iWheel += iNotch;
         return 0;                          /* consumido: el driver no lo usa */
      }
      case WM_LBUTTONDOWN:
      case WM_LBUTTONDBLCLK:
      {
         int   iR = s_iClickR, iC = s_iClickC, iDblMs;
         DWORD dwNow = GetTickCount();
         /* MEASURED: with a REAL double click Windows does NOT send a second
          * WM_LBUTTONDOWN, it sends WM_LBUTTONDBLCLK (the driver class does
          * accept it), and the first version consumed that message without
          * recording anything, so the double click never reached the clone
          * while a test that posts two WM_LBUTTONDOWN always worked. Both
          * messages are the same click here, and WM_LBUTTONDBLCLK IS the
          * double by itself. */
         HB_BOOL lDblMsg = ( uMsg == WM_LBUTTONDBLCLK );

         BpCellFromPoint( hWnd, lParam, &iR, &iC );
         /* a press happens with the pointer ON that cell: keeping the pointer
          * cell true here is what makes a fresh menu open with the right entry
          * highlighted even if the mouse has not moved since the last one */
         BpPointerNote( iR, iC );
         /* S39: the double click is detected HERE and not with
          * WM_LBUTTONDBLCLK, because this window class is not registered with
          * CS_DBLCLKS and that message never arrives (measured). The rule is
          * Windows' own: the same cell within GetDoubleClickTime(), plus the
          * margin the user asked for ("a bit more time" between the two clicks
          * that select a file: the system value alone felt short). */
         iDblMs = ( int ) GetDoubleClickTime();
         if( iDblMs <= 0 )
         {
            iDblMs = BP_DBLCLK_MS;
         }
         iDblMs += BP_DBLCLK_EXTRA;
         s_lClickDbl = lDblMsg || ( s_dwClickTick != 0 &&
                         ( dwNow - s_dwClickTick ) <= ( DWORD ) iDblMs &&
                         iR == s_iLastR );
         s_dwClickTick = dwNow;
         s_iLastR = iR;
         s_iClickR = iR;
         s_iClickC = iC;
         /* the SHIFT state at click time: the panels use it for the range
          * selection (Shift+click marks everything between the anchor and
          * the clicked row). Read here because the message itself does not
          * carry it. */
         s_lClickShift = ( ( GetKeyState( VK_SHIFT ) & 0x8000 ) != 0 );
         s_lClickCtrl  = ( ( GetKeyState( VK_CONTROL ) & 0x8000 ) != 0 );
         /* S1 of hc-editor-mouse.md: from here on the left button counts as
          * HELD. SetCapture() keeps the release coming even when the pointer
          * leaves the window - a lost UP would leave the editor selecting for
          * ever - and it is released in WM_LBUTTONUP, in WM_CAPTURECHANGED
          * and in DotMouseHook( .F. ). The press stays consumed, as before. */
         s_lLDown = HB_TRUE;
         SetCapture( hWnd );
         /* TAMBIEN se consume: medido, reenviar WM_LBUTTONDOWN al WndProc de
          * GTWVG con CallWindowProc() tumba el proceso (el driver no tiene
          * control de mouse). El click no hace falta para nada mas: la
          * activacion de la ventana la resuelve Windows antes, con
          * WM_MOUSEACTIVATE. */
         return 0;
      }
      case WM_LBUTTONUP:
         /* se consumen junto con el DOWN: GTWVG no tiene control de mouse y si
          * le llega un UP sin su DOWN previo, el WndProc del driver tumba el
          * proceso (medido). El WM_LBUTTONDBLCLK NO se consume aca: es un click
          * mas y se registra arriba junto con el DOWN (ver el comentario de
          * ese CASE). */
         if( s_lLDown )
         {
            s_lLDown = HB_FALSE;
            ReleaseCapture();
         }
         return 0;

      case WM_RBUTTONDOWN:
      case WM_RBUTTONDBLCLK:
         /* S37: the press is the first step of the gesture and it also counts
          * as "the pointer passed over this entry". Consumed, like the left
          * button (the driver has no mouse control at all). SetCapture() keeps
          * the moves and the release coming even if the pointer leaves the
          * window, so a drag can never stay "half open". */
         BpCellFromPoint( hWnd, lParam, &s_iRRow, &s_iRCol );
         BpPointerNote( s_iRRow, s_iRCol );   /* the pointer IS there */
         s_dwRDown = GetTickCount();      /* the real moment of the press */
         s_lRDown = HB_TRUE;
         s_lRStep = HB_TRUE;
         s_lRPlain = HB_TRUE;             /* still a plain click (right-click-esc) */
         SetCapture( hWnd );
         return 0;

      case WM_RBUTTONUP:
         if( s_lRDown )
         {
            s_lRDown = HB_FALSE;
            s_lRUp   = HB_TRUE;
            ReleaseCapture();
         }
         return 0;

      case WM_MOUSEMOVE:
      {
         int iR = s_iPtrR, iC = s_iPtrC;

         BpCellFromPoint( hWnd, lParam, &iR, &iC );
         /* S6: EVERY move is recorded, button or not, in its own statics (the
          * pointer cell). Not consumed: the driver keeps seeing the moves. */
         BpPointerNote( iR, iC );
         /* the gesture of S37 only exists while the right button is held, and
          * while it is held the move IS consumed (the driver has no mouse
          * control at all: forwarding it kills the process) */
         if( s_lRDown )
         {
            s_iRRow = iR;
            s_iRCol = iC;
            s_lRStep = HB_TRUE;
            /* right-click-esc S3: a move means it DRAGS, so it is no longer a
             * plain click and it can never fire an Esc */
            s_lRPlain = HB_FALSE;
            return 0;
         }
         break;
      }

      case WM_CAPTURECHANGED:
         /* the capture went elsewhere (another window took it): the gesture is
          * closed here, because its RELEASE will never reach this window */
         s_lLDown = HB_FALSE;
         if( s_lRDown )
         {
            s_lRDown = HB_FALSE;
            s_lRUp   = HB_TRUE;
            /* right-click-esc S3: the gesture was closed by force, it was not
             * clicked, so it must not fire an Esc */
            s_lRPlain = HB_FALSE;
         }
         break;

      case WM_KEYDOWN:
         /* S33: the SHIFT state of the key being pressed. Recorded, NOT
          * consumed (the driver must keep receiving the keys). GetKeyState()
          * here is the truth: the key code GTWVG hands over does not say
          * whether Shift was held. */
         s_lKeyShift = ( ( GetKeyState( VK_SHIFT ) & 0x8000 ) != 0 );
         /* S7 of hc-clipboard-files.md: the clipboard combos whose modifier
          * Inkey() drops. RECORDED, NOT CONSUMED: the panel loop drains them
          * with W32ClipKeyStep()/W32ClipKey() and drops the Inkey() copy of the
          * SAME stroke, so one keystroke is one action. Ctrl+Ins and Ctrl+V do
          * arrive correctly (402 / 22 with the CTRL bit) and are handled from
          * PRG, so they are NOT recorded here: recording them would paste
          * twice. The auto-repeat bit (30) is skipped. */
         if( ! ( lParam & ( 1L << 30 ) ) )
         {
            int vk = ( int ) wParam;
            if( ( GetKeyState( VK_CONTROL ) & 0x8000 ) && vk == 'C' )
               s_nClipKey = 1;                 /* Ctrl+C  -> copy  */
            else if( ( GetKeyState( VK_CONTROL ) & 0x8000 ) && vk == 'X' )
               s_nClipKey = 3;                 /* Ctrl+X  -> cut   */
            else if( ( GetKeyState( VK_SHIFT ) & 0x8000 ) && vk == VK_INSERT )
               s_nClipKey = 2;                 /* Shift+Ins -> paste */
            else if( ( GetKeyState( VK_SHIFT ) & 0x8000 ) && vk == VK_DELETE )
               s_lHardDel = HB_TRUE;           /* Shift+Del -> delete for real */
            /* editor-ctrl-chords.md S2/S4: the word chords of the editor. Only
             * the ARROW matters here: the letter form of a Ctrl+<letter> IS
             * recorded by the clipboard block above and read from PRG. */
            else if( ( GetKeyState( VK_CONTROL ) & 0x8000 ) && vk == VK_LEFT )
               s_nWordKey = 1;                 /* Ctrl+Left  -> word left  */
            else if( ( GetKeyState( VK_CONTROL ) & 0x8000 ) && vk == VK_RIGHT )
               s_nWordKey = 2;                 /* Ctrl+Right -> word right */
         }
         break;

      case WM_SYSKEYDOWN:
         /* Alt+<letter> with the key still down. RECORDED, NOT CONSUMED: the
          * driver keeps seeing it (Alt+F1/F2/F4 and the system shortcuts stay
          * alive). Only the first press is taken (bit 30 = auto repeat) and
          * only when the ALT context bit (29) is set and ALT is really down. */
         if( ( lParam & ( 1L << 29 ) ) && GetKeyState( VK_MENU ) < 0 &&
             ! ( lParam & ( 1L << 30 ) ) && s_cAltPend == 0 )
         {
            int vk = ( int ) wParam;
            if( vk >= 'A' && vk <= 'Z' )
            {
               s_cAltPend = ( char ) ( vk + 32 );   /* Alt+C -> 'c' */
               BpAltRecord( s_cAltPend );
            }
         }
         break;

      case WM_SYSCHAR:
         /* The character of an Alt combination. It normally belongs to the
          * WM_SYSKEYDOWN recorded above, so it is not stored twice; when it
          * arrives alone (no letter keydown seen) it is stored here. The
          * comparison is case insensitive (a Shift+Alt combination can report
          * the other case). */
         if( ( lParam & ( 1L << 29 ) ) || GetKeyState( VK_MENU ) < 0 )
         {
            int ch = ( int ) wParam;
            if( ch >= 32 && ch <= 255 )
            {
               char cUp = ( ch >= 'a' && ch <= 'z' ) ? ( char ) ( ch - 32 ) : ( char ) ch;
               char cPend = ( s_cAltPend >= 'a' && s_cAltPend <= 'z' ) ?
                            ( char ) ( s_cAltPend - 32 ) : s_cAltPend;
               if( cPend != cUp )
                  BpAltRecord( ( char ) ch );
               s_cAltPend = 0;
            }
         }
         break;

      case WM_SYSKEYUP:
         /* the Alt key was released: the pending letter (if its WM_SYSCHAR
          * never arrived) cannot be matched any more */
         if( ( int ) wParam == VK_MENU )
            s_cAltPend = 0;
         break;

      default:
         break;
   }
   if( s_pOldProc == NULL )
      return DefWindowProcA( hWnd, uMsg, wParam, lParam );
   return CallWindowProc( s_pOldProc, hWnd, uMsg, wParam, lParam );
}

/* icono de la ventana: el PRIMER icono del ejecutable (el del .rc). Se aplica
 * al instalar el hook, asi la barra de titulo y la barra de tareas del programa
 * muestran el icono de hwBro y no el generico del driver. */
static void BpSetWindowIcon( HWND hWnd )
{
   HICON hBig = ( HICON ) LoadImageA( GetModuleHandleA( NULL ), MAKEINTRESOURCEA( 1 ),
                                     IMAGE_ICON, GetSystemMetrics( SM_CXICON ),
                                     GetSystemMetrics( SM_CYICON ), 0 );
   HICON hSmall = ( HICON ) LoadImageA( GetModuleHandleA( NULL ), MAKEINTRESOURCEA( 1 ),
                                       IMAGE_ICON, GetSystemMetrics( SM_CXSMICON ),
                                       GetSystemMetrics( SM_CYSMICON ), 0 );
   if( hBig != NULL )
      SendMessageA( hWnd, WM_SETICON, ICON_BIG, ( LPARAM ) hBig );
   if( hSmall != NULL )
      SendMessageA( hWnd, WM_SETICON, ICON_SMALL, ( LPARAM ) hSmall );
}

/* ventana de hwBro: la que tiene el foco si es de GTWVG; si no, la primera de
 * esa clase (el caso de arrancar el .exe sin foco) */
static HWND BpFindGtWindow( void )
{
   char szClass[ 64 ];
   HWND h = GetForegroundWindow();

   if( h != NULL )
   {
      szClass[ 0 ] = 0;
      GetClassNameA( h, szClass, sizeof( szClass ) );
      if( strcmp( szClass, "Harbour_WVG_Class" ) == 0 )
         return h;
   }
   return FindWindowA( "Harbour_WVG_Class", NULL );
}

/* S8 of odd/tasks/commander-cleanup.md: is the window hook installed RIGHT NOW?
 * Read only, nothing changes. It exists so a screen that installs the hook on
 * entry can give it BACK when it leaves instead of tearing it off the screen
 * underneath: the dot prompt did exactly that, and coming back to the Browse edit
 * left it without wheel and without clicks (pending 24 of AGENTS.md, reported by
 * the user as "cuando entro al Dot. Y luego vuelvo al browse. El mouse no me
 * funciona sobre el browse"). */
HB_FUNC( W32MOUSEHOOKON )
{
   hb_retni( s_hWnd != NULL ? 1 : 0 );
}

HB_FUNC( DOTMOUSEHOOK )
{
   BOOL lOn = HB_ISLOG( 1 ) ? hb_parl( 1 ) : TRUE;

   if( lOn )
   {
      if( s_hWnd == NULL )
      {
         HWND h = BpFindGtWindow();
         if( h == NULL )
            hb_retl( FALSE );
         else
         {
            s_pOldProc = ( WNDPROC ) SetWindowLongPtrA( h, GWLP_WNDPROC,
                                                       ( LONG_PTR ) BpMouseProc );
            if( s_pOldProc == NULL )
            {
               hb_retl( FALSE );
            }
            else
            {
               s_hWnd = h;
               s_iWheel = 0;
               s_iClickR = s_iClickC = -1;
               s_iLastR = -1;
               s_iRRow = s_iRCol = -1;
               s_lRDown = s_lRStep = s_lRUp = HB_FALSE;
               s_lRPlain = HB_FALSE;
               s_lLDown = HB_FALSE;
               s_iPtrR = s_iPtrC = -1;
               s_lPtrStep = HB_FALSE;
               s_lCloseReq = HB_FALSE;
               BpAltReset();
               /* the icon of the EXECUTABLE (hwbro.rc, first icon) is also the
                * icon of the WINDOW: the title bar and the taskbar show the
                * same drawing as the file in Explorer */
               BpSetWindowIcon( h );
               hb_retl( TRUE );
            }
         }
      }
      else
         hb_retl( TRUE );
   }
   else
   {
      if( s_hWnd != NULL && s_pOldProc != NULL && IsWindow( s_hWnd ) )
         SetWindowLongPtrA( s_hWnd, GWLP_WNDPROC, ( LONG_PTR ) s_pOldProc );
      if( s_lRDown )
      {
         /* a gesture was open when the screen went away: release the capture
          * so Windows does not keep the mouse pointing at a dead hook */
         s_lRDown = HB_FALSE;
         ReleaseCapture();
      }
      if( s_lLDown )
      {
         /* same for the left button (S1 of hc-editor-mouse.md): a drag that
          * was open when the screen went away must not stay "held" */
         s_lLDown = HB_FALSE;
         ReleaseCapture();
      }
      s_hWnd = NULL;
      s_pOldProc = NULL;
      s_iWheel = 0;
      s_iClickR = s_iClickC = -1;
      s_iLastR = -1;
      s_lClickDbl = HB_FALSE;
      s_dwClickTick = 0;
      s_iRRow = s_iRCol = -1;
      s_dwRDown = 0;
      s_lRStep = s_lRUp = HB_FALSE;
      s_lRPlain = HB_FALSE;
      s_iPtrR = s_iPtrC = -1;
      s_lPtrStep = HB_FALSE;
      s_lCloseReq = HB_FALSE;
      s_lClickShift = s_lClickCtrl = HB_FALSE;
      s_lKeyShift = HB_FALSE;
      BpAltReset();
      hb_retl( TRUE );
   }
}

/* ---------------------------------------------------------------------------
 * Alt characters recorded by the hook (incremental search of bp_hc.prg).
 *
 *   W32ALTKEYS()  -> characters recorded so far (monotonic since the last
 *                    W32ALTRESET(); 0 when the hook is not installed)
 *   W32ALTKEY(n)  -> the n-th recorded character (1-based) as a one character
 *                    string, "" when it is out of range or already overwritten
 *   W32ALTRESET() -> clears the buffer and the counter
 *
 * Scalar getters only: returning arrays from this extension was measured to
 * kill the process (hb_reta/hb_storni, see AGENTS.md).
 * ------------------------------------------------------------------------- */
HB_FUNC( W32ALTKEYS )
{
   hb_retni( s_hWnd != NULL ? s_iAltTotal : 0 );
}

HB_FUNC( W32ALTKEY )
{
   int n = HB_ISNUM( 1 ) ? hb_parni( 1 ) : 0;

   if( n < 1 || n > s_iAltTotal || ( s_iAltTotal - n ) >= BP_ALTQ_SIZE )
      hb_retc( "" );
   else
   {
      char sz[ 2 ];
      sz[ 0 ] = s_altQ[ ( n - 1 ) % BP_ALTQ_SIZE ];
      sz[ 1 ] = 0;
      if( sz[ 0 ] == 0 )
         hb_retc( "" );
      else
         hb_retclen( sz, 1 );
   }
}

HB_FUNC( W32ALTRESET )
{
   BpAltReset();
   hb_retni( 0 );
}

HB_FUNC( DOTMOUSEWHEEL )
{
   int iNotch = s_iWheel;
   s_iWheel = 0;
   hb_retni( iNotch );
}

/* ---------------------------------------------------------------------------
 * Boton derecho arrastrando (S37 del Harbour Commander).
 *
 *   W32RMOUSESTEP() -> 1 cuando hay un paso sin leer (la pulsacion o un
 *                      movimiento con el boton apretado); lo pone a 0
 *   W32RMOUSEUP()   -> 1 cuando se solto el boton; lo pone a 0
 *   W32RMOUSEROW()  -> fila de la celda del ultimo paso (-1 si no hubo)
 *   W32RMOUSECOL()  -> columna de esa celda (-1 si no hubo)
 *
 * Paso y liberacion se leen APARTE a proposito: si el gesto entero cae entre
 * dos sondeos, el PRG procesa el paso (marca la entrada pulsada) y despues el
 * UP que cierra el gesto, sin perder ninguno de los dos.
 * ------------------------------------------------------------------------- */
HB_FUNC( W32RMOUSESTEP )
{
   HB_BOOL bStep = s_lRStep;
   s_lRStep = HB_FALSE;
   hb_retni( bStep ? 1 : 0 );
}

HB_FUNC( W32RMOUSEUP )
{
   HB_BOOL bUp = s_lRUp;
   s_lRUp = HB_FALSE;
   hb_retni( bUp ? 1 : 0 );
}

HB_FUNC( W32RMOUSEROW )
{
   hb_retni( s_iRRow );
}

/* S8 of hc-editor-mouse.md: FORGET the cell of the last right-button step. The
 * two getters above answer the cell of the gesture and do not clear it (the
 * panel needs it while the hold is being decided), so a screen that has already
 * consumed a press has to say so: without this the editor's context menu opened
 * again on every idle pass, because the same press was read forever. */
HB_FUNC( W32RMOUSERESET )
{
   s_iRRow = -1;
   s_iRCol = -1;
}

/* ---------------------------------------------------------------------------
 * El boton X de la ventana (ver WM_CLOSE en BpMouseProc).
 *
 *   W32CLOSESTEP()  -> 1 si hay un pedido sin atender, 0 si no. Es un PEEK:
 *                      leerla NO la limpia, para que el pedido sobreviva a
 *                      varias pantallas mientras el programa termina.
 *   W32CLOSERESET() -> lo limpia.
 *
 * Getters escalares, como el resto de este archivo: devolver arrays desde la
 * extension mata el proceso (hb_reta/hb_storni, ver AGENTS.md).
 * ------------------------------------------------------------------------- */
HB_FUNC( W32CLOSESTEP )
{
   hb_retni( s_lCloseReq ? 1 : 0 );
}

HB_FUNC( W32CLOSERESET )
{
   s_lCloseReq = HB_FALSE;
}

HB_FUNC( W32RMOUSECOL )
{
   hb_retni( s_iRCol );
}

/* ---------------------------------------------------------------------------
 * right-click-esc (S3/S6 de right-click-esc.md).
 *
 *   W32RMOUSEPLAIN() -> 1 mientras el gesto sigue siendo un click limpio (la
 *                       pulsacion y su liberacion sin un movimiento en medio).
 *                       Es un PEEK, como W32RMOUSEROW: leerlo NO lo limpia, y
 *                       asi el PRG puede verlo en el sondeo de la pulsacion y
 *                       otra vez en el de la liberacion, que caen en pasadas
 *                       distintas cuando el usuario mantiene el boton.
 * ------------------------------------------------------------------------- */
HB_FUNC( W32RMOUSEPLAIN )
{
   hb_retni( s_lRPlain ? 1 : 0 );
}

/* ---------------------------------------------------------------------------
 * The POINTER cell, with no button pressed (S6 of hc-ctx-menu-clipboard.md).
 *
 *   W32POINTERSTEP() -> 1 when the pointer is on a cell different from the last
 *                       one handed over; it sets it to 0 (the caller reads the
 *                       cell right after, so no move can slip between them)
 *   W32POINTERROW()  -> row of the pointer cell of the canvas (-1 = none yet)
 *   W32POINTERCOL()  -> column of the same cell (-1 = none yet)
 *
 * Scalar getters only: an array returned from this extension was measured to
 * kill the process (hb_reta/hb_storni, AGENTS.md trap 34). The cell is the
 * canvas one, because BpCellFromPoint() uses the grid W32SetGrid() was given.
 * ------------------------------------------------------------------------- */
HB_FUNC( W32POINTERSTEP )
{
   HB_BOOL bStep = s_lPtrStep;
   s_lPtrStep = HB_FALSE;
   hb_retni( bStep ? 1 : 0 );
}

HB_FUNC( W32POINTERROW )
{
   hb_retni( s_iPtrR );
}

HB_FUNC( W32POINTERCOL )
{
   hb_retni( s_iPtrC );
}

/* ---------------------------------------------------------------------------
 * The LEFT button, held or not (S1 of hc-editor-mouse.md).
 *
 *   W32LMOUSEDOWN() -> 1 while the left button is held, 0 when it is not
 *
 * The click channel says WHERE the press was; this says whether the gesture is
 * still going, which is what lets the Text editor tell a live drag from a
 * finished click (and stop extending the selection when the button is up).
 * Scalar only, like every other getter of this file: an array returned from
 * this extension kills the process (AGENTS trap 34). Not consuming anything -
 * the pointer channel keeps working exactly as before.
 * ------------------------------------------------------------------------- */
HB_FUNC( W32LMOUSEDOWN )
{
   hb_retni( s_lLDown ? 1 : 0 );
}

/* Milliseconds since the right button went down, measured on the message
 * itself: the PRG polls every 50 ms, so counting from the poll would add up to
 * one poll of delay to every hold. Returns 0 when the button is not held. */
HB_FUNC( W32RPRESSMS )
{
   if( ! s_lRDown )
      hb_retni( 0 );
   else
      hb_retni( ( int ) ( GetTickCount() - s_dwRDown ) );
}

/* Grid used to convert the client pixels of a click into a row and a column.
 * The caller passes the canvas it paints (MaxRow()+1, MaxCol()+1). */
HB_FUNC( W32SETGRID )
{
   int iRows = hb_parni( 1 );
   int iCols = hb_parni( 2 );
   if( iRows > 0 ) s_iGridRows = iRows;
   if( iCols > 0 ) s_iGridCols = iCols;
   hb_retl( HB_TRUE );
}

HB_FUNC( DOTMOUSECLICKROW )
{
   int iRow = s_iClickR;
   s_iClickR = -1;
   hb_retni( iRow );
}

/* .T. when the last click was made with SHIFT held (range selection), .F. after
 * being read once, like the row and the column */
HB_FUNC( W32CLICKSHIFT )
{
   HB_BOOL bVal = s_lClickShift;
   s_lClickShift = HB_FALSE;
   hb_retl( bVal );
}

/* same for CTRL (the panels do not use it yet; it keeps the ABI ready) */
/* S39: .T. when the click just collected was the second one of a double click;
 * read once, like the row, the column and the modifiers */
HB_FUNC( W32CLICKDBL )
{
   HB_BOOL bVal = s_lClickDbl;
   s_lClickDbl = HB_FALSE;
   hb_retl( bVal );
}

HB_FUNC( W32CLICKCTRL )
{
   HB_BOOL bVal = s_lClickCtrl;
   s_lClickCtrl = HB_FALSE;
   hb_retl( bVal );
}

/* Is SHIFT held RIGHT NOW? GetAsyncKeyState() is the LIVE physical state, and it
 * is the only source that works for the arrow keys of this GTWVG: measured, the
 * arrows do not reach the window hook (no WM_KEYDOWN: a trace printed
 * hookshift=0 while the ALT+letter path does receive WM_SYSKEYDOWN) and
 * HB_GTI_KBDSHIFTS reports only the locks (32 = NUMLOCK) for them. Shift+click
 * works because a click IS a window message and GetKeyState() sees the state
 * there. */
HB_FUNC( W32SHIFTDOWN )
{
   hb_retl( ( GetAsyncKeyState( VK_SHIFT ) & 0x8000 ) != 0 );
}

HB_FUNC( DOTMOUSECLICKCOL )
{
   int iCol = s_iClickC;
   s_iClickC = -1;
   hb_retni( iCol );
}

/* ---------------------------------------------------------------------------
 * Portapapeles de Windows.
 *
 * GTWVG de este Harbour no expone el portapapeles utilizable desde PRG, asi que
 * se copia con la API de Win32. El texto de Harbour va en la codepage OEM de la
 * consola, por eso se convierte con OemToCharA() antes de dejarlo en CF_TEXT
 * (sin eso los acentos y las enes salen como basura al pegarlo en Windows).
 *
 *   W32ClipPut( cText ) -> lOk
 * ------------------------------------------------------------------------- */
/* S81: open a file with the program Windows associates with it -- what `Enter`
 * does with everything that is not a script, a *.DBF or an archive. The "open"
 * verb IS the association; hb_run() would treat the name as a command line and
 * fail on a .pdf or a .jpg. Returns .T. when the shell accepted it (the return
 * value of ShellExecute is an HINSTANCE whose values above 32 mean success). */
HB_FUNC( W32SHELLOPEN )
{
   const char * szFile = hb_parc( 1 );
   HINSTANCE    h;

   if( szFile == NULL || *szFile == 0 )
      hb_retl( HB_FALSE );
   else
   {
      h = ShellExecuteA( NULL, "open", szFile, NULL, NULL, SW_SHOWNORMAL );
      hb_retl( ( HB_PTRUINT ) h > 32 );
   }
}

/* S13: the TEXT of the clipboard, the other half of W32ClipPut(). The console
 * byte space is OEM, so the answer is converted back with CharToOemA() -- the
 * exact inverse of the OemToCharA() the writer does. CF_UNICODETEXT is asked
 * first because that is what every modern program publishes; CF_TEXT covers the
 * old ones. Any failure answers "" and never NIL: a paste with nothing to paste
 * is a no-op, not an error, and this function must never raise (the caller runs
 * inside the key loop of a screen). */
HB_FUNC( W32CLIPGET )
{
   HGLOBAL h = NULL;
   char * pszAnsi = NULL;

   if( ! OpenClipboard( NULL ) )
   {
      hb_retc( "" );
      return;
   }
   h = GetClipboardData( CF_UNICODETEXT );
   if( h != NULL )
   {
      const WCHAR * pw = ( const WCHAR * ) GlobalLock( h );
      if( pw != NULL )
      {
         int nLen = WideCharToMultiByte( CP_ACP, 0, pw, -1, NULL, 0, NULL, NULL );
         if( nLen > 1 )
         {
            pszAnsi = ( char * ) hb_xgrab( ( HB_SIZE ) nLen + 1 );
            WideCharToMultiByte( CP_ACP, 0, pw, -1, pszAnsi, nLen, NULL, NULL );
            pszAnsi[ nLen ] = 0;
         }
         GlobalUnlock( h );
      }
   }
   else
   {
      h = GetClipboardData( CF_TEXT );
      if( h != NULL )
      {
         const char * psz = ( const char * ) GlobalLock( h );
         if( psz != NULL )
         {
            HB_SIZE nLen = ( HB_SIZE ) strlen( psz );
            pszAnsi = ( char * ) hb_xgrab( nLen + 1 );
            memcpy( pszAnsi, psz, ( size_t ) nLen );
            pszAnsi[ nLen ] = 0;
            GlobalUnlock( h );
         }
      }
   }
   CloseClipboard();
   if( pszAnsi == NULL )
      hb_retc( "" );
   else
   {
      CharToOemA( pszAnsi, pszAnsi );               /* ANSI -> OEM (consola) */
      hb_retc( pszAnsi );
      hb_xfree( pszAnsi );
   }
}

HB_FUNC( W32CLIPPUT )
{
   const char * szSrc = hb_parc( 1 );
   HB_SIZE nLen = hb_parclen( 1 );
   HGLOBAL h;
   char * p;
   BOOL lOk = FALSE;

   if( szSrc != NULL && OpenClipboard( NULL ) )
   {
      EmptyClipboard();
      h = GlobalAlloc( GMEM_MOVEABLE | GMEM_ZEROINIT, ( SIZE_T ) nLen + 1 );
      if( h != NULL )
      {
         p = ( char * ) GlobalLock( h );
         if( p != NULL )
         {
            memcpy( p, szSrc, ( size_t ) nLen );
            p[ nLen ] = 0;
            GlobalUnlock( h );
            OemToCharA( p, p );                    /* OEM (consola) -> ANSI */
            lOk = ( SetClipboardData( CF_TEXT, h ) != NULL );
         }
         if( ! lOk )
            GlobalFree( h );
      }
      CloseClipboard();
   }
   hb_retl( lOk );
}

/* ---------------------------------------------------------------------------
 * File clipboard: real FILES and FOLDERS, so that Ctrl+V on the desktop or in
 * Explorer pastes them (CF_HDROP). Paths travel as ANSI (CP_ACP), the same
 * convention W32Elevate() uses: Harbour's file functions are ANSI, so the OEM
 * conversion of W32ClipPut() is only for the text of the UI screen.
 *
 *   W32ClipFilesPut( aPaths ) -> lOk   absolute paths; also writes CF_TEXT with
 *                                      the list, one path per line (what
 *                                      Explorer does), so Notepad can paste it
 *   W32ClipFilesCount()       -> n     reads CF_HDROP ONCE into a static cache
 *   W32ClipFilesAt( n )       -> cPath 1-based; "" when out of range
 *
 * The extension NEVER returns an array (AGENTS.md trap 34: hb_reta() from here
 * crashed the process), hence the count + accessor pair, like W32ALTKEY( n ).
 * "Preferred DropEffect" = DROPEFFECT_COPY tells Explorer to COPY the entries
 * instead of moving or asking.
 * ------------------------------------------------------------------------- */
#define BP_CLIP_MAX   4096

/* the layout of a DROPFILES block; declared here instead of relying on the
 * header so the sizes are the ones of this build */
typedef struct
{
   DWORD pFiles;
   POINT pt;
   BOOL  fNC;
   BOOL  fWide;
} BP_DROPFILES;

static WCHAR * s_awClip[ BP_CLIP_MAX ];
static int     s_nClipCount = 0;

static void BpClipFreeAll( void )
{
   int i;
   for( i = 0; i < s_nClipCount; i++ )
   {
      free( s_awClip[ i ] );
      s_awClip[ i ] = NULL;
   }
   s_nClipCount = 0;
}

HB_FUNC( W32CLIPFILESPUT )
{
   PHB_ITEM pArray = hb_param( 1, HB_IT_ARRAY );
   HB_SIZE nCount, i;
   size_t nWideBytes = 0;
   HGLOBAL h = NULL, hEff = NULL, hText = NULL;
   BP_DROPFILES * pd = NULL;
   WCHAR * pw = NULL;
   char * ptxt = NULL;
   size_t nTextLen = 0;
   BOOL lOk = FALSE;

   if( pArray == NULL )
   {
      hb_retl( HB_FALSE );
      return;
   }
   nCount = hb_arrayLen( pArray );
   if( nCount == 0 )
   {
      hb_retl( HB_FALSE );
      return;
   }
   /* first pass: how many wide bytes the whole double-NUL block needs */
   for( i = 1; i <= nCount; i++ )
   {
      const char * psz = hb_arrayGetCPtr( pArray, i );
      int nWide;
      if( psz == NULL || psz[ 0 ] == 0 )
         continue;
      nWide = MultiByteToWideChar( CP_ACP, 0, psz, -1, NULL, 0 );
      if( nWide < 1 )
         continue;
      nWideBytes += ( ( size_t ) nWide ) * sizeof( WCHAR );
      nTextLen += strlen( psz ) + 2;
   }
   if( nWideBytes == 0 )
   {
      hb_retl( HB_FALSE );
      return;
   }
   /* one extra NUL closes the list (the converted strings bring their own) */
   h = GlobalAlloc( GMEM_MOVEABLE | GMEM_ZEROINIT,
                    sizeof( BP_DROPFILES ) + nWideBytes + sizeof( WCHAR ) );
   if( h == NULL )
   {
      hb_retl( HB_FALSE );
      return;
   }
   pd = ( BP_DROPFILES * ) GlobalLock( h );
   if( pd == NULL )
   {
      GlobalFree( h );
      hb_retl( HB_FALSE );
      return;
   }
   pd->pFiles = sizeof( BP_DROPFILES );
   pd->pt.x   = 0;
   pd->pt.y   = 0;
   pd->fNC    = FALSE;
   pd->fWide  = TRUE;
   pw = ( WCHAR * ) ( ( char * ) pd + sizeof( BP_DROPFILES ) );
   for( i = 1; i <= nCount; i++ )
   {
      const char * psz = hb_arrayGetCPtr( pArray, i );
      int nWide;
      if( psz == NULL || psz[ 0 ] == 0 )
         continue;
      nWide = MultiByteToWideChar( CP_ACP, 0, psz, -1, pw,
                      ( int ) ( ( nWideBytes / sizeof( WCHAR ) ) + 1 ) );
      if( nWide < 1 )
         continue;
      pw += nWide;
   }
   *pw = 0;
   GlobalUnlock( h );
   /* the plain text copy: one path per line, ANSI, like Explorer */
   if( nTextLen > 0 )
   {
      size_t nAt = 0;
      hText = GlobalAlloc( GMEM_MOVEABLE | GMEM_ZEROINIT, nTextLen + 4 );
      if( hText != NULL )
      {
         ptxt = ( char * ) GlobalLock( hText );
         if( ptxt == NULL )
         {
            GlobalFree( hText );
            hText = NULL;
         }
      }
      if( ptxt != NULL )
      {
         for( i = 1; i <= nCount; i++ )
         {
            const char * psz = hb_arrayGetCPtr( pArray, i );
            size_t nLen;
            if( psz == NULL || psz[ 0 ] == 0 )
               continue;
            nLen = strlen( psz );
            memcpy( ptxt + nAt, psz, nLen );
            nAt += nLen;
            ptxt[ nAt++ ] = '\r';
            ptxt[ nAt++ ] = '\n';
         }
         ptxt[ nAt ] = 0;
         GlobalUnlock( hText );
      }
   }
   /* the copy effect: without it Explorer may MOVE the entry it pastes */
   hEff = GlobalAlloc( GMEM_MOVEABLE | GMEM_ZEROINIT, sizeof( DWORD ) );
   if( hEff != NULL )
   {
      DWORD * pdw = ( DWORD * ) GlobalLock( hEff );
      if( pdw != NULL )
      {
         *pdw = DROPEFFECT_COPY;
         GlobalUnlock( hEff );
      }
      else
      {
         GlobalFree( hEff );
         hEff = NULL;
      }
   }
   if( OpenClipboard( NULL ) )
   {
      UINT uEffFmt = RegisterClipboardFormatA( "Preferred DropEffect" );
      EmptyClipboard();
      if( SetClipboardData( CF_HDROP, h ) != NULL )
      {
         h   = NULL;                     /* the clipboard owns it now */
         lOk = TRUE;
      }
      if( hText != NULL )
         SetClipboardData( CF_TEXT, hText );
      if( hEff != NULL && uEffFmt != 0 )
         SetClipboardData( uEffFmt, hEff );
      CloseClipboard();
   }
   if( h != NULL )
      GlobalFree( h );
   hb_retl( lOk );
}

/* the clipboard is read ONCE and kept in the static cache: a handle of
 * CF_HDROP is not valid after CloseClipboard(), so the strings are copied out
 * here (DragQueryFile sizes and copies wide) */
static void BpClipLoad( void )
{
   HANDLE hDrop;
   UINT nFiles, i;

   BpClipFreeAll();
   if( ! OpenClipboard( NULL ) )
      return;
   hDrop = GetClipboardData( CF_HDROP );
   if( hDrop != NULL )
   {
      nFiles = DragQueryFileW( ( HDROP ) hDrop, 0xFFFFFFFF, NULL, 0 );
      for( i = 0; i < nFiles && s_nClipCount < BP_CLIP_MAX; i++ )
      {
         UINT nLen = DragQueryFileW( ( HDROP ) hDrop, i, NULL, 0 );
         WCHAR * pw;
         if( nLen == 0 )
            continue;
         pw = ( WCHAR * ) malloc( ( ( size_t ) nLen + 1 ) * sizeof( WCHAR ) );
         if( pw == NULL )
            continue;
         if( DragQueryFileW( ( HDROP ) hDrop, i, pw, nLen + 1 ) == 0 )
         {
            free( pw );
            continue;
         }
         s_awClip[ s_nClipCount++ ] = pw;
      }
   }
   CloseClipboard();
}

HB_FUNC( W32CLIPFILESCOUNT )
{
   BpClipLoad();
   hb_retni( s_nClipCount );
}

HB_FUNC( W32CLIPFILESAT )
{
   int n = hb_parni( 1 );
   int nLen;
   char * psz;

   if( n < 1 || n > s_nClipCount )
   {
      hb_retc( "" );
      return;
   }
   nLen = WideCharToMultiByte( CP_ACP, 0, s_awClip[ n - 1 ], -1, NULL, 0, NULL, NULL );
   if( nLen < 1 )
   {
      hb_retc( "" );
      return;
   }
   psz = ( char * ) hb_xgrab( ( HB_SIZE ) nLen + 1 );
   WideCharToMultiByte( CP_ACP, 0, s_awClip[ n - 1 ], -1, psz, nLen, NULL, NULL );
   hb_retc( psz );
   hb_xfree( psz );
}

/* the two combos the hook recorded (S7): the panel loop asks "is there one?"
 * and takes it, which also clears it. Scalars, never arrays (trap 34). */
HB_FUNC( W32CLIPKEYSTEP )
{
   hb_retni( s_nClipKey != 0 ? 1 : 0 );
}

HB_FUNC( W32CLIPKEY )
{
   int n = s_nClipKey;
   s_nClipKey = 0;
   hb_retni( n );
}

/* S2/S3 of recycle-bin-delete.md: the Shift+Del channel. The panel loop asks
 * "is one pending?" and the read clears it (the same drain-on-read as
 * DOTMOUSECLICKROW), so one stroke is one delete. Scalars, never arrays
 * (AGENTS.md trap 34). */
HB_FUNC( W32HARDDELSTEP )
{
   int n = s_lHardDel ? 1 : 0;
   s_lHardDel = HB_FALSE;
   hb_retni( n );
}

/* flush: the pending stroke is thrown away unread. The PRG fallback uses it to
 * discard the hook copy of a stroke it already handled from Inkey(). */
HB_FUNC( W32HARDDELRESET )
{
   s_lHardDel = HB_FALSE;
   hb_retni( 1 );
}

/* editor-ctrl-chords.md S2/S4: the word chords of the Text editor, recorded on
 * WM_KEYDOWN with the CTRL bit held. Ctrl+Left and Ctrl+Z share ONE code in
 * this driver (26, measured), so this is the only source that can tell them
 * apart. 0 = nothing, 1 = Ctrl+Left, 2 = Ctrl+Right; the first read clears it
 * (scalars, never arrays: AGENTS trap 34) and the editor flushes it when the
 * screen opens so a chord typed elsewhere cannot fire later. */
HB_FUNC( W32WORDKEYSTEP )
{
   hb_retni( s_nWordKey != 0 ? 1 : 0 );
}

HB_FUNC( W32WORDKEY )
{
   int n = s_nWordKey;
   s_nWordKey = 0;
   hb_retni( n );
}

/* flush: the pending chord is thrown away unread (the editor calls it on open) */
HB_FUNC( W32WORDKEYRESET )
{
   s_nWordKey = 0;
   hb_retni( 0 );
}

/* ---------------------------------------------------------------------------
 * S75: elevacion (UAC), para agregar la regla del firewall del Commander Link.
 *
 * hb_processRun() usa CreateProcess y NO eleva nada, asi que la unica forma de
 * pedir privilegios desde PRG es ShellExecuteEx con el verbo "runas" (lo que
 * muestra el cartel de la UAC). El proceso se espera para poder devolver su
 * codigo de salida, porque el PRG pregunta despues si la regla quedo de verdad.
 *
 *   W32Elevate( cFile, cParams ) -> codigo de salida, -1 si no se pudo lanzar
 *   W32ElevErr()                 -> GetLastError() de ese fallo; 1223 es
 *                                   ERROR_CANCELLED, o sea el usuario dijo NO
 *
 * SEE_MASK_FLAG_NO_UI evita los carteles propios del shell; el unico dialogo
 * que aparece es el de la UAC. Se devuelven escalares (nunca arrays): devolver
 * un array desde esta extension tumba el proceso (AGENTS.md trampa 34).
 * ------------------------------------------------------------------------- */
static DWORD s_dwElevErr = 0;

HB_FUNC( W32ELEVATE )
{
   const char * pszFile = hb_parc( 1 );
   const char * pszParams = HB_ISNIL( 2 ) ? NULL : hb_parc( 2 );
   WCHAR wszFile[ MAX_PATH * 2 ];
   WCHAR wszParams[ 2048 ];
   SHELLEXECUTEINFOW sei;
   DWORD dwExit = 0;

   s_dwElevErr = 0;
   if( pszFile == NULL ||
       MultiByteToWideChar( CP_ACP, 0, pszFile, -1, wszFile,
                            ( int ) ( sizeof( wszFile ) / sizeof( WCHAR ) ) ) == 0 )
   {
      s_dwElevErr = ERROR_INVALID_PARAMETER;
      hb_retni( -1 );
      return;
   }
   wszParams[ 0 ] = 0;
   if( pszParams != NULL )
   {
      if( MultiByteToWideChar( CP_ACP, 0, pszParams, -1, wszParams,
                               ( int ) ( sizeof( wszParams ) / sizeof( WCHAR ) ) ) == 0 )
      {
         s_dwElevErr = ERROR_BUFFER_OVERFLOW;
         hb_retni( -1 );
         return;
      }
   }

   memset( &sei, 0, sizeof( sei ) );
   sei.cbSize       = sizeof( sei );
   sei.fMask        = SEE_MASK_NOCLOSEPROCESS | SEE_MASK_FLAG_NO_UI;
   sei.lpVerb       = L"runas";
   sei.lpFile       = wszFile;
   sei.lpParameters = ( pszParams != NULL ) ? wszParams : NULL;
   sei.nShow        = SW_HIDE;

   if( ! ShellExecuteExW( &sei ) )
   {
      s_dwElevErr = GetLastError();
      hb_retni( -1 );
      return;
   }
   if( sei.hProcess != NULL )
   {
      /* netsh is short: a generous cap so a slow machine is not cut off, but
       * an elevated cmd that never ends cannot hang hwBro forever */
      if( WaitForSingleObject( sei.hProcess, 120000 ) == WAIT_OBJECT_0 )
         GetExitCodeProcess( sei.hProcess, &dwExit );
      CloseHandle( sei.hProcess );
   }
   hb_retnl( ( long ) dwExit );
}

HB_FUNC( W32ELEVERR )
{
   hb_retnl( ( long ) s_dwElevErr );
}

/* ---------------------------------------------------------------------------
 * S75: lectura del registro y ejecucion SIN ventana.
 *
 * POR QUE EXISTEN: el chequeo del firewall del Commander Link leia el registro
 * con `reg query` y agregaba la regla lanzando `cmd`: los dos son programas de
 * CONSOLA, asi que Windows abre una ventana negra y la cierra, y con cuatro
 * consultas seguidas el parpadeo se ve. Estas dos funciones dejan el camino sin
 * un solo proceso de consola visible:
 *
 *   W32RegDump( cKey )             -> el contenido de la clave como texto
 *                                     "<nombre>\t<TIPO>\t<dato>\r\n", o "" si
 *                                     no se puede abrir. Sin procesos.
 *   W32RunHidden( cFile, cParams ) -> codigo de salida del programa, lanzado con
 *                                     CREATE_NO_WINDOW (no hay consola que
 *                                     mostrar), -1 si no se pudo lanzar.
 *
 * El texto de W32RegDump imita la forma de `reg query` a proposito: el parseo
 * del PRG (y sus 39 aserciones) no cambia, porque los nombres de tipo
 * (REG_SZ, REG_DWORD...) no estan traducidos.
 * ------------------------------------------------------------------------- */

/* el nombre de tipo que el PRG busca; para los tipos que no se usan se escribe
 * su nombre real, asi el parseo los ignora en vez de confundirlos */
static const char * bp_regTypeName( DWORD dwType )
{
   switch( dwType )
   {
      case REG_SZ:        return "REG_SZ";
      case REG_EXPAND_SZ: return "REG_EXPAND_SZ";
      case REG_DWORD:     return "REG_DWORD";
      case REG_QWORD:     return "REG_QWORD";
      case REG_MULTI_SZ:  return "REG_MULTI_SZ";
      case REG_BINARY:    return "REG_BINARY";
      default:            return "REG_NONE";
   }
}

HB_FUNC( W32REGDUMP )
{
   const char * pszKey = hb_parc( 1 );
   HKEY hKey = NULL;
   DWORD dwValues = 0, dwMaxName = 0, dwMaxData = 0, dwIndex = 0;
   char * pBuf = NULL;
   char * pName = NULL;
   char * pData = NULL;
   HB_SIZE nLen = 0, nCap = 0;
   const char * szSub = pszKey;

   /* "HKLM\..." y "HKEY_LOCAL_MACHINE\..." se aceptan y se descartan: la clave
    * abierta es siempre HKEY_LOCAL_MACHINE, que es donde vive el firewall */
   if( pszKey == NULL )
   {
      hb_retc( "" );
      return;
   }
   if( _strnicmp( szSub, "HKLM\\", 5 ) == 0 )
      szSub += 5;
   else if( _strnicmp( szSub, "HKEY_LOCAL_MACHINE\\", 19 ) == 0 )
      szSub += 19;

   if( RegOpenKeyExA( HKEY_LOCAL_MACHINE, szSub, 0, KEY_READ, &hKey ) != ERROR_SUCCESS )
   {
      hb_retc( "" );
      return;
   }
   if( RegQueryInfoKeyA( hKey, NULL, NULL, NULL, NULL, NULL, NULL, &dwValues,
                         &dwMaxName, &dwMaxData, NULL, NULL ) != ERROR_SUCCESS )
      dwValues = 0;
   if( dwValues > 0 )
   {
      nCap = ( HB_SIZE ) dwValues * ( ( HB_SIZE ) dwMaxName + ( HB_SIZE ) dwMaxData + 40 ) + 64;
      pBuf  = ( char * ) hb_xgrab( nCap );
      pName = ( char * ) hb_xgrab( ( HB_SIZE ) dwMaxName + 2 );
      pData = ( char * ) hb_xgrab( ( HB_SIZE ) dwMaxData + 2 );
      for( dwIndex = 0; dwIndex < dwValues; dwIndex++ )
      {
         DWORD dwType = 0;
         DWORD cchName = dwMaxName + 1;
         DWORD cbData = dwMaxData + 1;
         const char * pszVal;
         char szNum[ 32 ];
         size_t nAdd;
         DWORD i;

         pName[ 0 ] = 0;
         pData[ 0 ] = 0;
         if( RegEnumValueA( hKey, dwIndex, pName, &cchName, NULL, &dwType,
                            ( BYTE * ) pData, &cbData ) != ERROR_SUCCESS )
            continue;
         if( dwType == REG_DWORD )
         {
            sprintf( szNum, "0x%lx", ( unsigned long ) *( DWORD * ) pData );
            pszVal = szNum;
         }
         else if( dwType == REG_SZ || dwType == REG_EXPAND_SZ || dwType == REG_MULTI_SZ )
         {
            pData[ cbData < dwMaxData + 1 ? cbData : dwMaxData ] = 0;
            for( i = 0; i < cbData; i++ )
               if( pData[ i ] == 0 && i + 1 < cbData )
                  pData[ i ] = '|';        /* el MULTI_SZ queda en una linea */
            pszVal = pData;
         }
         else
            pszVal = "";
         /* la capacidad se calcula con los maximos de la clave y se vuelve a
          * comprobar igual: un dato inesperadamente largo no puede desbordar */
         nAdd = strlen( pName ) + strlen( bp_regTypeName( dwType ) ) + strlen( pszVal ) + 4;
         if( nLen + nAdd + 1 > nCap )
         {
            nCap = ( nLen + nAdd + 1 ) * 2;
            pBuf = ( char * ) hb_xrealloc( pBuf, nCap );
         }
         nLen += ( HB_SIZE ) sprintf( pBuf + nLen, "%s\t%s\t%s\r\n",
                                      pName, bp_regTypeName( dwType ), pszVal );
      }
   }
   if( hKey != NULL )
      RegCloseKey( hKey );
   if( pName != NULL )
      hb_xfree( pName );
   if( pData != NULL )
      hb_xfree( pData );
   if( pBuf == NULL )
      hb_retc( "" );
   else
   {
      hb_retclen( pBuf, nLen );
      hb_xfree( pBuf );
   }
}

HB_FUNC( W32RUNHIDDEN )
{
   const char * pszFile = hb_parc( 1 );
   const char * pszParams = HB_ISNIL( 2 ) ? NULL : hb_parc( 2 );
   char szCmd[ 4096 ];
   STARTUPINFOA si;
   PROCESS_INFORMATION pi;
   DWORD dwExit = 0;

   if( pszFile == NULL )
   {
      hb_retni( -1 );
      return;
   }
   if( pszParams != NULL && pszParams[ 0 ] != 0 )
      sprintf( szCmd, "\"%s\" %s", pszFile, pszParams );
   else
      sprintf( szCmd, "\"%s\"", pszFile );

   memset( &si, 0, sizeof( si ) );
   memset( &pi, 0, sizeof( pi ) );
   si.cb          = sizeof( si );
   si.dwFlags     = STARTF_USESHOWWINDOW;
   si.wShowWindow = SW_HIDE;
   /* CREATE_NO_WINDOW es la clave: el hijo no recibe consola, asi que no hay
    * ventana negra que aparecer y desaparecer */
   if( ! CreateProcessA( NULL, szCmd, NULL, NULL, FALSE, CREATE_NO_WINDOW,
                         NULL, NULL, &si, &pi ) )
   {
      hb_retni( -1 );
      return;
   }
   if( WaitForSingleObject( pi.hProcess, 120000 ) == WAIT_OBJECT_0 )
      GetExitCodeProcess( pi.hProcess, &dwExit );
   CloseHandle( pi.hThread );
   CloseHandle( pi.hProcess );
   hb_retnl( ( long ) dwExit );
}

/* -------------------------------------------------------------------------
 * S6/S10 of hc-file-attributes.md: set the last write time of a path.
 *
 * WHY IT EXISTS (measured, AGENTS.md trap 66): hb_vfTimeSet() of this Harbour
 * opens the path with FO_READWRITE, and a DIRECTORY cannot be opened for
 * writing, so it answered .F. and the attributes dialog counted the directory
 * as failed. Here the handle is opened with FILE_WRITE_ATTRIBUTES and
 * FILE_FLAG_BACKUP_SEMANTICS - the flag that makes a directory openable, and it
 * is harmless for a file - and SetFileTime writes the last write time only.
 *
 * W32SETSTAMP( cPath, "YYYYMMDDHHMMSS" )  ->  1 ok / 0 failed
 *   The stamp is LOCAL time as typed by the user; it is converted to UTC, which
 *   is what SetFileTime expects (a raw local value would shift the clock by the
 *   time zone offset). Scalars only: an array returned from this extension
 *   kills the process (AGENTS.md trap 34).
 * ------------------------------------------------------------------------- */
HB_FUNC( W32SETSTAMP )
{
   const char * pszPath  = hb_parc( 1 );
   const char * pszStamp = hb_parc( 2 );
   WCHAR wszPath[ MAX_PATH * 2 ];
   SYSTEMTIME stLocal, stUtc;
   FILETIME ft;
   HANDLE h;
   int i;

   if( pszPath == NULL || pszStamp == NULL || lstrlenA( pszStamp ) != 14 )
   {
      hb_retni( 0 );
      return;
   }
   for( i = 0; i < 14; i++ )
   {
      if( pszStamp[ i ] < '0' || pszStamp[ i ] > '9' )
      {
         hb_retni( 0 );
         return;
      }
   }
   memset( &stLocal, 0, sizeof( stLocal ) );
   if( sscanf( pszStamp, "%4hu%2hu%2hu%2hu%2hu%2hu",
               &stLocal.wYear, &stLocal.wMonth, &stLocal.wDay,
               &stLocal.wHour, &stLocal.wMinute, &stLocal.wSecond ) != 6 )
   {
      hb_retni( 0 );
      return;
   }
   if( MultiByteToWideChar( CP_ACP, 0, pszPath, -1, wszPath,
                            ( int ) ( sizeof( wszPath ) / sizeof( WCHAR ) ) ) == 0 )
   {
      hb_retni( 0 );
      return;
   }
   /* local -> UTC. A local time inside the spring-forward gap has no UTC
    * counterpart: fail instead of writing a value shifted by the zone offset
    * and reporting success (the PRG then counts the entry as failed, which is
    * the truth); the hb_vfTimeSet() fallback stays as the second chance. */
   if( ! TzSpecificLocalTimeToSystemTime( NULL, &stLocal, &stUtc ) )
   {
      hb_retni( 0 );
      return;
   }
   if( ! SystemTimeToFileTime( &stUtc, &ft ) )
   {
      hb_retni( 0 );
      return;
   }
   h = CreateFileW( wszPath, FILE_WRITE_ATTRIBUTES,
                    FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                    NULL, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, NULL );
   if( h == INVALID_HANDLE_VALUE )
   {
      hb_retni( 0 );
      return;
   }
   i = SetFileTime( h, NULL, NULL, &ft ) ? 1 : 0;
   CloseHandle( h );
   hb_retni( i );
}

/* ---------------------------------------------------------------------------
 * S1 of recycle-bin-delete.md: send a list of files and directory trees to the
 * Windows Recycle Bin.
 *
 * W32RECYCLE( aPaths )  ->  1 the whole list went to the Recycle Bin,
 *                           0 it did NOT.
 *   One SHFileOperationW() call for the whole list, so the shell sees ONE
 *   operation. fFrom is the double-NUL terminated WCHAR list the API wants and
 *   FOF_ALLOWUNDO makes the Recycle Bin the destination. FOF_SILENT |
 *   FOF_NOCONFIRMATION | FOF_NOERRORUI keep the shell quiet: the confirmation
 *   and the error message are the program's own (S4/S5).
 *   FOF_WANTNUKEWARNING is the S5 hole: for an entry the bin CANNOT hold
 *   (bigger than the per-volume quota, a volume with no bin, a UNC path) the
 *   shell deletes it permanently, and FOF_NOCONFIRMATION would swallow that
 *   question and report success; this flag makes the shell ask its own
 *   "permanently delete?" first, so the user is never robbed silently.
 *   0 is answered for an empty array, a non-string or empty element, a path
 *   that does not fit the buffer, a win32 error, and any aborted operation.
 *   There is NO retry and NO fallback to a permanent delete: an entry the
 *   Recycle Bin refuses is reported, never deleted for real behind the user's
 *   back. The paths are ANSI (what the PRG holds) and are widened with
 *   MultiByteToWideChar( CP_ACP ), the same convention W32SETSTAMP() uses.
 *   Scalars only: an array returned from this extension kills the process
 *   (AGENTS.md trap 34).
 * ------------------------------------------------------------------------- */
HB_FUNC( W32RECYCLE )
{
   PHB_ITEM        pArray = hb_param( 1, HB_IT_ARRAY );
   HB_SIZE         nLen, i, nNeed = 0;
   WCHAR *         pFrom;
   WCHAR *         pPos;
   SHFILEOPSTRUCTW sfo;
   int             iOk;

   if( pArray == NULL )
   {
      hb_retni( 0 );
      return;
   }
   nLen = hb_arrayLen( pArray );
   if( nLen == 0 )
   {
      hb_retni( 0 );
      return;
   }
   /* first pass: measure the list. Every path contributes its WCHARs plus the
    * terminating NUL, and one extra NUL closes the list. hb_arrayGetCLen() is
    * 0 for an empty string AND for an element that is not a string (the char
    * accessor answers "" for those), so both are rejected here. */
   for( i = 1; i <= nLen; i++ )
   {
      const char * psz = hb_arrayGetCPtr( pArray, i );
      int          n;

      if( psz == NULL || hb_arrayGetCLen( pArray, i ) == 0 )
      {
         hb_retni( 0 );
         return;
      }
      n = MultiByteToWideChar( CP_ACP, 0, psz, -1, NULL, 0 );
      if( n <= 0 )
      {
         hb_retni( 0 );
         return;
      }
      nNeed += ( HB_SIZE ) n;
   }
   pFrom = ( WCHAR * ) hb_xgrab( ( nNeed + 1 ) * sizeof( WCHAR ) );
   /* second pass: widen. The count of a successful conversion includes the
    * NUL, so pPos already points at the next slot. */
   pPos = pFrom;
   for( i = 1; i <= nLen; i++ )
   {
      int n = MultiByteToWideChar( CP_ACP, 0, hb_arrayGetCPtr( pArray, i ), -1, pPos,
                                   ( int ) ( nNeed + 1 - ( HB_SIZE ) ( pPos - pFrom ) ) );
      if( n <= 0 )
      {
         hb_xfree( pFrom );
         hb_retni( 0 );
         return;
      }
      pPos += n;
   }
   *pPos = 0;                             /* the extra NUL that closes the list */

   memset( &sfo, 0, sizeof( sfo ) );
   sfo.hwnd   = NULL;                     /* no owner window: no UI at all    */
   sfo.wFunc  = FO_DELETE;
   sfo.pFrom  = pFrom;
   sfo.pTo    = NULL;
   sfo.fFlags = ( FILEOP_FLAGS ) ( FOF_ALLOWUNDO | FOF_WANTNUKEWARNING |
                                   FOF_NOCONFIRMATION | FOF_SILENT |
                                   FOF_NOERRORUI );

   iOk = ( SHFileOperationW( &sfo ) == 0 && ! sfo.fAnyOperationsAborted ) ? 1 : 0;
   hb_xfree( pFrom );
   hb_retni( iOk );
}

/* ---------------------------------------------------------------------------
 *  W32PRINTTEXT( cPrinter, cText, cJob ) -> .T. / .F.
 *
 *  S6 of odd/tasks/list-to-print.md: printing the LIST through a Windows
 *  printer. WHY THIS EXISTS (measured, and it is the trap): sending the listing
 *  as RAW bytes to the spooler (hbwin's win_PrintFileRaw) only works on
 *  text-mode printers. "Microsoft Print to PDF" and PDFCreator are GDI class
 *  drivers: they receive bytes that mean nothing to them and produce an EMPTY
 *  page - the user got blank PDFs from both. The only portable way is to RENDER
 *  with GDI on the printer's device context, so the driver rasterises real text
 *  whatever the destination is (physical printer, PDF, XPS, PostScript).
 *
 *  The listing is monospaced (Courier New) so the columns keep their alignment,
 *  the font is sized in points against the DC's LOGPIXELSY, and a new page
 *  starts when the printable height is used up. cText is split on LF with an
 *  optional CR before it (the caller joins with hb_eol()).
 *
 *  hbwin is still the one that enumerates the printers (win_printerList); this
 *  helper only draws. It answers .F. on any failure (no DC, StartDoc refused,
 *  EndDoc refused) and never leaves a job half open.
 * ------------------------------------------------------------------------- */
HB_FUNC( W32PRINTTEXT )
{
   const char * pszPrn = hb_parc( 1 );
   const char * pszTxt = hb_parc( 2 );
   const char * pszJob = hb_parc( 3 );
   HDC          hDC;
   DOCINFOA     di;
   HFONT        hFont, hOld = NULL;
   TEXTMETRIC   tm;
   int          nY, nX, nMaxY, nLen;
   const char * p, * q;

   if( pszPrn == NULL || pszTxt == NULL )
   {
      hb_retl( 0 );
      return;
   }

   hDC = CreateDCA( "WINSPOOL", pszPrn, NULL, NULL );
   if( hDC == NULL )
   {
      hb_retl( 0 );
      return;
   }

   ZeroMemory( &di, sizeof( di ) );
   di.cbSize        = sizeof( di );
   di.lpszDocName   = ( pszJob != NULL && *pszJob != '\0' ) ? pszJob : ( char * ) "hwBro LIST";
   di.lpszOutput    = NULL;
   di.lpszDatatype  = NULL;     /* NULL = let the driver receive GDI, not bytes */
   di.fwType        = 0;

   if( StartDocA( hDC, &di ) <= 0 )
   {
      DeleteDC( hDC );
      hb_retl( 0 );
      return;
   }

   SetBkMode( hDC, TRANSPARENT );
   SetTextColor( hDC, RGB( 0, 0, 0 ) );
   hFont = CreateFontA( -MulDiv( 9, GetDeviceCaps( hDC, LOGPIXELSY ), 72 ),
                        0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, DEFAULT_CHARSET,
                        OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, DEFAULT_QUALITY,
                        FIXED_PITCH | FF_MODERN, "Courier New" );
   if( hFont != NULL )
   {
      hOld = ( HFONT ) SelectObject( hDC, hFont );
   }
   if( ! GetTextMetrics( hDC, &tm ) )
   {
      tm.tmHeight = GetDeviceCaps( hDC, LOGPIXELSY ) / 6;
      if( tm.tmHeight < 1 )
      {
         tm.tmHeight = 1;
      }
   }

   /* half an inch at the left, one text row at the top, one at the bottom */
   nX    = GetDeviceCaps( hDC, LOGPIXELSX ) / 2;
   nMaxY = GetDeviceCaps( hDC, VERTRES ) - ( 2 * tm.tmHeight );

   StartPage( hDC );
   nY = tm.tmHeight;
   for( p = pszTxt; *p != '\0'; )
   {
      q = p;
      while( *q != '\0' && *q != '\n' )
      {
         q++;
      }
      nLen = ( int ) ( q - p );
      if( nLen > 0 && p[ nLen - 1 ] == '\r' )
      {
         nLen--;
      }
      if( nY > nMaxY )
      {
         EndPage( hDC );
         StartPage( hDC );
         nY = tm.tmHeight;
      }
      if( nLen > 0 )
      {
         TextOutA( hDC, nX, nY, p, nLen );
      }
      nY += tm.tmHeight;
      p = ( *q == '\n' ) ? q + 1 : q;
   }
   EndPage( hDC );

   if( hOld != NULL )
   {
      SelectObject( hDC, hOld );
   }
   if( hFont != NULL )
   {
      DeleteObject( hFont );
   }

   if( EndDoc( hDC ) <= 0 )
   {
      DeleteDC( hDC );
      hb_retl( 0 );
      return;
   }
   DeleteDC( hDC );
   hb_retl( 1 );
}
