/*
 * bp_def.ch - Common definitions of the hwBro clone
 */
#ifndef BP_DEF_CH
#define BP_DEF_CH

#include "common.ch"
#include "set.ch"
#include "ord.ch"

/* =====================================================================
 *  Palette matched to the original BroPlus (measured on its screenshots):
 *    background      black on light gray        N/W
 *    boxes/menus     black on cyan              N/BG
 *    menu bar        black on gray              N/W  (active: white/cyan)
 *    menu selection  black on brown             N/GR
 *    list selection  black on yellow            N/GR+
 *    current record  black on bright red        N/R+
 *    green bars      black on green             N/G
 * ===================================================================== */
#define TC_DESKTOP       1
#define UI_C_DESKTOP     UiC( TC_DESKTOP )
#define TC_MENUBAR       2
#define UI_C_MENUBAR     UiC( TC_MENUBAR )  /* menu bar: dark gray background (measured) */
#define TC_MENUKEY       3
#define UI_C_MENUKEY     UiC( TC_MENUKEY )  /* F1..F9: white on dark gray (measured) */
#define TC_MENULBL       4
#define UI_C_MENULBL     UiC( TC_MENULBL )  /* labels: black on cyan, chip (measured) */
#define TC_MENUACT       5
#define UI_C_MENUACT     UiC( TC_MENUACT )  /* active label: white on RED (measured) */
#define TC_DARK          6
#define UI_C_DARK        UiC( TC_DARK )  /* inside of the selection boxes (dark gray) */
#define TC_FRAME1        7
#define UI_C_FRAME1      UiC( TC_FRAME1 )  /* white frame (left panel) */
#define TC_FRAME2        8
#define UI_C_FRAME2      UiC( TC_FRAME2 )  /* yellow frame (right panel) */
#define TC_CHIP          9
#define UI_C_CHIP        UiC( TC_CHIP )  /* label chip: C:\  *.DBF */
#define TC_SHADOWBLK     10
#define UI_C_SHADOWBLK   UiC( TC_SHADOWBLK )  /* black shadow of the boxes */
#define TC_SELITEM       11
#define UI_C_SELITEM     UiC( TC_SELITEM )  /* selected item: black on yellow */
#define TC_PICKED        12
#define UI_C_PICKED      UiC( TC_PICKED )  /* open tables: yellow on dark gray */
#define TC_BOX           13
#define UI_C_BOX         UiC( TC_BOX )
#define TC_BOXBORD       14
#define UI_C_BOXBORD     UiC( TC_BOXBORD )
#define TC_BOXSEL        15
#define UI_C_BOXSEL      UiC( TC_BOXSEL )  /* selected option: WHITE on brown
                                             * (measured on BRO.EXE: the text of the
                                             * highlighted option is white, not black) */
#define TC_LISTSEL       16
#define UI_C_LISTSEL     UiC( TC_LISTSEL )  /* yellow: RB is remapped in the palette */
#define TC_HOT           17
#define UI_C_HOT         UiC( TC_HOT )  /* item hot key: YELLOW (measured) */
#define TC_HOTON         18
#define UI_C_HOTON       UiC( TC_HOTON )  /* hot key on dark gray: yellow */
#define TC_BOXDIM        19
#define UI_C_BOXDIM      UiC( TC_BOXDIM )  /* option/label not available: gray on cyan */
#define TC_FIELDBG       20
#define UI_C_FIELDBG     UiC( TC_FIELDBG )  /* fixed SOFT background of the two search
                                              * fields of the File search form (S19):
                                              * black on light gray, the softest of the
                                              * eight palette backgrounds. It is NOT the
                                              * focus colour, which stays UI_C_LISTSEL. */
#define TC_FLATBG        21
#define UI_C_FLATBG      UiC( TC_FLATBG )  /* resting pair of a FLAT control of a form
                                             * (checkbox label, button label), S19/L14:
                                             * bright white on the box background, i.e.
                                             * NO band. The state is told by the text
                                             * (the `[X]`/`[ ]` of a box, the brackets of
                                             * a button) and the focus colour, never by
                                             * a background: only the inputs carry one. */
#define TC_HOTSEL        22
#define UI_C_HOTSEL      UiC( TC_HOTSEL )  /* hot key inside the selected item */
#define TC_SHADOW        23
#define UI_C_SHADOW      UiC( TC_SHADOW )  /* shadow: dark gray blocks (measured) */
#define TC_ERR           24
#define UI_C_ERR         UiC( TC_ERR )
#define TC_STATUS        25
#define UI_C_STATUS      UiC( TC_STATUS )  /* bottom border: Directory: ... white/dark gray */
#define TC_STATUSBAR     26
#define UI_C_STATUSBAR   UiC( TC_STATUSBAR )
#define TC_INPUT         27
#define UI_C_INPUT       UiC( TC_INPUT )
#define TC_HDR           28
#define UI_C_HDR         UiC( TC_HDR )  /* column headers: black on gray (measured) */
#define TC_HDRSEL        29
#define UI_C_HDRSEL      UiC( TC_HDRSEL )
#define TC_REC           30
#define UI_C_REC         UiC( TC_REC )
#define TC_RECSEL        31
#define UI_C_RECSEL      UiC( TC_RECSEL )  /* current record: white text on red */
/* T5 (S9 of hc-tree-panel.md): the DIM pair of a panel BODY - the guide of the
 * folder tree and the marker of a known leaf. Dim text on the same dark gray of
 * the body, i.e. the SAME palette pair UI_C_CODECMT already uses for comments
 * (W = 170,170,170 over B = 85,85,85): no new colour, and the guide stays a
 * subtle line instead of the saturated cyan band UI_C_BOXDIM would paint
 * (measured on the tree capture of T5). */
#define TC_DIM           32
#define UI_C_DIM         UiC( TC_DIM )
#define TC_RECDEL        33
#define UI_C_RECDEL      UiC( TC_RECDEL )  /* record marked as deleted: DIM (dark gray
                                             * letters on light gray). No new palette
                                             * entry: the same pair the Compare view
                                             * already uses for its dim text. */
#define TC_CURSEL        34
#define UI_C_CURSEL      UiC( TC_CURSEL )  /* cursor cell: black text on green */
#define TC_EDIT          35
#define UI_C_EDIT        UiC( TC_EDIT )  /* inline editing cell: black on YELLOW (measured);
                                           * in the original it is GR+ = 255,255,85 = the same RB */
#define TC_TITLEBAR      36
#define UI_C_TITLEBAR    UiC( TC_TITLEBAR )  /* title and "Key: (...)" bar in white on black */
#define TC_GREEN         37
#define UI_C_GREEN       UiC( TC_GREEN )
#define TC_HINT          38
#define UI_C_HINT        UiC( TC_HINT )
#define TC_SPLASH        39
#define UI_C_SPLASH      UiC( TC_SPLASH )  /* splash background: cyan (the box color of the
                                             * program). It used to be bright green, which
                                             * looked too garish. */
#define TC_SPLFRM        40
#define UI_C_SPLFRM      UiC( TC_SPLFRM )  /* splash frame and logo: bright white */
#define TC_SPLSHD        41
#define UI_C_SPLSHD      UiC( TC_SPLSHD )  /* shadow (dark gray blocks) in the splash */
#define TC_SPLMSG        42
#define UI_C_SPLMSG      UiC( TC_SPLMSG )  /* splash highlight line: yellow */
#define TC_OKBTN         43
#define UI_C_OKBTN       UiC( TC_OKBTN )  /* OK button: red on light gray */

/* --- Structure editor (F2 Create/Modify Structure) -------------------
 * Measured on BRO.EXE: dark gray background, frame and header texts in BRIGHT
 * CYAN (85,255,255), field rows in white, and the current row with the NAME in
 * black on bright cyan and TYPE/LENGTH/DECIMALS highlighted in magenta
 * (170,0,170). The clone uses yellow instead of magenta because its palette
 * already spends index 5 on the yellow of the lists and of the inline editing
 * (both do not fit; see the note about the forms). */
#define TC_STBRD         44
#define UI_C_STBRD       UiC( TC_STBRD )  /* editor frame: bright cyan */
#define TC_STTIT         45
#define UI_C_STTIT       UiC( TC_STTIT )  /* title, header and total line */
#define TC_STROW         46
#define UI_C_STROW       UiC( TC_STROW )  /* normal rows: white on gray */
/* --- Structure editor (F2 Create/Modify Structure) -------------------
 * Editor cursor: the cell of the current column (Name/Type/Len/Dec) in CYAN
 * (the original paints it in bright cyan 85,255,255 and the other three cells
 * of the current field in magenta 170,0,170; the clone uses plain cyan and
 * yellow because its palette cannot hold both — see the background note). */
#define TC_STCUR         47
#define UI_C_STCUR       UiC( TC_STCUR )  /* cursor cell: black on cyan */
#define TC_STSEL         48
#define UI_C_STSEL       UiC( TC_STSEL )  /* other cells of the current field: black on
                                            * brown (readable; the original paints them
                                            * in magenta with white text) */

/* --- Forms (input dialogs) of the original ---------------------------
 * Measured on BRO.EXE: box with a BRIGHT BLUE background (85,85,255), double
 * information lines in YELLOW (255,255,85) and editable fields in BRIGHT
 * GREEN (85,255,85) with black text.
 * LIMITATION: GTWVG in Harbour only allows 8 BACKGROUND colors (the "+" of a
 * background color applies to the TEXT, not to the background: "N/B+" = bright
 * blue text on a blue background). The clone already uses the 8 backgrounds
 * (black, gray, green, cyan, red, yellow, brown and light gray) to match the
 * colors of the original, so the bright blue of the interior does not fit:
 * dark gray with white text is used instead. What IS identical is the FIELD
 * (bright green 85,255,85) and the bright blue frame. Should the blue of the
 * original ever be preferred, another background would have to go. */
#define TC_DLG           49
#define UI_C_DLG         UiC( TC_DLG )  /* form interior: white on dark gray */
#define TC_DLGBRD        50
#define UI_C_DLGBRD      UiC( TC_DLGBRD )  /* form frame: bright blue (like the original) */
#define TC_DLGINFO       51
#define UI_C_DLGINFO     UiC( TC_DLGINFO )  /* information line: yellow on gray */
#define TC_DLGFIELD      52
#define UI_C_DLGFIELD    UiC( TC_DLGFIELD )  /* editable field: black on bright green (identical) */
#define TC_DLGRED        53
#define UI_C_DLGRED      UiC( TC_DLGRED )  /* directory field: white on RED
                                             * (measured in the Change Directory form) */

/* --- F3 Tag Selection/Information (replica of the original) ----------
 * The original paints that box with a BRIGHT BLUE background and BLACK text; the
 * clone has no blue background (see the note about the forms) and uses dark gray
 * with white text, the frame and the separators in bright blue
 * (UI_C_DLGBRD), the title and the values in yellow (UI_C_DLGINFO), the cursor
 * row in yellow (UI_C_LISTSEL) and the hints in cyan chips
 * (UI_C_CHIP / UI_C_MENUKEY).
 * The only measured detail with NO known meaning: the solid block of
 * row 12 column 40 (Descending column) is BROWN (170,85,0) in CLIENTES and
 * DARK BLUE (0,0,170) in ARTICULO, but it does not follow the cursor, the
 * scroll, the tag or the order (DBOI_ISDESC returns .F. in CLIENTES and the
 * original paints it brown anyway). It is always painted brown: dark blue does
 * not fit in the palette (B is remapped to dark gray) and brown is the value
 * measured on the reference table with more tags. */
#define TC_TAGDESC       54
#define UI_C_TAGDESC     UiC( TC_TAGDESC )  /* solid block of (12,40): brown (measured) */

/* --- F3 Index File Selection Screen (Alt-F3) -------------------------
 * MEASURED on BRO.EXE (_reversing/capturas/o6-idxsel-06-op1.png and
 * o8-idxpick-06-op2.png): the screen is the SAME as the Database Selection
 * Screen of F2 (boxes rows 5..21 in columns 11..26 and 51..67, black shadow
 * of 2 columns, "Selected" on row 4, row 23 with "Key: (...)" and
 * "Driver:" and row 24 with the hints), with these measured differences:
 *   · the frame of the right panel and the names of the open indexes are in
 *     BRIGHT CYAN (85,255,255) — on the database screen the frame is
 *     yellow and the text is yellow;
 *   · the highlighted item of the left panel is BLACK on BRIGHT CYAN
 *     (85,255,255) — on the database screen it is black on yellow;
 *   · the centre of row 3 shows the ALIAS in BROWN (170,85,0) on the
 *     light gray background of the screen.
 * LIMITATION (see the background note of the forms): GTWVG only gives 8
 * BACKGROUND colors, so bright cyan does NOT fit as a background and the
 * highlighted item is approximated with the base cyan (0,170,170), which is the
 * same background the boxes and chips already use. As TEXT (frame and names)
 * bright cyan IS identical (index 11 of the palette). */
#define TC_IDXSEL        55
#define UI_C_IDXSEL      UiC( TC_IDXSEL )  /* highlighted item: black on cyan (approx.) */
#define TC_IDXFRM        56
#define UI_C_IDXFRM      UiC( TC_IDXFRM )  /* frame of the right panel: bright cyan */
#define TC_IDXITEM       57
#define UI_C_IDXITEM     UiC( TC_IDXITEM )  /* open indexes: bright cyan */
#define TC_IDXALIAS      58
#define UI_C_IDXALIAS    UiC( TC_IDXALIAS )  /* centred alias of row 3: brown (measured) */

/* --- Progress bar (long processes: Alt-M rewrites the whole table) ---
 * Cyan box like the rest of the dialogs, yellow title (the hot key color of
 * the menus), bright green bar and dark gray empty part. */
#define TC_PROGTIT       59
#define UI_C_PROGTIT     UiC( TC_PROGTIT )  /* title: yellow on cyan */
#define TC_PROGTXT       60
#define UI_C_PROGTXT     UiC( TC_PROGTXT )  /* counter and hint: black on cyan */
/* CAREFUL: the block characters are drawn with the TEXT color (not with the
 * background), so the full bar is BRIGHT green text (G+, index 10 =
 * 85,255,85) over the dark gray background; the empty one is that dark gray. */
#define TC_PROGBAR       61
#define UI_C_PROGBAR     UiC( TC_PROGBAR )  /* full bar: bright green blocks */
#define TC_PROGEMPTY     62
#define UI_C_PROGEMPTY   UiC( TC_PROGEMPTY )  /* empty bar: dark gray background */

/* --- Compare screen (odd/tasks/hc-compare.md S5, verdicts L6/L7) ------
 * The screen copies the compare of Visual Studio: a LIGHT background with
 * dark text, the difference told by a 1-cell bar in the left margin of the
 * line and, on a changed line, only the differing span highlighted. None of
 * these pairs is a new RGB and none is a numeric attribute: every one is
 * made of palette entries the program already uses, so the screen ends up
 * gray and black except for the 1-cell bar of a line and the yellow span
 * (L7: nothing loud). */
#define TC_CMPBODY       63
#define UI_C_CMPBODY     UiC( TC_CMPBODY )  /* text of every line, equal or not */
#define TC_CMPDIM        64
#define UI_C_CMPDIM      UiC( TC_CMPDIM )  /* line numbers, rules, separator, dim text */
#define TC_CMPMRKD       65
#define UI_C_CMPMRKD     UiC( TC_CMPMRKD )  /* margin bar of a left-only line */
#define TC_CMPMRKA       66
#define UI_C_CMPMRKA     UiC( TC_CMPMRKA )  /* margin bar of a right-only line */
#define TC_CMPMRKC       67
#define UI_C_CMPMRKC     UiC( TC_CMPMRKC )  /* margin bar of a changed line */
#define TC_CMPWORD       68
#define UI_C_CMPWORD     UiC( TC_CMPWORD )  /* the differing span (VS yellow) */
#define TC_CMPBAR        69
#define UI_C_CMPBAR      UiC( TC_CMPBAR )  /* summary and message rows */
#define TC_CMPON         70
#define UI_C_CMPON       UiC( TC_CMPON )  /* option chip, on */
#define TC_CMPOFF        71
#define UI_C_CMPOFF      UiC( TC_CMPOFF )  /* option chip, off */
#define TC_CMPTRACK      72
#define UI_C_CMPTRACK    UiC( TC_CMPTRACK )  /* scroll-bar track: Chr( 176 ) in dark gray */
#define TC_CMPTHUMB      73
#define UI_C_CMPTHUMB    UiC( TC_CMPTHUMB )  /* scroll-bar thumb: Chr( 178 ) of the same pair, so
                                               * the cell MEASURES as a mid gray (its dominant
                                               * pixel is 85,85,85 over the light gray of the
                                               * row) instead of the bright cyan stripe of
                                               * Chr( 219 ) + "BG/N" that L7 turned down. The
                                               * alternative pair "B/W" measures the same
                                               * pixels (B is remapped to 85,85,85 by
                                               * BpSetVgaPalette()), so the plain bright-black
                                               * of the palette is used, without depending on
                                               * the remap of B. */

/* value returned by StructApply() (bp_struct.prg) when the user cancels */
#define BP_STRUCT_CANCEL "CANCEL"

/* =====================================================================
 *  SCREEN CANVAS - native 120x44 redesign
 * =====================================================================
 * `hwBro` used to clone the fixed 80x25 text grid of BRO.EXE, and every box
 * carried the coordinate measured on that grid. The canvas is now a native
 * 120x44 grid and the screens are laid out for it, so the ORIGINAL
 * MEASUREMENTS ARE NO LONGER A LAYOUT CONTRACT: they still define the COLORS
 * (see UI_C_* above) and the functional behavior (menus, keys, texts), but not
 * the geometry.
 *
 * These two numbers are ONLY the requested mode for SetMode() in Main().
 * Everything else is DERIVED from MaxRow()/MaxCol() at runtime through the
 * UiRows()/UiCols()/UiCenterCol()/UiCenterRow()/UiFitCol()/UiFitRow() helpers
 * of bp_ui.prg, so resizing the canvas means changing just these two numbers.
 *
 * RULE: never write the grid size (80, 25, 79, 24) or a box cap that only
 * exists because the grid was 80x25 as a literal in drawing code.
 * ===================================================================== */
#define BP_SCR_ROWS     44
#define BP_SCR_COLS     120

/* Browser layout. The rows keep the structure of the original (they are the
 * same chrome: two menu rows, the bar strip, the title, the rules and the
 * headers) but they are anchored to the canvas instead of to the old 80x25
 * grid: the rules and bars run to MaxCol() and the record area ends at
 * MaxRow()-2. On the 120x44 canvas that is 35 record rows (7..41).
 *
 *   row 0-1  menu bar              row 4      single horizontal line  ─
 *   row 2    Rec./Lock/Shared/...  row 5      column headers
 *   row 3    title (ALIAS Ord Tag) row 6      double horizontal line  ═
 *   row 7..MaxRow()-2  records  ·  MaxRow()-1  hint  ·  MaxRow()  status */
#define BP_ROW_TITLE    2
#define BP_ROW_BARS     3
#define BP_ROW_LINE1    4
#define BP_ROW_HDR      5
#define BP_ROW_LINE2    6
#define BP_ROW_TOP      7
#define BP_COL_BASE     4       /* left margin before the 1st column */

#define BP_SEP_VERT     Chr( 179 )   /* │ */
#define BP_LINE_SINGLE  Chr( 196 )   /* ─ */
#define BP_LINE_DOUBLE  Chr( 205 )   /* ═ */

#define BP_VERSION      "3.00"
#define BP_APPNAME      "hwBro"

/* ---- code files of the Harbour Commander viewer/editor (S78..S80) ---------
 * The kind of a token of HcCodeTokens() in bp_hc.prg. They live here and not in
 * that module so the shared header is the one place that names them: a .prg
 * does not see another .prg's #define, and Harbour compiles an unknown
 * identifier as a MEMORY VARIABLE, so a missing one only blows up the first
 * time the tokenizer runs (measured: "Variable does not exist: HC_TOK_KEY").
 */
#define HC_TOK_PLAIN    1       /* ordinary text                          */
#define HC_TOK_KEY      2       /* reserved word of the language           */
#define HC_TOK_STR      3       /* string literal                          */
#define HC_TOK_CMT      4       /* comment                                 */
#define HC_TOK_NUM      5       /* number literal                          */
#define HC_TOK_FUNC     6       /* identifier that opens a parenthesis     */
#define HC_TOK_PRE      7       /* preprocessor directive (C/C++)          */

/* ---- what `Enter` on a FILE does (S81 of hc-enter-actions.md) -------------
 * The extension decides, never the content: a *.DBF goes back to the caller and
 * opens the Browse edit, an archive opens in the panel, a SCRIPT asks first and
 * then runs, and everything else is handed to the program Windows associates
 * with it. The list below is what "script" means here (shell associations that
 * EXECUTE something), so nothing is run without the confirmation box.
 */
#define HC_ENTER_OPEN   1       /* the Windows association decides         */
#define HC_ENTER_RUN    2       /* a script: ask, then run it              */
#define HC_ENTER_DBF    3       /* Browse edit (the caller opens the base)  */
#define HC_ENTER_ZIP    4       /* the archive opens IN the panel (S47)     */
#define HC_ENTER_SCRIPTS ",EXE,COM,BAT,CMD,PS1,PSM1,PY,PYW,JS,JSE,VBS,VBE,WSF,WSH,MSI,REG,CPL,SCR,HTA,"

/* ---- Find & Replace of the Harbour Commander editor (S3..S6, S9) --------
 * Three small models travel as ARRAYS so the engine of bp_hc.prg stays pure
 * over ( lines, matcher, options, scope ) and the future Files > Find and
 * Replace can reuse it unchanged (S9).
 *
 * The options array (HF_*): the first six are the checkboxes of the dialog and
 * HF_FIND/HF_REPL carry the two strings. The matcher array (HM_*) holds the
 * query, the flags, the compiled regex ONCE (never per line) and the "bad
 * pattern" flag. A scope is one { line1, col1, line2, col2 } with 1-based lines
 * and 0-based columns, the same units the editor uses. */
#define HF_CASE         1       /* Match case                              */
#define HF_WORD         2       /* Whole words only                        */
#define HF_RE           3       /* Regular expression                      */
#define HF_BACK         4       /* Backwards                               */
#define HF_WHOLE        5       /* Whole document (and wrap once)          */
#define HF_INSEL        6       /* In selection                            */
#define HF_FIND         7       /* the query string                        */
#define HF_REPL         8       /* the replacement text                    */
#define HM_PAT          1       /* the query string                        */
#define HM_CASE         2       /* Match case                              */
#define HM_WORD         3       /* Whole words only (never with a regex)   */
#define HM_RE           4       /* Regular expression                      */
#define HM_HANDLE       5       /* the compiled regex (pointer, or NIL)    */
#define HM_BAD          6       /* the pattern did not compile             */
#define HM_START        1       /* one match: 0-based start column         */
#define HM_LEN          2       /*             length in characters        */
#define HM_GROUPS       3       /*             { whole, $1.. } of the match */
#define HS_L1           1       /* one scope: first line (1-based)         */
#define HS_C1           2       /*            first column (0-based)       */
#define HS_L2           3       /*            last line (1-based)          */
#define HS_C2           4       /*            last column (0-based)        */

/* ---- the selection model of the editor (S7, S85) -------------------------
 * A selection uses the same { line1, col1, line2, col2 } shape and the same
 * units as a scope above, so `In selection` is a copy of it. HcSelSpan() has
 * no text in hand, so a span that runs to the END of its line answers this
 * value as its EXCLUSIVE end: the painter, which does have the line, turns it
 * into Len( cLine ). */
#define HC_SEL_EOL     -1       /* a span runs to the end of the line      */

/* longest history list of the Find / Replace dialog (S10): memory only */
#define HF_HIST_MAX    20

/* ---- editor undo/redo (S2 of odd/tasks/editor-undo-redo.md) --------------
 * ONE step of the history is a LINE-SPLICE record: the nOut rows that started
 * at line nAt BEFORE the edit, the nIn rows that started there AFTER it, and the
 * caret on both sides. Undo replaces aIn with aOut and redo the other way round,
 * so a typed character costs one line and only a bulk action (paste, cut,
 * Replace All) stores a whole block. There is NO level cap: the history is as
 * deep as the user keeps editing. */
#define HU_AT     1             /* first row (1-based) the record touches */
#define HU_OUT    2             /* rows there BEFORE the edit (array)     */
#define HU_IN     3             /* rows there AFTER the edit (array)      */
#define HU_ROW_B  4             /* caret row BEFORE (0-based on screen)   */
#define HU_COL_B  5             /* caret column BEFORE                    */
#define HU_ROW_A  6             /* caret row AFTER                        */
#define HU_COL_A  7             /* caret column AFTER                     */
#define HU_MERGE  8             /* may absorb the edit that follows it     */
#define HU_LEN    8

/* ---- Find / Replace dialog: the state array (S3, S10) --------------------
 * HcFindState() builds it and the dialog works on it. Slots 3..8 are the six
 * checkboxes in the order they are painted, slot 9 says whether the editor has
 * a selection (without one `In selection` is disabled) and slot 10 is the
 * message row. */
#define FS_FIND         1       /* the query                               */
#define FS_REPL         2       /* the replacement                         */
#define FS_CASE         3       /* Match case                              */
#define FS_WORD         4       /* Whole words only                        */
#define FS_RE           5       /* Regular expression                      */
#define FS_INSEL        6       /* In selection                            */
#define FS_BACK         7       /* Backwards                               */
#define FS_WHOLE        8       /* Whole document                          */
#define FS_HASEL        9       /* the editor has a selection              */
#define FS_MSG         10       /* the message row                         */

/* ---- Find / Replace: the state packet of ONE action (S2, S6) -------------
 * HcFindRun() applies ONE action of the dialog to the editor and answers this
 * packet, so the rule is pure (no UiMsg, no painting) and the headless bank
 * checks it. nRow/nCol are the 0-based screen row and column of the caret,
 * nTop is the 1-based first visible line and nLft the horizontal offset that
 * keeps the caret inside a window nW wide. */
#define FF_MSG          1       /* the message for the dialog              */
#define FF_A_LINES      2       /* the (new) buffer                        */
#define FF_A_SEL        3       /* the (new) selection, or NIL             */
#define FF_N_ROW        4       /* the screen row of the caret             */
#define FF_N_TOP        5       /* the first visible line                  */
#define FF_N_COL        6       /* the column of the caret                 */
#define FF_N_LFT        7       /* the horizontal offset of the window     */
#define FF_A_UNDO       8       /* the snapshot Ctrl-Z restores, or NIL    */
#define FF_L_MOD        9       /* the buffer is modified                  */

/* ---- File search of the file manager: the state array (S3) ---------------
 * ONE array is the whole form and the whole search (odd/tasks/hc-file-search.md
 * S3): HcFsState() builds it, the screen edits it in place and HcFsSaveState()/
 * HcFsRestore() remember it IN MEMORY for the session (nothing goes to disk,
 * the same decision as s_aHfChk of the editor). `HS_` is already taken by the
 * selection slots above, so the two limits of the scan carry the FS_ prefix. */
#define FSX_MASK        1       /* name mask (`*.*` by default)            */
#define FSX_DIR         2       /* folder to search in ("" = the caller's) */
#define FSX_MASKRE      3       /* the mask is a regular expression        */
#define FSX_ONLYSEL     4       /* only the entries marked in the panel     */
#define FSX_DEPTH       5       /* subdirectories: -1 all, 0 none, n levels */
#define FSX_TEXT        6       /* the text (or the bytes) to search        */
#define FSX_TXT         7       /* search by content                        */
#define FSX_WORD        8       /* whole words only                         */
#define FSX_CASE        9       /* match case                               */
#define FSX_RE         10       /* regular expression (content)             */
#define FSX_HEX        11       /* hexadecimal (bytes, binaries readable)   */
#define FSX_NOT        12       /* the files that do NOT contain the text   */
#define FSX_DATES      13       /* filter by a date range                   */
#define FSX_DATE1      14       /* from (Date or CToD( "" ) = no bound)     */
#define FSX_DATE2      15       /* to                                       */
#define FSX_DAYS       16       /* filter by age                            */
#define FSX_NDAYS      17       /* N days (a string: it is a field)         */
#define FSX_SIZE       18       /* filter by size                           */
#define FSX_SOP        19       /* "=", ">" or "<"                         */
#define FSX_SVAL       20       /* the value (a string: it is a field)      */
#define FSX_SUNIT      21       /* 1 bytes, 2 KiB, 3 MiB                    */
#define FSX_MSG        22       /* the message row                          */
/* the `Replace with:` line of the General tab, added AFTER the original slots so
 * the numbering 1..22 of S3 does not move (a session memory saved by an older
 * build still merges slot by slot): FSX_REPLON is the checkbox and FSX_REPL the
 * text. Both travel in the session memory like the rest of the options. */
#define FSX_REPLON     23       /* [ ] Replace with:                        */
#define FSX_REPL       24       /* the replacement text                     */

/* ---- F8 "SUM/AVERAGE": the state array (S2/S3, sum-average-form.md) -------
 * ONE array is the whole form (odd/tasks/sum-average-form.md): SmStateNew()
 * builds it, the screen edits it in place and SmSaveState() remembers the
 * values IN MEMORY for the session (nothing goes to disk, the same decision as
 * the LIST form). The field SELECTION is not remembered on purpose: its numbers
 * belong to the file that was open and would point at other fields here. */
#define SMX_EXPR        1       /* Field/Expression to SUM/AVERAGE (input)  */
#define SMX_SCOPE       2       /* ALL / NEXT / REST / RECORD               */
#define SMX_COUNT       3       /* the Count of NEXT and RECORD             */
#define SMX_WHILE       4       /* the WHILE condition                      */
#define SMX_FOR         5       /* the FOR condition                        */
#define SMX_SEL         6       /* the picked numeric fields, in order      */
#define SMX_FIELDS      7       /* the NUMERIC field names, file order      */
#define SMX_TYPES       8       /* their types                              */
#define SMX_LENS        9       /* their lengths                            */
#define SMX_DECS       10       /* their decimals                           */
#define SMX_FOCUS      11       /* the stop the focus is standing on        */
#define SMX_MSG        12       /* the message row                          */
#define SMX_ERR        13       /* the message row is an error (red)        */
#define SMX_MAX        13

/* the limits of a search (S8/S9): a file bigger than the first one is skipped
 * and counted apart (the same cap the text viewer uses), FS_LIM_FILES files are
 * visited at most and FS_LIM_RES results are listed at most; when a cap cuts
 * the search short the screen says so instead of pretending it finished. */
#define FS_LIM_FILE   ( 4 * 1024 * 1024 )
#define FS_LIM_FILES  20000
#define FS_LIM_RES    2000

/* the focus ring of the File search screen (S13/S14): one stop per control, in
 * the order the form is read. The screen skips the stops that do not belong to
 * the ACTIVE TAB and every control that depends on a filter that is OFF
 * (HcSearchSkip()), so this numbering is the whole focus order there is. */
#define FSF_TABS         1      /* the General / Advanced strip            */
#define FSF_MASK         2      /* Search:          (name mask)            */
#define FSF_DIR          3      /* Search in:       (folder)               */
#define FSF_MASKRE       4      /* [ ] Regular expression (of the mask)    */
#define FSF_ONLYSEL      5      /* [ ] Search only in the selected entries */
#define FSF_DEPTH        6      /* Subdirectories:  (chip)                 */
#define FSF_TEXT         7      /* [ ] Search text:                        */
#define FSF_WORD         8      /* [ ] Whole words only                    */
#define FSF_CASE         9      /* [ ] Match case                          */
#define FSF_RE          10      /* [ ] Regular expression (content)        */
#define FSF_HEX         11      /* [ ] Hexadecimal                         */
#define FSF_NOT         12      /* [ ] Files that do NOT contain the text  */
#define FSF_DATES       13      /* [ ] Date range:                         */
#define FSF_D1          14      /* the `from` date                         */
#define FSF_D2          15      /* the `to` date                           */
#define FSF_DAYS        16      /* [ ] Not older than:                     */
#define FSF_NDAYS       17      /* N days                                  */
#define FSF_SIZE        18      /* [ ] File size:                          */
#define FSF_SOP         19      /* the operator chip                       */
#define FSF_SVAL        20      /* the value                               */
#define FSF_SUNIT       21      /* the unit chip                           */
#define FSF_BTSEARCH    22      /* [ Search ]                              */
#define FSF_BTCANCEL    23      /* [ Cancel ]                              */
/* `Replace with:` is painted right under the five content options, so it is
 * number 24 and NOT 13: the numeric order of the stops is not the order of the
 * ring. HcSearchRing() (bp_hc.prg) is the ONE list that says where it sits, and
 * the ring walks that list, not the numbers. */
#define FSF_REPL        24      /* [ ] Replace with:  (after the five options) */
#define FSF_MAX         24

/* ---- Find / Replace dialog: geometry (S3, S8) ----------------------------
 * Anchored to the 120x44 canvas, not to the 80x25 grid of the original: the box
 * is 80 wide and 16 tall at rows 10..25 / columns 20..99, so the editor it
 * belongs to stays visible above AND below it. Every control is registered in
 * the shared control table while it is painted (S8), so these numbers are the
 * only copy of the layout there is. */
#define FD_T           10       /* top border of the box                   */
#define FD_B           25       /* bottom border of the box                */
#define FD_L           20       /* left border of the box                  */
#define FD_W           80       /* width of the box, frame included        */
#define FD_ROW_FIND    13       /* `Find what:` and its field              */
#define FD_ROW_REPL    14       /* `Replace with:` and its field           */
#define FD_ROW_OPT1    16       /* Match case | Whole words only           */
#define FD_ROW_OPT2    17       /* Regular expression | In selection       */
#define FD_ROW_OPT3    18       /* Backwards | Whole document              */
#define FD_ROW_MSG     20       /* the message row                         */
#define FD_ROW_BTN     21       /* the four buttons                        */
#define FD_ROW_HINT    23       /* the hint row                            */
#define FD_COL_LBL     22       /* the two labels and the message          */
#define FD_COL_FLD     36       /* the two text fields                     */
#define FD_FLD_W       46       /* width of a text field                   */
#define FD_COL_CHK1    22       /* first column of the checkboxes          */
#define FD_COL_CHK2    52       /* second column of the checkboxes         */
#define FD_COL_BTN     22       /* first button                            */
#define FD_BTN_W       15       /* width of a button                       */
#define FD_BTN_GAP      2       /* blank columns between two buttons       */

/* the twelve focus stops, in the order Tab and the arrows walk them
 * (HcFindFocusStep() skips the `In selection` one while the editor has no
 * selection). The stops of the two columns are arithmetic: checkbox n is
 * FD_STOP_CASE + n - 1 and button n is FD_STOP_BTFIND + n - 1.
 * The two `[v]` history drop-downs are GONE (S16): the user asked for the
 * history to be removed, so Tab walks field -> field and nothing else. */
#define FD_STOP_FIND     1      /* the `Find what:` field                    */
#define FD_STOP_REPL     2      /* the `Replace with:` field                 */
#define FD_STOP_CASE     3      /* Match case                                */
#define FD_STOP_WORD     4      /* Whole words only                          */
#define FD_STOP_RE       5      /* Regular expression                        */
#define FD_STOP_INSEL    6      /* In selection (skipped without selection)  */
#define FD_STOP_BACK     7      /* Backwards                                 */
#define FD_STOP_WHOLE    8      /* Whole document                            */
#define FD_STOP_BTFIND   9      /* [ Find Next ]                             */
#define FD_STOP_BTREPL  10      /* [ Replace ]                               */
#define FD_STOP_BTALL   11      /* [ Replace All ]                           */
#define FD_STOP_BTCLOSE 12      /* [ Close ]                                 */
#define FD_STOP_MAX     12

/* The colours of those kinds, all on the dark background `B` (85,85,85) that
 * BpSetVgaPalette() installed. A DARK scheme is a decision (S79): it is the
 * only one with real contrast -- over the light gray of the plain screens the
 * greens, cyans and reds of the palette are washed out. NO new RGB is spent:
 * every pair is built from entries that were already measured (§4), the same
 * way the Compare screen did it. */
#define TC_CODEKEY       74
#define UI_C_CODEKEY     UiC( TC_CODEKEY )  /* reserved words: yellow                 */
#define TC_CODESTR       75
#define UI_C_CODESTR     UiC( TC_CODESTR )  /* strings: bright green                  */
#define TC_CODECMT       76
#define UI_C_CODECMT     UiC( TC_CODECMT )  /* comments: dim gray (170 on 85)         */
#define TC_CODENUM       77
#define UI_C_CODENUM     UiC( TC_CODENUM )  /* numbers: bright red                    */
#define TC_CODEFUNC      78
#define UI_C_CODEFUNC    UiC( TC_CODEFUNC )  /* function name: bright cyan             */
#define TC_CODEPRE       79
#define UI_C_CODEPRE     UiC( TC_CODEPRE )  /* preprocessor directive: bright magenta */

/* S13/L10 of hc-editor-tabs.md: the BAR OF TABS of the editor, colour by colour.
 * The format is `[ name  X ]` and these are the pairs the user chose (L10). The
 * `B` of the active tab is the chrome of this build - 85,85,85 in Classic and
 * 40,40,46 in Dark, because GTWVG allows only eight backgrounds and the program
 * spends them all (L10), so the band reads as a raised dark gray and never as a
 * blue - and `N` is the body.
 * The MARK never carries a background of its own (L7): each of its three states
 * is a LETTER over the background its tab already has, so the pairs below are
 * the ones that make the letter readable on that background. `DIR` is the mark
 * of a buffer modified and not saved (S8/L2), which WINS over the hover.
 * The tabs are JOINED (L12): there is no separator slot, so the closing bracket
 * of a tab touches the opening bracket of the next one.
 * Everything is a slot of BOTH themes: bp_hc.prg never names a pair. */
#define TC_TABLBLON      80
#define UI_C_TABLBLON    UiC( TC_TABLBLON )  /* label and brackets of the active tab */
#define TC_TABLBLOFF     81
#define UI_C_TABLBLOFF   UiC( TC_TABLBLOFF ) /* label and brackets of the other tabs */
#define TC_TABXACT       82
#define UI_C_TABXACT     UiC( TC_TABXACT )   /* mark at rest, active tab             */
#define TC_TABXOFF       83
#define UI_C_TABXOFF     UiC( TC_TABXOFF )   /* mark at rest, the other tabs         */
#define TC_TABXDIRA      84
#define UI_C_TABXDIRA    UiC( TC_TABXDIRA )  /* mark with changes not saved, active  */
#define TC_TABXDIRO      85
#define UI_C_TABXDIRO    UiC( TC_TABXDIRO )  /* mark with changes not saved, others  */
#define TC_TABXHOVA      86
#define UI_C_TABXHOVA    UiC( TC_TABXHOVA )  /* mark with the pointer over it, active*/
#define TC_TABXHOVO      87
#define UI_C_TABXHOVO    UiC( TC_TABXHOVO )  /* mark with the pointer over it, others*/
#define TC_TABBAR        88
#define UI_C_TABBAR      UiC( TC_TABBAR )    /* the empty rest of the row of the bar */
/* L17: the two BRACKETS of the ACTIVE tab. In `Classic` this is the same pair as
 * its label (nothing changes there: the grey band already says which tab is
 * active); in `Dark` it is the amber accent, because `B` (40,40,46) and `N`
 * (18,18,22) are almost the same grey and the band alone does not tell them
 * apart. It is a slot of both themes, like every other pair here. */
#define TC_TABBRKON      89
#define UI_C_TABBRKON    UiC( TC_TABBRKON )  /* brackets of the ACTIVE tab        */

/* Number of colour slots: one per UI_C_* macro, in the SAME order as
 * the colour tables of the themes (bp_ui.prg). Every theme carries
 * exactly this many pairs in its { cName, aColors } array (S6). */
#define TC_COUNT        89

#endif

