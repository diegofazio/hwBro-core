/*
 * bp_ui.prg - DOS style screen helpers (GTWVG)
 * hwBro - Harbour + MSVC x64
 */
#include "inkey.ch"
#include "fileio.ch"
#include "hbgtinfo.ch"
#include "bp_def.ch"

/* Labels of the two buttons of UiConfirm(). They are defines because the paint
 * (UiConfirmBtn) and the click hit-test (UiConfirmClick) have to agree on their
 * width: a click acts on a button only when it falls inside it. */
#define UI_YES_LBL   "  Yes  "
#define UI_NO_LBL    "  No  "
/* the single button of the message boxes (UiMsg/UiInfo/UiErr). It is a define
 * for the same reason as the two above: the paint and the click hit-test have to
 * agree on its width (S60). */
#define UI_OK_LBL    "  OK  "
/* S4/S5 (splash-mouse.md): the "Data engine:" line of the splash. The prefix,
 * the separator and the "there are more" tail are defines because the builder
 * (UiRddLine) and the assertions of the bank have to agree on them; the
 * fallback is the exact line the splash showed before it was built at run time
 * - it is what the user reads when the engine answers nothing. */
#define UI_RDD_PRE      "Data engine: "
#define UI_RDD_SEP      " / "
#define UI_RDD_TAIL     " ..."
#define UI_RDD_FALLBACK "Data engine: DBFCDX / DBFNTX"

/* ---------- color / screen helpers ---------- */

/* nesting counter of the deferred painting (see UiPaintBegin/UiPaintEnd) */
STATIC s_nPaint := 0
/* state of the system cursor saved while the painting block lasts
 * (NIL = the cursor was already hidden or was never saved: nothing has to be
 * restored). See UiPaintBegin(). */
STATIC s_nCurSave := NIL
/* progress bar state (UiProgBegin/UiProgUpdate/UiProgEnd): it has to live
 * up here because Harbour does not allow STATIC after code */
STATIC s_lProgOn    := .F.
STATIC s_nProgTotal := 0
STATIC s_nProgPct   := -1
STATIC s_cProgText  := ""
STATIC s_lProgEsc   := .F.
/* tick of the last repaint of the progress box: the throttle of UiProgUpdate()
 * - see PROG_REFRESH_MS */
STATIC s_nProgMs    := 0
/* Click source of the modals of this module: a block {|| { row, column } } that
 * answers NIL when there was no click. hwbro.prg installs the one that reads
 * the window hook of bp_win32.c; with no hook - every headless bank, and any
 * build without the C extension - the modals simply have no mouse, which is
 * why this module never calls the W32* helpers itself. */
STATIC s_bUiDbl := NIL
STATIC s_bUiWheel := NIL
STATIC s_bUiClick := NIL
/* right-click-esc (S5 of right-click-esc.md): a block {|| lPlainRightClick }
 * that answers .T. when ONE plain right click (press, no move, release) has
 * happened since the last ask. Main() wires it to HcMouseRightClick(), with the
 * same rule as the click above: this module never calls the W32* or Hc*
 * helpers, so the three headless banks keep linking it and a build without the
 * hook simply has no right-click-as-Esc. */
STATIC s_bUiRClick := NIL
/* S100: the clipboard, the combos and SHIFT of the inline editor, with the same
 * rule as the click: this module NEVER calls W32* or Hc* (it is linked into the
 * three headless banks), so Main() installs these four hooks and a build
 * without them simply has no clipboard and no Shift+arrow selection, which is
 * exactly what it had before. */
STATIC s_bUiClipPut := NIL
STATIC s_bUiClipGet := NIL
STATIC s_bUiChord   := NIL
STATIC s_bUiShift   := NIL
/* S13.7: the OPT-IN Alt chord of the inline editor, with the same rule as the
 * click: this module never calls the W32 helpers or Hc* functions itself (it is
 * linked into the three headless banks), so Main() installs {| | HcAltChord() }
 * and, with no hook (every headless bank), a field editor behaves exactly as it
 * did before. <s_cUiAltPend> is the chord already asked for and not yet taken
 * by the caller (UiAltChord() is what consumes it). */
STATIC s_bUiAlt := NIL
STATIC s_cUiAltPend := ""
/* S15: the key that closed the LAST UiLineEdit() (K_ENTER, K_TAB, K_SH_TAB or
 * K_ESC). Read with UiEditExit() by a caller that has to know whether the user
 * confirmed with Enter, walked to the next control with Tab, or cancelled; the
 * rest of the program does not ask and keeps its behaviour untouched. */
STATIC s_nUiEditExit := K_ENTER
/* B2 (window-close.md S4): the close request of the window (its X button), with
 * the same rule as the other hooks: this module NEVER calls W32* or Bp* (it is
 * linked into the three headless banks), so Main() installs a block that peeks
 * the latch of bp_win32.c and every modal asks it once per pass of its 50 ms
 * wait, leaving with its OWN cancel value the moment it answers .T. The request
 * is only PEEKED and never taken, because it has to survive the modal that just
 * cancelled itself and reach the key loop that ends the program (L9). With no
 * hook installed - every headless bank - UiCloseAsk() answers .F. and the
 * modals behave exactly as they did. */
STATIC s_bUiClose := NIL
/* S4/S8 of menu-accelerators.md: the key table of the menu accelerators, built
 * once by UiAccelKeys() and kept here because Harbour does not allow a STATIC
 * after code. */
STATIC s_aUiAccel := {}

/* ---------- themes: the colours are a RUNTIME table (theme-dark-mode.md) ----
 * Every UI_C_* macro of bp_def.ch is now UiC( TC_X ), i.e. a slot number, so the
 * ~790 use sites keep writing the same macro and the pair behind it can change
 * while the program runs. A theme is { cName, aColors, aPalette }:
 *   cName    the name the `Commands` dropdown shows;
 *   aColors  one pair per TC_* slot, in the SAME order as the slots of
 *            bp_def.ch (TC_COUNT);
 *   aPalette the RGB overrides of the 16 entry VGA palette, { { nEntry, nRGB },
 *            ... }, or {} for "the measured Classic palette, untouched".
 * The pairs alone are only half of a colour: with FONTA_DRAWBOX only the EIGHT
 * BASE entries of the palette can be a BACKGROUND (N B G BG R RB GR W), so a
 * theme can never invent a background letter - it has to RETUNE the RGB behind
 * those letters. That is the lever the Dark theme uses to become a designed
 * dark theme instead of the raw VGA palette with a different letter on every
 * cell. UiThemeSet() raises the hook of UiSetThemeHook() so the application
 * (Main() wires it to BpSetVgaPalette()) installs the new palette at once.
 * Adding a theme is appending one array to the table of UiThemeInit() and
 * nothing else (S6).
 *
 * The state lives in THIS module because a STATIC of bp_hc.prg would be
 * unreachable from bp_core.prg and bp_dot.prg. It is SESSION ONLY: hwBro has no
 * configuration file yet (AGENTS.md 7.1 is still open), so nothing is read at
 * startup and nothing is written (S7). This module never calls W32*, so the
 * headless banks keep linking it unchanged (S8). */

/* { { cName, aColors, aPalette }, ... }; built once, by UiThemeInit() */
STATIC s_aUiTheme := {}
/* 1-based index of the active theme in s_aUiTheme */
STATIC s_nUiTheme := 1
/* the block Main() installs to re-install the palette of the new theme; NIL -
 * the state of every headless bank - means "nothing to re-apply". This module
 * never calls hb_gtInfo() itself (S8). */
STATIC s_bUiThemePal := NIL

/* ---------- per-slot colour EXCEPTIONS (odd/tasks/theme-color-overrides.md) --
 * An exception is the pair the user pinned for ONE slot of `bp_def.ch` on top of
 * whatever theme is active, and it survives a theme switch on purpose: it is a
 * preference about that element, not part of a theme. The store is indexed by
 * the TC_* slot and holds "" for every slot the user did not touch, so "only the
 * exception is saved" (the .ini writes just the non-empty ones) needs no second
 * bookkeeping.
 *
 * s_aUiSlot  { cKey, cLabel, nGroup } per slot, in the order of bp_def.ch:
 *            cKey is what `hwbro.ini` stores (the TC_* name in lower case), the
 *            label is what the screen shows and the group is the heading it is
 *            filed under. Three columns because one table has to serve the
 *            screen, the file and the integrity check (Len == TC_COUNT).
 * s_aUiSlotG the name of each group, in the order the screen shows them.
 * s_aUiPal   the palette the screen offers: { cLetter, cName } x 16, the EIGHT
 *            first ones being the only ones usable as a BACKGROUND (with
 *            FONTA_DRAWBOX GTWVG only resolves a base entry as a background). */
STATIC s_aUiOv := {}
STATIC s_aUiSlot := {}
STATIC s_aUiSlotG := {}
STATIC s_aUiPal := {}

/* ---------- theme engine ---------- */

/* Colour pair of slot <nSlot> of the ACTIVE theme. This is what the UI_C_*
 * macros of bp_def.ch expand to, so it has to work before Main() has done
 * anything: the lazy guard builds the tables on first use, because a headless
 * bank may paint without Main(). An out-of-range slot answers "" instead of
 * raising an error, which also keeps a repaint alive if a slot is ever asked
 * with a number no theme has. */
FUNCTION UiC( nSlot )
   LOCAL aCol

   IF Empty( s_aUiTheme )
      UiThemeInit()
   ENDIF

   IF s_nUiTheme < 1 .OR. s_nUiTheme > Len( s_aUiTheme )
      s_nUiTheme := 1
   ENDIF

   aCol := s_aUiTheme[ s_nUiTheme ][ 2 ]

   IF ValType( nSlot ) != "N"
      RETURN ""
   ENDIF
   IF nSlot < 1 .OR. nSlot > Len( aCol )
      RETURN ""
   ENDIF
   /* S137: a colour EXCEPTION wins over the theme in force. The store may be
    * shorter than the table (it starts empty and UiOvSet() never grows it past
    * TC_COUNT), so the length is checked before indexing. An empty entry means
    * "this slot follows the theme", which is the state of every slot nobody
    * touched - and the reason the .ini only writes the exceptions. */
   IF nSlot <= Len( s_aUiOv ) .AND. ! Empty( s_aUiOv[ nSlot ] )
      RETURN s_aUiOv[ nSlot ]
   ENDIF

RETURN aCol[ nSlot ]

/* Builds the theme table ONCE (idempotent: the second call returns at once).
 * Every table carries exactly TC_COUNT pairs and entry n of a table is the pair
 * of the slot n of bp_def.ch, so the two lists must always be read together. */
FUNCTION UiThemeInit()
   LOCAL aCls, aDrk, aClsPal, aDrkPal
   LOCAL nTheme

   IF ! Empty( s_aUiTheme )
      RETURN NIL
   ENDIF

   /* Classic (S2): the pairs the program has always had, one per slot, in the
    * order of the TC_* slots. They are the colours measured on BRO.EXE
    * (AGENTS.md section 4) and they are what the program starts with, so a value
    * is only changed with a measurement. */
   aCls := { ;
      "N/W", ;   // 1  DESKTOP
      "N/B", ;   // 2  MENUBAR
      "W+/B", ;   // 3  MENUKEY
      "N/BG", ;   // 4  MENULBL
      "W+/R", ;   // 5  MENUACT
      "W+/B", ;   // 6  DARK
      "W+/B", ;   // 7  FRAME1
      "GR+/B", ;   // 8  FRAME2
      "N/BG", ;   // 9  CHIP
      "N/N", ;   // 10  SHADOWBLK
      "N/RB", ;   // 11  SELITEM
      "GR+/B", ;   // 12  PICKED
      "N/BG", ;   // 13  BOX
      "N/BG", ;   // 14  BOXBORD
      "W+/GR", ;   // 15  BOXSEL
      "N/RB", ;   // 16  LISTSEL
      "GR+/BG", ;   // 17  HOT
      "GR+/B", ;   // 18  HOTON
      "N+/BG", ;   // 19  BOXDIM
      "N/W", ;   // 20  FIELDBG
      "W+/BG", ;   // 21  FLATBG
      "GR+/GR", ;   // 22  HOTSEL
      "N+/N", ;   // 23  SHADOW
      "W+/R", ;   // 24  ERR
      "W+/B", ;   // 25  STATUS
      "W+/B", ;   // 26  STATUSBAR
      "N/W", ;   // 27  INPUT
      "N/W", ;   // 28  HDR
      "N/W", ;   // 29  HDRSEL
      "N/W", ;   // 30  REC
      "W+/R", ;   // 31  RECSEL
      "W/B", ;   // 32  DIM
      "N+/W", ;   // 33  RECDEL
      "N/G", ;   // 34  CURSEL
      "N/RB", ;   // 35  EDIT
      "W+/N", ;   // 36  TITLEBAR
      "N/G", ;   // 37  GREEN
      "N/BG", ;   // 38  HINT
      "N/BG", ;   // 39  SPLASH
      "W+/BG", ;   // 40  SPLFRM
      "N+/BG", ;   // 41  SPLSHD
      "GR+/BG", ;   // 42  SPLMSG
      "R/W", ;   // 43  OKBTN
      "BG+/B", ;   // 44  STBRD
      "BG+/B", ;   // 45  STTIT
      "W+/B", ;   // 46  STROW
      "N/BG", ;   // 47  STCUR
      "N/GR", ;   // 48  STSEL
      "N/BG", ;   // 49  DLG
      "N/BG", ;   // 50  DLGBRD
      "W+/BG", ;   // 51  DLGINFO
      "N/W", ;   // 52  DLGFIELD
      "N/W", ;   // 53  DLGRED
      "N/GR", ;   // 54  TAGDESC
      "N/BG", ;   // 55  IDXSEL
      "BG+/B", ;   // 56  IDXFRM
      "BG+/B", ;   // 57  IDXITEM
      "GR/W", ;   // 58  IDXALIAS
      "GR+/BG", ;   // 59  PROGTIT
      "N/BG", ;   // 60  PROGTXT
      "G+/B", ;   // 61  PROGBAR
      "N/B", ;   // 62  PROGEMPTY
      "N/W", ;   // 63  CMPBODY
      "N+/W", ;   // 64  CMPDIM
      "R/W", ;   // 65  CMPMRKD
      "G/W", ;   // 66  CMPMRKA
      "GR/W", ;   // 67  CMPMRKC
      "N/RB", ;   // 68  CMPWORD
      "W+/B", ;   // 69  CMPBAR
      "W+/B", ;   // 70  CMPON
      "N+/W", ;   // 71  CMPOFF
      "N+/W", ;   // 72  CMPTRACK
      "N+/W", ;   // 73  CMPTHUMB
      "GR+/B", ;   // 74  CODEKEY
      "G+/B", ;   // 75  CODESTR
      "W/B", ;   // 76  CODECMT
      "R+/B", ;   // 77  CODENUM
      "BG+/B", ;   // 78  CODEFUNC
      "RB+/B", ;   // 79  CODEPRE: bright MAGENTA (not `RG+`, which ColorToN reads as `GR+`)
      "W+/B", ;   // 80  TABLBLON: label and brackets of the ACTIVE tab
      "W/N", ;    // 81  TABLBLOFF: label and brackets of the other tabs
      "N/BG", ;   // 82  TABXACT: the mark at rest on the active tab (own chip)
      "N/BG", ;   // 83  TABXOFF: the mark at rest on the other tabs (own chip)
      "W+/R", ;   // 84  TABXDIRA: the mark of unsaved changes, active tab (red button)
      "W+/R", ;   // 85  TABXDIRO: the mark of unsaved changes, other tabs (red button)
      "N/RB", ;   // 86  TABXHOVA: the mark under the pointer, active tab (amber)
      "N/RB", ;   // 87  TABXHOVO: the mark under the pointer, other tabs (amber)
      "N/N", ;   // 88  TABBAR: the empty rest of the row of the bar
      "W+/B"    ;  // 89  TABBRKON: brackets of the ACTIVE tab (same as its label here)
      }

   /* Dark (S3): the CONTENT is BLACK, the CHROME keeps the dark gray surface
    * and the accents do not move, so a screen reads as black panels with gray
    * strips instead of a gray page with black text.
    *
    * Why this is NOT "Classic with a few pairs remapped": in Classic the content
    * surface of the Commander, of the text viewer/editor, of the browse and of
    * the Compare IS UI_C_DARK = "W+/B" (white on the 85,85,85 gray) - the
    * largest area of every one of those screens. A Dark table that maps "W+/B"
    * to itself leaves that area exactly as it was and the theme is invisible;
    * that was the reported defect. UI_C_DARK therefore may NOT stay "W+/B".
    *
    * Every body-like slot moves to a BLACK background with bright text:
    *   DARK 6, REC 30, STROW 46, CMPBODY 63   the four content surfaces
    *   FIELDBG 20, INPUT 27, DESKTOP 1        the browse buffer, the inline
    *                                          input and the area the dialogs
    *                                          and menus are raised over
    *   CODEKEY..CODEPRE 74..79                the code tokens, which share the
    *                                          background of DARK so a code file
    *                                          never paints a stripe over the body
    * Everything else keeps the dark gray raised surface of the CHROME: the menu
    * and status bars, the chips on a gray band (here the cyan is TEXT, not
    * background: MENULBL 4, CHIP 9, BOXBORD 14, HINT 38, SPLASH 39, STBRD 44,
    * STTIT 45, IDXFRM 56, IDXITEM 57...), the frames, the interior of boxes and
    * dialogs (BOX 13, DLG 49), the column headers (HDR/HDRSEL 28/29) and the
    * bars of the Compare.
    *
    * The accents are kept exactly as they are the identity of the program:
    * LISTSEL N/RB, CURSEL N/G, EDIT N/RB, RECSEL W+/GR, DLGRED W+/GR, CMPWORD
    * N/RB. PROGEMPTY stays N/B because that half of the progress bar is painted
    * with SPACES and a bright pair there reads as a FULL bar (L10).
    *
    * NO slot ends up with W (the light gray "paper") as its background: the
    * backgrounds used here are N (black, the content), B (the dark gray chrome)
    * and, where the accent IS the point of the pair, G (cursor cell and editable
    * field), RB (yellow selection and inline edit cell), GR (brown selected
    * band) and BG (the cyan of the active menu label).
    *
    * The RGB BEHIND those letters is not the raw VGA one: aDrkPal (below)
    * retunes all sixteen palette entries, and that is what makes this a DESIGNED
    * dark theme instead of the Classic palette wearing different letters. */
   aDrk := { ;
      "W+/N", ;   // 1  DESKTOP
      "W+/B", ;   // 2  MENUBAR
      "W+/B", ;   // 3  MENUKEY
      "BG+/B", ;   // 4  MENULBL
      "N/BG", ;   // 5  MENUACT
      "W+/N", ;   // 6  DARK: the content surface is BLACK, never the gray
      "W+/B", ;   // 7  FRAME1
      "GR+/B", ;   // 8  FRAME2
      "BG+/B", ;   // 9  CHIP
      "N/N", ;   // 10  SHADOWBLK
      "N/RB", ;   // 11  SELITEM
      "GR+/B", ;   // 12  PICKED
      "W+/B", ;   // 13  BOX
      "BG+/B", ;   // 14  BOXBORD
      "W+/GR", ;   // 15  BOXSEL
      "N/RB", ;   // 16  LISTSEL
      "GR+/B", ;   // 17  HOT
      "GR+/B", ;   // 18  HOTON
      "N+/B", ;   // 19  BOXDIM
      "W+/N", ;   // 20  FIELDBG
      "W+/B", ;   // 21  FLATBG
      "GR+/GR", ;   // 22  HOTSEL
      "N+/N", ;   // 23  SHADOW
      "R+/B", ;   // 24  ERR
      "W+/B", ;   // 25  STATUS
      "W+/B", ;   // 26  STATUSBAR
      "W+/N", ;   // 27  INPUT
      "W+/B", ;   // 28  HDR
      "W+/B", ;   // 29  HDRSEL
      "W+/N", ;   // 30  REC
      "W+/GR", ;   // 31  RECSEL
      "W/N", ;   // 32  DIM
      "N+/N", ;   // 33  RECDEL
      "N/G", ;   // 34  CURSEL
      "N/RB", ;   // 35  EDIT
      "W+/N", ;   // 36  TITLEBAR
      "N/G", ;   // 37  GREEN
      "BG+/B", ;   // 38  HINT
      "N+/B", ;   // 39  SPLASH
      "W+/B", ;   // 40  SPLFRM
      "N/N", ;   // 41  SPLSHD
      "GR+/B", ;   // 42  SPLMSG
      "N/RB", ;   // 43  OKBTN
      "BG+/B", ;   // 44  STBRD
      "BG+/B", ;   // 45  STTIT
      "W+/N", ;   // 46  STROW
      "N/RB", ;   // 47  STCUR
      "N/GR", ;   // 48  STSEL
      "W+/B", ;   // 49  DLG: el cuerpo del cuadro es la superficie elevada (B), no el cian
      "BG+/B", ;   // 50  DLGBRD: el marco lleva el acento del tema, como BOXBORD
      "GR+/B", ;   // 51  DLGINFO: la etiqueta del cuadro en ambar, legible sobre B
      "W+/N", ;   // 52  DLGFIELD
      "W+/N", ;   // 53  DLGRED
      "N/GR", ;   // 54  TAGDESC
      "N/RB", ;   // 55  IDXSEL
      "BG+/B", ;   // 56  IDXFRM
      "BG+/B", ;   // 57  IDXITEM
      "GR+/N", ;   // 58  IDXALIAS
      "GR+/B", ;   // 59  PROGTIT
      "W+/B", ;   // 60  PROGTXT
      "G+/B", ;   // 61  PROGBAR
      "N/B", ;    // 62  PROGEMPTY: the empty half is SPACES, so it stays dark
      "W+/N", ;   // 63  CMPBODY
      "N+/N", ;   // 64  CMPDIM
      "R+/N", ;   // 65  CMPMRKD
      "G+/N", ;   // 66  CMPMRKA
      "GR+/N", ;   // 67  CMPMRKC
      "N/RB", ;   // 68  CMPWORD
      "W+/B", ;   // 69  CMPBAR
      "W+/B", ;   // 70  CMPON
      "W/B", ;   // 71  CMPOFF
      "N+/N", ;   // 72  CMPTRACK
      "N+/N", ;   // 73  CMPTHUMB
      "GR+/N", ;   // 74  CODEKEY
      "G+/N", ;   // 75  CODESTR
      "W/N", ;   // 76  CODECMT
      "R+/N", ;   // 77  CODENUM
      "BG+/N", ;   // 78  CODEFUNC
      "RB+/N", ;   // 79  CODEPRE: bright MAGENTA (not `RG+`, which ColorToN reads as `GR+`)
      "W+/B", ;   // 80  TABLBLON: label and brackets of the ACTIVE tab
      "N+/N", ;   // 81  TABLBLOFF: label and brackets of the other tabs (dim on Dark)
      "N/BG", ;   // 82  TABXACT: the mark at rest on the active tab (own chip)
      "N/BG", ;   // 83  TABXOFF: the mark at rest on the other tabs (own chip)
      "W+/R", ;   // 84  TABXDIRA: the mark of unsaved changes, active tab (red button)
      "W+/R", ;   // 85  TABXDIRO: the mark of unsaved changes, other tabs (red button)
      "N/RB", ;   // 86  TABXHOVA: the mark under the pointer, active tab (amber)
      "N/RB", ;   // 87  TABXHOVO: the mark under the pointer, other tabs (amber)
      "N/N", ;    // 88  TABBAR: the empty rest of the row of the bar
      "GR+/B" ;   // 89  TABBRKON: brackets of the ACTIVE tab (amber: B and N are too close)
      }

   /* ---------- the PALETTES of the two themes ----------------------------
    * The pairs above are only HALF of a colour: the RGB behind each letter is
    * whatever the palette of the driver says, and BpSetVgaPalette() installs the
    * measured Classic one. With FONTA_DRAWBOX only the EIGHT BASE entries of the
    * palette can be a BACKGROUND (N B G BG R RB GR W), so a theme can NEVER
    * invent a background letter to get a new surface: it has to RETUNE the RGB
    * of the entries that already exist. That is exactly what this list is, and
    * it is the lever the Dark theme was missing:
    *
    *   { nEntry, nRGB }, ...   nEntry 1..16 of the VGA palette, nRGB packed the
    *                           way BpSetVgaPalette() packs it:
    *                           nR + nG * 256 + nB * 65536.
    *
    * Classic has NO override at all ({}): it keeps the palette measured on
    * BRO.EXE (AGENTS.md section 4) byte for byte, which is what S2 requires.
    *
    * Dark retunes the sixteen, entry by entry:
    *   1 N    body / near black             18, 18, 22
    *   2 B    chrome, raised surfaces       40, 40, 46
    *   3 G    green bands (cursor, field)   70,185,120
    *   4 BG   cyan (chips, active label)     0,155,160
    *   5 R    red bands (error)            200, 70, 70
    *   6 RB   amber selection / edit cell  205,175, 65
    *   7 GR   brown bands (recsel, boxsel) 125, 92, 40
    *   8 W    light text / dim            185,185,192
    *   9 N+   dim text ("bright black")   110,110,120
    *  10 B+   blue form frame               95, 95,215
    *  11 G+   bright green (strings)       105,220,150
    *  12 BG+  bright cyan (frames, funcs)  105,225,230
    *  13 R+   bright red (errors, numbers) 225, 95, 95
    *  14 RB+  bright magenta (preproc.)    200,130,225
    *  15 GR+  yellow/amber (hot keys,code) 230,210,110
    *  16 W+   brightest text              245,245,250
    *
    * Why these numbers: the body is a SOFT near-black and the chrome a SUBTLE
    * raise, so a screen has two dark surfaces instead of the hard 0,0,0 ->
    * 85,85,85 jump of the raw VGA palette (that jump is what made the first
    * Dark look ugly). The accents are the Classic hues with the edge taken off
    * (no neon 255,255,85 and no 255,0,0), so the identity of the program
    * survives - yellow selection, green cursor, cyan chips - without the
    * glare. */
   aClsPal := {}
   aDrkPal := { ;
      {  1,  1446418 }, ;   // N   18, 18, 22
      {  2,  3024936 }, ;   // B   40, 40, 46
      {  3,  7911750 }, ;   // G   70,185,120
      {  4, 10525440 }, ;   // BG   0,155,160
      {  5,  4605640 }, ;   // R  200, 70, 70
      {  6,  4304845 }, ;   // RB 205,175, 65
      {  7,  2645117 }, ;   // GR 125, 92, 40
      {  8, 12630457 }, ;   // W  185,185,192
      {  9,  7892590 }, ;   // N+ 110,110,120
      { 10, 14114655 }, ;   // B+  95, 95,215
      { 11,  9886825 }, ;   // G+ 105,220,150
      { 12, 15130985 }, ;   // BG+105,225,230
      { 13,  6250465 }, ;   // R+ 225, 95, 95
      { 14, 14779080 }, ;   // RB+200,130,225
      { 15,  7262950 }, ;   // GR+230,210,110
      { 16, 16446965 }  ;   // W+ 245,245,250
      }

   s_aUiTheme := { ;
      { "Classic", aCls, aClsPal }, ;
      { "Dark",    aDrk, aDrkPal } }

   /* S10: the theme the program STARTS in is UiThemeDefault() (`Dark`), not the
    * first row of the table. It is resolved BY NAME here so reordering the two
    * lines above -or adding a third theme- cannot change the startup screen by
    * accident; a name that is not in the table keeps the first theme. */
   s_nUiTheme := 1
   FOR nTheme := 1 TO Len( s_aUiTheme )
      IF Upper( s_aUiTheme[ nTheme ][ 1 ] ) == Upper( UiThemeDefault() )
         s_nUiTheme := nTheme
         EXIT
      ENDIF
   NEXT

RETURN NIL

/* Names of the themes, in the order of the table. Built FROM the table, so the
 * list can never disagree with the themes that exist (S4/S6). */
FUNCTION UiThemeNames()
   LOCAL aName := {}
   LOCAL i

   UiThemeInit()
   FOR i := 1 TO Len( s_aUiTheme )
      AAdd( aName, s_aUiTheme[ i ][ 1 ] )
   NEXT

RETURN aName

/* Name of the theme the program STARTS in (S10 of
 * odd/tasks/globalset-date-format.md: the user asked for the dark mode by
 * default). It is the startup rule and nothing else: the theme still lives in
 * the SESSION, so this is not a saved preference (pendiente 22 of AGENTS.md
 * section 7) and `Commands > Themes` switches it like any other. UiThemeInit()
 * resolves it to the index of the table, and an unknown name falls back to the
 * first theme instead of leaving the program without colours. */
FUNCTION UiThemeDefault()
RETURN "Dark"

/* Name of the active theme. */
FUNCTION UiThemeName()

   UiThemeInit()

RETURN s_aUiTheme[ s_nUiTheme ][ 1 ]

/* 1-based index of the active theme. */
FUNCTION UiThemeIndex()

   UiThemeInit()

RETURN s_nUiTheme

/* Switches to the theme <cName>, case insensitive. Answers .T. when that theme
 * ends up active - switching to the theme already active is a valid switch - and
 * .F. for an unknown name, which changes NOTHING (S5).
 * The theme HOOK is raised right after the switch, so the application can
 * re-apply whatever depends on the theme outside the pair table - in hwBro that
 * is the RGB palette of the driver (BpSetVgaPalette()), which the pairs alone
 * cannot change. With no hook installed nothing is raised, so every headless
 * bank sees the same engine it had before. */
FUNCTION UiThemeSet( cName )
   LOCAL i

   UiThemeInit()

   IF ValType( cName ) != "C"
      RETURN .F.
   ENDIF

   FOR i := 1 TO Len( s_aUiTheme )
      IF Upper( s_aUiTheme[ i ][ 1 ] ) == Upper( cName )
         s_nUiTheme := i
         IF ! hb_IsNIL( s_bUiThemePal )
            Eval( s_bUiThemePal )
         ENDIF
         RETURN .T.
      ENDIF
   NEXT

RETURN .F.

/* The block raised by UiThemeSet() after every accepted switch (no argument, the
 * answer is ignored), or NIL to remove it. This module does NOT call hb_gtInfo()
 * itself: the palette is the driver's, and Main() is where the W32/GT worlds
 * meet, so bp_ui.prg keeps linking in the three headless banks unchanged (S8). */
FUNCTION UiSetThemeHook( bBlock )
   s_bUiThemePal := bBlock
RETURN NIL

/* A COPY of the colour array of the theme <cName>, or {} for an unknown name. It
 * is a real copy, element by element: arrays are references in Harbour and
 * ACopy( a, {} ) copies nothing, so a caller that edited the result would
 * otherwise change the theme itself. */
FUNCTION UiThemeColors( cName )
   LOCAL aCol := {}
   LOCAL aSrc
   LOCAL i, n

   UiThemeInit()

   IF ValType( cName ) != "C"
      RETURN aCol
   ENDIF

   n := 0
   FOR i := 1 TO Len( s_aUiTheme )
      IF Upper( s_aUiTheme[ i ][ 1 ] ) == Upper( cName )
         n := i
         EXIT
      ENDIF
   NEXT

   IF n == 0
      RETURN aCol
   ENDIF

   aSrc := s_aUiTheme[ n ][ 2 ]
   FOR i := 1 TO Len( aSrc )
      AAdd( aCol, aSrc[ i ] )
   NEXT

RETURN aCol

/* A COPY of the PALETTE overrides of the theme <cName>, or {} for an unknown
 * name (and for a theme that has none, which is what `Classic` is). Each answer
 * element is a NEW { nEntry, nRGB } pair, not the one the engine holds: arrays
 * are references in Harbour (AGENTS trap 67) and ACopy( a, {} ) copies nothing
 * (trap 33), so writing into the answer of a shallow copy would retune the
 * palette of the whole program. */
FUNCTION UiThemePalette( cName )
   LOCAL aPal := {}
   LOCAL aSrc
   LOCAL i, n

   UiThemeInit()

   IF ValType( cName ) != "C"
      RETURN aPal
   ENDIF

   n := 0
   FOR i := 1 TO Len( s_aUiTheme )
      IF Upper( s_aUiTheme[ i ][ 1 ] ) == Upper( cName )
         n := i
         EXIT
      ENDIF
   NEXT

   IF n == 0
      RETURN aPal
   ENDIF

   aSrc := s_aUiTheme[ n ][ 3 ]
   IF ! HB_ISARRAY( aSrc )
      RETURN aPal
   ENDIF

   FOR i := 1 TO Len( aSrc )
      IF HB_ISARRAY( aSrc[ i ] ) .AND. Len( aSrc[ i ] ) >= 2
         AAdd( aPal, { aSrc[ i ][ 1 ], aSrc[ i ][ 2 ] } )
      ENDIF
   NEXT

RETURN aPal

/* =====================================================================
 *  COLOUR EXCEPTIONS OVER THE THEME IN FORCE (S137 of
 *  odd/tasks/theme-color-overrides.md)
 *
 *  The user asked to "add exceptions to the selected theme": pick one of the
 *  colour slots the program has (body, cursor, input, header...) and one of the
 *  colours of the palette, see it applied at once, and keep just that exception
 *  in hwbro.ini. Everything below is PURE (no window, no driver, no disk) so the
 *  headless bank pins it; the screen lives in bp_cmds.prg and the .ini in
 *  bp_cfg.prg.
 *
 *  Two facts order this code:
 *   - every UI_C_* is a PAIR "text/background", so an exception is a pair too;
 *   - with FONTA_DRAWBOX GTWVG only the EIGHT base entries of the palette can be
 *     a background, so the background list is the first eight of the palette and
 *     the text list is the sixteen.
 * ===================================================================== */

/* Pair of <nSlot> in the ACTIVE THEME, ignoring the exceptions: it is the value
 * a Reset goes back to and the "THEME" column of the screen. "" for a slot that
 * does not exist, like UiC(). */
FUNCTION UiThemePair( nSlot )
   LOCAL aCol

   UiThemeInit()

   IF ValType( nSlot ) != "N"
      RETURN ""
   ENDIF
   IF nSlot < 1 .OR. nSlot > TC_COUNT
      RETURN ""
   ENDIF

   aCol := s_aUiTheme[ s_nUiTheme ][ 2 ]
   IF nSlot > Len( aCol )
      RETURN ""
   ENDIF

RETURN aCol[ nSlot ]

/* Builds the three tables of this section ONCE (idempotent). The slot table is
 * read together with bp_def.ch: entry n has to describe the slot n, which is why
 * the bank checks Len() == TC_COUNT and that every key is unique. */
FUNCTION UiSlotInit()
   LOCAL n

   IF ! Empty( s_aUiSlot )
      RETURN NIL
   ENDIF

   /* The palette the screen offers. The NAME says what the colour is used for in
    * the program (it survives a theme change, the RGB does not), and the order of
    * the first EIGHT is the order of the background list. */
   s_aUiPal := { ;
      { "N",   "Black (body)" }, ;
      { "B",   "Gray (chrome)" }, ;
      { "G",   "Green (cursor)" }, ;
      { "BG",  "Cyan (chips)" }, ;
      { "R",   "Red (bands)" }, ;
      { "RB",  "Yellow (selection)" }, ;
      { "GR",  "Brown (bands)" }, ;
      { "W",   "Light gray (text)" }, ;
      { "N+",  "Dark gray (dim)" }, ;
      { "B+",  "Blue (form frame)" }, ;
      { "G+",  "Bright green (strings)" }, ;
      { "BG+", "Bright cyan (frames)" }, ;
      { "R+",  "Bright red (errors)" }, ;
      { "RB+", "Magenta (preprocessor)" }, ;
      { "GR+", "Bright yellow (keys)" }, ;
      { "W+",  "White (bright text)" } ;
      }

   /* The headings of the screen, in the order they are shown. */
   s_aUiSlotG := { ;
      "Screen, panels & bars", ;
      "Menu bar", ;
      "Boxes & forms", ;
      "Dialogs", ;
      "Records & lists", ;
      "Structure editor", ;
      "Index screens", ;
      "Progress", ;
      "Splash", ;
      "Compare", ;
      "Code", ;
      "Editor tabs" ;
      }

   /* { cKey, cLabel, nGroup } per slot, in the order of bp_def.ch. The key is
    * what hwbro.ini stores (the TC_* name in lower case) and it is the stable
    * half of the row: the NUMBER of a slot may move if the tables grow, the name
    * does not. */
   s_aUiSlot := { ;
      { "desktop",    "Screen background",        1 }, ;
      { "menubar",    "Menu bar background",      2 }, ;
      { "menukey",    "Menu key (F1..F9)",        2 }, ;
      { "menulbl",    "Menu label",               2 }, ;
      { "menuact",    "Menu label, active",       2 }, ;
      { "dark",       "Panel body (panels, editor, browse)", 1 }, ;
      { "frame1",     "Panel frame, left",        3 }, ;
      { "frame2",     "Panel frame, right",       3 }, ;
      { "chip",       "Chip (title, path)",       3 }, ;
      { "shadowblk",  "Box shadow block",         1 }, ;
      { "selitem",    "List selection",           3 }, ;
      { "picked",     "Open database tint",       3 }, ;
      { "box",        "Box / form body",          3 }, ;
      { "boxbord",    "Box / form frame",         3 }, ;
      { "boxsel",     "Option in focus",          3 }, ;
      { "listsel",    "Cursor / focus highlight",  3 }, ;
      { "hot",        "Quick letter",             3 }, ;
      { "hoton",      "Quick letter on dark",     3 }, ;
      { "boxdim",     "Unavailable option",       3 }, ;
      { "fieldbg",    "Input field at rest",      3 }, ;
      { "flatbg",     "Flat control at rest",     3 }, ;
      { "hotsel",     "Quick letter, in focus",   3 }, ;
      { "shadow",     "Window shadow",            1 }, ;
      { "err",        "Error message",            1 }, ;
      { "status",     "Status line",              1 }, ;
      { "statusbar",  "Key bar / command line",   1 }, ;
      { "input",      "Browse input field",       5 }, ;
      { "hdr",        "Column header (browse, panels)", 5 }, ;
      { "hdrsel",     "Column header, sorted",    5 }, ;
      { "rec",        "Record row",               5 }, ;
      { "recsel",     "Marked entry / current record", 5 }, ;
      { "dim",        "Dim text / guides",        1 }, ;
      { "recdel",     "Record, deleted",          5 }, ;
      { "cursel",     "Cursor cell",              5 }, ;
      { "edit",       "Cell being edited",        5 }, ;
      { "titlebar",   "Title bar",                1 }, ;
      { "green",      "Green bar",                1 }, ;
      { "hint",       "Hint bar (status row)",    1 }, ;
      { "splash",     "Splash box",               9 }, ;
      { "splfrm",     "Splash frame / logo",      9 }, ;
      { "splshd",     "Splash shadow",            9 }, ;
      { "splmsg",     "Splash version line",      9 }, ;
      { "okbtn",      "Splash OK button",         9 }, ;
      { "stbrd",      "Structure: frame",         6 }, ;
      { "sttit",      "Structure: title",         6 }, ;
      { "strow",      "Structure: row",           6 }, ;
      { "stcur",      "Structure: cursor cell",   6 }, ;
      { "stsel",      "Structure: current field", 6 }, ;
      { "dlg",        "Dialog body",              4 }, ;
      { "dlgbord",    "Dialog frame",             4 }, ;
      { "dlginfo",    "Dialog label",             4 }, ;
      { "dlgfield",   "Dialog field",             4 }, ;
      { "dlgred",     "Dialog field, red",        4 }, ;
      { "tagdesc",    "Tag screen: block",        6 }, ;
      { "idxsel",     "Index: selected item",     7 }, ;
      { "idxfrm",     "Index: right frame",       7 }, ;
      { "idxitem",    "Index: open index",        7 }, ;
      { "idxalias",   "Index: alias line",        7 }, ;
      { "progtit",    "Progress: title",          8 }, ;
      { "progtxt",    "Progress: counter",        8 }, ;
      { "progbar",    "Progress: filled bar",     8 }, ;
      { "progempty",  "Progress: empty bar",      8 }, ;
      { "cmpbody",    "Compare: text",           10 }, ;
      { "cmpdim",     "Compare: dim text",       10 }, ;
      { "cmpmrkd",    "Compare: marker left",    10 }, ;
      { "cmpmrka",    "Compare: marker right",   10 }, ;
      { "cmpmrkc",    "Compare: marker changed", 10 }, ;
      { "cmpword",    "Compare: changed span",   10 }, ;
      { "cmpbar",     "Compare: bars",           10 }, ;
      { "cmpon",      "Compare: chip on",        10 }, ;
      { "cmpoff",     "Compare: chip off",       10 }, ;
      { "cmptrack",   "Compare: scroll track",   10 }, ;
      { "cmpthumb",   "Compare: scroll thumb",   10 }, ;
      { "codekey",    "Code: keyword",           11 }, ;
      { "codestr",    "Code: string",            11 }, ;
      { "codecmt",    "Code: comment",           11 }, ;
      { "codenum",    "Code: number",            11 }, ;
      { "codefunc",   "Code: function",          11 }, ;
      { "codepre",    "Code: preprocessor",      11 }, ;
      { "tablblon",   "Tab: label, active",      12 }, ;
      { "tablbloff",  "Tab: label, other",       12 }, ;
      { "tabxact",    "Tab: X, active",          12 }, ;
      { "tabxoff",    "Tab: X, other",           12 }, ;
      { "tabxdira",   "Tab: X unsaved, active",  12 }, ;
      { "tabxdiro",   "Tab: X unsaved, other",   12 }, ;
      { "tabxhova",   "Tab: X hover, active",    12 }, ;
      { "tabxhovo",   "Tab: X hover, other",     12 }, ;
      { "tabbar",     "Tab bar background",      12 }, ;
      { "tabbrkon",   "Tab: brackets, active",   12 } ;
      }

   /* the store of the exceptions: one empty string per slot, so it is indexed
    * like the tables and "no exception" needs no NIL test */
   IF Empty( s_aUiOv )
      FOR n := 1 TO Len( s_aUiSlot )
         AAdd( s_aUiOv, "" )
      NEXT
   ENDIF

RETURN NIL

/* ---------- the slot table ---------- */

FUNCTION UiSlotCount()
   UiSlotInit()
RETURN Len( s_aUiSlot )

FUNCTION UiSlotKey( nSlot )
   UiSlotInit()
   IF nSlot < 1 .OR. nSlot > Len( s_aUiSlot )
      RETURN ""
   ENDIF
RETURN s_aUiSlot[ nSlot ][ 1 ]

FUNCTION UiSlotLabel( nSlot )
   UiSlotInit()
   IF nSlot < 1 .OR. nSlot > Len( s_aUiSlot )
      RETURN ""
   ENDIF
RETURN s_aUiSlot[ nSlot ][ 2 ]

FUNCTION UiSlotGroup( nSlot )
   UiSlotInit()
   IF nSlot < 1 .OR. nSlot > Len( s_aUiSlot )
      RETURN 0
   ENDIF
RETURN s_aUiSlot[ nSlot ][ 3 ]

/* the slot a key of hwbro.ini stands for, or 0. The NAME is tried first and a
 * plain number is accepted as a fallback, so a file written by hand with `6=N/W`
 * also works; anything else - and the name of a slot that no longer exists - is
 * ignored by the caller instead of breaking the program. */
FUNCTION UiSlotByKey( cKey )
   LOCAL i, n
   LOCAL c := Upper( AllTrim( iif( ValType( cKey ) == "C", cKey, "" ) ) )

   UiSlotInit()

   IF Len( c ) == 0
      RETURN 0
   ENDIF

   FOR i := 1 TO Len( s_aUiSlot )
      IF Upper( s_aUiSlot[ i ][ 1 ] ) == c
         RETURN i
      ENDIF
   NEXT

   n := Val( c )
   IF n >= 1 .AND. n <= Len( s_aUiSlot ) .AND. AllTrim( Str( n ) ) == c
      RETURN n
   ENDIF

RETURN 0

/* ---------- the groups ---------- */

FUNCTION UiSlotGroupNames()
   UiSlotInit()
RETURN s_aUiSlotG

FUNCTION UiSlotGroupName( nGroup )
   UiSlotInit()
   IF nGroup < 1 .OR. nGroup > Len( s_aUiSlotG )
      RETURN ""
   ENDIF
RETURN s_aUiSlotG[ nGroup ]

/* The rows of the screen, in display order: { 1, nGroup } for a heading and
 * { 2, nSlot } for an element. Grouped here - and not by walking the slots in
 * order - so a heading appears ONCE even though its slots are spread over
 * bp_def.ch; the order inside a group is the order of the slots, which keeps the
 * list stable. A heading is not a stop: the screen and the bank skip it with
 * UiSlotRowStep(). */
FUNCTION UiSlotRows()
   LOCAL aRow := {}
   LOCAL nG, n, nId, lHead

   UiSlotInit()

   FOR nG := 1 TO Len( s_aUiSlotG )
      lHead := .F.
      FOR n := 1 TO Len( s_aUiSlot )
         nId := s_aUiSlot[ n ][ 3 ]
         IF nId == nG
            IF ! lHead
               AAdd( aRow, { 1, nG } )
               lHead := .T.
            ENDIF
            AAdd( aRow, { 2, n } )
         ENDIF
      NEXT
   NEXT

RETURN aRow

/* the next ELEMENT of <aRow> in direction <nDir> from <nFrom>, wrapping
 * backwards/forwards is NOT done here: at the end it answers <nFrom>, which is
 * what the caller needs to keep the cursor where it was. */
FUNCTION UiSlotRowStep( aRow, nFrom, nDir )
   LOCAL n := nFrom + nDir

   IF ! HB_ISARRAY( aRow ) .OR. nDir == 0
      RETURN nFrom
   ENDIF

   DO WHILE n >= 1 .AND. n <= Len( aRow )
      IF aRow[ n ][ 1 ] == 2
         RETURN n
      ENDIF
      n += nDir
   ENDDO

RETURN nFrom

/* first and last ELEMENT row of the list */
FUNCTION UiSlotRowEdge( aRow, lLast )
   LOCAL n

   IF ! HB_ISARRAY( aRow )
      RETURN 0
   ENDIF

   IF lLast
      FOR n := Len( aRow ) TO 1 STEP -1
         IF aRow[ n ][ 1 ] == 2
            RETURN n
         ENDIF
      NEXT
   ELSE
      FOR n := 1 TO Len( aRow )
         IF aRow[ n ][ 1 ] == 2
            RETURN n
         ENDIF
      NEXT
   ENDIF

RETURN 0

/* ---------- the palette ---------- */

/* { { cLetter, cName }, ... } x 16: every colour a TEXT can use */
FUNCTION UiPaletteFg()
   LOCAL a := {}, i

   UiSlotInit()
   FOR i := 1 TO Len( s_aUiPal )
      AAdd( a, { s_aUiPal[ i ][ 1 ], s_aUiPal[ i ][ 2 ] } )
   NEXT

RETURN a

/* { { cLetter, cName }, ... } x 16: every colour a BACKGROUND can use. The
 * eight BASE ones are the palette letters; the eight BRIGHT ones are the same
 * letters with a STAR (`N* B* G* BG* R* RB* GR* W*`), which is how this driver
 * paints an intense surface.
 *
 * THE WHOLE COLOUR SPACE IS 16 x 16 = 256 ATTRIBUTES (the table the user handed
 * over). Two bits build them, and they are POSITION-FREE:
 *   hbgtcore.c:  '+' -> nColor |= 0x08 (the bright bit of the TEXT nibble)
 *                '*' -> nColor |= 0x80 (the high bit of the BACKGROUND nibble)
 *   gtwvgd.c:    SetBkColor( hdc, COLORS[ ( iColor >> 4 ) & 0x0F ] )
 * so 16 inks x 16 surfaces all paint, and `N+/B`/`N/B+` are the same attribute,
 * as are `N/W*` and the same star written in the text half (measured:
 * ColorToN() gives 0x18 and 0xF0 in both cases; hb_NToColor() answers the
 * canonical form, `N+/B` and `N/W*`).
 *
 * On real VGA TEXT MODE the top bit is BLINK, so a DOS screen has 16 inks and
 * only 8 surfaces; this clone is a GDI window (gtwvg) with no blink code, which
 * is why the star really paints here. MEASURED with the palette of the theme
 * (PrintWindow, and six captures 250 ms apart to rule a blink out - identical):
 *    N/W  185,185,192      N/W*  245,245,250     (Dark)
 *    N/N   18,18,22        N/N*  110,110,120
 *    N/B   40,40,46        N/B*   95,95,215
 * The screen shows the 256 as a matrix, one cell per attribute (see
 * BpThemeColors), and UiPairSplit() puts each bit in its own half, so a pair
 * written in any of the four ways ends up in the canonical one. */
FUNCTION UiPaletteBg()
   LOCAL a := {}, i
   LOCAL aBr := { "Bright black", "Bright gray", "Bright green", "Bright cyan", ;
                  "Bright red", "Bright yellow", "Bright brown", "Bright white" }

   UiSlotInit()
   FOR i := 1 TO 8
      AAdd( a, { s_aUiPal[ i ][ 1 ], s_aUiPal[ i ][ 2 ] } )
   NEXT
   FOR i := 1 TO 8
      AAdd( a, { s_aUiPal[ i ][ 1 ] + "*", aBr[ i ] } )
   NEXT

RETURN a

/* the name of a palette letter, or "" for something that is not one. A
 * BACKGROUND letter may carry the star of the bright halves (`W*`). */
FUNCTION UiPaletteName( cLetter )
   LOCAL i, aBr
   LOCAL c := iif( ValType( cLetter ) == "C", Upper( AllTrim( cLetter ) ), "" )

   UiSlotInit()

   IF Right( c, 1 ) == "*"
      aBr := { "Bright black", "Bright gray", "Bright green", "Bright cyan", ;
               "Bright red", "Bright yellow", "Bright brown", "Bright white" }
      FOR i := 1 TO 8
         IF s_aUiPal[ i ][ 1 ] + "*" == c
            RETURN aBr[ i ]
         ENDIF
      NEXT
      RETURN ""
   ENDIF

   FOR i := 1 TO Len( s_aUiPal )
      IF s_aUiPal[ i ][ 1 ] == c
         RETURN s_aUiPal[ i ][ 2 ]
      ENDIF
   NEXT

RETURN ""

/* The colour of the LETTER painted over a swatch of <cLetter>: a fixed light
 * foreground on the dark entries and black on the rest. Text mode has no
 * contrast test, so this is a table and it never needs a driver: the answer is
 * always a valid FOREGROUND letter. */
FUNCTION UiPalContrast( cLetter )
   LOCAL c := Upper( AllTrim( iif( ValType( cLetter ) == "C", cLetter, "" ) ) )

   /* a surface with the star is the bright entry of its colour (`W*` lights like
    * `W+`), so it needs the contrast of that entry */
   IF Right( c, 1 ) == "*"
      c := Left( c, Len( c ) - 1 ) + "+"
   ENDIF

   DO CASE
   CASE c == "N"  ; RETURN "W+"
   CASE c == "B"  ; RETURN "W+"
   CASE c == "N+" ; RETURN "W+"
   CASE c == "GR" ; RETURN "W+"
   ENDCASE
RETURN "N"

/* The PAIR a swatch of the palette is painted with. A BASE or BRIGHT surface
 * (`N B G BG R RB GR W` / `N* … W*`) is painted as the BACKGROUND with a
 * contrasting letter on top, which is how it will look on screen. A BRIGHT
 * colour of the TEXT row (`N+ … W+`) is painted as INK over black: the plus
 * brightens the LETTER (hbgtcore.c decodes it as `nColor |= 0x08`, in the
 * foreground nibble), so it is not a surface. */
FUNCTION UiPalSwatchPair( cLetter )
   LOCAL c := Upper( AllTrim( iif( ValType( cLetter ) == "C", cLetter, "" ) ) )

   IF Right( c, 1 ) == "*"
      /* a bright SURFACE: the star goes at the end of the pair */
      RETURN UiPalContrast( c ) + "/" + c
   ENDIF
   IF ! UiPairFgOk( c )
      RETURN ""
   ENDIF
   IF Right( c, 1 ) == "+"
      RETURN c + "/N"
   ENDIF

RETURN UiPalContrast( c ) + "/" + c

/* ---------- the pairs ---------- */

FUNCTION UiPairFgOk( cFg )
   LOCAL i
   LOCAL c := iif( ValType( cFg ) == "C", Upper( AllTrim( cFg ) ), "" )

   UiSlotInit()
   IF Len( c ) == 0
      RETURN .F.
   ENDIF
   FOR i := 1 TO Len( s_aUiPal )
      IF s_aUiPal[ i ][ 1 ] == c
         RETURN .T.
      ENDIF
   NEXT

RETURN .F.

FUNCTION UiPairBgOk( cBg )
   LOCAL i
   LOCAL c := iif( ValType( cBg ) == "C", Upper( AllTrim( cBg ) ), "" )

   UiSlotInit()
   IF Len( c ) == 0
      RETURN .F.
   ENDIF
   /* the surface half: one of the eight base letters, or the same with the star
    * of the bright ones (`W*`). A PLUS here is the OTHER marker - it brightens
    * the ink - so it is accepted and UiPairSplit() moves it to the text half
    * (hbgtcore.c: the bits are position-free). */
   IF Right( c, 1 ) == "*" .OR. Right( c, 1 ) == "+"
      c := Left( c, Len( c ) - 1 )
   ENDIF
   FOR i := 1 TO 8
      IF s_aUiPal[ i ][ 1 ] == c
         RETURN .T.
      ENDIF
   NEXT

RETURN .F.

/* "W+/N" -> { "W+", "N" }, or {} when it is not a pair this program can paint
 * (wrong number of slashes, a letter outside the palette). The vocabulary is the
 * whole 16 x 16 space of the driver - 16 inks (the bright ones with `+`) and 16
 * surfaces (the bright ones with `*`) - and the answer is CANONICAL: a marker
 * written in the wrong half is moved to its own (a star in the text half over
 * `W` becomes `N/W*`, and `N/B+` becomes `N+/B`), because the two bits are
 * position-free in the driver. */
FUNCTION UiPairSplit( cPair )
   LOCAL n
   LOCAL cFg, cBg
   LOCAL lFgBright := .F., lBgBright := .F.
   LOCAL c := iif( ValType( cPair ) == "C", AllTrim( cPair ), "" )

   IF Len( c ) == 0
      RETURN {}
   ENDIF

   n := At( "/", c )
   IF n <= 1 .OR. n >= Len( c )
      RETURN {}
   ENDIF
   IF At( "/", SubStr( c, n + 1 ) ) > 0
      RETURN {}
   ENDIF

   cFg := Left( c, n - 1 )
   cBg := SubStr( c, n + 1 )

   /* The two bits are POSITION-FREE: '+' is the bright bit of the ink and '*' is
    * the high bit of the surface (hbgtcore.c: 0x08 and 0x80), so `N+/B`,
    * `N/B+` and the same star written in the text half all describe the same
    * attribute (measured: ColorToN() gives the same byte for each pair of
    * forms). Take each marker from wherever it was written and put it in ITS
    * half, so the store always holds the canonical form (`N+/B`, `N/W*`). */
   IF "*" $ cFg
      lBgBright := .T.
      cFg := StrTran( cFg, "*", "" )
   ENDIF
   IF "*" $ cBg
      lBgBright := .T.
      cBg := StrTran( cBg, "*", "" )
   ENDIF
   IF "+" $ cFg
      lFgBright := .T.
      cFg := StrTran( cFg, "+", "" )
   ENDIF
   IF "+" $ cBg
      lFgBright := .T.
      cBg := StrTran( cBg, "+", "" )
   ENDIF

   IF ! UiPairFgOk( cFg ) .OR. ! UiPairBgOk( cBg )
      RETURN {}
   ENDIF

   cFg := Upper( AllTrim( cFg ) )
   cBg := Upper( AllTrim( cBg ) )
   IF lFgBright
      cFg += "+"
   ENDIF
   IF lBgBright
      cBg += "*"
   ENDIF

RETURN { cFg, cBg }

FUNCTION UiPairOk( cPair )
RETURN ! Empty( UiPairSplit( cPair ) )

/* the canonical pair, or "" when the two letters cannot make one. It goes
 * through UiPairSplit() and NOT through a pre-check of each half: a half may
 * carry the marker of the OTHER half (`N*`, `W+`), and it is Split that moves
 * each bit where it belongs, exactly as the driver reads it. */
FUNCTION UiPairMake( cFg, cBg )
   LOCAL a

   IF ValType( cFg ) != "C" .OR. ValType( cBg ) != "C"
      RETURN ""
   ENDIF
   a := UiPairSplit( AllTrim( cFg ) + "/" + AllTrim( cBg ) )
   IF Empty( a )
      RETURN ""
   ENDIF
RETURN a[ 1 ] + "/" + a[ 2 ]

/* ---------- the store of exceptions ---------- */

/* Is there an exception on <nSlot>? */
FUNCTION UiOvHas( nSlot )
   IF nSlot < 1 .OR. nSlot > Len( s_aUiOv )
      RETURN .F.
   ENDIF
RETURN ! Empty( s_aUiOv[ nSlot ] )

/* the exception of <nSlot>, or "" when that slot follows the theme */
FUNCTION UiOvGet( nSlot )
   IF nSlot < 1 .OR. nSlot > Len( s_aUiOv )
      RETURN ""
   ENDIF
RETURN s_aUiOv[ nSlot ]

/* pins <cPair> on <nSlot>. Answers .F. - changing NOTHING - for a slot that does
 * not exist or a pair that cannot be painted, so a bad call can never leave a
 * slot with a colour SetColor() would reject. */
FUNCTION UiOvSet( nSlot, cPair )
   LOCAL a := UiPairSplit( cPair )
   LOCAL c

   UiSlotInit()

   IF ValType( nSlot ) != "N" .OR. nSlot < 1 .OR. nSlot > Len( s_aUiSlot )
      RETURN .F.
   ENDIF
   IF Empty( a )
      RETURN .F.
   ENDIF

   c := a[ 1 ] + "/" + a[ 2 ]
   s_aUiOv[ nSlot ] := c

RETURN .T.

/* the slot goes back to the pair of the theme in force */
FUNCTION UiOvClear( nSlot )
   UiSlotInit()
   IF nSlot < 1 .OR. nSlot > Len( s_aUiOv )
      RETURN .F.
   ENDIF
   s_aUiOv[ nSlot ] := ""
RETURN .T.

FUNCTION UiOvClearAll()
   LOCAL i
   UiSlotInit()
   FOR i := 1 TO Len( s_aUiOv )
      s_aUiOv[ i ] := ""
   NEXT
RETURN NIL

FUNCTION UiOvCount()
   LOCAL i, n := 0
   FOR i := 1 TO Len( s_aUiOv )
      IF ! Empty( s_aUiOv[ i ] )
         n++
      ENDIF
   NEXT
RETURN n

/* { { cKey, cPair }, ... } of the exceptions ONLY, in slot order: it is what
 * hwbro.ini stores, and the reason saving writes just the exceptions. */
FUNCTION UiOvList()
   LOCAL a := {}, i
   UiSlotInit()
   FOR i := 1 TO Len( s_aUiOv )
      IF ! Empty( s_aUiOv[ i ] )
         AAdd( a, { s_aUiSlot[ i ][ 1 ], s_aUiOv[ i ] } )
      ENDIF
   NEXT
RETURN a

/* applies { { cKey, cPair }, ... }. Every row is validated on its own and a row
 * that cannot be painted - unknown slot, a colour outside the palette, a bright
 * background - is IGNORED, so a hand-edited file can lose at most its own line.
 * Answers how many were applied. */
FUNCTION UiOvLoad( aList )
   LOCAL i, n := 0, nSlot, cPair, a
   LOCAL cKey

   UiSlotInit()

   IF ! HB_ISARRAY( aList )
      RETURN 0
   ENDIF

   FOR i := 1 TO Len( aList )
      IF ! HB_ISARRAY( aList[ i ] ) .OR. Len( aList[ i ] ) < 2
         LOOP
      ENDIF
      cKey  := aList[ i ][ 1 ]
      cPair := aList[ i ][ 2 ]
      a     := UiPairSplit( cPair )
      IF Empty( a )
         LOOP
      ENDIF
      nSlot := UiSlotByKey( cKey )
      IF nSlot == 0
         LOOP
      ENDIF
      s_aUiOv[ nSlot ] := a[ 1 ] + "/" + a[ 2 ]
      n++
   NEXT

RETURN n

/* A COPY of the store, element by element (Harbour arrays are references, AGENTS
 * trap 67): the screen takes one on entry so Cancel can put back exactly what
 * there was, without ACopy( a, {} ) - which copies nothing (trap 33). */
FUNCTION UiOvSnapshot()
   LOCAL a := {}, i
   FOR i := 1 TO Len( s_aUiOv )
      AAdd( a, s_aUiOv[ i ] )
   NEXT
RETURN a

FUNCTION UiOvRestore( aSave )
   LOCAL i
   IF ! HB_ISARRAY( aSave )
      RETURN .F.
   ENDIF
   FOR i := 1 TO Min( Len( s_aUiOv ), Len( aSave ) )
      s_aUiOv[ i ] := aSave[ i ]
   NEXT
RETURN .T.

FUNCTION UiClr( cName )
   DO CASE
   CASE cName == "DESKTOP" ; RETURN UI_C_DESKTOP
   CASE cName == "MENUBAR" ; RETURN UI_C_MENUBAR
   CASE cName == "MENUACT" ; RETURN UI_C_MENUACT
   CASE cName == "BOX"     ; RETURN UI_C_BOX
   CASE cName == "BOXBRD"  ; RETURN UI_C_BOXBORD
   CASE cName == "BOXSEL"  ; RETURN UI_C_BOXSEL
   CASE cName == "ERR"     ; RETURN UI_C_ERR
   CASE cName == "STATUS"  ; RETURN UI_C_STATUS
   CASE cName == "STATBAR" ; RETURN UI_C_STATUSBAR
   CASE cName == "HDR"     ; RETURN UI_C_HDR
   CASE cName == "REC"     ; RETURN UI_C_REC
   CASE cName == "RECSEL"  ; RETURN UI_C_RECSEL
   CASE cName == "HINT"    ; RETURN UI_C_HINT
   CASE cName == "INPUT"   ; RETURN UI_C_INPUT
   ENDCASE
RETURN UI_C_DESKTOP

FUNCTION UiCls()
   SetColor( UI_C_DESKTOP )
   CLS
RETURN NIL

/* ---------- screen geometry (native 120x44 canvas) ----------
 * Every screen derives its size from these helpers. MaxCol()/MaxRow() are the
 * LAST index of the grid, so the usable counts are one more. Nothing may write
 * the grid size as a literal in drawing code: BP_SCR_ROWS/BP_SCR_COLS in
 * bp_def.ch request the mode and the rest of the program reflows from here.
 *
 * The *Fit* helpers clamp a block so that it ends inside the canvas; they are
 * the safe replacement for the old "Min( ..., 79 )" style clamps, which
 * silently clipped a grown box. */

FUNCTION UiCols()
RETURN MaxCol() + 1

FUNCTION UiRows()
RETURN MaxRow() + 1

/* first column of a nW wide block centred on the canvas */
FUNCTION UiCenterCol( nW )
RETURN Max( 0, Int( ( UiCols() - nW ) / 2 ) )

/* first row of a nH high block centred on the canvas */
FUNCTION UiCenterRow( nH )
RETURN Max( 0, Int( ( UiRows() - nH ) / 2 ) )

/* clamp the left column of a nW wide block into the canvas */
FUNCTION UiFitCol( nCol, nW )
RETURN Max( 0, Min( nCol, UiCols() - nW ) )

/* clamp the top row of a nH high block into the canvas */
FUNCTION UiFitRow( nRow, nH )
RETURN Max( 0, Min( nRow, UiRows() - nH ) )

/* ---------- two pure decisions of the splash (splash-mouse.md S5) ----------
 * They live here and not in hwbro.prg because the headless banks link THIS
 * module (bp_ui.prg) and never the main program: BpSplash() only composes
 * them, so the bank can pin them without a window and without a splash. */

/* S1/S5: .T. when the cell (nRow, nCol) falls inside the rectangle
 * nT..nB / nL..nR, borders included. The splash OK button is decided with
 * this, and the button and its shadow are two different rectangles: a click on
 * the shadow (one row below / one column right of the button) is NOT a click
 * on the button and leaves the splash on screen. Junk arguments answer .F., so
 * a click source that answers something unexpected never closes anything. */
FUNCTION UiCellInBox( nRow, nCol, nT, nL, nB, nR )
   IF ValType( nRow ) != "N" .OR. ValType( nCol ) != "N" .OR. ;
      ValType( nT ) != "N" .OR. ValType( nL ) != "N" .OR. ;
      ValType( nB ) != "N" .OR. ValType( nR ) != "N"
      RETURN .F.
   ENDIF
   /* an inverted rectangle is not a rectangle */
   IF nT > nB .OR. nL > nR
      RETURN .F.
   ENDIF
RETURN nRow >= nT .AND. nRow <= nB .AND. nCol >= nL .AND. nCol <= nR

/* S2 of browse-edit-mouse.md: which column of a row of cells covers the canvas
 * column nX. aWidths holds the width, in cells, of the columns that are VISIBLE
 * in the window, in painting order, and nFirst is the canvas column where the
 * cells of the first one start; between two columns there are nGap cells, and
 * EVERY one of those cells belongs to the column on its LEFT (the same rule the
 * header of the panels follows), so a click on a separator can only move the
 * cursor to that column and never two of them. Answers the 1-based index inside
 * aWidths, or 0 when nX is left of nFirst or past the last column (its own gap
 * included) - the caller then KEEPS the column it had. A width that is not a
 * number counts as one cell instead of opening a hole in the row, and a nGap
 * that is not a number means the cells are contiguous. Pure: no window, no
 * state, no storage touched. */
FUNCTION UiColAtX( aWidths, nX, nFirst, nGap )
   LOCAL i, n, nOff := 0
   IF ! HB_ISARRAY( aWidths ) .OR. Len( aWidths ) == 0
      RETURN 0
   ENDIF
   IF ValType( nX ) != "N" .OR. ValType( nFirst ) != "N"
      RETURN 0
   ENDIF
   IF ValType( nGap ) != "N" .OR. nGap < 0
      nGap := 0
   ENDIF
   IF nX < nFirst
      RETURN 0
   ENDIF
   FOR i := 1 TO Len( aWidths )
      n := aWidths[ i ]
      IF ValType( n ) != "N" .OR. n < 1
         n := 1
      ENDIF
      IF nX < nFirst + nOff + n + nGap
         RETURN i
      ENDIF
      nOff += n + nGap
   NEXT
RETURN 0

/* S6 of browse-edit-mouse.md: the RECORD context menu of the Browse edit. One
 * action code per entry, and every entry calls the SAME routine its key calls:
 * bp_core.prg turns the chosen code into the key of the browser
 * (UiRecCtxKey()) and lets the DO CASE of CoreBrowse() run it, so the menu and
 * the keyboard cannot diverge.
 *
 * The list is { label, action, flag } - the shape HcCtxPanel() of bp_hc.prg
 * takes -, the hot letter of every entry is unique inside its own label (C, I,
 * R, P, D or U, A, S) and a row with no action is the RULE that groups two
 * blocks and that the cursor never reaches.
 *
 * The row of the delete follows Deleted(): `~D~elete record` on a live record
 * and `~U~undelete record` on a record already marked as deleted, because the
 * SAME key (Del) does the two things (CoreDeleteRecall()).
 *
 * S6/L9 (the user: "Las opciones Paste Field y Paste record no deben estar
 * disponibles si no hice antes un Copy Field o Copy Record"): the two PASTE
 * rows carry the "D" of the menus of the program (trap 13) while the matching
 * internal clipboard is empty, so the popup paints them in UI_C_BOXDIM and
 * never lets the cursor, the wheel, the pointer, a click, Enter or their hot
 * letter reach them. The two flags come in as the LAST optional arguments and
 * default to .F. - not available is the safe answer -, and bp_core.prg passes
 * the state of the clipboard at the moment the menu is built. The labels, the
 * order and the hot letters of the rows do not change with the flags. */
#define URC_CPFLD  "CPFLD"          /* Copy field       Shift-F4  */
#define URC_PSFLD  "PSFLD"          /* Paste field      Ctrl-F4   */
#define URC_CPREC  "CPREC"          /* Copy record      Shift-F7  */
#define URC_PSREC  "PSREC"          /* Paste record     Ctrl-F7   */
#define URC_DELREC "DELREC"         /* Delete/Undelete  Del       */
#define URC_APPEND "APPEND"         /* Append record    Ins       */
#define URC_SEEK   "SEEK"           /* Seek / Find      Ctrl-F    */

/* The list, built for the state of the record the menu is about. Public so the
 * headless bank pins both labels of the delete row, the order of the entries
 * and the fact that the rules carry no action. */
FUNCTION UiRecCtxItems( lDeleted, lPasteField, lPasteRecord )
   DEFAULT lDeleted TO .F.
   DEFAULT lPasteField TO .F.
   DEFAULT lPasteRecord TO .F.
RETURN { { "~C~opy field",      URC_CPFLD,  ""                            }, ;
         { "Paste f~i~eld",     URC_PSFLD,  iif( lPasteField, "", "D" ) }, ;
         { "",                  ""                                        }, ;
         { "Copy ~r~ecord",     URC_CPREC,  ""                            }, ;
         { "~P~aste Record",    URC_PSREC,  iif( lPasteRecord, "", "D" ) }, ;
         { "",                  ""                                        }, ;
         { iif( lDeleted, "~U~ndelete record", "~D~elete record" ), URC_DELREC, "" }, ;
         { "",                  ""                                        }, ;
         { "~A~ppend record",   URC_APPEND, ""                            }, ;
         { "",                  ""                                        }, ;
         { "~S~eek / Find",     URC_SEEK,   ""                            } }

/* S6: the KEY the chosen entry stands for, 0 when the menu was closed without
 * a choice (the caller then does nothing). This is what makes the menu and the
 * keyboard one single path: bp_core.prg sets its key variable to this answer
 * and the existing DO CASE of the browser runs exactly what the F4/F7/Del/Ins
 * keys run.
 *
 * `Seek / Find` answers K_CTRL_F, the key of the search. In this driver family
 * K_CTRL_F IS K_END (both 6) and only the CTRL bit of the stroke tells them
 * apart (DbfSearchMode()), so bp_core.prg does NOT feed that code to the key
 * dispatch: it enters the search branch through its own flag. Every other code
 * here is unique and can go straight in. */
FUNCTION UiRecCtxKey( cAct )
   IF ValType( cAct ) != "C"
      RETURN 0
   ENDIF
   DO CASE
   CASE cAct == URC_CPFLD  ; RETURN K_SH_F4
   CASE cAct == URC_PSFLD  ; RETURN K_CTRL_F4
   CASE cAct == URC_CPREC  ; RETURN K_SH_F7
   CASE cAct == URC_PSREC  ; RETURN K_CTRL_F7
   CASE cAct == URC_DELREC ; RETURN K_DEL
   CASE cAct == URC_APPEND ; RETURN K_INS
   CASE cAct == URC_SEEK   ; RETURN K_CTRL_F
   ENDCASE
RETURN 0

/* S4/S5: the "Data engine:" line of the splash, built from the RDD names the
 * engine answers at run time (RddList()) instead of a literal. Tolerant of
 * everything the engine may hand over: a NIL or non-array list, NIL/""/
 * non-character entries and blanks around a name; duplicates are collapsed
 * case-insensitively keeping the first spelling and the original order. The
 * line NEVER grows past nMaxW columns: the names that do not fit are dropped
 * and " ..." says the list goes on, so a build with many RDDs cannot push the
 * splash box out of the canvas. With no usable name it answers cFallback -
 * the exact line the splash showed before this change. Pure: no window, no
 * engine call of its own (the caller passes RddList()). */
FUNCTION UiRddLine( aRdd, cFallback, nMaxW )
   LOCAL aName := {}, c := "", cOne, cAll := "", i
   DEFAULT aRdd TO {}
   DEFAULT cFallback TO UI_RDD_FALLBACK
   DEFAULT nMaxW TO UiCols() - 12
   IF ValType( nMaxW ) != "N" .OR. nMaxW < 0
      nMaxW := UiCols() - 12
   ENDIF
   IF HB_ISARRAY( aRdd )
      FOR i := 1 TO Len( aRdd )
         IF ValType( aRdd[ i ] ) == "C"
            cOne := AllTrim( aRdd[ i ] )
            /* Len() and not Empty(): Empty() is .T. for a string of blanks too
             * (AGENTS trap 46) */
            IF Len( cOne ) > 0 .AND. ;
               AScan( aName, {| c | Upper( c ) == Upper( cOne ) } ) == 0
               AAdd( aName, cOne )
            ENDIF
         ENDIF
      NEXT
   ENDIF
   IF Len( aName ) == 0
      IF ValType( cFallback ) != "C"
         RETURN ""
      ENDIF
      RETURN Left( cFallback, nMaxW )
   ENDIF
   FOR i := 1 TO Len( aName )
      cAll += iif( i == 1, "", UI_RDD_SEP ) + aName[ i ]
   NEXT
   IF Len( UI_RDD_PRE ) + Len( cAll ) <= nMaxW
      RETURN UI_RDD_PRE + cAll
   ENDIF
   /* it does not fit: keep the names that fit and reserve room for the " ..." */
   FOR i := 1 TO Len( aName )
      cOne := iif( i == 1, aName[ i ], UI_RDD_SEP + aName[ i ] )
      IF Len( UI_RDD_PRE ) + Len( c ) + Len( cOne ) + Len( UI_RDD_TAIL ) > nMaxW
         EXIT
      ENDIF
      c += cOne
   NEXT
   IF Len( c ) == 0
      /* not even the first name fits: cut the line at the limit */
      RETURN Left( UI_RDD_PRE + aName[ 1 ], nMaxW )
   ENDIF
RETURN UI_RDD_PRE + c + UI_RDD_TAIL

/* ---------- GTWVG repaint control (anti flicker) ----------
 * GTWVG exposes two extensions of its own (contrib/gtwvg/hbgtwvg.ch):
 *    HB_GTI_DEFERPAINT = HB_GTI_EXTENDED(100) + 6   -> 106
 *    HB_GTI_REFRESH    = HB_GTI_EXTENDED(100) + 9   -> 109
 * While DEFERPAINT is on the window does NOT repaint (the changes pile up
 * in the text buffer); when it is turned off a REFRESH has to be forced so
 * that everything appears at once. With this a full redraw is seen in one
 * shot and the flicker disappears. It can be nested.
 *
 * Besides, the system cursor (the GTWVG "caret", a 9x3 px bar at the base of
 * the cell) is HIDDEN while the painting block lasts and restored when it
 * ends: otherwise GTWVG leaves it painted over the cells the DevPos goes
 * through (box borders and column separators) and the user sees
 * "low cursors" appearing and disappearing on every repaint. It is only touched
 * at the OUTERMOST level and only when it was visible, so the internal
 * HideCaret/ShowCaret of the driver stays balanced (the structure editor
 * hides it on its own and it must stay hidden after every repaint). */

FUNCTION UiPaintBegin()
   LOCAL nOld
   IF s_nPaint == 0
      UiGtInfo( 106, .T. )
      /* SetCursor(0) hides the caret and returns the previous state. It is only
       * saved when it was VISIBLE (>0): if it was already hidden (structure
       * editor) nothing is touched on exit and the internal HideCaret/ShowCaret
       * of the driver stays compensated exactly as it was. */
      nOld := SetCursor( 0 )
      IF ValType( nOld ) == "N" .AND. nOld > 0
         s_nCurSave := nOld
      ELSE
         s_nCurSave := NIL
      ENDIF
   ENDIF
   s_nPaint++
RETURN NIL

FUNCTION UiPaintEnd()
   LOCAL nCur
   IF s_nPaint > 0
      s_nPaint--
      IF s_nPaint == 0
         UiGtInfo( 106, .F. )
         UiGtInfo( 109 )
         /* restore the cursor: refresh first (above) and show it afterwards,
          * so the caret is not painted in the middle of the refresh */
         IF ! hb_IsNIL( s_nCurSave )
            nCur := s_nCurSave
            s_nCurSave := NIL
            SetCursor( nCur )
         ENDIF
      ENDIF
   ENDIF
RETURN NIL

/* hb_gtInfo() tolerant to failure (if the driver does not support the extension) */
STATIC FUNCTION UiGtInfo( nWhat, xVal )
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      IF xVal == NIL
         hb_gtInfo( nWhat )
      ELSE
         hb_gtInfo( nWhat, xVal )
      ENDIF
   RECOVER
   END SEQUENCE
RETURN NIL

FUNCTION UiWrite( nRow, nCol, cText, cColor )
   DEFAULT cColor TO UI_C_DESKTOP
   SetColor( cColor )
   @ nRow, nCol SAY cText
   SetColor( UI_C_DESKTOP )
RETURN NIL

/* ---------- shadow (like the original) ---------- */

FUNCTION UiShadow( nT, nL, nB, nR )
   LOCAL i
   /* it is drawn with blocks so the background color does not depend on the brightness */
   SetColor( UI_C_SHADOW )
   FOR i := nT + 1 TO nB + 1
      @ i, nR + 1 SAY Replicate( Chr( 219 ), 2 )
   NEXT
   @ nB + 1, nL + 2 SAY Replicate( Chr( 219 ), nR - nL )
   SetColor( UI_C_DESKTOP )
RETURN NIL

/* ---------- text with a hot key marked as ~x~ ---------- */

FUNCTION UiDrawHot( nRow, nCol, cText, cColor, cHot )
   LOCAL p1, p2, cAntes, cLetra, cResto
   DEFAULT cColor TO UI_C_BOX
   DEFAULT cHot   TO UI_C_HOT
   p1 := At( "~", cText )
   IF p1 == 0
      /* no marks: highlight the first visible character (style of the original) */
      p1 := 1
      DO WHILE p1 <= Len( cText ) .AND. SubStr( cText, p1, 1 ) == " "
         p1++
      ENDDO
      IF p1 > Len( cText )
         SetColor( cColor )
         @ nRow, nCol SAY cText
         Return NIL
      ENDIF
      SetColor( cColor )
      @ nRow, nCol SAY SubStr( cText, 1, p1 - 1 )
      SetColor( cHot )
      @ nRow, nCol + p1 - 1 SAY SubStr( cText, p1, 1 )
      SetColor( cColor )
      @ nRow, nCol + p1 SAY SubStr( cText, p1 + 1 )
      Return NIL
   ENDIF
   p2 := At( "~", SubStr( cText, p1 + 1 ) )
   IF p2 == 0
      SetColor( cColor )
      @ nRow, nCol SAY StrTran( cText, "~", "" )
      Return NIL
   ENDIF
   p2 := p1 + p2
   IF .F.
      SetColor( cColor )
      @ nRow, nCol SAY cText
      Return NIL
   ENDIF
   cAntes := SubStr( cText, 1, p1 - 1 )
   cLetra := SubStr( cText, p1 + 1, p2 - p1 - 1 )
   cResto := SubStr( cText, p2 + 1 )
   SetColor( cColor )
   @ nRow, nCol SAY cAntes
   SetColor( cHot )
   @ nRow, nCol + Len( cAntes ) SAY cLetra
   SetColor( cColor )
   @ nRow, nCol + Len( cAntes ) + Len( cLetra ) SAY cResto
RETURN NIL

/* ---------- visible width of a text with ~ marks (without the ~) ---------- */

FUNCTION UiHotLen( cText )
RETURN Len( StrTran( cText, "~", "" ) )

/* hot key marked as ~x~ inside the text of an option ("" when there is none) */
FUNCTION UiHotKey( cText )
   LOCAL p1 := At( "~", cText ), p2
   IF p1 == 0
      RETURN ""
   ENDIF
   p2 := At( "~", SubStr( cText, p1 + 1 ) )
   IF p2 == 0
      RETURN ""
   ENDIF
   p2 := p1 + p2
RETURN Upper( Left( SubStr( cText, p1 + 1, p2 - p1 - 1 ), 1 ) )

/* =================== menu accelerators (menu-accelerators.md) =============
 * The DB manager advertises a shortcut in the right column of almost every menu
 * row ("Alt-F2", "Shift-F4", "Alt-BSpc", ...). These two functions are the ONLY
 * rule that reads one: UiAccelName() turns the shortcut text of a row into its
 * canonical name and UiAccelHit() answers whether a key stroke means that name.
 *
 * Both are PURE (no screen, no RDD, no file) and they live HERE because bank 3
 * links bp_hc.prg + bp_ui.prg and bank 2 links bp_dot.prg + bp_ui.prg WITHOUT
 * bp_hc.prg: calling HcAltLetter() from this module would break that link, so
 * the letter of a stroke is extracted locally (S8).
 *
 * MEASURED (AGENTS.md trap 37): this GTWVG hands `Alt+<letter>` to Inkey() as the
 * BARE LETTER plus the ALT bit of HB_GTI_KBDSHIFTS, never as K_ALT_A..K_ALT_Z,
 * while the function keys DO arrive as their own K_ALT_F<n>/K_SH_F<n>/
 * K_CTRL_F<n> codes. Both channels are read (S7), and AltGr - ALT carried
 * together with CTRL (trap 38) - is rejected: it is a character, not a chord.
 * ------------------------------------------------------------------------- */

/* canonical name of the shortcut text of a menu row, or "" when that text is
 * not an accelerator. Tolerant on purpose: case and outer spaces do not matter.
 *   "Alt-F2"    -> "ALT-F2"        "alt-minus" -> "ALT-MINUS"
 *   "Shift-Tab" -> "SHIFT-TAB"     "Alt-BSpc"  -> "ALT-BSPC"
 *   "F10"       -> "F10"           "H" / "K"   -> ""
 * The two quick keys of the F1 menu are NOT accelerators: a bare letter or digit
 * is the (~x~) hot key of the row, which the menu reads with UiHotKey() and the
 * DB manager does not handle at all, so it answers "" and never enters a map. */
FUNCTION UiAccelName( cShortcut )
   LOCAL c, p, cMod, cTok
   IF ValType( cShortcut ) != "C"
      RETURN ""
   ENDIF
   c := Upper( AllTrim( cShortcut ) )
   IF Len( c ) == 0
      RETURN ""
   ENDIF
   p := At( "-", c )
   IF p > 0
      cMod := Left( c, p - 1 )
      cTok := SubStr( c, p + 1 )
      /* one modifier and one key: "ALT-F2-x" is not a shortcut of this program */
      IF Empty( cMod ) .OR. Empty( cTok ) .OR. At( "-", cTok ) > 0
         RETURN ""
      ENDIF
      IF ! ( cMod == "ALT" .OR. cMod == "SHIFT" .OR. cMod == "CTRL" )
         RETURN ""
      ENDIF
      IF ! UiAccelTok( cTok )
         RETURN ""
      ENDIF
      RETURN cMod + "-" + cTok
   ENDIF
   IF Len( c ) == 1
      RETURN ""
   ENDIF
   IF ! UiAccelTok( c )
      RETURN ""
   ENDIF
RETURN c

/* does this key stroke mean <cName>? <cName> is the canonical name, <nKey> the
 * key Inkey() delivered and <nShift> the word HcShiftState() returned for it.
 * The shift state is REQUIRED to be a number - the LIVE state of the keyboard
 * has to be known for a stroke to be an accelerator, and a caller that cannot
 * answer it (a bank, a build without the driver) gets .F. instead of a guess. */
FUNCTION UiAccelHit( cName, nKey, nShift )
   LOCAL c, p, cMod, cTok, aK, lAlt, lCtrl, lSh, cCh
   IF ValType( nKey ) != "N" .OR. ValType( nShift ) != "N"
      RETURN .F.
   ENDIF
   c := UiAccelName( cName )
   IF Len( c ) == 0
      RETURN .F.
   ENDIF
   lAlt  := hb_bitAnd( nShift, HB_GTI_KBD_ALT ) != 0
   lCtrl := hb_bitAnd( nShift, HB_GTI_KBD_CTRL ) != 0
   lSh   := hb_bitAnd( nShift, HB_GTI_KBD_SHIFT ) != 0
   /* AltGr is Ctrl+Alt on a Spanish keyboard (trap 38): the two bits together
    * are a character, not an accelerator, whichever channel brings them */
   IF lAlt .AND. lCtrl
      RETURN .F.
   ENDIF
   p := At( "-", c )
   cMod := iif( p > 0, Left( c, p - 1 ), "" )
   cTok := iif( p > 0, SubStr( c, p + 1 ), c )
   aK := UiAccelRow( cTok )
   IF Empty( aK )
      RETURN .F.
   ENDIF
   cCh := UiAccelChar( nKey )
   DO CASE
   CASE cMod == "ALT"
      /* channel 1: the ALT code of the key (a function key always arrives so) */
      IF aK[ 3 ] != 0 .AND. nKey == aK[ 3 ]
         RETURN .T.
      ENDIF
      /* channel 2: the bare character (or the plain key) plus the ALT bit */
      IF ! Empty( aK[ 6 ] )
         RETURN lAlt .AND. Upper( cCh ) == aK[ 6 ]
      ENDIF
      RETURN lAlt .AND. nKey == aK[ 2 ]
   CASE cMod == "SHIFT"
      IF aK[ 4 ] != 0 .AND. nKey == aK[ 4 ]
         RETURN .T.
      ENDIF
      IF ! Empty( aK[ 6 ] )
         RETURN lSh .AND. Upper( cCh ) == aK[ 6 ]
      ENDIF
      RETURN lSh .AND. nKey == aK[ 2 ]
   CASE cMod == "CTRL"
      IF aK[ 5 ] != 0 .AND. nKey == aK[ 5 ]
         RETURN .T.
      ENDIF
      IF ! Empty( aK[ 6 ] )
         RETURN lCtrl .AND. Upper( cCh ) == aK[ 6 ]
      ENDIF
      RETURN lCtrl .AND. nKey == aK[ 2 ]
   ENDCASE
   /* no modifier: the key itself and nothing else - Shift-F10 is not F10, and a
    * stroke with a modifier is a different accelerator of this table */
   IF cMod == ""
      RETURN nKey == aK[ 2 ] .AND. ! lAlt .AND. ! lCtrl .AND. ! lSh
   ENDIF
RETURN .F.

/* { nPlain, nAlt, nSh, nCtrl, cChar } of the key called <cTok>, or {} when the
 * name is not a key of this table. cChar is what the bare-character channel
 * compares (a letter, a digit or "-") and is "" for a named key or a function
 * key, which that channel matches by their PLAIN code instead. */
STATIC FUNCTION UiAccelRow( cTok )
   LOCAL a := UiAccelKeys(), i
   FOR i := 1 TO Len( a )
      IF a[ i ][ 1 ] == cTok
         RETURN a[ i ]
      ENDIF
   NEXT
RETURN {}

/* is <cTok> the name of a key? (used by UiAccelName()) */
STATIC FUNCTION UiAccelTok( cTok )
RETURN ! Empty( UiAccelRow( cTok ) )

/* the character a key code stands for in the bare-letter channel of this driver,
 * or "" when the code is not a printable character. */
STATIC FUNCTION UiAccelChar( nKey )
   IF nKey >= 33 .AND. nKey <= 255
      RETURN Chr( nKey )
   ENDIF
RETURN ""

/* the key table of the accelerators, built once. The ALT codes are NOT
 * contiguous in inkey.ch (K_ALT_A = 286, K_ALT_B = 304, K_ALT_C = 302, ...), so
 * the letters are spelled out; the CTRL codes of the letters (1..26) are the
 * control characters of inkey.ch - K_CTRL_A is also Home - and are therefore
 * NOT stored: a Ctrl+<letter> accelerator is read from the CTRL bit only, never
 * from a code that a plain key also produces. */
STATIC FUNCTION UiAccelKeys()
   LOCAL aAlt := { K_ALT_A, K_ALT_B, K_ALT_C, K_ALT_D, K_ALT_E, K_ALT_F, K_ALT_G, ;
                   K_ALT_H, K_ALT_I, K_ALT_J, K_ALT_K, K_ALT_L, K_ALT_M, K_ALT_N, ;
                   K_ALT_O, K_ALT_P, K_ALT_Q, K_ALT_R, K_ALT_S, K_ALT_T, K_ALT_U, ;
                   K_ALT_V, K_ALT_W, K_ALT_X, K_ALT_Y, K_ALT_Z }
   LOCAL i
   IF ! Empty( s_aUiAccel )
      RETURN s_aUiAccel
   ENDIF
   s_aUiAccel := {}
   /* the 26 letters: plain 65..90, the ALT code of the table, no CTRL code */
   FOR i := 1 TO 26
      AAdd( s_aUiAccel, { Chr( 64 + i ), 64 + i, aAlt[ i ], 0, 0, Chr( 64 + i ) } )
   NEXT
   /* the ten digits and the minus sign, which this driver does deliver as the
    * bare character plus the ALT bit (Alt-Minus is a shortcut of the F2 menu) */
   AAdd( s_aUiAccel, { "0", 48, K_ALT_0, 0, 0, "0" } )
   AAdd( s_aUiAccel, { "1", 49, K_ALT_1, 0, 0, "1" } )
   AAdd( s_aUiAccel, { "2", 50, K_ALT_2, 0, 0, "2" } )
   AAdd( s_aUiAccel, { "3", 51, K_ALT_3, 0, 0, "3" } )
   AAdd( s_aUiAccel, { "4", 52, K_ALT_4, 0, 0, "4" } )
   AAdd( s_aUiAccel, { "5", 53, K_ALT_5, 0, 0, "5" } )
   AAdd( s_aUiAccel, { "6", 54, K_ALT_6, 0, 0, "6" } )
   AAdd( s_aUiAccel, { "7", 55, K_ALT_7, 0, 0, "7" } )
   AAdd( s_aUiAccel, { "8", 56, K_ALT_8, 0, 0, "8" } )
   AAdd( s_aUiAccel, { "9", 57, K_ALT_9, 0, 0, "9" } )
   AAdd( s_aUiAccel, { "MINUS", 45, K_ALT_MINUS, 0, 0, "-" } )
   /* the named keys the menus use, and their modified codes */
   AAdd( s_aUiAccel, { "BSPC",  K_BS,  K_ALT_BS,  K_SH_BS,  K_CTRL_BS,  "" } )
   AAdd( s_aUiAccel, { "INS",   K_INS, K_ALT_INS, 0,        K_CTRL_INS, "" } )
   AAdd( s_aUiAccel, { "DEL",   K_DEL, K_ALT_DEL, 0,        K_CTRL_DEL, "" } )
   AAdd( s_aUiAccel, { "TAB",   K_TAB, K_ALT_TAB, K_SH_TAB, K_CTRL_TAB, "" } )
   /* the function keys */
   AAdd( s_aUiAccel, { "F1",  K_F1,  K_ALT_F1,  K_SH_F1,  K_CTRL_F1,  "" } )
   AAdd( s_aUiAccel, { "F2",  K_F2,  K_ALT_F2,  K_SH_F2,  K_CTRL_F2,  "" } )
   AAdd( s_aUiAccel, { "F3",  K_F3,  K_ALT_F3,  K_SH_F3,  K_CTRL_F3,  "" } )
   AAdd( s_aUiAccel, { "F4",  K_F4,  K_ALT_F4,  K_SH_F4,  K_CTRL_F4,  "" } )
   AAdd( s_aUiAccel, { "F5",  K_F5,  K_ALT_F5,  K_SH_F5,  K_CTRL_F5,  "" } )
   AAdd( s_aUiAccel, { "F6",  K_F6,  K_ALT_F6,  K_SH_F6,  K_CTRL_F6,  "" } )
   AAdd( s_aUiAccel, { "F7",  K_F7,  K_ALT_F7,  K_SH_F7,  K_CTRL_F7,  "" } )
   AAdd( s_aUiAccel, { "F8",  K_F8,  K_ALT_F8,  K_SH_F8,  K_CTRL_F8,  "" } )
   AAdd( s_aUiAccel, { "F9",  K_F9,  K_ALT_F9,  K_SH_F9,  K_CTRL_F9,  "" } )
   AAdd( s_aUiAccel, { "F10", K_F10, K_ALT_F10, K_SH_F10, K_CTRL_F10, "" } )
   AAdd( s_aUiAccel, { "F11", K_F11, K_ALT_F11, K_SH_F11, K_CTRL_F11, "" } )
   AAdd( s_aUiAccel, { "F12", K_F12, K_ALT_F12, K_SH_F12, K_CTRL_F12, "" } )
RETURN s_aUiAccel

/* ---------- frames ---------- */

FUNCTION UiFrame( nT, nL, nB, nR, cColor, lDouble )
   LOCAL cH, cV, cTL, cTR, cBL, cBR, n, r
   DEFAULT lDouble TO .T.
   IF lDouble
      cH := Chr(205) ; cV := Chr(186) ; cTL := Chr(201) ; cTR := Chr(187) ; cBL := Chr(200) ; cBR := Chr(188)
   ELSE
      cH := Chr(196) ; cV := Chr(179) ; cTL := Chr(218) ; cTR := Chr(191) ; cBL := Chr(192) ; cBR := Chr(217)
   ENDIF
   SetColor( cColor )
   @ nT, nL SAY cTL + Replicate( cH, nR - nL - 1 ) + cTR
   FOR r := nT + 1 TO nB - 1
      @ r, nL SAY cV
      @ r, nR SAY cV
   NEXT
   @ nB, nL SAY cBL + Replicate( cH, nR - nL - 1 ) + cBR
   SetColor( UI_C_DESKTOP )
RETURN NIL

FUNCTION UiFillBox( nT, nL, nB, nR, cColor )
   UiFill( nT, nL, nB, nR, cColor )
RETURN NIL

STATIC FUNCTION UiFill( nT, nL, nB, nR, cColor )
   LOCAL r
   SetColor( cColor )
   FOR r := nT TO nB
      @ r, nL SAY Space( nR - nL + 1 )
   NEXT
   SetColor( UI_C_DESKTOP )
RETURN NIL

/* ---------- message box ---------- */

/* split the lines longer than nW: PadR() does NOT truncate, so a long
 * line was painted whole and ran out of the frame (it was seen in the boxes
 * of the F4 options, with 30+ character texts inside 10 wide boxes). */
STATIC FUNCTION UiWrapLines( aLin, nW )
   LOCAL a := {}, i, c
   FOR i := 1 TO Len( aLin )
      c := aLin[ i ]
      DO WHILE Len( c ) > nW
         AAdd( a, Left( c, nW ) )
         c := SubStr( c, nW + 1 )
      ENDDO
      AAdd( a, c )
   NEXT
RETURN a

/* Text width available inside a modal box, and therefore the widest line it
 * will accept. The margins keep the box away from the screen edges so the
 * 2-column shadow always fits; the value grows with the canvas (108 columns on
 * the 120x44 grid) instead of the old fixed 70. */
STATIC FUNCTION UiBoxTextW()
RETURN Max( 20, UiCols() - 12 )

/* S60: .T. when a click falls on the OK button of a message box (UiMsg, and
 * therefore UiInfo/UiErr): a message has a single way out and this is it, so a
 * click anywhere else leaves the box on screen instead of guessing. */
FUNCTION UiOkClick( nRow, nCol, nOkRow, nOkCol )
   IF ValType( nRow ) != "N" .OR. ValType( nCol ) != "N" .OR. ;
      ValType( nOkRow ) != "N" .OR. ValType( nOkCol ) != "N"
      RETURN .F.
   ENDIF
   IF nRow != nOkRow
      RETURN .F.
   ENDIF
RETURN nCol >= nOkCol .AND. nCol < nOkCol + Len( UI_OK_LBL )

FUNCTION UiMsg( cText, cTitle, cColor )
   LOCAL aLin, nMax, nT, nL, nB, nR, i, cSave, cOldCur, nTextW, nMaxH, nMaxW
   LOCAL nKey, aPt, nOkRow, nOkCol
   DEFAULT cTitle TO "hwBro"
   DEFAULT cColor TO UI_C_BOX
   aLin := hb_ATokens( cText, Chr( 10 ) )
   nTextW := UiBoxTextW()
   nMaxW := Min( nTextW + 2, UiCols() - 4 )
   nMaxH := UiRows() - 4
   nMax := Len( cTitle ) + 4
   FOR i := 1 TO Len( aLin )
      aLin[ i ] := StrTran( aLin[ i ], Chr( 13 ), "" )
      nMax := Max( nMax, Len( aLin[ i ] ) )
   NEXT
   aLin := UiWrapLines( aLin, nTextW )
   nMax := Min( nMax, nTextW )
   nR := Min( nMax + 2, nMaxW )
   nB := Min( Len( aLin ) + 4, nMaxH )
   /* a message with more lines than the canvas allows is truncated so the text
    * never runs out of the box (before nB was capped at 21 and the extra lines
    * were painted over the frame and the rows below it) */
   IF Len( aLin ) > nB - 4
      ASize( aLin, nB - 4 )
   ENDIF
   nT := UiFitRow( UiCenterRow( nB ), nB + 1 )
   nL := UiFitCol( UiCenterCol( nR ), nR + 2 )
   /* the system cursor stays hidden the WHOLE time the box is on
    * screen: UiPaintBegin/End only hides it while painting, and while the box
    * waited for a key (Inkey) it blinked over the box again. This is done before
    * the first UiPaintBegin so the painting block saves/restores the
    * already hidden state. */
   cOldCur := SetCursor( 0 )
   cSave := SaveScreen( nT, nL, nT + nB + 1, Min( nL + nR + 2, MaxCol() ) )
   /* the box is drawn "in one shot" (no flicker) */
   UiPaintBegin()
   UiShadow( nT, nL, nT + nB, nL + nR )
   UiFill( nT, nL, nT + nB, nL + nR, cColor )
   UiFrame( nT, nL, nT + nB, nL + nR, cColor, .T. )
   SetColor( cColor )
   /* the title goes as a "chip" over the top border, but WITHOUT filling it
    * up to nMax: it ate the right border and the top right corner of the
    * frame (it looked "shifted" and without a corner, e.g. in "Error"). */
   @ nT, nL + 2 SAY " " + Left( cTitle, nR - 6 ) + " "
   FOR i := 1 TO Len( aLin )
      @ nT + i + 1, nL + 2 SAY PadR( aLin[ i ], nMax )
   NEXT
   SetColor( UI_C_BOXSEL )
   nOkRow := nT + nB - 1
   nOkCol := nL + Int( nR / 2 ) - 2
   @ nOkRow, nOkCol SAY UI_OK_LBL
   SetColor( UI_C_DESKTOP )
   UiPaintEnd()
   /* S60: the box answers Enter, Space and Esc, and it also answers the MOUSE
    * on its OK button (the click of bp_win32.c never arrives through Inkey(),
    * it is polled through the hook that Main() installs). Before this the box
    * was blind to the mouse and Esc did nothing at all. */
   DO WHILE .T.
      nKey := Inkey( 0.05 )
      /* B2 (S4): the X of the window closes this box like Esc does. The close is
       * handed over AS Esc so the single cancel path of the box is the one that
       * runs: nothing is painted over the close and the request stays latched. */
      IF UiCloseAsk()
         nKey := K_ESC
      ENDIF
      IF nKey == 0
         aPt := UiClick()
         IF HB_ISARRAY( aPt ) .AND. UiOkClick( aPt[ 1 ], aPt[ 2 ], nOkRow, nOkCol )
            EXIT
         ENDIF
         /* right-click-esc (S1/S7): a plain right click closes the box, which
          * is what Esc and every other key already do here */
         IF UiRightClick()
            EXIT
         ENDIF
         LOOP
      ENDIF
      IF nKey == K_ENTER .OR. nKey == K_SPACE .OR. nKey == K_ESC
         EXIT
      ENDIF
   ENDDO
   RestScreen( nT, nL, nT + nB + 1, Min( nL + nR + 2, MaxCol() ), cSave )
   SetCursor( cOldCur )
RETURN NIL

FUNCTION UiErr( cText, cTitle )
   DEFAULT cTitle TO "Error"
   UiMsg( cText, cTitle, UI_C_ERR )
RETURN NIL

FUNCTION UiInfo( cText, cTitle )
   DEFAULT cTitle TO "hwBro"
   UiMsg( cText, cTitle, UI_C_BOX )
RETURN NIL

/* the click source of the modals (see s_bUiClick): {| | { row, column } | lAny }.
 * NIL removes it. */
FUNCTION UiSetClickHook( bBlock )
   s_bUiClick := bBlock
RETURN NIL

/* S10 of odd/tasks/commander-cleanup.md: the other two things the window hook
 * knows about a click - whether it was the second of a double click and how many
 * wheel notches arrived -. bp_ui.prg never calls the natives (it is linked by the
 * three headless banks), so Main() wires them with the same rule as the click. */
FUNCTION UiSetDblHook( bBlock )
   s_bUiDbl := bBlock
RETURN NIL

FUNCTION UiSetWheelHook( bBlock )
   s_bUiWheel := bBlock
RETURN NIL

/* right-click-esc (S5): the block that says whether a plain right click is
 * waiting; NIL removes it. Same shape as UiSetClickHook() above. */
FUNCTION UiSetRClickHook( bBlock )
   s_bUiRClick := bBlock
RETURN NIL

/* right-click-esc (S1/S5): .T. when one plain right click was consumed by this
 * call. A screen that leaves with Esc turns it into K_ESC on its idle pass, so
 * the CASE it already has stays the only place where Esc acts. .F. when there
 * is no hook (headless banks) or the answer is not a logical. */
FUNCTION UiRightClick()
   LOCAL l
   IF hb_IsNIL( s_bUiRClick ) .OR. ! hb_IsBlock( s_bUiRClick )
      RETURN .F.
   ENDIF
   l := Eval( s_bUiRClick )
RETURN ValType( l ) == "L" .AND. l

/* .F. when there is no hook (headless banks) or the answer is not a logical */
FUNCTION UiClickDbl()
   LOCAL x
   IF hb_IsNIL( s_bUiDbl )
      RETURN .F.
   ENDIF
   x := Eval( s_bUiDbl )
RETURN ( ValType( x ) == "L" .AND. x )

/* 0 when there is no hook or nothing arrived. The caller compares explicitly:
 * a number is never used as a condition in this program (trap 59). */
FUNCTION UiMouseWheel()
   LOCAL x
   IF hb_IsNIL( s_bUiWheel )
      RETURN 0
   ENDIF
   x := Eval( s_bUiWheel )
   IF ValType( x ) != "N"
      RETURN 0
   ENDIF
RETURN x

/* S100: the two halves of the clipboard of the inline editor: bPut receives the
 * text to publish (one argument) and bGet answers the text to paste ("" when
 * there is nothing). Main() wires them to W32ClipPut()/W32ClipGet(); with no
 * hook a copy is a no-op and a paste has nothing to paste. */
FUNCTION UiSetClipHook( bPut, bGet )
   s_bUiClipPut := bPut
   s_bUiClipGet := bGet
RETURN NIL

/* S100: the combos the window hook of bp_win32.c records because this driver
 * loses their modifier (AGENTS trap 58: Ctrl+C, Ctrl+X and Shift+Ins arrive
 * WITHOUT it). The block answers 1 = copy, 2 = paste, 3 = cut, 0 = none, and
 * draining it is what takes it. Main() wires it to
 * W32ClipKeyStep()/W32ClipKey(). S3 of recycle-bin-delete.md: Shift+Del is NOT
 * one of these codes any more - the hook has its own channel for it
 * (W32HardDelStep(), drained by the Harbour Commander), so this editor never
 * sees it and Shift+Del does not cut here. */
FUNCTION UiSetChordHook( bBlock )
   s_bUiChord := bBlock
RETURN NIL

/* S100: is SHIFT held right now? The arrows do not reach the window hook and
 * HB_GTI_KBDSHIFTS only reports the locks for them, so the live state has to
 * come from Main() (W32ShiftDown()). */
FUNCTION UiSetShiftHook( bBlock )
   s_bUiShift := bBlock
RETURN NIL

/* S13.7 (hc-file-search.md): the Alt chord source of the inline editor, the
 * same opt-in shape as the click hook. The block answers the pending chord -one
 * letter, already upper case- or "" when there is none, and ANSWERING takes it.
 * Main() wires it to HcAltChord(), which drains the ALT ring of the window hook:
 * in this driver an Alt+<letter> also arrives as a PLAIN letter, so without this
 * hook a chord typed inside a field would be written into the value. NIL
 * removes the hook. */
FUNCTION UiSetAltHook( bBlock )
   s_bUiAlt := bBlock
   s_cUiAltPend := ""
RETURN NIL

/* S13.7: the pending Alt chord, and answering it CONSUMES it (the caller of a
 * field editor takes it once and acts on it once). "" when nothing is pending
 * or when no hook is installed, so a bank without Main() sees exactly the
 * behaviour it had before. */
FUNCTION UiAltChord()
   LOCAL c := UiAltAsk()
   s_cUiAltPend := ""
RETURN c

/* S13.7: ask the installed hook for a chord and KEEP it pending, so the caller
 * of the field editor can take it with UiAltChord() after the editor closed. A
 * chord already pending is not asked for again (one keystroke, one chord). */
STATIC FUNCTION UiAltAsk()
   LOCAL x
   IF Len( s_cUiAltPend ) > 0
      RETURN s_cUiAltPend
   ENDIF
   IF hb_IsNIL( s_bUiAlt )
      RETURN ""
   ENDIF
   x := Eval( s_bUiAlt )
   IF ValType( x ) == "C" .AND. Len( x ) > 0
      s_cUiAltPend := x
   ENDIF
RETURN s_cUiAltPend

/* B2 (window-close.md S4): the close request of the window, in the same shape as
 * the click hook. The block answers .T. when the program has to end; Main()
 * wires it to BpCloseAsk(), which peeks the latch of the Windows hook instead of
 * forwarding WM_CLOSE to the driver (S3). NIL removes the hook. */
FUNCTION UiSetCloseHook( bBlock )
   s_bUiClose := bBlock
RETURN NIL

/* B2: has the window been closed? A modal calls this on EVERY pass of its wait
 * and leaves at once with its own cancel value, so a close is never swallowed by
 * a box: the box is cancelled (not painted over) and the request stays latched
 * for the screen that ends the program (S4, L9). With no hook - every headless
 * bank, and any build without the C extension - the answer is .F. */
FUNCTION UiCloseAsk()
   LOCAL l
   IF hb_IsNIL( s_bUiClose )
      RETURN .F.
   ENDIF
   l := Eval( s_bUiClose )
RETURN ValType( l ) == "L" .AND. l

/* the click of this pass as { row, column }, or NIL when there was none */
/* The click of this pass as { row, column }, or NIL when there was none.
 * PUBLIC (U2/U3) so a screen loop can poll it the same way the modals do: the
 * hook installed by Main() reads bp_win32.c and hands each click over once, so
 * only the loop that is running can see it. */
FUNCTION UiClick()
   LOCAL x
   IF hb_IsNIL( s_bUiClick )
      RETURN NIL
   ENDIF
   x := Eval( s_bUiClick )
   IF ! HB_ISARRAY( x ) .OR. Len( x ) < 2
      RETURN NIL
   ENDIF
RETURN x

/* What a click on the button row of UiConfirm() means (S45): 1 = Yes, 2 = No
 * and 0 = anywhere else, which leaves the box exactly as it is. nYesCol is the
 * first column of the Yes button and nNoCol that of the No one, both painted
 * by UiConfirmBtn(), so a click can never act on a button it did not touch. */
FUNCTION UiConfirmClick( nRow, nCol, nBtnRow, nYesCol, nNoCol )
   IF ValType( nRow ) != "N" .OR. ValType( nCol ) != "N" .OR. ;
      ValType( nBtnRow ) != "N" .OR. ValType( nYesCol ) != "N" .OR. ;
      ValType( nNoCol ) != "N"
      RETURN 0
   ENDIF
   IF nRow != nBtnRow
      RETURN 0
   ENDIF
   IF nCol >= nYesCol .AND. nCol < nYesCol + Len( UI_YES_LBL )
      RETURN 1
   ENDIF
   IF nCol >= nNoCol .AND. nCol < nNoCol + Len( UI_NO_LBL )
      RETURN 2
   ENDIF
RETURN 0

FUNCTION UiConfirm( cText, cTitle )
   LOCAL aLin, nMax, nT, nL, nB, nR, nKey, cSave, i, nBtn, nOfs, lYes := .T., cOldCur, nTextW
   LOCAL aPt, nHit
   DEFAULT cTitle TO "Confirm"
   /* the text may come in several lines separated by hb_eol(): it has to be
    * split before painting it, because a SAY with Chr(13)/Chr(10) inside does
    * not break the line in GTWVG: it paints the two control characters as
    * symbols ON THE SAME ROW (they looked like a "dash" and a block in front
    * of the text, e.g. in "Structure has been Edited! Discard Changes?").
    * UiMsg() already did it this way; UiConfirm did not. */
   nTextW := UiBoxTextW()
   aLin := hb_ATokens( cText, Chr( 10 ) )
   nMax := Len( cTitle ) + 4
   FOR i := 1 TO Len( aLin )
      aLin[ i ] := StrTran( aLin[ i ], Chr( 13 ), "" )
      nMax := Max( nMax, Len( aLin[ i ] ) )
   NEXT
   aLin := UiWrapLines( aLin, nTextW )
   nMax := Min( nMax, nTextW )
   /* height: 1 title row + N text lines + button row + 1 of air
    * and the frame; with a single line the box stays as it was (6 rows) */
   nB := Min( Len( aLin ) + 4, UiRows() - 3 )
   IF Len( aLin ) > nB - 4
      ASize( aLin, nB - 4 )
   ENDIF
   /* the Yes/No buttons take 16 columns, so the box has a minimum
    * width that contains them (otherwise, with a short text, the "No" was
    * painted over the right border) */
   nR := Min( Max( nMax + 4, 22 ), UiCols() - 4 )
   nT := UiFitRow( UiCenterRow( nB ), nB + 1 )
   nL := UiFitCol( UiCenterCol( nR ), nR + 2 )
   nBtn := nT + Len( aLin ) + 2
   nOfs := Max( 2, Int( ( nR - 16 ) / 2 ) )
   /* the system cursor stays HIDDEN while the box is on screen
    * (otherwise a bar blinks over the buttons: UiPaintEnd restores it). It is
    * hidden before the first UiPaintBegin. */
   cOldCur := SetCursor( 0 )
   cSave := SaveScreen( nT, nL, nT + nB + 1, Min( nL + nR + 2, MaxCol() ) )
   UiPaintBegin()
   UiShadow( nT, nL, nT + nB, nL + nR )
   UiFill( nT, nL, nT + nB, nL + nR, UI_C_BOX )
   UiFrame( nT, nL, nT + nB, nL + nR, UI_C_BOX, .T. )
   SetColor( UI_C_BOX )
   @ nT, nL + 2 SAY " " + Left( cTitle, nR - 6 ) + " "
   FOR i := 1 TO Len( aLin )
      @ nT + i + 1, nL + 2 SAY PadR( Left( aLin[ i ], nMax ), nMax )
   NEXT
   UiConfirmBtn( nBtn, nL + nOfs,      UI_YES_LBL, 3, lYes )
   UiConfirmBtn( nBtn, nL + nOfs + 10, UI_NO_LBL,  2, ! lYes )
   SetColor( UI_C_DESKTOP )
   UiPaintEnd()
   /* visible focus: Yes starts selected (Enter = Yes, as before). The
    * arrows / Tab move the focus and Enter activates the focused button; Y/N
    * are still the hot keys. A key that does nothing NO LONGER
    * cancels the box (any key used to return "No": inside a Pack or a
    * Zap that is dangerous to keep). */
   DO WHILE .T.
      nKey := Inkey( 0.05 )
      /* B2 (S4): the X of the window answers NO and leaves at once, the same
       * answer as Esc: it is handed over AS Esc so the cancel path of this box
       * runs once, and the latch is left alone for the loop that ends hwBro. */
      IF UiCloseAsk()
         nKey := K_ESC
      ENDIF
      IF nKey == 0
         /* right-click-esc (S1/S7): a plain right click answers NO, exactly as
          * Esc does in this box, and through the same one cancel path */
         IF UiRightClick()
            lYes := .F.
            EXIT
         ENDIF
         /* S45: this pass carries no key, so it may carry a CLICK on one of the
          * two buttons. The click of bp_win32.c never arrives through Inkey(),
          * it is polled here; anywhere else in the box it is ignored and the
          * box stays up with its focus where it was. */
         aPt := UiClick()
         nHit := 0
         IF HB_ISARRAY( aPt )
            nHit := UiConfirmClick( aPt[ 1 ], aPt[ 2 ], nBtn, nL + nOfs, nL + nOfs + 10 )
         ENDIF
         IF nHit == 1
            lYes := .T. ; EXIT
         ELSEIF nHit == 2
            lYes := .F. ; EXIT
         ENDIF
         LOOP
      ENDIF
      DO CASE
      CASE nKey == K_ESC
         /* Esc = No */
         lYes := .F. ; EXIT
      CASE nKey == K_ENTER .OR. nKey == K_SPACE
         EXIT
      CASE nKey == 121 .OR. nKey == 89        /* y / Y */
         lYes := .T. ; EXIT
      CASE nKey == 110 .OR. nKey == 78        /* n / N */
         lYes := .F. ; EXIT
      CASE nKey == K_LEFT .OR. nKey == K_RIGHT .OR. nKey == K_TAB .OR. ;
           nKey == K_SH_TAB .OR. nKey == K_UP .OR. nKey == K_DOWN
         /* only the two buttons are repainted (not the whole box: no flicker) */
         lYes := ! lYes
         UiPaintBegin()
         UiConfirmBtn( nBtn, nL + nOfs,      UI_YES_LBL, 3, lYes )
         UiConfirmBtn( nBtn, nL + nOfs + 10, UI_NO_LBL,  2, ! lYes )
         SetColor( UI_C_DESKTOP )
         UiPaintEnd()
      ENDCASE
   ENDDO
   RestScreen( nT, nL, nT + nB + 1, Min( nL + nR + 2, MaxCol() ), cSave )
   SetCursor( cOldCur )
RETURN lYes

/* confirmation box button: hot key in ANOTHER color and a different background
 * depending on whether it has the focus or not (so the user sees where the
 * cursor is). nHot = position (1..) of the hot key inside cLabel. */
STATIC PROCEDURE UiConfirmBtn( nRow, nCol, cLabel, nHot, lOn )
   SetColor( iif( lOn, UI_C_BOXSEL, UI_C_MENUKEY ) )
   @ nRow, nCol SAY cLabel
   SetColor( iif( lOn, UI_C_HOTSEL, UI_C_HOTON ) )
   @ nRow, nCol + nHot - 1 SAY SubStr( cLabel, nHot, 1 )
   SetColor( UI_C_DESKTOP )
RETURN NIL

/* ---------- forms in the style of the original (F2 Database) ---------- */

/* Form box: shadow + BRIGHT BLUE fill + double frame.
 * Measured on the original (e.g. FileSpec: rows 12..19, columns 17..63). */
FUNCTION UiFormBox( nT, nL, nB, nR )
   LOCAL i
   UiShadow( nT, nL, nB, nR )
   SetColor( UI_C_DLG )
   FOR i := nT TO nB
      @ i, nL SAY Space( nR - nL + 1 )
   NEXT
   UiFrame( nT, nL, nB, nR, UI_C_DLGBRD, .T. )
   SetColor( UI_C_DLG )
RETURN NIL

/* Editable field of a form. It returns the text or NIL when it is cancelled
 * with Esc.
 *
 * The pair is UI_C_LISTSEL, the SAME focus colour of the Commander's forms: the
 * field at rest is painted by the form with UI_C_DLGFIELD (= UI_C_FIELDBG, the
 * soft grey of an input), so opening it is what makes it YELLOW. That is the
 * one language of the whole program (odd/tasks/replace-form.md, skill
 * pantallas-de-formulario) and the reason every form of the DB manager looks
 * like the Commander's. */
FUNCTION UiFormEdit( nRow, nCol, nLen, cValue, lDigitsOnly )
RETURN UiLineEdit( nRow, nCol, nLen, cValue, lDigitsOnly, UI_C_LISTSEL )

/* ---------- S100: the clipboard and SHIFT of the inline editor ---------- */

/* Write cText to the clipboard of the system; .T. when it was written. With no
 * hook - every headless bank - a copy is a no-op, which is why this module
 * never calls the W32* helpers itself. */
FUNCTION UiClipPutText( cText )
   LOCAL lOk
   IF Len( cText ) == 0 .OR. hb_IsNIL( s_bUiClipPut )
      RETURN .F.
   ENDIF
   lOk := Eval( s_bUiClipPut, cText )
   /* anything that is not a logical "no" counts as written (the hook of Main()
    * answers the .T./.F. of W32ClipPut) */
RETURN ! ( ValType( lOk ) == "L" ) .OR. lOk

/* The text of the clipboard, always a string: "" when there is nothing to
 * paste or when no hook is installed. */
STATIC FUNCTION UiClipGetText()
   LOCAL cText
   IF hb_IsNIL( s_bUiClipGet )
      RETURN ""
   ENDIF
   cText := Eval( s_bUiClipGet )
RETURN iif( HB_ISCHAR( cText ), cText, "" )

/* The combo the window hook recorded, drained ONCE (that is what takes it from
 * the ring): 1 = copy, 2 = paste, 3 = cut, 0 = none. */
FUNCTION UiChordDrain()
   LOCAL n
   IF hb_IsNIL( s_bUiChord )
      RETURN 0
   ENDIF
   n := Eval( s_bUiChord )
RETURN iif( ValType( n ) == "N", n, 0 )

/* Is SHIFT held right now? The live state, from the hook Main() installs. */
STATIC FUNCTION UiShiftHeld()
   LOCAL l
   IF hb_IsNIL( s_bUiShift )
      RETURN .F.
   ENDIF
   l := Eval( s_bUiShift )
RETURN ValType( l ) == "L" .AND. l

/* S3 (browse-edit-mouse.md): is SHIFT held RIGHT NOW, for the stroke Inkey() has
 * just handed over? The caller passes what HcShiftState() answered and this
 * function ORs it with the LIVE state of the window hook (W32ShiftDown through
 * UiSetShiftHook). It is PUBLIC because the cell of the Browse edit of
 * bp_core.prg needs the same answer:
 *   - HB_GTI_KBDSHIFTS does report the SHIFT bit for the LETTERS (trap 62), but
 *     MEASURED: it does NOT report it for the ARROWS in this GTWVG, and the
 *     arrows do not reach the window hook either, so the live state is the only
 *     source that makes a Shift+arrow selection work at all. bp_hc.prg applies
 *     the very same rule (HcKeyShift) for the marks of the panels.
 * With no hook installed - every headless bank - it answers what the driver
 * reported, so nothing changes there. */
FUNCTION UiShiftLive( nShiftState )
   IF ValType( nShiftState ) == "N" .AND. ;
      hb_bitAnd( nShiftState, HB_GTI_KBD_SHIFT ) != 0
      RETURN .T.
   ENDIF
RETURN UiShiftHeld()

/* The CTRL bit of the stroke Inkey() has JUST delivered (AGENTS trap 37: it has
 * to be read immediately after). ALT disqualifies it, because on a Spanish
 * keyboard AltGr IS Ctrl+Alt and AltGr+V types a character (trap 38). */
STATIC FUNCTION UiCtrlHeld()
   LOCAL n := 0
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      n := hb_gtInfo( HB_GTI_KBDSHIFTS )
   RECOVER
      n := 0
   END SEQUENCE
   IF ValType( n ) != "N"
      RETURN .F.
   ENDIF
RETURN hb_bitAnd( n, HB_GTI_KBD_CTRL ) != 0 .AND. ;
       hb_bitAnd( n, HB_GTI_KBD_ALT ) == 0

/* The CLIPBOARD CHORD of the keystroke an inline editor has just read:
 * 1 = copy, 2 = paste, 3 = cut, 0 = none. The combos the window hook records
 * WIN over the copy Inkey() hands over for the same stroke (AGENTS trap 58:
 * Ctrl+C arrives as a bare 'c' and Shift+Ins as a bare Ins), so one keystroke is
 * one action and the caller DISCARDS whatever Inkey() delivered. Ctrl-Ins does
 * arrive with its own code and Ctrl-V arrives as 22 (the Ins code) with the
 * CTRL bit, which is the only thing that tells it apart from the mark.
 * PUBLIC because the Browse edit of bp_core.prg has its own inline editor (the
 * cell of the record browser, S4 of browse-edit-mouse.md) and the rule of the
 * chords cannot be written twice. */
FUNCTION UiClipChord( nKey )
   LOCAL nClip := UiChordDrain()
   IF nClip == 0 .AND. nKey != 0
      IF nKey == K_CTRL_INS
         nClip := 1
      ELSEIF nKey == K_INS .AND. UiCtrlHeld()
         nClip := 2
      ENDIF
   ENDIF
RETURN nClip

/* Remove the cells [ nFrom, nTo ) and KEEP the width of the field: the rest
 * shifts left and the tail is filled with blanks, like Del does.
 * cMask (S3/S4 of browse-edit-mouse.md) is the FIXED LAYOUT of a Date field:
 * there the cells are only BLANKED - shifting the text would break the format -
 * and the separators are re-stamped right away. */
FUNCTION UiSelDel( cBuf, nFrom, nTo, cMask )
   LOCAL nMax := Len( cBuf )
   DEFAULT cBuf TO "" ; DEFAULT cMask TO ""
   nFrom := Max( 0, Min( nMax, nFrom ) )
   nTo   := Max( nFrom, Min( nMax, nTo ) )
   IF Len( cMask ) > 0
      RETURN UiMaskStamp( Stuff( cBuf, nFrom + 1, nTo - nFrom, ;
                                 Replicate( " ", nTo - nFrom ) ), cMask )
   ENDIF
RETURN Left( cBuf, nFrom ) + SubStr( cBuf, nTo + 1 ) + Space( nTo - nFrom )

/* One clipboard action on the field: 1 = copy, 2 = paste, 3 = cut. It answers
 * { cBuf, nPos } when the buffer or the caret changed, and NIL when nothing
 * moved (a copy, a paste with an empty clipboard, a cut of nothing): the
 * caller then leaves the field exactly as it was. A cut only deletes when the
 * copy reached the clipboard, so a cut can never lose text. */
FUNCTION UiClipApply( nWhat, cBuf, nFrom, nTo, lDigitsOnly, lUpper, cAccept, cMask )
   LOCAL cText
   DO CASE
   CASE nWhat == 1
      UiClipPutText( UiSelText( cBuf, nFrom, nTo ) )
   CASE nWhat == 2
      cText := UiClipGetText()
      IF Len( cText ) > 0
         RETURN UiEditPaste( cBuf, nFrom, nTo, cText, lDigitsOnly, lUpper, ;
                             cAccept, cMask )
      ENDIF
   CASE nWhat == 3
      IF nTo > nFrom .AND. UiClipPutText( UiSelText( cBuf, nFrom, nTo ) )
         RETURN { UiSelDel( cBuf, nFrom, nTo, cMask ), nFrom }
      ENDIF
   ENDCASE
RETURN NIL

/* ---------- the date format of the engine (F6 GlobalSet) ---------- */

/* The fourteen pictures of the Date Format select (S2 of
 * odd/tasks/globalset-date-format.md), in the order of the original. They are
 * nothing but the PICTURES the engine accepts in SET DATE FORMAT, measured with
 * the T1 probe of that document: Harbour takes the fourteen verbatim and
 * reports them back untouched, so this list is the whole model - there is NO
 * STATIC holding the format in force (S3). */
FUNCTION UiDateFormats()
RETURN { "mm/dd/yy", ;
         "mm-dd-yy", ;
         "dd/mm/yy", ;
         "dd-mm-yy", ;
         "dd.mm.yy", ;
         "yy/mm/dd", ;
         "yy.mm.dd", ;
         "mm/dd/yyyy", ;
         "mm-dd-yyyy", ;
         "dd/mm/yyyy", ;
         "dd-mm-yyyy", ;
         "dd.mm.yyyy", ;
         "yyyy/mm/dd", ;
         "yyyy.mm.dd" }

/* The picture in force AS THE ENGINE RENDERS IT: that is exactly the string the
 * masks of the program use (bp_core.prg: cMask := DToC( Date() ); bp_ui.prg:
 * UiValToStr() for a D field and UiLineEdit( ..., cMask )), so reading it here
 * is reading the ONE source of truth (S3). */
FUNCTION UiDateFormat()
RETURN DToC( Date() )

/* The NAME of the picture in force, as the engine reports it (SET DATE FORMAT).
 * The menu row shows it because it is what the select lists, and it is read back
 * from the engine so a SET DATE FORMAT typed in the dot prompt shows up in the
 * screen instead of disagreeing with it. An engine that answers nothing falls
 * back to the rendering, so the row is never empty. */
FUNCTION UiDateFormatName()
   LOCAL c := Set( _SET_DATEFORMAT )
   IF ValType( c ) != "C"
      c := ""
   ENDIF
   c := AllTrim( c )
RETURN iif( Empty( c ), UiDateFormat(), c )

/* Position of a picture inside a list (the list of UiDateFormats() by default),
 * 0 when it is not there. WITHOUT case, because the engine reports the picture
 * in the case it was given to it and a dot prompt SET DATE FORMAT TO "DD/MM/YY"
 * still has to come back to its row. This is the index the select opens on. */
FUNCTION UiDateFormatIdx( cPic, aList )
   LOCAL i, cWant, c
   IF ValType( cPic ) != "C"
      cPic := ""
   ENDIF
   IF ! HB_ISARRAY( aList )
      aList := UiDateFormats()
   ENDIF
   cWant := Lower( AllTrim( cPic ) )
   IF Empty( cWant )
      RETURN 0
   ENDIF
   FOR i := 1 TO Len( aList )
      IF ValType( aList[ i ] ) != "C"
         LOOP
      ENDIF
      c := Lower( AllTrim( aList[ i ] ) )
      IF c == cWant
         RETURN i
      ENDIF
   NEXT
RETURN 0

/* Install a picture with the SET DATE FORMAT of the engine (S3: the state lives
 * in the engine, never in this module) and answer the name in force afterwards,
 * so a caller can report what really happened. Nothing is written when the
 * picture is empty. */
FUNCTION UiDateFormatSet( cPic )
   IF ValType( cPic ) == "C" .AND. ! Empty( AllTrim( cPic ) )
      Set( _SET_DATEFORMAT, AllTrim( cPic ) )
   ENDIF
RETURN UiDateFormatName()

/* The picture the session STARTS with: dd/mm/yyyy (S13 of
 * odd/tasks/globalset-date-format.md, the user's "El default debe ser
 * DD/MM/YYYY"). PURE: the string is the rule and UiDateFormatInit() installs it,
 * exactly as UiDateEpochBase() is the rule of the epoch.
 * Ten cells, so DToC( Date() ) is ten cells from the first screen on and the
 * edit buffer / mask of a Date cell coincide with the ten cells of its column
 * (S12), which is what makes the startup state consistent instead of a cell that
 * edits eight cells inside a column of ten. */
FUNCTION UiDateFormatDefault()
RETURN "dd/mm/yyyy"

/* Install the startup picture of UiDateFormatDefault() in the ENGINE (SET DATE
 * FORMAT) and answer the picture in force afterwards, so a caller reports what
 * really happened instead of what it asked for (the shape of
 * UiDateEpochInit()).
 * Same single-source rule as S3: there is NO STATIC holding the format here, the
 * engine keeps it, so Main() only calls this once at startup, next to the epoch,
 * and everything that reads DToC( Date() ) -the cell of the Browse edit, the
 * painted value of a D field, the mask of every date input- follows with no
 * second rule. The bank calls it too, which is why the rule is a function and
 * not a line of Main(). */
FUNCTION UiDateFormatInit()
RETURN UiDateFormatSet( UiDateFormatDefault() )

/* Width in CELLS of the COLUMN of a Date field: TEN, the width this program has
 * always given it (HEAD: "CASE aFld[ 2 ] == "D" ; nLen := 10").
 * S12 of odd/tasks/globalset-date-format.md: the picture does NOT decide this.
 * A Date field of a .DBF is 8 bytes and six of the fourteen pictures print TEN
 * cells, but a column that grows or shrinks with the format moves the whole grid
 * of the browse -headers, separators, click resolution and row painter- and
 * nobody asked for that. What the picture decides is the EDIT BUFFER, the MASK
 * and the PAINTED VALUE of the cell: UiDateValWidth().
 * The field length is taken only so a hypothetical Date field wider than ten
 * keeps its own width; a real one is always 8, so this answers 10.
 * PURE, and it lives here because no headless bank links bp_core.prg:
 * CoreColumnWidth() of bp_core.prg calls it and the bank asserts it (S124). */
FUNCTION UiDateColWidth( nLen )
   DEFAULT nLen TO 8
   IF ValType( nLen ) != "N" .OR. nLen < 1
      nLen := 8
   ENDIF
RETURN Max( nLen, 10 )

/* Width in CELLS of the VALUE of a Date field - the edit buffer and the mask of
 * its cell, and the segment the row painter highlights -: Max( field length,
 * Len( DToC( Date() ) ) ), that is, the picture in force (S8).
 * The FIELD keeps its 8 bytes for FieldPut() (the confirm path of the edit cell
 * converts the text with CToD()), and a field wider than the picture keeps its
 * own width, so this only ever GROWS the buffer. */
FUNCTION UiDateValWidth( nLen )
   DEFAULT nLen TO 8
   IF ValType( nLen ) != "N" .OR. nLen < 1
      nLen := 8
   ENDIF
RETURN Max( nLen, Len( DToC( Date() ) ) )

/* The EPOCH in force, READ FROM THE ENGINE (`SET EPOCH`, the base year of the
 * window of the two-digit years): Set( _SET_EPOCH ). No STATIC holds a copy -
 * the same single-source rule the date format follows (S3/S11) - so the F6 row
 * shows what the engine has, even if a SET EPOCH was typed in the dot prompt. */
FUNCTION UiDateEpoch()
RETURN Set( _SET_EPOCH )

/* PURE: is nYear a base the window can take? A whole number between 1 and 9999.
 * The engine itself accepts anything it is given, so this range is the rule of
 * the program (S11) and UiDateEpochSet() is what enforces it. */
FUNCTION UiDateEpochOk( nYear )
   IF ValType( nYear ) != "N"
      RETURN .F.
   ENDIF
   IF nYear != Int( nYear ) .OR. nYear < 1 .OR. nYear > 9999
      RETURN .F.
   ENDIF
RETURN .T.

/* PURE: the year typed in the F6 row, as a number, and 0 when it is not a valid
 * base -empty, a character that is not a digit, or a year outside 1..9999- so
 * the caller can report the rejection without touching the engine.
 * It does NOT use Val(), which stops at the first non-digit and would take
 * "1999abc" as 1999. */
FUNCTION UiDateEpochParse( cText )
   LOCAL c := "", i, n
   IF ValType( cText ) == "C"
      c := AllTrim( cText )
   ENDIF
   IF Empty( c )
      RETURN 0
   ENDIF
   FOR i := 1 TO Len( c )
      IF ! ( SubStr( c, i, 1 ) $ "0123456789" )
         RETURN 0
      ENDIF
   NEXT
   n := Val( c )
   IF ! UiDateEpochOk( n )
      RETURN 0
   ENDIF
RETURN n

/* Write the epoch in the ENGINE, and ONLY when it is a base UiDateEpochOk()
 * accepts: an invalid year changes NOTHING (S11). The answer is the epoch really
 * in force afterwards, so a caller reports the truth and not what it asked for. */
FUNCTION UiDateEpochSet( nYear )
   IF UiDateEpochOk( nYear )
      Set( _SET_EPOCH, Int( nYear ) )
   ENDIF
RETURN Set( _SET_EPOCH )

/* The base of the two-digit-year window: 1950, the conventional one (dBASE,
 * Clipper and FoxPro agree on it), so the years 50..99 are 19xx and 00..49 are
 * 20xx. PURE: the number is the rule and UiDateEpochInit() installs it. */
FUNCTION UiDateEpochBase()
RETURN 1950

/* Install the window of UiDateEpochBase() in the ENGINE (SET EPOCH) and answer
 * the epoch in force, so a caller can report what really happened.
 * Measured: this build starts with `_SET_EPOCH` = 1900, so every short-year
 * picture resolved "11/20/26" to 1926 - and the cell of the Browse edit would
 * write that 1926 into the .DBF. Main() calls this once at startup, next to the
 * other Set() calls; the bank calls it too (S124/S125), which is why the rule is
 * a function and not a line of Main(). */
FUNCTION UiDateEpochInit()
RETURN UiDateEpochSet( UiDateEpochBase() )

/* ---------- fixed layouts (masks) ---------- */

/* A FIXED LAYOUT is a string of the same width as the field whose NON digit
 * cells are SEPARATORS that the user can neither type over nor erase: the Date
 * fields use DToC( Date() ), so the mask follows SET DATE FORMAT ("MM/DD/YY"
 * in AMERICAN/BRITISH/JAPAN, "DD.MM.YY" in GERMAN, "DD-MM-YY" in ITALIAN…).
 * These five helpers are the ONLY copy of that rule: bp_core.prg (the cell of the
 * Browse edit) and UiEditKey()/UiEditPaste() all go through them. All the
 * positions are 0-based, like the caret of a field. */

/* is the position a FIXED cell? A position outside the mask is editable. */
FUNCTION UiMaskIsSep( cMask, nPos )
   DEFAULT cMask TO "" ; DEFAULT nPos TO 0
   IF ValType( nPos ) != "N" .OR. nPos < 0 .OR. nPos >= Len( cMask )
      RETURN .F.
   ENDIF
RETURN ! IsDigit( SubStr( cMask, nPos + 1, 1 ) )

/* next EDITABLE position after nPos (nPos = -1 -> the first one) */
FUNCTION UiMaskNext( nPos, cMask )
   DEFAULT nPos TO -1 ; DEFAULT cMask TO ""
   IF nPos < -1
      nPos := -1
   ENDIF
   DO WHILE nPos < Len( cMask ) - 1
      nPos++
      IF ! UiMaskIsSep( cMask, nPos )
         RETURN nPos
      ENDIF
   ENDDO
RETURN Len( cMask ) - 1

/* previous EDITABLE position before nPos */
FUNCTION UiMaskPrev( nPos, cMask )
   DEFAULT nPos TO 0 ; DEFAULT cMask TO ""
   DO WHILE nPos > 0
      nPos--
      IF ! UiMaskIsSep( cMask, nPos )
         RETURN nPos
      ENDIF
   ENDDO
RETURN 0

/* last EDITABLE position of the layout */
FUNCTION UiMaskLast( cMask )
   DEFAULT cMask TO ""
RETURN UiMaskPrev( Len( cMask ), cMask )

/* rewrite the separators of the layout into the buffer (they are never erased) */
FUNCTION UiMaskStamp( cBuf, cMask )
   LOCAL i
   DEFAULT cBuf TO "" ; DEFAULT cMask TO ""
   FOR i := 1 TO Min( Len( cMask ), Len( cBuf ) )
      IF ! IsDigit( SubStr( cMask, i, 1 ) )
         cBuf := Stuff( cBuf, i, 1, SubStr( cMask, i, 1 ) )
      ENDIF
   NEXT
RETURN cBuf

/* Is the printable character cCh one this field accepts? lDigitsOnly is the
 * historic switch (dialog fields) and cAccept is the OPTIONAL set of the caller
 * (S3 of browse-edit-mouse.md): "" means "every printable character", which is
 * what every field did before cAccept existed. The comparison is case
 * INSENSITIVE, because a Logical field is typed T/F or y/n. */
STATIC FUNCTION UiAcceptOk( cCh, lDigitsOnly, cAccept )
   DEFAULT lDigitsOnly TO .F. ; DEFAULT cAccept TO ""
   IF Len( cCh ) == 0
      RETURN .F.
   ENDIF
   IF lDigitsOnly .AND. ! IsDigit( cCh )
      RETURN .F.
   ENDIF
   IF Len( cAccept ) == 0
      RETURN .T.
   ENDIF
RETURN Upper( cCh ) $ Upper( cAccept )

/* ---------- line editing ---------- */

/* One keystroke of the inline editor, WITHOUT painting: the whole editing rule
 * of UiLineEdit(), BpIdxTextEdit() and the cell of the Browse edit in one place,
 * so the copies cannot drift apart again (they had, and neither of them could
 * insert).
 *   cBuf        field buffer, exactly as wide as the field
 *   nPos        0-based cursor position
 *   nKey        the Inkey() code
 *   lInsert     insert mode (Ins toggles it)
 *   lDigitsOnly only digits are accepted when typing
 *   lUpper      typed characters are turned into upper case
 *   lTabNav     Tab / Shift-Tab confirm the field (dialog forms)
 *   lShift      SHIFT is held (S100); the optional four last arguments are the
 *   nSelFrom    SELECTION of the field, as { from, to, anchor }: the selected
 *   nSelTo      cells are [ from, to ) and the anchor is the end that does NOT
 *   nSelAnchor  move, while nPos (the caret) is the end that moves
 *   cAccept     OPTIONAL set of characters a printable key may type, case
 *               INSENSITIVE ("0123456789.-+" for a numeric field). "" is the
 *               behaviour of every caller that existed before: any printable
 *   cMask       OPTIONAL fixed layout (DToC( Date() )). "" = no mask. With a
 *               mask the separators can be neither typed over nor erased, the
 *               caret SKIPS them, Del/Backspace blank the cell without shifting
 *               (shifting would break the layout) and the field confirms itself
 *               when the LAST EDITABLE cell is filled.
 *   lHighBytes  OPTIONAL and .F. by default: does this field TYPE the bytes
 *               >= 128? The historic printable range is 32..126, and widening it
 *               for EVERY caller let a byte >= 128 into every dialog field and
 *               DELETED THE SELECTION first - on a Spanish keyboard the ñ and
 *               the accented vowels arrive as those bytes, so `Copy to:`, the
 *               File search form and the rest started typing them (measured).
 *               Only the cell of the Browse edit asks for the wider range, and it
 *               does because at baseline it already typed those bytes. cAccept
 *               can only NARROW the range, never open it, and K_CTRL_BS (127) is
 *               not a character in either of them.
 * returns { cBuf, nPos, lInsert, nPaint, cAction, nFrom, nTo, nAnchor }
 *   nPaint : 0 = only the cursor moved, 1 = repaint the whole field, 2 = one cell
 *   cAction: "" = keep editing, "ENTER" = accept and leave, "ESC" = cancel
 * S100 adds the LAST THREE values and nothing else: the five of today keep
 * their meaning, so every existing caller - and every S71 assertion - reads
 * exactly what it read before. A collapsed selection is from == to == nPos.
 * The field NEVER grows: insert mode pushes the text right and drops what
 * falls off the end. This Harbour exposes no cursor-size GT info, so the mode
 * cannot be shown by the caret itself: the caller paints the cell under the
 * cursor as a BLOCK (UiEditFieldPaint) while lInsert is true. */
FUNCTION UiEditKey( cBuf, nPos, nKey, lInsert, lDigitsOnly, lUpper, lTabNav, ;
                    lShift, nSelFrom, nSelTo, nSelAnchor, cAccept, cMask, ;
                    lHighBytes )
   LOCAL cCh, nPaint := 0, cAction := ""
   LOCAL nFrom, nTo, nAnchor, nNew, nMax, lSel := .F., lMove := .F., lDelSel := .F.
   LOCAL lMask, nLast, lPrint
   DEFAULT cBuf TO "" ; DEFAULT nPos TO 0 ; DEFAULT nKey TO 0
   DEFAULT lInsert TO .F. ; DEFAULT lDigitsOnly TO .F. ; DEFAULT lUpper TO .F.
   DEFAULT lTabNav TO .F. ; DEFAULT lShift TO .F.
   DEFAULT cAccept TO "" ; DEFAULT cMask TO "" ; DEFAULT lHighBytes TO .F.
   lMask := Len( cMask ) > 0
   /* The PRINTABLE range of the field: 32..126 -the historic one, byte for byte
    * the one every dialog field had- unless the caller OPTS IN to the bytes
    * >= 128 with the last argument. K_CTRL_BS (127) is excluded from both: it is
    * a control code that happens to sit right above the printable range. */
   lPrint := nKey >= 32 .AND. ;
             nKey <= iif( lHighBytes, 255, 126 ) .AND. nKey != K_CTRL_BS
   /* S100: the incoming selection is normalised here, so a caller that hands
    * over a stale or crossed pair cannot break the rule below. */
   nMax := Len( cBuf ) - 1
   nPos := Max( 0, Min( Max( 0, nMax ), nPos ) )
   IF lMask .AND. UiMaskIsSep( cMask, nPos )
      /* a masked field never leaves the caret on a separator */
      nPos := Max( 0, Min( Max( 0, nMax ), UiMaskNext( nPos - 1, cMask ) ) )
   ENDIF
   nFrom   := iif( ValType( nSelFrom ) == "N", nSelFrom, nPos )
   nTo     := iif( ValType( nSelTo ) == "N", nSelTo, nPos )
   nAnchor := iif( ValType( nSelAnchor ) == "N", nSelAnchor, nPos )
   IF nFrom > nTo
      nNew := nFrom ; nFrom := nTo ; nTo := nNew
   ENDIF
   nFrom   := Max( 0, Min( Max( 0, nMax ), nFrom ) )
   nTo     := Max( 0, Min( Max( 0, nMax ), nTo ) )
   nAnchor := Max( 0, Min( Max( 0, nMax ), nAnchor ) )
   lSel := nTo > nFrom
   IF ! lSel
      /* no selection: the anchor sits on the caret */
      nAnchor := nPos
   ENDIF
   /* S100: Backspace, Del and a printable character work on the SELECTION
    * FIRST: they delete it and the caret ends where the deletion ended, so
    * typing right after replaces what was selected. A character the field
    * refuses (lDigitsOnly, or the cAccept set) does not delete anything: the
    * key does not act at all. */
   IF lSel .AND. ( nKey == K_BS .OR. nKey == K_DEL .OR. ;
      ( lPrint .AND. UiAcceptOk( Chr( nKey ), lDigitsOnly, cAccept ) ) )
      cBuf := UiSelDel( cBuf, nFrom, nTo, cMask )
      nPos := nFrom
      nFrom := nPos ; nTo := nPos ; nAnchor := nPos
      lSel := .F.
      lDelSel := .T.
      nPaint := 1
      IF nKey == K_BS .OR. nKey == K_DEL
         /* for these two the deletion IS the whole action */
         nKey := 0
      ENDIF
   ENDIF
   DO CASE
   CASE nKey == K_ENTER .OR. nKey == K_CTRL_END
      /* accept and leave; Ctrl-End is the classic READ (same effect) */
      cAction := "ENTER"
   CASE nKey == K_ESC
      cAction := "ESC"
   CASE lTabNav .AND. nKey == K_TAB
      /* S15: Tab and Shift+Tab CONFIRM the field and move the focus, which is
       * what a form of a dialog is expected to do. Only when the caller asks
       * for it (lTabNav): everywhere else Tab keeps doing nothing inside a
       * field, which is what the rest of the program assumes. */
      cAction := "TAB"
   CASE lTabNav .AND. nKey == K_SH_TAB
      cAction := "SH_TAB"
   CASE nKey == K_INS
      /* the toggle: per field, it starts in OVERWRITE (the old behaviour) */
      lInsert := ! lInsert
   CASE nKey == K_BS
      IF lMask
         /* FIXED LAYOUT: the cell to the left is BLANKED and nothing shifts
          * (shifting would break the format), and the caret skips the
          * separators, which can never be erased. */
         nNew := UiMaskPrev( nPos, cMask )
         IF nNew < nPos .AND. Len( cBuf ) > 0
            nPos := nNew
            cBuf := Stuff( cBuf, nPos + 1, 1, " " )
            nPaint := 1
         ENDIF
      ELSEIF nPos > 0
         nPos--
         IF lInsert
            /* insert mode: the character is removed and the rest shifts left
             * (a hole would be wrong in insert mode) */
            cBuf := Left( cBuf, nPos ) + SubStr( cBuf, nPos + 2 ) + " "
            nPaint := 1
         ELSE
            /* overwrite mode: the classic behaviour, it only leaves a blank */
            cBuf := Stuff( cBuf, nPos + 1, 1, " " )
            nPaint := 2
         ENDIF
      ENDIF
   CASE nKey == K_DEL
      IF lMask
         /* FIXED LAYOUT: blank the cell under the caret, without shifting */
         IF Len( cBuf ) > 0
            cBuf := Stuff( cBuf, Min( nPos, Len( cBuf ) - 1 ) + 1, 1, " " )
            nPaint := 1
         ENDIF
      ELSE
         /* Del = deletes the character under the cursor and shifts the rest to
          * the left (with a space at the end), like the classic editor */
         cBuf := Left( cBuf, nPos ) + SubStr( cBuf, nPos + 2 ) + " "
         nPaint := 1
      ENDIF
   CASE nKey == K_LEFT
      lMove := .T.
      nNew := iif( lMask, UiMaskPrev( nPos, cMask ), Max( 0, nPos - 1 ) )
   CASE nKey == K_RIGHT
      lMove := .T.
      nNew := iif( lMask, UiMaskNext( nPos, cMask ), ;
                   Max( 0, Min( Len( cBuf ) - 1, nPos + 1 ) ) )
   CASE nKey == K_HOME
      lMove := .T.
      nNew := iif( lMask, UiMaskNext( -1, cMask ), 0 )
   CASE nKey == K_END
      /* next to the LAST TYPED CHARACTER, not at the right border of the
       * field: the buffer is padded to the field width, so the end of the
       * buffer is usually far right of the text (reported in the `Copy to:`
       * box of the file manager, whose field is 96 cells wide). It is the same
       * cell the field opens the caret in, so End then typing appends.
       * With a mask the end is the last EDITABLE cell of the layout. */
      lMove := .T.
      nNew := iif( lMask, UiMaskLast( cMask ), ;
                   Max( 0, Min( Len( RTrim( cBuf ) ), Len( cBuf ) - 1 ) ) )
   CASE nKey == K_CTRL_LEFT
      lMove := .T.
      /* one WORD or one SYMBOL back (UiWordLeft); a masked field only stops on
       * its editable cells, so there it walks them one by one */
      nNew := iif( lMask, UiMaskPrev( nPos, cMask ), UiWordLeft( cBuf, nPos ) )
   CASE nKey == K_CTRL_RIGHT
      lMove := .T.
      nNew := iif( lMask, UiMaskNext( nPos, cMask ), UiWordRight( cBuf, nPos ) )
   CASE lPrint
      IF UiAcceptOk( Chr( nKey ), lDigitsOnly, cAccept )
         /* lUpper: everything typed is turned into upper case on the fly
          * (used by the field name of the structure editor) */
         cCh := iif( lUpper, Upper( Chr( nKey ) ), Chr( nKey ) )
         IF lMask
            /* FIXED LAYOUT: the character goes in the cell under the caret and
             * NOTHING shifts; the separators are stamped back at once. */
            IF Len( cBuf ) > 0
               cBuf := Stuff( cBuf, Min( nPos, Len( cBuf ) - 1 ) + 1, 1, cCh )
            ENDIF
            nPaint := 1
            nLast := UiMaskLast( cMask )
            IF nPos >= Min( nLast, Len( cBuf ) - 1 )
               /* the last editable cell is filled: it confirms itself */
               cAction := "ENTER"
            ELSE
               nPos := UiMaskNext( nPos, cMask )
            ENDIF
         ELSE
            IF lInsert
               /* insert: the text from the cursor on shifts one cell right and
                * what falls off the end is lost (the field never grows) */
               cBuf := Left( Left( cBuf, nPos ) + cCh + SubStr( cBuf, nPos + 1 ), Len( cBuf ) )
               nPaint := 1
            ELSE
               cBuf := Stuff( cBuf, nPos + 1, 1, cCh )
               /* when the selection was just deleted the text MOVED, so the
                * whole field is repainted and not only this cell */
               nPaint := iif( lDelSel, 1, 2 )
            ENDIF
            IF nPos < Len( cBuf ) - 1
               nPos++
            ELSE
               /* the field is full: it confirms itself (classic GET with
                * SET CONFIRM OFF), no need to press Enter */
               cAction := "ENTER"
            ENDIF
         ENDIF
         /* the typed character leaves the caret on a single point, so a
          * collapsed selection is ALWAYS from == to == caret */
         nFrom := nPos ; nTo := nPos ; nAnchor := nPos
      ENDIF
   ENDCASE
   /* S100: the movement, applied AFTER the rule above so a key has exactly
    * one effect. With SHIFT the caret moves and the anchor stays, so the
    * selection covers what the caret crossed; without SHIFT the selection
    * collapses (from == to == caret), which is what any editor does. */
   IF lMove
      IF lShift
         IF ! lSel
            /* the extension starts on the cell the caret was on */
            nAnchor := nPos
         ENDIF
         nPos := nNew
         nFrom := Min( nAnchor, nPos )
         nTo   := Max( nAnchor, nPos )
      ELSE
         nPos := nNew
         nFrom := nPos ; nTo := nPos ; nAnchor := nPos
      ENDIF
   ENDIF
   /* S101: with NO selection the three points ARE the caret. A key that moved
    * it without being a movement (Backspace, Del, a typed character) would
    * otherwise leave the old anchor behind and the next Shift+arrow would
    * extend from the wrong cell. */
   IF nTo <= nFrom
      nFrom := nPos ; nTo := nPos ; nAnchor := nPos
   ENDIF
   IF lMask
      /* the separators are FIXED: whatever the key did, they are re-stamped
       * (the buffer is the same width as the layout, so this cannot grow it) */
      cBuf := UiMaskStamp( cBuf, cMask )
   ENDIF
RETURN { cBuf, nPos, lInsert, nPaint, cAction, nFrom, nTo, nAnchor }

/* ---------- word movement for the inline editor ---------- */

/* A WORD is a run of letters, digits and underscore. Every other cell of the
 * field - a blank or a symbol - is its OWN stop, so Ctrl-Right/Ctrl-Left walk a
 * path like C:\xampp\hwbro.exe one piece at a time: C | : | \ | xampp | \ |
 * hwbro | . | exe. Bytes >= 128 count as word characters, so an accented
 * letter does not split the word it belongs to. */
FUNCTION UiIsWordChar( cCh )
   LOCAL n
   IF Len( cCh ) == 0
      RETURN .F.
   ENDIF
   n := Asc( cCh )
RETURN ( n >= 48 .AND. n <= 57 ) .OR. ( n >= 65 .AND. n <= 90 ) .OR. ;
       ( n >= 97 .AND. n <= 122 ) .OR. n == 95 .OR. n >= 128

/* Ctrl-Left: the first cell of the previous word, or the symbol just before
 * the caret. A run of blanks is crossed in one step. It never walks out of the
 * field (0 is the left border). */
FUNCTION UiWordLeft( cBuf, nPos )
   LOCAL n, nMax
   DEFAULT cBuf TO "" ; DEFAULT nPos TO 0
   nMax := Len( cBuf ) - 1
   IF nMax < 0
      RETURN 0
   ENDIF
   n := Max( 0, Min( nPos, nMax ) )
   IF n == 0
      RETURN 0
   ENDIF
   n--
   DO WHILE n > 0 .AND. SubStr( cBuf, n + 1, 1 ) == " "
      n--
   ENDDO
   IF UiIsWordChar( SubStr( cBuf, n + 1, 1 ) )
      /* SubStr( cBuf, n, 1 ) is the cell just before the caret at n (1-based
       * n), so the loop walks back while that cell belongs to the same word */
      DO WHILE n > 0 .AND. UiIsWordChar( SubStr( cBuf, n, 1 ) )
         n--
      ENDDO
   ENDIF
RETURN n

/* Ctrl-Right: the LAST cell of the current word, or the next symbol, and a run
 * of blanks is crossed in one step. It never walks out of the field (Len()-1
 * is the right border). */
FUNCTION UiWordRight( cBuf, nPos )
   LOCAL n, nMax
   DEFAULT cBuf TO "" ; DEFAULT nPos TO 0
   nMax := Len( cBuf ) - 1
   IF nMax < 0
      RETURN 0
   ENDIF
   n := Max( 0, Min( nPos, nMax ) )
   IF n == nMax
      RETURN nMax
   ENDIF
   n++
   DO WHILE n < nMax .AND. SubStr( cBuf, n + 1, 1 ) == " "
      n++
   ENDDO
   IF UiIsWordChar( SubStr( cBuf, n + 1, 1 ) )
      DO WHILE n < nMax .AND. UiIsWordChar( SubStr( cBuf, n + 2, 1 ) )
         n++
      ENDDO
   ENDIF
RETURN n

/* ---------- S100: the selection and the clipboard of a field ---------- */

/* The text covered by the selection [ nFrom, nTo ). A collapsed selection (or
 * one that falls outside the buffer) answers "", which is what makes a copy
 * with nothing selected a no-op. The cells are returned AS THEY ARE, trailing
 * blanks included: the user selected them. */
FUNCTION UiSelText( cBuf, nFrom, nTo )
   LOCAL nMax, nA, nB
   DEFAULT cBuf TO "" ; DEFAULT nFrom TO 0 ; DEFAULT nTo TO 0
   nMax := Len( cBuf )
   nA := Max( 0, Min( nMax, Min( nFrom, nTo ) ) )
   nB := Max( 0, Min( nMax, Max( nFrom, nTo ) ) )
   IF nB <= nA
      RETURN ""
   ENDIF
RETURN SubStr( cBuf, nA + 1, nB - nA )

/* Replace the selection [ nFrom, nTo ) with cText, or insert it on the caret
 * when there is no selection (from == to). It answers { cBuf, nPos } with
 * nPos just after the pasted text and NEVER outside the buffer.
 *
 * The text is filtered with the SAME rules typing obeys - lDigitsOnly keeps
 * only digits and lUpper turns everything into upper case - and folded to one
 * line, because a field has one line and a path copied from Explorer can come
 * with a line break at the end. The field NEVER grows: what falls off the end
 * is lost, exactly like in insert mode.
 * D1: the RANGE of the typed keys is NOT here on purpose. Widening the printable
 * range of UiEditKey() to 32..255 let a byte >= 128 into every dialog field; a
 * PASTE never had a range limit - it only ever filtered digits and the cAccept
 * set - so an accented letter pasted into a dialog keeps going in exactly as it
 * did before, and gating it here would be a second, different rule. The set of
 * accepted characters is what changes the paste, and only a caller that passes
 * one (the cell of the Browse edit) narrows it. */
FUNCTION UiEditPaste( cBuf, nFrom, nTo, cText, lDigitsOnly, lUpper, cAccept, cMask )
   LOCAL nMax, nA, nB, cTxt, cKeep, i, cCh, nLast
   DEFAULT cBuf TO "" ; DEFAULT nFrom TO 0 ; DEFAULT nTo TO 0
   DEFAULT cText TO "" ; DEFAULT lDigitsOnly TO .F. ; DEFAULT lUpper TO .F.
   DEFAULT cAccept TO "" ; DEFAULT cMask TO ""
   nMax := Len( cBuf )
   nA := Max( 0, Min( nMax, Min( nFrom, nTo ) ) )
   nB := Max( nA, Min( nMax, Max( nFrom, nTo ) ) )
   cTxt := StrTran( StrTran( StrTran( cText, Chr( 13 ), "" ), Chr( 10 ), "" ), Chr( 9 ), " " )
   IF lUpper
      cTxt := Upper( cTxt )
   ENDIF
   /* the SAME filter typing obeys: lDigitsOnly and/or the cAccept set of the
    * caller. With both at their default every printable character goes in,
    * which is what every caller that existed before expected. */
   cKeep := ""
   FOR i := 1 TO Len( cTxt )
      cCh := SubStr( cTxt, i, 1 )
      IF UiAcceptOk( cCh, lDigitsOnly, cAccept )
         cKeep += cCh
      ENDIF
   NEXT
   cTxt := cKeep
   IF Len( cMask ) > 0
      /* FIXED LAYOUT: the accepted characters are TYPED one by one on the
       * editable cells from the caret on and NOTHING shifts; the separators are
       * re-stamped and what does not fit in the layout is lost. */
      IF nB > nA
         cBuf := UiSelDel( cBuf, nA, nB, cMask )
      ENDIF
      IF nA >= nMax .OR. UiMaskIsSep( cMask, nA )
         nA := UiMaskNext( nA - 1, cMask )
      ENDIF
      nLast := UiMaskLast( cMask )
      i := 1
      DO WHILE i <= Len( cTxt ) .AND. nA <= nLast .AND. nA < nMax
         cBuf := Stuff( cBuf, nA + 1, 1, SubStr( cTxt, i, 1 ) )
         i++
         IF nA < Min( nLast, nMax - 1 )
            nA := UiMaskNext( nA, cMask )
         ELSE
            nA := Min( nLast, nMax - 1 )
            i := Len( cTxt ) + 1
         ENDIF
      ENDDO
      RETURN { UiMaskStamp( cBuf, cMask ), Max( 0, Min( nMax - 1, nA ) ) }
   ENDIF
   cBuf := Left( Left( cBuf, nA ) + cTxt + SubStr( cBuf, nB + 1 ), nMax )
   IF Len( cBuf ) < nMax
      /* pasting nothing over a selection shortens the text: the width of the
       * field is what the buffer has to keep */
      cBuf := PadR( cBuf, nMax )
   ENDIF
   nA := Min( nA + Len( cTxt ), nMax - 1 )
RETURN { cBuf, Max( 0, nA ) }

/* The two halves of a Harbour colour pair swapped around the "/":
 * "N/W" -> "W/N", "N/G" -> "G/N", "W+/B" -> "B/W+" (the + travels with its
 * own half). A pair without "/", or an empty one, comes back untouched.
 * It paints the cell under the cursor as a BLOCK: this Harbour build has no
 * cursor-shape GT info (HB_GTI_SETCURSORSIZE does not exist and the gtwvg
 * contrib does not handle it), so the difference between INSERT and OVERWRITE
 * has to be painted, like CoreDrawEditCell does in the Browse edit. */
FUNCTION UiSwapColor( cPair )
   LOCAL nAt
   DEFAULT cPair TO ""
   IF Len( cPair ) == 0
      RETURN cPair
   ENDIF
   nAt := At( "/", cPair )
   IF nAt == 0
      RETURN cPair
   ENDIF
RETURN SubStr( cPair, nAt + 1 ) + "/" + Left( cPair, nAt - 1 )

/* Paint a whole inline field and, when lBlock is true, repaint the single cell
 * under the cursor with the colours INVERTED (UiSwapColor): that block is the
 * visible mark of INSERT mode, and the caller keeps the system caret hidden
 * while it shows. nCursor is 0-based and is clamped into the field, so the
 * block can never run past its right edge. It opens its own painting block
 * (one REFRESH), so the field is never left half painted.
 *
 * S100: the OPTIONAL last two arguments are the selection { nSelFrom, nSelTo }
 * and it is painted with THE SAME language - the field pair swapped
 * (UiSwapColor) - so no new colour is invented and the highlight reads as "this
 * is the selected text" everywhere in the program. The caret stays visible on
 * top of it: outside the selection it is the usual swapped block, and INSIDE it
 * it is a hole of the normal colours, because two swapped cells on top of each
 * other would hide the caret completely. */
PROCEDURE UiEditFieldPaint( nRow, nCol, cBuf, cColor, nCursor, lBlock, nSelFrom, nSelTo )
   LOCAL nPos := nCursor, nLen, nFrom, nTo, nSwap
   DEFAULT cBuf TO "" ; DEFAULT cColor TO UI_C_INPUT
   DEFAULT nPos TO 0 ; DEFAULT lBlock TO .F.
   nLen := Len( cBuf )
   nPos := Max( 0, Min( nLen - 1, nPos ) )
   nFrom := iif( ValType( nSelFrom ) == "N", nSelFrom, nPos )
   nTo   := iif( ValType( nSelTo ) == "N", nSelTo, nPos )
   nSwap := nFrom ; nFrom := Min( nSwap, nTo ) ; nTo := Max( nSwap, nTo )
   nFrom := Max( 0, Min( nLen, nFrom ) )
   nTo   := Max( 0, Min( nLen, nTo ) )
   UiPaintBegin()
   SetColor( cColor )
   @ nRow, nCol SAY cBuf
   IF nTo > nFrom
      SetColor( UiSwapColor( cColor ) )
      @ nRow, nCol + nFrom SAY SubStr( cBuf, nFrom + 1, nTo - nFrom )
   ENDIF
   IF lBlock .AND. nLen > 0
      IF nPos >= nFrom .AND. nPos < nTo
         /* the caret inside the selection: a HOLE, or it would disappear */
         SetColor( cColor )
      ELSE
         SetColor( UiSwapColor( cColor ) )
      ENDIF
      @ nRow, nCol + nPos SAY SubStr( cBuf, nPos + 1, 1 )
   ENDIF
   SetColor( UI_C_DESKTOP )
   UiPaintEnd()
RETURN

/* cMask (9th, optional) is a FIXED LAYOUT of the same width as the field (see
 * UiMaskStamp()): the non digit cells are separators the user can neither type
 * over nor erase and the caret skips them. The Date fields of the Replace form
 * pass DToC( Date() ), so the picture follows SET DATE FORMAT (F6 GlobalSet).
 * cAccept (10th, optional) is the set of characters a printable key may enter.
 * Both default to "", and with them empty the field behaves EXACTLY as before
 * (the three headless banks pin that: S100/S115). */
FUNCTION UiLineEdit( nRow, nCol, nLen, cValue, lDigitsOnly, cColor, lUpper, lTabNav, ;
                    cMask, cAccept, lSelAll, lNoAltClose )
   LOCAL cBuf, nPos, nKey, cOldCur, lDone := .F., aKey, lCancel := .F.
   LOCAL lInsert := .F., lShift := .F., nSelFrom, nSelTo, nAnchor
   LOCAL aPt, nClip, aRes
   DEFAULT cValue TO "" ; DEFAULT lDigitsOnly TO .F.
   DEFAULT cColor TO UI_C_INPUT ; DEFAULT lUpper TO .F.
   DEFAULT lTabNav TO .F. ; DEFAULT cMask TO "" ; DEFAULT cAccept TO ""
   DEFAULT lSelAll TO .F. ; DEFAULT lNoAltClose TO .F.
   IF Len( cMask ) > 0
      /* the separators of the layout are stamped in, and the caret starts on
       * the first EDITABLE cell: a masked field never rests on a separator */
      cBuf := UiMaskStamp( PadR( Left( cValue, nLen ), nLen ), cMask )
      nPos := Min( UiMaskNext( -1, cMask ), nLen - 1 )
   ELSE
      cBuf := PadR( Left( cValue, nLen ), nLen )
      nPos := Min( Len( RTrim( cValue ) ), nLen - 1 )
   ENDIF
   /* S100: the selection starts collapsed on the caret */
   nSelFrom := nPos ; nSelTo := nPos ; nAnchor := nPos
   /* S3 of odd/tasks/commander-cleanup.md: a SEEDED value can open WHOLE
    * SELECTED, so the first character typed REPLACES it instead of being
    * appended - the mask proposed by `Select group` is useless if typing
    * `*.prg` yields `*.**.prg`. Opt-in, and only for an UNMASKED field: a mask
    * has fixed separators and a selection across them is not a value. With the
    * default (.F.) the field opens exactly as before, which is what every other
    * caller relies on (S100/S115). */
   IF lSelAll .AND. Len( cMask ) == 0
      nSelFrom := 0
      nSelTo   := Max( 0, Len( RTrim( cValue ) ) - 1 )
      nAnchor  := 0
      nPos     := nSelTo
   ENDIF
   cOldCur := SetCursor( 1 )
   s_nUiEditExit := K_ENTER
   /* S100: a chord recorded BEFORE the field opened (while a box that does not
    * drain the clipboard ring was modal) belongs to nobody: it is dropped here
    * so it cannot copy, cut or paste inside a field the user just opened */
   UiChordDrain()
   /* S13.7: the same for an Alt chord nobody took (it belongs to the screen
    * that asked for it, not to the field this one is opening) */
   s_cUiAltPend := ""
   /* The field is repainted WHOLE whenever the buffer, the cursor, the mode or
    * the selection changes (one block = one REFRESH), so no cell is ever left
    * stale: with the block cursor there is no single changed cell to patch any
    * more. In INSERT mode the cell under the cursor is the inverted one and the
    * system caret is hidden, so the two modes LOOK different. */
   UiEditFieldPaint( nRow, nCol, cBuf, cColor, nPos, lInsert, nSelFrom, nSelTo )
   DO WHILE ! lDone
      DevPos( nRow, nCol + nPos )
      /* S100: 50 ms instead of a blocking Inkey() so the CLICK and the combos
       * of the window hook can be polled; nothing is painted unless something
       * really changed, so the field does not flicker. */
      nKey := Inkey( 0.05 )
      /* B2 (S4): the X of the window cancels the field. It is handed over AS Esc
       * so the field leaves through its ONE cancel path: s_nUiEditExit becomes
       * K_ESC and the caller gets NIL, exactly like pressing Esc. The latch is
       * not taken, so the loop that ends hwBro still sees the request. */
      IF UiCloseAsk()
         nKey := K_ESC
      ENDIF
      /* right-click-esc (S1/S7): a plain right click cancels the FIELD and the
       * caller gets NIL, exactly as with Esc: it is handed over AS K_ESC so the
       * one cancel path of this editor runs (s_nUiEditExit) instead of a second
       * exit of its own. The test is nKey == 0 so a real key always wins. */
      IF nKey == 0 .AND. UiRightClick()
         nKey := K_ESC
      ENDIF
      /* S13.7 (trap 61): the OPT-IN Alt hook is asked FIRST, before anything is
       * done with the key. This driver delivers `Alt+<letter>` as the PLAIN
       * letter, so the copy Inkey() handed over is DISCARDED -the chord is not
       * text- and the editor CLOSES keeping the value it has; the chord stays
       * pending for the caller (UiAltChord()), which is what makes `Alt+S` run
       * the button of the screen instead of typing an `s`. With no hook there
       * is nothing pending and the loop goes on exactly as before.
       * lNoAltClose: a PLAIN UiInput() is not a form and has no Alt hot keys of
       * its own, so it does NOT close on a chord. Without this an accelerator
       * that opens an input (Alt-S = Seek) died at once: the ALT ring is fed by
       * WM_SYSCHAR AFTER the accelerator already ran, the field saw the chord
       * and left with an empty value ("Not found."). That is the red A1 of
       * _reversing/verifica-menu-accels.ps1 since the Alt hook exists. */
      IF ! lNoAltClose .AND. Len( UiAltAsk() ) > 0
         s_nUiEditExit := K_ENTER
         lDone := .T.
         EXIT
      ENDIF
      /* The combos the window hook records WIN over the copy Inkey() hands
       * over for the same stroke (AGENTS trap 58: Ctrl+C arrives as a bare
       * 'c', Shift+Ins as a bare Ins), so that one keystroke is one action.
       * S3 of recycle-bin-delete.md: Shift+Del left this channel, so the codes
       * that can arrive here are copy, paste and cut and NOTHING else. The
       * rule lives in UiClipChord() because the cell of the Browse edit has its
       * own inline editor and it must not be written twice. */
      nClip := UiClipChord( nKey )
      IF nClip != 0
         aRes := UiClipApply( nClip, cBuf, nSelFrom, nSelTo, lDigitsOnly, lUpper )
         IF ! hb_IsNIL( aRes )
            cBuf := aRes[ 1 ] ; nPos := aRes[ 2 ]
            /* after a paste or a cut the caret is the new single end */
            nSelFrom := nPos ; nSelTo := nPos ; nAnchor := nPos
         ENDIF
         SetCursor( iif( lInsert, 0, 1 ) )
         UiEditFieldPaint( nRow, nCol, cBuf, cColor, nPos, lInsert, nSelFrom, nSelTo )
         LOOP
      ENDIF
      IF nKey == 0
         /* S3: a click INSIDE the field puts the caret on the clicked cell and
          * collapses the selection; anywhere else it is ignored and the field
          * stays open (a lost click must never close an input box). */
         aPt := UiClick()
         IF HB_ISARRAY( aPt ) .AND. aPt[ 1 ] == nRow .AND. ;
            aPt[ 2 ] >= nCol .AND. aPt[ 2 ] < nCol + nLen
            nPos := Max( 0, Min( nLen - 1, aPt[ 2 ] - nCol ) )
            nSelFrom := nPos ; nSelTo := nPos ; nAnchor := nPos
            SetCursor( iif( lInsert, 0, 1 ) )
            UiEditFieldPaint( nRow, nCol, cBuf, cColor, nPos, lInsert, nSelFrom, nSelTo )
         ENDIF
         LOOP
      ENDIF
      /* S100: SHIFT has to be read RIGHT NOW: the arrows do not carry it in
       * this driver and the live state is the only source (AGENTS trap 34). */
      lShift := UiShiftHeld()
      /* the whole editing rule (Ins = insert/overwrite included) lives in
       * UiEditKey(), shared with the Create Index form: one copy only */
      aKey := UiEditKey( cBuf, nPos, nKey, lInsert, lDigitsOnly, lUpper, lTabNav, ;
                         lShift, nSelFrom, nSelTo, nAnchor, cAccept, cMask )
      cBuf := aKey[ 1 ] ; nPos := aKey[ 2 ] ; lInsert := aKey[ 3 ]
      nSelFrom := aKey[ 6 ] ; nSelTo := aKey[ 7 ] ; nAnchor := aKey[ 8 ]
      DO CASE
      CASE aKey[ 5 ] == "ENTER"
         s_nUiEditExit := K_ENTER
         lDone := .T.
      CASE aKey[ 5 ] == "ESC"
         s_nUiEditExit := K_ESC
         lCancel := .T. ; lDone := .T.
      CASE aKey[ 5 ] == "TAB"
         s_nUiEditExit := K_TAB
         lDone := .T.
      CASE aKey[ 5 ] == "SH_TAB"
         s_nUiEditExit := K_SH_TAB
         lDone := .T.
      OTHERWISE
         /* the caret only lives in the OVERWRITE look: in insert mode the
          * block cell says where we are and the bar would sit on top of it */
         SetCursor( iif( lInsert, 0, 1 ) )
         UiEditFieldPaint( nRow, nCol, cBuf, cColor, nPos, lInsert, nSelFrom, nSelTo )
      ENDCASE
   ENDDO
   SetCursor( cOldCur )
   IF lInsert .OR. nSelTo > nSelFrom
      /* leave with the normal look: the caller restores or repaints, and a
       * black block or a highlight left behind would read as text */
      UiEditFieldPaint( nRow, nCol, cBuf, cColor, nPos, .F. )
   ENDIF
   SetColor( UI_C_DESKTOP )
RETURN iif( lCancel, NIL, RTrim( cBuf ) )

/* S15: how the last UiLineEdit() of this thread ended: K_ENTER (confirmed),
 * K_TAB / K_SH_TAB (confirmed and the form moves the focus) or K_ESC (the
 * caller gets NIL and the field keeps its old value). */
FUNCTION UiEditExit()
RETURN s_nUiEditExit

/* ---------- modal input with a label ---------- */

FUNCTION UiInput( cPrompt, cValue, nWidth, lSelAll )
   LOCAL nT, nL, nB, nR, cSave, cRes, nW, nMaxW, nTextW
   DEFAULT cValue TO "" ; DEFAULT nWidth TO Max( Len( cPrompt ), 20 )
   DEFAULT lSelAll TO .F.
   /* the WIDTH of the box has to hold the prompt AND the field: before it
    * only looked at nWidth, so with a long prompt and a short field (e.g. "VISIBLE
    * column number to cut:" with nWidth 4) the text ran out of the frame. */
   nMaxW := UiCols() - 12
   nTextW := UiBoxTextW()
   cPrompt := Left( cPrompt, nTextW - 4 )
   nW := Min( nMaxW, Max( nWidth, Len( cPrompt ) + 1 ) )
   nB := 4 ; nR := Min( nW + 6, UiCols() - 2 )
   nT := UiFitRow( UiCenterRow( nB ), nB + 1 )
   nL := UiFitCol( UiCenterCol( nR ), nR + 2 )
   cSave := SaveScreen( nT, nL, nT + nB + 1, Min( nL + nR + 2, MaxCol() ) )
   UiPaintBegin()
   UiShadow( nT, nL, nT + nB, nL + nR )
   UiFill( nT, nL, nT + nB, nL + nR, UI_C_BOX )
   UiFrame( nT, nL, nT + nB, nL + nR, UI_C_BOX, .T. )
   SetColor( UI_C_BOX )
   @ nT + 1, nL + 2 SAY cPrompt
   SetColor( UI_C_DESKTOP )
   UiPaintEnd()
   /* the FIELD is clamped to the box interior: with nWidth wider than the box
    * the text used to run past the right border. B2: this box has no wait of its
    * own - it waits inside the field - so the close of the window reaches it
    * through UiLineEdit(), which answers its cancel value (NIL, the same as Esc)
    * and is handed over here as it comes. */
   /* the field opens in the FOCUS pair, which is the one language of the forms
    * of this program (skill pantallas-de-formulario): grey `UI_C_FIELDBG` is for
    * a field at REST, and this one is the field being typed into */
   cRes := UiLineEdit( nT + 2, nL + 2, Min( nWidth, nW ), cValue, .F., UI_C_LISTSEL, ;
                       .F., .F., "", "", lSelAll, .T. )
   /* this box is not a form and has no Alt hot key of its own: the chord that
    * opened it (an accelerator) is dropped here so it cannot close the NEXT
    * field of the screen (the field itself already ignores it, lNoAltClose) */
   UiAltChord()
   RestScreen( nT, nL, nT + nB + 1, Min( nL + nR + 2, MaxCol() ), cSave )
RETURN cRes

/* ---------- modal list picker ---------- */

FUNCTION UiPick( aItems, cTitle, nStart, nT, nL, nH )
   LOCAL nB, nR, nSel, nKey, i, cSave, nScroll := 1, nMax := 0
   LOCAL nOldSel, nOldScroll
   LOCAL cOldCur
   DEFAULT cTitle TO "" ; DEFAULT nStart TO 1 ; DEFAULT nT TO -1
   DEFAULT nL TO -1 ; DEFAULT nH TO Min( 24, UiRows() - 6 )
   IF Empty( aItems )
      UiMsg( "No items to show.", cTitle )
      RETURN 0
   ENDIF
   nH := Min( nH, Len( aItems ) )
   FOR i := 1 TO Len( aItems )
      nMax := Max( nMax, Len( aItems[ i ] ) )
   NEXT
   nMax := Max( nMax, Len( cTitle ) )
   nMax := Min( nMax, UiCols() - 10 )
   nB := Min( nH + 3, UiRows() - 2 )
   /* the visible height cannot exceed the box interior */
   nH := Min( nH, nB - 3 )
   nR := Min( nMax + 4, UiCols() - 2 )
   IF nT < 0 ; nT := UiFitRow( UiCenterRow( nB ), nB + 1 ) ; ENDIF
   IF nL < 0 ; nL := UiFitCol( UiCenterCol( nR ), nR + 2 ) ; ENDIF
   nT := UiFitRow( nT, nB + 1 )
   nL := UiFitCol( nL, nR + 2 )
   nSel := Min( Max( nStart, 1 ), Len( aItems ) )
   /* the system cursor stays hidden the WHOLE time the box is on screen:
    * UiPaintBegin/End only hides it while painting, so while the list waited for
    * a key (Inkey) the caret blinked at the end of the last painted row - the
    * "blinking cursor" of the Alt-F1/F2 picker. It is done BEFORE the first
    * UiPaintBegin so the painting block saves/restores the already hidden state
    * (the same recipe as UiMsg()/UiConfirm()). */
   cOldCur := SetCursor( 0 )
   cSave := SaveScreen( nT, nL, nT + nB + 1, Min( nL + nR + 2, MaxCol() ) )
   /* the box is drawn only once; on every move only the affected list
    * rows are repainted (no filling of the whole box) */
   UiPaintBegin()
   UiShadow( nT, nL, nT + nB, nL + nR )
   UiFill( nT, nL, nT + nB, nL + nR, UI_C_BOX )
   UiFrame( nT, nL, nT + nB, nL + nR, UI_C_BOX, .T. )
   IF ! Empty( cTitle )
      SetColor( UI_C_BOX )
      @ nT, nL + 2 SAY " " + cTitle + " "
   ENDIF
   SetColor( UI_C_DESKTOP )
   UiPaintEnd()
   IF nSel < nScroll ; nScroll := nSel ; ENDIF
   IF nSel > nScroll + nH - 1 ; nScroll := nSel - nH + 1 ; ENDIF
   FOR i := 1 TO nH
      UiPickRow( aItems, nScroll, nSel, nT, nL, nMax, i )
   NEXT
   DO WHILE .T.
      /* B2 (S4): the wait is in 50 ms slices so the close of the window is seen
       * even when no key arrives (Inkey( 0 ) would block it for ever); a slice
       * without a key does not repaint, so the box stays exactly as it was. */
      DO WHILE .T.
         nKey := Inkey( 0.05 )
         IF nKey != 0
            EXIT
         ENDIF
         IF UiCloseAsk()
            /* the X of the window cancels the list like Esc does */
            nKey := K_ESC
            EXIT
         ENDIF
         /* right-click-esc (S1/S7): a plain right click cancels the list, the
          * same answer Esc gives, so the caller is left exactly as with Esc */
         IF UiRightClick()
            nKey := K_ESC
            EXIT
         ENDIF
         /* S10 of odd/tasks/commander-cleanup.md: THE MOUSE of the list. A
          * click on a row puts the cursor there (and a DOUBLE click chooses it,
          * the same as Enter); the wheel moves one row. The box is the one of
          * every UiPick of the program, so the 23 callers get it at once. */
         aPt := UiClick()
         IF HB_ISARRAY( aPt )
            IF aPt[ 1 ] >= nT + 1 .AND. aPt[ 1 ] <= nT + nH .AND. ;
               aPt[ 2 ] >= nL .AND. aPt[ 2 ] <= nR
               nIdx := nScroll + ( aPt[ 1 ] - nT ) - 1
               IF nIdx >= 1 .AND. nIdx <= Len( aItems )
                  nSel := nIdx
                  IF UiClickDbl()
                     nKey := K_ENTER
                     EXIT
                  ENDIF
               ENDIF
            ENDIF
            LOOP
         ENDIF
         nNotch := UiMouseWheel()
         IF nNotch != 0
            nSel := Min( Max( 1, nSel - nNotch ), Len( aItems ) )
            LOOP
         ENDIF
      ENDDO
      nOldSel := nSel ; nOldScroll := nScroll
      DO CASE
      CASE nKey == K_ESC
         nSel := 0 ; EXIT
      CASE nKey == K_ENTER .OR. nKey == K_SPACE
         EXIT
      CASE nKey == K_UP
         IF nSel > 1 ; nSel-- ; ENDIF
      CASE nKey == K_DOWN
         IF nSel < Len( aItems ) ; nSel++ ; ENDIF
      CASE nKey == K_PGUP
         nSel := Max( 1, nSel - nH )
      CASE nKey == K_PGDN
         nSel := Min( Len( aItems ), nSel + nH )
      CASE nKey == K_HOME
         nSel := 1
      CASE nKey == K_END
         nSel := Len( aItems )
      ENDCASE
      IF nSel < nScroll ; nScroll := nSel ; ENDIF
      IF nSel > nScroll + nH - 1 ; nScroll := nSel - nH + 1 ; ENDIF
      UiPaintBegin()
      IF nScroll != nOldScroll
         FOR i := 1 TO nH
            UiPickRow( aItems, nScroll, nSel, nT, nL, nMax, i )
         NEXT
      ELSEIF nSel != nOldSel
         UiPickRow( aItems, nScroll, nSel, nT, nL, nMax, nOldSel - nScroll + 1 )
         UiPickRow( aItems, nScroll, nSel, nT, nL, nMax, nSel - nScroll + 1 )
      ENDIF
      UiPaintEnd()
   ENDDO
   SetColor( UI_C_DESKTOP )
   RestScreen( nT, nL, nT + nB + 1, Min( nL + nR + 2, MaxCol() ), cSave )
   /* the caret comes back as it was before the list (it was blinking over the
    * box: see the SetCursor( 0 ) at the top) */
   SetCursor( cOldCur )
RETURN nSel

/* draw one row of the UiPick list (1..nH) */
STATIC PROCEDURE UiPickRow( aItems, nScroll, nSel, nT, nL, nMax, nRow )
   LOCAL nIdx := nScroll + nRow - 1
   IF nRow < 1 .OR. nRow > Len( aItems ) ; RETURN ; ENDIF
   IF nIdx > Len( aItems ) ; RETURN ; ENDIF
   IF nIdx == nSel
      SetColor( UI_C_LISTSEL )
   ELSE
      SetColor( UI_C_BOX )
   ENDIF
   @ nT + nRow, nL + 2 SAY PadR( aItems[ nIdx ], nMax )
   SetColor( UI_C_DESKTOP )
RETURN NIL

/* ---------- scrollable text window (help / information) ---------- */

/* Scrollable text window. aActions (optional) = { { "S", "Save to
 * file" }, { "C", "Copy to clipboard" } }: they are announced in the hint line
 * and the function returns the key of the chosen action ("" when it is closed
 * with Esc or Enter). The usual callers (BpHelp, BpHotKeys) do not pass them. */
FUNCTION UiTextWin( aLines, cTitle, aActions )
   LOCAL nTop := 0, nKey, nT, nB, nL, nR, nMax := 0, i, cSave, nVis, cHint, cAct := ""
   LOCAL cOldCur
   DEFAULT cTitle TO "Info"
   DEFAULT aActions TO {}
   cHint := "<Up/Down/PgUp/PgDn/Home/End>  <Esc> " + iif( Empty( aActions ), "exit", "close" )
   FOR i := 1 TO Len( aActions )
      cHint += "  <" + aActions[ i ][ 1 ] + "> " + aActions[ i ][ 2 ]
   NEXT
   FOR i := 1 TO Len( aLines )
      nMax := Max( nMax, Len( aLines[ i ] ) )
   NEXT
   nMax := Min( Max( nMax, Max( Len( cTitle ), Len( cHint ) ) ), UiCols() - 12 )
   /* the window uses the canvas: one row of margin on top, the last row left
    * to the caller, and centred horizontally */
   nT := 1 ; nB := MaxRow() - 1
   nR := Min( nMax + 4, UiCols() - 6 )
   nL := UiFitCol( UiCenterCol( nR ), nR + 2 )
   /* the caret stays hidden while the window waits for a key (UiPaintBegin/End
    * only hide it while painting): the same reason and recipe as UiPick() */
   cOldCur := SetCursor( 0 )
   cSave := SaveScreen( nT, nL, nB + 1, Min( nL + nR + 2, MaxCol() ) )
   nVis := nB - nT - 2
   /* fixed frame; when scrolling only the text lines are repainted */
   UiPaintBegin()
   UiShadow( nT, nL, nB, nL + nR )
   UiFill( nT, nL, nB, nL + nR, UI_C_BOX )
   UiFrame( nT, nL, nB, nL + nR, UI_C_BOX, .T. )
   SetColor( UI_C_BOX )
   @ nT, nL + 2 SAY " " + Left( cTitle, nR - 6 ) + " "
   SetColor( UI_C_HINT )
   @ nB, nL + 2 SAY PadR( Left( cHint, nR - 5 ), nR - 5 )
   SetColor( UI_C_DESKTOP )
   UiPaintEnd()
   DO WHILE .T.
      UiPaintBegin()
      FOR i := 1 TO nVis
         SetColor( UI_C_BOX )
         @ nT + i, nL + 2 SAY PadR( iif( nTop + i <= Len( aLines ), SubStr( aLines[ nTop + i ], 1, nMax ), "" ), nMax )
      NEXT
      SetColor( UI_C_DESKTOP )
      UiPaintEnd()
      /* B2 (S4): 50 ms slices, so a close with no key is seen; a slice without a
       * key does not repaint (the text is only painted when a key was handled) */
      DO WHILE .T.
         nKey := Inkey( 0.05 )
         IF nKey != 0
            EXIT
         ENDIF
         IF UiCloseAsk()
            /* the X of the window closes this window like Esc: the caller gets
             * the same empty action and the latch survives for the exit */
            nKey := K_ESC
            EXIT
         ENDIF
         /* right-click-esc (S1/S7): a plain right click closes the window, the
          * same as Esc and as the X of the window above */
         IF UiRightClick()
            nKey := K_ESC
            EXIT
         ENDIF
      ENDDO
      DO CASE
      CASE nKey == K_ESC .OR. nKey == K_ENTER ; EXIT
      CASE nKey == K_UP     ; nTop := Max( 0, nTop - 1 )
      CASE nKey == K_DOWN   ; nTop := Min( Max( 0, Len( aLines ) - nVis ), nTop + 1 )
      CASE nKey == K_PGUP   ; nTop := Max( 0, nTop - nVis )
      CASE nKey == K_PGDN   ; nTop := Min( Max( 0, Len( aLines ) - nVis ), nTop + nVis )
      CASE nKey == K_HOME   ; nTop := 0
      CASE nKey == K_END    ; nTop := Max( 0, Len( aLines ) - nVis )
      CASE nKey >= 32 .AND. nKey <= 255
         /* optional actions (save, copy): they return the key */
         IF ! Empty( aActions )
            IF AScan( aActions, {| a | a[ 1 ] == Upper( Chr( nKey ) ) } ) > 0
               cAct := Upper( Chr( nKey ) )
               EXIT
            ENDIF
         ENDIF
      ENDCASE
   ENDDO
   RestScreen( nT, nL, nB + 1, Min( nL + nR + 2, MaxCol() ), cSave )
   SetCursor( cOldCur )
RETURN cAct

/* ---------- conversion of field values to/from text ---------- */

FUNCTION UiValToStr( xVal, cType, nLen, nDec )
   DO CASE
   CASE cType == "C" ; RETURN PadR( xVal, nLen )
   CASE cType == "N" ; RETURN LTrim( Str( xVal, nLen, nDec ) )
   CASE cType == "D" ; RETURN DToC( xVal )
   CASE cType == "L" ; RETURN iif( xVal, "T", "F" )
   CASE cType == "M" ; RETURN "<memo>"
   ENDCASE
RETURN ""

FUNCTION UiStrToVal( cStr, cType )
   DO CASE
   CASE cType == "C" ; RETURN cStr
   CASE cType == "N" ; RETURN Val( cStr )
   CASE cType == "D" ; RETURN CToD( cStr )
   CASE cType == "L" ; RETURN ( Upper( Left( cStr, 1 ) ) == "T" .OR. Left( cStr, 1 ) == "Y" )
   ENDCASE
RETURN cStr


/* ---------- progress bar (long processes) ----------
 * Meant for processes that take tens of seconds (Alt-M rewrites the whole
 * table): modal box with a block bar, record counter and
 * percentage, and <Esc> to cancel.
 *
 *   UiProgBegin( cTitle, nTotal )   paints the box ONCE
 *   UiProgUpdate( nDone, nTotal )   repaints bar + counter and returns .T. if
 *                                   the user pressed <Esc> (cancel)
 *   UiProgEnd()                     closes the state; the screen underneath is
 *                                   repainted by the caller (not saved here)
 *
 * It repaints at most once every PROG_REFRESH_MS, whatever moves (percentage or
 * text line): a repaint is a full window REFRESH, and refreshing once per record
 * is what made SUM/AVERAGE and the other long walks crawl. Callers that walk a
 * whole table also ask UiProgStep() and only call this every n records.
 * The "Cls"/"SetColor" lines are not used: it paints with UiWrite so it does not
 * touch the color of the rest of the screen. */

#define PROG_W          60                            /* total width, frame included */
#define PROG_H          6
#define PROG_T          ( Max( 0, Int( ( UiRows() - PROG_H ) / 2 ) ) )
#define PROG_L          ( Max( 0, Int( ( UiCols() - PROG_W ) / 2 ) ) )
#define PROG_B          ( PROG_T + PROG_H - 1 )
#define PROG_R          ( PROG_L + PROG_W - 1 )
#define PROG_IN_L       ( PROG_L + 2 )
#define PROG_IN_W       ( PROG_W - 4 )              /* bar cells */
/* a repaint of the bar costs a full window REFRESH, so it happens at most once
 * every this many milliseconds: a walk that moves the percentage on almost every
 * record (or that passes a per-record text) must not refresh once per record. */
#define PROG_REFRESH_MS 80
/* how many times per table the bar is repainted (and the keyboard polled):
 * 50,000 records give a step of 100, i.e. 500 steps per walk. Repainting and
 * polling on EVERY record is what made the long walks crawl. */
#define PROG_STEPS      500

/* { nT, nL, nB, nR } of the progress box, so a caller that has to save and
 * restore the area underneath does not hardcode the rectangle: BpIdxVerify
 * used to SaveScreen( 9, 13, 16, 67 ), the box of the old 80x25 grid. */
FUNCTION UiProgRect()
RETURN { PROG_T, PROG_L, PROG_B, PROG_R }

/* CAREFUL: the STATIC state of the bar goes at the TOP of the file (with s_nPaint),
 * because Harbour does not allow STATIC declarations after code (AGENTS.md 5.7) */

FUNCTION UiProgBegin( cTitle, nTotal, lCancel )
   DEFAULT cTitle TO "", nTotal TO 0, lCancel TO .T.
   s_nProgTotal := Max( 0, nTotal )
   s_nProgPct   := -1
   s_cProgText  := ""
   s_lProgEsc   := .F.
   s_lProgOn    := .T.
   s_nProgMs    := 0
   UiPaintBegin()
   UiShadow( PROG_T, PROG_L, PROG_B, PROG_R )
   UiFillBox( PROG_T, PROG_L, PROG_B, PROG_R, UI_C_BOX )
   UiFrame( PROG_T, PROG_L, PROG_B, PROG_R, UI_C_BOX, .T. )
   UiWrite( PROG_T, PROG_L + 2, " " + cTitle + " ", UI_C_PROGTIT )
   UiWrite( PROG_T + 2, PROG_IN_L, Space( PROG_IN_W ), UI_C_PROGEMPTY )
   UiWrite( PROG_T + 3, PROG_IN_L, PadR( "", PROG_IN_W ), UI_C_PROGTXT )
   UiWrite( PROG_T + 4, PROG_IN_L, PadR( iif( lCancel, "<Esc>=Cancel", "" ), PROG_IN_W ), UI_C_PROGTXT )
   UiPaintEnd()
   /* paint the initial state (0%) with the counter at zero */
   UiProgUpdate( 0, s_nProgTotal )
RETURN NIL

/* how many records make ONE progress step: callers that walk a table ask this
 * once and only touch the bar (and poll the keyboard) on the multiples of the
 * answer - 50,000 records give a step of 100 - instead of on every record. */
FUNCTION UiProgStep( nTotal )
RETURN Max( 1, Int( Max( 0, nTotal ) / PROG_STEPS ) )

/* nDone/nTotal and, optionally, the text line: if cText is passed it is used
 * AS IS instead of "N / total records  P%" (for processes that do not count
 * records, e.g. the tag by tag reindex: "Indexing Tag ART_NOM"). */
FUNCTION UiProgUpdate( nDone, nTotal, cText )
   LOCAL nPct, nFill, cLine, lMove, nNow
   DEFAULT nTotal TO s_nProgTotal, cText TO ""
   IF ! s_lProgOn
      RETURN .F.
   ENDIF
   nPct := iif( nTotal > 0, Min( 100, Int( nDone * 100 / nTotal ) ), 100 )
   /* SPEED: a repaint costs a full window REFRESH (several ms), so the bar is
    * repainted at most once every PROG_REFRESH_MS whatever moves - the
    * percentage of a fast walk changes on almost every record and a per-record
    * REFRESH is exactly what made SUM/AVERAGE crawl. A slow process (a reindex
    * tag, a copy) calls this far apart and paints every time. */
   lMove := nPct != s_nProgPct
   IF lMove .OR. ! ( cText == s_cProgText )
      nNow := hb_MilliSeconds()
      IF nNow - s_nProgMs >= PROG_REFRESH_MS
         s_nProgPct  := nPct
         s_cProgText := cText
         s_nProgMs   := nNow
         cLine := iif( Empty( cText ), UiProgText( nDone, nTotal, nPct ), cText )
         nFill := Int( PROG_IN_W * nPct / 100 )
         UiPaintBegin()
         IF nFill > 0
            UiWrite( PROG_T + 2, PROG_IN_L, Replicate( Chr( 219 ), nFill ), UI_C_PROGBAR )
         ENDIF
         IF nFill < PROG_IN_W
            UiWrite( PROG_T + 2, PROG_IN_L + nFill, ;
                     Space( PROG_IN_W - nFill ), UI_C_PROGEMPTY )
         ENDIF
         UiWrite( PROG_T + 3, PROG_IN_L, PadR( cLine, PROG_IN_W ), UI_C_PROGTXT )
         UiPaintEnd()
      ENDIF
   ENDIF
   /* <Esc> cancels: it is checked on EVERY call (even when nothing has to be
    * repainted) so it answers at once in a process of a million records */
   IF Inkey() == K_ESC
      s_lProgEsc := .T.
   ENDIF
   /* B2 (S4): the X of the window aborts the operation EXACTLY like Esc, and the
    * callers already cope with a cancelled operation (the data they were
    * writing is left intact by the temporary-file-and-rename path), so nothing
    * else has to change. The latch is only peeked: the exit still happens. */
   IF UiCloseAsk()
      s_lProgEsc := .T.
   ENDIF
RETURN s_lProgEsc

FUNCTION UiProgEnd()
   s_lProgOn    := .F.
   s_nProgPct   := -1
   s_cProgText  := ""
   s_lProgEsc   := .F.
   s_nProgMs    := 0
RETURN NIL

/* Progress box WITHOUT a known total: for processes the engine does not report
 * (REINDEX, PACK, APPEND FROM, REPLACE ALL, COPY TO, INDEX ON...). It is shown
 * before starting them and closed with UiProgEnd(); the screen is repainted by
 * the caller (the browser repaints the frame after every menu option).
 * It cannot be cancelled with <Esc>: these processes are not interruptible. */
FUNCTION UiProgBusy( cTitle )
   DEFAULT cTitle TO ""
   UiProgBegin( cTitle, 0 )
   UiPaintBegin()
   UiWrite( PROG_T + 2, PROG_IN_L, Space( PROG_IN_W ), UI_C_PROGEMPTY )
   UiWrite( PROG_T + 3, PROG_IN_L, PadR( "Working... please wait", PROG_IN_W ), UI_C_PROGTXT )
   UiWrite( PROG_T + 4, PROG_IN_L, PadR( "", PROG_IN_W ), UI_C_PROGTXT )
   UiPaintEnd()
   s_lProgEsc := .F.
RETURN NIL

/* counter line: "  412000 / 1020098 records   40%" */
STATIC FUNCTION UiProgText( nDone, nTotal, nPct )
RETURN PadL( LTrim( Str( nDone ) ), 9 ) + " / " + ;
       PadR( LTrim( Str( nTotal ) ), 9 ) + " records" + ;
       PadL( LTrim( Str( nPct ) ) + "%", 7 )


/* =====================================================================
 *  F8 -> "List to Print": the RULES of the LIST screen
 *  (odd/tasks/list-to-print.md, S2/S3/S4/S5/S7/S8/S10)
 * ---------------------------------------------------------------------
 *  The screen itself lives in bp_cmds.prg, but the headless bank links THIS
 *  module (test_hc.prg links bp_ui.prg + bp_hc.prg and never bp_cmds.prg), so
 *  every rule that can be decided without a window and without a database is
 *  a plain FUNCTION here: the shape of the listing, the destination, the
 *  scope, the field selection and its ORDER, the separator, the compilation of
 *  the conditions and the three builders of the listing.
 *
 *  This module NEVER calls win_* (hbwin is linked into the product only): the
 *  printer list and the raw printing stay in bp_cmds.prg.
 * ===================================================================== */

/* S2: the three shapes of the listing, in the order of the capture of the
 * original. The INDEX in this array is the value the form keeps. */
FUNCTION LpShapeList()
RETURN { "Current Fields/Columnar", "Full Page per Record", "Memo Field" }

/* S2: the shape as the select shows it. Anything out of range answers the
 * first one, so a form state from an older session can never paint "" */
FUNCTION LpShapeText( nShape )
   LOCAL a := LpShapeList()
   IF ValType( nShape ) != "N" .OR. nShape < 1 .OR. nShape > Len( a )
      RETURN a[ 1 ]
   ENDIF
RETURN a[ Int( nShape ) ]

/* S4: the two destinations, in the order of the capture (PRINT first) */
FUNCTION LpToList()
RETURN { "PRINT", "FILE" }

/* S4: the destination as the select shows it: 2 = FILE, anything else PRINT */
FUNCTION LpToText( nTo )
RETURN iif( ValType( nTo ) == "N" .AND. Int( nTo ) == 2, "FILE", "PRINT" )

/* S7: the four scopes, in the order of the Replace form (and of the original) */
FUNCTION LpScopeList()
RETURN { "ALL", "NEXT", "REST", "RECORD" }

FUNCTION LpScopeText( nScope )
   LOCAL a := LpScopeList()
   IF ValType( nScope ) != "N" .OR. nScope < 1 .OR. nScope > Len( a )
      RETURN a[ 1 ]
   ENDIF
RETURN a[ Int( nScope ) ]

/* S7: Count only exists with NEXT and RECORD; with ALL and REST the cell is
 * painted dimmed and is neither clicked nor tabbed to (one rule, used by the
 * painter, the ring and the bank) */
FUNCTION LpScopeNeedsCount( nScope )
   IF ValType( nScope ) != "N"
      RETURN .F.
   ENDIF
RETURN Int( nScope ) == 2 .OR. Int( nScope ) == 4

/* S3: the selection is a LIST of field numbers in the order they were picked,
 * so the ORDER NUMBER of a field is its position in that list and un-picking
 * one of the middle RENUMBERS the ones behind it with no second rule.
 *
 * The answer is a NEW array: in Harbour an array is a REFERENCE (trap 67), so
 * mutating the argument would alias the state of the screen. A field number
 * that is not a positive whole number is ignored. */
FUNCTION LpSelToggle( aSel, nField )
   LOCAL a := {}, i, nF := 0, lHad := .F.
   IF ValType( nField ) == "N" .AND. nField >= 1
      nF := Int( nField )
   ENDIF
   IF HB_ISARRAY( aSel )
      FOR i := 1 TO Len( aSel )
         IF ValType( aSel[ i ] ) != "N" .OR. aSel[ i ] < 1
            LOOP
         ENDIF
         IF nF > 0 .AND. Int( aSel[ i ] ) == nF
            lHad := .T.
         ELSE
            AAdd( a, Int( aSel[ i ] ) )
         ENDIF
      NEXT
   ENDIF
   IF nF > 0 .AND. ! lHad
      AAdd( a, nF )
   ENDIF
RETURN a

/* S3: the order number a field shows at its left, 0 when it is not selected */
FUNCTION LpSelOrder( aSel, nField )
   LOCAL i
   IF ! HB_ISARRAY( aSel ) .OR. ValType( nField ) != "N"
      RETURN 0
   ENDIF
   FOR i := 1 TO Len( aSel )
      IF ValType( aSel[ i ] ) == "N" .AND. Int( aSel[ i ] ) == Int( nField )
         RETURN i
      ENDIF
   NEXT
RETURN 0

FUNCTION LpSelCount( aSel )
RETURN iif( HB_ISARRAY( aSel ), Len( aSel ), 0 )

/* S3: every field selected, in FILE order - the default of the screen, which is
 * what the old `LIST OFF` of this menu row did */
FUNCTION LpSelAll( nFields )
   LOCAL a := {}, i
   IF ValType( nFields ) != "N" .OR. nFields < 1
      RETURN a
   ENDIF
   FOR i := 1 TO Int( nFields )
      AAdd( a, i )
   NEXT
RETURN a

/* S5: the separator really used between fields: an EMPTY box means ONE space,
 * and a box holding more than one character only means its first one, so the
 * line can never be broken by a stray paste. Junk answers the space too. */
FUNCTION LpSepText( cSep )
   LOCAL c := ""
   IF ValType( cSep ) == "C" .AND. Len( cSep ) > 0
      c := Left( cSep, 1 )
   ENDIF
   IF Len( c ) == 0
      c := " "
   ENDIF
RETURN c

/* S8: a WHILE/FOR expression compiled ONCE, before the run starts. cErr comes
 * back NIL when it compiles (and the block is the answer) and with the reason
 * when it does not; an EMPTY box is no condition at all and answers NIL with no
 * error, so a condition nobody asked for costs nothing. */
FUNCTION LpCondBlock( cExpr, cErr )
   LOCAL b := NIL, oErr
   cErr := NIL
   IF ValType( cExpr ) != "C" .OR. Len( AllTrim( cExpr ) ) == 0
      RETURN NIL
   ENDIF
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      b := &( "{|| " + cExpr + " }" )
   RECOVER USING oErr
      cErr := "The condition does not compile:" + hb_eol() + oErr:Description
      b := NIL
   END SEQUENCE
RETURN b

/* S10: the width of one column of the Columnar shape: the width of the FIELD,
 * and the length of its NAME when the name is longer (a header that does not
 * fit in its column would run over the next one) */
FUNCTION LpColWidth( cName, nLen )
   LOCAL nW := 1
   IF ValType( nLen ) == "N" .AND. nLen >= 1
      nW := Int( nLen )
   ENDIF
   IF ValType( cName ) == "C"
      nW := Max( nW, Len( cName ) )
   ENDIF
RETURN nW

/* S10: ONE line of the Columnar shape - the header row and a record row are the
 * same builder, so they cannot get out of step: every cell is cut or padded to
 * its column width and the cells are joined with the separator. A column whose
 * type is "N" is right aligned (a number reads better), everything else left
 * aligned. `aTypes` is optional. */
FUNCTION LpColLine( aCells, aWidths, cSep, aTypes )
   LOCAL c := "", i, nW, cCell, cType := ""
   DEFAULT cSep TO " "
   IF ValType( cSep ) != "C" .OR. Len( cSep ) == 0
      cSep := " "
   ENDIF
   IF ! HB_ISARRAY( aCells )
      RETURN c
   ENDIF
   FOR i := 1 TO Len( aCells )
      nW := 1
      IF HB_ISARRAY( aWidths ) .AND. i <= Len( aWidths ) .AND. ;
         ValType( aWidths[ i ] ) == "N" .AND. aWidths[ i ] >= 1
         nW := Int( aWidths[ i ] )
      ENDIF
      cCell := iif( ValType( aCells[ i ] ) == "C", aCells[ i ], "" )
      cCell := Left( cCell, nW )
      cType := ""
      IF HB_ISARRAY( aTypes ) .AND. i <= Len( aTypes ) .AND. ValType( aTypes[ i ] ) == "C"
         cType := Upper( aTypes[ i ] )
      ENDIF
      cCell := iif( cType == "N", PadL( cCell, nW ), PadR( cCell, nW ) )
      c += cCell
      IF i < Len( aCells )
         c += cSep
      ENDIF
   NEXT
RETURN c

/* S10: one record of the "Full Page per Record" shape: `NAME = value`, one line
 * per field, the names padded to the widest of THIS record so the equals signs
 * line up. Answers an array of lines (the caller decides the blank line between
 * two records, so the builder stays the same for one record or for many). */
FUNCTION LpPageLines( aNames, aVals )
   LOCAL a := {}, i, nW := 0, cVal
   IF ! HB_ISARRAY( aNames )
      RETURN a
   ENDIF
   FOR i := 1 TO Len( aNames )
      IF ValType( aNames[ i ] ) == "C"
         nW := Max( nW, Len( aNames[ i ] ) )
      ENDIF
   NEXT
   FOR i := 1 TO Len( aNames )
      cVal := ""
      IF HB_ISARRAY( aVals ) .AND. i <= Len( aVals ) .AND. ValType( aVals[ i ] ) == "C"
         cVal := aVals[ i ]
      ENDIF
      AAdd( a, PadR( iif( ValType( aNames[ i ] ) == "C", aNames[ i ], "" ), nW ) + ;
               " = " + cVal )
   NEXT
RETURN a

/* S10: the memo dump of one record - `NAME:` and the content below it. The
 * content arrives as ONE string with hb_eol() inside (that is what a memo field
 * answers) and it is split here, because a SAY does not break lines in GTWVG
 * (trap 19) and the file is written line by line. A blank line separates two
 * memos but never follows the last one. */
FUNCTION LpMemoLines( aNames, aTexts )
   LOCAL a := {}, i, j, aLin, cBody, nLast
   IF ! HB_ISARRAY( aNames ) .OR. Len( aNames ) == 0
      RETURN a
   ENDIF
   FOR i := 1 TO Len( aNames )
      AAdd( a, iif( ValType( aNames[ i ] ) == "C", aNames[ i ], "" ) + ":" )
      cBody := ""
      IF HB_ISARRAY( aTexts ) .AND. i <= Len( aTexts ) .AND. ValType( aTexts[ i ] ) == "C"
         cBody := aTexts[ i ]
      ENDIF
      /* an EMPTY memo prints only its name, and the blank lines a memo may end
       * with never reach the listing (a job that ends with a blank line per
       * record would print a page of them) */
      IF Len( AllTrim( cBody ) ) > 0
         aLin := hb_ATokens( StrTran( cBody, Chr( 13 ), "" ), Chr( 10 ) )
         nLast := Len( aLin )
         DO WHILE nLast >= 1 .AND. Len( AllTrim( aLin[ nLast ] ) ) == 0
            nLast--
         ENDDO
         FOR j := 1 TO nLast
            AAdd( a, aLin[ j ] )
         NEXT
      ENDIF
      IF i < Len( aNames )
         AAdd( a, "" )
      ENDIF
   NEXT
RETURN a

/* S10: which fields the "Memo Field" shape dumps - the SELECTED ones whose type
 * is Memo, and every Memo field of the file when the selection has none (a
 * Memo listing with an empty page would be a lie). Answers field numbers. */
FUNCTION LpMemoFields( aSel, aTypes )
   LOCAL a := {}, i
   IF ! HB_ISARRAY( aSel ) .OR. ! HB_ISARRAY( aTypes )
      RETURN a
   ENDIF
   FOR i := 1 TO Len( aSel )
      IF ValType( aSel[ i ] ) == "N" .AND. aSel[ i ] >= 1 .AND. ;
         aSel[ i ] <= Len( aTypes ) .AND. ValType( aTypes[ aSel[ i ] ] ) == "C" .AND. ;
         Upper( aTypes[ aSel[ i ] ] ) == "M"
         AAdd( a, Int( aSel[ i ] ) )
      ENDIF
   NEXT
   IF Len( a ) == 0
      FOR i := 1 TO Len( aTypes )
         IF ValType( aTypes[ i ] ) == "C" .AND. Upper( aTypes[ i ] ) == "M"
            AAdd( a, i )
         ENDIF
      NEXT
   ENDIF
RETURN a 

/* =====================================================================
 *  F8 CommandTools -> "SUM/AVERAGE"  (odd/tasks/sum-average-form.md)
 * ---------------------------------------------------------------------
 *  The pure rules of the SUM/AVERAGE form, here for the same reason as the
 *  Lp* family above: the headless bank links THIS module and never
 *  bp_cmds.prg, so everything that can be decided without a window lives
 *  here and the screen only composes it.
 * ===================================================================== */

/* S3: the only field types that can be added up. Numeric and Float; a
 * character, a date, a logical or a memo would only make the engine answer a
 * type error, so the field screen lists nothing else. Never fails: junk (NIL,
 * "", a number) is not numeric. */
FUNCTION SmIsNumType( cType )
   LOCAL c := ""
   IF ValType( cType ) == "C"
      c := Upper( AllTrim( cType ) )
   ENDIF
RETURN c == "N" .OR. c == "F"

/* S3: the POSITIONS of the numeric fields of the file, in file order - the one
 * rule the state uses to filter the file down to what can be summed, so the
 * screen never asks a second time. Junk answers an empty list. */
FUNCTION SmNumFields( aTypes )
   LOCAL a := {}, i
   IF ! HB_ISARRAY( aTypes )
      RETURN a
   ENDIF
   FOR i := 1 TO Len( aTypes )
      IF SmIsNumType( aTypes[ i ] )
         AAdd( a, i )
      ENDIF
   NEXT
RETURN a

/* S4: the comma-separated expressions of the input, trimmed and without the
 * empty pieces, so "A, , B" is two expressions and an empty box is none. */
FUNCTION SmExprList( cExpr )
   LOCAL a := {}, aRaw, i, c
   IF ValType( cExpr ) != "C" .OR. Len( AllTrim( cExpr ) ) == 0
      RETURN a
   ENDIF
   aRaw := hb_ATokens( cExpr, "," )
   FOR i := 1 TO Len( aRaw )
      c := AllTrim( aRaw[ i ] )
      IF Len( c ) > 0
         AAdd( a, c )
      ENDIF
   NEXT
RETURN a

/* S3: the expression the field screen builds - the names of the chosen fields
 * in the order they were picked, comma separated. A number that does not name a
 * field of the list is skipped, so a stale selection cannot print a name that is
 * not there; an empty selection answers "". */
FUNCTION SmExprText( aSel, aNames )
   LOCAL c := "", i, n
   IF ! HB_ISARRAY( aSel ) .OR. ! HB_ISARRAY( aNames )
      RETURN c
   ENDIF
   FOR i := 1 TO Len( aSel )
      IF ValType( aSel[ i ] ) != "N" .OR. aSel[ i ] < 1
         LOOP
      ENDIF
      n := Int( aSel[ i ] )
      IF n > Len( aNames ) .OR. ValType( aNames[ n ] ) != "C"
         LOOP
      ENDIF
      c += iif( Len( c ) == 0, "", ", " ) + aNames[ n ]
   NEXT
RETURN c

/* S5: one number as the report shows it - four decimals at most, the trailing
 * zeros dropped (a sum of whole numbers reads as a whole number) and a "-0"
 * normalized to "0". Junk answers "" so a missing slot never prints a lie. */
FUNCTION SmNumText( nVal )
   LOCAL c := ""
   IF ValType( nVal ) != "N"
      RETURN ""
   ENDIF
   c := AllTrim( Str( nVal, 20, 4 ) )
   IF "." $ c
      DO WHILE Right( c, 1 ) == "0"
         c := Left( c, Len( c ) - 1 )
      ENDDO
      IF Right( c, 1 ) == "."
         c := Left( c, Len( c ) - 1 )
      ENDIF
   ENDIF
   IF Len( c ) == 0 .OR. c == "-0"
      c := "0"
   ENDIF
RETURN c

/* S5: the average of the records that were summed. With ZERO records it does
 * not divide: it answers 0, which is what keeps a form that found nothing from
 * reporting a division by zero as a result. */
FUNCTION SmAverage( nSum, nRecs )
   IF ValType( nSum ) != "N" .OR. ValType( nRecs ) != "N" .OR. nRecs < 1
      RETURN 0
   ENDIF
RETURN nSum / nRecs

/* S4: ONE expression compiled ONCE, before anything is walked. cErr comes back
 * NIL when it compiles AND answers a number for the record the pointer is on
 * (a character cannot be summed), and with the reason when it does not; an
 * EMPTY expression is no expression at all (NIL, no error), which is how the
 * caller tells "nothing to do" from "it is broken". */
FUNCTION SmExprBlock( cExpr, cErr )
   LOCAL b := NIL, x, oErr
   cErr := NIL
   IF ValType( cExpr ) != "C" .OR. Len( AllTrim( cExpr ) ) == 0
      RETURN NIL
   ENDIF
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      b := &( "{|| " + cExpr + " }" )
   RECOVER USING oErr
      cErr := "Invalid expression: " + AllTrim( cExpr ) + hb_eol() + oErr:Description
      b := NIL
   END SEQUENCE
   IF hb_IsNIL( b )
      RETURN NIL
   ENDIF
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      x := Eval( b )
   RECOVER USING oErr
      cErr := "Invalid expression: " + AllTrim( cExpr ) + hb_eol() + oErr:Description
      RETURN NIL
   END SEQUENCE
   IF ValType( x ) != "N"
      cErr := "Invalid expression: " + AllTrim( cExpr ) + " is not numeric."
      RETURN NIL
   ENDIF
RETURN b

/* S4: every comma-separated expression of the input, compiled in order. Answers
 * the array of blocks with cErr NIL, or an EMPTY array with the reason; an input
 * with nothing in it is an error here, because this form has nothing to do
 * without it. The caller compiles BEFORE walking anything, so a typo cannot
 * leave a half-read table behind. */
FUNCTION SmExprBlocks( cExpr, cErr )
   LOCAL aTxt := SmExprList( cExpr ), aBlk := {}, b, cE, i
   cErr := NIL
   IF Len( aTxt ) == 0
      cErr := "Enter the field or the expression to SUM/AVERAGE."
      RETURN aBlk
   ENDIF
   FOR i := 1 TO Len( aTxt )
      b := SmExprBlock( aTxt[ i ], @cE )
      IF ! hb_IsNIL( cE )
         cErr := cE
         RETURN {}
      ENDIF
      AAdd( aBlk, b )
   NEXT
RETURN aBlk

/* S5: the report - ONE line per expression carrying its SUM and its AVERAGE,
 * the expressions padded to the widest one and the totals right aligned among
 * themselves, so the two columns line up; the number of records summed goes on
 * the last line. With ZERO records the answer is that ONE line and nothing else
 * ("No record matches the scope."). */
FUNCTION SmResultLines( aExprs, aSums, nRecs )
   LOCAL a := {}, i, nW := 0, nSum, cLine, nSW := 0
   LOCAL aTxt := {}, aSum := {}
   IF ValType( nRecs ) != "N" .OR. nRecs < 1
      RETURN { "No record matches the scope." }
   ENDIF
   IF ! HB_ISARRAY( aExprs )
      RETURN a
   ENDIF
   FOR i := 1 TO Len( aExprs )
      nSum := 0
      IF HB_ISARRAY( aSums ) .AND. i <= Len( aSums ) .AND. ValType( aSums[ i ] ) == "N"
         nSum := aSums[ i ]
      ENDIF
      AAdd( aTxt, iif( ValType( aExprs[ i ] ) == "C", aExprs[ i ], "" ) )
      AAdd( aSum, nSum )
      nW  := Max( nW, Len( aTxt[ i ] ) )
      nSW := Max( nSW, Len( SmNumText( nSum ) ) )
   NEXT
   nW := Min( nW, 24 )
   FOR i := 1 TO Len( aTxt )
      cLine := PadR( Left( aTxt[ i ], nW ), nW )
      cLine += "  SUM = " + PadL( SmNumText( aSum[ i ] ), nSW )
      cLine += "   AVERAGE = " + SmNumText( SmAverage( aSum[ i ], nRecs ) )
      AAdd( a, cLine )
   NEXT
   AAdd( a, LTrim( Str( Int( nRecs ) ) ) + " record(s)." )
RETURN a

/* =====================================================================
 *  Append From - the rules that can be decided WITHOUT a window
 *  (odd/tasks/append-from-form.md, S19)
 * ---------------------------------------------------------------------
 *  They live here, and not with their screen (bp_cmds.prg), for the same
 *  reason the Sm* helpers of SUM/AVERAGE do: the headless bank links THIS
 *  module and never bp_cmds.prg, so a rule that stays with the screen cannot
 *  be pinned. The screen only paints and walks them.
 * ===================================================================== */

/* the SCOPE values of the forms: 1 ALL, 2 NEXT, 3 REST, 4 RECORD. The screen
 * names them with RpScopeText() (bp_cmds.prg); these four are the NUMBERING
 * itself, repeated because a .prg does not see the #define of another one. */
#define AP_SC_ALL    1
#define AP_SC_NEXT   2
#define AP_SC_REST   3
#define AP_SC_REC    4

/* the stops of the Append From ring, in VISUAL order: the same numbering the
 * form of bp_cmds.prg paints and walks */
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

/* the Count of the SCOPE exists only with NEXT and RECORD. RpScopeNeedsCount()
 * (bp_cmds.prg) -the door the Replace form and this screen use- answers with
 * THIS function, so the ring and the painting cannot disagree about it */
FUNCTION ApScopeNeedsCount( nScope )
RETURN nScope == AP_SC_NEXT .OR. nScope == AP_SC_REC

/* ---------- the rules of the Append From form (S19) ---------- */

/* the text of the FIELDS chip: `All Fields` while every field of the source is
 * ticked (which is also what an empty source shows) and `N of M Fields`
 * otherwise (S8) */
FUNCTION ApFieldsText( aSel, nTotal )
   LOCAL n := ApSelCount( aSel ), m
   m := iif( ValType( nTotal ) == "N" .AND. nTotal > 0, Int( nTotal ), ;
             iif( HB_ISARRAY( aSel ), Len( aSel ), 0 ) )
   IF m <= 0 .OR. n == m
      RETURN "All Fields"
   ENDIF
RETURN LTrim( Str( n ) ) + " of " + LTrim( Str( m ) ) + " Fields"

/* how many boxes of the selector are ticked */
FUNCTION ApSelCount( aSel )
   LOCAL i, n := 0
   IF ! HB_ISARRAY( aSel )
      RETURN 0
   ENDIF
   FOR i := 1 TO Len( aSel )
      IF ValType( aSel[ i ] ) == "L" .AND. aSel[ i ]
         n++
      ENDIF
   NEXT
RETURN n

/* a NEW selection of nTotal boxes, all in the same state: in Harbour an array
 * is a REFERENCE, so a selection is never handed back by alias (trap 67) */
STATIC FUNCTION ApSelMake( nTotal, lOn )
   LOCAL a := {}, i, n
   n := iif( ValType( nTotal ) == "N" .AND. nTotal > 0, Int( nTotal ), 0 )
   FOR i := 1 TO n
      AAdd( a, lOn )
   NEXT
RETURN a

FUNCTION ApSelAll( aSel, nTotal )
   LOCAL n
   n := iif( ValType( nTotal ) == "N" .AND. nTotal > 0, Int( nTotal ), ;
             iif( HB_ISARRAY( aSel ), Len( aSel ), 0 ) )
RETURN ApSelMake( n, .T. )

FUNCTION ApSelNone( aSel, nTotal )
   LOCAL n
   n := iif( ValType( nTotal ) == "N" .AND. nTotal > 0, Int( nTotal ), ;
             iif( HB_ISARRAY( aSel ), Len( aSel ), 0 ) )
RETURN ApSelMake( n, .F. )

/* one box toggled, as a NEW array: the one handed over is never touched */
FUNCTION ApSelToggle( aSel, nRow )
   LOCAL a := {}, i, n, lOn
   IF ! HB_ISARRAY( aSel )
      RETURN a
   ENDIF
   n := iif( ValType( nRow ) == "N", Int( nRow ), 0 )
   FOR i := 1 TO Len( aSel )
      lOn := ( ValType( aSel[ i ] ) == "L" .AND. aSel[ i ] )
      IF i == n
         lOn := ! lOn
      ENDIF
      AAdd( a, lOn )
   NEXT
RETURN a

/* S13: the field of the TARGET a selected field of the SOURCE lands on, matched
 * BY NAME and without case; "" when the target does not have it */
FUNCTION ApFieldNameOk( cName, aTargetFlds )
   LOCAL c, i, x
   IF ! HB_ISSTRING( cName ) .OR. ! HB_ISARRAY( aTargetFlds )
      RETURN ""
   ENDIF
   c := Upper( AllTrim( cName ) )
   IF Len( c ) == 0
      RETURN ""
   ENDIF
   FOR i := 1 TO Len( aTargetFlds )
      x := aTargetFlds[ i ]
      IF ValType( x ) == "C" .AND. Upper( AllTrim( x ) ) == c
         RETURN x
      ENDIF
   NEXT
RETURN ""

/* S11: a FOR / WHILE of the SOURCE compiled ONCE, before touching a record.
 * NIL comes back with cErr = NIL for an empty box (it means "no condition") */
FUNCTION ApCondBlock( cExpr, cErr, cName )
   LOCAL b := NIL, oErr
   DEFAULT cName TO "FOR/WHILE"
   cErr := NIL
   IF ! HB_ISSTRING( cExpr ) .OR. Len( AllTrim( cExpr ) ) == 0
      RETURN NIL
   ENDIF
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      b := &( "{|| " + cExpr + " }" )
   RECOVER USING oErr
      cErr := "The " + cName + " condition does not compile:" + hb_eol() + ;
              oErr:Description
      b := NIL
   END SEQUENCE
RETURN b

/* S5: the path of the source in its two halves, `{ cDir, cName }`, so the
 * Browse button can fill the two inputs and HcJoinPath() rebuilds the path the
 * picker answered */
FUNCTION ApSplitPath( cPath )
   LOCAL c, n
   IF ! HB_ISSTRING( cPath )
      RETURN { "", "" }
   ENDIF
   c := AllTrim( cPath )
   IF Len( c ) == 0
      RETURN { "", "" }
   ENDIF
   /* a trailing separator is "this directory": there is no name in it */
   IF Right( c, 1 ) == "\" .OR. Right( c, 1 ) == "/"
      RETURN { c, "" }
   ENDIF
   n := Max( Rat( "\", c ), Rat( "/", c ) )
   IF n <= 0
      RETURN { "", c }
   ENDIF
RETURN { Left( c, n ), SubStr( c, n + 1 ) }

/* S136: a DIRECTORY with its trailing separator and its `.` and `..` resolved
 * TEXTUALLY: nothing is read from the disk, so it also answers for a directory
 * that does not exist yet, which is exactly the question "where is this file
 * going to be created". The root is respected: `..` in `C:\` stays in `C:\`,
 * and in a UNC path it never climbs above `\\SERVER\SHARE`. `""` answers `""`
 * (there is no directory to promise). */
FUNCTION UiDirNorm( cDir )
   LOCAL cSrc, aPart := {}, aOut := {}, c := "", i, ch, nRoot := 0
   IF ! HB_ISSTRING( cDir )
      RETURN ""
   ENDIF
   cSrc := AllTrim( cDir )
   IF Len( cSrc ) == 0
      RETURN ""
   ENDIF
   /* the anchor that `..` can never pop: the UNC server + share, or the drive */
   IF SubStr( cSrc, 1, 2 ) == "\\"
      nRoot := 2
   ELSEIF SubStr( cSrc, 2, 1 ) == ":"
      nRoot := 1
   ENDIF
   /* the path is split BY HAND on both separators. hb_ATokens() is NOT used
    * here because in this build a delimiter list that carries a backslash does
    * not split at all (measured: it answered the whole path as ONE token, so
    * `..` was never resolved), and an empty field -`C:\work\` ends in a
    * separator- has to be dropped instead of becoming a part. */
   c := ""
   FOR i := 1 TO Len( cSrc )
      ch := SubStr( cSrc, i, 1 )
      IF ch == "\" .OR. ch == "/"
         IF Len( c ) > 0
            AAdd( aPart, c )
         ENDIF
         c := ""
      ELSE
         c += ch
      ENDIF
   NEXT
   IF Len( c ) > 0
      AAdd( aPart, c )
   ENDIF
   FOR i := 1 TO Len( aPart )
      c := aPart[ i ]
      DO CASE
      CASE c == "."
         /* this directory: nothing to add */
      CASE c == ".."
         IF Len( aOut ) > nRoot
            ASize( aOut, Len( aOut ) - 1 )
         ENDIF
      OTHERWISE
         AAdd( aOut, c )
      ENDCASE
   NEXT
   c := ""
   FOR i := 1 TO Len( aOut )
      c += aOut[ i ] + "\"
   NEXT
   IF nRoot == 2
      c := "\\" + c
   ENDIF
RETURN c

/* S136: the DIRECTORY where a file typed in a form will be created. `cName` is
 * what the user typed and `cBase` the directory of the session, the one a bare
 * name falls in. The answer is ABSOLUTE and carries its trailing separator, so a
 * screen can show it as it is; when there is nothing to resolve -a bare name and
 * no base- it answers `""` and the caller shows that it does not know. */
FUNCTION UiNewFileDir( cName, cBase )
   LOCAL aSp, cDir
   DEFAULT cBase TO ""
   aSp := ApSplitPath( iif( HB_ISSTRING( cName ), cName, "" ) )
   cDir := aSp[ 1 ]
   IF Len( cDir ) == 0
      RETURN UiDirNorm( cBase )
   ENDIF
   /* a drive or a UNC share is already absolute: the base does not apply */
   IF SubStr( cDir, 2, 1 ) == ":" .OR. SubStr( cDir, 1, 2 ) == "\\"
      RETURN UiDirNorm( cDir )
   ENDIF
   IF Len( UiDirNorm( cBase ) ) == 0
      /* a relative directory with no base is relative to the directory the
       * program runs in, which is what the operating system would use */
      RETURN UiDirNorm( cDir )
   ENDIF
RETURN UiDirNorm( UiDirNorm( cBase ) + cDir )

/* S136: the NAME of the file a form is going to create, out of what the user
 * typed: the last component, with `.DBF` when it carries no extension. The
 * extension is decided by the NAME and not by the whole path, so `my.dir\x` -
 * a directory with a dot in it- still gets one; `""` answers `""` and the
 * caller asks for a name. */
FUNCTION UiNewFileName( cTyped )
   LOCAL cName := AllTrim( ApSplitPath( iif( HB_ISSTRING( cTyped ), cTyped, "" ) )[ 2 ] )
   IF Len( cName ) == 0
      RETURN ""
   ENDIF
   IF ! ( "." $ cName )
      cName += ".DBF"
   ENDIF
RETURN cName

/* S10: whether the record at the ABSOLUTE position nRec of the SOURCE belongs to
 * the SCOPE. The walk starts at the top of the source -it is a file that was
 * just opened-, so ALL and REST cover the whole file, NEXT n is its first n
 * records and RECORD n is that one record */
FUNCTION ApQualify( nRec, nScope, nCount )
   LOCAL n, c
   IF ValType( nRec ) != "N"
      RETURN .F.
   ENDIF
   n := Int( nRec )
   c := iif( ValType( nCount ) == "N", Int( nCount ), 0 )
   IF n < 1
      RETURN .F.
   ENDIF
   DO CASE
   CASE nScope == AP_SC_NEXT
      RETURN c > 0 .AND. n <= c
   CASE nScope == AP_SC_REC
      RETURN c > 0 .AND. n == c
   ENDCASE
RETURN .T.

/* the ring of the form: ONE step and ONE skip rule -the Count exists only with
 * NEXT and RECORD, which is what ApScopeNeedsCount() answers- */
FUNCTION ApFocusStep( nFrom, nDir, nScope )
   LOCAL n, i, d
   n := iif( ValType( nFrom ) == "N" .AND. nFrom >= 1 .AND. ;
             nFrom <= AP_FOC_MAX, Int( nFrom ), AP_FOC_PATH )
   d := iif( ValType( nDir ) == "N" .AND. nDir < 0, -1, 1 )
   FOR i := 1 TO AP_FOC_MAX
      n += d
      IF n > AP_FOC_MAX
         n := AP_FOC_PATH
      ENDIF
      IF n < AP_FOC_PATH
         n := AP_FOC_MAX
      ENDIF
      IF n == AP_FOC_CNT .AND. ! ApScopeNeedsCount( nScope )
         LOOP
      ENDIF
      RETURN n
   NEXT
RETURN n

/* S7: the structure of a .DBF read from its own HEADER, WITHOUT opening the
 * file in a work area. Answers { { cName, cType, nLen, nDec }, ... } - the
 * shape StructConvert() already takes - or {} when the file is not a database
 * this build can read (not there, too short, no field descriptor) */
FUNCTION ApReadStruct( cFile )
   LOCAL a := {}, nH := -1, cBuf := Space( 0 ), nHdr := 0, nOff := 0
   LOCAL cName, lOk := .F., lDone := .F.
   IF ! HB_ISSTRING( cFile ) .OR. Len( AllTrim( cFile ) ) == 0
      RETURN a
   ENDIF
   IF ! hb_FNameExists( cFile )
      RETURN a
   ENDIF
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      nH := FOpen( cFile, FO_READ )
      IF nH != -1
         cBuf := Space( 32 )
         IF FRead( nH, @cBuf, 32 ) == 32
            nHdr := Asc( SubStr( cBuf, 9, 1 ) ) + Asc( SubStr( cBuf, 10, 1 ) ) * 256
            IF nHdr >= 33
               FSeek( nH, 32 )
               cBuf := Space( nHdr - 32 )
               FRead( nH, @cBuf, nHdr - 32 )
               lOk := .T.
            ENDIF
         ENDIF
         FClose( nH )
         nH := -1
      ENDIF
      IF lOk
         nOff := 1
         DO WHILE nOff + 31 <= Len( cBuf ) .AND. ! lDone
            IF Asc( SubStr( cBuf, nOff, 1 ) ) == 13
               lDone := .T.
            ELSE
               cName := SubStr( cBuf, nOff, 11 )
               IF At( Chr( 0 ), cName ) > 0
                  cName := Left( cName, At( Chr( 0 ), cName ) - 1 )
               ENDIF
               cName := AllTrim( cName )
               IF Len( cName ) > 0
                  AAdd( a, { Upper( cName ), SubStr( cBuf, nOff + 11, 1 ), ;
                             Asc( SubStr( cBuf, nOff + 16, 1 ) ), ;
                             Asc( SubStr( cBuf, nOff + 17, 1 ) ) } )
               ENDIF
               nOff += 32
            ENDIF
         ENDDO
      ENDIF
   RECOVER
      IF nH != -1
         FClose( nH )
      ENDIF
      a := {}
   END SEQUENCE
RETURN a


/* S7: the cell width the FIELDS chip needs. The widest text ApFieldsText() can
 * answer is "NNN of MMM Fields" -a .DBF tops at 255 fields and 255 of 255 reads
 * "All Fields"-, which is 17 cells, plus one of breathing room. It is a function
 * and not a constant of the screen so the bank can compare it with the text
 * itself: a chip narrower than its own text would clip it. */
FUNCTION ApFieldsWidth()
RETURN Len( "000 of 000 Fields" ) + 1


/* =====================================================================
 *  The SIMPLE PICKER of the Append From form (odd/tasks/append-from-form.md S21)
 * ---------------------------------------------------------------------
 *  The form's [ Browse ] used to nest the Harbour Commander; L7 asked for a
 *  plain browser of drives, directories and *.DBF files. These are the rules it
 *  needs that can be decided WITHOUT a window, so the headless bank pins them:
 *  which names are listed and in which order, where "up" stops, and the text of
 *  one row. The dialog itself lives in bp_cmds.prg.
 * ===================================================================== */

/* a name the picker lists: *.DBF, without case. A directory is a directory
 * whatever it is called, so the caller asks its attribute FIRST and this rule
 * only sees file names. */
FUNCTION ApPkIsDbf( cName )
   IF ! HB_ISSTRING( cName )
      RETURN .F.
   ENDIF
   cName := AllTrim( cName )
RETURN Len( cName ) > 4 .AND. Upper( Right( cName, 4 ) ) == ".DBF"

/* is there a row to go UP to? Never above the root of a drive nor above the
 * root of a UNC share, which are their own parent */
FUNCTION ApPkUpOk( cDir )
   LOCAL c, i, n
   IF ! HB_ISSTRING( cDir )
      RETURN .F.
   ENDIF
   c := AllTrim( cDir )
   IF Len( c ) == 0
      RETURN .F.
   ENDIF
   /* a drive root: the letter, the colon and ONE separator */
   IF Len( c ) == 3 .AND. SubStr( c, 2, 1 ) == ":" .AND. Right( c, 1 ) == "\"
      RETURN .F.
   ENDIF
   /* a UNC share root: two leading separators, the SERVER, the SHARE and not one
    * separator more (the trailing one is not a level). The separators are
    * counted by hand because hb_ATokens() decides emptiness on its own. */
   IF Len( c ) > 1 .AND. ( Right( c, 1 ) == "\" .OR. Right( c, 1 ) == "/" )
      c := Left( c, Len( c ) - 1 )
   ENDIF
   IF Left( c, 2 ) == "\\"
      n := 0
      FOR i := 3 TO Len( c )
         IF SubStr( c, i, 1 ) == "\" .OR. SubStr( c, i, 1 ) == "/"
            n++
         ENDIF
      NEXT
      IF n <= 1
         RETURN .F.
      ENDIF
   ENDIF
RETURN .T.

/* the directory ABOVE cDir, with its trailing separator. At the top it answers
 * the directory itself, so a caller that asks anyway cannot build a path above
 * it or "C:" (HcParentDir() of bp_hc.prg is the panel rule and is not UNC
 * safe) */
FUNCTION ApPkParent( cDir )
   LOCAL c, n
   IF ! HB_ISSTRING( cDir )
      RETURN ""
   ENDIF
   c := AllTrim( cDir )
   IF Len( c ) == 0
      RETURN c
   ENDIF
   IF ! ApPkUpOk( c )
      RETURN c
   ENDIF
   IF Right( c, 1 ) == "\" .OR. Right( c, 1 ) == "/"
      c := Left( c, Len( c ) - 1 )
   ENDIF
   n := Max( Rat( "\", c ), Rat( "/", c ) )
   IF n <= 0
      RETURN c
   ENDIF
RETURN Left( c, n )

/* the rows of the list, out of what hb_vfDirectory()/hb_DirScan() answered:
 * `{ { cName, nSize, xDate, lDir }, ... }`. `.` and `..` of the scan are
 * dropped (the picker has its own ".."), only directories and *.DBF files
 * survive, and the order is the one of the panels: **directories first and by
 * name**, then the files by name, both without case. With lUp the ".." row goes
 * on top, whatever the other rows are. */
FUNCTION ApPkRows( aRaw, lUp )
   LOCAL aDir := {}, aFil := {}, a := {}, i, aE, cName, cAttr, nSize, xDate
   IF HB_ISARRAY( aRaw )
      FOR i := 1 TO Len( aRaw )
         aE := aRaw[ i ]
         IF ! HB_ISARRAY( aE ) .OR. Len( aE ) < 1 .OR. ValType( aE[ 1 ] ) != "C"
            LOOP
         ENDIF
         cName := AllTrim( aE[ 1 ] )
         IF Len( cName ) == 0 .OR. cName == "." .OR. cName == ".."
            LOOP
         ENDIF
         cAttr := iif( Len( aE ) >= 5, aE[ 5 ], "A" )
         IF ValType( cAttr ) == "C" .AND. "D" $ Upper( cAttr )
            AAdd( aDir, { cName, 0, NIL, .T. } )
            LOOP
         ENDIF
         IF ! ApPkIsDbf( cName )
            LOOP
         ENDIF
         nSize := iif( Len( aE ) >= 2 .AND. ValType( aE[ 2 ] ) == "N", aE[ 2 ], 0 )
         xDate := iif( Len( aE ) >= 3, aE[ 3 ], NIL )
         AAdd( aFil, { cName, nSize, xDate, .F. } )
      NEXT
   ENDIF
   ASort( aDir, , , {| x, y | Upper( x[ 1 ] ) < Upper( y[ 1 ] ) } )
   ASort( aFil, , , {| x, y | Upper( x[ 1 ] ) < Upper( y[ 1 ] ) } )
   IF lUp
      AAdd( a, { "..", 0, NIL, .T. } )
   ENDIF
   FOR i := 1 TO Len( aDir )
      AAdd( a, aDir[ i ] )
   NEXT
   FOR i := 1 TO Len( aFil )
      AAdd( a, aFil[ i ] )
   NEXT
RETURN a

/* the size column of one row: "DIR" for a directory (and for ".."), the digits
 * for a file. The caller pads it to the right the column, so the rule cannot
 * depend on the width of the dialog */
FUNCTION ApPkSizeText( aRow )
   IF ! HB_ISARRAY( aRow ) .OR. Len( aRow ) < 2
      RETURN ""
   ENDIF
   IF Len( aRow ) >= 4 .AND. ValType( aRow[ 4 ] ) == "L" .AND. aRow[ 4 ]
      RETURN "DIR"
   ENDIF
   IF ValType( aRow[ 2 ] ) != "N"
      RETURN ""
   ENDIF
RETURN LTrim( Str( Int( aRow[ 2 ] ) ) )

/* the date column of one row: DD/MM/YY in 8 cells, the layout of the panels
 * (L24 of hc-commander.md). hb_vfDirectory()/hb_DirScan() hand the date over as
 * a TIMESTAMP ("T"), measured, so both shapes are accepted; anything else, an
 * empty date included, gives eight blanks - which is what ".." shows */
FUNCTION ApPkDateText( xDate )
   LOCAL d
   IF ValType( xDate ) == "T"
      d := hb_TToD( xDate )
   ELSEIF ValType( xDate ) == "D"
      d := xDate
   ELSE
      RETURN Space( 8 )
   ENDIF
   IF Empty( d )
      RETURN Space( 8 )
   ENDIF
RETURN StrZero( Day( d ), 2 ) + "/" + StrZero( Month( d ), 2 ) + "/" + ;
       SubStr( StrZero( Year( d ), 4 ), 3, 2 )

/* one row of the list: the name in nWName cells, one blank, the size RIGHT in
 * 10, one blank and the date in 8 - the columns of the panels. ".." is written
 * "[..]" and carries NO size and NO date (S21). */
FUNCTION ApPkRowText( aRow, nWName )
   LOCAL cName := "", cDate := Space( 8 )
   DEFAULT nWName TO 24
   IF HB_ISARRAY( aRow ) .AND. Len( aRow ) >= 1 .AND. ValType( aRow[ 1 ] ) == "C"
      cName := AllTrim( aRow[ 1 ] )
   ENDIF
   IF cName == ".."
      RETURN PadR( "[..]", nWName ) + " " + Space( 10 ) + " " + Space( 8 )
   ENDIF
   IF HB_ISARRAY( aRow ) .AND. Len( aRow ) >= 3
      cDate := ApPkDateText( aRow[ 3 ] )
   ENDIF
RETURN PadR( Left( cName, nWName ), nWName ) + " " + ;
       PadL( ApPkSizeText( aRow ), 10 ) + " " + ;
       PadR( Left( cDate, 8 ), 8 )

/* The ACTION a footer chip of the Append From form ANNOUNCES, by the name of the
 * key painted on it. A chip name is NOT always a key that screen can resolve by
 * its code: `Ctrl-S` arrives as code 19, which is also `K_LEFT` (trap 71), so
 * handing it to the key table would step the focus BACKWARDS instead of running
 * the Accept the chip announces. The click asks for the ACTION by name instead,
 * and the names are the same ones the keyboard and the [ Accept ] button answer,
 * so a click and a key cannot do two different things (S3 and L8 of
 * append-from-form.md: the mouse has to work on every screen, and it has to do
 * what the keyboard does).
 * Anything else answers "": an unknown chip does nothing rather than inventing an
 * action nobody wrote. */
FUNCTION ApHintAct( cKey )
   LOCAL cName
   IF ! HB_ISSTRING( cKey )
      RETURN ""
   ENDIF
   cName := AllTrim( cKey )
   DO CASE
   CASE cName == "Tab"    ; RETURN "focus"
   CASE cName == "Ctrl-S" ; RETURN "run"
   CASE cName == "Alt-B"  ; RETURN "browse"
   CASE cName == "Alt-F"  ; RETURN "fields"
   CASE cName == "F1"     ; RETURN "help"
   CASE cName == "Esc"    ; RETURN "cancel"
   ENDCASE
RETURN ""
