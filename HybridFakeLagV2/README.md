# HybridFakeLag V2 - TrollNetInterceptor + Fake-lag + Floating Button + Logs + Config

Bản mix hoàn chỉnh theo yêu cầu: **floating button như TrollNetInterceptor, lưu log all action, tuỳ chỉnh config chặn**

## Tính năng mới so với V1

### 1. Floating Button giống TrollNetInterceptor (100%)
- **File gốc đã port:** `HUD/HUDMain.mm`, `HUDRootApplication.mm`, `FloatingToggleButton.h/.mm`, `HUDMainWindow.h/.mm`, `TSEventFetcher`, `IOHIDEventKIF`
- Cơ chế: 
  - Main App spawn HUD daemon bằng `posix_spawnattr_set_persona_np(99) UID 0` -> daemon sống sót qua lock/unlock, windowLevel `10000010.0` render trên mọi app/game
  - Đăng ký qua `SBSAccessibilityWindowHostingController.registerWindowWithContextID:atLevel:`
  - Touch qua BackBoard HID pipeline `BKSHIDEventRegisterEventCallback` -> `AXEventRepresentation` -> `TSEventFetcher` -> gesture recognizers
  - Nút tròn: viền titanium, orbital ring quay khi active, icon ▶ (tắt) / ⏸ (bật), badge số packet held
  - Kéo tự do, edge snap magnet, lưu vị trí vào shared memory, haptic feedback
  - Passthrough hit-test: chỉ ăn touch đúng nút, còn lại xuyên qua game
- Điều khiển: Tab Home có nút "Create/Remove Floating Button", hoặc spawn tự động khi bật VPN

### 2. Lưu log all action
- **3 nơi log:**
  1. `group.com.hybrid.fakelag/hybrid_actions.log` (App Group, share giữa app và extension) - log mọi action: APP_LAUNCH, VPN_CONNECT, BLOCK_ENABLE/DISABLE, SELECT_PID, CONFIG_SAVE, PRESET_APPLY, HUD_CREATE/REMOVE, TUN_START/STOP, FLUSH
  2. `Documents/aethernet.log` (app log) + `/var/mobile/Library/aethernet-hud.log` (daemon log) - từ AetherNet AetherLog.mm với rotation 256KB -> 128KB
  3. Extension log trong cùng file App Group: `[ext] TUN_START`, `MSG_ENABLE`, `FLUSH`
- **UI Logs tab:** hiển thị live, auto-refresh 1s, merge cả 3 nguồn, nút Clear/Export
- **Format log:** `[timestamp] ACTION details` + `[ext] passed/dropped/held` stats

### 3. Tuỳ chỉnh config chặn đầy đủ

**Tab Settings:**
- **Interception Rules:**
  - Direction: Both / Download RX only / Upload TX only
  - Protocol: TCP+UDP / UDP only / TCP only
  - Mode: Hold (Freeze/Ghost) / Drop 100% / Delay+Jitter / Tamper
  - Capture Ratio 0-100% (master) + Download/Upload ratio riêng
- **Network Simulation:**
  - Latency RTT 0-1500ms + Jitter 0-500ms
  - Bandwidth cap 0-20Mbps
  - Duplicate UDP %
  - Auto-flush Off/5s/12s/30s (chống treo)
  - Preset: Normal / Ghost-Freeze 98% / Lag Spike 450ms / Degraded 3G 280ms 128kbps / TCP-RST
- **Floating Button:**
  - Diameter 40-88pt slider
  - Opacity 35-100%
  - Edge snap, Lock position, Haptics
- **Per-PID Filtering:**
  - Chọn PID từ sheet (search theo tên/bundle/PID, hiện TCP/UDP socket count, icon app)
  - Dump socket list remote IP/port vào App Group -> extension chỉ chặn packet match target
  - GLOBAL mode = chặn tất cả

## Kiến trúc V2

```
HybridFakeLag.app (single binary, TrollStore permasign)
  ├─ main.mm dispatcher: -hud / -exit / -check / normal
  ├─ Hybrid/
  │   ├─ App.swift + AppDelegate (host ContentView)
  │   ├─ ContentView.swift (3 tabs: Home, Settings, Logs)
  │   ├─ VPNManager.swift (NETunnelProviderManager + App Group sync)
  │   ├─ ProcessManager.swift (sysctl + proc_pidinfo)
  │   ├─ AppGroup.swift (HybridConfig JSON + logging + shm sync)
  │   ├─ FloatingHUDManager.swift (spawn root daemon)
  │   ├─ SettingsView.swift (full config UI)
  │   └─ LogsView.swift (live logs)
  ├─ Core/
  │   ├─ AetherLog.h/.mm (persistent logging)
  │   ├─ AetherSharedMemory.mm (mmap shm /var/mobile/Library/Caches/com.aethernet.shared.shm)
  │   ├─ ProcessManager.h/.mm (objc, inject + HUD spawn)
  │   ├─ MachInjector.mm (task_for_pid remote dlopen + pf fallback)
  │   └─ DopamineBridge.h/.mm (Tier 0 PPL bypass via jbserver XPC)
  ├─ HUD/ (global floating button daemon)
  │   ├─ HUDMain.mm (event callback, raw digitizer parsing, payload installer)
  │   ├─ HUDRootApplication.mm (windowLevel 10000010 + SBS hosting)
  │   ├─ FloatingToggleButton.h/.mm (circular button ▶/⏸ + badge)
  │   ├─ HUDMainWindow.h/.mm (passthrough hitTest)
  │   └─ TSEventFetcher + IOHIDEventKIF (touch synthesis)
  ├─ UI/AppTheme (obsidian gold theme)
  ├─ headers/AetherNetShared.h (shm struct)
  └─ Payload/libNetHookPayload.dylib (fishhook hooks, fixed EWOULDBLOCK sleep 20ms)

HybridExtension (PacketTunnelProvider FIXED V2)
  ├─ PacketTunnelProvider.swift (no kill, bounded queue, per-PID filter, logging)
  └─ Info.plist + entitlements

Supports
  ├─ entitlements.plist (38 keys merged: platform-app, no-sandbox, persona-mgmt, task_for_pid, networkextension full, app-groups)
  └─ Info.plist
```

## Flow hoạt động

1. **User mở app** -> `AppGroupStore.logAction("APP_LAUNCH")` -> check VPN status + HUD status
2. **Bật VPN** -> `VPNManager.connectVPN()` -> save config enabled=false (pass-through) -> `NETunnelProviderManager` start tunnel -> extension `startTunnel` set TUN 10.8.0.2 mtu 1280 includeAllNetworks=true -> `readLoop()` fixed không bị kill
3. **Chọn PID** -> `ProcessManager` scan sysctl + proc_pidfdinfo -> dump sockets -> `AppGroupStore.save()` -> log SELECT_PID
4. **Create Floating Button** -> `FloatingHUDManager` spawn `-hud` với persona UID 0 -> daemon `HUDMain` load private frameworks, `SBSAccessibilityWindowHostingController.registerWindow`, `BKSHIDEventRegisterEventCallback`, tạo `FloatingToggleButton` -> heartbeat shm mỗi 1s
5. **Bật FakeLag** (qua app button hoặc floating button tap) -> `setInterceptionActive(true)` -> write `hybrid_config.json` enabled=true mode=hold -> notify `com.aethernet.interceptor.state_changed` -> HUD button đổi ▶->⏸ + orbital ring quay + badge held count, extension `handlePacket` giữ packet trong heldQueue 512, payload fishhook (nếu inject được) cũng giữ
6. **Tắt FakeLag** -> flush held queue ngay (cả TUN và payload) -> log FLUSH -> game tiếp tục
7. **Logs** -> mọi action ghi vào App Group log + AetherLog files, UI Logs tab merge hiển thị

## Fix kill đã áp dụng (từ V1)

- ReadLoop không lồng async, 1 readQueue + 1 writeQueue
- Bounded queue 512, flush khi OFF
- Single delay timer 0.1s, không per-packet timer
- Không drop SYN/FIN/RST
- Per-PID filter giảm 90% tải
- Payload recv hold sleep 20ms tránh busy-loop

## Build & Cài

### Linux crossbuild (như AetherNet)
```bash
sudo apt-get install clang lld
curl -Lo ~/.cache/ldid https://github.com/ProcursusTeam/ldid/releases/latest/download/ldid_linux_x86_64 && chmod +x ~/.cache/ldid
git clone --depth=1 --filter=blob:none --sparse https://github.com/theos/sdks.git ~/.cache/sdk-repo
cd ~/.cache/sdk-repo && git sparse-checkout set iPhoneOS16.5.sdk && cd -
# Build
clang -arch arm64 -isysroot ~/.cache/sdk-repo/iPhoneOS16.5.sdk -Iheaders -ICore -IHUD -c Core/*.mm HUD/*.mm Payload/*.c -o build/
ldid -S supports/entitlements.plist build/HybridFakeLag
```

### macOS Xcode
1. Tạo project mới, Bundle ID `com.hybrid.fakelag`, App Groups `group.com.hybrid.fakelag`, NetworkExtension packet-tunnel
2. Add tất cả files trong `HybridFakeLagV2/` vào target
3. Extension target: Bundle ID `com.hybrid.fakelag.extension`, App Groups same, entitlements `HybridExtension/entitlements.plist`
4. Build Release arm64, `CODE_SIGNING_ALLOWED=NO`, sau đó `ldid -S supports/entitlements.plist`

### Cài qua TrollStore
- Copy .tipa vào iPhone -> mở bằng TrollStore -> Install
- Mở app -> cho phép VPN -> Bật VPN -> Create Floating Button -> Chọn PID game -> Bật FakeLag bằng nút nổi

## Log ví dụ

```
[2026-09-30T05:55:00Z] APP_LAUNCH Hybrid V2 launched
[2026-09-30T05:55:10Z] VPN_CONNECT starting tunnel
[2026-09-30T05:55:12Z] SELECT_PID FreeFire pid=1234 bundle=com.dts.freefire
[2026-09-30T05:55:13Z] CONFIG_SAVE mode=hold dir=both proto=both target=com.dts.freefire pid=1234 latency=350 ratio=100
[2026-09-30T05:55:15Z] HUD_CREATE spawning daemon
[2026-09-30T05:55:20Z] BLOCK_ENABLE mode=hold target=FreeFire
[2026-09-30T05:55:20Z] [ext] FLUSH flushing 0 held packets
[2026-09-30T05:55:25Z] BLOCK_DISABLE mode=hold target=FreeFire
[2026-09-30T05:55:25Z] [ext] FLUSH flushing 87 held packets passed=1234 dropped=12 held=0
```

## Credits

- opa334/TrollStore - CoreTrust bypass & arbitrary entitlements
- opa334/Dopamine - PPL/SPTM bypass
- Lessica/TrollSpeed - HUD plugin-mode & HID pipeline
- facebook/fishhook - symbol rebinding
- LLOS-Lord/Fake-lag - base VPN TUN
- AetherNet - floating button visual + shm + payload architecture
