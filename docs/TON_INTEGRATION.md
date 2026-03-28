# TON Payment Integration — Design Overview

> Status: Specification (pre-implementation)
> Branch: `ton` — all TON features live here; `main` tracks upstream bitchat

---

## What This Fork Adds

This fork of [bitchat](https://github.com/permissionlesstech/bitchat) adds **TON blockchain payment propagation** over the existing Bluetooth mesh network. No changes to the core BLE mesh, Noise XX encryption, or flood routing — TON transactions ride as new message types in the existing `BitchatPacket` payload.

### Design Principles

1. **Zero modification to BLE core** — `BLEService.swift` and the Noise session handshake are untouched.
2. **TON as payload** — A signed TON external message (BOC) is just bytes in `BitchatPacket.payload`.
3. **Native TON replay protection** — TON transactions embed `seqno` (double-spend prevention) and `valid_until` (expiry). No additional mesh-layer coordination needed.
4. **Offline-first** — The sender signs the transaction before going offline. Gateways broadcast when internet returns.
5. **Public Domain** — Same license as upstream bitchat; no restrictions.

---

## Use Case

```
[Alice — offline iPhone]
  Wants to pay Bob 5 TON at a concert with no internet

  1. Alice opens TONPayView, enters Bob's address + 5 TON
  2. App fetches current seqno (must be done while online, or uses cached seqno)
  3. App signs the TON external message → BOC bytes (~200-400 bytes)
  4. BOC is wrapped in BitchatPacket(type: .tonTxAnnounce) and broadcast over BLE mesh

[Relay iPhones — offline]
  Standard bitchat flood routing: TTL--, dedup via seen-set, rebroadcast

[Gateway iPhone — has internet]
  Receives .tonTxAnnounce → calls TonCenter API sendBoc
  On success: broadcasts BitchatPacket(type: .tonTxAck, payload: txHash)
  On failure: broadcasts BitchatPacket(type: .tonTxReject, payload: reason)

[Alice — receives ACK over BLE mesh]
  UI updates: "Payment confirmed ✓"
```

---

## Repository Structure

```
main         ← upstream bitchat (sync with permissionlesstech/bitchat)
ton          ← TON integration branch (base for all TON PRs)
ton-spec     ← this branch: spec docs only → PR to ton
ton-wallet   ← (future) TONWallet.swift implementation → PR to ton
ton-protocol ← (future) BitchatProtocol + BinaryProtocol extension → PR to ton
ton-gateway  ← (future) TONCenterGateway.swift → PR to ton
ton-ui       ← (future) TONPayView.swift → PR to ton
```

### PR Flow

```
ton-spec ──────────────────────────────────────────┐
ton-wallet ──────────────────────────────────────── ▼
ton-protocol ─────────────────────────────────── [ton branch]
ton-gateway ─────────────────────────────────────── ▲
ton-ui ────────────────────────────────────────────┘
```

Each feature branch is reviewed independently before merging into `ton`. The `ton` branch is never merged into `main` (which stays clean for upstream sync).

---

## New Files (all under `bitchat/`)

| File | Purpose |
|---|---|
| `Models/TONTransaction.swift` | Value types: address, amount, BOC, seqno, valid_until, status |
| `Services/TONWallet.swift` | Keypair generation, BOC signing, Keychain storage |
| `Services/TONCenterGateway.swift` | TonCenter JSON-RPC client: `sendBoc`, `getSeqno` |
| `Views/TONPayView.swift` | SwiftUI payment UI: address input, amount, QR scan |

## Modified Files

| File | Change |
|---|---|
| `Protocols/BitchatProtocol.swift` | Add `.tonTxAnnounce`, `.tonTxAck`, `.tonTxReject` to `MessageType` |
| `Protocols/BinaryProtocol.swift` | Add TON BOC serialization/deserialization for new message types |
| `Services/MessageRouter.swift` | Route `.tonTxAnnounce` to `TONCenterGateway` when online |
| `Views/ContentView.swift` | Add "Send TON" button navigating to `TONPayView` |

---

## Dependencies

### TON SDK

**Recommended: `ton-sdk-swift`**
- URL: `https://github.com/nerzh/ton-sdk-swift`
- Version: `>= 0.3.0`
- Reason: Fine-grained BOC (Bag of Cells) control — `CellBuilder`, `Boc.serialize()`, `Boc.deserialize()`
- Added to `Package.swift` (or via Xcode SPM)

No other new dependencies. TonCenter is accessed via `URLSession` (standard library).

---

## BOC Size Budget

BLE MTU is typically 512 bytes. BitchatPacket overhead is ~89 bytes (header + padding). TON BOC sizes:

| Transaction type | Typical BOC size | Fits in single BLE packet? |
|---|---|---|
| Native TON transfer | 170–250 bytes | Yes (512 MTU) |
| Jetton transfer | 280–420 bytes | Yes |
| Complex contract call | 500–800 bytes | Needs BLE fragmentation |

Fragmentation uses bitchat's existing packet fragmentation mechanism (type `0xF0 FRAGMENT` in `BitchatProtocol.swift`).

---

## Security Considerations

- **Signing happens on-device**: Private key never leaves Keychain. TON transaction is signed before entering the mesh.
- **Mesh does not validate BOC**: Relay nodes forward opaque bytes. Only the gateway (with internet access) submits to TON and can detect invalid signatures.
- **Replay protection**: TON's `seqno` + `valid_until` make replays impossible. Expired transactions (past `valid_until`) are silently dropped.
- **Gateway trust**: Any node with internet can act as gateway. The sender verifies the ACK by checking the transaction hash on TonCenter directly when back online.
- **No new key material**: TON keypair is separate from the Noise XX keypair used for BLE mesh encryption.

---

## Protocol Reference

Full wire format specification: [`meshpay-ton/SPEC.md`](https://github.com/Masashi-Ono0611/meshpay-ton/blob/main/SPEC.md)

The TypeScript reference implementation at `Masashi-Ono0611/meshpay-ton` defines the canonical protocol. This Swift implementation follows the same design but adapts to bitchat's `BitchatPacket` format instead of the standalone `MeshFrame` format.
