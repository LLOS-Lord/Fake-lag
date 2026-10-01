import SwiftUI

/// Drives the injected payload: injects libNetHookPayload.dylib into the chosen
/// PID, connects the IPC control channel and surfaces what the payload actually
/// reports. The point of this type is that it never claims success the payload
/// did not confirm — hookMask, status and the counters come straight from the
/// process we injected into.
@MainActor
class PayloadManager: ObservableObject {
    static let shared = PayloadManager()

    @Published var status: String = "chưa inject"
    @Published var detail: String = ""
    @Published var isAttached = false

    @Published var tcpRX: UInt64 = 0
    @Published var udpRX: UInt64 = 0
    @Published var tcpTX: UInt64 = 0
    @Published var udpTX: UInt64 = 0
    @Published var held: UInt64 = 0
    @Published var dropped: UInt64 = 0
    @Published var hookMask: UInt32 = 0

    private var timer: Timer?
    private var targetPID: Int32 = 0
    private var bundleID: String = ""

    private static func modeCode(_ s: String) -> Int32 {
        switch s { case "drop": return 1; case "delay": return 2; default: return 0 }
    }
    private static func dirCode(_ s: String) -> Int32 {
        switch s { case "download": return 1; case "upload": return 2; default: return 0 }
    }
    private static func protoCode(_ s: String) -> Int32 {
        switch s { case "udp": return 1; case "tcp": return 2; default: return 0 }
    }

    /// Inject (if needed), attach, and start streaming config + telemetry.
    func attach(to process: ProcessInfoModel?, config: VPNManager) {
        stopTimer()
        guard let p = process else {
            status = "chưa chọn PID"
            detail = ""
            isAttached = false
            return
        }

        targetPID = p.pid
        bundleID = p.bundleID
        status = "đang inject…"
        detail = ""

        // Publish the target so the HUD daemon's ellekit Filter names the right
        // bundle (otherwise the payload only ever loads into SpringBoard).
        HybridPayloadSetTarget(p.pid, p.bundleID)

        var err = [CChar](repeating: 0, count: 512)
        let rc = HybridPayloadInject(p.pid, &err, 512)
        let errText = String(cString: err)

        guard rc == 1 else {
            status = "inject thất bại"
            detail = String(cString: HybridInjectResultString(rc))
            if !errText.isEmpty { detail += " — " + errText }
            isAttached = false
            return
        }
        status = "đã inject"
        detail = errText

        guard HybridPayloadAttach(p.pid) == 1 else {
            detail += " — không kết nối được IPC socket"
            isAttached = false
            return
        }
        isAttached = true
        push(config: config)
        startTimer()
    }

    /// Re-send the current config without re-injecting (floating button, mode
    /// picker, Settings changes).
    func push(config: VPNManager) {
        guard HybridPayloadIsAttached() == 1 else { return }
        HybridPayloadSendConfig(config.isBlocking ? 1 : 0,
                               Int32(targetPID),
                               bundleID,
                               PayloadManager.dirCode(config.direction),
                               PayloadManager.protoCode(config.protoFilter),
                               PayloadManager.modeCode(config.mode),
                               Int32(config.captureRatio),
                               Int32(config.latencyMs),
                               Int32(config.jitterMs),
                               12)
    }

    func detach() {
        stopTimer()
        HybridPayloadDetach()
        isAttached = false
        status = "đã detach"
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            var t = AetherIpcTelemetry()
            guard HybridPayloadPoll(&t) == 1 else { return }
            self.tcpRX = t.tcpRX; self.udpRX = t.udpRX
            self.tcpTX = t.tcpTX; self.udpTX = t.udpTX
            self.held = t.held;  self.dropped = t.dropped
            self.hookMask = t.hookMask
            switch t.status {
            case 1: self.status = "payload đang chờ app kết nối"
            case 2: self.status = "đang bắt gói tin (hook \(t.hookMask)/\(0x3F))"
            case 3: self.status = "LỖI: process không có hook engine — 0 hook"
            case 4: self.status = "payload chạy nhưng không phải PID đích"
            default: self.status = "payload status \(t.status)"
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    var summary: String {
        String(format: "TCP %llu/%llu  UDP %llu/%llu  held %llu  drop %llu  hooks 0x%02X",
               tcpRX, tcpTX, udpRX, udpTX, held, dropped, hookMask)
    }
}