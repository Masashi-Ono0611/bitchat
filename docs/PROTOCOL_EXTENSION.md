# Protocol Extension — TON Message Types

> How TON transactions map to BitchatPacket without breaking existing bitchat compatibility.

---

## BitchatPacket Format (existing)

```
Header (fixed 13 bytes):
  version       (1 byte, uint8)
  type          (1 byte, MessageType)
  ttl           (1 byte, uint8, decremented each hop)
  timestamp     (4 bytes, uint32 BE, Unix seconds)
  flags         (1 byte)
  length        (2 bytes, uint16 BE, payload length)
  senderID      (8 bytes)

Optional:
  recipientID   (8 bytes, present when flags.hasRecipient == 1)

Variable:
  payload       (length bytes)

Optional:
  signature     (64 bytes, Ed25519, present when flags.hasSig == 1)

Padding to nearest block: 256 / 512 / 1024 / 2048 bytes
```

---

## New MessageType Values

Add to `MessageType` enum in `BitchatProtocol.swift`:

```swift
// TON Payment types (0x30–0x3F reserved for this fork)
case tonTxAnnounce  = 0x30   // Signed TON transaction BOC
case tonTxAck       = 0x31   // Transaction confirmed on TON
case tonTxReject    = 0x32   // Transaction rejected
```

Values `0x30`–`0x3F` are in the unassigned range of the current bitchat MessageType enum, avoiding conflicts with upstream additions in the lower ranges.

---

## tonTxAnnounce Payload

Payload structure when `type == .tonTxAnnounce`:

```
Offset  Size  Field
───────────────────────────────────────────────────
0       4     valid_until   (uint32 BE, Unix seconds)
4       N     boc           (signed TON external message, raw bytes)
```

### Encoding (`BinaryProtocol.swift`)

```swift
static func encodeTonTxAnnounce(validUntil: UInt32, boc: Data) -> Data {
    var data = Data(capacity: 4 + boc.count)
    var validUntilBE = validUntil.bigEndian
    data.append(contentsOf: withUnsafeBytes(of: &validUntilBE, Array.init))
    data.append(boc)
    return data
}

static func decodeTonTxAnnounce(payload: Data) -> (validUntil: UInt32, boc: Data)? {
    guard payload.count >= 4 else { return nil }
    let validUntil = payload[0..<4].withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
    let boc = payload[4...]
    guard !boc.isEmpty else { return nil }
    return (validUntil, Data(boc))
}
```

### TTL

Default TTL for `.tonTxAnnounce`: **16 hops** (same as bitchat channel messages).

---

## tonTxAck Payload

Payload structure when `type == .tonTxAck`:

```
Offset  Size  Field
───────────────────────────────────────────────────
0       32    tx_id         (SHA-256 of original tonTxAnnounce payload)
32      2     block_id_len  (uint16 BE)
34      N     block_id      (UTF-8 string, TON block identifier)
```

### Encoding

```swift
static func encodeTonTxAck(txId: Data, blockId: String) -> Data {
    let blockIdData = blockId.data(using: .utf8) ?? Data()
    var data = Data(capacity: 32 + 2 + blockIdData.count)
    data.append(txId.prefix(32))
    var lenBE = UInt16(blockIdData.count).bigEndian
    data.append(contentsOf: withUnsafeBytes(of: &lenBE, Array.init))
    data.append(blockIdData)
    return data
}
```

### TTL

Default TTL for `.tonTxAck`: **8 hops**.

---

## tonTxReject Payload

Payload structure when `type == .tonTxReject`:

```
Offset  Size  Field
───────────────────────────────────────────────────
0       32    tx_id         (SHA-256 of original tonTxAnnounce payload)
32      1     reason        (uint8, see Reject Reasons)
```

### Reject Reasons

```swift
enum TONRejectReason: UInt8 {
    case expired       = 0x01  // valid_until has passed
    case seqnoMismatch = 0x02  // TON rejected: wrong seqno
    case invalidSign   = 0x03  // TON rejected: bad signature
    case tonNodeError  = 0x04  // Other TON API error
}
```

### TTL

Default TTL for `.tonTxReject`: **8 hops**.

---

## Deduplication

bitchat's existing seen-set (Bloom filter + TTL expiry) works unchanged:
- Dedup key: `senderID + timestamp + type` (existing bitchat logic)
- TON messages participate in the same dedup as chat messages
- No additional dedup state needed for TON

---

## Fragmentation

For BOC payloads exceeding the effective BLE MTU (~400 bytes after packet overhead), use bitchat's existing fragmentation (MessageType `0x40 FRAGMENT` or equivalent). The gateway reassembles before calling `sendBoc`.

See bitchat's `BinaryProtocol.swift` for the existing fragmentation codec.

---

## Upstream Compatibility

Nodes running upstream bitchat (without TON support) will receive `.tonTxAnnounce` (type `0x30`) packets. Since `0x30` is not in their `MessageType` enum:

- The packet is decoded with an unknown type
- bitchat's `MessageRouter` will log/drop unknown types (no crash)
- The packet is **not relayed** by non-TON nodes (TTL still decrements but unknown types are dropped)

**Implication**: TON transactions only propagate through TON-enabled nodes. For the network effect to work, a critical mass of users needs the TON fork installed. In the short term, gateways (TON-enabled, internet-connected nodes) should be placed at strategic locations.

> Future mitigation: submit a PR upstream to bitchat adding `.unknownRelay` forwarding for unrecognized types.
