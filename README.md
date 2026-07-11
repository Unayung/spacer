# Spacer

桌面上的浮動玻璃面板，放你想看的小工具（widget），想擺哪就擺哪。
可以開很多塊、各自放不同 widget；拖到 dock 兩側死角再釘住，就變回「dock 旁的資訊條」。

![Spacer](docs/screenshot.png)

macOS 14+（玻璃背景在 macOS 26 是 Liquid Glass，較舊版本退回毛玻璃）。純 SwiftUI/AppKit，
單一檔案 `Sources/Spacer/main.swift`。

## 安裝

```sh
swift run          # 開發跑一下
./make-app.sh      # 打包 + Developer ID 簽名 → /Applications/Spacer.app（TCC 授權不會因重 build 失效）
```

以 menu bar accessory 常駐（沒有 dock 圖示），選單列的格子圖示管理所有面板。
`make-app.sh` 會註冊開機啟動（也可從選單 Launch at Login 開關）。

## 面板

- **Add Panel** — 選單列新增一塊；每塊有自己的 widget 清單、位置、釘住狀態，存 UserDefaults。
- **拖曳** — 拖面板背景即可移動。
- **Pin** — 釘住後鎖定位置、不能再拖；再點一次解除。
- 面板寬度 = widget 數 × 200 + 分隔線；加／移 widget 會立刻變寬變窄。
- 在面板的 widget 上**右鍵**：左右移、放大／縮小字級、Add Widget、Remove。

## Widget

| Widget | 顯示 | 點擊 | 相依 |
|--------|------|------|------|
| Clock | 時間（圓體等寬）＋日期 | Clock.app | — |
| CPU / RAM | 負載膠囊儀表（綠→琥珀→紅） | Activity Monitor | — |
| Network | ↓／↑ 即時流量 | Activity Monitor | — |
| GitHub | 我的開啟 PR 數・待我 review 數 | github.com | `gh`（已登入） |
| Now Playing | 封面滿版當背景＋跑馬燈標題＋播放控制 | 沒播放時開 YouTube | `media-control`（brew） |
| Calendar | 今天接下來幾個行程 | Calendar.app | 行事曆授權 |
| Pomodoro | 倒數進度環 | 點一下開始／停止 25 分鐘 | — |
| herdr Agents | 遠端 agent 狀態（working／blocked／idle） | 跳到既有 Ghostty 分頁或新開一個 | `ssh` + 遠端 herdr |

所有 widget 共用一組「儀表」視覺語彙：圓體等寬數字 + 微型大寫標籤 + 琥珀 HUD 色。

## 選單

Start / Stop Pomodoro ・ 每塊面板（Pin、widget 管理、Remove Panel）・ Add Panel ・
Glass Background ・ Panel Border ・ Launch at Login ・ Quit。

## 權限與相依

- **Calendar**：EventKit，第一次點 Calendar widget 會要授權。
- **Apple Events**：herdr widget 用 AppleScript 操作 Ghostty 開分頁，第一次會要授權。
- 選用 CLI：`gh`（GitHub）、`media-control`（Now Playing）、`ssh`＋遠端 `herdr`（herdr widget）。
  沒裝的 widget 會顯示 `—`，不影響其他 widget。

## 取捨（要升級再說）

- widget 內容與點擊動作寫死在 `main.swift`；herdr 的遠端主機也寫死 `omarchy-outside`。
- 面板是純浮動：不會自動閃避 dock 放大，也不會在 fullscreen 時自動隱藏。
