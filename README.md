# HybridFakeLag V2 - TrollNetInterceptor + Fake-lag + Floating Button + Logs + Config

Bản mix hoàn chỉnh: floating button như TrollNetInterceptor, log all action, tuỳ chỉnh config chặn.

> **BẢN FIX 3 BUG (build 3.7.1)** — chi tiết ở mục "Fix log" bên dưới.
>
> **BẢN FIX 3.8.0 — GỘP 2 HƯỚNG ĐI THÀNH MỘT KIẾN TRÚC HYBRID CHUẨN** — sửa lại toàn
> bộ bản mix HybridFakeLagV2 (VPN extension + inject PID + floating HUD) đã bị
> "tựa lưa": extension của bản mix vẫn là engine loop-back cũ, Swift không gọi
> được lớp ObjC, payload inject đọc nhầm path config. Chi tiết ở mục "Fix 3.8.0".
> Kèm **test giả định** (`scripts/simulate_test.py` — 131 test, tất cả PASS).

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

Chạy: `python3 scripts/simulate_test.py` (exit 0 = OK hết).

## Credits

- opa334/TrollStore
- Lessica/TrollSpeed
- facebook/fishhook
- LLOS-Lord/Fake-lag
- AetherNet
