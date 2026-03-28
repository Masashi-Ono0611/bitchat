# TON Payment — Architecture & Design Decisions

> Ported and adapted from the meshpay-ton TypeScript reference implementation.
> Original: [Masashi-Ono0611/meshpay-ton](https://github.com/Masashi-Ono0611/meshpay-ton)
> Last updated: 2026-03-28

---

## Why bitchat Hardfork (not TMA / Web App)?

| Approach | BLE Peripheral | iOS Web Bluetooth | Cross-platform |
|---|---|---|---|
| TMA (Telegram Mini App) | ❌ Not supported | ❌ Not supported | Limited |
| Web App (React Native) | ❌ iOS limitation | ❌ Not supported | Limited |
| **bitchat hardfork (Swift)** | ✅ CoreBluetooth | ✅ (native) | ✅ Kotlin port |

iOS requires a **native app** (CoreBluetooth) to act as a BLE Peripheral. This is the only viable approach for a mesh node that can both send and relay packets.

---

## Why Flood Routing (not AODV / DSDV / PROPHET)?

For Phase 1, **epidemic/flood routing** is chosen because:

1. **Simplicity**: No routing table maintenance, no topology knowledge required
2. **Robustness**: Works correctly regardless of network size or topology
3. **BOC is small**: At ~200-400 bytes, bandwidth cost of flooding is acceptable (expected: 1-50 tx/hour in typical use)
4. **Already implemented**: bitchat's existing `BLEService` flood routing handles TON packets transparently

Flood routing weakness (bandwidth with high tx volume) is mitigated by:
- Per-sender rate limiting (planned Phase 2)
- TON's `valid_until` ensuring rapid cleanup of expired frames
- Low expected transaction rate in target scenarios

**Future**: PROPHET routing (Probabilistic ROuting Protocol using History of Encounters) will be evaluated when network scale increases.

---

## TON Replay Protection: Why MeshPay Works Without Coordination

Unlike Bitcoin (where UTXO selection requires knowing unspent outputs), TON's account-based model with `seqno` simplifies offline signing:

```
ExternalMessage {
  seqno:       uint32  // must match current account seqno
  valid_until: uint32  // Unix timestamp; message rejected after this time
}
```

Key properties:
- **No double-spend at protocol level**: Two identical signed messages propagating in the mesh can only result in ONE on-chain transaction. The second broadcast is rejected with `SEQNO_MISMATCH`.
- **Automatic expiry**: `valid_until` provides TTL semantics natively — no mesh-layer coordination needed.
- **No relay validation**: Relay nodes forward without needing to validate TON state.

**Edge case**: If the user signs a MeshPay tx offline, then submits another tx via a different path (brief internet connectivity), the seqno increments and the MeshPay tx fails with `SEQNO_MISMATCH`. The UI should warn against submitting other txs while a MeshPay tx is pending.

---

## BOC Size Budget

TON signed external messages are serialized as BOC (Bag of Cells):

| Transaction type | Typical BOC size |
|---|---|
| TON native transfer (no comment) | ~170-200 bytes |
| TON native transfer (with comment) | ~200-280 bytes |
| Jetton (USDT) transfer | ~280-420 bytes |
| NFT transfer | ~350-500 bytes |
| Smart contract call (complex) | ~500-2000 bytes |

BLE GATT MTU (negotiated): typically 185-512 bytes on modern devices.

**Phase 1 limit**: 800 bytes (`TONConfig.maxBOCSize`). This covers all native TON transfers and most Jetton transfers in a single BLE write after MTU negotiation. Fragmentation is deferred to Phase 2.

---

## Gateway Node: Trustless by Construction

The design explicitly does not require trusting the gateway:

1. **BOC signing happens at sender**: Private key never leaves sender device
2. **Modification impossible**: Any bit flip in the BOC breaks the Ed25519 signature; TON node rejects malformed messages
3. **Drop detectable**: Sender uses `valid_until` as a deadline; if ACK not received before expiry, the tx never executed
4. **Multiple gateways**: Any gateway receiving the frame will attempt broadcast; suppression requires all gateways in range to collude

This is equivalent to the Bitcoin mempool trust model: you don't trust any specific node to broadcast your transaction; you just need one honest node.

---

## Node.js Gateway (Raspberry Pi / PC)

The [meshpay-ton TypeScript implementation](https://github.com/Masashi-Ono0611/meshpay-ton) provides a Node.js gateway that can run on Raspberry Pi or any PC with a BLE adapter. This is an alternative to using an iPhone as gateway.

```
packages/core       — MeshFrame codec + TON BOC builder (TypeScript)
packages/node       — @abandonware/noble BLE transport for Node.js
```

The TypeScript gateway is compatible with the bitchat hardfork BLE mesh because:
- Same MessageType values (`0x30-0x32`)
- Same binary payload encoding (see `docs/PROTOCOL_EXTENSION.md`)
- Same flood routing / TTL semantics

**Setup**: See the meshpay-ton repository for Node.js gateway documentation.

---

## Phase 1 Scope Restrictions (Intentional)

Phase 1 deliberately excludes:

- **Complex contract calls**: BOC > 800 bytes requires multi-fragment assembly. Defer to Phase 2.
- **Jetton transfers over LoRa**: LoRa's 51-255 byte payload is too small. BLE-only for Phase 1.
- **Directed ACK routing**: Phase 1 ACKs are flooded; directed routing requires sender identity storage (Phase 2).
- **Offline seqno coordination**: Users must manually avoid overlapping transactions. Phase 2 will explore seqno reservation.
- **Mnemonic export UI**: The wallet mnemonic is in Keychain but not exportable in Phase 1 UI.
