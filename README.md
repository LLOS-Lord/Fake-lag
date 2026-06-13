# PacketBlocker - TrollStore Edition

A simple iOS app that blocks all network traffic using a Personal VPN with Packet Tunnel Provider.

## Features

- ✅ Connect VPN once
- 🔒 Toggle traffic blocking ON/OFF without disconnecting VPN
- 🚫 When blocking is enabled, ALL internet traffic is dropped
- 🛡️ **New**: Block Network Simulate configuration (`/var/mobile/Library/Preferences/com.apple.network.prefPaneSimulate`)
- 📦 Install via TrollStore (no jailbreak required for compatible iOS versions)

## Requirements

- iOS 14.0 - 17.x (device dependent)
- TrollStore installed
- Compatible with arm64/arm64e devices

## How It Works

1. **Connect VPN** - Establishes a Personal VPN connection
2. **Enable Blocking** - Routes all traffic through TUN interface and drops packets
3. **Disable Blocking** - Removes routing rules, traffic flows normally
4. **Disconnect VPN** - Stops the VPN service

## Installation

1. Download the IPA from GitHub Actions artifacts
2. Transfer to your device
3. Open with TrollStore
4. Tap "Install"

## Building

This project uses GitHub Actions to automatically build unsigned IPAs:

1. Fork/clone this repository
2. Update Bundle IDs in entitlements files
3. Push to GitHub
4. Download IPA from Actions tab

## Technical Details

- Built with SwiftUI
- Uses NetworkExtension framework
- Packet Tunnel Provider for traffic interception
- Fake signed with ldid for TrollStore compatibility
