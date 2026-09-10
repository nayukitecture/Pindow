#Requires AutoHotkey v2.0
#SingleInstance Force
; PinWindow — タイトルバーを左クリックで押したまま(ドラッグ中)に右クリックすると
; 常に最前面固定のON/OFFを切り替える。固定中は4辺の枠に色を付けて一目で分かるようにする。

CoordMode "Mouse", "Screen"
DetectHiddenWindows true  ; 最小化中に Hide() した枠も掃除対象として検出できるようにする

WM_NCHITTEST := 0x0084
HTCAPTION    := 2
DWMWA_EXTENDED_FRAME_BOUNDS := 9

BORDER_COLOR := "FF3B30"  ; 固定中インジケータの色 (赤系)
BORDER_THICK := 6         ; 枠の太さ(px)
POLL_MS     := 15        ; 追従ポーリング間隔(ms)。ドラッグ中も滑らかに見えるよう短め
SWEEP_MS    := 2000      ; 内部管理から外れた枠を掃除する間隔(ms)
MY_PID      := DllCall("GetCurrentProcessId", "UInt")

pinned      := Map()  ; 対象hwnd -> true
overlays    := Map()  ; 対象hwnd -> Gui
overlayHwnd := Map()  ; 枠自身のhwnd -> true (誤クリック除外用)

^+!p:: ClearAllPins()  ; 緊急脱出用: 全ての固定・枠を強制解除する

; 左ボタンが物理的に押されている間だけ RButton をホットキーとして有効化する。
; これにより通常時(左ボタンを押していない時)の右クリックには一切干渉しない。
#HotIf GetKeyState("LButton", "P")
; #InputLevel を上げることで、下の Click "Right" (SendLevel 0) が
; このホットキー自体を再トリガーする無限ループを防ぐ。
#InputLevel 1
RButton:: HandleDragRightClick()
#InputLevel 0
#HotIf

HandleDragRightClick() {
    global WM_NCHITTEST, HTCAPTION, overlayHwnd

    MouseGetPos(&mx, &my, &winHwnd)

    ; 自分自身が出している枠(オーバーレイ)をクリック対象と誤認しないようにする。
    ; overlayHwnd は「枠自身のウィンドウhwnd」の集合(固定対象のhwndとは別物)。
    if (winHwnd && !overlayHwnd.Has(winHwnd) && IsTitleBarHit(winHwnd, mx, my)) {
        TogglePin(winHwnd)
        return
    }

    ; タイトルバー以外(=左ドラッグ中のただの右クリック)なら通常通り再送する
    Click "Right"
}

TogglePin(hwnd) {
    global pinned
    if pinned.Has(hwnd)
        UnpinWindow(hwnd)
    else
        PinWindow(hwnd)
}

ClearAllPins() {
    global pinned, overlays, overlayHwnd
    for hwnd in pinned.Clone() {
        try WinSetAlwaysOnTop(0, "ahk_id " hwnd)
    }
    for hwnd, ov in overlays.Clone() {
        try ov.Destroy()
    }
    pinned := Map()
    overlays := Map()
    overlayHwnd := Map()
    LogEvent("CLEAR_ALL")
    TrayTip("PinWindow", "すべての固定と枠を解除しました", 1)
}

LogEvent(msg) {
    try FileAppend FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss") " " msg "`n", A_ScriptDir "\pinwindow.log", "UTF-8"
}

HTCLIENT := 1

IsTitleBarHit(hwnd, x, y) {
    global WM_NCHITTEST, HTCAPTION, HTCLIENT
    lParam := (y << 16) | (x & 0xFFFF)
    try {
        hit := SendMessage(WM_NCHITTEST, 0, lParam, , "ahk_id " hwnd)
    } catch {
        return false
    }
    if (hit = HTCAPTION)
        return true
    if (hit != HTCLIENT)
        return false

    ; Windows 11 の現行 File Explorer 等(WinUI3/Windows App SDK系)は、
    ; カスタムタイトルバーをアプリ内部だけで処理しており、外部からの
    ; WM_NCHITTEST には常に HTCLIENT を返す。この場合は「見た目上の
    ; タイトルバー相当の高さ」をDPIから逆算し、その帯の中(かつ最小化/
    ; 最大化/閉じるボタンより左)ならタイトルバー扱いにする。
    dpi := DllCall("GetDpiForWindow", "Ptr", hwnd, "UInt")
    if (!dpi)
        dpi := 96
    try {
        GetVisibleRect(hwnd, &wx, &wy, &ww, &wh)
    } catch {
        return false
    }
    capH := DllCall("GetSystemMetricsForDpi", "Int", 4, "UInt", dpi, "Int")   ; SM_CYCAPTION
        + DllCall("GetSystemMetricsForDpi", "Int", 33, "UInt", dpi, "Int")   ; SM_CYSIZEFRAME
        + DllCall("GetSystemMetricsForDpi", "Int", 92, "UInt", dpi, "Int")   ; SM_CXPADDEDBORDER
    if (y < wy || y >= wy + capH)
        return false
    btnZone := Round(138 * dpi / 96)  ; 最小化/最大化/閉じるボタン想定幅の概算
    if (x >= wx + ww - btnZone)
        return false
    return true
}

PinWindow(hwnd) {
    global pinned
    try WinSetAlwaysOnTop(1, "ahk_id " hwnd)
    catch {
        return
    }
    title := ""
    try title := WinGetTitle("ahk_id " hwnd)
    LogEvent("PIN hwnd=" hwnd " title=" title " alreadyTracked=" pinned.Has(hwnd))
    pinned[hwnd] := true
    UpdateOverlay(hwnd)
}

UnpinWindow(hwnd) {
    global pinned, overlays
    try WinSetAlwaysOnTop(0, "ahk_id " hwnd)
    title := ""
    try title := WinGetTitle("ahk_id " hwnd)
    LogEvent("UNPIN hwnd=" hwnd " title=" title)
    if pinned.Has(hwnd)
        pinned.Delete(hwnd)
    DestroyOverlay(hwnd)
}

; WinGetPos (=GetWindowRect) は Windows 10/11 だと影・リサイズ判定用の
; 見えない余白(数px)を含んだ矩形を返す。それをそのまま使うと特に右・左・下で
; 見た目の枠からラインがはみ出るので、DWM の「実際に見えている矩形」を使う。
GetVisibleRect(hwnd, &x, &y, &w, &h) {
    global DWMWA_EXTENDED_FRAME_BOUNDS
    rect := Buffer(16, 0)
    hr := DllCall("dwmapi\DwmGetWindowAttribute", "Ptr", hwnd, "Int", DWMWA_EXTENDED_FRAME_BOUNDS, "Ptr", rect, "UInt", 16, "Int")
    if (hr != 0) {
        WinGetPos(&x, &y, &w, &h, "ahk_id " hwnd)
        return
    }
    left   := NumGet(rect, 0, "Int")
    top    := NumGet(rect, 4, "Int")
    right  := NumGet(rect, 8, "Int")
    bottom := NumGet(rect, 12, "Int")
    x := left
    y := top
    w := right - left
    h := bottom - top
}

; ウィンドウ全体を覆う矩形から、内側(枠の太さぶん内側にオフセットした矩形)を
; くり抜いた「額縁」形のリージョンを作る。SetWindowRgn に渡すと、そのリージョンの
; 外は透明・クリック不可になり、4辺の枠だけが表示される。
CreateFrameRegion(w, h, thick) {
    t := Min(thick, w // 2, h // 2)
    outer := DllCall("gdi32\CreateRectRgn", "Int", 0, "Int", 0, "Int", w, "Int", h, "Ptr")
    if (t <= 0)
        return outer
    inner := DllCall("gdi32\CreateRectRgn", "Int", t, "Int", t, "Int", w - t, "Int", h - t, "Ptr")
    DllCall("gdi32\CombineRgn", "Ptr", outer, "Ptr", outer, "Ptr", inner, "Int", 4) ; RGN_DIFF
    DllCall("gdi32\DeleteObject", "Ptr", inner)
    return outer
}

UpdateOverlay(hwnd) {
    global overlays, overlayHwnd, BORDER_COLOR, BORDER_THICK
    if !overlays.Has(hwnd) {
        ; -DPIScale が無いと AHK が W/H に現在の DPI 倍率(125%環境なら1.25倍等)を
        ; 勝手に掛けてしまい、指定したピクセル数より大きく表示されてしまう。
        ; ここでは既に物理ピクセルで幅・高さを計算しているので二重に掛からないようにする。
        ov := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x20 +E0x08000000 -DPIScale")
        ; E0x20 = WS_EX_TRANSPARENT (クリックを透過), E0x08000000 = WS_EX_NOACTIVATE
        ov.BackColor := BORDER_COLOR
        ; 対象ウィンドウを「オーナー」に設定する。オーナー付きウィンドウは
        ; OSが自動的に常にオーナーの直上に表示し続けてくれるため、Zオーダーを
        ; 毎フレーム自前で操作する必要がなくなる(前回の SetWindowPos の
        ; hWndInsertAfter 誤用バグ — 指定したウィンドウの"直後"=裏側に
        ; 置いてしまい枠が完全に隠れていた — を構造的に踏まなくなる)。
        DllCall("SetWindowLongPtr", "Ptr", ov.Hwnd, "Int", -8, "Ptr", hwnd) ; GWLP_HWNDPARENT
        overlays[hwnd] := ov
        overlayHwnd[ov.Hwnd] := true
        LogEvent("OVERLAY_CREATE hwnd=" hwnd " ovHwnd=" ov.Hwnd)
    }
    ov := overlays[hwnd]
    try {
        GetVisibleRect(hwnd, &wx, &wy, &ww, &wh)
    } catch {
        return
    }
    ; Gui.Show() は "NoActivate" を付けてもZオーダーに干渉することがあり、
    ; 2つ固定した状態で無関係なウィンドウをクリックすると2枚が入れ替わる不具合の
    ; 原因だった。ここは純粋な移動・リサイズ・表示だけを行い、Zオーダーには
    ; 一切触れない(SWP_NOZORDER)。上下関係はオーナー設定にOSが自動維持する。
    DllCall("SetWindowPos", "Ptr", ov.Hwnd, "Ptr", 0, "Int", wx, "Int", wy, "Int", ww, "Int", wh, "UInt", 0x0004 | 0x0010 | 0x0040)
    ; 0x0004=SWP_NOZORDER, 0x0010=SWP_NOACTIVATE, 0x0040=SWP_SHOWWINDOW
    rgn := CreateFrameRegion(ww, wh, BORDER_THICK)
    DllCall("SetWindowRgn", "Ptr", ov.Hwnd, "Ptr", rgn, "Int", true) ; 以降 rgn の所有権は OS 側

    EnsureAboveOwner(hwnd, ov.Hwnd)
}

; オーナー設定(生成時にSetWindowLongPtrで後付けしたもの)だけでは、切り替えを
; 繰り返すうちにOSがZオーダー追従を取りこぼし、枠が自分の対象ウィンドウより
; 下に来てしまうことがある。ここで「対象ウィンドウの直前(直上)が本当に自分の
; 枠になっているか」を毎回軽く検証し、ズレていた時だけ補正する。
; (SetWindowPos の hWndInsertAfter は「指定したウィンドウを自分の直前=上に置く」
;  という意味なので、対象ウィンドウ側を「枠の直後(下)」に差し込む形で直す)
EnsureAboveOwner(hwnd, ovHwnd) {
    GW_HWNDPREV := 3
    above := DllCall("GetWindow", "Ptr", hwnd, "UInt", GW_HWNDPREV, "Ptr")
    if (above != ovHwnd) {
        LogEvent("ZORDER_FIX hwnd=" hwnd " ovHwnd=" ovHwnd " wasAbove=" above)
        try DllCall("SetWindowPos", "Ptr", hwnd, "Ptr", ovHwnd, "Int", 0, "Int", 0, "Int", 0, "Int", 0, "UInt", 0x0001 | 0x0002 | 0x0010)
        ; 0x0001=SWP_NOSIZE, 0x0002=SWP_NOMOVE, 0x0010=SWP_NOACTIVATE
    }
}

; デバッグ用: Ctrl+Shift+Alt+D で、その瞬間の固定状況(対象/枠それぞれの座標・Zオーダー)を
; ログに書き出す。「ズレて見える」瞬間に押してもらえれば、原因の切り分けに使える。
^+!d:: DumpDiagnostics()

DumpDiagnostics() {
    global pinned, overlays
    LogEvent("--- DIAG DUMP START ---")
    for hwnd, ov in overlays.Clone() {
        title := ""
        try title := WinGetTitle("ahk_id " hwnd)
        exists := WinExist("ahk_id " hwnd) ? 1 : 0
        wx := wy := ww := wh := "?"
        try GetVisibleRect(hwnd, &wx, &wy, &ww, &wh)
        ox := oy := ow := oh := "?"
        try WinGetPos(&ox, &oy, &ow, &oh, "ahk_id " ov.Hwnd)
        GW_HWNDPREV := 3
        above := DllCall("GetWindow", "Ptr", hwnd, "UInt", GW_HWNDPREV, "Ptr")
        visible := DllCall("IsWindowVisible", "Ptr", ov.Hwnd, "Int")
        LogEvent("  target hwnd=" hwnd " title=" title " exists=" exists " rect=" wx "," wy "," ww "," wh)
        LogEvent("  overlay ovHwnd=" ov.Hwnd " rect=" ox "," oy "," ow "," oh " visible=" visible " aboveTargetIsOverlay=" (above = ov.Hwnd))
    }
    LogEvent("--- DIAG DUMP END ---")
    TrayTip("PinWindow", "診断ログを書き出しました", 1)
}

DestroyOverlay(hwnd) {
    global overlays, overlayHwnd
    if overlays.Has(hwnd) {
        ovHwnd := overlays[hwnd].Hwnd
        LogEvent("OVERLAY_DESTROY hwnd=" hwnd " ovHwnd=" ovHwnd)
        try overlays[hwnd].Destroy()
        ; ディスプレイの抜き差し等のタイミングでは Gui.Destroy() が失敗し、
        ; 内部管理から消えたのに画面上には残る「幽霊の枠」になることがあった。
        ; 実際に消えたかを確認し、残っていれば DestroyWindow で強制的に消す。
        if DllCall("IsWindow", "Ptr", ovHwnd, "Int") {
            LogEvent("OVERLAY_DESTROY_FALLBACK ovHwnd=" ovHwnd)
            try DllCall("DestroyWindow", "Ptr", ovHwnd)
        }
        overlays.Delete(hwnd)
        if overlayHwnd.Has(ovHwnd)
            overlayHwnd.Delete(ovHwnd)
    }
}

; 何らかの理由で内部管理(overlayHwnd)から外れてしまった枠ウィンドウ(幽霊)を
; 定期的に見つけて消す。ディスプレイの抜き差し等でこのスクリプト内部の追跡が
; 一時的に壊れても、画面上に永久に残り続けないようにするための最終防衛線。
SetTimer(SweepOrphanOverlays, SWEEP_MS)

SweepOrphanOverlays() {
    global overlayHwnd, MY_PID
    try list := WinGetList("ahk_class AutoHotkeyGUI ahk_pid " MY_PID)
    catch {
        return
    }
    for h in list {
        if !overlayHwnd.Has(h) {
            LogEvent("ORPHAN_SWEEP destroying ovHwnd=" h)
            try DllCall("DestroyWindow", "Ptr", h)
        }
    }
}

; --- 追従・後片付けポーリング ---
SetTimer(TrackPinned, POLL_MS)

TrackPinned() {
    global pinned, overlays
    for hwnd in pinned.Clone() {
        try {
            if !WinExist("ahk_id " hwnd) {
                LogEvent("STALE_CLEANUP hwnd=" hwnd)
                pinned.Delete(hwnd)
                DestroyOverlay(hwnd)
                continue
            }
            if WinGetMinMax("ahk_id " hwnd) = -1 {
                if overlays.Has(hwnd)
                    overlays[hwnd].Hide()
                continue
            }
            UpdateOverlay(hwnd)
        } catch as e {
            ; 1件の異常でポーリング全体が止まらないようにする
            LogEvent("TRACK_ERROR hwnd=" hwnd " msg=" e.Message)
        }
    }
}
