#Requires AutoHotkey v2.0
;@Ahk2Exe-SetName QuickNotes
;@Ahk2Exe-SetDescription QuickNotes
;@Ahk2Exe-SetVersion 2.0.0
;@Ahk2Exe-SetCompanyName Mogdho Paul
;@Ahk2Exe-SetCopyright Mogdho Paul - MIT License
;@Ahk2Exe-SetMainIcon assets\icon.ico
;  (Lines starting with ;@Ahk2Exe are only read when building the .exe)

#SingleInstance Force

; ==================================================================
;  QuickNotes - reads ANY language (Bangla, English, Hindi, ...)
;  using Google Gemini. Nothing extra to install.
;
;  DOUBLE-TAP Right Alt  -> the screen dims: drag over any text
;  (the default shortcut)   -> it's read and copied to your clipboard.
;                           Esc or right-click cancels.
;
;  The shortcut can be changed (tray -> "Change shortcut…"): double-tap
;  another key, or a key combination like Ctrl + Shift + Q.
;  A single tap does nothing - the key keeps working normally.
;
;  First launch opens a setup window for a free Gemini API key (one time).
;  Only the area you select is sent to Google Gemini to read the text.
; ==================================================================

Models        := "gemini-flash-lite-latest,gemini-flash-latest"  ; tried in order
MagicKey      := "RAlt"     ; default shortcut: double-tap Right Alt (changeable from the tray)
HoldTime      := 400        ; ms - holding the key longer than this isn't a "tap"
DoubleTapTime := 350        ; max ms between the two taps

AppName      := "QuickNotes"
DataDir      := A_AppData "\QuickNotes"
SettingsFile := DataDir "\settings.ini"         ; Tray options (e.g. sound on/off)
KeyFile      := DataDir "\gemini-key.txt"       ; Encrypted for your Windows account only
IsPaused     := false
TryingIt     := false        ; true while the user does their first "Try it now" scan
DownTime     := 0
LastTap      := 0
ScanBusy     := false
ActiveHotkeys := []          ; the hotkeys currently switched on for the shortcut
ShortcutHold := 0            ; > 0 while a window that needs the shortcut off is open (guide, shortcut picker)

DirCreate(DataDir)
try DirDelete(A_Temp "\QuickNotes", true)       ; Leftover from older versions (PowerShell helper)
if (IniRead(SettingsFile, "State", "BusyCursor", "0") = "1")
    BusyCursor(false, true)                     ; QuickNotes was closed mid-scan: give the normal cursor back
OnExit((*) => BusyCursor(false))

ApplyShortcut()
SetupTray()

; First launch (no key saved yet): open the setup window right away
if (LoadKey() = "")
    SetTimer(FirstRun, -300)

FirstRun() {
    if (KeySetup.Ask("first") != "")
        ShowHowTo(true)                      ; teach the shortcut right away
    else
        TrayTip("QuickNotes needs a free Gemini key to work.`n" ShortcutInfo().sentence " to set it up.", "QuickNotes")
}

; ================= the shortcut (double-tap a key, or a key combination) =================

; Switches the shortcut off while a window needs it off (the guide page during
; onboarding, the shortcut picker). Every PauseShortcut needs one ResumeShortcut;
; the shortcut only comes back when ALL such windows are closed.
PauseShortcut() {
    global ShortcutHold += 1, LastTap := 0, DownTime := 0
    for h in ActiveHotkeys
        try Hotkey(h, "Off")
}

ResumeShortcut() {
    global ShortcutHold := Max(0, ShortcutHold - 1)
    ApplyShortcut()
}

; Sets up the shortcut saved in settings.ini (default: double-tap Right Alt).
; It stays switched off while a window is holding it (ShortcutHold > 0).
ApplyShortcut() {
    global ActiveHotkeys, MagicKey, LastTap := 0, DownTime := 0
    for h in ActiveHotkeys
        try Hotkey(h, "Off")
    ActiveHotkeys := []
    onOff := ShortcutHold > 0 ? "Off" : "On"
    if (IniRead(SettingsFile, "Shortcut", "Mode", "double") = "combo") {
        combo := IniRead(SettingsFile, "Shortcut", "Combo", "")
        if (combo != "") {
            try {
                Hotkey(combo, StartScan, onOff)
                ActiveHotkeys.Push(combo)
                return
            }
        }
    }
    MagicKey := IniRead(SettingsFile, "Shortcut", "Key", "RAlt")
    Hotkey("~" MagicKey, MagicDown, onOff)
    Hotkey("~" MagicKey " up", MagicUp, onOff)
    ActiveHotkeys.Push("~" MagicKey, "~" MagicKey " up")
}

; The current shortcut in words and as key caps, for the help page, tray and messages
ShortcutInfo() {
    static names := Map("RAlt", "Right Alt", "RControl", "Right Ctrl", "LAlt", "Left Alt", "LControl", "Left Ctrl", "RShift", "Right Shift")
    if (IniRead(SettingsFile, "Shortcut", "Mode", "double") = "combo") {
        combo := IniRead(SettingsFile, "Shortcut", "Combo", "")
        if (combo != "") {
            caps := []
            mods := RegExReplace(combo, "[^#^!+].*$")       ; just the modifier symbols at the start
            for pair in [["#", "Win"], ["^", "Ctrl"], ["!", "Alt"], ["+", "Shift"]]   ; usual reading order
                if InStr(mods, pair[1])
                    caps.Push(pair[2])
            key := RegExReplace(combo, "^[#^!+]*")
            caps.Push(StrLen(key) = 1 ? StrUpper(key) : StrTitle(key))
            text := ""
            for c in caps
                text .= (A_Index > 1 ? " + " : "") c
            return {caps: caps, joiner: "+", hint: "press together", text: text, sentence: "Press " text, double: false}
        }
    }
    k := IniRead(SettingsFile, "Shortcut", "Key", "RAlt")
    n := names.Has(k) ? names[k] : k
    return {caps: [n, n], joiner: "", hint: "tap twice, quickly", text: "Double-tap " n, sentence: "Double-tap " n, double: true, name: n}
}

; Shows Windows' "working in background" cursor (arrow + spinning circle) while Gemini reads.
; Always given back: after the scan, on errors, and when QuickNotes closes.
BusyCursor(on, force := false) {
    static active := false
    if (on && !active) {
        for id in [32512, 32513, 32649] {               ; normal arrow, text I-beam, hand
            h := DllCall("CopyImage", "ptr", DllCall("LoadCursor", "ptr", 0, "ptr", 32650, "ptr"), "uint", 2, "int", 0, "int", 0, "uint", 0, "ptr")
            DllCall("SetSystemCursor", "ptr", h, "uint", id)
        }
        active := true
        IniWrite("1", SettingsFile, "State", "BusyCursor")
    } else if (!on && (active || force)) {
        DllCall("SystemParametersInfo", "uint", 0x57, "uint", 0, "ptr", 0, "uint", 0)   ; reload the user's own cursors
        active := false
        try IniDelete(SettingsFile, "State", "BusyCursor")
    }
}


; ================= the magic key =================

MagicDown(*) {
    global DownTime
    Send("{Blind}{vkE8}")            ; stops a lone Alt tap opening app menus
    if !DownTime                     ; ignore key auto-repeat while held
        DownTime := A_TickCount
}

MagicUp(*) {
    global DownTime, LastTap
    held := A_TickCount - DownTime
    DownTime := 0

    if (A_PriorKey != MagicKey) {    ; Alt was used in a combination -> ignore
        LastTap := 0
        return
    }

    if (held >= HoldTime) {          ; held down -> not a tap
        LastTap := 0
        return
    }

    now := A_TickCount               ; short tap
    if (LastTap && now - LastTap <= DoubleTapTime) {
        LastTap := 0
        StartScan()                  ; second tap -> scan (ignored if one is already running)
    } else {
        LastTap := now               ; first tap -> just remember it
    }
}


; ================= scanning =================

; Starts a scan - unless one is already running. Double-tapping again while the
; dim screen is open (or while the text is being read) is ignored, not queued.
StartScan(*) {
    global ScanBusy
    if ScanBusy
        return
    TryPrompt(false)                         ; the "Your turn!" card has done its job
    SetTimer(TryPromptTimeout, 0)            ; ...and keep the "first try" message for this scan
    ScanBusy := true
    SetTimer(ScanAndCopy, -1)
}

; Draws the shortcut as key caps: [Right Alt] [Right Alt]  or  [Ctrl] + [Shift] + [Q]
AddShortcutCaps(g, sc, firstPos) {
    for i, cap in sc.caps {
        g.SetFont("s11 bold c111827")
        g.AddText((i = 1 ? firstPos : "x+8 yp") " w" Max(56, 11 * StrLen(cap) + 22) " h46 0x200 Center Border BackgroundF3F4F6", cap)
        if (sc.joiner != "" && i < sc.caps.Length) {
            g.SetFont("s12 bold c6B7280")
            g.AddText("x+8 yp w14 h46 0x200 Center", sc.joiner)
        }
    }
    g.SetFont("s11 norm c2563EB")
    g.AddText("x+14 yp w170 h46 0x200", "→  " sc.hint)
}

; "Your turn!" card after "Try it now": asks the user to press the real shortcut.
; Sits at the top of the screen without taking the keyboard focus; gone after a minute.
TryPrompt(show := true) {
    static g := 0
    global TryingIt
    if !show {
        if g
            try g.Destroy()
        g := 0
        return
    }
    if g
        return
    sc := ShortcutInfo()
    TryingIt := true
    g := Gui("+AlwaysOnTop +ToolWindow -Caption +Border", "QuickNotes - your turn")
    g.BackColor := "FFFFFF", g.MarginX := 22, g.MarginY := 16
    g.SetFont("s13 bold c111827", "Segoe UI")
    g.AddText("w420", "Your turn! " sc.sentence (sc.double ? ", quickly." : "."))
    AddShortcutCaps(g, sc, "xm y+12")
    g.SetFont("s9 norm c6B7280")
    g.AddText("xm y+12 w420", "Then drag over any text on your screen. It's copied for you.")
    g.SetFont("s10 c111827")
    g.AddButton("xm+330 y+8 w90 h30", "Skip").OnEvent("Click", (*) => TryPromptTimeout())
    g.Show("Hide AutoSize")
    g.GetPos(, , &w, &h)
    MonitorGetWorkArea(MonitorGetPrimary(), &l, &t, &r)
    g.Show("x" Round(l + (r - l - w) / 2) " y" (t + 40) " NoActivate")
    SetTimer(TryPromptTimeout, -60000)
}

TryPromptTimeout() {
    global TryingIt := false
    TryPrompt(false)
}

ScanAndCopy() {
    global ScanBusy
    try ScanOnce()
    finally ScanBusy := false
}

ScanOnce() {
    key := GetKey()
    if (key = "")
        return

    ; Our own scan screen: dims, you drag over the text. The clipboard is only
    ; touched at the very end, after the text was read successfully.
    WarmUp(key)                              ; connect to Google while you drag
    try png := ScanOverlay().Run()
    catch as e {
        png := 0
        MsgBox("Couldn't open the scan screen:`n`n" e.Message, AppName, "Icon!")
    }
    if !png
        return                               ; cancelled (Esc / right-click)

    BusyCursor(true)                         ; the classic "working" cursor while Gemini reads
    try result := AskGemini(png, key)
    finally BusyCursor(false)

    if (result.error != "") {
        err := result.error
        if InStr(err, "API_KEY_INVALID") || InStr(err, "API key not valid") {
            KeySetup.Ask("invalid")
        } else if InStr(err, "RESOURCE_EXHAUSTED") || InStr(err, "429") {
            MsgBox("You've hit Google's free limit for now.`nWait a minute and try again.", AppName, "Icon!")
        } else {
            MsgBox("Couldn't read the text:`n`n" SubStr(err, 1, 400), AppName, "Icon!")
        }
        return
    }

    text := Trim(result.text, " `t`r`n")
    ; Gemini sometimes wraps the answer in Markdown fences (```text ... ```): remove them
    if RegExMatch(text, "s)^``````[^\r\n]*\R(.*?)\R?``````$", &fence)
        text := Trim(fence[1], " `t`r`n")
    if (text = "") {
        Notify("No text found")
        return
    }
    if !CopyToClipboard(text) {
        MsgBox("The text was read, but another app is using the clipboard right now, "
            . "so it couldn't be copied.`n`nPlease try the scan again.", AppName, "Icon!")
        return
    }
    if SoundOn()
        PlayCopiedSound()
    global TryingIt
    Notify(TryingIt ? "Copied! That's all there is to it." : "Copied")
    TryingIt := false
}

; Sends the picture to Gemini and returns {text, error}
AskGemini(png, key) {
    ; Reading text is easy, so ask Gemini to think as little as possible.
    ; Models accept different settings, so try the lightest first and step up
    ; only if Google refuses it. What worked is remembered for the next scans.
    static thinking := ['{"thinkingLevel":"minimal"}', '{"thinkingLevel":"low"}', '{"thinkingBudget":0}', ""]
    static works := Map()                     ; model -> index in `thinking` that Google accepted
    prompt := "Transcribe all the text in this image exactly as written, in its original language and script "
        . "(for example Bangla or English). Keep the line breaks. Do not translate, correct, explain or add anything. "
        . "Output only the text. If there is no text, output nothing."
    contents := '{"contents":[{"parts":[{"inline_data":{"mime_type":"image/png","data":"' Base64Encode(png)
        . '"}},{"text":"' prompt '"}]}]'

    ; Speed plan: ask the first model. If it hasn't answered after HedgeAfter ms
    ; (or it fails), ask the backup model too and take whichever answers first.
    ; Never wait longer than MaxWait ms in total.
    static HedgeAfter := 6000, MaxWait := 25000
    modelList := StrSplit(Models, ",")      ; (not "models": AutoHotkey names ignore case, it would hide Models)
    attempts := []
    start := A_TickCount
    WaitIdle(Http())                          ; the warm-up is quick; never wait long for it
    GeminiSend(attempts, Trim(modelList[1]), Http(), contents, key, works, thinking)
    errs := []
    loop {
        ; Start the backup model when the first one is slow or has failed
        if (attempts.Length < modelList.Length && attempts.Length < 2)
            && (A_TickCount - start > HedgeAfter || attempts[1].state = "failed")
            GeminiSend(attempts, Trim(modelList[2]), ComObject("WinHttp.WinHttpRequest.5.1"), contents, key, works, thinking)

        for a in attempts {
            r := GeminiCheck(a, contents, key, works, thinking)
            if (r = "")
                continue
            if r.HasOwnProp("text") {                     ; got the text: stop the other request
                for other in attempts
                    if (ObjPtr(other) != ObjPtr(a))
                        try other.req.Abort()
                return {text: r.text, error: ""}
            }
            errs.Push(r.error)
            if r.HasOwnProp("fatal") {                    ; wrong key: no point trying anything else
                for other in attempts
                    try other.req.Abort()
                return {text: "", error: r.error}
            }
        }

        allFailed := attempts.Length >= Min(2, modelList.Length)
        for a in attempts
            if (a.state != "failed")
                allFailed := false
        if allFailed
            break
        if (A_TickCount - start > MaxWait) {
            for a in attempts
                try a.req.Abort()
            errs.Push("Gemini took too long to answer. Please try again.")
            break
        }
        Sleep(20)                                         ; keeps the tray menu and hotkeys responsive
    }
    ; Prefer the most useful message (e.g. the free limit) over a generic one
    for e in errs
        if InStr(e, "RESOURCE_EXHAUSTED") || InStr(e, "429")
            return {text: "", error: e}
    return {text: "", error: errs.Length ? errs[errs.Length] : "Unknown error"}
}

; Starts (or restarts) one request to `model` and adds it to `attempts`
GeminiSend(attempts, model, req, contents, key, works, thinking, a := "") {
    if (a = "") {
        a := {model: model, req: req, i: works.Has(model) ? works[model] : 1, retried: false, state: "", retryAt: 0}
        attempts.Push(a)
    }
    cfg := thinking[a.i]
    body := contents (cfg != "" ? ',"generationConfig":{"thinkingConfig":' cfg '}' : "") "}"
    try {
        a.req.Open("POST", "https://generativelanguage.googleapis.com/v1beta/models/" a.model ":generateContent", true)
        a.req.SetTimeouts(5000, 5000, 15000, 25000)
        a.req.SetRequestHeader("Content-Type", "application/json; charset=utf-8")
        a.req.SetRequestHeader("x-goog-api-key", key)
        a.req.Send(body)
        a.state := "running"
    } catch as e {
        a.state := "failed", a.lastError := e.Message
    }
    return a
}

; Looks at one request without waiting. Returns "" (nothing new), {text} or {error[, fatal]}
GeminiCheck(a, contents, key, works, thinking) {
    if (a.state = "waiting" && A_TickCount >= a.retryAt) {     ; Google was busy: try again now
        GeminiSend("", a.model, a.req, contents, key, works, thinking, a)
        return ""
    }
    if (a.state = "failed" && a.HasOwnProp("lastError")) {
        err := a.lastError, a.DeleteProp("lastError")
        return {error: err}
    }
    if (a.state != "running")
        return ""
    try {
        if !a.req.WaitForResponse(0)
            return ""
        status := a.req.Status, body := ResponseText(a.req)
    } catch as e {                                            ; network error
        a.state := "failed"
        return {error: e.Message}
    }
    if (status = 200) {
        works[a.model] := a.i
        a.state := "done"
        return {text: JsonTextParts(body)}
    }
    err := "HTTP " status ": " body
    if InStr(body, "API_KEY_INVALID") || InStr(body, "API key not valid") {
        a.state := "failed"
        return {error: err, fatal: true}
    }
    if (status = 400 && a.i < thinking.Length) {              ; thinking setting refused: try the next one
        a.i += 1
        GeminiSend("", a.model, a.req, contents, key, works, thinking, a)
        return ""
    }
    if (status >= 500 && !a.retried) {                         ; Google busy: one retry after a moment
        a.retried := true, a.state := "waiting", a.retryAt := A_TickCount + 1000
        return ""
    }
    a.state := "failed"
    return {error: err}
}

; One connection to Google, kept alive between requests: every request after
; the first skips the secure handshake (about 0.1-0.3 s)
Http() {
    static req := ComObject("WinHttp.WinHttpRequest.5.1")
    return req
}

; Opens the connection while you're still dragging, so the real request doesn't
; wait for the handshake. A tiny GET that sends no key. (Not HEAD: after a HEAD,
; WinHTTP returns an empty body for the next reply on the same connection.)
WarmUp(key := "") {
    try {
        r := Http()
        r.Open("GET", "https://generativelanguage.googleapis.com/", true)
        r.Send()
    }
}

; Waits (without freezing) until the shared connection finished its last request
WaitIdle(r, maxMs := 1000) {
    start := A_TickCount
    try while !r.WaitForResponse(0) {
        if (A_TickCount - start > maxMs) {
            r.Abort()
            return
        }
        Sleep(10)
    }
}

; ---- "Sound when copied" (tray option, on by default) ----
SoundOn() => IniRead(SettingsFile, "Options", "SoundWhenCopied", "1") = "1"

ToggleSound(*) {
    IniWrite(SoundOn() ? "0" : "1", SettingsFile, "Options", "SoundWhenCopied")
    UpdateTray()
}

; Windows' own soft notification sound (falls back to the system "information" sound)
PlayCopiedSound() {
    f := A_WinDir "\Media\Windows Notify System Generic.wav"
    try SoundPlay(FileExist(f) ? f : "*64")
}

; Reads the reply as UTF-8 (so Bangla and other scripts come through correctly)
ResponseText(req) {
    try {
        bytes := req.ResponseBody
        size := bytes.MaxIndex() + 1
        if (size <= 0)
            return ""
        return StrGet(NumGet(ComObjValue(bytes), 8 + A_PtrSize, "ptr"), size, "UTF-8")
    }
    return ""
}

; Joins every "text" value in Gemini's JSON reply
JsonTextParts(json) {
    ; "Unrolled" pattern: stays fast and safe even for very long text
    ; (the simpler (?:a|b)* form can fail on long answers)
    out := "", pos := 1
    while (pos := RegExMatch(json, '"text"\s*:\s*"([^"\\]*+(?:\\.[^"\\]*+)*+)"', &m, pos)) {
        out .= JsonUnescape(m[1])
        pos += m.Len
    }
    return out
}

JsonUnescape(s) {
    if !InStr(s, "\")                          ; nothing escaped: use it as it is
        return s
    out := "", i := 1, n := StrLen(s)
    while (i <= n) {
        c := SubStr(s, i, 1)
        if (c != "\") {
            out .= c, i += 1
            continue
        }
        e := SubStr(s, i + 1, 1)
        switch e, true {
            case "n": out .= "`n"
            case "r": out .= "`r"
            case "t": out .= "`t"
            case "b": out .= Chr(8)
            case "f": out .= Chr(12)
            case "u":
                out .= Chr(Integer("0x" SubStr(s, i + 2, 4)))
                i += 4
            default: out .= e                 ; \" \\ \/
        }
        i += 2
    }
    return out
}

; ================= the scan screen =================
; Minimal: the screen dims, and the area you drag over shows clear.
; Smooth: nothing animates while you wait. Each mouse move only redraws
; the old and new selection box, paced to the monitor refresh (DwmFlush),
; and the fade in/out is done by Windows' compositor (window opacity).

class ScanOverlay {
    Run() {
        GdipInit()
        ; Per-monitor DPI: real pixels on every screen, even with mixed scaling
        prevCtx := DllCall("SetThreadDpiAwarenessContext", "ptr", -4, "ptr")
        DllCall("winmm\timeBeginPeriod", "uint", 1)
        try return this.Show()
        finally {
            DllCall("winmm\timeEndPeriod", "uint", 1)
            this.Cleanup()
            if prevCtx
                DllCall("SetThreadDpiAwarenessContext", "ptr", prevCtx, "ptr")
        }
    }

    Show() {
        ; ---- freeze: copy what all screens show right now ----
        this.vx := SysGet(76), this.vy := SysGet(77), this.w := w := SysGet(78), this.h := h := SysGet(79)
        MonitorGet(MonitorGetPrimary(), &pl, &pt)
        hMon := DllCall("MonitorFromPoint", "int64", ((pt + 1) << 32) | ((pl + 1) & 0xFFFFFFFF), "uint", 1, "ptr")
        dpi := 96
        try DllCall("shcore\GetDpiForMonitor", "ptr", hMon, "int", 0, "uint*", &dpi, "uint*", &dpiY := 0)
        this.s := dpi / 96

        this.bright := MemCanvas(w, h)
        sdc := DllCall("GetDC", "ptr", 0, "ptr")
        DllCall("BitBlt", "ptr", this.bright.dc, "int", 0, "int", 0, "int", w, "int", h, "ptr", sdc, "int", this.vx, "int", this.vy, "uint", 0x00CC0020)
        DllCall("ReleaseDC", "ptr", 0, "ptr", sdc)

        ; ---- dimmed copy (made once) ----
        this.dim := MemCanvas(w, h)
        this.Copy(this.dim.dc, this.bright.dc, [0, 0, w, h])
        DllCall("gdiplus\GdipCreateFromHDC", "ptr", this.dim.dc, "ptr*", &g := 0)
        DllCall("gdiplus\GdipCreateSolidFill", "uint", 0x80000000, "ptr*", &shade := 0)     ; 50% black
        DllCall("gdiplus\GdipFillRectangle", "ptr", g, "ptr", shade, "float", 0, "float", 0, "float", w, "float", h)
        DllCall("gdiplus\GdipDeleteBrush", "ptr", shade)
        DllCall("gdiplus\GdipDeleteGraphics", "ptr", g)

        ; ---- the frame we show (back buffer) + a faint 1 px line around the clear area ----
        this.back := MemCanvas(w, h)
        this.Copy(this.back.dc, this.dim.dc, [0, 0, w, h])
        DllCall("gdiplus\GdipCreateFromHDC", "ptr", this.back.dc, "ptr*", &g := 0)
        this.g := g
        DllCall("gdiplus\GdipCreatePen1", "uint", 0x8CFFFFFF, "float", 1, "int", 2, "ptr*", &pen := 0)
        this.pen := pen

        ; ---- the window ----
        this.sel := 0, this.lastBand := 0, this.changed := false
        this.state := "open", this.dragging := false
        this.gui := Gui("+AlwaysOnTop -Caption +ToolWindow -DPIScale +E0x80000")   ; layered = cheap fade
        this.hwnd := this.gui.Hwnd
        WinSetTransparent(0, this.hwnd)
        this.handlers := Map(
            0x000F, ObjBindMethod(this, "OnPaint"),        ; WM_PAINT
            0x0014, ObjBindMethod(this, "OnErase"),        ; WM_ERASEBKGND
            0x0020, ObjBindMethod(this, "OnSetCursor"),    ; WM_SETCURSOR
            0x0201, ObjBindMethod(this, "OnLDown"),        ; WM_LBUTTONDOWN
            0x0200, ObjBindMethod(this, "OnMove"),         ; WM_MOUSEMOVE
            0x0202, ObjBindMethod(this, "OnLUp"),          ; WM_LBUTTONUP
            0x0204, ObjBindMethod(this, "OnCancel"),       ; WM_RBUTTONDOWN
            0x0100, ObjBindMethod(this, "OnKey"),          ; WM_KEYDOWN
            0x0006, ObjBindMethod(this, "OnActivate"))     ; WM_ACTIVATE
        for msg, fn in this.handlers
            OnMessage(msg, fn)
        this.shownAt := A_TickCount           ; set before showing: focus messages can arrive during Show
        this.gui.Show("x" this.vx " y" this.vy " w" w " h" h)
        WinActivate(this.hwnd)

        ; ---- wait for the drag. Draw only when the selection changed ----
        t0 := A_TickCount, this.shownAt := t0, fading := true
        while (this.state = "open") {
            now := A_TickCount - t0
            if fading {
                WinSetTransparent(Min(255, Round(255 * now / 120)), this.hwnd)
                fading := now < 120
            }
            if this.changed
                this.Frame()
            if (fading || this.changed)
                DllCall("dwmapi\DwmFlush")    ; wait for the next screen refresh
            else
                Sleep(4)                      ; idle: nothing to draw
            Sleep(-1)                         ; handle mouse / keys
            if (now > 120000)                 ; forgotten for 2 minutes
                this.state := "cancel"
        }
        ; fade out
        fadeStart := A_TickCount
        loop {
            k := (A_TickCount - fadeStart) / 120
            if (k >= 1)
                break
            WinSetTransparent(Round(255 * (1 - k)), this.hwnd)
            DllCall("dwmapi\DwmFlush")
        }
        WinSetTransparent(0, this.hwnd)

        if (this.state != "accept")
            return 0
        sel := this.sel
        crop := MemCanvas(sel[3] - sel[1], sel[4] - sel[2], 24)
        this.Copy(crop.dc, this.bright.dc, [0, 0, sel[3] - sel[1], sel[4] - sel[2]], sel[1], sel[2])
        return HBitmapToPng(crop.hbm)
    }

    Frame() {
        this.changed := false
        ; only the old and the new selection box change
        dirty := []
        if this.lastBand
            dirty.Push(this.lastBand)
        band := this.sel ? [this.sel[1] - 2, this.sel[2] - 2, this.sel[3] + 2, this.sel[4] + 2] : 0
        if band
            dirty.Push(band)
        this.lastBand := band

        for r in dirty
            this.Restore(r)
        if this.sel
            DllCall("gdiplus\GdipDrawRectangleI", "ptr", this.g, "ptr", this.pen, "int", this.sel[1] - 1, "int", this.sel[2] - 1
                , "int", this.sel[3] - this.sel[1] + 1, "int", this.sel[4] - this.sel[2] + 1)

        wdc := DllCall("GetDC", "ptr", this.hwnd, "ptr")
        for r in dirty
            this.Copy(wdc, this.back.dc, r)
        DllCall("ReleaseDC", "ptr", this.hwnd, "ptr", wdc)
    }

    ; Dim everywhere, clear inside the selection
    Restore(r) {
        this.Copy(this.back.dc, this.dim.dc, r)
        if this.sel {
            i := [Max(r[1], this.sel[1]), Max(r[2], this.sel[2]), Min(r[3], this.sel[3]), Min(r[4], this.sel[4])]
            if (i[1] < i[3] && i[2] < i[4])
                this.Copy(this.back.dc, this.bright.dc, i)
        }
    }

    ; Copies rectangle r = [x1, y1, x2, y2] (from sx, sy in the source if given)
    Copy(dstDC, srcDC, r, sx?, sy?) {
        x1 := Max(r[1], 0), y1 := Max(r[2], 0), x2 := Min(r[3], this.w), y2 := Min(r[4], this.h)
        if IsSet(sx)
            x1 := r[1], y1 := r[2], x2 := r[3], y2 := r[4]
        if (x2 <= x1 || y2 <= y1)
            return
        DllCall("BitBlt", "ptr", dstDC, "int", x1, "int", y1, "int", x2 - x1, "int", y2 - y1
            , "ptr", srcDC, "int", IsSet(sx) ? sx : x1, "int", IsSet(sy) ? sy : y1, "uint", 0x00CC0020)
    }

    ; ---- window messages ----
    Mine(hwnd) => hwnd = this.hwnd
    OnPaint(wParam, lParam, msg, hwnd) {
        if !this.Mine(hwnd)
            return
        ps := Buffer(72, 0)
        dc := DllCall("BeginPaint", "ptr", hwnd, "ptr", ps, "ptr")
        o := A_PtrSize + 4
        this.Copy(dc, this.back.dc, [NumGet(ps, o, "int"), NumGet(ps, o + 4, "int"), NumGet(ps, o + 8, "int"), NumGet(ps, o + 12, "int")])
        DllCall("EndPaint", "ptr", hwnd, "ptr", ps)
        return 0
    }
    OnErase(wParam, lParam, msg, hwnd) => this.Mine(hwnd) ? 1 : ""
    OnSetCursor(wParam, lParam, msg, hwnd) {
        if !this.Mine(hwnd)
            return
        cur := ScanOverlay.MakeCursor(this.s)
        DllCall("SetCursor", "ptr", cur ? cur : DllCall("LoadCursor", "ptr", 0, "ptr", 32515, "ptr"))
        return 1
    }

    ; A "+" cursor that stays visible on any background: white lines with a thin
    ; dark outline. (Windows' own crosshair inverts the colours under it, so on
    ; the 50% dimmed screen it turns the same grey as the background.)
    static MakeCursor(s) {
        static cache := Map()
        if cache.Has(s)
            return cache[s]
        n := Max(32, Round(32 * s / 2) * 2)          ; cursor size (even), follows display scaling
        c := n // 2                                  ; hotspot = the centre
        L := Round(11 * s)                           ; arm length
        t := Max(2, Round(1.5 * s))                  ; white line thickness
        o := Max(1, Round(0.75 * s))                 ; dark outline around it
        y0 := c - t // 2
        DllCall("gdiplus\GdipCreateBitmapFromScan0", "int", n, "int", n, "int", 0, "int", 0x26200A, "ptr", 0, "ptr*", &bmp := 0)
        DllCall("gdiplus\GdipGetImageGraphicsContext", "ptr", bmp, "ptr*", &g := 0)
        DllCall("gdiplus\GdipGraphicsClear", "ptr", g, "uint", 0)
        DllCall("gdiplus\GdipCreateSolidFill", "uint", 0xE6000000, "ptr*", &dark := 0)
        DllCall("gdiplus\GdipCreateSolidFill", "uint", 0xFFFFFFFF, "ptr*", &light := 0)
        for pass in [[dark, o], [light, 0]] {        ; outline first, white on top
            br := pass[1], e := pass[2]
            DllCall("gdiplus\GdipFillRectangleI", "ptr", g, "ptr", br, "int", c - L - e, "int", y0 - e, "int", 2 * L + 2 * e, "int", t + 2 * e)
            DllCall("gdiplus\GdipFillRectangleI", "ptr", g, "ptr", br, "int", y0 - e, "int", c - L - e, "int", t + 2 * e, "int", 2 * L + 2 * e)
        }
        DllCall("gdiplus\GdipCreateHICONFromBitmap", "ptr", bmp, "ptr*", &hIcon := 0)
        DllCall("gdiplus\GdipDeleteBrush", "ptr", dark), DllCall("gdiplus\GdipDeleteBrush", "ptr", light)
        DllCall("gdiplus\GdipDeleteGraphics", "ptr", g), DllCall("gdiplus\GdipDisposeImage", "ptr", bmp)
        if !hIcon
            return cache[s] := 0
        ; Turn the icon into a cursor whose click point is the centre of the "+"
        ii := Buffer(A_PtrSize = 8 ? 32 : 20, 0)
        DllCall("GetIconInfo", "ptr", hIcon, "ptr", ii)
        NumPut("int", 0, "uint", c, "uint", c, ii)  ; fIcon = FALSE (cursor), hotspot x, y
        hCur := DllCall("CreateIconIndirect", "ptr", ii, "ptr")
        mo := A_PtrSize = 8 ? 16 : 12
        DllCall("DeleteObject", "ptr", NumGet(ii, mo, "ptr")), DllCall("DeleteObject", "ptr", NumGet(ii, mo + A_PtrSize, "ptr"))
        DllCall("DestroyIcon", "ptr", hIcon)
        return cache[s] := hCur
    }
    OnLDown(wParam, lParam, msg, hwnd) {
        if !this.Mine(hwnd)
            return
        this.ax := lParam << 48 >> 48, this.ay := lParam << 32 >> 48
        this.dragging := true, this.sel := 0, this.changed := true
        DllCall("SetCapture", "ptr", hwnd)
        return 0
    }
    OnMove(wParam, lParam, msg, hwnd) {
        if !this.Mine(hwnd) || !this.dragging
            return
        x := Min(Max(lParam << 48 >> 48, 0), this.w), y := Min(Max(lParam << 32 >> 48, 0), this.h)
        this.sel := [Min(this.ax, x), Min(this.ay, y), Max(this.ax, x), Max(this.ay, y)]
        this.changed := true
        return 0
    }
    OnLUp(wParam, lParam, msg, hwnd) {
        if !this.Mine(hwnd) || !this.dragging
            return
        this.dragging := false
        DllCall("ReleaseCapture")
        if this.sel && (this.sel[3] - this.sel[1] >= 8 * this.s) && (this.sel[4] - this.sel[2] >= 8 * this.s)
            this.state := "accept"
        else
            this.sel := 0, this.changed := true    ; just a click: keep the screen open
        return 0
    }
    OnCancel(wParam, lParam, msg, hwnd) {
        if this.Mine(hwnd)
            this.state := "cancel"
    }
    OnKey(wParam, lParam, msg, hwnd) {
        if this.Mine(hwnd) && (wParam = 27)  ; Esc
            this.state := "cancel"
    }
    OnActivate(wParam, lParam, msg, hwnd) {
        ; Switched away (Alt+Tab, Win key...) -> close quietly
        if this.Mine(hwnd) && !(wParam & 0xFFFF) && (A_TickCount - this.shownAt > 400) && this.state = "open"
            this.state := "cancel"
    }

    Cleanup() {
        if this.HasOwnProp("handlers")
            for msg, fn in this.handlers
                OnMessage(msg, fn, 0)
        if this.HasOwnProp("gui")
            this.gui.Destroy()
        if this.HasOwnProp("pen")
            DllCall("gdiplus\GdipDeletePen", "ptr", this.pen)
        if this.HasOwnProp("g")
            DllCall("gdiplus\GdipDeleteGraphics", "ptr", this.g)
        this.bright := this.dim := this.back := 0      ; frees the screen copies
    }
}

; A screen-sized drawing surface (memory DC + DIB section)
class MemCanvas {
    __New(w, h, bpp := 32) {
        bi := Buffer(40, 0)
        NumPut("uint", 40, "int", w, "int", -h, "ushort", 1, "ushort", bpp, bi)
        this.hbm := DllCall("CreateDIBSection", "ptr", 0, "ptr", bi, "uint", 0, "ptr*", &bits := 0, "ptr", 0, "uint", 0, "ptr")
        if !this.hbm
            throw Error("Not enough memory for a " w "x" h " screen copy.")
        this.dc := DllCall("CreateCompatibleDC", "ptr", 0, "ptr")
        this.old := DllCall("SelectObject", "ptr", this.dc, "ptr", this.hbm, "ptr")
    }
    __Delete() {
        DllCall("SelectObject", "ptr", this.dc, "ptr", this.old)
        DllCall("DeleteDC", "ptr", this.dc)
        DllCall("DeleteObject", "ptr", this.hbm)
    }
}

GdipInit() {
    static token := 0
    if !token {
        DllCall("LoadLibrary", "str", "gdiplus", "ptr")
        si := Buffer(24, 0), NumPut("uint", 1, si)
        DllCall("gdiplus\GdiplusStartup", "ptr*", &token, "ptr", si, "ptr", 0)
    }
}

; Turns a bitmap into PNG bytes (Buffer), or 0
HBitmapToPng(hbm) {
    static pngEncoder := GuidBuffer("{557CF406-1A04-11D3-9A73-0000F81EF32E}")
    GdipInit()
    bitmap := 0
    DllCall("gdiplus\GdipCreateBitmapFromHBITMAP", "ptr", hbm, "ptr", 0, "ptr*", &bitmap)
    if !bitmap
        return 0

    DllCall("ole32\CreateStreamOnHGlobal", "ptr", 0, "int", true, "ptr*", &stream := 0)
    status := DllCall("gdiplus\GdipSaveImageToStream", "ptr", bitmap, "ptr", stream, "ptr", pngEncoder, "ptr", 0)
    DllCall("gdiplus\GdipDisposeImage", "ptr", bitmap)
    if status {
        ObjRelease(stream)
        return 0
    }
    ComCall(5, stream, "int64", 0, "uint", 2, "uint64*", &size := 0)    ; IStream::Seek to end = PNG size
    DllCall("ole32\GetHGlobalFromStream", "ptr", stream, "ptr*", &hGlobal := 0)
    png := Buffer(size)
    DllCall("RtlMoveMemory", "ptr", png, "ptr", DllCall("GlobalLock", "ptr", hGlobal, "ptr"), "uptr", size)
    DllCall("GlobalUnlock", "ptr", hGlobal)
    ObjRelease(stream)
    return png
}


; ================= Gemini API key (stored encrypted) =================

; Returns the saved Gemini key, or opens the setup window if there is none
GetKey() {
    k := LoadKey()
    return (k != "") ? k : KeySetup.Ask("first")
}

LoadKey() {
    if !FileExist(KeyFile)
        return ""
    stored := Trim(FileRead(KeyFile, "UTF-8"), " `t`r`n")
    if (SubStr(stored, 1, 6) = "dpapi:") {
        try return UnprotectText(SubStr(stored, 7))
        return ""
    }
    if (stored != "")
        try SaveKey(stored)                  ; Older versions stored it as plain text: encrypt it now
    return stored
}

; Asks Google whether the key works. Free: it only lists models, it doesn't read anything.
; Returns "ok", "offline" or a message for the user.
TestKey(key) {
    try {
        req := ComObject("WinHttp.WinHttpRequest.5.1")
        req.Open("GET", "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1", true)
        req.SetTimeouts(8000, 8000, 10000, 10000)
        req.SetRequestHeader("x-goog-api-key", key)
        req.Send()
        start := A_TickCount
        while !req.WaitForResponse(0) {      ; keep the window responsive while waiting
            if (A_TickCount - start > 15000) {
                req.Abort()
                return "offline"
            }
            Sleep(50)
        }
        if (req.Status = 200 || req.Status = 429)   ; 429 = valid key, just busy right now
            return "ok"
        body := ResponseText(req)
        if InStr(body, "API_KEY_INVALID") || InStr(body, "API key not valid")
            return "That key doesn't work. Copy it again from AI Studio."
        if (req.Status = 403)
            return "This key isn't allowed to use Gemini. Create a new key in AI Studio."
        return "Google answered with an error (HTTP " req.Status "). Try again in a minute."
    } catch {
        return "offline"
    }
}

; ---- "How to use" page: shown once after setup, and from the tray anytime ----
; ShowHowTo("refresh") rebuilds the page if it's open (after the shortcut changed)
ShowHowTo(afterSetup := false) {
    static g := 0, lastAfter := false
    refresh := false
    if (afterSetup = "refresh") {
        if !g
            return
        try g.Destroy()                      ; redraw only: the shortcut stays held
        g := 0, afterSetup := lastAfter, refresh := true
    } else if g {                            ; already open: bring it to the front
        try WinActivate("ahk_id " g.Hwnd)
        return
    }
    lastAfter := afterSetup
    if !refresh
        PauseShortcut()                      ; read first, then use: the shortcut works once this page is closed
    sc := ShortcutInfo()
    g := Gui("-MinimizeBox", afterSetup ? "QuickNotes is ready" : "How to use QuickNotes")
    g.BackColor := "FFFFFF", g.MarginX := 24, g.MarginY := 20
    close := (*) => (g.Destroy(), g := 0, ResumeShortcut())
    g.OnEvent("Close", close), g.OnEvent("Escape", close)

    g.SetFont("s15 bold c111827", "Segoe UI")
    g.AddText("w440", afterSetup ? "You're all set!" : "How to use QuickNotes")
    g.SetFont("s10 norm c4B5563")
    g.AddText("w440 y+4", "Copy text from anything on your screen, in any language.")

    AddShortcutCaps(g, sc, "xm+4 y+18")

    g.SetFont("s10 norm c111827")
    g.AddText("xm y+18 w440", "1.   " sc.sentence (sc.double ? ", quickly." : "."))
    g.AddText("xm y+8 w440", "2.   The screen dims. Drag over any text.")
    g.AddText("xm y+8 w440", "3.   It's copied. Paste it anywhere with Ctrl + V.")
    g.SetFont("s9 c6B7280")
    g.AddText("xm y+14 w440", "Esc or right-click cancels."
        . (sc.double ? " A single tap does nothing, so " sc.name " keeps working normally." : ""))
    g.AddText("xm y+6 w440", "QuickNotes lives in the tray, next to the clock: right-click its icon "
        . "for Pause, sound, your shortcut and this help.")

    g.SetFont("s10 c111827")
    g.AddButton("xm y+18 w150 h34", "Change shortcut…").OnEvent("Click", ShortcutDialog.Open.Bind(ShortcutDialog))
    tryBtn := g.AddButton("x+76 yp w110 h34 Default", "Try it now")
    tryBtn.OnEvent("Click", (*) => (close(), TryPrompt()))     ; the user presses the real shortcut
    g.AddButton("x+8 yp w100 h34", "Done").OnEvent("Click", close)
    g.Show("AutoSize")
    try WinActivate("ahk_id " g.Hwnd)
}

; ---- "Choose your shortcut" window (from the guide page and the tray) ----
class ShortcutDialog {
    static g := 0
    static keys := ["RAlt", "RControl", "LAlt", "LControl", "RShift"]
    static labels := ["Right Alt", "Right Ctrl", "Left Alt", "Left Ctrl", "Right Shift"]

    static Open(*) {
        if ShortcutDialog.g {                ; already open: bring it to the front
            try WinActivate("ahk_id " ShortcutDialog.g.Hwnd)
            return
        }
        ShortcutDialog().Build()
    }

    Build() {
        mode := IniRead(SettingsFile, "Shortcut", "Mode", "double")
        key := IniRead(SettingsFile, "Shortcut", "Key", "RAlt")
        combo := IniRead(SettingsFile, "Shortcut", "Combo", "")
        g := Gui("-MinimizeBox", "Choose your shortcut")
        ShortcutDialog.g := g
        g.BackColor := "FFFFFF", g.MarginX := 22, g.MarginY := 18
        ; While choosing, the current shortcut is off (pressing keys here must not start a scan).
        ; Closing the window in any way switches the saved shortcut back on.
        PauseShortcut()
        this.close := (*) => (g.Destroy(), ShortcutDialog.g := 0, ResumeShortcut())
        g.OnEvent("Close", this.close), g.OnEvent("Escape", this.close)

        g.SetFont("s14 bold c111827", "Segoe UI")
        g.AddText("w400", "Choose your shortcut")
        g.SetFont("s10 norm c4B5563")
        g.AddText("w400 y+4", "How do you want to start a scan? Pick what's easy on your keyboard.")

        g.SetFont("s10 bold c111827")
        this.r1 := g.AddRadio("xm y+16" (mode != "combo" ? " Checked" : ""), "Tap a key twice, quickly")
        g.SetFont("norm")
        idx := 1
        for i, k in ShortcutDialog.keys
            if (k = key)
                idx := i
        this.ddl := g.AddDropDownList("xm+22 y+6 w180 Choose" idx, ShortcutDialog.labels)

        g.SetFont("bold")
        this.r2 := g.AddRadio("xm y+18" (mode = "combo" ? " Checked" : ""), "Press a key combination")
        g.SetFont("norm")
        this.hk := g.AddHotkey("xm+22 y+6 w180 h26", RegExReplace(combo, "#"))
        this.win := g.AddCheckbox("x+12 yp+4" (InStr(combo, "#") ? " Checked" : ""), "with Win key")
        g.SetFont("s9 c6B7280")
        g.AddText("xm+22 y+10 w380", "Click the box, then press your keys, e.g. Ctrl + Shift + Q.")

        g.SetFont("s10 c6B7280")
        this.status := g.AddText("xm y+12 w400 h20", "")
        g.SetFont("s10 c111827")
        g.AddButton("xm y+10 w130 h32", "Reset to default").OnEvent("Click", (*) => this.Reset())
        g.AddButton("xm+212 yp w90 h32 Default", "Save").OnEvent("Click", (*) => this.Save())
        g.AddButton("x+8 yp w90 h32", "Cancel").OnEvent("Click", this.close)

        ; The two options are in separate rows, so keep exactly one of them selected
        this.r1.OnEvent("Click", (*) => this.r2.Value := 0)
        this.r2.OnEvent("Click", (*) => this.r1.Value := 0)
        this.ddl.OnEvent("Change", (*) => (this.r1.Value := 1, this.r2.Value := 0))
        this.hk.OnEvent("Change", (*) => (this.r2.Value := 1, this.r1.Value := 0))
        this.win.OnEvent("Click", (*) => (this.r2.Value := 1, this.r1.Value := 0))
        g.Show("AutoSize")
        try WinActivate("ahk_id " g.Hwnd)
    }

    Say(text, color := "DC2626") {
        this.status.SetFont("c" color)
        this.status.Value := text
    }

    Reset() {
        this.r1.Value := 1, this.r2.Value := 0, this.ddl.Choose(1)
        this.Save()
    }

    Save() {
        if this.r1.Value {
            IniWrite("double", SettingsFile, "Shortcut", "Mode")
            IniWrite(ShortcutDialog.keys[this.ddl.Value], SettingsFile, "Shortcut", "Key")
        } else {
            hk := this.hk.Value
            if (hk = "") {
                this.Say("Click the box and press your keys first.")
                return
            }
            combo := (this.win.Value ? "#" : "") hk
            ; Needs Ctrl/Alt/Shift/Win (or an F-key), so normal typing keeps working
            if !RegExMatch(combo, "^[#^!+]+.") && !RegExMatch(hk, "i)^F([1-9]|1\d|2[0-4])$") {
                this.Say("Add Ctrl, Alt, Shift or Win, so normal typing still works.")
                return
            }
            if RegExMatch(combo, "i)^\^[acvxzyswpfn]$") {
                this.Say("That's a common shortcut (like copy or paste). Please pick another.")
                return
            }
            ; Windows' own Win shortcuts: Win + L can never be taken over, and taking
            ; the others (Win + D, Win + E...) would stop them doing their usual job
            if RegExMatch(combo, "i)^#[a-z0-9]$") || RegExMatch(combo, "i)^(\^!|!\^)(Delete|Del)$") {
                this.Say("Windows already uses that shortcut. Add Ctrl, Alt or Shift, or pick another.")
                return
            }
            ; Ctrl + Alt types special letters on many keyboards (AltGr), e.g. Ctrl + Alt + E
            if RegExMatch(combo, "^[\^!]{2}[^\^!#+]") && InStr(combo, "^") && InStr(combo, "!") {
                this.Say("Ctrl + Alt types special letters on some keyboards. Add Shift or Win.")
                return
            }
            try {
                Hotkey(combo, (*) => 0, "On"), Hotkey(combo, "Off")
            } catch {
                this.Say("That shortcut can't be used. Please try another.")
                return
            }
            IniWrite("combo", SettingsFile, "Shortcut", "Mode")
            IniWrite(combo, SettingsFile, "Shortcut", "Combo")
        }
        ApplyShortcut()
        UpdateTray()
        ShowHowTo("refresh")
        this.close()
        Notify("Shortcut saved: " ShortcutInfo().text)
    }
}

; ---- the setup window ----
; mode: "first" (no key yet), "change" (from the tray), "invalid" (saved key stopped working)
class KeySetup {
    static busy := false
    static hwnd := 0

    static Ask(mode := "first") {
        if KeySetup.busy {                   ; already open: bring it to the front
            try WinActivate("ahk_id " KeySetup.hwnd)
            return ""
        }
        KeySetup.busy := true
        try return KeySetup().Run(mode)
        finally KeySetup.busy := false
    }

    Run(mode) {
        this.result := ""
        g := Gui("-MinimizeBox", "QuickNotes setup")   ; NOT always-on-top: the browser must be able to come forward
        g.BackColor := "FFFFFF", g.MarginX := 22, g.MarginY := 18
        g.SetFont("s14 bold c111827", "Segoe UI")
        g.AddText("w420", mode = "first" ? "Set up QuickNotes" : "Change your Gemini key")
        g.SetFont("s10 norm c4B5563")
        g.AddText("w420 y+6", "QuickNotes uses Google Gemini to read text in any language. "
            . "It needs a free API key: one time, about a minute.")

        g.SetFont("s10 bold c111827")
        g.AddText("w420 y+16", "1.  Open Google AI Studio and sign in")
        g.SetFont("norm")
        g.AddButton("xm+20 y+6 w170 h30", "Open AI Studio  ↗").OnEvent("Click", (*) => Run("https://aistudio.google.com/apikey"))
        g.SetFont("bold")
        g.AddText("xm w420 y+14", "2.  Click " Chr(0x201C) "Create API key" Chr(0x201D) " and copy it")
        g.AddText("w420 y+12", "3.  Paste it here and click Test")
        g.SetFont("norm")
        this.tested := ""                     ; the key Google confirmed (Save only works for this one)
        this.edit := g.AddEdit("xm+20 y+6 w318 h28 -Wrap")
        this.edit.OnEvent("Change", (*) => this.OnEdit())
        this.testBtn := g.AddButton("x+8 yp w74 h28 Default", "Test")
        this.testBtn.OnEvent("Click", (*) => this.Test())
        this.status := g.AddText("xm+20 y+8 w400 h20 c6B7280"
            , mode = "invalid" ? "Your saved key stopped working. Paste a new one."
            : mode = "change"  ? "A key is already saved. Paste a new one to replace it."
            : "Tip: once you copy the key, it appears here by itself.")
        g.SetFont("s9 c9CA3AF")
        g.AddText("xm w420 y+12", "Only the area you select when scanning is sent to Google. "
            . "Your key is stored encrypted, for your Windows account only.")
        g.SetFont("s10 c111827")
        this.saveBtn := g.AddButton("xm+234 y+16 w90 h32 Disabled", "Save")   ; grey until the key passes the test
        this.saveBtn.OnEvent("Click", (*) => this.Save())
        this.cancelBtn := g.AddButton("x+8 yp w90 h32", "Cancel")
        this.cancelBtn.OnEvent("Click", (*) => g.Destroy())
        g.OnEvent("Close", (*) => g.Destroy())
        g.OnEvent("Escape", (*) => g.Destroy())
        if (mode = "invalid")
            this.status.SetFont("cDC2626")

        this.gui := g, KeySetup.hwnd := g.Hwnd
        clipWatch := ObjBindMethod(this, "OnClip")
        OnClipboardChange(clipWatch)          ; key copied in the browser -> fill it in
        if (mode = "first")
            this.Fill(A_Clipboard, false)     ; maybe it's already copied
        g.Show("AutoSize")
        try WinActivate("ahk_id " g.Hwnd)    ; open in front (once), then behave like a normal window
        WinWaitClose("ahk_id " g.Hwnd)
        OnClipboardChange(clipWatch, 0)
        return this.result
    }

    ; Gemini keys look like "AIza" + 35 letters/digits. Fills the box when the key is copied.
    Fill(text, manual) {
        t := Trim(text, " `t`r`n")
        if RegExMatch(t, "^AIza[\w-]{30,}$") {
            this.edit.Value := t
            this.OnEdit()
            this.Say("Key pasted. Click Test to check it.", "2563EB")
            try WinActivate("ahk_id " this.gui.Hwnd)  ; key copied in the browser -> come back to the front
            try this.testBtn.Focus()
        }
    }

    ; The key changed: it has to be tested (again) before it can be saved
    OnEdit() {
        ok := this.tested != "" && RegExReplace(this.edit.Value, "\s") = this.tested
        this.saveBtn.Enabled := ok
        if !ok {
            this.saveBtn.Opt("-Default"), this.testBtn.Opt("+Default")
            if (this.tested != "") {
                this.tested := ""
                this.Say("Key changed. Click Test to check it again.", "6B7280")
            }
        }
    }

    ; Disables everything while testing; afterwards Save is only enabled for a tested key
    Lock(busy) {
        for c in [this.edit, this.testBtn, this.cancelBtn]
            c.Enabled := !busy
        this.saveBtn.Enabled := !busy && this.tested != "" && RegExReplace(this.edit.Value, "\s") = this.tested
    }

    OnClip(type) {
        if (type = 1 && Trim(this.edit.Value) = "")
            try this.Fill(A_Clipboard, false)
    }

    Say(text, color := "6B7280") {
        this.status.SetFont("c" color)
        this.status.Value := text
    }

    ; Checks the key with Google. The window stays open; Save turns on only if it works.
    Test() {
        key := RegExReplace(this.edit.Value, "\s")
        if (key = "") {
            this.Say("Paste your key first.", "DC2626")
            this.edit.Focus()
            return
        }
        this.tested := ""
        this.Lock(true)
        this.Say("Checking the key with Google...", "6B7280")
        r := TestKey(key)
        if (r = "ok") {
            this.tested := key
            this.Lock(false)
            this.testBtn.Opt("-Default"), this.saveBtn.Opt("+Default")
            this.Say("✓ Key works. Click Save to finish.", "16A34A")
            this.saveBtn.Focus()
            return
        }
        this.Lock(false)
        this.Say(r = "offline" ? "✗ Couldn't reach Google. Check your internet and test again." : "✗ " r, "DC2626")
        this.edit.Focus()
    }

    ; Saves the key that passed the test
    Save() {
        key := RegExReplace(this.edit.Value, "\s")
        if (this.tested = "" || key != this.tested)
            return                            ; (button is grey in this case anyway)
        SaveKey(key)
        this.result := key
        this.gui.Destroy()
        Notify("Key saved")
    }
}

SaveKey(k) {
    try FileDelete(KeyFile)
    FileAppend("dpapi:" ProtectText(k), KeyFile, "UTF-8-RAW")
}

; Windows DPAPI: only your Windows account on this PC can decrypt it
ProtectText(text) {
    data := Buffer(StrPut(text, "UTF-8") - 1)
    StrPut(text, data, "UTF-8")
    inBlob := Buffer(A_PtrSize * 2, 0), outBlob := Buffer(A_PtrSize * 2, 0)
    NumPut("uint", data.Size, inBlob, 0), NumPut("ptr", data.Ptr, inBlob, A_PtrSize)
    if !DllCall("crypt32\CryptProtectData", "ptr", inBlob, "ptr", 0, "ptr", 0, "ptr", 0, "ptr", 0, "uint", 1, "ptr", outBlob)
        throw Error("Couldn't encrypt the key.")
    p := NumGet(outBlob, A_PtrSize, "ptr"), size := NumGet(outBlob, 0, "uint")
    encrypted := Buffer(size)
    DllCall("RtlMoveMemory", "ptr", encrypted, "ptr", p, "uptr", size)
    DllCall("LocalFree", "ptr", p)
    return Base64Encode(encrypted)
}

UnprotectText(b64) {
    data := Base64Decode(b64)
    inBlob := Buffer(A_PtrSize * 2, 0), outBlob := Buffer(A_PtrSize * 2, 0)
    NumPut("uint", data.Size, inBlob, 0), NumPut("ptr", data.Ptr, inBlob, A_PtrSize)
    if !DllCall("crypt32\CryptUnprotectData", "ptr", inBlob, "ptr", 0, "ptr", 0, "ptr", 0, "ptr", 0, "uint", 1, "ptr", outBlob)
        throw Error("Couldn't decrypt the key.")
    p := NumGet(outBlob, A_PtrSize, "ptr"), size := NumGet(outBlob, 0, "uint")
    text := StrGet(p, size, "UTF-8")
    DllCall("LocalFree", "ptr", p)
    return text
}

Base64Encode(buf) {
    DllCall("crypt32\CryptBinaryToString", "ptr", buf, "uint", buf.Size, "uint", 0x40000001, "ptr", 0, "uint*", &chars := 0)
    out := Buffer(chars * 2)
    DllCall("crypt32\CryptBinaryToString", "ptr", buf, "uint", buf.Size, "uint", 0x40000001, "ptr", out, "uint*", &chars)
    return StrGet(out, chars)
}

Base64Decode(b64) {
    DllCall("crypt32\CryptStringToBinary", "str", b64, "uint", 0, "uint", 1, "ptr", 0, "uint*", &size := 0, "ptr", 0, "ptr", 0)
    out := Buffer(size)
    DllCall("crypt32\CryptStringToBinary", "str", b64, "uint", 0, "uint", 1, "ptr", out, "uint*", &size, "ptr", 0, "ptr", 0)
    return out
}

GuidBuffer(str) {
    buf := Buffer(16)
    DllCall("ole32\CLSIDFromString", "wstr", str, "ptr", buf)
    return buf
}


; ================= helpers =================

Notify(msg) {
    ToolTip(msg)
    SetTimer(NotifyHide, -1500)               ; one named timer: a new message always gets its full 1.5 s
}

NotifyHide() => ToolTip()

; Puts text on the clipboard. Another app can hold the clipboard for a moment
; (clipboard managers, remote desktop), so retry briefly instead of failing.
; Each attempt already waits up to ~1 s inside AutoHotkey, so 3 tries is about 3 s at most.
CopyToClipboard(text) {
    loop 3 {
        try {
            A_Clipboard := text
            if (A_Clipboard == text)
                return true
        }
        Sleep(100)
    }
    return false
}


; ================= pause / options =================

TogglePause(*) {
    global IsPaused := !IsPaused, LastTap := 0
    Suspend(IsPaused)                 ; Right Alt is completely normal while paused
    UpdateTray()
}


; ==============================================================================
; TRAY MENU + START WITH WINDOWS  (same block as the other scripts)
; ==============================================================================
SetupTray() {
    tray := A_TrayMenu
    tray.Delete()
    tray.Add(AppName, (*) => 0)
    tray.Disable(AppName)
    tray.Add()
    tray.Add("Scan text on screen", StartScan)
    tray.Add("How to use", (*) => ShowHowTo(false))
    tray.Add("Change shortcut…", ShortcutDialog.Open.Bind(ShortcutDialog))
    tray.Add()
    tray.Add("Pause", TogglePause)
    tray.Add("Start with Windows", ToggleStartup)
    tray.Add("Sound when copied", ToggleSound)
    tray.Add("Change Gemini API key", (*) => KeySetup.Ask(LoadKey() != "" ? "change" : "first"))
    tray.Add()
    tray.Add("Exit", (*) => ExitApp())
    tray.Default := "Scan text on screen"   ; Double-click the tray icon = scan
    OnMessage(0x1A, OnThemeChange)    ; WM_SETTINGCHANGE: follow light/dark taskbar
    UpdateTray()
}

UpdateTray() {
    RefreshIcon()
    A_IconTip := AppName (IsPaused ? " (paused)" : " - " ShortcutInfo().text " to scan")
    if IsPaused
        A_TrayMenu.Check("Pause")
    else
        A_TrayMenu.Uncheck("Pause")
    if StartupEnabled()
        A_TrayMenu.Check("Start with Windows")
    else
        A_TrayMenu.Uncheck("Start with Windows")
    if SoundOn()
        A_TrayMenu.Check("Sound when copied")
    else
        A_TrayMenu.Uncheck("Sound when copied")
}

StartupTaskName() => AppName " (AutoHotkey)"

; True if a logon task exists AND points at this script's current location
StartupEnabled() {
    try {
        svc := ComObject("Schedule.Service")
        svc.Connect()
        task := svc.GetFolder("\").GetTask(StartupTaskName())
        return InStr(task.Definition.Actions.Item(1).Arguments, A_ScriptFullPath)
            || task.Definition.Actions.Item(1).Path = A_ScriptFullPath
    }
    return false
}

ToggleStartup(*) {
    try {
        svc := ComObject("Schedule.Service")
        svc.Connect()
        root := svc.GetFolder("\")
        if StartupEnabled() {
            root.DeleteTask(StartupTaskName(), 0)
        } else {
            user := EnvGet("USERDOMAIN") "\" A_UserName
            td := svc.NewTask(0)
            td.RegistrationInfo.Description := "Starts " AppName " when you log in."
            td.Principal.RunLevel := 0                   ; Normal rights: QuickNotes doesn't need admin
            td.Principal.LogonType := 3                  ; Only when the user is logged on
            td.Settings.DisallowStartIfOnBatteries := false
            td.Settings.StopIfGoingOnBatteries := false
            td.Settings.ExecutionTimeLimit := "PT0S"     ; Never stop it
            td.Settings.MultipleInstances := 2           ; Don't start a second copy
            td.Settings.Priority := 4                    ; Normal priority (default is below normal)
            trigger := td.Triggers.Create(9)             ; At log on
            trigger.UserId := user
            action := td.Actions.Create(0)               ; Start a program
            if A_IsCompiled {
                action.Path := A_ScriptFullPath
            } else {
                action.Path := A_AhkPath
                action.Arguments := '"' A_ScriptFullPath '"'
            }
            action.WorkingDirectory := A_ScriptDir
            root.RegisterTaskDefinition(StartupTaskName(), td, 6, user, , 3)
        }
    } catch as e {
        MsgBox("Couldn't change the startup setting:`n`n" e.Message, AppName, 48)
    }
    UpdateTray()
}

; ==============================================================================
; TRAY ICON  (built into this file, so the script works on its own anywhere)
; White lines on a dark taskbar, black lines on a light one; faded when paused.
; ==============================================================================
RefreshIcon(*) {
    try TraySetIcon("HICON:*" TrayIcon(IsPaused, TaskbarIsDark()), , true)   ; true = keep our icon even while suspended
}

TaskbarIsDark() {
    try return !RegRead("HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "SystemUsesLightTheme")
    return true
}

; Windows broadcasts this when the theme (light/dark) changes
OnThemeChange(wParam, lParam, msg, hwnd) {
    SetTimer(RefreshIcon, -300)
}

TrayIcon(paused, dark) {
    static cache := Map()
    key := paused "|" dark
    if cache.Has(key)
        return cache[key]
    data := IconData(paused, dark)
    want := SysGet(49)                 ; Tray icon size for the current display scaling
    best := 0
    for size in data                   ; Sizes are sorted: take the first one big enough
        if (size >= want) {
            best := size
            break
        }
    if !best
        for size in data
            best := size
    png := Base64Decode(data[best])
    return cache[key] := DllCall("CreateIconFromResourceEx", "ptr", png, "uint", png.Size, "int", 1, "uint", 0x30000, "int", want, "int", want, "uint", 0, "ptr")
}

; PNG images of the tray icon at several sizes, as text
; d / dp = dark taskbar (normal / paused), l / lp = light taskbar (normal / paused)
IconData(paused, dark) {
    static d := Map(16, "iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAFBSURBVDhPrZLLLoNRFIX/ujWSFhHiFp3xEEzM3B5AExJjUlUxMSF1ewVPYOA9JC4TMwaGHoEp35J9sg9/T/4YYCU76b/W2pfTvbMsyzKgH6gDO0AD2JZUM03SOLDlvOkbwIBpAUAVuFcCM7q+WqA9ShqJBdadXAMmLayrpFJs4lMEDVh2fzMW2HPie6wfIKnb/WeBAHadmErNRZA05P7jQOQmGJPUJekAuEhDUltSn6SK+89jxZr/DyWgDDwAr0m8Ac+SBr2pbWymc7bfwkYHVuy3pF7gErjJxTUwn+QsAtPxo+lvGpXUA1wBd7m4lbSQS666/yQSrX/ZggmpuQj2TC9wGghg04klOyYLW1WSVHHNzn7O/fuxwDDw5FMEAB+2Ktet8Huiv3Q82Ys0/FjawBEw693tTg5zWguY+Er+Kz4Bz9wWA/JlvTgAAAAASUVORK5CYII=",
        20, "iVBORw0KGgoAAAANSUhEUgAAABQAAAAUCAYAAACNiR0NAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAGqSURBVDhPtZTPSpVRFMXNSqMIwj+jGlkNIlCaqpAKJs3qdhNqWNBA8AFsZKggIoiQiILoUJrkO/gEvkLNIgtqEJT8VuzbOh/Hw1WukAsO33fXXnvt7569z2lrM4DrwBAwKmkEGAP6U9yae8E7HrphoCvXNGDBJzUBcNuanjIWAL4AT3OzG0E6uAdsAJt+zgPXrOsA3uZxSR+c9wu42TAEHpr8WFU5A2wc+bVETJh4X4pbgaRZ5082CGDcxEYpbgXAgrfzeSIe23A7iSRdldR30oqJyAyXnP8iEQ+AP8CczS4CB67aFMDn1CxgGjiKMUpFgrwj6YoN24EVYP+UtRVdt/4ScLcyOxcA3ZIuxHs8o2OSFstVdbJADH31A7gPHAIzDsZf+FruWwD4Julybga8Br4Dg4lodFnSTiYaAOpN1kBuZu2yi71MxH+fw0c2XCvFrQB45/zqpMQ1FMRuKW4FwKrz64noBX7yD+s+m7NRGZgCOkPnZr3yFyXNqm8a4gTlVZ4BP7wXxxBDnwqXsQDwW9KbyiwzvSXpSWxuWr6d2zPNUBGvHfuy88Bfft71EBFph5YAAAAASUVORK5CYII=",
        24, "iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAHSSURBVEhLzZW/S5ZRFMcN097KQAR/VRZpg6mLoLa5ugURjYGbQ/QvlIuDkw5CUZMViLyLODtFf4GLkyAEbQ2i9LvPN87LvQ/Hw6O9z/LmFw4P3Odzvod7uOfetjYnSZ3AEHA7h6Rbki54znQKdyVyhYBnwD7wE/gN/HLfrcC+Cv/z9xPwwrM54anOELAT+PeR8QKWPHwZ+Jx+1IEpYNyHpJovIOkiMBa4SeBl8vkB9OcCd1zxUW9UVUCPtTgVmc6LI25r92JSFUkaAL4mr5m8OOwKjMekKgKuA99O7KDVBSYc/BB4ayfmjHgnaT7PiRVwXvdzgRqwbUdRUpcr0DhZzchOYvLqADaBD5K6s1epgAfA6ybiScw9HwJuAI8kPY4BzNmwxZxSpb7Z3bLuJxbYjb32AhZOOjW82oEVYAO4mo2KSfbHNIEHp8QeMOvNTTZozqt0kotjmhI6ysIzXqmt35PX/5nksZhURcDgvwrcjUlVZMNlV3XyKlrUBXxJi2vpKezzEY1MQK/d+Y6z9jxPPn+AmwUsadHtwh6L4xAbwXwVOApMozXJ443nc9IycJghL+BjYOuRMdlbYObAJc8XSg+GPZnTIa4Fzi7IMm7Icy3RX0niIeCVnZ7zAAAAAElFTkSuQmCC",
        32, "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAItSURBVFhH7Ze7axVREIdjFB9EFLHQStHCQoQ0lhY2ItjZKEkhWAgWCoLgo1VQjBLRYHx3YmGiMaDxAfk/1MpGFLRQsFL4fjLL3MvcYbN3vXfBCPlgiju/meHcPWdnzg4MLLEYkbQWOAKMAeMldlzSipSzDBgpiTW7ZjnApphTCjAMvFcXgJ0pb2OOyQBfgH0xrwNgHfDRg38Bb4HpZE+By5JWx1xJy4Ezrsf4KWAO+OF1f0raEnPbAEdD0J6s9wOwA/jk9S9mvQC44QFzWWsC4LbXn8laATDp2/Uka00AXPcFzGatALjlAdNZa4LwhJ9nrWBRLwA4AFwBrnp/WMha+oj1hlSj6wIeeMCL5B/ys/FXAFtTnTvufx39bYATHnAp+iUNSjrn73Mde+VPYlWs4x3U6o9FfwfW4aypZH9TeP2ONl4L4KDtITAB3Kywlm5NbTDX6YmmzkDP2D8BTgHPatoMcEHSylyrK5I2ZF+TVNYHRoFvwOkSzWb9PXtVgfvJzDcJ7M55EeCw1z+btQLgoe/dy+SvdQaA+ZiXAe563JusFSzUCf22YzeaxxX2SNLemJep0wlLF9AU/8UC/vl9YKJyhX1iHbLbAk56wFdJ27PeD5LWA++8/njWCyRtlvTdgz7b+PQ7QJ75x8oGFnCoJNbybT588O212rtybhtgf2sRVfT4XfDbhlTMKwXYZr3c7/izdiaC2W+b9Wtijn8XnE+xLbP5YDnDMWcJ4w/svBMiDAXjnwAAAABJRU5ErkJggg==",
        40, "iVBORw0KGgoAAAANSUhEUgAAACgAAAAoCAYAAACM/rhtAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAALaSURBVFhH7ZhNiE5hFMdHQspXvkKIfIyITMjXQvkYG3byUSQaLEwhGxZW2KGZKGWh7CxYWLCxsbGyUApNZGNhGkRENn5HZ3ru7Xn/c+997x3vGzXvr05v3fPxnPve+5xz7tPW1mIkY2YTgA5gU45sNLPJ6pdgZmOBDRl+LpuBdWY2Xf3qYmZjgIvAe6sD8DIrSTMbDTxSewX4DNwCpmmMTMJdP9ZARQBzNQ4wDhhQ2zyAV8BMjTME/+cip9/AA+A60CPSG353aYyE8HivRbbqfxf4Hq13T2PUAEwEPgXjX8BOtWk0wArgQ5Rku9qkAGsjw/uqbxbApWjdA6pPAbZFhldV3yyAk9G6R1WfAmyNDHtU3yyAU9G6R1Sf0kowh4YmCExyO6AT2FFSOs1su5nN0nhOlQTjTTIkwdD6nic2VQnlZL7GBU5HNqUTvKl675tevNMVh8dqjQucjfTHVZ8CzAgt5yewW/WO3wRwxctQ+C0jbuuyT+M5nnToyQNeuFVfQ3iM8/R6s/E+7H+QXq+Mv+jAHmB/RdkLLNF4DSXs4LfR+1IJHwyARRq3YQBTgR+6cBWAlRq3oYSB4hxwfhjSqfGGhU/Deu2/IOzgh0AfsF71DrAYOAF0+xSSI91ez7KKchZmtsAbAPAsazpPAbZE78oN1ZvZFKC/9q3KB3gDjNc4irS6wnEr7iS9qg8JfkwzqAPwrmSCZyKfwgTLDAvtQJc/QuBYlgRdF7BQ/bOoMizUTbAZtBL8W6ok+K8+mrwsJesWbhI/a0kM76i+WXiXidY9pPqUMA8O9towny1Vm0bj5zrA6yjBDrWpAbgdGfcDl0PnGCwfsYSykjtgeldISpJK8L0gyT01s1Eap4Yw1vclTvUAvmUd+oQTMj/5KgXwpehmawBm+0FOye+PrwUJvlDjHJ4AqzRGXYDlflbiO8u3v8jgNTNbpn4JwBzgcIH/QTNbo34tRhR/AMV66ySVa7q9AAAAAElFTkSuQmCC",
        48, "iVBORw0KGgoAAAANSUhEUgAAADAAAAAwCAYAAABXAvmHAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAANxSURBVGhD7ZlJqE5hGMfNhAzJPJZ5WCllgTIuDLFgL2TKgkxJWVgopWwsKCHK6mYjFmKjFBJlWshUhjJlyHSj31+P3qP3Pvec7zv3XOe70ferZ3PO8/zP+5zzDs/7nnbt6tSpk4mkCcA+4DJwB7hbwW4Ba7xGDDAXuJYS6+0qcBiY6TVyA2wBvqmFAP29VgLwwPtXAzgkqYPXqgiw2QvlAbgP9PB6CUCDj8kDcMxrZQKMA344gTPAHmArsD3FdljSwDCvFyOpJ7A++HsNs23AbuA48MW1YYnXSwU4EAX9lLTC+9QCYCrwOmrLRe+Tig2gKKjB368lwK6oLe+AXt6nCZI6xgPNPqv3qSXAwqgtNqGM8D5NkNQZeBQFbfM+tQRYHLXla94EHkZBbf0FltQT8D61pPQEJHWX1EdS74LW02vGlJaApPbAXuC5zdXAqwJmcS+BU/Yi/DOMogk8joJ2eh8DGJv4/CWW+WcYwNLEwaZRYKT3aYIVTcCTKCh1GrVuU6QwSwP4DEzyzzCABc53iPdpBrBO0gfgtqRR/n4CMFjSSmA1sKqAJXFTvHaCFYbAeeATcNC6rvdJBRggqYu/3lZIGuSv/RWA4cAYYHQBG1PpC5eKpE7AUZsZrPRuhX0HLknq659RKsD4eHC1FmC5f0aphMF1xTekCMCzNulKtviETfqCVtj80gboPwswB7gOnLZ6xd9PCOXENDv6kDSjkpkPMF1SN69TibCw7gdu2rrh7zcjNOpe1D/Xex/DGgKca9qbqxPOjjKPXTzhBSSxjVVjQy30NAra5X2M1sxCwCKvl4XVSFFcY9XBnrcaBbraUcufVuUknMr183pZFK1GqyaQAEy0WianTW5peVJ6AmVTT+B/SCB1Q1MriiRgVWacwFbvU0v8yVzVLaVhq14UdMTfryWS1kZt+ZhrCpZ0IgkKW8vMLV+ZWBkTVwWSbuTaUsbLtwG8sRXZPicwO1SgaTbLuqDX84SaaF5KvJnVYValbrRfTa4dG7xWJtZ14uC8AGdtIvB6CVaY+Zg8hL1Hpm4zwjH7SS+UB2Cg10sAXnj/aoQfjJWLuCxsqwdcAN6GWcDM9sHe7Lqd79jRR+YPufB76X0Fnd9aYezZn8pN9jK9TouxTbfNwZUMGOrj0rAjG5sOfXykM9J8fFydOnXS+QVziwbIivoU1AAAAABJRU5ErkJggg==")
    static dp := Map(16, "iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAFBSURBVDhPpZPNSwNRDMRXrVVb8ShCe6kfB2sRbE+ioHe1Cp4EQauo1I////YbmUee7i6iqIGwu8nLvGQmWxRFUUiaAzaAPrAdz7ZzwFIpZt+SNO9cMn8AY+ANeAh/MWAAdIFpKedzl5IWM8B6BHuSWnbf+nFDdFHKdeKCfk7uGLnS1jcmaQaYAMMUiLkM0Kof/sokNYE7YC8FogO35DaNvivpENgv+YELJM0GZ0+SRhmgnQkLNcaSboHrkt8Ecc2o6QErldb+bKFz1+9uETgCzoET4DTeV2s1ViLtSSZxal3NgaTjKHLxmaQLSWu5ODjwPnySKOnxlyrcl2XMe5AI+slizMoebMYmdtxeeKNW1Mg58xGyDzLAgiUCXgN54pEsVeRNmGdOOeAZuKqMHHN5lGEszCjrLGk5x+M5qP8r/7J3zJniX/s9EjYAAAAASUVORK5CYII=",
        20, "iVBORw0KGgoAAAANSUhEUgAAABQAAAAUCAYAAACNiR0NAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAGnSURBVDhPtZTbS1ZREMU1TUPwQwzSUjSFBHswvFWKouBbD/YmqBReKrIo8/bv/5as08xps/HhC3RgHvacxZrZZ63ZPT0RkvoljQPPI18Ao/k9MCNRbzDGSxooMQk00QHwq8hz4DswHJgnwAnwp8J9kjRVkg0A+8AZsAOsR24CS548cI+AN1FvMJK2ga+SjiQNldO5007b5T8iyD31dBYmgvB9De4mgMUgnMmCf7IJ12twNyFp2YSSXjaFmPBc0kYB6gc6FuSO7Eh6nFhgFbiUNJuFp6HmUpD1Ah+BH5K+1Rni7aVYwGvgp22UTVwcltRXEL4DdoEPd+Sub2PVA2/1Oy3Zg4S96MnybMWAt8BKkT7/VbIKYLA9xDp5Axbi7Ct7a25iWzKvgcO8akE2Z3MDz7IwGT7aLECjVs1WKHK23u3AevKrUuV792ESrtXgbsJ2qwn9FP0GtmpwNxEWu2gJ41n6HD92LXZzMa4yX/nzVSjeYILsGDjNZy67TMcHi5N5GRvQmDYau+lVhftipVuyDL9nHtteK1T1q1z6cyzVD686/032EHEL5p2sqe7/aDMAAAAASUVORK5CYII=",
        24, "iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAHaSURBVEhLzZVLa1RBEIUTR42a+Ag6uBB8IuIuoER8KwqKbtz4BOMjvhITURB//nfkjNXXmnIyeDfGA2dxq09V9e2uqp6ZSZC0Q9LCBM5mXWirxtxZdR2A88BTSa8zgffAnaK9YnvRvQGeS1rK2ubg4J+DDvgucQ24X/Q3gPWiM23blHShE0saeOexeFvSEUmLhYOcII5yTAMcBi4Dn4BXwN4mXojf8y8fzIH6ApiLI/vgjTbj/kiwKulQdeoD7xpYmZZgsTr1gaR925PABl9OTgCc8KUDN6NqKm33+tmSYDWqcdiMA0l3gXuSdqUEz4AfwNcp/O6/b1UW1XULeChpd4s1EZKOx06vTqHXz1Tf/wM+T0mngVOSTibadmzSfJoIn1vMluu5YyU9Ar6lEdK4EfZz45FGPrPAsu+hG3wxBV1Fa6WKloEXkh5nAk+CR3Pw8HGjuYo2/qoPoir+YNZkbNkHWyXoi21P4Hl+oDr1gZvLo3osgbvXlxnvgef5vKQ9Zlzar7le0NabNsp6CfgYG57PYi9spsfiZeJbz50cHLgU9qxbieBf3OVZ35wupt/rGLX/oGg95FyKWTfauaRr9QXsEEcyjGdzxPjuhqARz+wwa+P797H8K/wEKeC4kU+r5ngAAAAASUVORK5CYII=",
        32, "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAIeSURBVFhH7ZdZa1RBEIUTd1FRg6CoIIqRKMaH6CRuKNmMPougKIrbg0vcH/z135FzqRl6yp6FyQUN5EC9dPWp7ltUna47NbWD/xGS9gCzwGLFbkmakzRd4V2wv8KxXZZ0IHP+AjAj6QnwGfgKfEv2A9iUdCzx9gPvgZ8VjuNsAs+B0yWvD5L2Foe/AjaAZWCla5LWJF2XtDtxp4F5YL3cH3yvvQA+AS+BQyW3h0h79/CT2b8VSDoKPAO+AAvZ3wBYinStZ18biPpw/NXsawDcjg3L2dcGohiHXqB7w5XsawNFhrfhBYCzEaAzhi1ZEyoxhl9A0l3gey7CEKbXwK8IMMqsFR8lHS7jRI05/oNyvQerldvEfV6uR49fAx5FT48y7+tUtGIuBKlTrvfBCleT2bYwcXzgXKTw5hjmfbMTHVRDWzUwMaIGrrh4ks4PMu9bkLQrxxoJSfvyWpsYGj/ecz+pVwf47gF3srl9w05kXgngfMSfz74GoQN+z2s68CZqIL/1jUn6DTwseRlRnI6/kX0Nhilh9PAqcH+AeVY4lXklRirhsAu0gW11gX82D1jFXFT1DVvEOBmw2HSn1yPZvxW4/4HHMRMuZn8D4GAxvT6NtrmRzF9xqabz0ef2Z44z68M/AG8lHc/cHoAzMRX7pk5X7nm/55P8FzjeO+BiyavCj0jM/mvR+6VZ52tvfXdm8L9EHyfiODMzJWcHxh8frX27VJwiOQAAAABJRU5ErkJggg==",
        40, "iVBORw0KGgoAAAANSUhEUgAAACgAAAAoCAYAAACM/rhtAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAALqSURBVFhH7VhpaxRREIxG423UeAc/aC6j4omJCQqKih8UvPLBaAzeRqP+/09VUlIzzPa+OXadRSFbUCxsv+5X75junhkZGWIrg+QOABMAjpfwBMmd0S8Dye0JnyKPkdwd/WqhwCRvAFgF8KmCGwCekxxLxNgG4CGAbwm/It+SvA1gV4yRhFf9CMAmyS8WoUlS/OFJ9iXijHqBvxJ+OT3HJoCXjXYTwHU7aOL3AO4DuAVgMcFlAGdijAw6QgBLCb8/JHlXOwjgs+e8F2N0QPcJwGuvSuIm45i2QfKQ5rTIDyTH45gcJI8W7lb1alqET01HvkHyXLTnAHDKK9HghWgfFADMZwIBzEZ7jiBwMdoHBQAXCgJnoj3HUGAJWhXoJ33SPN2Q2fg9MZ7QmkCLe5ol2F7oyZW4u5J6LwK1Wg1UhViOdmV6ku9sz6tBQyoR6/dIjAvgkmNqzFy055AAAC+cC5MVwrusyrIA4GYPlM/ZGE+QaFeUNSXuaO+AO5iuYxg0vDnNGoYq6KIr24vakSb02CkAB2O8VuGHZMV3RRf6a0Nq7HcA6wAOxLitQUfgu9LXQ+In+nCM2yrUUJC8CuByj7ymLBHj9QV1w/G//wJ+gtWmv1KzGe2CLroTqzqQOjbKBiT369XBRaDch+RJ3xe16UsJ+5jFN7mDP93Gj8Y4EV6w5pRPbSWpKnUSqHIlgXoyq6jJVnQqMU4EgIues7bUVdZiQS25j2+uiiTP6+iifwq91OJagYPAUODfol+B/+qlqVKgvpdkAu9E+6DgSpMJnIr2HG559K1EHbB+y1+iW4JTl/Kl5tTmTMQxHfCHHHUrGrzqj0hdacScr2owVRWUbhJ+4iyAK2qQLU47+Li2zHoX1VKpPcqOOybhjErYa6mXIX+EUvlSwi6LkX08kn29arEdcFP6AMDHRNAitdNvygSSfGaB0a9IbcKTvtowf9hRJ6zjmElQFaP0npLcW+Gr/6fVvkW/IbYUfgNwpA7zgu7NTAAAAABJRU5ErkJggg==",
        48, "iVBORw0KGgoAAAANSUhEUgAAADAAAAAwCAYAAABXAvmHAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAOCSURBVGhD7ZnpTxRBEMVBxfs2nqDRDyIqeCRq4kXEI8EoHnhfKF6gIP//p1+ZR2rMUMz0zs5mF6PzkhfCTnX1VHd19+uavr4GDRqUwsx2AZeBB8BT0cyeRPqzZ8Bw9JEHcNjtp6OP4OuRmd0ADkYflQGcAT4DP4E54FsL/gBmzWxz9JXBg1wsaLuCZvZd/vzvVTPrj76S8JdfAL54EApAL5jiL5+hDdFfBmACWCpoGzmf63tRsxF9lQLY6Q2/uhPxjpldAEZLOObcFv3lYWYDwGngXIGPjOeBm8CMz8isB3U0+iuE57zSRg0VxIlo0wsA+4D3PoCakcloUwjgoeeeGk3E572Ez6pGXwP51sw2RpsV0GLxhZYtytFo00sAQz6YmgWlVDJFFcA64HkugLPRppdQ3ncawFrPQBPAvx2ADi3tDB1wIPrMo6sBABeBd8CbDqj242Wnd60AzOxFLoCxaCP4aT3nzrVHd8IlMzsW+xD0e7sB9HsAOsSkbQpnQNOfE2ayrUud+B/NbHfsQwAGZeNBSChujTarAJxyLSRhtj0+zwBskXx2nqzBYTMbKXt5QakF3POMuFJZlUoSK53i72uFSiNfB8pJXw91uSP67AlcM11XqpnZJ+Vxu/R2StVJranYR1fhV00tQuVmdmeoS+1Cx2MfXYUvLt2Tl699demD8Dq1WXQNHoS2uU44pN0s+v6/odKHlz1utVpcwH4zO6TyRwUeMLP10UcKvllcAl62Ktn8gddldMJqcY3E54JexA+YrNwS5UGkbGT7OFV2ifDAJWmyEzvdtqoWyu1Cerm4q6Sokkq16oJrIQ9cbRVAerFXVaM+A7fdTnu5KhitKNspYFP0V4ZaarRKABmkY8xsTxUCe9uVJ10PoNtoAmgC6BB1AtDB8TcF0F5lTvCPC5nQuhaf9xJ+29NAKgAVeltvwV7azhrNaAuMNr2Al+Knc6f4VLQphB/faqADSo1V+lA9X8pROqmIR/zzUcs7qzRRZl/CQUkY12OS3br4LJTJmkIodVwPZd8I5j2tFFAZdTe4mzqsXJhln45i+2Xm0lf/q399KXqQ8rsKvpjHPZUqaR7vWHal+h545cJsVfsCKgtkq+8VaRFXBl31gPueRtoFUtRoJUsfXkbJ7tCxfZ4ftJnoW13KX2Vo9UsJehViFfWsaunDSzZJX6lZbNCgwUr8BupAvhF3ipXRAAAAAElFTkSuQmCC")
    static l := Map(16, "iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAGHSURBVDhPpVO7bhRBEGzzspDgjtmq2rvFhzP4CEjIsOEDOAlLjkGcOcuJE1t+/gJfQMB/IPFIyCAg5BMgBYFqNGvtnWwCrqWStrumq3t6eiMiYjQaXSc5ljSR9FLSi5TSqjlJQwDPS3wCYKOqqp65bABukvxU1/UfSRn+9kHzJJ+08ZYj+aVpGrYCzwaDgYNPAdw2XDUiltoipYvMkVwvIluZJLlt5Zm2/m2XSbrDk+yRfFUEVuZPnmf9fv9WETjMAXfgluq6HkTEJQC7JF/PA8BBRFyTdMMFAZxmAU/bcyh3XgbwWdIPkl38BPAtpdQvRcck78729r/m1kk+Lu5Vkm9Ivu/gnaQH3RxJj1JKd7Lj5/AMhsOhIuIKgLeSPpLMkPQBwMM22XtTZnDUCkwXfgULmJg/fIH5mhY4zl5VVZtljde8TIafqpth33G3n1K6X1Z9J5O9Xq8i+bWsZ4ak336qkrwm6VfLlXPfZ65sEf9tXhaD5D7Je+a8JyT3OtyUZHOWvKj9BahQbJxDFlVoAAAAAElFTkSuQmCC",
        20, "iVBORw0KGgoAAAANSUhEUgAAABQAAAAUCAYAAACNiR0NAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAIQSURBVDhPtVTLahRREO34Rntm7DqnqntQGNBxIYLBrQoaQSU7H1HQpYILwQ/QlUEFEUECiiiILsWN/oNf4C/oLvgAXQgqiVSnbjPTRhjBHCiaW3Vu1b19qm6WBQB0VPUQgBkARwEcM7P9Ke4Qkb3uj/iMqh7udrsyyqnhBJLvzWy5LMvl9FVVt93OyfOcJJt4MpKLInK6Sdbr9bYDWIzgGwBPADyN7+2yLLcFdRPJG6o6Gn/lRUl+F5EdNYvkEa9K8nVT5R/gieM2Z2pHURQnI+HDNnkSALgZ+8/XDhE57g6v1CZPAgB34oTnakdRFLOR8Hki9fv9rWa262/mHZG4InIvTnihdpA8YGY/AdwKznoA71ykUHnMQrwPSSwRuWZmv7yNUpFMVYeDwWBLLNcBeEDyLYA/LPzPXPXgbyC5p0m2Juh0OsiybCqWU64Yybur2IqSLXjTN4uiKPap6idVvR4uv8LHqqrqqUjma5Kfsyzb2Gxe0eCymX1R1YMp4WyQXySSqk6r6twqNj2azEHyvu8HcLF2/Pc+FJET0UeP2uRJAGB+bFK8f+KEL9vkSQBgIU44VzuqqlIA31R1ieRjn82weQBXh8Ph5tjrYl1SVfcnzoK/NCSXfIKaKiJyVlW/jqrqFtMydE6e5+qT0lZfVX+QvNIkG0m608xO+c9N5q+zT07i+Is+Gvcna+xka4Hfpnek3qCx+OUAAAAASUVORK5CYII=",
        24, "iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAJKSURBVEhLzVU9ixRBEB3R9dvdnXqvpmd0dVE30DsT4dTM1EwQMRTMDMS/oCYGRhoIikZ+wCGXiLGR+AtMjARBuMxAlNP1g5MauofedkbY5PTBo6H7VVVPz6vuLJvF1jzP9w+Hw3FgVVUHsizblOiyNl1VVTtTXQNVvUryHcnvJH+S/GGjqtr4PNaSvO/nG50fP5C8HmtrALhSFMW6UVVnaHMkX8Z6kk+7tEYANxvxaDTaAWDVJ1oBsJTn+WKgc25xPB5vjwtkWbalLMuFWEfyOMl7Ps+0KApXK51zB0nWOwBwJEk0F/r9vtgR+1wn6klVPWwFjCJyNA2aB6paAlizAiJysp4siuJQKGCfmgbNAwB7AXyd+YINKRBckOf5sSAWkXMkH5tj/sInInIp9IkVsI3ajxaRU3UicwjJF2ZFVd0d7Wa1LMt151wnbd0SmhN9WA/AMwCvBoPBMORqBYCzqvoAQCf9+sU09v+AiOxT1fOqeqGFZ6zZ0pgu9OxuIfko7liSb+ycQ/vHtHkAl2fT1NgM4DaAZefcrnrGOjlyUWNTE6rqe5J/UFXfkjwdZzZYowUXtXZybFOPXgdbYccK4Nu/62QRWUiD5gHJqrOA/w+TNGgeWHMBmM4ckXUvyY/+Hr9rT6FzroiZJjKUZal25weNvyauWXKSv0Rk1IgB3DDr+cUpgC+BJG1cjpMDuEPyc6wLR+Mt/DDW1yB5S1U/BcsGesu9jrUAVtqeTJJrlnwymWyL9Q38g7FkPyjhnlhnDdmms+ONdRuC33st7PcYrjWdAAAAAElFTkSuQmCC",
        32, "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAKlSURBVFhH7Ze7a1RREMZvEvGBxs293/ed3UAwKMFCBBtLCxsR7GyUWAgWQgoFQfDRRlDMipIE37ETC43GgMYH+H+olY0oaBEhlRaRWU/C3cl6N2QXjJAfDJd7vpnZ4ew5c85NkjVWI5K2SDpOcgTA9bxJsudQkiTrXFgHycGo1xnJayGEoRBC2cUsRdIeSR9CCPPlcrmhmZZl2a58XHd3NyTNVyqVJf4LMSS/Zll2IB9XR5ZlWwF8is4/Sb4FMEkyb09JXunv79/owrsAnIv6oj+AJwBmSP6wvADm0jTd5mL/IOlE/PE5Sfu83gokd5L8bLMB4JLXawAYjQ4zXmsHJG9bfpJTXqtB8pY5SHrstXYA4EYsYNprNUjejA6TXmsHCzNM8rnXaqzqAkgeInmVZNX6Q4FVQwj2HLTekM/RtABJE3ENvMiPl8vlzST/uscbme2mnp6e/nwekndiAa/z44tkWXYqOlx2UieAC5JmbIc0M5KvbCYGBgY25JNYB435R/LjdcQO1+XH20XM79t4c7IsOyxpFMA4gLECGyc5Zk3NZs7nWRHtWgOt0EnyDMlny7QpAMNJkqz3iZpSKpVSP9ZOCvMDOBZC+A7grNfiWX8PwASA+84mrI0D2Ovj8pA8GvOf91oNSQ/sf5b0Mj++nDXQ29tr2+tdPs4D4K7lIPnGazUKOmGH7WFJjwA0NEkPAex3cXU07YQFBbSF/6KAf34fGC+ssEWsUxYWIOl0vBN+CyHs8HorpGlaIvneCrCrutdrSKqQnI231y92fMY7gD/zTzY6sEgeaeBr8XZ+fLS8dnVP03S3j10kTdODkmb9Ps/bSr4L4tT/iodUMaVSabuk4XjHn7Y1kTN7r/b19W1yYV2SLkrK+y6YnQ9V++hxMWskvwHAEz4lHRYFRQAAAABJRU5ErkJggg==",
        40, "iVBORw0KGgoAAAANSUhEUgAAACgAAAAoCAYAAACM/rhtAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAN0SURBVFhH7Zg9aBRRFIVXQiJCknXeOfdNIlEU4w8RxaCi0UKIGhvtxB9QRElMkYCKjRZW0S5KgoJgIdhZxMJCGxsbK4uAoBIUG4uEqCiKYiORC2+W2ZvdzW7cRSH54DLL3HfPnp158+7byWQWWciISCPJThHZXSi8911RFGVtXUJHR0eD936XrQuxB8CO1tZW2rpyqBeRIZIfSM6ISNEg+aqIyToAT7z3s2pM/WcRudvU1AQrUIwGkk8TYT2WCh3jnGuzIu3t7UsBTMdxPKvG1uuR5Os4jr3VmQWAoaSQ5G+SjwDcAjBiYlRERkgeshoJzjm9vTd1bKF6AA8AfE+ZHLMaeQBoAvApmPslIgftmGoTRdEmkpPhO2cAbLBjcgDYnvo1D22+VgC4lrprJ2w+B4B9iUEAN2y+VojIQMrgWZvPAaA7ZXDE5msFyfOJQRE5Y/M5Fg0WoaoGnXPNcRx3O+d6nHMHyowe7/1+EWmxekolBtMPySyD2voAjKfEyo6gORlF0SqrS/JC2QZ1oK7+JO/YvPZNXbx1zHxDRLZaXQCXko5D8pzN52hpaRFtOSLyE8Bhm1fCVR7WZYjkcDmhY0VExx+zeoqa1p5McloXbpvPQ29jFEUr7flao31YL5A9XzE60UXkCMnjFcZRkuusXlXRJxjAuzCXKoowv3RjsNbqVo3m5mYH4Ied+OVGMLrZ6laVsKG47Jy7UkmIiB57rN58qbMn/gvCQvxYRCacczttXhGRdu99v3NuEMBAoRCRQV3PCi3Khchms6tJjpN8UWh3noPkXp0rumg6527bfDabXQ5gys6tQqEaAN62tbUtszoWbXWphbrkdivd6kZtPhj8aM3YUI1g8H2ZBi8mdXMZnHOzoFtykr16C0n2FQnN9cZxvMbWF6KSzcKcBmvBosG/pRKD/+pP02BZD0kURV2pvnnf5muFdprEIIBTNp9Dtzvaa8Mv0f3Zejum2uh7HZJvwu3V7+20Y/IAcC91uadE5DqA/tTykQvvfV+pDaZ2hdSSZEP1ribmwrR6nslkllidPBobGwlgIjGpx1JB8luRlz71+uargpdHX0r92DxI6p+PseT/R3L5bQThr8UMAnipBm1duj58fua932IF5sQ516HvSvTJ0sc/Hck5ABttXQKAFSJyulg9gJMkt9m6RRYUfwACwO93b2T4mAAAAABJRU5ErkJggg==",
        48, "iVBORw0KGgoAAAANSUhEUgAAADAAAAAwCAYAAABXAvmHAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAQhSURBVGhD7ZlLiB1FFIZvJmqCztjT9f+n+s74uII3PrMShCxU0GgWPtCF7kVFY8hCSVRCwIWLQCDgxoWCqCi4CtmILkQ3QsCIJOBrIb5ADSQqRtEZRSFyQpUUZ7r79nTS7YP7wb+4t0+dqlNdj1PVg8GUKVMqAXAFyT0i8g7JD0l+VKMjJB+wPlIAbCZ5qKSs1bsknyV5vfXRGJKPklz23p8UkUYieXI4HIr1FQHwaVN/0Y7kM4PBYMb6qoXkI4mDvx1OEslPiqI4z/qLkNxfFMWKclaxXpX+BvCC9VUJyctI/pE6IXmA5JMAdgB4rESPa9DOuQutvxQRmQWwVe1LfKh2ktxN8kUAv8Y2hCDusP5KIbkv9Kb2xJ8ico+16QOS15A8HocUybesTSk6gWIhAPvt8z4RkV3JkPrBOXe+tbGs1YkWx7y+VmvQJyRvjcMIwHKe5xdbG8vZAD5PAthpDfqE5O1JAEtNA/js3/IGdOJOA7AGfdJ5AAsLC+dmWTaf53nWRrovWJ8pXQawBsBTIvINgOMAjrWQrvFHSb6iHWErUNoG8EUSwBPWQCG5QW3OhDS1AHCXrUMBcKfaxGV0fn5+ZG0sMwC+1MYHx6XLqA6b1SRmVQo7/i/OuatsHYpzbkuaGwFYtDYrAPCQiJwg+UFRFJfY5xGSCyJyL8n7Sd7XQqfK5Xm+0fqOaGII4A3v/c8Antaha21KKYrCDwaDc+z//xQiMrT/nRHyPL9IRMYicmkLjevecNecBeB5kkuaep+GfiP5dpZlua2gUwBcHidicmZoJV0sRORuW0enhMl18HRXodABX2dZ1v9Q0s3He79Zl7q28t7f0tkE/c8C4CYReQ/Aq5qv2OcJmk5cq1cfInJdndTGe79pNBqtt04mMENyr/f+sO4b9mEZa0h+nOzEW62Bog0B8Lodz5ME4Mjs7GzltYtFg9e2hLTm9yZlNRf6SivTQs65XdZA0VUopAGrknYKydusvyo0RwoT/VQATSZ7o2x0PB6vA3AgOm+iYHtocXER1l8VbbPRiQFEnHNXai7TREVRXL3a9KTzALpmGsD/IYDSA01ftAlAs8w0gB3WoE/szVyTI6VGfTgJ4Dn7vE9IPpgcKX+am5ubvASTfCnZpE7UHfm6RNMYzQq08SGA9xsdKUP+km4+3+ktsb5OADfqZ6IykbxBh6D1Z3HObXLO3WzLB2ketgXANv3UFNsRRsPD1lclOnTiW4g9MEmhktd0IbD+IiExW1G2SknjD9b5LWMtyZfTymxqYJUEUlhnEZLfJsOzVrFT9ANj3Xe3WvSoR/JNkt/rKhC0VKJlvd8JVx+VH+Q0uxWRH/XjYYmP1Jde6+iHlu3amdbPqtFDt67BdXLOXWDLlaFXNsPhcGTLR+lSGa51pkyZ0oC/ANPosgc+HeCnAAAAAElFTkSuQmCC")
    static lp := Map(16, "iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAF2SURBVDhPpVPLSgNBENxE4xshM1U9CS4ENR5cRTA5iYLefYInQfBFIj7y/1epcdZsAopiQx96avtV1ZtlnzZDctM5VzjntlutVhFCWBaQ5/mi3hJWANjKsqyR8qI1vPcXJEcABnKSbyoo0DmXk3ypYCOS151OZyFmm9mGHkMI6+12e0murtUOikvMObemBpoygs1mc0eV+/3+xFg/WI3kA4BejNJeA1Wf/vIbmwPwCGA/RppAI6Wxa2a2R/LIzA5KJ3mYEuqJs2cA/VhAbJeESY1E6L2Z3ZZO8k7EqXvKWXfOrY6H+o8lnfMU1gEce+8vAZwCODOzyxCCVXOkRHknkUTv/UvStea9P0kFzrz352Z2RbJVyW+kmxiTCGD4RxWevmQs76AoikjQL6w+cQcku7pE7ZVuXD47laQ4YuJDsocQdiPS7XbnJRHJd1WWm9lQUglX4fQPRIzkK4CbiZU1fghBq/REjo6k1JnkSuW9p87T/8q/7APeRz7dttwvMwAAAABJRU5ErkJggg==",
        20, "iVBORw0KGgoAAAANSUhEUgAAABQAAAAUCAYAAACNiR0NAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAHrSURBVDhPtVRda1RBDL1d6wfC7rrJSWZXxXVlW3AfLFqtWhQF33zQN8GKYrUtfqC2Vf+/nMtkvJ2nFeyBPEzmkGTmJGmav1g1szGACU1VLw8GA+ncN8Ph8BL9wSF/sVic63Ja8MLdd8zsWxiAH+7+SVX75Eyn0wsAPgA47PLM7O1oNLpWgjEDgNdm9llVn5nZNg3AYwB3WHmm9sxsg/7gqOpTAPtm9n4ymVws1TETg5Us/4Cc/HA8Hk9bh4hcYUB3f1CTlwGA2wyYUpq1Dn5y/ovtmrwMAGzmgNdbByukAGb2qMNbFZEBBamN/qZpzgZRVe8BOHb3G62j3+8r1cwCECuq+tLMvgA4qI3iAXgVYonIwsy+so0iCbOwNc5EQBG5r6ovADyvjf78ml7m93LVp4jc7StxpmIisqWqd8NSSltFyQrz+fx8OXCcOAHufiu7+Ic7qvqbYoWp6i9VfdN5agsA62zulJK3DhG5Stk5AUHiDFM1tkIYz/VsE/klP4vK/70PI6C7P6zJy4DtdiJgXkXfATypycuALQbgqATkWjKzd/xYVplnk7YpIje7/QlgjYoHh8HMbBfAx1hzLbgp8gXFCTvmBETT5n24TwEq3h6VLsEC3GdZ0Vmomsep9Ke7p4765M1OVHYa+AMtRl7SStW/tAAAAABJRU5ErkJggg==",
        24, "iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAIiSURBVEhLzVVra1NBEN0mWt9e786c2ZsYjI+ImE8FRfFZi4KiX/ziE3y3tU1VLIi/X07cDZslKcYP1gMHLrNnZ2bn7sw6N40WgOMlnXNLhc6Vmqg7UOom8N5fVtUXAN7nVNUNEbmfawHcpL3QflDVVwBWcu0YdA5gh+RGVV1PFJFtAI9yvareBTDKdSRtAL6q6pVc346Zj0RkrdPpaFVVdU5q8g0sZanpdrtiZjfMbAvAu16vd2SsjPXj8Tbquq4KRwthMBgcimXdZKJjo4iciAE+VVV1qty0CJg1gLd7BWA5/hqdTufo/gSgQUS28gBN0/T501V1lbdmBlfj+sU8ABMVkZ2maZDsbTN7AOChc+5gMqrqSxH5qarf51FEfvD02S1ricg9VX3inFtOvmairusz8b7fmse4fqHc+3+A9TSz8yGEcyGEs4m0ee9Pz5pP88ABx9lyJ+9YM3uqqrtphGT8Yma7InJp2s0YS977a/wPk8HHTjazTQDb+S0KIVD4GsCznKr6nDSzkHsm2Gi8RUziT/ugNYczMbcP9giwEPY9wLr3/mS5aREMh8NljuqpAOze+DNHnOchhGP9fv8wyZ82mesF0nrSxuxXROQzE6afiZgLfInSYwHgTaKqfuTcyZ1776/TnutYGjpX1W/s8lw/hohcTcfLGZ/Rx4V2jVcx16XMAdye8QL+Bo/MKcj6JcapOBmCEW3acy2/p8ryr/AL6C+F9ITzMBIAAAAASUVORK5CYII=",
        32, "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAJpSURBVFhH7VddaxNREN1orYqaTe7MmWs0EJRUNKgPfrRVi+K3PhdBURS/HvysVR/8+XLWu2U73WaxWdBCD8xL5p7Zm9mZM7NZtof/FHOquhBCWPRmZtdE5GyWZR1PMrPT9HtOsnOj0eiQ52xBt9sNAJ4A+Kyqa6r6zdl3AF/yPO9VeePx+KCqvheRHzWcNXLM7LmInKjyPA6UDwfwCsBDEbktIndKM7N7qno5y7L9jtsxswtmdr96nvz02wsAnwC8jDEecdw/YNrLh5tZ9P5Z0O/3c1V9pqpfVfWS9xeIMS4xXbyx97UB1keKf9f7CgC4zgNMm/e1gRjj4tQLlDfku/O+NlDJ8C68QAhhyAAicrXJeI6a4GM0XgDAiqquhxB8Ec4BeC0iP5M2NBm14iOAo9UgqcbWATyo/r4BqlVqE/Z5Fezxi6r6mB3SZDzHTHitoIJSkJKvHknhtshsW9hx/F6vN2IKzWy5yVKqF3b0oG3QSg3Mgk4IYcLicTpfazyX5HafD9SIyWQy739rE1Pjs3c5UmOM57fx3QRwo8ZWaIPBQD2vihjjKcbn1PS+AgzCeV6nA6r6JtWAn/WFAfgF4JHjbQKLk/E55r2vwDQlZA9TwVT1Vp2ld3/c86poVMJpF2gDu+oC/2wfWGZBiUj9gRnRmIEkNuX2esz7Z8Q8gFUOO67p3llgOBweNrNie1XVp6ltrlQt/YszdTrPPk87wyZOmg+rAD6o6ts8z/ueu4EQwkluxWksU9d9z3Oe//V3QYr3DsC4yqsFhwh3An4D8H1VLc2DLbO+3BkoMp7DOCGEJX70OM4est/+Nq/8n9wvwQAAAABJRU5ErkJggg==",
        40, "iVBORw0KGgoAAAANSUhEUgAAACgAAAAoCAYAAACM/rhtAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAANKSURBVFhH7VhtTxNBEF4qxbfa83Zn5nq1QtSqWI1vjaBGE40SPmiCL3wQBSMqSlH8/x/NQ/YuZey1C16jCX2S58vN7uyzO3czs2fMBEcc081m0yVJIoMoIokxpqon9aGi5/Sz0Wjw3NzcCT0pBBUi6hLRGhF9LaJzbltEXnc6nRntwBgzJSJLzNzT8/rJzBvM/MgYc1w7KEKFmZeZ+QcRfRORbSxSwJ9YJEmS09qJMeaY3+CvAfNyYg2sxcxvg06TiO56cdjdpog8E5H7SZIsajLzwziOz2sfGRBCEXmg52V0zj3BCRLRFtZ0zj3VPjSqIvLe72rTWntODygbURSddc5hzS0i+hzHcaTH5EjTlHByCGvIbsqCj1oP64rIRW3PQURQiOPuJUmyoO3jgrX2WiaQiK5oew4lcFHbxwVrbadP4GVtzzERWICyBVbxdYPOuWYIs/GtVuukdgaUKRBpaCVLsAehX3xtUFIPFuh3vFchkIS1HZmemT95+x9VYQSRiHutVstqv3Ec3/A+MeaqtufwAt4gFxZVCJwyKou1dsE5dy+Uvhpd0P6Aer1uUVFEZB2JW9s1pgeFYdzA4bTb7eCGoRB40ZHtQZxICDGWmS9Za+vaX6nodrtVZl7Fu+LL0vdAoiPaYeaPzrkz2m9pQAh8/3aojwRf8+zsbKz9loparUbMfFtEbh6ERHQHWUL7Oyym9IP/BdPW2iUieodmUxsBvOhIrOhARjE0GzBzDVcH59zK0DnM3EAyRZuOTljbcfeA+MB3cBdtPFp/7UcDG/ZXg92RlWRYqfMC1yDQf8WF9AJXERXtRyOO4+tYc2SpC6jFcBYhfChJIziP0On5gxBci0MEjgMTgX+Lwwr8V5emYoH4X5IJJKLH2j4uoNJkAtFUaHsO3w/ipo+L+8bQS3R5mEG+9J33Fn5W6QH7gB85vrDjpo9/K90BKWSPCM2wBhNVIU3TeT0PxP2XmW/5BhkHgqi9GFlm/SmipdrJwq2TcF8yRsJeL7gMVVC+fMIe6MOL2hOHVmzYZvfBN6XPieiLdqoWQF/4oUigc+4VBOp5/fSRehlF0cHbMOwILy3Cga9LE6Ea9p6maXqqaK4PcRv/g/S8CY4UfgNk0xXsY4SbowAAAABJRU5ErkJggg==",
        48, "iVBORw0KGgoAAAANSUhEUgAAADAAAAAwCAYAAABXAvmHAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAPkSURBVGhD7Vlpb9NAEHVoyg3BOzPrJBgKUilQbhWQOMUpgTgLlLMchZYeQP7/R/SicRUmjm0cEpDwk54ixbtjz8565u04CCpUqDAQYRg2iOgCMz/w3s8rn6ZwXkSeM/OMtdELZm5hvIg8S7GxaYuIHovIVe99ZG0UhnNulpk/i8gGEa0y80oWiWhdRJampqa2W1sJ4KSIfLdzU/hVRNbx672/FARBzdrKBB5eRL4x8xc44b1fhcEc/sDqBUFQt/YSENFNZu6kzP2F3vu15N5wGNGwtgbCObcXE5l5WY18IaLbInI2iqKTafTenwKjKNpl7RlMNpvN497709ZGQhE5w8zXROQDooGowqkwDA9YY6nAnse2wUQ4EUXRYTtmHGi32+S9X8QCIiIics+OSQUzP9S9t4aQ2+vjBKKK1cdCEtHbIAi22jEWNc0mCN06QmoHjBPOuRiLiShgSxXYosEWEXnR48AJO2CcwL4f1oG/GoHKgf/BARQtZIaynLQGezFSB5j5nPf+HTO/KUsiwvzrg6p3WQcWEgeQh+0AANUa8kKNo2IPw06r1Tpo7wGEYXjwdx1AHVggIlS+HxkR2JoIMxS8stSK/7HRaOyzNwCcc/uJaEPF3VKr1dppx/SBiI6qgINE3m2vJ4jjeAfks/JICc4Q0bFBD6+oe+/vYkc45y4WVqUqibfY//8WCq18GWBP4n0oSyLaY22OC3hXrqhe/4R9XIKfdP692dnZXJH2R4GjJl5CPT11zwxDsBNF0SF7j1GjjnOySl2kuVLURXidlSxGiTrS3JCMkc2s4f8baH2g7UFEN1SvDESz2RQRaaL9kccoinwQBBPWRg5qRHSemV/mtWw2oQUMrY8OCo29rphAgelpt1h5YIm2yyoRPclqu1jAcW3XdCt2kbmFtFBPFsLD2aySxU7h7oJqIV0kaCGk3tyXvaganSCiW7r6yOVofWRSo/Boenp6mzU2CGXVaBEHuoCOaTQaYRHGcex+V56M3IFRo3KgcmBIlHEAKvOfcaBMZw4nsseJ0BKRy/b6OIHqq4IRDd7FQilYW9vdSfAaKdCOGQfm5uYmIWl6qvgjOyYVql1Q/fCNYAWtE/TzNZytNBJRG79FzqzQRMn4NEKlQsLow+MwjwPTtwxZ0w9sHf0y0v1GoLIBe9F+Ctokouacu5NVrCDMes4QfTaUyTkBNlHF8aXoQZbdNNTQcFI9VFTz4KGWs/Q9M7/SNomd20dsG4g4fK8oIuJSgaMeM99HBw3vQw6X8lofujWSM7Sd38v3SCb4VpdlrzDw9kMJIo2lEdeKtj6wmnm2sqJYoUKFX/ET7w527nI0gq4AAAAASUVORK5CYII=")

    return dark ? (paused ? dp : d) : (paused ? lp : l)
}
