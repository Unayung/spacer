# Spacer

桌面上的浮動玻璃面板，放你想看的小工具（widget），想擺哪就擺哪。
拖兩塊到 dock 兩側的死角，就變回「dock 旁的資訊條」；也可以到處丟、疊很多塊。

## 執行（需在 macOS 14+ 上）

```sh
swift run                    # 開發
./make-app.sh                # 打包簽名版 /Applications/Spacer.app
```

選單列有圖示可以管理面板與 Quit。首次點某些 widget 會要授權（行事曆、Ghostty 自動化）。

## 面板

- **Add Panel**：從選單列新增一塊面板；每塊有自己的 widget 清單與位置。
- **拖曳**：拖面板背景即可移動（Liquid Glass 半透明）。
- **Pin**：釘住後固定位置、不能再拖；再按一次解除。
- 面板寬度 = widget 數 × 200；加 / 移 widget 會立刻變寬變窄。

## Widget

Clock、CPU/RAM、Network、GitHub、Now Playing（封面當背景 + 播放控制）、
Calendar、Pomodoro（進度環）、herdr Agents（遠端 SSH agent 看板）。
在面板上右鍵可增減、排序、調字級；每個 widget 點擊有各自的動作
（開對應 app / 網頁 / 終端機）。

外觀：選單列可切 Glass Background、Panel Border；每塊面板都是同一組
「儀表」視覺語彙（圓體等寬數字 + 微型大寫標籤 + 琥珀 HUD 色）。

## 取捨（要升級再說）

- widget 內容與點擊動作寫死在 `main.swift`；herdr 的遠端主機也寫死 `omarchy-outside`。
- 面板不會自動閃避 dock 放大或 fullscreen（改成純浮動後拿掉了那套邏輯）。
