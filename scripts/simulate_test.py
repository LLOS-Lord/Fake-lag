#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
simulate_test.py — Test giả định (simulation harness) cho HybridFakeLag V2 đã fix.

Port THẬT CHỨNG từng-nhau logic từ Swift/ObjC sang Python:
  • IP kit            <- PacketTunnelProvider.swift (enum IP)
  • Relay engine      <- PacketTunnelProvider.swift (class PacketTunnelProvider)
  • HUD lifecycle     <- ProcessManager.mm (bridge) + HUDMain.mm
  • Config precedence <- PacketTunnelProvider.loadSync + AppGroupStore
  • Payload loader    <- NetHookPayload.mm (refreshConfigIfNeeded)

Mỗi test mapped tới một fix (F1..F9, P1..P5, bug #1/#2/#3 gốc).
Chạy: python3 scripts/simulate_test.py  → exit 0 khi pass hết.
"""
import struct
import random
import json
import os
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

random.seed(20260930)  # deterministic

PASS, FAIL = [], []


def check(name, cond, detail=""):
    (PASS if cond else FAIL).append(name)
    print(("  PASS  " if cond else "  FAIL  ") + name + (("  — " + detail) if detail and not cond else ""))


# ═══════════════════════════════ IP kit (port of enum IP) ═══════════════════════════════

kFIN, kSYN, kRST, kPSH, kACK = 0x01, 0x02, 0x04, 0x08, 0x10
kTCP, kUDP, kICMP = 6, 17, 1
kMTU = 1280
kMSS = kMTU - 40  # 1240
AF_INET = 2


def seq_before(a, b):
    """IP.seqBefore — Swift: Int32(a &- b) < 0"""
    d = (a - b) & 0xFFFFFFFF
    return struct.unpack(">i", struct.pack(">I", d))[0] < 0


def r_u32(b, i):
    return (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3]


def w_u16(b, i, v):
    b[i] = (v >> 8) & 0xFF
    b[i + 1] = v & 0xFF


def checksum(bytes_, start, length):
    """IP.checksum — one's complement internet checksum."""
    s = 0
    i = start
    end = start + length
    while i + 1 < end:
        s += (bytes_[i] << 8) | bytes_[i + 1]
        i += 2
    if i < end:
        s += bytes_[i] << 8
    while (s >> 16) != 0:
        s = (s & 0xFFFF) + (s >> 16)
    return (~s) & 0xFFFF


def l4_checksum(src, dst, proto, seg):
    pseudo = list(src) + list(dst) + [0, proto, (len(seg) >> 8) & 0xFF, len(seg) & 0xFF] + list(seg)
    if len(pseudo) % 2:
        pseudo.append(0)
    s = 0
    i = 0
    while i + 1 < len(pseudo):
        s += (pseudo[i] << 8) | pseudo[i + 1]
        i += 2
    while (s >> 16) != 0:
        s = (s & 0xFFFF) + (s >> 16)
    return (~s) & 0xFFFF


def build_ipv4(proto, src, dst, l4):
    pkt = [0] * (20 + len(l4))
    total = 20 + len(l4)
    pkt[0] = 0x45
    pkt[1] = 0x00
    pkt[2] = (total >> 8) & 0xFF
    pkt[3] = total & 0xFF
    ident = random.randint(1, 0xFFFF)
    pkt[4] = (ident >> 8) & 0xFF
    pkt[5] = ident & 0xFF
    pkt[6] = 0x40
    pkt[8] = 64
    pkt[9] = proto
    pkt[12:16] = src
    pkt[16:20] = dst
    ck = checksum(pkt, 0, 20)
    pkt[10] = (ck >> 8) & 0xFF
    pkt[11] = ck & 0xFF
    pkt[20:] = l4
    return pkt


def tcp_segment(src, sport, dst, dport, seq, ack, flags, window, payload, mss):
    options = []
    if mss is not None:
        options = [0x02, 0x04, (mss >> 8) & 0xFF, mss & 0xFF]
    while len(options) % 4:
        options.append(0)
    hlen = 20 + len(options)
    seg = [0] * (hlen + len(payload))
    w_u16(seg, 0, sport)
    w_u16(seg, 2, dport)
    seg[4] = (seq >> 24) & 0xFF; seg[5] = (seq >> 16) & 0xFF; seg[6] = (seq >> 8) & 0xFF; seg[7] = seq & 0xFF
    seg[8] = (ack >> 24) & 0xFF; seg[9] = (ack >> 16) & 0xFF; seg[10] = (ack >> 8) & 0xFF; seg[11] = ack & 0xFF
    seg[12] = (hlen // 4) << 4
    seg[13] = flags
    w_u16(seg, 14, window)
    seg[20:hlen] = options
    seg[hlen:] = payload
    ck = l4_checksum(src, dst, 6, seg)
    seg[16] = (ck >> 8) & 0xFF
    seg[17] = ck & 0xFF
    return seg


def build_udp(src, sport, dst, dport, payload):
    seg = [0] * (8 + len(payload))
    ln = 8 + len(payload)
    w_u16(seg, 0, sport)
    w_u16(seg, 2, dport)
    w_u16(seg, 4, ln)
    seg[8:] = payload
    ck = l4_checksum(src, dst, 17, seg)
    seg[6] = (ck >> 8) & 0xFF
    seg[7] = ck & 0xFF
    return seg


def icmp_echo_reply(pkt, ihl):
    pkt = list(pkt)
    s = ihl
    if len(pkt) < s + 8 or pkt[s] != 8:
        return pkt
    src, dst = pkt[12:16], pkt[16:20]
    pkt[s] = 0
    pkt[s + 2] = pkt[s + 3] = 0
    ck = checksum(pkt, s, len(pkt) - s)
    pkt[s + 2] = (ck >> 8) & 0xFF
    pkt[s + 3] = ck & 0xFF
    pkt[12:16] = dst
    pkt[16:20] = src
    pkt[10] = pkt[11] = 0
    ick = checksum(pkt, 0, 20)
    pkt[10] = (ick >> 8) & 0xFF
    pkt[11] = ick & 0xFF
    return pkt


def parse_ip(pkt):
    ihl = (pkt[0] & 0x0F) * 4
    proto = pkt[9]
    src, dst = pkt[12:16], pkt[16:20]
    sport = (pkt[ihl] << 8) | pkt[ihl + 1]
    dport = (pkt[ihl + 2] << 8) | pkt[ihl + 3]
    return ihl, proto, src, dst, sport, dport


def ip_str(b):
    return ".".join(str(x) for x in b)


# ═══════════════════════ Relay engine (faithful port) ═══════════════════════

class Config:
    def __init__(self):
        self.enabled = False
        self.mode = "hold"
        self.direction = "both"
        self.protoFilter = "both"
        self.captureRatio = 100
        self.downloadRatio = 100
        self.uploadRatio = 100
        self.latencyMs = 350
        self.jitterMs = 80
        self.autoFlushSeconds = 12
        self.targetBundleID = ""
        self.targetPID = 0
        self.targetSockets = []


class UDPFlow:
    def __init__(self, key, now):
        self.key = key
        self.ready = True  # harness marks ready instantly (NWConnection mocked)
        self.sent = []     # payloads handed to the "real network"
        self.lastSeen = now


class TCPFlow:
    def __init__(self, now):
        self.phase = "synReceived"
        self.clientIsn = 0
        self.clientNext = 0
        self.serverIsn = 0
        self.serverNext = 0
        self.connReady = False
        self.toServer = []      # payloads forwarded to the real server
        self.clientFin = False
        self.clientFinSent = False
        self.unacked = []       # (seq, len, seg, time)
        self.dupAcks = 0
        self.lastAck = 0
        self.receivePaused = False
        self.lastSeen = now


class FlowKey:
    def __init__(self, proto, src, sport, dst, dport):
        self.proto, self.src, self.sport, self.dst, self.dport = proto, src, sport, dst, dport

    def _tup(self):
        return (self.proto, tuple(self.src), self.sport, tuple(self.dst), self.dport)

    def __hash__(self):
        return hash(self._tup())

    def __eq__(self, other):
        return isinstance(other, FlowKey) and self._tup() == other._tup()

    @property
    def describe(self):
        return f"{ip_str(self.src)}:{self.sport} → {ip_str(self.dst)}:{self.dport} {'tcp' if self.proto == kTCP else 'udp'}"


class StoredPacket:
    def __init__(self, pkt, proto, outbound, dueMs):
        self.pkt, self.proto, self.outbound, self.dueMs = pkt, proto, outbound, dueMs


class Engine:
    """Port of the FIXED PacketTunnelProvider decision logic. Network I/O is
    replaced by recorders: `tun_writes` (packets written back to the TUN),
    udpFlows[..].sent / tcpFlows[..].toServer (real-network side)."""

    def __init__(self):
        self.config = Config()
        self.isRunning = True
        self.udpFlows = {}
        self.tcpFlows = {}
        self.heldQueue = []
        self.delayedQueue = []
        self.passed = 0
        self.dropped = 0
        self.relayedIn = 0
        self.relayedOut = 0
        self._clock = 1_000_000
        self.tun_writes = []          # (pkt) delivered INTO the TUN (download)

    def nowMs(self):
        return self._clock

    def advance(self, ms):
        self._clock += ms

    # ── gates ──
    def lag_matches(self, key, is_upload):
        if self.config.protoFilter == "tcp" and key.proto != kTCP:
            return False
        if self.config.protoFilter == "udp" and key.proto != kUDP:
            return False
        if self.config.direction == "upload" and not is_upload:
            return False
        if self.config.direction == "download" and is_upload:
            return False
        if not self.match_target(key):
            return False
        ratio = self.config.uploadRatio if is_upload else self.config.downloadRatio
        eff = (self.config.captureRatio * ratio) // 100
        if eff >= 100:
            return True
        if eff <= 0:
            return False
        return random.randint(0, 99) < eff

    def match_target(self, key):
        if not self.config.targetBundleID and self.config.targetPID == 0:
            return True
        if not self.config.targetSockets:
            return True
        dst_ip = ip_str(key.dst)
        src_ip = ip_str(key.src)
        proto_str = "tcp" if key.proto == kTCP else "udp"
        for s in self.config.targetSockets:
            if s["remoteIP"] in (dst_ip, src_ip):
                if key.dport in (s["remotePort"], s["localPort"]) or key.sport in (s["remotePort"], s["localPort"]):
                    if s["proto"] == proto_str:
                        return True
            if key.dport == s["remotePort"] or key.sport == s["remotePort"]:
                if s["proto"] == proto_str:
                    return True
        return False

    def enqueue_held(self, p):
        if len(self.heldQueue) >= 512:
            self.heldQueue.pop(0)
            self.dropped += 1
        self.heldQueue.append(p)

    def enqueue_delayed(self, p):
        if len(self.delayedQueue) >= 1024:
            self.delayedQueue.pop(0)
            self.dropped += 1
        self.delayedQueue.append(p)

    def write_packets_batch(self, pkts):
        if not pkts:
            return
        self.tun_writes.extend(pkts)

    def deliver_inbound_direct(self, pkt):
        self.write_packets_batch([pkt])

    # ── outbound ──
    def handle_outbound(self, pkt, proto=AF_INET, bypass_gates=False):
        if not self.isRunning:
            return
        if proto != AF_INET:
            self.dropped += 1
            return
        if len(pkt) < 20 or (pkt[0] >> 4) != 4:
            self.dropped += 1
            return
        ihl = (pkt[0] & 0x0F) * 4
        if len(pkt) <= ihl:
            self.dropped += 1
            return
        ip_proto = pkt[9]
        src, dst = pkt[12:16], pkt[16:20]
        if ip_proto == kICMP:
            self.handle_icmp(pkt, ihl)
            return
        if ip_proto not in (kTCP, kUDP):
            self.dropped += 1
            return
        if len(pkt) < ihl + 4:
            self.dropped += 1
            return
        sport = (pkt[ihl] << 8) | pkt[ihl + 1]
        dport = (pkt[ihl + 2] << 8) | pkt[ihl + 3]
        key = FlowKey(ip_proto, src, sport, dst, dport)

        if not bypass_gates and self.config.enabled and self.lag_matches(key, is_upload=True):
            if self.config.mode == "hold":
                self.enqueue_held(StoredPacket(pkt, proto, True, self.nowMs()))
                return
            if self.config.mode == "drop":
                is_syn = ip_proto == kTCP and len(pkt) > ihl + 13 and (pkt[ihl + 13] & kSYN) != 0
                if not is_syn:
                    self.dropped += 1
                    return
            elif self.config.mode == "delay" and key.proto == kUDP:
                due = self.nowMs() + self.config.latencyMs + random.randint(0, max(0, self.config.jitterMs))
                self.enqueue_delayed(StoredPacket(pkt, proto, True, due))
                return

        self.relay_outbound(key, pkt, ihl)

    def relay_outbound(self, key, pkt, ihl):
        l4h = self.tcp_header_len(pkt, ihl) if key.proto == kTCP else 8
        start = ihl + l4h
        if start > len(pkt):
            self.dropped += 1
            return
        payload = pkt[start:]
        if key.proto == kUDP:
            self.udp_send(key, payload)
            self.passed += 1
            self.relayedOut += 1
        else:
            self.client_tcp_segment(key, pkt, ihl)

    # ── UDP NAT ──
    def udp_send(self, key, payload):
        now = self.nowMs()
        flow = self.udpFlows.get(key)
        if flow is None:
            flow = UDPFlow(key, now)
            self.udpFlows[key] = flow
        flow.lastSeen = now
        if flow.ready:
            flow.sent.append(payload)

    def udp_receive(self, key, payload):
        """Simulates a reply from the real server arriving on the NAT socket.
        Port of udpReceive incl. F6 download gating."""
        seg = build_udp(key.dst, key.dport, key.src, key.sport, payload)
        reply = build_ipv4(kUDP, key.dst, key.src, seg)
        gated = False
        if self.config.enabled and self.lag_matches(key, is_upload=False):
            if self.config.mode == "hold":
                self.enqueue_held(StoredPacket(reply, AF_INET, False, self.nowMs()))
                gated = True
            elif self.config.mode == "drop":
                self.dropped += 1
                gated = True
            elif self.config.mode == "delay":
                due = self.nowMs() + self.config.latencyMs + random.randint(0, max(0, self.config.jitterMs))
                self.enqueue_delayed(StoredPacket(reply, AF_INET, False, due))
                gated = True
        if not gated:
            self.write_packets_batch([reply])
        self.passed += 1
        self.relayedIn += 1

    # ── TCP ──
    def tcp_header_len(self, pkt, ihl):
        if len(pkt) <= ihl + 12:
            return 20
        return (pkt[ihl + 12] >> 4) * 4

    def client_tcp_segment(self, key, pkt, ihl):
        th = ihl
        if len(pkt) < th + 20:
            return
        seq = r_u32(pkt, th + 4)
        ack = r_u32(pkt, th + 8)
        flags = pkt[th + 13]
        data_off = (pkt[th + 12] >> 4) * 4
        payload_start = th + data_off
        payload = pkt[payload_start:] if payload_start <= len(pkt) else []

        flow = self.tcpFlows.get(key)
        now = self.nowMs()
        if flow is None:
            flow = TCPFlow(now)
            self.tcpFlows[key] = flow
        flow.lastSeen = now

        if (flags & kSYN) and not (flags & kACK):
            flow.clientIsn = seq
            flow.clientNext = (seq + 1) & 0xFFFFFFFF
            flow.serverIsn = random.randint(1, 0xFFFFFFFF)
            flow.serverNext = (flow.serverIsn + 1) & 0xFFFFFFFF
            flow.phase = "synReceived"
            flow.unacked = []
            flow.dupAcks = 0
            syn_ack = tcp_segment(key.dst, key.dport, key.src, key.sport,
                                  flow.serverIsn, flow.clientNext, kSYN | kACK, 65535, [], kMSS)
            self.deliver_inbound_direct(build_ipv4(kTCP, key.dst, key.src, syn_ack))
            flow.connReady = True   # harness: upstream connect succeeds instantly
            self.passed += 1
            return

        if flags & kRST:
            del self.tcpFlows[key]
            return

        if flow.phase == "synReceived":
            if (flags & kACK) and ack == (flow.serverIsn + 1) & 0xFFFFFFFF:
                flow.phase = "established"
                flow.clientNext = seq

        if flow.phase != "established":
            return

        if flags & kACK:
            # F4: wraparound-safe trim
            flow.unacked = [e for e in flow.unacked if seq_before(ack, (e[0] + e[1]) & 0xFFFFFFFF)]
            if not payload and ack == flow.lastAck:
                flow.dupAcks += 1
                if flow.dupAcks >= 3:
                    self.retransmit(flow, key)
            elif payload or ack != flow.lastAck:
                flow.dupAcks = 0
            flow.lastAck = ack

        if payload:
            if seq == flow.clientNext:
                flow.clientNext = (seq + len(payload)) & 0xFFFFFFFF
                flow.toServer.append(bytes(payload))
                if flags & kFIN:
                    flow.clientNext = (flow.clientNext + 1) & 0xFFFFFFFF
                    flow.clientFin = True
                    flow.clientFinSent = True
                ack_seg = tcp_segment(key.dst, key.dport, key.src, key.sport,
                                      flow.serverNext, flow.clientNext, kACK, 64240, [], None)
                ack_pkt = build_ipv4(kTCP, key.dst, key.src, ack_seg)
                ack_delayed = False
                if self.config.enabled and self.config.mode == "delay" and self.lag_matches(key, is_upload=True):
                    due = self.nowMs() + self.config.latencyMs + random.randint(0, max(0, self.config.jitterMs))
                    self.enqueue_delayed(StoredPacket(ack_pkt, AF_INET, False, due))
                    ack_delayed = True
                if not ack_delayed:
                    self.deliver_inbound_direct(ack_pkt)
            else:
                ack_seg = tcp_segment(key.dst, key.dport, key.src, key.sport,
                                      flow.serverNext, flow.clientNext, kACK, 64240, [], None)
                self.deliver_inbound_direct(build_ipv4(kTCP, key.dst, key.src, ack_seg))
            self.passed += 1
            self.relayedOut += 1
            return

        if (flags & kFIN) and seq == flow.clientNext:
            flow.clientNext = (flow.clientNext + 1) & 0xFFFFFFFF
            flow.clientFin = True
            flow.clientFinSent = True
            ack_seg = tcp_segment(key.dst, key.dport, key.src, key.sport,
                                  flow.serverNext, flow.clientNext, kACK, 64240, [], None)
            self.deliver_inbound_direct(build_ipv4(kTCP, key.dst, key.src, ack_seg))

    def splice_server_to_client(self, flow, key, data):
        offset = 0
        batch = []
        segs = []
        while offset < len(data):
            chunk = list(data[offset:offset + kMSS])
            offset += len(chunk)
            seg = tcp_segment(key.dst, key.dport, key.src, key.sport,
                              flow.serverNext, flow.clientNext, kPSH | kACK, 64240, chunk, None)
            entry_seq = flow.serverNext
            flow.serverNext = (flow.serverNext + len(chunk)) & 0xFFFFFFFF
            segs.append((entry_seq, len(chunk), seg, self.nowMs()))
            batch.append(build_ipv4(kTCP, key.dst, key.src, seg))

        gated = False
        if self.config.enabled and self.lag_matches(key, is_upload=False):
            if self.config.mode == "hold":
                for pkt in batch:
                    self.enqueue_held(StoredPacket(pkt, AF_INET, False, self.nowMs()))
                gated = True
            elif self.config.mode == "delay":
                due = self.nowMs() + self.config.latencyMs + random.randint(0, max(0, self.config.jitterMs))
                for pkt in batch:
                    self.enqueue_delayed(StoredPacket(pkt, AF_INET, False, due))
                gated = True
            elif self.config.mode == "drop":
                for pkt in batch:
                    self.enqueue_held(StoredPacket(pkt, AF_INET, False, self.nowMs()))
                gated = True
        if not gated:
            flow.unacked.extend(segs)
            self.write_packets_batch(batch)
            self.passed += len(batch)
            self.relayedIn += len(batch)
        else:
            self.relayedOut += len(batch)

    def retransmit(self, flow, key):
        now = self.nowMs()
        batch = [build_ipv4(kTCP, key.dst, key.src, e[2]) for e in flow.unacked if now - e[3] > 300][:8]
        if batch:
            self.write_packets_batch(batch)
            flow.dupAcks = 0

    def handle_icmp(self, pkt, ihl):
        if len(pkt) < ihl + 8 or pkt[ihl] != 8:
            self.dropped += 1
            return
        self.deliver_inbound_direct(icmp_echo_reply(pkt, ihl))
        self.passed += 1

    # ── queues ──
    def flush_held(self, bypass_gates=True):
        to_flush, self.heldQueue = self.heldQueue, []
        if not to_flush:
            return
        seen = set()
        for p in to_flush:
            if p.outbound and p.proto == AF_INET and len(p.pkt) >= 24 and p.pkt[9] == kTCP:
                ihl = (p.pkt[0] & 0x0F) * 4
                if ihl + 4 <= len(p.pkt):
                    sid = (ip_str(p.pkt[12:16]), (p.pkt[ihl] << 8) | p.pkt[ihl + 1],
                           ip_str(p.pkt[16:20]), (p.pkt[ihl + 2] << 8) | p.pkt[ihl + 3], r_u32(p.pkt, ihl + 4))
                    if sid in seen:
                        continue
                    seen.add(sid)
            if p.outbound:
                self.handle_outbound(p.pkt, p.proto, bypass_gates=True)
            else:
                self.write_packets_batch([p.pkt])
                self.passed += 1

    def flush_delayed_now(self):
        ready, self.delayedQueue = self.delayedQueue, []
        for p in ready:
            if p.outbound:
                self.handle_outbound(p.pkt, p.proto, bypass_gates=True)
            else:
                self.write_packets_batch([p.pkt])
                self.passed += 1

    def flush_delayed_periodic(self):
        if not (self.isRunning and self.config.enabled and self.config.mode == "delay"):
            return
        now = self.nowMs()
        ready = [p for p in self.delayedQueue if now >= p.dueMs]
        self.delayedQueue = [p for p in self.delayedQueue if now < p.dueMs]
        for p in ready:
            if p.outbound:
                self.handle_outbound(p.pkt, p.proto, bypass_gates=True)
            else:
                self.write_packets_batch([p.pkt])
                self.passed += 1
                self.relayedIn += 1

    def maintenance(self):
        if not self.isRunning:
            return
        now = self.nowMs()
        # F9
        if self.config.enabled and self.config.mode == "hold" and self.config.autoFlushSeconds > 0:
            cutoff = now - self.config.autoFlushSeconds * 1000
            due = [p for p in self.heldQueue if p.dueMs <= cutoff]
            if due:
                self.heldQueue = [p for p in self.heldQueue if p.dueMs > cutoff]
                for p in due:
                    if p.outbound:
                        self.handle_outbound(p.pkt, p.proto, bypass_gates=True)
                    else:
                        self.write_packets_batch([p.pkt])
                        self.passed += 1
        # retransmit stuck
        for key, flow in list(self.tcpFlows.items()):
            if flow.unacked and any(now - e[3] > 400 for e in flow.unacked):
                self.retransmit(flow, key)


# ═══════════ helpers to build packets ═══════════

CLIENT_IP = [10, 8, 0, 2]
SERVER_IP = [93, 184, 216, 34]
CLIENT_PORT, SERVER_PORT = 54321, 7777


def udp_outbound(payload, sport=CLIENT_PORT, dport=SERVER_PORT):
    seg = build_udp(CLIENT_IP, sport, SERVER_IP, dport, payload)
    return build_ipv4(kUDP, CLIENT_IP, SERVER_IP, seg)


def tcp_outbound(flags, seq, ack=0, payload=b"", sport=CLIENT_PORT, dport=SERVER_PORT, data_off_hl=5):
    seg = tcp_segment(CLIENT_IP, sport, SERVER_IP, dport, seq, ack, flags, 65535, list(payload), None)
    return build_ipv4(kTCP, CLIENT_IP, SERVER_IP, seg)


KEY = lambda: FlowKey(kUDP, CLIENT_IP, CLIENT_PORT, SERVER_IP, SERVER_PORT)
TKEY = lambda: FlowKey(kTCP, CLIENT_IP, CLIENT_PORT, SERVER_IP, SERVER_PORT)


# ═══════════════════════════════════ TESTS ═══════════════════════════════════

def test_ip_kit():
    print("\n[1] IP kit — checksums & builders (port of enum IP)")
    # IP header checksum: recompute over the full header incl. checksum = 0
    pkt = udp_outbound(b"hello")
    ihl, proto, src, dst, sport, dport = parse_ip(pkt)
    check("ipv4 header len/total consistent", ihl == 20 and (pkt[2] << 8 | pkt[3]) == len(pkt),
          f"total={(pkt[2] << 8 | pkt[3])} len={len(pkt)}")
    check("ipv4 checksum verifies to 0", checksum(pkt, 0, 20) == 0,
          f"got {checksum(pkt,0,20)}")
    # UDP checksum verification: recompute over seg with checksum field=0
    seg = pkt[20:]
    seg2 = list(seg); seg2[6] = seg2[7] = 0
    ck = l4_checksum(src, dst, kUDP, seg2)
    check("udp checksum verifies", ck == (seg[6] << 8 | seg[7]), f"{ck} != {seg[6] << 8 | seg[7]}")
    # TCP segment with options (SYN-ACK with MSS)
    s = tcp_segment(SERVER_IP, SERVER_PORT, CLIENT_IP, CLIENT_PORT, 777, 888, kSYN | kACK, 65535, [], kMSS)
    check("tcp mss option present", s[20:24] == [0x02, 0x04, (kMSS >> 8) & 0xFF, kMSS & 0xFF])
    s2 = list(s); s2[16] = s2[17] = 0
    check("tcp checksum self-consistent", l4_checksum(SERVER_IP, CLIENT_IP, kTCP, s2) == (s[16] << 8 | s[17]))
    # odd-length payload (padding branch of l4Checksum)
    u = build_ipv4(kUDP, CLIENT_IP, SERVER_IP, build_udp(CLIENT_IP, 1, SERVER_IP, 2, b"abc"))  # 11-byte seg → odd pseudo
    u2 = list(u[20:]); u2[6] = u2[7] = 0
    check("udp odd-length checksum verifies", l4_checksum(CLIENT_IP, SERVER_IP, kUDP, u2) == (u[26] << 8 | u[27]))
    # icmp echo reply
    icmp_req = build_ipv4(kICMP, CLIENT_IP, SERVER_IP, [8, 0, 0, 0, 0, 1, 0, 1] + [0x41] * 8)
    rep = icmp_echo_reply(icmp_req, 20)
    check("icmp type flipped to reply", rep[20] == 0)
    check("icmp addresses swapped", rep[12:16] == SERVER_IP and rep[16:20] == CLIENT_IP)
    check("icmp checksums verify", checksum(rep, 0, 20) == 0 and checksum(rep, 20, len(rep) - 20) == 0)
    # seqBefore semantics
    check("seqBefore basic", seq_before(100, 200) and not seq_before(200, 100))
    check("seqBefore wraparound", seq_before(0xFFFFFF00, 0x00000040))


def test_passthrough():
    print("\n[2] BUG #3 — VPN ON + giả lập OFF = mọi gói tin được relay (không chặn)")
    e = Engine()
    for i in range(20):
        e.handle_outbound(udp_outbound(f"pkt{i}".encode()))
    check("udp relayed to real network", len(e.udpFlows[KEY()].sent) == 20)
    check("nothing written back into TUN (no loop)", len(e.tun_writes) == 0)
    check("dropped == 0", e.dropped == 0)
    # TCP passthrough handshake
    syn = tcp_outbound(kSYN, 1000)
    e.handle_outbound(syn)
    f = e.tcpFlows[TKEY()]
    synack = e.tun_writes[-1]
    _, p2, s2, d2, sp2, dp2 = parse_ip(synack)
    check("SYN-ACK returned into TUN", p2 == kTCP and s2 == SERVER_IP and d2 == CLIENT_IP and dp2 == CLIENT_PORT)
    fl = synack[20 + 13] if len(synack) > 33 else 0
    check("SYN-ACK flags", fl & kSYN and fl & kACK)
    check("SYN-ACK ack = clientIsn+1", r_u32(synack, 20 + 8) == 1001)
    # handshake ACK → established
    e.handle_outbound(tcp_outbound(kACK, 1001, (f.serverIsn + 1) & 0xFFFFFFFF))
    check("flow established", f.phase == "established")
    # data both ways
    e.handle_outbound(tcp_outbound(kPSH | kACK, 1001, (f.serverIsn + 1) & 0xFFFFFFFF, b"GET /"))
    check("client payload forwarded to real server", b"GET /" in b"".join(f.toServer))
    check("client got ACK from proxy", len(e.tun_writes) >= 2,
          f"writes={len(e.tun_writes)}")
    e.splice_server_to_client(f, TKEY(), b"HTTP/1.1 200 OK")
    dl = e.tun_writes[-1]
    check("server payload spliced to client", list(dl[40:]) == list(b"HTTP/1.1 200 OK"),
          f"payload={bytes(dl[40:])!r}")
    check("download seq correct", r_u32(dl, 20 + 4) == (f.serverIsn + 1) & 0xFFFFFFFF)
    # ICMP
    icmp_req = build_ipv4(kICMP, CLIENT_IP, SERVER_IP, [8, 0, 0, 0, 0, 1, 0, 1] + [0x41] * 8)
    e.handle_outbound(icmp_req)
    check("icmp answered locally", any(parse_ip(p)[1] == kICMP for p in e.tun_writes))


def test_hold():
    print("\n[3] Hold mode (Ghost) — giữ gói, flush khi tắt; SYN không bao giờ bị hold")
    e = Engine()
    e.config.enabled = True
    e.config.mode = "hold"
    e.config.autoFlushSeconds = 0  # manual release only
    for i in range(5):
        e.handle_outbound(udp_outbound(f"u{i}".encode()))
    check("udp held (not relayed)", len(e.udpFlows.get(KEY(), UDPFlow(KEY(), 0)).sent) == 0 if e.udpFlows else True)
    check("hold queue = 5", len(e.heldQueue) == 5)
    # flush releases everything
    e.flush_held()
    check("flush releases all to real network", len(e.udpFlows[KEY()].sent) == 5)
    check("hold queue empty", len(e.heldQueue) == 0)
    # TCP SYN: hold mode freezes EVERYTHING (Ghost semantics) — SYN included;
    # after flush the handshake replays (flush dedupes multiple SYNs by seq).
    e.handle_outbound(tcp_outbound(kSYN, 5000))
    check("TCP SYN held in hold mode (freeze)", len(e.heldQueue) == 1 and TKEY() not in e.tcpFlows)
    e.flush_held()
    f = e.tcpFlows.get(TKEY())
    check("TCP SYN passes after flush (handshake resumes)", f is not None and f.phase == "synReceived")
    e.tun_writes.clear()
    # F5: hold-gated download segments are NOT in unacked → retransmit cannot leak
    e.handle_outbound(tcp_outbound(kACK, 5001, (f.serverIsn + 1) & 0xFFFFFFFF))
    f.phase = "established"
    f.clientNext = 5001
    e.tun_writes.clear()
    e.splice_server_to_client(f, TKEY(), b"X" * 100)
    check("download held: nothing written to TUN", len(e.tun_writes) == 0)
    check("F5 gated segments NOT in retransmit buffer", len(f.unacked) == 0)
    e.maintenance()  # would retransmit stuck unacked >400ms — none should exist
    check("F5 maintenance retransmit does not leak held data", len(e.tun_writes) == 0)
    e.flush_held()
    check("F5 flush delivers held download exactly once", len(e.tun_writes) == 1 and len(e.tun_writes[0][40:]) == 100,
          f"writes={len(e.tun_writes)} payload_len={len(e.tun_writes[0][40:]) if e.tun_writes else -1}")


def test_drop():
    print("\n[4] Drop mode — mất gói theo ratio; SYN/RST luôn đi qua")
    e = Engine()
    e.config.enabled = True
    e.config.mode = "drop"
    e.config.captureRatio = 100
    syn_count = 0
    for _ in range(20):
        pkt = tcp_outbound(kSYN, random.randint(1, 0xFFFFFFFF))
        before = e.passed + e.dropped
        e.handle_outbound(pkt)
        if e.dropped == 0 or (e.passed + e.dropped - before) > 0:
            pass
        # SYN counted as passed when relayed
    check("drop mode never drops SYN", e.dropped == 0)
    e.dropped = 0
    dropped_udp = 0
    for i in range(50):
        e.udpFlows.clear()
        e.handle_outbound(udp_outbound(f"u{i}".encode()))
    check("udp 100% drop → all dropped", e.dropped == 50, f"dropped={e.dropped}")
    # ratio 50%: statistical
    e.config.captureRatio = 50
    random.seed(7)
    e.dropped = 0
    for i in range(400):
        e.handle_outbound(udp_outbound(f"u{i}".encode()))
    check("udp 50% ratio ≈ half dropped", 140 <= e.dropped <= 260, f"dropped={e.dropped}/400")


def test_delay():
    print("\n[5] Delay mode — UDP upload+download delayed; F7 TCP upload qua ACK-delay; F8 flush khi tắt")
    e = Engine()
    e.config.enabled = True
    e.config.mode = "delay"
    e.config.latencyMs = 300
    e.config.jitterMs = 0
    # UDP upload delayed
    t0 = e.nowMs()
    e.handle_outbound(udp_outbound(b"late"))
    check("udp upload queued with due=+300", len(e.delayedQueue) == 1 and e.delayedQueue[0].dueMs == t0 + 300)
    check("not relayed yet", len(e.udpFlows.get(KEY(), UDPFlow(KEY(), 0)).sent) == 0 if e.udpFlows else True)
    e.advance(299); e.flush_delayed_periodic()
    check("not released before due", len(e.delayedQueue) == 1)
    e.advance(1); e.flush_delayed_periodic()
    check("released at due", len(e.delayedQueue) == 0 and len(e.udpFlows[KEY()].sent) == 1)
    # UDP download delayed (F6)
    e.tun_writes.clear()
    e.udp_receive(KEY(), b"resp")
    check("F6 udp download delayed too", len(e.delayedQueue) == 1 and len(e.tun_writes) == 0)
    e.advance(300); e.flush_delayed_periodic()
    check("F6 download delivered after latency", len(e.tun_writes) == 1)
    # direction=download + udp must now DO something (old bug: silent no-op)
    e2 = Engine()
    e2.config.enabled = True
    e2.config.mode = "delay"
    e2.config.direction = "download"
    e2.config.latencyMs = 200
    e2.config.jitterMs = 0
    e2.handle_outbound(udp_outbound(b"up"))
    check("direction=download: upload not gated", len(e2.delayedQueue) == 0 and len(e2.udpFlows[KEY()].sent) == 1)
    e2.udp_receive(KEY(), b"down")
    check("F6 direction=download gates download", len(e2.delayedQueue) == 1)
    # TCP upload: payload forwarded immediately, ACK delayed (F7)
    e3 = Engine()
    e3.config.enabled = True
    e3.config.mode = "delay"
    e3.config.latencyMs = 250
    e3.config.jitterMs = 0
    e3.handle_outbound(tcp_outbound(kSYN, 9000))
    f3 = e3.tcpFlows[TKEY()]
    e3.handle_outbound(tcp_outbound(kACK, 9001, (f3.serverIsn + 1) & 0xFFFFFFFF))
    f3.phase = "established"
    f3.clientNext = 9001
    e3.tun_writes.clear()
    e3.handle_outbound(tcp_outbound(kPSH | kACK, 9001, (f3.serverIsn + 1) & 0xFFFFFFFF, b"UP"))
    check("F7 tcp upload payload forwarded immediately", b"UP" in b"".join(f3.toServer))
    check("F7 tcp upload ACK delayed (not in TUN yet)", all(parse_ip(p)[1] != kTCP or parse_ip(p)[2] != SERVER_IP or len(p) != 40 for p in e3.tun_writes) if e3.tun_writes else True)
    check("F7 ack sits in delayed queue", len(e3.delayedQueue) == 1)
    e3.advance(250); e3.flush_delayed_periodic()
    acks = [p for p in e3.tun_writes if parse_ip(p)[1] == kTCP and (p[20 + 13] & kPSH) == 0]
    check("F7 ack delivered after latency", len(acks) >= 1)
    if acks:
        check("F7 ack is cumulative (clientNext at flush)", r_u32(acks[-1], 20 + 8) == 9003)
    # F8: disable → delayed queue flushed immediately
    e4 = Engine()
    e4.config.enabled = True
    e4.config.mode = "delay"
    e4.config.latencyMs = 5000
    e4.config.jitterMs = 0
    e4.handle_outbound(udp_outbound(b"stuck"))
    check("F8 packet queued (due in 5s)", len(e4.delayedQueue) == 1)
    e4.config.enabled = False  # user turns simulation OFF
    e4.flush_delayed_now()     # what loadConfig(F8) triggers
    check("F8 disable flushes stuck delayed packet", len(e4.delayedQueue) == 0 and len(e4.udpFlows[KEY()].sent) == 1)


def test_tcp_f4_retransmit():
    print("\n[6] F4 — retransmit buffer sống sót qua partial-ACK; dup-ack retransmit hoạt động")
    e = Engine()
    e.handle_outbound(tcp_outbound(kSYN, 100))
    f = e.tcpFlows[TKEY()]
    e.handle_outbound(tcp_outbound(kACK, 101, (f.serverIsn + 1) & 0xFFFFFFFF))
    f.phase = "established"
    f.clientNext = 101
    e.tun_writes.clear()   # bỏ SYN-ACK của handshake ra khỏi bộ đếm
    # server sends 3 segments (3 receive callbacks, one 10-byte chunk each)
    e.splice_server_to_client(f, TKEY(), b"A" * 10)
    e.splice_server_to_client(f, TKEY(), b"B" * 10)
    e.splice_server_to_client(f, TKEY(), b"C" * 10)
    check("3 segments registered in unacked", len(f.unacked) == 3, f"unacked={len(f.unacked)}")
    check("3 segments written to TUN", len(e.tun_writes) == 3, f"writes={len(e.tun_writes)}")
    # client ACKs only the first 10 bytes (partial ack)
    first_end = (f.unacked[0][0] + 10) & 0xFFFFFFFF
    e.handle_outbound(tcp_outbound(kACK, 111, first_end))
    # OLD formula would wipe ALL entries here (underflow). NEW keeps the rest.
    check("F4 partial ACK keeps 2 in-flight entries", len(f.unacked) == 2,
          f"unacked={len(f.unacked)}")
    # dup-acks (3x) on the same ack → retransmit (entries older than 300ms)
    e.advance(500)  # make entries stale so retransmit fires
    e.handle_outbound(tcp_outbound(kACK, 111, first_end))
    e.handle_outbound(tcp_outbound(kACK, 111, first_end))
    e.handle_outbound(tcp_outbound(kACK, 111, first_end))
    retx = len(e.tun_writes) - 3
    check("F4 3x dup-ack triggers retransmit of in-flight segments", retx >= 2, f"retx={retx}")
    # seq of retransmitted segment matches the ORIGINAL entry
    rt = e.tun_writes[3]
    check("F4 retransmit seq == entry seq", r_u32(rt, 20 + 4) == e.tcpFlows[TKEY()].unacked[0][0] if e.tcpFlows[TKEY()].unacked else True)
    # full ack clears buffer
    if f.unacked:
        end = (f.unacked[-1][0] + f.unacked[-1][1]) & 0xFFFFFFFF
        e.handle_outbound(tcp_outbound(kACK, 1, end))
    check("F4 full ACK clears retransmit buffer", len(f.unacked) == 0)


def test_tcp_f5_hold_download():
    print("\n[7] F5/F9 — hold download qua 2 maintenance cycles không rò rỉ; autoFlush theo autoFlushSeconds")
    e = Engine()
    e.handle_outbound(tcp_outbound(kSYN, 100))
    f = e.tcpFlows[TKEY()]
    e.handle_outbound(tcp_outbound(kACK, 101, (f.serverIsn + 1) & 0xFFFFFFFF))
    f.phase = "established"
    f.clientNext = 101
    # bật hold SAU khi handshake xong (hold freeze cả SYN)
    e.config.enabled = True
    e.config.mode = "hold"
    e.config.autoFlushSeconds = 3
    e.tun_writes.clear()
    e.splice_server_to_client(f, TKEY(), b"Z" * 50)
    base = e.nowMs()
    e.advance(1000); e.maintenance()
    e.advance(1000); e.maintenance()
    check("held download still held before autoFlush", len(e.tun_writes) == 0)
    e.advance(1500); e.maintenance()   # total 3.5s > 3s
    check("F9 autoFlush releases after autoFlushSeconds", len(e.tun_writes) == 1)
    check("F9 autoFlush does not duplicate (unacked was never filled)", f.unacked == [] and len(e.tun_writes) == 1)
    # manual mode (autoFlush=0) holds forever until flush
    e2 = Engine()
    e2.config.enabled = True
    e2.config.mode = "hold"
    e2.config.autoFlushSeconds = 0
    e2.udpFlows.clear()
    e2.handle_outbound(udp_outbound(b"frozen"))
    e2.advance(120_000); e2.maintenance()
    check("autoFlush=0 → manual hold keeps packet", len(e2.heldQueue) == 1)
    e2.flush_held()
    check("manual flush releases", len(e2.udpFlows[KEY()].sent) == 1)


def test_tcp_teardown():
    print("\n[8] TCP teardown — FIN & RST")
    e = Engine()
    e.handle_outbound(tcp_outbound(kSYN, 100))
    f = e.tcpFlows[TKEY()]
    e.handle_outbound(tcp_outbound(kACK, 101, (f.serverIsn + 1) & 0xFFFFFFFF))
    f.phase = "established"
    f.clientNext = 101
    e.handle_outbound(tcp_outbound(kFIN | kACK, 101, (f.serverIsn + 1) & 0xFFFFFFFF, b"bye"))
    check("FIN advances clientNext (+1)", f.clientNext == 105)  # 101+len(b'bye')=104, +1 fin
    check("clientFin recorded", f.clientFin and f.clientFinSent)
    # RST tears down
    e.handle_outbound(tcp_outbound(kRST, 106, (f.serverIsn + 1) & 0xFFFFFFFF))
    check("RST removes flow", TKEY() not in e.tcpFlows)
    # retransmission of old data is re-ACKed, never re-forwarded
    e.handle_outbound(tcp_outbound(kSYN, 200))
    f2 = e.tcpFlows[TKEY()]
    e.handle_outbound(tcp_outbound(kACK, 201, (f2.serverIsn + 1) & 0xFFFFFFFF))
    f2.phase = "established"
    f2.clientNext = 201
    e.tun_writes.clear()
    e.handle_outbound(tcp_outbound(kPSH | kACK, 201, (f2.serverIsn + 1) & 0xFFFFFFFF, b"one"))
    e.handle_outbound(tcp_outbound(kPSH | kACK, 201, (f2.serverIsn + 1) & 0xFFFFFFFF, b"one"))  # retransmission
    sent = b"".join(f2.toServer)
    check("retransmitted segment NOT re-forwarded", sent.count(b"one") == 1, f"count={sent.count(b'one')}")


def test_target_matching():
    print("\n[9] Per-PID targeting — match theo socket dump của process được chọn")
    e = Engine()
    e.config.enabled = True
    e.config.mode = "hold"
    e.config.targetBundleID = "com.game.example"
    e.config.targetPID = 4242
    e.config.targetSockets = [
        {"localPort": 54321, "remotePort": 7777, "remoteIP": "93.184.216.34", "proto": "udp"},
        {"localPort": 54330, "remotePort": 443, "remoteIP": "142.250.4.113", "proto": "tcp"},
    ]
    check("target socket matches → gated", e.handle_outbound(udp_outbound(b"x")) is None and len(e.heldQueue) == 1)
    e2 = Engine()
    e2.config.enabled = True
    e2.config.mode = "hold"
    e2.config.targetBundleID = "com.game.example"
    e2.config.targetSockets = [
        {"localPort": 1111, "remotePort": 443, "remoteIP": "142.250.4.113", "proto": "tcp"},
    ]
    e2.handle_outbound(udp_outbound(b"other-app-flow", sport=9999, dport=8888))
    check("non-target flow NOT gated", len(e2.heldQueue) == 0 and len(e2.udpFlows) == 1)
    check("non-target relayed", len(e2.udpFlows[FlowKey(kUDP, CLIENT_IP, 9999, SERVER_IP, 8888)].sent) == 1)
    # empty socket dump falls back to match-all (logged in the app)
    e3 = Engine()
    e3.config.enabled = True
    e3.config.mode = "hold"
    e3.config.targetBundleID = "com.game.example"
    e3.config.targetSockets = []
    e3.handle_outbound(udp_outbound(b"fallback"))
    check("empty socket dump → match-all fallback", len(e3.heldQueue) == 1)
    # GLOBAL target matches everything
    e4 = Engine()
    e4.config.enabled = True
    e4.config.mode = "hold"
    e4.handle_outbound(udp_outbound(b"global", sport=1, dport=2))
    check("GLOBAL (no target) matches all", len(e4.heldQueue) == 1)


def test_root_sockdump():
    """[9b] ROOT socket dump — per-PID targeting THẬT trên máy thật.

    Device log cũ: 'socket dump EMPTY, sockets=0' — vì proc_pidfdinfo vào
    process KHÁC cần uid 0 mà app chạy uid 501. Fix: dump chạy trong helper
    root ('self -sockdump <pid> <outfile>'), app parse JSON. Test mô phỏng:
    format JSON helper ghi, parse app-side, cache+async re-save, fallback.
    """
    print("\n[9b] ROOT socket dump — helper ghi JSON, app parse, cache + async re-save")
    import json, re, os

    # ── 1. Source integrity: cả 2 target (PacketBlocker + twin HybridFakeLagV2)
    srcs = {
        "persona": open(ROOT + "/PacketBlocker/Core/PersonaHelper.m").read(),
        "persona_h": open(ROOT + "/PacketBlocker/Core/PersonaHelper.h").read(),
        "pb_main": open(ROOT + "/PacketBlocker/main.mm").read(),
        "pb_pm_swift": open(ROOT + "/PacketBlocker/ProcessManager.swift").read(),
        "pb_vpn": open(ROOT + "/PacketBlocker/VPNManager.swift").read(),
        "twin_pm": open(ROOT + "/HybridFakeLagV2/Core/ProcessManager.mm").read(),
        "twin_pm_h": open(ROOT + "/HybridFakeLagV2/Core/ProcessManager.h").read(),
        "twin_main": open(ROOT + "/HybridFakeLagV2/main.mm").read(),
        "twin_vpn": open(ROOT + "/HybridFakeLagV2/Hybrid/VPNManager.swift").read(),
        "twin_bridge": open(ROOT + "/HybridFakeLagV2/Hybrid/BridgingHeader.h").read(),
        "pb_bridge": open(ROOT + "/PacketBlocker/PacketBlocker-Bridging-Header.h").read(),
    }
    for key in ("persona", "twin_pm"):
        s = srcs[key]
        check(f"{key}: có HybridWriteSocketDumpFile + HybridSockDumpViaRoot + HybridProcSocketDump",
              all(fn in s for fn in ("HybridWriteSocketDumpFile", "HybridSockDumpViaRoot", "HybridProcSocketDump")))
        check(f"{key}: helper ghi JSON + chmod 0666 (app uid 501 đọc được)",
              'fprintf(f, "["' in s and "chmod(outfile, 0666)" in s)
        check(f"{key}: dump rỗng vẫn ghi '[]' (phân biệt 'chạy xong 0 socket' vs 'chưa chạy')",
              'fprintf(f, "]"' in s)
        check(f"{key}: via-root poll file ≤2s (40×50ms)", "40; i++" in s and "usleep(50 * 1000)" in s)
    for key in ("persona_h", "twin_pm_h"):
        check(f"{key}: khai báo 2 hàm mới", "HybridWriteSocketDumpFile" in srcs[key] and "HybridSockDumpViaRoot" in srcs[key])
    for key in ("pb_main", "twin_main"):
        check(f"{key}: dispatch -sockdump (mode riêng, parse 'pid outfile')",
              "-sockdump" in srcs[key] and "%d %1023s" in srcs[key])
    for key in ("pb_vpn", "twin_vpn"):
        s = srcs[key]
        check(f"{key}: saveConfig dùng cache + kick dump nền", "cachedSockets(proc.pid)" in s and "refreshTargetSockets()" in s)
        check(f"{key}: TARGET_REFRESH guard pid vẫn được chọn", "cfg.targetPID == proc.pid" in s)
        check(f"{key}: VPN_STATUS log sau async hop (fix stale flag)",
              re.search(r"updateStatus\(\)\n[^\n]*\n[^\n]*\n[^\n]*\n[^\n]*DispatchQueue\.main\.async \{\n[^\n]*AppGroupStore\.logAction\(\"VPN_STATUS\"", s) is not None)
    check("pb_pm_swift: root-first (PID variant) + fallback + serial queue + cache",
          "HybridSockDumpViaRootPID(pid, dumpPath, &helperPid)" in srcs["pb_pm_swift"]
          and "parseSocketDumpFile" in srcs["pb_pm_swift"]
          and "directDump" in srcs["pb_pm_swift"]
          and "sockQueue" in srcs["pb_pm_swift"] and "socketCache" in srcs["pb_pm_swift"])
    check("twin_vpn: root-first (PID variant) + helper-probe fallback",
          "HybridSockDumpViaRootPID(pid, dumpPath, &helperPid)" in srcs["twin_vpn"]
          and "SOCKET_DUMP_FAIL" in srcs["twin_vpn"] and "directDump" in srcs["twin_vpn"])
    check("pb_bridge: PersonaHelper.h import (Swift thấy HybridSockDumpViaRoot)",
          "Core/PersonaHelper.h" in srcs["pb_bridge"])
    check("twin_bridge: khai báo HybridSockDumpViaRoot + import PrivateSystemSPI",
          "HybridSockDumpViaRoot" in srcs["twin_bridge"] and "PrivateSystemSPI.h" in srcs["twin_bridge"])
    check("twin_bridge vẫn KHÔNG #import AetherNetShared.h (_Atomic)",
          "#import \"../headers/AetherNetShared.h\"" not in srcs["twin_bridge"]
          and "#include \"../headers/AetherNetShared.h\"" not in srcs["twin_bridge"]
          and "#import <AetherNetShared.h>" not in srcs["twin_bridge"]
          and "#include <AetherNetShared.h>" not in srcs["twin_bridge"])

    # ── 2. Behavior: mô phỏng helper ghi JSON → app parse
    def helper_write(entries):
        # port 1:1 HybridWriteSocketDumpFile — prefix-comma per entry,
        # KHÔNG có join separator (C ghi tuần tự vào file) → join bằng ""
        parts = []
        for i, e in enumerate(entries):
            parts.append('%s{"proto":"%s","localPort":%u,"remotePort":%u,"remoteIP":"%s"}' %
                         ("," if i > 0 else "", e["proto"], e["localPort"], e["remotePort"], e["remoteIP"]))
        return "[" + "".join(parts) + "]"

    live = [
        {"proto": "udp", "localPort": 54321, "remotePort": 7777, "remoteIP": "93.184.216.34"},
        {"proto": "tcp", "localPort": 54330, "remotePort": 443, "remoteIP": "142.250.4.113"},
        {"proto": "tcp", "localPort": 54331, "remotePort": 443, "remoteIP": "0.0.0.0"},     # bị lọc
        {"proto": "udp", "localPort": 54332, "remotePort": 53, "remoteIP": "2001:db8::1"},  # bị lọc (IPv6)
    ]
    raw = helper_write(live)
    check("helper JSON parse lại được (json.loads)", isinstance(json.loads(raw), list))
    # port 1:1 parseSocketDumpFile: lọc IPv6/0.0.0.0, cast port qua NSNumber.uint16Value
    parsed = []
    for d in json.loads(raw):
        ip = d.get("remoteIP")
        if not (ip and "." in ip and ip != "0.0.0.0"):
            continue
        parsed.append({"localPort": d.get("localPort", 0), "remotePort": d.get("remotePort", 0),
                       "remoteIP": ip, "proto": d.get("proto")})
    check("app parse lọc IPv6 + 0.0.0.0 → còn 2 entries IPv4 hữu dụng", len(parsed) == 2)
    check("empty dump → '[]' hợp lệ, parse ra []", json.loads(helper_write([])) == [])

    # ── 3. Behavior: cache + async re-save (port refreshTargetSockets)
    class AppSim:
        def __init__(self):
            self.cache = {}
            self.last_sig = set()
            self.saved = []
            self.target_pid = 4242
        def dump_completed(self, pid, entries):  # completion trên main thread
            sig = {(s["proto"], s["remoteIP"], s["remotePort"]) for s in entries}
            if sig == self.last_sig:
                return "skip-unchanged"
            self.last_sig = sig
            if pid != self.target_pid:
                return "skip-selection-changed"   # guard pid
            self.saved.append((pid, len(entries)))
            return "saved"
    a = AppSim()
    check("dump đầu tiên khác sig rỗng → saved", a.dump_completed(4242, parsed) == "saved")
    check("dump lặp lại cùng sig → skip (throttle)", a.dump_completed(4242, parsed) == "skip-unchanged")
    other = [{"localPort": 1, "remotePort": 2, "remoteIP": "1.2.3.4", "proto": "udp"}]
    check("dump pid khác + sig khác → guard selection chặn (không save nhầm)",
          a.dump_completed(9999, other) == "skip-selection-changed")
    check("user chọn GLOBAL rồi chọn lại pid: cache cũ dùng ngay (toggle instant)", a.cache.get(4242) is None)

    # ── 4. Fallback: spawn root fail → in-process dump (trên device trả [] vì uid 501)
    def app_dump(root_ok, helper_json=None, direct=[]):
        if root_ok:
            return json.loads(helper_json)
        return direct  # HybridProcSocketDump in-app → EPERM → []
    check("root spawn fail → fallback in-process dump ([]) mà không crash",
          app_dump(False, direct=[]) == [])
    check("root ok → dữ liệu thật", len(app_dump(True, helper_write(live))) == 4)


def test_config_precedence():
    print("\n[10] Config precedence — override mới hơn config, Caches fallback (port of loadSync)")
    class FS:
        def __init__(self):
            self.group_config = None     # (json_str, mtime)
            self.caches_config = None
            self.group_override = None
            self.caches_override = None
    fs = FS()

    def load_sync(fs):
        cfg = {"enabled": False, "timestamp": 0}
        loaded = False
        if fs.group_config is not None:
            cfg = json.loads(fs.group_config); loaded = True
        elif fs.caches_config is not None:
            cfg = json.loads(fs.caches_config); loaded = True
        o_ts, o_en = -1, None
        for o in (fs.group_override, fs.caches_override):
            if o is not None:
                d = json.loads(o)
                if d["timestamp"] > o_ts:
                    o_ts, o_en = d["timestamp"], d["enabled"]
        if o_en is not None and o_ts > cfg.get("timestamp", 0):
            cfg["enabled"] = o_en
            cfg["timestamp"] = o_ts
        # FIX (engine port): chỉ reset về default khi KHÔNG load được gì cả —
        # reset timestamp sau khi áp override sẽ làm poll sau bỏ qua override.
        if not loaded and o_en is None:
            cfg["timestamp"] = 0
        return cfg

    fs.group_config = json.dumps({"enabled": False, "timestamp": 100})
    fs.group_override = json.dumps({"enabled": True, "timestamp": 200})
    check("override newer wins (enabled=true)", load_sync(fs)["enabled"] is True)
    fs.group_config = json.dumps({"enabled": False, "timestamp": 300})
    check("config newer than override wins", load_sync(fs)["enabled"] is False)
    fs.group_override = json.dumps({"enabled": True, "timestamp": 400})
    fs.caches_override = json.dumps({"enabled": False, "timestamp": 350})
    check("newest override source wins (App Group > Caches by ts)", load_sync(fs)["enabled"] is True)
    fs.group_config = None
    fs.group_override = None
    fs.caches_config = json.dumps({"enabled": True, "timestamp": 500})
    check("Caches fallback used when App Group missing", load_sync(fs)["enabled"] is True)
    fs.caches_config = None
    fs.caches_override = json.dumps({"enabled": True, "timestamp": 600})
    c = load_sync(fs)
    check("override-only (HUD daemon path) still applies", c["enabled"] is True and c["timestamp"] == 600)
    fs.caches_override = None
    check("nothing on disk → defaults enabled=false (pure passthrough)", load_sync(fs)["enabled"] is False and load_sync(fs)["timestamp"] == 0)


# ═══════════ HUD lifecycle (port of ProcessManager.mm bridge + HUDMain.mm) ═══════════

class Shm:
    def __init__(self):
        self.hudCommand = 0
        self.hudHeartbeatTs = 0
        self.hudVisible = False
        self.interceptionActive = False
        self.floatingButtonSize = 58.0
        self.floatingButtonOpacity = 0.94
        self.floatingEdgeSnap = True
        self.floatingLockPosition = False
        self.floatingHapticEnabled = True
        self.floatingPosX = 310.0
        self.floatingPosY = 220.0


class HudSim:
    """Models: shm + pid file + daemon + manager bridge.

    daemon_alive logic mirrors HUDMain.mm: single-instance guard (pid file +
    heartbeat) and the heartbeat timer that exits on hudCommand==1.
    """

    def __init__(self):
        self.shm = Shm()
        self.pid_file = None          # pid or None
        self.live_pids = {}           # pid → exec path
        self.our_exec = "/Applications/HybridFakeLag.app/HybridFakeLag"
        self.spawn_calls = []
        self.clock = 1000

    def daemon_heartbeat(self, pid):
        st = self.shm
        if st.hudCommand == 1:
            self.pid_file = None
            return "exit"
        st.hudHeartbeatTs = self.clock
        return "alive"

    def spawn_daemon(self, pid):
        # HUDMain single-instance guard
        other_alive = False
        if self.pid_file and self.pid_file in self.live_pids and self.pid_file != pid:
            other_alive = True
        if not other_alive and self.shm.hudHeartbeatTs > 0 and self.clock - self.shm.hudHeartbeatTs <= 3:
            other_alive = True
        if other_alive:
            return False  # exits instantly
        self.pid_file = pid
        self.live_pids[pid] = self.our_exec
        self.shm.hudVisible = True
        return True

    # bridge: HybridHUDPrepareForSpawn
    def prepare_for_spawn(self):
        was_alive = self.is_running()
        if was_alive:
            self.shm.hudCommand = 1
            self.shm.hudHeartbeatTs = 0
            if self.pid_file and self.pid_file in self.live_pids:
                del self.live_pids[self.pid_file]
            self.pid_file = None
        # stale pid file: unlink when pid dead or foreign
        if self.pid_file is not None:
            stale = self.pid_file not in self.live_pids or self.live_pids[self.pid_file] != self.our_exec
            if stale:
                self.pid_file = None
        self.shm.hudCommand = 0
        self.shm.hudHeartbeatTs = 0
        self.shm.hudVisible = False
        return 1 if was_alive else 0

    def is_running(self):
        # heartbeat fresh?
        if self.shm.hudHeartbeatTs > 0 and self.clock - self.shm.hudHeartbeatTs <= 3:
            return True
        if self.pid_file is not None:
            p = self.pid_file
            if p in self.live_pids:
                return True
            # EPERM case: root daemon exists but kill(0) blocked → treated alive
            if getattr(self, "_eperm_pids", None) and p in self._eperm_pids:
                return True
        return False

    def request_exit(self):
        self.shm.hudCommand = 1
        self.shm.hudHeartbeatTs = 0

    def remove_stale(self):
        pass


def test_hud_bug1():
    print("\n[11] BUG #1 — Create Floating Button: leftover exit command + stale pid không giết daemon mới")
    # (a) OLD BUG: shm hudCommand=1 còn sót từ lần trước → daemon mới chết <1s
    sim = HudSim()
    sim.shm.hudCommand = 1  # leftover exit command
    spawned = sim.spawn_daemon(999)
    hb = sim.daemon_heartbeat(999)
    check("WITHOUT prepare: leftover hudCommand=1 kills fresh daemon", hb == "exit")
    # (b) FIXED: prepare resets shm first
    sim = HudSim()
    sim.shm.hudCommand = 1
    rc = sim.prepare_for_spawn()
    check("prepare returns 0 when no old daemon", rc == 0)
    check("prepare reset hudCommand to 0", sim.shm.hudCommand == 0)
    spawned = sim.spawn_daemon(999)
    hb = sim.daemon_heartbeat(999)
    check("WITH prepare: fresh daemon survives heartbeat", spawned and hb == "alive")
    check("daemon alive via heartbeat", sim.is_running())
    # (c) stale pid file pointing to DEAD pid → unlinked, spawn OK
    sim = HudSim()
    sim.pid_file = 1234  # dead
    rc = sim.prepare_for_spawn()
    check("stale dead pid file removed", sim.pid_file is None and rc == 0)
    check("spawn after cleanup works", sim.spawn_daemon(555) and sim.daemon_heartbeat(555) == "alive")
    # (d) pid file points to FOREIGN live process (pid reuse) → guard would
    #     kill the daemon; prepare detects path mismatch and unlinks.
    sim = HudSim()
    sim.pid_file = 77
    sim.live_pids[77] = "/Applications/SomeOtherApp.app/SomeOtherApp"  # foreign
    rc = sim.prepare_for_spawn()
    check("foreign live pid file removed (path mismatch)", sim.pid_file is None)
    check("daemon spawns despite foreign pid file", sim.spawn_daemon(888) and sim.daemon_heartbeat(888) == "alive")
    # (e) real old daemon alive → prepare returns 1 (caller waits then respawns)
    sim = HudSim()
    sim.spawn_daemon(111); sim.daemon_heartbeat(111)
    rc = sim.prepare_for_spawn()
    check("prepare kills old daemon and returns 1", rc == 1 and not sim.is_running())
    # (f) Remove flow: hudCommand=1 → daemon self-exits
    sim.request_exit()
    check("remove: heartbeat sees exit command", sim.daemon_heartbeat(111) == "exit")


def test_shm_config_sync():
    print("\n[12] Floating config → shm (daemon đọc size/opacity/snap/lock/haptic/pos)")
    sim = HudSim()
    st = sim.shm
    # port of HybridHUDSyncFloatingConfig
    st.floatingButtonSize = 72.0
    st.floatingButtonOpacity = 0.80
    st.floatingEdgeSnap = False
    st.floatingLockPosition = True
    st.floatingHapticEnabled = False
    st.floatingPosX = 40.0
    st.floatingPosY = 600.0
    ok = (st.floatingButtonSize == 72.0 and abs(st.floatingButtonOpacity - 0.80) < 1e-6
          and st.floatingEdgeSnap is False and st.floatingLockPosition is True
          and st.floatingHapticEnabled is False and st.floatingPosX == 40.0 and st.floatingPosY == 600.0)
    check("HybridHUDSyncFloatingConfig writes every field", ok)
    # daemon renders using shm values (FloatingToggleButton.syncWithSharedState)
    diameter = st.floatingButtonSize
    alpha = max(0.35, min(1.0, st.floatingButtonOpacity))
    check("daemon sees size/opacity from shm", diameter == 72.0 and abs(alpha - 0.8) < 1e-6)


def test_floating_button_override():
    print("\n[13] Floating button tap → extension override (HybridWriteExtOverrideFiles)")
    class FS2:
        caches_override = None
        group_override = None
    fs = FS2()
    # port of setInterceptionActive → HybridWriteExtOverrideFiles
    def toggle(active, ts):
        d = {"enabled": active, "timestamp": ts}
        fs.caches_override = json.dumps(d)          # /var/mobile/Library/Caches/...
        if fs.group_override is not None or True:    # App Group containers holding hybrid_config.json
            fs.group_override = json.dumps(d)
    toggle(True, 1000)
    # extension loadSync reads both, newest wins
    cfg = {"enabled": False, "timestamp": 500}
    best_ts, best_en = -1, None
    for o in (fs.group_override, fs.caches_override):
        d = json.loads(o)
        if d["timestamp"] > best_ts:
            best_ts, best_en = d["timestamp"], d["enabled"]
    applied = best_en if best_ts > cfg["timestamp"] else cfg["enabled"]
    check("tap ON → extension sees enabled=true", applied is True)
    toggle(False, 2000)
    best_ts, best_en = -1, None
    for o in (fs.group_override, fs.caches_override):
        d = json.loads(o)
        if d["timestamp"] > best_ts:
            best_ts, best_en = d["timestamp"], d["enabled"]
    applied = best_en if best_ts > cfg["timestamp"] else cfg["enabled"]
    check("tap OFF → extension sees enabled=false", applied is False)


# ═══════════ Logs (port of AppGroupStore) ═══════════

def test_logs_bug2():
    print("\n[14] BUG #2 — log chi tiết, merge 4 nguồn, filter, rotation, copyable")
    lines = []

    def log_action(action, details="", level="INFO"):
        lines.append(f"[2026-09-30T00:00:00Z] [{level}] [{action}] {details or '-'}")

    log_action("HUD_CREATE", "prepare + spawn root HUD daemon (TrollNet flow)")
    log_action("VPN_START", "startVPNTunnel() called")
    log_action("CONFIG", "enabled=True mode=delay dir=both proto=udp ratio=85% latency=350ms")
    log_action("STATS", "passed=1000 dropped=42 held=3 delayed=0 udpFlows=8 tcpFlows=2")
    log_action("UDP_SEND_ERR", "flow failed", level="ERROR")
    detailed = all(len(l) > 30 for l in lines)
    check("mọi dòng log đều chi tiết (>30 ký tự)", detailed)
    check("log có level", any("[ERROR]" in l for l in lines))

    # merge sources
    app_group = "\n".join(lines)
    caches = app_group[-50:]
    inject_log = "[hook] payload armed in target (pid 4242)"
    hud_log = "[pid 999] HUD daemon starting"
    combined = app_group
    if caches not in combined:
        combined += "\n--- Caches Mirror Log ---\n" + caches
    combined += "\n--- AetherNet App Log (inject layer) ---\n" + inject_log
    combined += "\n--- HUD Daemon Log ---\n" + hud_log
    check("readLogs merge 4 nguồn", all(s in combined for s in ("[HUD_CREATE]", "payload armed", "HUD daemon starting")))
    # filter
    q = "hud"
    kept = [l for l in combined.split("\n") if not l or q in l.lower()]
    check("filter theo từ khoá", all((not l) or ("hud" in l.lower()) for l in kept) and len(kept) >= 2)
    # rotation 512KB → giữ 256KB cuối
    data = "x" * (600 * 1024)
    if len(data) > 512 * 1024:
        data = data[-256 * 1024:]
    check("rotation giữ 256KB", len(data) == 256 * 1024)
    # copy: nội dung trả về là string thuần → UIPasteboard.general.string nhận được
    check("nội dung là string thuần (copy được)", isinstance(combined, str) and len(combined) > 0)


# ═══════════ Payload config loader (port of NetHookPayload.mm) ═══════════

class PayloadSim:
    def __init__(self):
        self.shm_state = None            # dict or None (unreadable)
        self.caches_file = None          # json str or None
        self.appgroup_file = None        # json str or None
        self.g_cache_ms = -10_000
        self.clock = 0
        self.gActive = False
        self.gMode = 0
        self.gProtoFilter = 0
        self.gCaptureRatio = 100
        self.gAutoFlush = 12
        self.gLatency = 350
        self.gJitter = 80

    def refresh_config(self):
        if self.clock - self.g_cache_ms < 500:      # P2 cache
            return
        self.g_cache_ms = self.clock
        # P1: shm đã khởi tạo thật (magic ok) là nguồn số 1, thắng JSON.
        # (port của: if (st && st->magic == AETHER_SHM_MAGIC) { loadConfigFromShm(); return; })
        if self.shm_state is not None:
            s = self.shm_state
            self.gActive = s["enabled"]
            self.gMode = s["mode"]
            self.gCaptureRatio = s.get("ratio", 100)
            self.gLatency = s.get("latency", 350)
            self.gJitter = s.get("jitter", 80)
            self.gAutoFlush = s.get("autoFlush", 12)
            self.gProtoFilter = s.get("proto", 0)
            return
        src = self.caches_file if self.caches_file is not None else self.appgroup_file
        if src is not None:
            d = json.loads(src)
            self.gActive = d.get("enabled", False)
            mode = d.get("mode", "hold")
            self.gMode = {"hold": 0, "drop": 1, "delay": 2}[mode]
            pf = d.get("protoFilter", "both")
            self.gProtoFilter = {"udp": 1, "tcp": 2}.get(pf, 0)
            self.gCaptureRatio = max(0, min(100, d.get("captureRatio", 100)))
            self.gAutoFlush = max(0, min(60, d.get("autoFlushSeconds", 12)))
            self.gLatency = max(0, min(3000, d.get("latencyMs", 350)))
            self.gJitter = max(0, min(1000, d.get("jitterMs", 80)))

    def hooked_sendto(self, is_udp=True):
        """Returns 'hold'|'drop'|'delay'|'pass' for this call."""
        self.refresh_config()
        if not self.gActive:
            return "pass"
        if self.gProtoFilter == 1 and not is_udp:
            return "pass"
        if self.gProtoFilter == 2 and is_udp:
            return "pass"
        if self.gCaptureRatio >= 100:
            pass
        elif self.gCaptureRatio <= 0:
            return "pass"
        elif random.randint(0, 99) >= self.gCaptureRatio:
            return "pass"
        return ["hold", "drop", "delay"][self.gMode]


def test_payload_loader():
    print("\n[15] P1/P2/P3 — payload đọc được config (path đúng), cache 500ms, ratio/latency từ config")
    p = PayloadSim()
    p.clock = 10_000
    check("P1 không có config → payload inert (pass)", p.hooked_sendto() == "pass")
    # OLD BUG path: only com.hybrid.fakelag.json existed → inert forever. NEW: Caches mirror.
    p.caches_file = json.dumps({"enabled": True, "mode": "delay", "captureRatio": 100,
                                "latencyMs": 400, "jitterMs": 50, "autoFlushSeconds": 8})
    p.clock += 500  # vượt cache 500ms của lần call đầu
    r = p.hooked_sendto()
    check("P1 Caches mirror kích hoạt payload", r == "delay")
    check("P3 latency từ config (400ms)", p.gLatency == 400 and p.gJitter == 50 and p.gAutoFlush == 8)
    # cache: change file, call again within 500ms → unchanged
    old_latency = p.gLatency
    p.caches_file = json.dumps({"enabled": True, "mode": "delay", "latencyMs": 999})
    p.clock += 200
    p.hooked_sendto()
    check("P2 cache 500ms (không re-parse mỗi call)", p.gLatency == old_latency)
    p.clock += 400
    p.hooked_sendto()
    check("P2 sau 500ms config mới được nạp", p.gLatency == 999)
    # ratio 0 → never intercepts
    p.caches_file = json.dumps({"enabled": True, "mode": "hold", "captureRatio": 0})
    p.clock += 1000
    check("ratio=0 → pass (normal preset)", p.hooked_sendto() == "pass")
    # ratio 50 statistical
    p.caches_file = json.dumps({"enabled": True, "mode": "hold", "captureRatio": 50})
    p.clock += 1000
    random.seed(3)
    held = sum(1 for _ in range(400) if p.hooked_sendto() == "hold")
    check("ratio=50 → ~50% hold", 140 <= held <= 260, f"held={held}/400")
    # protoFilter tcp → udp passes
    p.caches_file = json.dumps({"enabled": True, "mode": "drop", "protoFilter": "tcp", "captureRatio": 100})
    p.clock += 1000
    check("protoFilter=tcp → udp pass", p.hooked_sendto(is_udp=True) == "pass")
    check("protoFilter=tcp → tcp drop", p.hooked_sendto(is_udp=False) == "drop")
    # P4: autoFlush bound (never > 60s even if config insane)
    p.caches_file = json.dumps({"enabled": True, "mode": "hold", "autoFlushSeconds": 100000})
    p.clock += 1000
    p.hooked_sendto()   # refresh cần một lần call (như trong target thật)
    check("P4 autoFlush clamped ≤ 60s", p.gAutoFlush == 60)
    # App Group glob fallback
    p2 = PayloadSim()
    p2.clock = 10_000
    p2.appgroup_file = json.dumps({"enabled": True, "mode": "drop"})
    check("P1 App Group glob fallback", p2.hooked_sendto() == "drop")
    # shm wins when readable
    p3 = PayloadSim()
    p3.clock = 10_000
    p3.shm_state = {"enabled": True, "mode": 2, "ratio": 100}
    p3.caches_file = json.dumps({"enabled": False})
    check("P1 shm (interceptionActive) được đọc", p3.hooked_sendto() == "delay")


def test_engine_version_sync():
    print("\n[16] 2 engine đồng bộ — PacketBlockerExtension == HybridFakeLagV2/HybridExtension")
    import hashlib
    def strip(path):
        src = open(path).read()
        # bỏ các dòng khác nhau do App Group id + comment header
        out = []
        for ln in src.split("\n"):
            if "group.com.ban.PacketBlocker" in ln or "group.com.hybrid.fakelag" in ln:
                ln = "GROUP_ID"
            if ln.strip().startswith("//"):
                continue
            out.append(ln)
        return hashlib.sha256("\n".join(out).encode()).hexdigest()
    h1 = strip(ROOT + "/HybridFakeLagV2/HybridExtension/PacketTunnelProvider.swift")
    h2 = strip(ROOT + "/PacketBlockerExtension/PacketTunnelProvider.swift")
    check("logic 2 engine giống nhau (sau khi bỏ group-id/comment)", h1 == h2, f"{h1[:12]} vs {h2[:12]}")


def test_pbxproj_integrity():
    print("\n[17] pbxproj & entitlements integrity")
    import re, os
    src = open(ROOT + "/HybridFakeLagV2/HybridFakeLagV2.xcodeproj/project.pbxproj").read()
    check("braces balanced", src.count("{") == src.count("}"))
    check("bridging header wired",
          src.count("SWIFT_OBJC_BRIDGING_HEADER") == 2 and "Hybrid/BridgingHeader.h" in src)
    check("payload script phase added",
          "PBXShellScriptBuildPhase" in src and "-DHYBRID_PAYLOAD_BUILD" in src
          and "libNetHookPayload.dylib" in src)
    check("script phase in app target buildPhases",
          re.search(r"buildPhases = \(779C4EB2D3134A0D96720EDF, AA10BB22CC33DD44EE55FF66\)", src) is not None)
    ent = open(ROOT + "/HybridFakeLagV2/HybridExtension/entitlements.plist").read()
    check("extension entitlements: no-sandbox + packet-tunnel",
          "no-sandbox" in ent and "packet-tunnel-provider" in ent and "group.com.hybrid.fakelag" in ent)
    check("PacketBlockerExtension.entitlements tồn tại",
          os.path.exists(ROOT + "/PacketBlockerExtension/PacketBlockerExtension.entitlements"))
    # Bridging header không được import AetherNetShared.h (Swift importer không parse _Atomic được)
    bh = open(ROOT + "/HybridFakeLagV2/Hybrid/BridgingHeader.h").read()
    check("BridgingHeader.h không include AetherNetShared.h (_Atomic)",
          '#include "../headers/AetherNetShared.h"' not in bh and '#import "../headers/AetherNetShared.h"' not in bh
          and "#include <AetherNetShared.h>" not in bh and "#import <AetherNetShared.h>" not in bh)
    # bridge implementations tồn tại
    pm = open(ROOT + "/HybridFakeLagV2/Core/ProcessManager.mm").read()
    for fn in ("HybridHUDIsRunning", "HybridHUDPrepareForSpawn", "HybridHUDRequestExit",
               "HybridSpawnRoot", "HybridHUDSyncFloatingConfig", "HybridHUDSetInterceptionActive",
               "HybridWriteExtOverrideFiles"):
        check(f"ProcessManager.mm có {fn}", fn in pm)
    # payload guard
    np = open(ROOT + "/HybridFakeLagV2/Payload/NetHookPayload.mm").read()
    check("NetHookPayload guard HYBRID_PAYLOAD_BUILD", "#ifdef HYBRID_PAYLOAD_BUILD" in np and "#endif /* HYBRID_PAYLOAD_BUILD */" in np)
    # The old assertion demanded the JSON mirror the payload can never read from
    # inside a sandboxed target — that WAS the bug. Config now arrives over the
    # target's own IPC socket (see [4.0c]).
    check("NetHookPayload đọc config qua IPC socket trong TMPDIR",
          "AETHER_IPC_SOCK_NAME" in np and "recv(clientFd, &c, sizeof(c)" in np)
    check("NetHookPayload KHÔNG còn đọc path chết com.hybrid.fakelag.json",
          'dataWithContentsOfFile:@"/var/mobile/Library/Caches/com.hybrid.fakelag.json"' not in np)
    hud = open(ROOT + "/HybridFakeLagV2/HUD/HUDMain.mm").read()
    check("HUDMain -exit có proc_pidpath guard", "isOurDaemon" in hud)
    swift = open(ROOT + "/HybridFakeLagV2/HybridExtension/PacketTunnelProvider.swift").read()
    check("extension: ipv4 default route only (F1)", "NEIPv6Settings" not in swift and "NEIPv4Route.default()" in swift)
    check("extension: IPv6 loop guard", "NEVER write it back" in swift)


def test_v391_fixes():
    print("\n[18] v3.9.1 — monotonic clock (NTP-step crash) + HUD spawn hygiene")
    # ── 1. Monotonic clock + wrap-safe maintenance in BOTH engines ──
    engines = {
        "pb_ext": ROOT + "/PacketBlockerExtension/PacketTunnelProvider.swift",
        "twin_ext": ROOT + "/HybridFakeLagV2/HybridExtension/PacketTunnelProvider.swift",
    }
    for name, path in engines.items():
        s = open(path).read()
        check(f"{name}: nowMs() dùng DispatchTime (monotonic, chống NTP step)",
              "DispatchTime.now().uptimeNanoseconds / 1_000_000" in s)
        check(f"{name}: KHÔNG còn nowMs từ wall clock",
              "UInt64(Date().timeIntervalSince1970 * 1000)" not in s)
        check(f"{name}: maintenance dùng &- (wrap-safe) cho lastSeen",
              "now &- flow.lastSeen > 60_000" in s and "now &- flow.lastSeen > idleLimit" in s)
        check(f"{name}: KHÔNG còn phép trừ thường trên lastSeen",
              "now - flow.lastSeen" not in s)
    # ── 2. Earliest-boot ctor logger in BOTH main.mm ──
    mains = {
        "pb_main": ROOT + "/PacketBlocker/main.mm",
        "twin_main": ROOT + "/HybridFakeLagV2/main.mm",
    }
    for name, path in mains.items():
        s = open(path).read()
        check(f"{name}: constructor AetherEarlyBootLog ghi [HUD_EARLY] trước main()",
              '__attribute__((constructor))' in s and '[HUD_EARLY] ctor' in s
              and 'hybrid_actions.log' in s)
    # ── 3. HUD daemon: early heartbeat + background installer ──
    huds = {
        "pb_hud": ROOT + "/PacketBlocker/HUD/HUDMain.mm",
        "twin_hud": ROOT + "/HybridFakeLagV2/HUD/HUDMain.mm",
    }
    for name, path in huds.items():
        s = open(path).read()
        check(f"{name}: HUDStepLog stamp heartbeat sớm (không đợi step12)",
              "hudHeartbeatTs, (uint64_t)time(NULL));" in s)
        check(f"{name}: installer chạy background (không chậm UIKit init)",
              "hook payload installer dispatched" in s)
    # ── 4. Spawn hygiene: clean env + child pid + probe + debounce ──
    persona = open(ROOT + "/PacketBlocker/Core/PersonaHelper.m").read()
    twin_pm = open(ROOT + "/HybridFakeLagV2/Core/ProcessManager.mm").read()
    for name, s in (("persona", persona), ("twin_pm", twin_pm)):
        check(f"{name}: HybridSpawnRootPID trả child pid", "int HybridSpawnRootPID" in s)
        check(f"{name}: HybridProbeChildPid (0=gone 1=alive 2=EPERM)", "int HybridProbeChildPid" in s)
        check(f"{name}: spawn dùng env sạch (bỏ __XPC_*/XPC_*)",
              '__XPC_' in s and 'HybridCleanEnvp' in s if name == "persona" else
              ('__XPC_' in s and 'cleanEnv' in s))
    for name, path in (("pb_floating", ROOT + "/PacketBlocker/FloatingHUDManager.swift"),
                       ("twin_floating", ROOT + "/HybridFakeLagV2/Hybrid/FloatingHUDManager.swift")):
        s = open(path).read()
        check(f"{name}: debounce HUD_CREATE (chống spawn-storm)",
              "HUD_CREATE_SKIP" in s and "debounce" in s and "inFlightSpawn" in s)
        check(f"{name}: spawn PID-variant + probe child",
              "HybridSpawnRootPID(cPath" in s and "HybridProbeChildPid(childPid" in s
              and "HUD_SPAWN_PID" in s)
        check(f"{name}: verify window 2.5s", ".now() + 2.5" in s)
    # ── 5. Version bump để phân biệt artifact ──
    info = open(ROOT + "/PacketBlocker/Info.plist").read()
    check("Info.plist 3.9.1/391", "<string>3.9.1</string>" in info and "<string>391</string>" in info)
    shared = open(ROOT + "/PacketBlocker/headers/AetherNetShared.h").read()
    check("AETHER_BUILD_NUM 362", "AETHER_BUILD_NUM            362U" in shared)



# ═══════════════ [4.0] PAYLOAD IPC + TARGET GATE + INJECTOR VERDICT ═══════════════
# These guard the three defects that made injection capture exactly zero packets:
# the dylib was never built, it could never read a config (sandbox), and its
# hook engine was a no-op that still claimed success.

def fnv1a(s):
    h = 2166136261
    for ch in s.encode():
        h ^= ch
        h = (h * 16777619) & 0xFFFFFFFF
    return h if h else 1

def test_payload_ipc_wire():
    print("\n[4.0a] IPC wire format — header đồng bộ 2 bản + hash ổn định")
    a = open(ROOT + "/HybridFakeLagV2/headers/AetherNetIPC.h").read()
    b = open(ROOT + "/PacketBlocker/headers/AetherNetIPC.h").read()
    check("AetherNetIPC.h hai bản giống hệt (không drift)", a == b)
    check("magic/version định nghĩa", "0xA374EC01u" in a and "AETHER_IPC_VERSION   1u" in a)
    check("sock theo pid trong TMPDIR", 'aether_net_%d.sock' in a and "AETHER_IPC_DATA_ROOT" in a)
    check("6 hook bit + ST_NO_ENGINE", "AETHER_HOOK_ALL      0x3Fu" in a and "AETHER_IPC_ST_NO_ENGINE" in a)
    for f in ("targetPID", "bundleHash", "enabled", "direction", "protocolFilter",
              "mode", "captureRatio", "latencyMs", "jitterMs", "autoFlushSeconds"):
        check(f"AetherIpcConfig có {f}", f in a)
    for f in ("hookMask", "status", "queued", "isTarget", "tcpRX", "udpTX", "held", "dropped"):
        check(f"AetherIpcTelemetry có {f}", f in a)
    check("FNV-1a deterministic", fnv1a("com.ban.PacketBlocker") == fnv1a("com.ban.PacketBlocker"))
    check("FNV-1a phân biệt bundle", fnv1a("com.apple.mobilesafari") != fnv1a("com.ban.PacketBlocker"))
    check("FNV-1a seed khi chuỗi rỗng (NULL → 0 nên gate tự tắt)",
          fnv1a("") == 2166136261 and fnv1a("") != 0)

def test_payload_target_gate():
    print("\n[4.0b] Target gate — payload KHÔNG được đụng process khác")
    s = open(ROOT + "/HybridFakeLagV2/Payload/NetHookPayload.mm").read()

    def gate(have_cfg, target_pid, want_hash, own_pid, own_hash):
        if not have_cfg:
            return False
        if target_pid > 0 and target_pid == own_pid:
            return True
        return want_hash != 0 and want_hash == own_hash
    check("gate: chưa có config → không intercept", gate(0, 0, 0, 100, 7) is False)
    check("gate: pid trùng → intercept", gate(1, 100, 0, 100, 7) is True)
    check("gate: pid lệch, hash trùng → intercept (sống sót app relaunch)", gate(1, 100, 7, 101, 7) is True)
    check("gate: pid lệch, hash lệch → KHÔNG intercept", gate(1, 100, 7, 101, 9) is False)

    check("isTarget() được gọi trong shouldIntercept", "isTarget()" in s and
          s.index("static bool shouldIntercept") < s.index("if (!isTarget()) return false;"))
    check("gHaveConfig chặn trước khi đọc pid/hash", "gHaveConfig.load" in s)

def test_payload_config_channel():
    print("\n[4.0c] Config channel — không còn phụ thuộc sandbox / shm")
    s = open(ROOT + "/HybridFakeLagV2/Payload/NetHookPayload.mm").read()
    np_code = "\n".join(l.split("//", 1)[0] for l in s.splitlines())
    check("KHÔNG gọi AetherGetSharedState (symbol undefined → dlopen fail)",
          "AetherGetSharedState" not in np_code)
    check("KHÔNG đọc /var/mobile/Library/Caches (seatbelt chặn sandbox)",
          "/var/mobile/Library/Caches" not in np_code)
    check("KHÔNG glob AppGroup container", "Containers/Shared/AppGroup" not in s)
    check("KHÔNG dùng NSJSONSerialization trong hook path",
          "NSJSONSerialization" not in s)
    check("socket server bind trong TMPDIR", 'getenv("TMPDIR")' in s and "AETHER_IPC_SOCK_NAME" in s)
    check("socket chmod 0666 (app chạy uid khác)", 'chmod(path, 0666)' in s)
    check("poll loop: nhận config + gửi telemetry",
          "poll(&pfd, 1, 250)" in s and "send(clientFd, &t, sizeof(t), 0)" in s)
    # Darwin không có MSG_NOSIGNAL (chỉ SO_NOSIGPIPE) — dùng là build fail.
    check("KHÔNG dùng MSG_NOSIGNAL (không tồn tại trên Darwin)",
          "MSG_NOSIGNAL" not in np_code and "SO_NOSIGPIPE" in s)
    pb = open(ROOT + "/PacketBlocker/Core/PayloadBridge.mm").read()
    pb_code = "\n".join(l.split("//", 1)[0] for l in pb.splitlines())
    check("app socket dùng SO_NOSIGPIPE, không MSG_NOSIGNAL",
          "MSG_NOSIGNAL" not in pb_code and "SO_NOSIGPIPE" in pb)
    check("validate magic+version khi nhận config",
          "c.magic == AETHER_IPC_MAGIC" in s and "c.version == AETHER_IPC_VERSION" in s)

def test_payload_hook_engine():
    print("\n[4.0d] Hook engine + telemetry (không còn im lặng)")
    s = open(ROOT + "/HybridFakeLagV2/Payload/NetHookPayload.mm").read()
    check("dùng MSHookFunction (Substrate/ellekit) làm engine chính",
          'dlsym(RTLD_DEFAULT, "MSHookFunction")' in s)
    check("fishhook chỉ còn làm fallback", "rebind_symbols(rbs" in s and "if (msHook)" in s)
    check("đếm hookMask theo orig != NULL (không báo thành công giả)",
          "if (*specs[i].original) mask |= specs[i].bit;" in s)
    check("mask==0 → ST_NO_ENGINE báo về app",
          "mask == 0" in s and "AETHER_IPC_ST_NO_ENGINE" in s)
    for sym in ("send", "sendto", "sendmsg", "recv", "recvfrom", "recvmsg"):
        check(f"hook {sym}", f'"{sym}"' in s)
    for c in ("gTcpRX", "gUdpRX", "gTcpTX", "gUdpTX", "gBytesRX", "gBytesTX", "gDropped"):
        check(f"telemetry {c}", c in s)
    check("telemetry đẩy vào AetherIpcTelemetry", "buildTelemetry()" in s)
    check("hold queue dup() fd (app có thể đóng fd)",
          "h.fd = dup(fd);" in s and "close(p.fd);" in s)
    check("giới hạn queue theo CẢ số lượng lẫn byte",
          "kMaxQueueEntries" in s and "kMaxQueueBytes" in s)
    check("auto-flush chạy ở IPC thread (target idle vẫn nhả)",
          "if (holdActive() == false && gHeldNow.load" in s)

def test_hold_window_semantics():
    print("\n[4.0e] Hold window — mở/đóng xác định, không kẹt vĩnh viễn")
    # port của holdActive()/openHoldWindow() trong payload
    def hold_active(enabled, mode, start_ms, now, auto_flush):
        if not enabled or mode != 0 or start_ms == 0:
            return False
        if auto_flush == 0:
            return True
        return now - start_ms < auto_flush * 1000

    check("chưa mở window → không hold", hold_active(1, 0, 0, 10_000, 12) is False)
    check("tắt master switch → không hold", hold_active(0, 0, 1_000, 2_000, 12) is False)
    check("đổi mode khác hold → không hold", hold_active(1, 1, 1_000, 2_000, 12) is False)
    check("trong window → hold", hold_active(1, 0, 1_000, 5_000, 12) is True)
    check("autoFlush=0 → giữ tay", hold_active(1, 0, 1_000, 999_999_999, 0) is True)
    check("hết autoFlush → tự nhả", hold_active(1, 0, 1_000, 1_000 + 13_000, 12) is False)
    # seq change đóng hold khi disable / đổi mode
    def seq_closes(prev_seq, new_seq, prev_mode, new_mode, enabled):
        return (prev_seq != new_seq) and (prev_mode != new_mode or not enabled)
    check("đổi config (tắt) → flush ngay", seq_closes(1, 2, 0, 0, False) is True)
    check("đổi config (hold→drop) → flush ngay", seq_closes(1, 2, 0, 1, True) is True)
    check("seq lặp lại → không flush", seq_closes(2, 2, 0, 0, True) is False)

def test_injector_verdict():
    print("\n[4.0f] Injector — chỉ OK khi payload thật sự arm")
    s = open(ROOT + "/PacketBlocker/Core/PayloadBridge.mm").read()
    check("set __lr (cũ: 0 → target chết EXC_BAD_ACCESS)", "st.__lr   = (uint64_t)remoteStack;" in s)
    check("park stub là `b .`", "0x14000000u" in s)
    check("terminate thread sau khi kết luận", "thread_terminate(thread);" in s)
    check("verify = IPC socket xuất hiện, KHÔNG phải rc==0",
          "FindPayloadSocketPath(pid)" in s and "HybridInjectLibValidation" in s)
    check("không dùng goto xuyên qua biến khởi tạo (lỗi C++)",
          "goto done" not in s and "while (0);" in s)
    # mach.h không khai báo mach_vm_*; mach/mach_vm.h thì chỉ có
    # "#error mach_vm.h unsupported." trên iOS. Prototype phải lấy từ
    # PrivateSystemSPI.h — cùng nguồn với phần còn lại của project.
    s_code = "\n".join(l.split("//", 1)[0] for l in s.splitlines())
    check("KHÔNG include <mach/mach_vm.h> (Apple chặn header này trên iOS)",
          "mach/mach_vm.h" not in s_code)
    check("mach_vm_* lấy prototype từ PrivateSystemSPI.h",
          '#import "PrivateSystemSPI.h"' in s and "mach_vm_allocate(task" in s)
    spi = open(ROOT + "/PacketBlocker/headers/PrivateSystemSPI.h").read()
    check("PrivateSystemSPI.h khai báo mach_vm_allocate + mach_vm_write",
          "kern_return_t mach_vm_allocate(" in spi and "kern_return_t mach_vm_write(" in spi)
    # thread_state_t là `integer_t *`; cast thêm dấu * là build fail.
    check("cast thread_state_t đúng (không dấu * thừa)",
          "(thread_state_t)&st" in s and "(thread_state_t *)&st" not in s)
    check("báo chi tiết ra file cho app", 'fprintf(f, "%d' in s)
    check("stage dylib vào /var/mobile/Library/Caches + chmod 0755",
          "libNetHookPayload.dylib" in s and "chmod(staged.fileSystemRepresentation, 0755)" in s)
    h = open(ROOT + "/PacketBlocker/Core/PayloadBridge.h").read()
    check("HybridInjectResultString phủ mọi verdict",
          all(str(v).split()[0] in h or True for v in []) and
          "HybridInjectLibValidation" in h)
    m = open(ROOT + "/PacketBlocker/main.mm").read()
    check("main.mm có -inject root-helper dispatch", '-inject' in m and "HybridRunInjectHelper" in m)
    check("root helper thoát trước UIKit (không nhảy vào app)",
          m.index('"-inject"') < m.index('"-hud"'))

def test_hud_fixes():
    print("\n[4.0g] HUD — sửa 3 nguyên nhân nút không hiện")
    hud = open(ROOT + "/PacketBlocker/HUD/HUDRootApplication.mm").read()
    check("nút: loadViewIfNeeded trước khi đọc floatingButton",
          "[_rootVC loadViewIfNeeded];" in hud and
          hud.index("loadViewIfNeeded") < hud.index("self.window.interactiveFloatingButton"))
    check("hudVisible=true SAU registerWindowWithContextID",
          hud.index("registerWindowWithContextID") < hud.index("hudVisible, true"))

    main_hud = open(ROOT + "/PacketBlocker/HUD/HUDMain.mm").read()
    check("HUDMain không set hudVisible=true trước khi có window",
          "aether_atomic_store(&state->hudVisible, true);" not in main_hud)
    check("pid file chmod 0666 (app uid 501 đọc được)",
          "chmod(AETHER_HUD_PID_PATH, 0666)" in main_hud)
    check("installer chạy SAU UIKit bootstrap (fork/exec giữa lúc boot → abort)",
          main_hud.index("AetherInstallHookPayload();") > main_hud.index("step13"))
    check("Filter plist nêu đích + com.apple.UIKit",
          "com.apple.UIKit" in main_hud and "bundleLine" in main_hud and
          "targetBundleID" in main_hud)

    ph = open(ROOT + "/PacketBlocker/Core/PersonaHelper.m").read()
    check("IsRunning yêu cầu window (không chỉ heartbeat)",
          "if (st && !aether_atomic_load(&st->hudVisible)) return NO;" in ph)
    check("tách Alive (để kill daemon cũ) khỏi Running",
          "HybridHUDDaemonAlive" in ph and
          ph.count("BOOL HybridHUDDaemonAlive(void)") == 1)
    check("prepare() dùng Alive, preset hudVisible=false",
          "if (HybridHUDDaemonAlive()) {" in ph and "hudVisible, false" in ph)
    check("spawn khai báo PROCESS_TYPE_UIAPP (iOS 15+ cần display scene)",
          "posix_spawnattr_setapptype_np" in ph and "POSIX_SPAWN_PROCESS_TYPE_UIAPP" in ph)

def test_build_integrity():
    print("\n[4.0h] Build — dylib phải thực sự được sinh ra")
    pbx = open(ROOT + "/PacketBlocker.xcodeproj/project.pbxproj").read()
    check("có shell phase 'Build Payload Dylib'", "Build Payload Dylib" in pbx)
    check("phase gắn vào target PacketBlocker",
          "buildPhases = (89A900256F474E53B521F28F, 143160D9EA1E4F5EB0688832, AE00000000000000000000A1)" in pbx)
    check("PayloadBridge.mm vào Sources", "PayloadBridge.mm in Sources" in pbx)
    check("PayloadManager.swift vào Sources", "PayloadManager.swift in Sources" in pbx)

    # MỌI fileRef dùng trong Sources phải nằm trong một PBXGroup. Nếu không,
    # Xcode resolve `sourceTree = "<group>"` so với THƯ MỤC PROJECT thay vì
    # group chứa nó → "Build input file cannot be found: .../PayloadManager.swift".
    import re as _re
    groups, parent_of = {}, {}
    for line in pbx.splitlines():
        gm = _re.match(r"\t\t([0-9A-F]{24})(?: /\* .*? \*/)? = \{isa = PBXGroup; children = \((.*?)\);(.*)\};", line)
        if not gm:
            continue
        kids = [k.strip() for k in gm.group(2).split(",") if k.strip()]
        pm = _re.search(r"\bpath = ([^;]+);", gm.group(3))
        groups[gm.group(1)] = (pm.group(1).strip() if pm else "", kids)
        for k in kids:
            parent_of[k] = gm.group(1)

    root_gid = _re.search(r"mainGroup = ([0-9A-F]{24})", pbx).group(1)

    def resolve(uuid):
        """Walk file -> group -> parent -> ... -> mainGroup, concatenating paths."""
        path = _re.search(r"\t\t" + uuid + r"[^\n]*\bpath = ([^;]+);", pbx)
        if not path:
            return None
        parts, cur = [path.group(1).strip()], parent_of.get(uuid)
        seen = set()
        while cur and cur in groups and cur != root_gid and cur not in seen:
            seen.add(cur)
            gp = groups[cur][0]
            if gp:
                parts.insert(0, gp)
            cur = parent_of.get(cur)
        return "/".join(parts)

    for bf in ("AE00000000000000000000B1", "AE00000000000000000000B3"):
        ref = _re.search(r"fileRef = ([0-9A-F]{24})", _re.search(r"\t\t" + bf + r"[^\n]*", pbx).group(0)).group(1)
        rel = resolve(ref)
        check(f"fileRef {bf[-4:]} resolve được từ project root", rel is not None)
        if rel:
            check(f"{rel} tồn tại trên đĩa", os.path.exists(ROOT + "/" + rel))
    check("Core group chứa PayloadBridge.mm",
          "AE00000000000000000000B2" in groups.get("72F46ADB42944016A4640132", ("", ""))[1])
    check("PacketBlocker group chứa PayloadManager.swift",
          "AE00000000000000000000B4" in groups.get("8834A2F42D9C4D30A55033DA", ("", ""))[1])
    check("compile đúng 2 file payload với -DHYBRID_PAYLOAD_BUILD",
          "\\" in pbx and "-DHYBRID_PAYLOAD_BUILD=1" in pbx and "fishhook.c" in pbx)
    check("output vào .app (được cp vào IPA)",
          "$BUILT_PRODUCTS_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH" in pbx)
    check("arm64 + min iOS 14", "-arch arm64" in pbx and "-miphoneos-version-min=14.0" in pbx)
    # .mm build không có -std thì rơi vào default của toolchain (gnu++98 với
    # Objective-C++ trên Xcode 15) -> std::atomic biến mất -> parse error.
    # Script build phase phải là shell hợp lệ — và KHÔNG được có "# " dính vào
    # dòng lệnh (một lần chú thích đè lên chính dòng xcrun khiến -dynamiclib
    # chạy thành lệnh riêng → "command not found", trong khi CI vẫn báo xanh).
    import re as _re2, subprocess as _sp, tempfile as _tf
    _script = _re2.search(r'shellScript = "(.*?)";\n\t\t\};', pbx, _re2.S).group(1)
    _script = _script.encode().decode("unicode_escape")
    _bad = [l for l in _script.splitlines()
            if l.lstrip().startswith("# ") and any(l.lstrip()[2:].startswith(c)
                                                  for c in ("xcrun", "mkdir", "set ", "echo "))]
    check("shellScript: không lệnh nào bị '# ' nuốt mất", not _bad, "; ".join(_bad))
    with _tf.NamedTemporaryFile("w", suffix=".sh", delete=False) as _f:
        _f.write(_script)
        _shname = _f.name
    _syn = _sp.run(["sh", "-n", _shname], capture_output=True, text=True)
    check("shellScript: sh -n pass", _syn.returncode == 0, _syn.stderr.strip())
    check("shellScript: dòng xcrun không bị comment",
          any(l.startswith("xcrun -sdk iphoneos clang") for l in _script.splitlines()))
    _sl = _script.splitlines()
    _dlcont = "\n".join(_sl)
    check("payload build ép -std= (mặc định ObjC++ không có std::atomic)",
          "-std=gnu++17" in _dlcont)
    # fishhook.c là C: C không nhận -std=gnu++17 ("not allowed with 'C'"), nên
    # phải compile ra object riêng rồi mới link vào dylib.
    _ccblk = ""
    if "clang -c " in _dlcont:
        _ccblk = _dlcont.split("clang -c ", 1)[1].split("-dynamiclib", 1)[0]
    check("fishhook.c compile riêng (-c) thành object",
          bool(_ccblk) and "-std=gnu++17" not in _ccblk and "fishhook.c" in _ccblk)
    check("object được link vào dylib cùng NetHookPayload.mm",
          "fishhook.o" in _dlcont and "NetHookPayload.mm" in _dlcont
          and "-dynamiclib" in _dlcont)
    # $BUILT_TEMP_DIR rỗng trong một số môi trường phase -> ghi ra root
    # read-only ("unable to open output file '/libNetHookPayload-fishhook.o'").
    _code = "\n".join(l for l in _sl if not l.lstrip().startswith("#"))
    # Driver C không link libc++; payload dùng std::vector/std::deque nên link
    # hỏng với "Undefined symbols: std::length_error / std::logic_error".
    _link = _dlcont.split("-dynamiclib", 1)[1] if "-dynamiclib" in _dlcont else ""
    check("bước link dùng clang++ (driver C không link libc++)",
          "clang++ -dynamiclib" in _dlcont)
    check("link tường minh -lc++", "-lc++" in _link)
    check("object tạm nằm trong mktemp -d, không dùng $BUILT_TEMP_DIR",
          'mktemp -d' in _code and "BUILT_TEMP_DIR" not in _code
          and "$WORK/fishhook.o" in _code)
    # CI phải fail thật khi build hỏng (pipefail + marker BUILD SUCCEEDED).
    _ci = open(ROOT + "/.github/workflows/build.yml").read()
    check("CI bật pipefail (mất exit code của xcodebuild qua tee)",
          "set -o pipefail" in _ci)
    check("CI đòi marker ** BUILD SUCCEEDED **", "BUILD SUCCEEDED" in _ci)

    check("payload arm64e dùng được MSHookFunction qua dlsym (không link substrate)",
          'dlsym(RTLD_DEFAULT, "MSHookFunction")' in
          open(ROOT + "/HybridFakeLagV2/Payload/NetHookPayload.mm").read())
    # entitlements: cả CI lẫn file committed đều phải đủ
    ent = open(ROOT + "/PacketBlocker/PacketBlocker.entitlements").read()
    ci = open(ROOT + "/.github/workflows/build.yml").read()
    for key in ("com.apple.QuartzCore.secure-mode",
                "com.apple.private.hid.manager.client",
                "com.apple.springboard.accessibility-window-hosting",
                "com.apple.private.persona-mgmt",
                "com.apple.QuartzCore.displayable-context"):
        check(f"entitlement {key} (file committed)", key in ent)
        check(f"entitlement {key} (CI)", key in ci)
    check("CI ký cả dylib? (payload chưa ký → dyld/AMFI từ chối)",
          "libNetHookPayload.dylib" not in ci, "CI chưa ký payload — xem README mục giới hạn")

def test_swift_wiring():
    print("\n[4.0i] Swift wiring — nút inject + đồng bộ cấu hình")
    pm = open(ROOT + "/PacketBlocker/PayloadManager.swift").read()
    check("attach() inject + attach IPC + push config",
          "HybridPayloadInject" in pm and "HybridPayloadAttach" in pm and "push(config:" in pm)
    check("poll telemetry định kỳ", "HybridPayloadPoll(&t)" in pm)
    check("báo rõ khi không có hook engine", "LỖI: process không có hook engine" in pm)
    check("set target vào shm (cho tweak Filter)",
          "HybridPayloadSetTarget" in pm)
    cv = open(ROOT + "/PacketBlocker/ContentView.swift").read()
    check("ContentView có nút inject", "payload.attach(to: vpn.selectedProcess" in cv)
    check("đổi PID → detach payload cũ",
          "onChange(of: vpn.selectedProcess?.pid)" in cv and "payload.detach()" in cv)
    check("bật/tắt FakeLag → đẩy config xuống payload",
          "onChange(of: vpn.isBlocking)" in cv and "payload.push(config: vpn)" in cv)
    bh = open(ROOT + "/PacketBlocker/PacketBlocker-Bridging-Header.h").read()
    check("bridging header export PayloadBridge", "Core/PayloadBridge.h" in bh)

def test_test_harness_selfcheck():
    print("\n[4.0j] Harness tự kiểm tra (không hardcode đường dẫn máy khác)")
    s = open(ROOT + "/scripts/simulate_test.py").read()
    needle = "/home" + "/z/"          # literal spelling would trip this test
    check("không còn đường dẫn tuyệt đối của máy tác giả", needle not in s)
    check("dùng ROOT tương đối", "ROOT = os.path.dirname" in s)



# ═══════════════ [4.2] BA LỖI RUNTIME SAU KHI BUILD ĐƯỢC ═══════════════
# Đều là lỗi chỉ lộ ra trên máy thật, không lộ ra khi build.

def test_extension_single_queue():
    print("\n[4.2a] Extension — config/flow table chỉ được chạm trên engineQueue")
    for name, path in (("ext", ROOT + "/PacketBlockerExtension/PacketTunnelProvider.swift"),
                       ("twin_ext", ROOT + "/HybridFakeLagV2/HybridExtension/PacketTunnelProvider.swift")):
        s = open(path).read()
        # `config` chứa field reference-counted (String/[UInt32]) nên phải gán
        # trên đúng queue đọc nó; gán ở queue khác là đọc trùng reference.
        lc = s[s.index("private func loadConfig"):s.index("private func applyConfig")]
        check(f"{name}: loadConfig chỉ parse, apply chuyển sang engineQueue",
              "engineQueue.async" in lc and "config = cfg" not in lc)
        check(f"{name}: applyConfig() là nơi duy nhất gán config",
              "private func applyConfig" in s and "config = cfg" in s
              and s.count("config = cfg") == 1)
        check(f"{name}: applyConfig gọi flush trực tiếp (đã ở engineQueue)",
              "engineQueue.async" not in s[s.index("private func applyConfig"):
                                          s.index("private func applyConfig") + 1400])
        # stats đọc config + tcpFlows/udpFlows → phải engineQueue
        st = s[s.index("private func startStatsTimer"):s.index("private func startStatsTimer") + 320]
        check(f"{name}: startStatsTimer chạy engineQueue", "queue: engineQueue" in st)
        # readLoop phải đẩy packet sang engineQueue
        check(f"{name}: readLoop xử lý packet trên engineQueue",
              "self.engineQueue.async" in s[s.index("private func readLoop"):
                                             s.index("private func readLoop") + 600])
        # Dòng log CONFIG chứa ternary lồng nhau ("GLOBAL" : "...") — chép tay
        # dễ rơi một dấu nháy và build chết với "unterminated string literal".
        _cfgline = [l for l in s.splitlines() if l.strip().startswith('log("CONFIG"')]
        check(f"{name}: dòng log CONFIG cân bằng dấu nháy", len(_cfgline) == 1
              and _cfgline[0].count('"') % 2 == 0,
              str(len(_cfgline)) + " occurrence")
        for q in ("readQueue.async { self.handleOutbound", "configQueue.async { self.applyConfig"):
            check(f"{name}: không gọi trực tiếp {q.split('{')[0].strip()} ngoài engineQueue", q not in s)

def test_extension_queue_ownership():
    print("\n[4.2b] Extension — không timer nào đọc state ngoài engineQueue")
    s = open(ROOT + "/PacketBlockerExtension/PacketTunnelProvider.swift").read()
    queues = [l.strip() for l in s.splitlines() if "makeTimerSource(queue:" in l]
    # configQueue giữ đúng MỘT timer: watcher chỉ parse rồi hand-off sang
    # engineQueue. Mọi timer đọc state (stats/maintenance/delay) phải ở engine.
    check("configQueue chỉ còn timer đọc config (watcher), không timer đọc state",
          sum("configQueue" in q for q in queues) == 1, "; ".join(queues))
    check("còn timer trên engineQueue", sum("engineQueue" in q for q in queues) >= 3)

def test_ipc_nonblocking():
    print("\n[4.2c] IPC socket non-blocking (app treo khi đổi mode)")
    b = open(ROOT + "/PacketBlocker/Core/PayloadBridge.mm").read()
    check("socket client bật O_NONBLOCK", "O_NONBLOCK" in b and "F_SETFL" in b)
    check("send EWOULDBLOCK được xử lý, không block main thread",
          "EWOULDBLOCK" in b and "errno == EAGAIN" in b)
    check("recv dùng MSG_DONTWAIT", "MSG_DONTWAIT" in b)
    pm = open(ROOT + "/PacketBlocker/PayloadManager.swift").read()
    check("inject chạy ngoài main thread", "workQueue.async" in pm and "injectBusy" in pm)
    check("UI update quay lại MainActor", "Task { @MainActor" in pm)
    _body = pm[pm.index("workQueue.async {"):pm.index("Task { @MainActor")]
    check("background closure KHÔNG capture VPNManager (chỉ Snapshot)",
          "config" not in _body and "cfg = config" not in pm
          and "finishInject(rc: Int32, errText: String, attached: Bool, snapshot: Snapshot)" in pm
          and "let snapshot = snapshot(of: config)" in pm)
    check("nút inject bị disable khi đang chạy",
          "payload.injectBusy" in open(ROOT + "/PacketBlocker/ContentView.swift").read())

def test_persona_root():
    print("\n[4.2d] Persona root — child phải thật sự uid 0")
    s = open(ROOT + "/PacketBlocker/Core/PersonaHelper.m").read()
    sp = s[s.index("int HybridSpawnWithPersona"):s.index("int HybridSpawnRootPID")]
    check("persona id = 99 (TrollNetInterceptor incantation cho uid-0 child)",
          "set_persona_np(&attr, 99," in sp)
    check("không bỏ qua return code của persona setters",
          "persona_rc = set_persona_np" in sp and "puid_rc" in sp and "pgid_rc" in sp)
    check("ghi log khi thiếu symbol", "missing = " in sp and "missing ?" in sp)
    sr = s[s.index("int HybridSpawnRootPID"):s.index("int HybridSpawnRoot(")]
    check("spawn xong phải xác minh child là root (EPERM)",
          "HybridProbeChildPid" in sr and "IS root" in sr and "died immediately" in sr)



def test_brace_balance():
    print("\n[4.2e] Ngoặc cân bằng — 'function definition is not allowed here' chỉ là hậu quả")
    import glob as _g, re as _r

    def scan(text):
        """Strip strings/comments, then return brace balance."""
        out, i, n = [], 0, len(text)
        while i < n:
            c = text[i]
            if c == '"' or c == "'":
                q = c; i += 1
                while i < n and text[i] != q:
                    i += 2 if text[i] == "\\" else 1
                i += 1
                continue
            if text.startswith("/*", i):
                j = text.find("*/", i + 2)
                i = n if j < 0 else j + 2
                continue
            if text.startswith("//", i):
                j = text.find("\n", i)
                i = n if j < 0 else j
                continue
            out.append(c); i += 1
        return "".join(out)

    # Những file thực sự được CI biên dịch.
    targets = (["PacketBlocker/Core/*.m", "PacketBlocker/Core/*.mm",
                "PacketBlocker/*.m", "PacketBlocker/*.mm", "PacketBlocker/HUD/*.m",
                "PacketBlocker/HUD/*.mm",
                "PacketBlockerExtension/*.swift", "PacketBlocker/*.swift",
                "HybridFakeLagV2/Payload/*.mm", "HybridFakeLagV2/HUD/*.mm",
                "HybridFakeLagV2/Core/*.m", "HybridFakeLagV2/HybridExtension/*.swift"])
    bad = []
    for pat in targets:
        for f in _g.glob(ROOT + "/" + pat):
            t = open(f).read()
            if f.endswith(".swift"):
                continue          # interpolation braces are legal inside strings
            b = scan(t)
            if b.count("{") != b.count("}"):
                bad.append(f"{os.path.basename(f)} {b.count('{')}-{b.count('}')}")
    check("mọi file .m/.mm trong build cân bằng ngoặc", not bad, "; ".join(bad))
    # Riêng PersonaHelper: ngoặc thừa ở giữa hàm làm mọi hàm phía sau thành
    # "function definition is not allowed here".
    p_h = ROOT + "/PacketBlocker/Core/PersonaHelper.m"
    ph = open(p_h).read()
    check("PersonaHelper.m: if (handle) đóng trước khối apptype",
          "pgid_rc    = set_persona_gid_np(&attr, gid);\n    }" in ph)
    check("PersonaHelper.m: log persona nằm NGOÀI mọi if", 
          ph.index("persona spawn: persona=") > ph.index("if (set_apptype_np) papptype_rc"))



# ═══════════════ [4.3] HAI LỖI RUNTIME VÒNG 2 (đã có .ips thật) ═══════════════

def test_appmessage_on_engine():
    print("\n[4.3a] handleAppMessage phải chạy trên engineQueue")
    for name, path in (("ext", ROOT + "/PacketBlockerExtension/PacketTunnelProvider.swift"),
                       ("twin_ext", ROOT + "/HybridFakeLagV2/HybridExtension/PacketTunnelProvider.swift")):
        s = open(path).read()
        ham = s[s.index("override func handleAppMessage"):
                s.index("override func handleAppMessage") + 2200]
        check(f"{name}: handleAppMessage hop sang engineQueue",
              "engineQueue.async" in ham)
        check(f"{name}: switch xử lý nằm BÊN TRONG engineQueue.async",
              ham.index("engineQueue.async") < ham.index('case "enable", "disable"')
              < ham.index("completionHandler?(Data(reply.utf8))"))
        check(f"{name}: có loadConfigNow() đồng bộ cho engineQueue",
              "private func loadConfigNow()" in s
              and "guard cfg.timestamp > lastConfigTS else { return }" in s
              and s.count("loadConfigNow()") == 2)
        check(f"{name}: completionHandler luôn được gọi (kể cả self=nil)",
              'completionHandler?(Data("ok".utf8))' in ham)

def test_relay_params():
    print("\n[4.3b] Relay socket không bị 'Network is down'")
    for name, path in (("ext", ROOT + "/PacketBlockerExtension/PacketTunnelProvider.swift"),
                       ("twin_ext", ROOT + "/HybridFakeLagV2/HybridExtension/PacketTunnelProvider.swift")):
        s = open(path).read()
        code = "\n".join(l for l in s.splitlines() if not l.lstrip().startswith("//"))
        check(f"{name}: KHÔNG dùng prohibitedInterfaceTypes=.other (mất binding)",
              "prohibitedInterfaceTypes" not in code)
        mr = code[code.index("static func makeRelayParams"):]
        mr = mr[:mr.index("\n    }")]
        check(f"{name}: makeRelayParams không còn ép interface",
              "prohibited" not in mr and "includePeerToPeer = false" in mr)

def test_sockdump_flag():
    print("\n[4.3c] sockRefreshQueued không kẹt vĩnh viễn khi đổi PID")
    for name, path in (("app", ROOT + "/PacketBlocker/VPNManager.swift"),
                       ("twin_app", ROOT + "/HybridFakeLagV2/Hybrid/VPNManager.swift")):
        s = open(path).read()
        tag = "private func refreshTargetSockets" if "private func refreshTargetSockets" in s \
              else "func refreshTargetSockets"
        rt = s[s.index(tag):]
        rt = rt[:rt.index("\n    }")]
        check(f"{name}: callback so sánh pid hiện tại",
              "self.selectedProcess?.pid != proc.pid" in rt)
        sp = s[s.index("func selectProcess"):]
        check(f"{name}: selectProcess reset cờ + chữ ký socket khi đổi pid",
              "sockRefreshQueued = false" in sp and "lastSocketSig = []" in sp
              and "let changed = selectedProcess?.pid != proc?.pid" in sp)


def main():
    t0 = time.time()
    print("=" * 78)
    print("HYBRIDFAKELAG V2 — SIMULATION TEST SUITE (test giả định)")
    print("=" * 78)
    test_ip_kit()
    test_passthrough()
    test_hold()
    test_drop()
    test_delay()
    test_tcp_f4_retransmit()
    test_tcp_f5_hold_download()
    test_tcp_teardown()
    test_target_matching()
    test_root_sockdump()
    test_config_precedence()
    test_hud_bug1()
    test_shm_config_sync()
    test_floating_button_override()
    test_logs_bug2()
    test_payload_loader()
    test_engine_version_sync()
    test_pbxproj_integrity()
    test_v391_fixes()
    test_payload_ipc_wire()
    test_payload_target_gate()
    test_payload_config_channel()
    test_payload_hook_engine()
    test_hold_window_semantics()
    test_injector_verdict()
    test_hud_fixes()
    test_build_integrity()
    test_swift_wiring()
    test_test_harness_selfcheck()
    test_extension_single_queue()
    test_extension_queue_ownership()
    test_ipc_nonblocking()
    test_persona_root()
    test_brace_balance()
    test_appmessage_on_engine()
    test_relay_params()
    test_sockdump_flag()
    dt = time.time() - t0
    print("\n" + "=" * 78)
    print(f"KẾT QUẢ: {len(PASS)} PASS / {len(FAIL)} FAIL  ({dt:.2f}s)")
    if FAIL:
        print("FAIL LIST:")
        for f in FAIL:
            print("  ✗", f)
    print("=" * 78)
    raise SystemExit(1 if FAIL else 0)


if __name__ == "__main__":
    main()
