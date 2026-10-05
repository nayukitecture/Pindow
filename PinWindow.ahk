#Requires AutoHotkey v2.0
#SingleInstance Force
; PinWindow — タイトルバーを左クリックで押したまま(ドラッグ中)に右クリックすると
; 常に最前面固定のON/OFFを切り替える。固定中は4辺の枠に色を付けて一目で分かるようにする。

CoordMode "Mouse", "Screen"
DetectHiddenWindows true  ; 最小化中に Hide() した枠も掃除対象として検出できるようにする

WM_NCHITTEST := 0x0084
HTCAPTION    := 2
DWMWA_EXTENDED_FRAME_BOUNDS := 9

BORDER_COLOR := "00BFFF"  ; 固定中インジケータの色 (水色)
BORDER_THICK := 3         ; 枠の太さ(px)
POLL_MS     := 15        ; 追従ポーリング間隔(ms)。ドラッグ中も滑らかに見えるよう短め
SWEEP_MS    := 2000      ; 内部管理から外れた枠を掃除する間隔(ms)
MY_PID      := DllCall("GetCurrentProcessId", "UInt")

FADE_OUT_ALPHA := 40   ; カーソルが外に出た時の半透明具合(0-255。約16%)
FADE_OUT_MS    := 700  ; 半透明になるまでの時間
FADE_IN_MS     := 150  ; 不透明に戻るまでの時間

pinned      := Map()  ; 対象hwnd -> true
overlays    := Map()  ; 対象hwnd -> Gui
overlayHwnd := Map()  ; 枠自身のhwnd -> true (誤クリック除外用)
zfixStreak  := Map()  ; 対象hwnd -> 連続Zオーダー補正回数
zfixGiveUp  := Map()  ; 対象hwnd -> true (補正を諦めたウィンドウ。Windows Terminal 等、
                       ; アプリ自身が内部の補助ウィンドウを常に直上に置き直そうとして
                       ; 際限なく競合するケースがあるため)
fadeState    := Map()  ; 対象hwnd -> {target, startAlpha, curAlpha, startTime, duration}
layeredAdded := Map()  ; 対象hwnd -> true (このスクリプトが WS_EX_LAYERED を追加した場合のみ記録)
entryState        := Map()  ; 対象hwnd -> {wasInside, mode}  ("side"=縦の辺から進入中 / "topbottom" / "")
clickThroughAdded := Map()  ; 対象hwnd -> true (このスクリプトがクリック透過を付与した場合のみ記録)
ovGeom      := Map()  ; 対象hwnd -> 前回適用した枠の "x,y,w,h,角丸" (変化が無い時は SetWindowPos/SetWindowRgn を呼ばない)

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

; トラックパッドで「左押したまま右クリック」がやりにくい場合の代替操作:
; タイトルバーを Alt+クリック(1回のクリックだけで済む)。Alt+クリックは
; Windowsのタイトルバー操作として標準では使われていない組み合わせなので、
; 上のホールド+右クリックとも衝突しない。
#InputLevel 1
!LButton:: HandleAltClick()
#InputLevel 0

HandleAltClick() {
    global WM_NCHITTEST, HTCAPTION, overlayHwnd

    MouseGetPos(&mx, &my, &winHwnd)

    if (winHwnd && !overlayHwnd.Has(winHwnd) && IsTitleBarHit(winHwnd, mx, my)) {
        TogglePin(winHwnd)
        return
    }

    ; タイトルバー以外なら通常のAlt+クリックとして再送する
    Click
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
        DisableFadeSupport(hwnd)
        SetClickThrough(hwnd, false)
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
    EnableFadeSupport(hwnd)
    UpdateOverlay(hwnd)
}

; カーソルがウィンドウの外に出ている間、半透明にして見た目だけ透過させる準備をする
; (クリックは透過させない。見えるだけ)。WS_EX_LAYERED が無いウィンドウには付与し、
; 元々付いていなかった場合のみ解除時に外す(既にレイヤードなアプリの挙動を壊さない)。
EnableFadeSupport(hwnd) {
    global layeredAdded
    WS_EX_LAYERED := 0x80000
    exStyle := DllCall("GetWindowLongPtr", "Ptr", hwnd, "Int", -20, "Ptr")
    if !(exStyle & WS_EX_LAYERED) {
        try DllCall("SetWindowLongPtr", "Ptr", hwnd, "Int", -20, "Ptr", exStyle | WS_EX_LAYERED)
        layeredAdded[hwnd] := true
    }
    try DllCall("SetLayeredWindowAttributes", "Ptr", hwnd, "UInt", 0, "UChar", 255, "UInt", 2) ; LWA_ALPHA
}

DisableFadeSupport(hwnd) {
    global layeredAdded, fadeState
    try DllCall("SetLayeredWindowAttributes", "Ptr", hwnd, "UInt", 0, "UChar", 255, "UInt", 2)
    if layeredAdded.Has(hwnd) {
        WS_EX_LAYERED := 0x80000
        exStyle := DllCall("GetWindowLongPtr", "Ptr", hwnd, "Int", -20, "Ptr")
        try DllCall("SetWindowLongPtr", "Ptr", hwnd, "Int", -20, "Ptr", exStyle & ~WS_EX_LAYERED)
        layeredAdded.Delete(hwnd)
    }
    if fadeState.Has(hwnd)
        fadeState.Delete(hwnd)
}

; 対象ウィンドウに WS_EX_TRANSPARENT を付けて、クリックを裏のウィンドウへ
; 素通りさせる(半透明の見た目はそのまま、操作だけ裏に通す)。既に付いていた
; 場合(アプリ自身の設定)は触らない/外さない。
SetClickThrough(hwnd, enable) {
    global clickThroughAdded
    WS_EX_TRANSPARENT := 0x20
    exStyle := DllCall("GetWindowLongPtr", "Ptr", hwnd, "Int", -20, "Ptr")
    hasIt := (exStyle & WS_EX_TRANSPARENT) != 0
    if (enable && !hasIt) {
        try DllCall("SetWindowLongPtr", "Ptr", hwnd, "Int", -20, "Ptr", exStyle | WS_EX_TRANSPARENT)
        clickThroughAdded[hwnd] := true
    } else if (!enable && hasIt && clickThroughAdded.Has(hwnd)) {
        try DllCall("SetWindowLongPtr", "Ptr", hwnd, "Int", -20, "Ptr", exStyle & ~WS_EX_TRANSPARENT)
        clickThroughAdded.Delete(hwnd)
    }
}

; 対象ウィンドウの中心点がどのモニタ上にあるかを探し、そのモニタの中心と比べて
; 右/左・上/下のどちら寄りかを判定する。「画面の最寄りの角に面した2辺」を
; 固定ウィンドウへのアクセス辺として返す(残り2辺=中央寄りの辺は背面操作用)。
GetAccessEdges(wx, wy, ww, wh) {
    cx := wx + ww / 2
    cy := wy + wh / 2
    monCx := A_ScreenWidth / 2, monCy := A_ScreenHeight / 2  ; 見つからなかった時のフォールバック
    count := MonitorGetCount()
    loop count {
        MonitorGet(A_Index, &l, &t, &r, &b)
        if (cx >= l && cx < r && cy >= t && cy < b) {
            monCx := (l + r) / 2
            monCy := (t + b) / 2
            break
        }
    }
    edges := Map()
    edges[(cy >= monCy) ? "bottom" : "top"] := true
    edges[(cx >= monCx) ? "right" : "left"] := true
    return edges
}

; カーソルが対象ウィンドウの矩形内にあるかどうかで、半透明⇔不透明を滑らかにアニメーションする。
; どの辺から入ったかに加えて「その辺が画面の最寄りの角に面しているか」も見る。
; 画面中央寄りの辺(=普段のカーソル移動で素通りしやすい側)から入った場合は
; 半透明・クリック透過のままにし、画面の端に意図的にカーソルを寄せてから
; 進入した場合(角に面した2辺から)だけ、固定ウィンドウ自体を操作できるようにする。
UpdateFade(hwnd, wx, wy, ww, wh) {
    global fadeState, FADE_OUT_ALPHA, FADE_OUT_MS, FADE_IN_MS, entryState
    MouseGetPos(&mx, &my)
    inside := (mx >= wx && mx < wx + ww && my >= wy && my < wy + wh)

    if !entryState.Has(hwnd)
        entryState[hwnd] := Map("wasInside", false, "mode", "", "prevMx", mx, "prevMy", my)
    est := entryState[hwnd]

    if (inside && !est["wasInside"]) {
        ; 外→中に切り替わった瞬間。直前(外にいた時)のカーソル位置から
        ; 具体的にどの辺(上下左右)を越えてきたかを特定する。
        px := est["prevMx"], py := est["prevMy"]
        dxLeft := wx - px, dxRight := px - (wx + ww)
        dyTop := wy - py, dyBottom := py - (wy + wh)
        dx := Max(dxLeft, dxRight, 0)
        dy := Max(dyTop, dyBottom, 0)
        crossedEdge := (dx > dy) ? ((dxLeft > dxRight) ? "left" : "right")
                                  : ((dyTop > dyBottom) ? "top" : "bottom")
        accessEdges := GetAccessEdges(wx, wy, ww, wh)
        est["mode"] := accessEdges.Has(crossedEdge) ? "access" : "through"
    }
    if !inside
        est["mode"] := ""
    est["wasInside"] := inside
    est["prevMx"] := mx
    est["prevMy"] := my

    throughEntry := (est["mode"] = "through")
    SetClickThrough(hwnd, throughEntry)

    desiredTarget := (inside && !throughEntry) ? 255 : FADE_OUT_ALPHA
    desiredDuration := (inside && !throughEntry) ? FADE_IN_MS : FADE_OUT_MS

    if !fadeState.Has(hwnd)
        fadeState[hwnd] := Map("target", 255, "startAlpha", 255, "curAlpha", 255, "startTime", A_TickCount, "duration", 1)
    st := fadeState[hwnd]

    if (st["target"] != desiredTarget) {
        ; 方向転換: 今の実際のアルファ値から新しい目標へ、新しい所要時間でやり直す
        st["startAlpha"] := st["curAlpha"]
        st["target"] := desiredTarget
        st["startTime"] := A_TickCount
        st["duration"] := desiredDuration
    }

    elapsed := A_TickCount - st["startTime"]
    if (elapsed >= st["duration"])
        alpha := st["target"]
    else {
        t := elapsed / st["duration"]
        alpha := Round(st["startAlpha"] + (st["target"] - st["startAlpha"]) * t)
    }
    st["curAlpha"] := alpha
    ; 値が変わった時だけ適用する(同じ値の再設定でも再合成が走るため)
    if (!st.Has("applied") || st["applied"] != alpha) {
        try DllCall("SetLayeredWindowAttributes", "Ptr", hwnd, "UInt", 0, "UChar", alpha, "UInt", 2)
        st["applied"] := alpha
    }
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
; radius は角の丸みの半径(px)。Windows 11 のウィンドウ角丸に合わせるため、
; 外側だけでなく内側のくり抜きも(枠の太さぶん小さい半径で)丸めることで、
; コーナー部分でも枠の太さが均一に見えるようにする。
CreateFrameRegion(w, h, thick, radius := 0) {
    t := Min(thick, w // 2, h // 2)
    d := radius * 2
    outer := (radius > 0)
        ? DllCall("gdi32\CreateRoundRectRgn", "Int", 0, "Int", 0, "Int", w, "Int", h, "Int", d, "Int", d, "Ptr")
        : DllCall("gdi32\CreateRectRgn", "Int", 0, "Int", 0, "Int", w, "Int", h, "Ptr")
    if (t <= 0)
        return outer
    innerRadius := Max(0, radius - t)
    innerD := innerRadius * 2
    inner := (innerRadius > 0)
        ? DllCall("gdi32\CreateRoundRectRgn", "Int", t, "Int", t, "Int", w - t, "Int", h - t, "Int", innerD, "Int", innerD, "Ptr")
        : DllCall("gdi32\CreateRectRgn", "Int", t, "Int", t, "Int", w - t, "Int", h - t, "Ptr")
    DllCall("gdi32\CombineRgn", "Ptr", outer, "Ptr", outer, "Ptr", inner, "Int", 4) ; RGN_DIFF
    DllCall("gdi32\DeleteObject", "Ptr", inner)
    return outer
}

UpdateOverlay(hwnd) {
    global pinned, overlays, overlayHwnd, BORDER_COLOR, BORDER_THICK, ovGeom
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
        ; 直前のティックの WinExist チェックと、ここでの座標取得の間に
        ; 対象ウィンドウが閉じた可能性が高い。枠だけが取り残されないよう、
        ; ここでも道連れで片付ける(通常の閉じ検知は TrackPinned 側で行う)。
        pinned.Delete(hwnd)
        DestroyOverlay(hwnd)
        return
    }
    ; Gui.Show() は "NoActivate" を付けてもZオーダーに干渉することがあり、
    ; 2つ固定した状態で無関係なウィンドウをクリックすると2枚が入れ替わる不具合の
    ; 原因だった。ここは純粋な移動・リサイズ・表示だけを行い、Zオーダーには
    ; 一切触れない(SWP_NOZORDER)。上下関係はオーナー設定にOSが自動維持する。
    ; Windows 11 の既定の角丸(100%DPIで約8px相当)にDPIを合わせて枠も丸める
    dpi := DllCall("GetDpiForWindow", "Ptr", hwnd, "UInt")
    if !dpi
        dpi := 96
    cornerRadius := Round(8 * dpi / 96)

    ; 位置・大きさ・角丸が前回と同じで枠も表示中なら、移動もリージョン再設定もしない。
    ; 以前は 15ms 毎に無条件で SetWindowPos(SHOWWINDOW) と SetWindowRgn(再描画あり) を
    ; 呼んでいたため、何も動いていなくても DWM が画面を毎秒約66回合成し直し、
    ; GPU がアイドルに下がらなかった(2026-10-05 PC描画もたつき検証で判明)。
    geom := wx "," wy "," ww "," wh "," cornerRadius
    visible := DllCall("IsWindowVisible", "Ptr", ov.Hwnd, "Int")
    if (!visible || !ovGeom.Has(hwnd) || ovGeom[hwnd] != geom) {
        DllCall("SetWindowPos", "Ptr", ov.Hwnd, "Ptr", 0, "Int", wx, "Int", wy, "Int", ww, "Int", wh, "UInt", 0x0004 | 0x0010 | 0x0040)
        ; 0x0004=SWP_NOZORDER, 0x0010=SWP_NOACTIVATE, 0x0040=SWP_SHOWWINDOW
        rgn := CreateFrameRegion(ww, wh, BORDER_THICK, cornerRadius)
        DllCall("SetWindowRgn", "Ptr", ov.Hwnd, "Ptr", rgn, "Int", true) ; 以降 rgn の所有権は OS 側
        ovGeom[hwnd] := geom
    }

    EnsureAboveOwner(hwnd, ov.Hwnd)
    UpdateFade(hwnd, wx, wy, ww, wh)
}

; オーナー設定(生成時にSetWindowLongPtrで後付けしたもの)だけでは、切り替えを
; 繰り返すうちにOSがZオーダー追従を取りこぼし、枠が自分の対象ウィンドウより
; 下に来てしまうことがある。ここで「対象ウィンドウの直前(直上)が本当に自分の
; 枠になっているか」を毎回軽く検証し、ズレていた時だけ補正する。
; (SetWindowPos の hWndInsertAfter は「指定したウィンドウを自分の直前=上に置く」
;  という意味なので、対象ウィンドウ側を「枠の直後(下)」に差し込む形で直す)
EnsureAboveOwner(hwnd, ovHwnd) {
    global zfixStreak, zfixGiveUp
    if zfixGiveUp.Has(hwnd)
        return

    GW_HWNDPREV := 3
    above := DllCall("GetWindow", "Ptr", hwnd, "UInt", GW_HWNDPREV, "Ptr")
    if (above = ovHwnd) {
        if zfixStreak.Has(hwnd)
            zfixStreak.Delete(hwnd)
        return
    }

    ; Windows Terminal 等、アプリ自身が内部の補助ウィンドウ(疑似コンソール等)を
    ; 常に自分の直上に置き直そうとするケースがあり、その場合は毎ティック補正しても
    ; 次のティックでまた負けるだけの無限ループになる(実際に1つのウィンドウで
    ; 数万回/数分というログ肥大が発生した)。連続で補正が必要な回数を数え、
    ; 一定回数を超えたら「このウィンドウとは戦わない」と諦めて静かに抜ける。
    streak := zfixStreak.Has(hwnd) ? zfixStreak[hwnd] + 1 : 1
    zfixStreak[hwnd] := streak
    if (streak = 1)
        LogEvent("ZORDER_FIX hwnd=" hwnd " ovHwnd=" ovHwnd " wasAbove=" above)
    if (streak > 5) {
        LogEvent("ZORDER_GIVEUP hwnd=" hwnd " ovHwnd=" ovHwnd " (別ウィンドウと競合し続けるため以後の補正を停止)")
        zfixGiveUp[hwnd] := true
        return
    }
    try DllCall("SetWindowPos", "Ptr", hwnd, "Ptr", ovHwnd, "Int", 0, "Int", 0, "Int", 0, "Int", 0, "UInt", 0x0001 | 0x0002 | 0x0010)
    ; 0x0001=SWP_NOSIZE, 0x0002=SWP_NOMOVE, 0x0010=SWP_NOACTIVATE
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
    global overlays, overlayHwnd, zfixStreak, zfixGiveUp, entryState, ovGeom
    if ovGeom.Has(hwnd)
        ovGeom.Delete(hwnd)
    DisableFadeSupport(hwnd)
    SetClickThrough(hwnd, false)
    if entryState.Has(hwnd)
        entryState.Delete(hwnd)
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
    if zfixStreak.Has(hwnd)
        zfixStreak.Delete(hwnd)
    if zfixGiveUp.Has(hwnd)
        zfixGiveUp.Delete(hwnd)
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
