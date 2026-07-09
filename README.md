# Spacer

在超寬螢幕（如 3440x1440）上，macOS dock 置中後左右各剩一大塊死角。
Spacer 在那裡放兩塊跟 dock 同層級的玻璃面板：左邊時鐘＋日期，右邊 CPU / RAM。

## 執行（需在 macOS 13+ 上）

```sh
swift run                    # 開發
swift build -c release       # 產出 .build/release/Spacer
```

不需要任何權限（dock 位置用 CGWindowList 的 ownerName + bounds 偵測，
不碰 Accessibility 也不碰螢幕錄製）。選單列有一個圖示可以 Quit。

## 行為

- 每 2 秒重新偵測 dock 位置（app 增減會改變 dock 寬度）。
- dock 自動隱藏、放到左右側、或死角寬度 < 200pt 時，面板自動隱藏。
- 面板點擊穿透，純顯示，不搶焦點。

## 目前的取捨（要升級再說）

- 只支援主螢幕、dock 在底部。
- 面板內容寫死：左時鐘、右系統數據。想換內容改 `main.swift` 裡的
  `ClockView` / `StatsView` 即可。

## 這塊空間還能拿來做什麼（roadmap 候選）

- 正在播放 + 播放控制（需拿掉點擊穿透）
- 今日行事曆下一個行程（EventKit）
- 剪貼簿歷史 / 拖放暫存架（Yoink 式 shelf）
- 常用 app 快捷列 / 最近檔案
- 番茄鐘、天氣、網路流量、CI 或 Docker 狀態
