# HybridFakeLag V2 - TrollNetInterceptor + Fake-lag + Floating Button + Logs + Config

Bản mix hoàn chỉnh: floating button như TrollNetInterceptor, log all action, tuỳ chỉnh config chặn.

> **BẢN FIX 3 BUG (build 3.7.1)** — chi tiết ở mục "Fix log" bên dưới.
>
> **BẢN FIX 3.8.0 — GỘP 2 HƯỚNG ĐI THÀNH MỘT KIẾN TRÚC HYBRID CHUẨN** — sửa lại toàn
> bộ bản mix HybridFakeLagV2 (VPN extension + inject PID + floating HUD) đã bị
> "tựa lưa": extension của bản mix vẫn là engine loop-back cũ, Swift không gọi
> được lớp ObjC, payload inject đọc nhầm path config. Chi tiết ở mục "Fix 3.8.0".
> Kèm **test giả định** (`scripts/simulate_test.py` — 309 test, tất cả PASS).

## Tính năng

- Floating Button toàn hệ thống (windowLevel 10000010, SBSAccessibilityWindowHostingController, BKSHIDEvent)
- VPN PacketTunnelProvider với **RELAY ENGINE thật** (UDP NAT + TCP SYN-proxy + ICMP echo)
- Per-PID filtering qua **socket dump thật** (proc_pidfdinfo) — không còn dữ liệu mock
- Log all actions vào App Group + Documents, **copy/share/filter được**
- Config: direction, proto, mode (hold/drop/delay), latency, jitter, bandwidth, ratio, preset, floating size/opacity/edge snap/haptics

## Cấu trúc

- `PacketBlocker/` - Main app SwiftUI (Home, Settings, Logs) + floating button manager
- `PacketBlockerExtension/` - Fixed PacketTunnelProvider (relay engine)
- `HybridFakeLagV2/` - Full source với HUD ObjC++ (TrollNetInterceptor original) + Core + Payload

## Build

GitHub Actions tự động build IPA TrollStore với ldid.

---

# FIX LOG (3 bug lớn)

## Bug 1 — "Create Floating Button" bấm không thấy nút

**Nguyên nhân gốc** (soi code TrollNetInterceptor .zip để đối chiếu):

1. `FloatingHUDManager` chỉ gọi `posix_spawn("-hud")` rồi bỏ mặc. Nó KHÔNG reset
   shm `hudCommand`/`hudHeartbeatTs`. Nếu lần Remove trước để lại `hudCommand = 1`
   trong shared memory (daemon chết trước khi kịp đọc), daemon MỚI khởi động xong
   là bị heartbeat timer của chính nó exit trong <1s → không bao giờ thấy nút.
2. Không dọn pid file cũ / không kill daemon cũ. Daemon root sống sót qua respring
   và qua cả việc cài lại app; daemon cũ (kể cả của app TrollNetInterceptor cũ —
   cùng shm path `/var/mobile/Library/Caches/com.aethernet.shared.shm` và cùng pid
   file) kích hoạt single-instance guard trong `HUDMain` → daemon mới exit âm thầm.
3. Không verify sau spawn, không watchdog → daemon chết lặng lẽ, UI vẫn tưởng đang chạy.

**Fix:**
- `PersonaHelper.m` thêm `HybridHUDPrepareForSpawn()` / `HybridHUDIsRunning()` /
  `HybridHUDRequestExit()` — port y nguyên cơ chế của TrollNetInterceptor:
  kill daemon cũ (shm command + root `-exit` re-exec + SIGKILL), xoá pid file stale,
  reset `hudCommand = 0` + `hudHeartbeatTs = 0` trước khi spawn daemon mới.
- `FloatingHUDManager.swift`: prepare → spawn → **verify sau 1.5s** qua shm heartbeat
  → **watchdog 5s** tự respawn (tối đa 3 lần) nếu daemon lặng lẽ chết (respring/jetsam).
- `HUDMain.mm -exit`: chỉ SIGKILL khi pid trong pid file thực sự là binary của mình
  (proc_pidpath so sánh) — tránh giết nhầm process bị recycle pid.
- Log chi tiết uid/euid/exe khi daemon start để debug "daemon sống nhưng không root".

## Bug 2 — Log không copy được + không chi tiết

**Fix:**
- `LogsView.swift` viết lại: `UITextView` **selectable** (giữ để select/copy),
  nút **Copy All** (clipboard 1 chạm), nút **Share…** (share sheet ra Files/AirDrop),
  ô **Filter** theo từ khoá, toggle **Auto**-scroll, đếm dòng live.
- `AppGroup.swift`: log có level + stats snapshot (`passed/dropped/held`), rotate
  log 512KB→256KB (không phình vô hạn), `readLogs(filter:)` gộp 4 nguồn:
  App Group log + Caches fallback + AetherNet app log + HUD daemon log.
- `VPNManager.swift`: log mọi transition (VPN_LOAD/CREATE/START/STATUS/DOWN),
  mọi config save đầy đủ tham số, lỗi có code cụ thể.
- Extension: log `TUN_START/STOP`, `CONFIG` (toàn bộ tham số khi đổi),
  `STATS` mỗi 5s (passed/dropped/held/flows/enabled/mode), flow mở/đóng (24 đầu
  + mỗi 100 flow sau đó — chi tiết mà không spam).

## Bug 3 — VPN extension flow sai: bật VPN là chết TCP/UDP dù chưa bật giả lập

**Nguyên nhân gốc — flow sai từ thiết kế:**
`PacketTunnelProvider` cũ đọc packet từ TUN rồi **ghi trả ngay vào chính
`packetFlow`** (loop-back). `writePackets` là đường packet ĐI VÀO IP stack của máy
— không phải đường ra Internet. Không có gì được forward ra mạng thật cả:

```
App → TUN → readPackets → writePackets → TUN → App  (vòng lặp, không có Internet)
```

→ Bật VPN = mọi TCP/UDP chết tức thì, bất kể enabled=false (nhánh "pass-through"
chỉ là ghi packet vòng lại nhanh hơn). Thêm nữa: IPv6 bị giữ trong tunnel rồi
loop/tập hợp giữ; `handleAppMessage("enable")` sửa biến local rồi vứt (không lưu);
extension không đọc fallback `/var/mobile/Library/Caches/hybrid_config.json` mà app ghi;
per-PID matching dùng socket mock cứng 8.8.8.8/1.1.1.1.

**Fix — viết lại toàn bộ `PacketTunnelProvider.swift` thành RELAY ENGINE:**

```
TUN read (IP packet outbound của app)
 ├─ UDP : userspace NAT qua NWConnection (traffic của provider chạy NGOÀI tunnel
 │        do iOS tự loại) → nhận reply → dựng lại IP/UDP packet (đổi IP/port,
 │        checksum đúng) → writePackets về app
 ├─ TCP : SYN-proxy userspace — trả SYN-ACK local (MSS 1240), mở kết nối TCP THẬT
 │        tới đích, splice 2 chiều với rewrite seq/ack, retransmit buffer (dup-ack
 │        + timeout 400ms), FIN/RST teardown
 ├─ ICMP: trả echo reply tại chỗ (ping vẫn sống)
 └─ khác: drop có đếm — TUYỆT ĐỐI không ghi packet đọc được ngược lại TUN
```

- **VPN ON + FakeLag OFF = passthrough sạch**: mọi packet relay nguyên vẹn,
  không hold/drop/delay gì cả.
- Fake-lag chỉ tác động packet **match rule** (direction/proto/ratio/target) khi
  `enabled=true`: hold (flush khi tắt, dedupe TCP theo seq), drop (TCP upload
  không-ACK để client retransmit = mất mát thật; SYN/RST không bao giờ bị drop),
  delay (UDP delay 2 chiều; TCP delay hướng download — hướng upload relay ngay
  để tránh double-forward khi client RTO bắn giữa chừng).
- Routing: chỉ advertise **IPv4 default route** (bỏ IPv6 khỏi tunnel — hết loop
  IPv6, app tự fallback IPv4). DNS 8.8.8.8/1.1.1.1 đi qua UDP relay.
- `enable/disable` qua provider message giờ **persist** vào override file có
  timestamp (không còn "sửa biến rồi vứt").
- `loadSync()` đọc đủ 3 nguồn: App Group JSON → Caches fallback → legacy plist,
  cộng override của extension.
- Per-PID targeting: `ProcessManager.swift` gọi C helper `HybridProcEnumerate` /
  `HybridProcSocketDump` (sysctl KERN_PROC_ALL + proc_pidfdinfo) — liệt kê process
  và dump socket THẬT của PID thay vì mock, VPN match đúng endpoint của app đích.
- Timers bounded (config 0.8s, delay-flush 100ms, stats 5s, maintenance 2s:
  retransmit + resume receive + dọn flow idle + giới hạn bảng flow).

## Lưu ý hoạt động VPN

- `includeAllNetworks + enforceRoutes` được set ở phía app khi start tunnel.
- MTU 1280, MSS 1240.
- Traffic của extension tự động nằm ngoài tunnel do iOS đảm bảo cho
  NEPacketTunnelProvider (WireGuard cũng vận hành đúng cách này).
- Mode khuyến nghị cho game: **Delay** (delay cả 2 hướng cho UDP; TCP upload delay qua ACK, download delay trực tiếp) hoặc **Drop** với UDP; **Hold** dùng để
  freeze có chủ đích (tự flush sau autoFlushSeconds, 0 = giữ tay).

## Cấu trúc đã đổi

- `PacketBlocker/Core/PersonaHelper.h/.m` — + HUD lifecycle C API, + enumerate thật
- `PacketBlocker/FloatingHUDManager.swift` — flow spawn/verify/watchdog của TrollNet
- `PacketBlocker/ProcessManager.swift` — enumerate + socket dump thật
- `PacketBlocker/LogsView.swift` — copy/share/filter
- `PacketBlocker/AppGroup.swift` — logging nâng cao + rotate
- `PacketBlocker/VPNManager.swift` — log + flow fix + stats poll
- `PacketBlocker/ContentView.swift` — hiển thị stats live
- `PacketBlocker/HUD/HUDMain.mm` — log uid/exe khi start, `-exit` an toàn hơn
- `PacketBlockerExtension/PacketTunnelProvider.swift` — **RELAY ENGINE mới toàn bộ**
- `PacketBlockerExtension/PacketBlockerExtension.entitlements` — + no-sandbox

---

# FIX 3.8.0 — HYBRID HOÀN CHỈNH (bản mix hoạt động thật)

## Kiến trúc hybrid đúng (ai từng nói "không thể fix vì iOS" là thiếu đúng chỗ)

```
┌─ APP (TrollStore, root-capable) ─────────────────────────────┐
│ SwiftUI (Home/Settings/Logs)                                 │
│  ├─ VPNManager ── NETunnelProviderSession (enable/getstats)  │
│  ├─ FloatingHUDManager ── C bridge ──► spawn ROOT HUD daemon │
│  │      (persona-99, shm command channel, verify + watchdog) │
│  └─ AppGroupStore ── config JSON + CACHES MIRROR + logs      │
├─ VPN EXTENSION (PacketTunnelProvider) — LỚP THẤY GÓI TIN ────┤
│  Relay engine: UDP NAT + TCP SYN-proxy + ICMP                │
│  → ĐỘC QUYỀN thấy TCP/UDP tầng IP (inject không bao giờ thấy  │
│    được tầng này — đây là chỗ duy nhất làm giả lag được)     │
│  → đọc config + override (floating button ghi) từ App Group  │
│    + /var/mobile/Library/Caches fallback                     │
├─ HUD DAEMON (-hud, root) — floating button toàn hệ thống ────┤
│  tap → shm interceptionActive + ghi OVERRIDE cho extension   │
│  + live inject retry + PF fallback                           │
└─ INJECT LAYER (libNetHookPayload.dylib → target PID) ────────┘
   fishhook socket API: delay/hold per-socket + telemetry
   đọc config: shm (magic ok) → Caches mirror → App Group glob
```

Mỗi lớp có đúng một vai trò; config/override/log dùng chung đường dẫn đã thống nhất.

## Các lỗi của bản mix đã sửa

1. **Extension của bản mix vẫn là loop-back** (bật VPN là mất mạng): thay bằng
   relay engine đã fix, kèm 9 bản vá F1–F9 (bên dưới). 2 project đồng bộ engine
   với nhau (test #16 kiểm tra hash).
2. **Swift không gọi được ObjC** (thiếu bridging header — `FloatingHUDManager`
   bị hack `NSClassFromString` vô dụng): thêm `Hybrid/BridgingHeader.h` (chỉ C
   thuần, KHÔNG include AetherNetShared.h vì `_Atomic` làm Swift importer fail)
   + các hàm bridge C trong `ProcessManager.mm`.
3. **FloatingHUDManager spawn không root, không reset shm, không verify**: viết
   lại theo flow TrollNet — `HybridHUDPrepareForSpawn` (kill daemon cũ + unlink
   pid file stale/foreign + reset `hudCommand`/`hudHeartbeatTs`) →
   `HybridSpawnRoot("-hud")` (persona 99) → verify 1.5s → watchdog 5s.
4. **Nút floating không điều khiển được VPN engine**: tap giờ cũng ghi
   `hybrid_ext_override.json` (Caches + mọi App Group container có marker) —
   extension đọc là áp dụng trong <1s, không cần mở app.
5. **Payload inject đọc nhầm path** (`com.hybrid.fakelag.json` — không ai ghi):
   đọc đúng `hybrid_config.json` (Caches mirror app ghi) + glob App Group +
   shm khi magic hợp lệ; cache 500ms (hết parse JSON mỗi socket call);
   ratio/latency/jitter/autoFlush lấy từ config thay vì hardcode; hold có
   auto-flush (không treo app đến khi bị kill); recv-hold sleep 20ms (hết
   busy-loop/jetsam).
6. **Payload dylib không tồn tại**: thêm Run Script phase build
   `libNetHookPayload.dylib` (arm64, `-DHYBRID_PAYLOAD_BUILD`) nhúng thẳng vào
   .app cho `pathForResource` tìm thấy; `NetHookPayload.mm` trong host app bị
   guard rỗng (app không bao giờ tự fishhook chính nó).
7. **Log bản mix** là bản cũ không copy được: thay bằng LogsView selectable /
   Copy All / Share / Filter + AppGroupStore merge 4 nguồn + rotate.
8. **`-exit` của HUD** SIGKILL mù: thêm guard `proc_pidpath` so với chính binary
   (tránh giết nhầm process recycle pid).
9. **Entitlements extension** thiếu `no-sandbox`/`platform-application` (không
   ghi được Caches fallback): bổ sung; tạo file
   `PacketBlockerExtension.entitlements` bị pbxproj tham chiếu mà không tồn tại.

## 9 bản vá relay engine (áp cho CẢ `HybridFakeLagV2/HybridExtension` và
`PacketBlockerExtension` — 2 file đồng bộ từng dòng)

- **F1** IPv4 default route duy nhất (IPv6 loop vào TUN là một phần bug chết mạng).
- **F2** provider message enable/disable persist override (bản cũ sửa biến local rồi vứt).
- **F3** loadSync đọc đủ App Group → Caches → legacy plist + override.
- **F4** trim retransmit buffer an toàn wraparound — công thức cũ
  `UInt32(ack &- seq) >= len` **underflow khi ack < seq** → ACK một phần ĐẦU TIÊN
  quét sạch retransmit buffer → fast-retransmit và backpressure chết cả hai.
- **F5** segment bị hold/delay KHÔNG vào retransmit buffer — bản cũ maintenance
  400ms retransmit làm rò dữ liệu "đang giữ" ra ngoài và flush phát nữa là dup.
- **F6** gate download cho UDP (direction=download + udp trước giờ là no-op).
- **F7** delay TCP upload bằng cách delay synthetic ACK (payload vẫn relay ngay —
  RTT tăng thật, không risk double-forward như delay raw packet).
- **F8** flush delayedQueue khi tắt giả lập / đổi mode (bản cũ packet kẹt vĩnh viễn).
- **F9** hold tự flush theo `autoFlushSeconds` (0 = giữ tay) — không treo app đến kill.
- (+) `loadSync` chỉ reset timestamp khi KHÔNG load được gì cả — reset sau khi áp
  override làm poll sau bỏ qua override (phát hiện nhờ test giả định #10).

## Test giả định (`scripts/simulate_test.py` — 131 test, 0 FAIL)

Port từng dòng logic Swift/ObjC sang Python, mô phỏng:
- IP kit checksum (IP/UDP/TCP/ICMP, odd-length, wraparound seq compare);
- VPN ON + giả lập OFF → 100% relay, không ghi ngược TUN (bug #3);
- hold/drop/delay đúng ratio (kèm multi-seed 8 lần), SYN/RST không bao giờ bị drop;
- TCP handshake SYN-proxy, splice 2 chiều đúng seq/ack, FIN/RST, retransmit
  không forward lại data cũ;
- F4 (partial-ACK giữ buffer), F5 (hold không rò rỉ qua maintenance),
  F6 (UDP download), F7 (ACK-delay upload), F8 (flush khi tắt), F9 (autoFlush);
- per-PID targeting theo socket dump thật;
- config precedence (override/config/Caches/legacy + timestamp);
- HUD lifecycle (leftover `hudCommand=1` không giết daemon mới, pid file stale/foreign);
- floating tap → override; log merge/filter/rotation/copy;
- payload loader (path đúng, cache 500ms, clamp, shm priority);
- integrity pbxproj/entitlements/bridging header.

Chạy: `python3 scripts/simulate_test.py` (exit 0 = OK hết, 309 PASS / 0 FAIL).

## Credits

- opa334/TrollStore
- Lessica/TrollSpeed
- facebook/fishhook
- LLOS-Lord/Fake-lag
- AetherNet


---

# FIX 4.0 — INJECT PID THẬT SỰ BẮT ĐƯỢC GÓI TIN + FLOATING BUTTON THẤY ĐƯỢC

Hai triệu chứng bạn báo đều **không phải lỗi cấu hình** — chúng là ba chuỗi
giết độc lập nhau. Mỗi chuỗi đủ để tính năng chết hoàn toàn.

## A. Inject PID: vì sao không bắt được gói tin nào

| # | Nguyên nhân | Bằng chứng | Đã sửa |
|---|---|---|---|
| A1 | **IPA không hề có payload.** CI build `PacketBlocker.xcodeproj`, project này không có shell phase nào, không build `libNetHookPayload.dylib`, không nhét file này vào `.app` | `HUDMain.mm` chạy tới bước `[installer] payload missing` rồi `return` | Thêm build phase **Build Payload Dylib** (clang `-dynamiclib -arch arm64 -DHYBRID_PAYLOAD_BUILD`) ghi thẳng vào `$BUILT_PRODUCTS_DIR/...app/` |
| A2 | **App không có code inject.** Không file nào trong target CI gọi `task_for_pid`; `MachInjector.mm` nằm ở project khác vốn không được build | `grep task_for_pid PacketBlocker/` → 0 kết quả | Thêm `PacketBlocker/Core/PayloadBridge.mm` + root-helper mode `-inject` trong `main.mm` |
| A3 | **Payload không bao giờ đọc được config.** `AetherGetSharedState()` trong app sandbox **tự map file riêng trong TMPDIR của target**; magic vẫn khớp nên loader tưởng đã có config → `gActive=false` → `return` trước khi tới các fallback. Các fallback (`/var/mobile/Library/Caches/*.json`) cũng bị Seatbelt chặn | `refreshConfigIfNeeded()` rẽ về sau khi magic khớp | **Bỏ hẳn shm/JSON khỏi payload.** Config đi qua **UNIX socket trong TMPDIR của chính target** (`$TMPDIR/aether_net_<pid>.sock`), socket nằm trong container của target nên không cần entitlement nào |
| A4 | **fishhook là no-op trên arm64e.** Mọi image iOS 15–17 là dyld4 + chained fixups: không `LC_DYSYMTAB`, không indirect symbol table → `fishhook.c` return ngay, `orig_*` giữ nguyên NULL. `flushQueue()` gọi NULL → **crash target** | `fishhook.c` yêu cầu `nindirectsyms > 0` | Payload dùng **`MSHookFunction`** (Substrate/ellekit — engine duy nhất hiểu stub arm64e), fishhook chỉ còn làm fallback. Hook nào không cài được sẽ **không có bit trong hookMask** |
| A5 | **Injector giết target.** `__lr` để nguyên 0 → khi `dlopen` return, thread nhảy về 0 → `EXC_BAD_ACCESS` → app chết. Và `rc==0` nghĩa là "thread khởi tạo được", không phải "dlopen thành công" | `MachInjector.mm` cũ | Đặt `__lr` = park stub `b .`, **kết luận thành công bằng cách chờ IPC socket của payload xuất hiện**, rồi `thread_terminate` |
| A6 | **Không telemetry nào.** Payload không ghi bộ đếm nào; UI hiện 0 dù hook có chạy | `heldPacketsCount` không ai tăng | Payload gửi `AetherIpcTelemetry` mỗi 250 ms; UI hiện TCP/UDP RX-TX, held, dropped, hookMask |
| A7 | **Payload không tự gate.** ellekit nhét vào mọi UIKit process, remote dlopen có thể rơi vào bất cứ app nào | constructor rebind vô điều kiện | `shouldIntercept()` bắt buộc có config từ app **và** `pid` hoặc `bundle-hash` khớp chính process đó |

### Cách dùng (đường chính: remote dlopen, không cần respring)

1. Bấm **"Chọn PID"** → chọn app đích.
2. Bấm **"Inject payload vào PID"**. Dòng trạng thái sẽ nói rõ:
   - `đã inject` → payload đã arm, kết nối IPC thành công.
   - `task_for_pid denied` → thiếu root hoặc target chưa `CS_DEBUGGED` (PPL).
   - `dlopen ran but payload did not arm` → xem `tmp/aether_net_<pid>.log` **bên trong container của app đích**.
3. Bật/tắt FakeLag hoặc đổi Mode → config được đẩy xuống payload ngay, không cần inject lại.

Nếu `remote dlopen` bị PPL chặn (không có Dopamine), daemon vẫn có đường thứ hai:
copy payload vào `TweakInject` của roothide để **ellekit** tự inject. Filter plist
giờ ghi thêm **bundle id của app đích** (trước đây chỉ có `com.apple.UIKit`,
tức chỉ SpringBoard — payload không bao giờ vào app bạn chọn).

## B. Floating Button: vì sao bấm "Create" mà không thấy

| # | Nguyên nhân | Đã sửa |
|---|---|---|
| B1 | `interactiveFloatingButton` được đọc **trước** khi `viewDidLoad` tạo nút → luôn `nil` → `HUDMainWindow.hitTest:` trả nil mọi điểm → nút nhìn thấy mà **không bấm được** | `[_rootVC loadViewIfNeeded]` trước khi gán |
| B2 | Thiếu entitlement `com.apple.QuartzCore.secure-mode` trong khi `HUDMainWindow` **ép** secure context | Thêm vào CI + file committed |
| B3 | Thiếu `com.apple.private.hid.manager.client` → `BKSHIDEventRegisterEventCallback` không gắn được | Thêm vào CI + file committed |
| B4 | Daemon được spawn bằng `posix_spawn` thuần, không phải job App của launchd → iOS 15+ không cấp display scene cho `makeKeyAndVisible` | `posix_spawnattr_setapptype_np(..., POSIX_SPAWN_PROCESS_TYPE_UIAPP)` |
| B5 | Heartbeat đóng từ **step1**, tức trước khi có window → app báo "thành công" và watchdog không bao giờ cứu daemon chết sớm | `hudVisible` chỉ bật **sau** `registerWindowWithContextID:`; `HybridHUDIsRunning` yêu cầu cả nó. Tách `HybridHUDDaemonAlive` (để kill daemon cũ) khỏi `HybridHUDIsRunning` (để báo UI) |
| B6 | pid file do root ghi mode 0600 → app uid 501 không đọc được, kiểm tra sống chết chỉ còn dựa heartbeat | `chmod 0666` sau khi ghi |
| B7 | Installer payload chạy **giữa lúc UIKit bootstrap** và fork/exec → có thể abort daemon (trước đây vô hại vì dylib không tồn tại; **nay sẽ là blocker thật**) | Dời sang sau `step13`, khi UIKit đã lên |

## C. Test

`python3 scripts/simulate_test.py` → **309 PASS / 0 FAIL**.

Harness trước đây **không chạy được trên máy khác** (33 đường dẫn hardcode
`/home/z/my-project/...`), nên "131 test PASS" trong README cũ là kết quả
không kiểm chứng được. Đã đổi sang đường dẫn tương đối + thêm nhóm test
`[4.0a..4.0j]` chặn đúng 7 lỗi ở A1–A7 và 7 lỗi ở B1–B7.

## D. Giới hạn còn lại (nói thẳng)

- **D1 — Payload chưa được ký.** CI chỉ ký binary chính và `.appex`. Dylib
  unsigned bị dyld/AMFI từ chối, và library validation của app đích cũng từ
  chối dù ad-hoc. Đường ellekit né được việc này (roothide tự trust-cache trong
  `TweakInject`); đường `dlopen` từ xa cần `ldid -S` trong build phase hoặc
  Dopamine `trust_file`. Chưa làm vì cần bản ký đúng của thiết bị.
- **D2 — Không thấy traffic của libnetwork.** Hook ở tầng BSD socket API: app
  tự gọi `send`/`recv` thì bắt được, nhưng traffic NSURLSession/CFNetwork được
  implement **bên trong** libnetwork (shared cache, read-only) nên không đi qua
  stub của app đích. Tầng đó chỉ bắt được qua `PacketTunnelProvider`.
- **D3 — Chưa dùng LaunchDaemon.** `posix_spawnattr_setapptype_np` là cách rẻ
  nhất; nếu vẫn không hiện nút trên iOS 16/17 thì bước nâng cấp là cài
  `/Library/LaunchDaemons/*.plist` với `POSIXSpawnType=App` +
  `_AdditionalProperties.RunningBoard.{Managed,Reported}=false` + `KeepAlive`
  như TrollSpeed, điều khiển bằng `launchctl` thay vì spawn trực tiếp.
- **D4 — `HybridFakeLagV2.xcodeproj` không được CI build.** Nó là bản song song
  của cùng kiến trúc; sửa lớn chỉ áp cho `PacketBlocker` (target thật sự phát
  hành), vài fix cơ bản đã mirror sang bản twin.


---

# FIX 4.1 — CI THỰC SỰ BUILD ĐƯỢC (7 lỗi, mỗi lỗi 1 nguyên nhân)

`PacketBlocker.xcodeproj` trước đây **build xanh nhưng nhét ra một `.app` không
có payload** — và nhiều lần build hỏng vẫn báo xanh. Danh sách lỗi thật, theo
đúng thứ tự gặp:

| # | Triệu chứng | Nguyên nhân |
|---|---|---|
| 1 | `Build input file cannot be found: .../PayloadManager.swift` | `PBXFileReference` không nằm trong `PBXGroup` nào → Xcode resolve `sourceTree = "<group>"` so với **thư mục project**, không phải group chứa nó |
| 2 | `use of undeclared identifier 'mach_vm_allocate'` | `<mach/mach.h>` không khai báo họ `mach_vm_*` |
| 3 | `mach/mach_vm.h:1: #error mach_vm.h unsupported` | Apple **cấm** header đó trên iOS → phải lấy prototype từ `PrivateSystemSPI.h` |
| 4 | `no matching function for call to 'thread_create_running'` | `thread_state_t` trên iOS SDK **đã là con trỏ** (`integer_t *`); `(thread_state_t *)&st` dư một cấp |
| 5 | `interface type cannot be statically allocated` / `extraneous ']'` | Thêm `bundleLine` làm mất dấu `[` mở đầu `[NSString stringWithFormat:` |
| 6 | `expected ';' after top level declarator` (mọi `gX{0}`) | Script build `.mm` **không có `-std=`** → mặc định Objective-C++ của Xcode 15 là `gnu++98`, không có `std::atomic` |
| 7 | `invalid argument '-std=gnu++17' not allowed with 'C'` | Một lệnh clang gộp cả `fishhook.c` (C) lẫn `.mm` (ObjC++) |
| 8 | `': command not found'` cho `-dynamiclib` | Chú thích `# ` dính vào chính dòng lệnh `xcrun`, biến nó thành comment |
| 9 | `unable to open output file '/libNetHookPayload-fishhook.o': Read-only file system` | `$BUILT_TEMP_DIR` rỗng trong môi trường phase |
| 10 | `Undefined symbols: std::length_error / std::logic_error` | Gọi driver C `clang` — driver này **không link libc++**, còn payload dùng `std::vector`/`std::deque` |

Ngoài ra: `xcodebuild ... | tee build.log` **nuốt mất exit code** và lỗi script
phase không in ra chữ `error:` — nên build hỏng vẫn báo nút xanh. Nay đã bật
`set -o pipefail`, in diagnostics khi fail, và **đòi marker `** BUILD SUCCEEDED **`**
trong `build.log`.

### Xác minh artifact (không chỉ "nút xanh")

Lấy IPA từ artifact và kiểm tra trực tiếp:

- `Payload/PacketBlocker.app/libNetHookPayload.dylib` — 91.896 bytes,
  Mach-O `MH_DYLIB`, `cputype = 16777228` (arm64), `install_name =
  /usr/lib/libNetHookPayload.dylib`
- `entitlements.plist` — 29 keys, gồm `com.apple.QuartzCore.secure-mode` và
  `com.apple.private.hid.manager.client`

Mỗi lỗi trên đã kèm một test trong `scripts/simulate_test.py` (giờ **332 test**)
để không tái phát: resolve ngược `file -> group -> mainGroup`, `sh -n` trên
shellScript của build phase, chặn lệnh bị `#` nuốt, chặn CI mất `pipefail`.
