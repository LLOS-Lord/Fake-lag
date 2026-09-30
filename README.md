# HybridFakeLag V2 - TrollNetInterceptor + Fake-lag + Floating Button + Logs + Config

Bản mix hoàn chỉnh: floating button như TrollNetInterceptor, log all action, tuỳ chỉnh config chặn.

## Tính năng

- Floating Button toàn hệ thống (windowLevel 10000010, SBSAccessibilityWindowHostingController, BKSHIDEvent)
- VPN PacketTunnelProvider FIXED không bị iOS kill (bounded queue 512, single timer, không drop SYN)
- Per-PID filtering via App Group socket dump
- Log all actions vào App Group + Documents
- Config: direction, proto, mode (hold/drop/delay), latency, jitter, bandwidth, ratio, preset, floating size/opacity/edge snap/haptics

## Cấu trúc

- `PacketBlocker/` - Main app SwiftUI (Home, Settings, Logs) + floating button manager
- `PacketBlockerExtension/` - Fixed PacketTunnelProvider
- `HybridFakeLagV2/` - Full source với HUD ObjC++ (TrollNetInterceptor original) + Core + Payload

## Build

GitHub Actions tự động build IPA TrollStore với ldid.

## Credits

- opa334/TrollStore
- Lessica/TrollSpeed
- facebook/fishhook
- LLOS-Lord/Fake-lag
- AetherNet
