# TON Wallet — Design Specification

> `bitchat/Services/TONWallet.swift` — implementation target

---

## Responsibilities

1. **Keypair management** — Generate Ed25519 keypair for TON; store in iOS Keychain
2. **Address derivation** — Derive TON address (v4r2 wallet contract) from public key
3. **Seqno caching** — Cache last-known seqno for offline signing; refresh when online
4. **Transaction signing** — Build and sign a TON external message → BOC bytes
5. **BOC introspection** — Extract `valid_until` from a BOC for display purposes

---

## Keypair Generation & Storage

```swift
import Security
import CryptoKit  // for Curve25519 (Diffie-Hellman); Ed25519 via TON SDK

// TON uses Ed25519 for wallet signatures
// Keychain item: kSecAttrService = "chat.bitchat.ton", kSecAttrAccount = "wallet_keypair"

class TONWallet {
    private static let keychainService = "chat.bitchat.ton"
    private static let keychainAccount = "wallet_keypair"

    // Returns existing keypair or creates a new one
    static func loadOrCreate() throws -> TONKeypair

    // Returns nil if no keypair exists yet
    static func load() throws -> TONKeypair?

    // Permanently deletes the keypair (emergency wipe hook)
    static func delete()
}

struct TONKeypair {
    let privateKey: Data  // 32 bytes Ed25519 seed
    let publicKey: Data   // 32 bytes Ed25519 public key
    var address: String   // "EQD..." (base64url, bounceable)
}
```

### Keychain Storage

```swift
// Store
let query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: keychainService,
    kSecAttrAccount as String: keychainAccount,
    kSecValueData as String: privateKey,          // 32-byte seed
    kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
]
SecItemAdd(query as CFDictionary, nil)

// Retrieve
// ... SecItemCopyMatching with kSecReturnData
```

Only the 32-byte **seed** (private key scalar) is stored. The public key and address are derived each time.

---

## TON Address Derivation

TON Wallet v4r2 contract:
- Code hash: fixed constant (loaded from ton-sdk-swift)
- Initial data: `subwallet_id(4) + last_cleaned(8) + public_key(32) + plugins_dict(1)`
- Address = hash of (code + data) in workchain 0

```swift
// Using ton-sdk-swift
import TonSdkSwift

static func deriveAddress(publicKey: Data) throws -> String {
    let cell = try WalletV4R2.buildStateInit(publicKey: publicKey, subwalletId: 698983191)
    let address = try Address.parse(workchain: 0, stateInit: cell)
    return address.toBounceable()  // "EQD..."
}
```

---

## Seqno Management

```swift
// In-memory cache + UserDefaults persistence
class SeqnoCache {
    private let key = "ton.wallet.seqno"

    // Last cached seqno (persisted across app launches)
    var cached: UInt32 {
        get { UserDefaults.standard.object(forKey: key) as? UInt32 ?? 0 }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    // Fetch from TonCenter (requires internet)
    func refresh(address: String) async throws -> UInt32
}
```

**Seqno edge cases** (from SPEC.md):
- If offline seqno is stale, the transaction will be rejected with `SEQNO_MISMATCH`
- The gateway broadcasts a `.tonTxReject(reason: .seqnoMismatch)` so the sender can increment and retry
- The app should show a "Retry with updated seqno?" prompt when a reject is received

---

## Transaction Signing

```swift
struct TONTransferParams {
    let to: String          // Destination address "EQD..."
    let amount: UInt64      // In nanoTON (1 TON = 1_000_000_000 nanoTON)
    let comment: String?    // Optional transfer comment (UTF-8)
    let seqno: UInt32       // Current wallet seqno
    let validUntil: UInt32  // Unix timestamp, suggest: now + 3600 (1 hour)
}

extension TONWallet {
    // Returns signed BOC as Data + the validUntil used
    func signTransfer(_ params: TONTransferParams) throws -> (boc: Data, validUntil: UInt32)
}
```

### Implementation using ton-sdk-swift

```swift
// Pseudocode — exact API depends on ton-sdk-swift version
func signTransfer(_ params: TONTransferParams) throws -> (boc: Data, validUntil: UInt32) {
    let keypair = try TONWallet.load() ?? { throw TONWalletError.noKeypair }()

    // 1. Build internal message (transfer body)
    let body = try CellBuilder()
        .storeUint(0, bits: 32)          // op: 0 = simple transfer
        .storeUint(0, bits: 64)          // query_id
        .storeString(params.comment ?? "")
        .build()

    // 2. Build external message
    let msg = try WalletV4R2.buildExternalMessage(
        address: params.to,
        amount: params.amount,
        seqno: params.seqno,
        validUntil: params.validUntil,
        body: body,
        keypair: keypair
    )

    // 3. Serialize to BOC
    let boc = try Boc.serialize(root: msg)
    return (Data(boc), params.validUntil)
}
```

### BOC Size Validation

Before injecting into BLE mesh, verify BOC fits in BLE packet:

```swift
guard boc.count <= 420 else {
    throw TONWalletError.bocTooLarge(size: boc.count)
    // TODO: fragmentation support for complex contract calls
}
```

---

## Emergency Wipe Integration

bitchat has an emergency wipe (triple-tap). Hook into it:

```swift
// In ChatViewModel or EmergencyWipeManager
func performEmergencyWipe() {
    // ... existing bitchat wipe ...
    TONWallet.delete()  // Remove TON keypair from Keychain
}
```

---

## Error Types

```swift
enum TONWalletError: LocalizedError {
    case noKeypair
    case keychainWriteFailed(OSStatus)
    case keychainReadFailed(OSStatus)
    case invalidAddress(String)
    case bocTooLarge(size: Int)
    case signingFailed(underlying: Error)

    var errorDescription: String? { ... }
}
```
