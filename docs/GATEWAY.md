# Gateway Node — Design Specification

> `bitchat/Services/TONCenterGateway.swift` + `MessageRouter.swift` changes

---

## What Is a Gateway?

Any device running this fork that has **internet connectivity** becomes a gateway. It:

1. Receives `.tonTxAnnounce` messages from the BLE mesh
2. Submits the BOC to TonCenter API (`sendBoc`)
3. Broadcasts the result (`.tonTxAck` or `.tonTxReject`) back into the BLE mesh

No explicit "gateway mode" toggle is needed — gateway behavior is triggered automatically when:
- `MessageRouter.isOnline() == true`, AND
- A `.tonTxAnnounce` message is received

---

## TONCenterGateway

```swift
// bitchat/Services/TONCenterGateway.swift

struct TONCenterConfig {
    let endpoint: URL           // default: https://toncenter.com/api/v2/jsonRPC
    let apiKey: String?         // optional, needed for high-traffic
    let timeoutSeconds: Double  // default: 30
}

class TONCenterGateway {
    init(config: TONCenterConfig)

    // Submit BOC to TonCenter. Returns block identifier on success.
    func sendBoc(_ boc: Data) async throws -> String  // returns block_id

    // Fetch current seqno for an address
    func getSeqno(address: String) async throws -> UInt32
}
```

### sendBoc Implementation

```swift
func sendBoc(_ boc: Data) async throws -> String {
    let bocBase64 = boc.base64EncodedString()

    let requestBody: [String: Any] = [
        "id": "1",
        "jsonrpc": "2.0",
        "method": "sendBoc",
        "params": ["boc": bocBase64]
    ]

    let (data, response) = try await URLSession.shared.data(from: request)

    guard let httpResponse = response as? HTTPURLResponse,
          httpResponse.statusCode == 200 else {
        throw TONCenterError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    let json = try JSONDecoder().decode(TONCenterResponse.self, from: data)

    if let error = json.error {
        throw TONCenterError.apiError(code: error.code, message: error.message)
    }

    return json.result?.hash ?? ""
}
```

### Error Classification for Reject Reason

```swift
func classifyError(_ error: TONCenterError) -> TONRejectReason {
    switch error {
    case .apiError(_, let msg) where msg.contains("Seqno mismatch"):
        return .seqnoMismatch
    case .apiError(_, let msg) where msg.contains("Invalid signature"):
        return .invalidSign
    case .httpError, .apiError:
        return .tonNodeError
    }
}
```

---

## MessageRouter Extension

Changes to `bitchat/Services/MessageRouter.swift`:

```swift
// Add to MessageRouter class:

private let tonGateway = TONCenterGateway(config: .default)

// Called when a .tonTxAnnounce is received AND isOnline() == true
func handleTonTxAnnounce(_ packet: BitchatPacket) async {
    guard let (validUntil, boc) = BinaryProtocol.decodeTonTxAnnounce(payload: packet.payload) else {
        return  // malformed payload, silently drop
    }

    // Check expiry before submitting
    let now = UInt32(Date().timeIntervalSince1970)
    guard validUntil > now else {
        // Send reject: expired
        let txId = SHA256.hash(data: packet.payload)
        broadcastTonReject(txId: Data(txId), reason: .expired)
        return
    }

    do {
        let blockId = try await tonGateway.sendBoc(boc)
        let txId = SHA256.hash(data: packet.payload)
        broadcastTonAck(txId: Data(txId), blockId: blockId)
    } catch let error as TONCenterError {
        let txId = SHA256.hash(data: packet.payload)
        let reason = tonGateway.classifyError(error)
        broadcastTonReject(txId: Data(txId), reason: reason)
    }
}

private func broadcastTonAck(txId: Data, blockId: String) {
    let payload = BinaryProtocol.encodeTonTxAck(txId: txId, blockId: blockId)
    let packet = BitchatPacket(
        type: .tonTxAck,
        payload: payload,
        ttl: 8,
        senderID: localNodeID
    )
    bleService.broadcast(packet)
}

private func broadcastTonReject(txId: Data, reason: TONRejectReason) {
    let payload = BinaryProtocol.encodeTonTxReject(txId: txId, reason: reason)
    let packet = BitchatPacket(
        type: .tonTxReject,
        payload: payload,
        ttl: 8,
        senderID: localNodeID
    )
    bleService.broadcast(packet)
}
```

---

## Connectivity Detection

`isOnline()` uses the existing `NetworkMonitor` in bitchat (based on `Network.framework NWPathMonitor`). No changes needed.

---

## Rate Limiting

To prevent abuse from malformed or spam transactions:

- Max 10 `sendBoc` calls per minute per gateway instance
- Exponential backoff on TonCenter API errors (1s, 2s, 4s, max 30s)
- Drop `.tonTxAnnounce` if BOC size > 2048 bytes (DoS protection)

---

## TonCenter API Reference

Base URL: `https://toncenter.com/api/v2/jsonRPC`

### sendBoc

```json
POST /api/v2/jsonRPC
Content-Type: application/json

{
  "id": "1",
  "jsonrpc": "2.0",
  "method": "sendBoc",
  "params": { "boc": "<base64-encoded BOC>" }
}
```

Response (success):
```json
{ "id": "1", "jsonrpc": "2.0", "result": { "hash": "tx_hash_here" } }
```

Response (error):
```json
{ "id": "1", "jsonrpc": "2.0", "error": { "code": -32603, "message": "Seqno mismatch" } }
```

### getSeqno

```json
{
  "method": "runGetMethod",
  "params": {
    "address": "EQD...",
    "method": "seqno",
    "stack": []
  }
}
```

---

## Testnet Configuration

For testing without real TON:

```swift
extension TONCenterConfig {
    static let `default` = TONCenterConfig(
        endpoint: URL(string: "https://toncenter.com/api/v2/jsonRPC")!,
        apiKey: nil,
        timeoutSeconds: 30
    )

    static let testnet = TONCenterConfig(
        endpoint: URL(string: "https://testnet.toncenter.com/api/v2/jsonRPC")!,
        apiKey: nil,
        timeoutSeconds: 30
    )
}
```

Switch via build configuration flag: `#if TESTNET ... #endif`

---

## Node.js Gateway (Alternative)

For non-mobile gateways (Raspberry Pi, PC hotspot nodes), the TypeScript implementation at [`Masashi-Ono0611/meshpay-ton`](https://github.com/Masashi-Ono0611/meshpay-ton) provides equivalent gateway functionality. The Swift and TypeScript implementations are protocol-compatible.
