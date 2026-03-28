// TONWallet.swift
// bitchat — TON Payment Integration
//
// This is free and unencumbered software released into the public domain.

import BigInt
import Foundation
import Security
import TonSwift

/// Errors from TON wallet operations
enum TONWalletError: LocalizedError {
    case noKeypair
    case keychainSaveFailed(OSStatus)
    case keychainReadFailed(OSStatus)
    case invalidAddress(String)
    case bocTooLarge(size: Int)
    case signingFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .noKeypair:
            return "No TON wallet found. Tap to create one."
        case .keychainSaveFailed(let code):
            return "Keychain save failed (OSStatus \(code))"
        case .keychainReadFailed(let code):
            return "Keychain read failed (OSStatus \(code))"
        case .invalidAddress(let addr):
            return "Invalid TON address: \(addr)"
        case .bocTooLarge(let size):
            return "Transaction too large for BLE (\(size) bytes, max \(TONConfig.maxBOCSize))"
        case .signingFailed(let err):
            return "Signing failed: \(err.localizedDescription)"
        }
    }
}

/// Represents a ready-to-broadcast signed TON external message.
struct SignedTONTransfer {
    /// Raw BOC bytes — this is what gets injected into the BLE mesh
    let boc: Data
    /// Unix timestamp after which the tx expires (embedded in the BOC)
    let validUntil: UInt32
    /// SHA-256 of the tonTxAnnounce payload — used as dedup key / ACK correlation
    let txId: Data
}

/// Manages TON keypair (Ed25519 via BIP39/TON mnemonic), address derivation, and transaction signing.
///
/// The 24-word mnemonic is stored in the iOS Keychain.
/// All signing is done on-device — private key never leaves the device.
@MainActor
final class TONWallet: ObservableObject {

    @Published private(set) var address: String?
    @Published private(set) var isReady: Bool = false

    private var keyPair: KeyPair?

    // MARK: - Lifecycle

    init() {
        Task { await loadOrCreate() }
    }

    /// Load existing keypair from Keychain, or create a new one.
    func loadOrCreate() async {
        if let mnemonic = keychainLoadMnemonic() {
            if await load(mnemonic: mnemonic) { return }
        }
        await create()
    }

    // MARK: - Keypair Management

    @discardableResult
    private func load(mnemonic: [String]) async -> Bool {
        guard let kp = try? Mnemonic.mnemonicToPrivateKey(mnemonicArray: mnemonic) else { return false }
        let contract = WalletV4R2(workchain: 0, publicKey: kp.publicKey.data)
        guard let addr = try? contract.address() else { return false }
        self.keyPair = kp
        let friendly = FriendlyAddress(address: addr, testOnly: TONConfig.active == .testnet, bounceable: false)
        self.address = friendly.toString()
        self.isReady = true
        return true
    }

    private func create() async {
        let mnemonic = Mnemonic.mnemonicNew(wordsCount: 24)
        guard let _ = try? keychainSaveMnemonic(mnemonic) else { return }
        _ = await load(mnemonic: mnemonic)
    }

    /// Remove keypair from Keychain. Called during emergency wipe.
    func deleteKeypair() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: TONConfig.keychainService,
            kSecAttrAccount as String: TONConfig.keychainSeedKey
        ]
        SecItemDelete(query as CFDictionary)
        keyPair = nil
        address = nil
        isReady = false
    }

    // MARK: - Transaction Signing

    /// Sign a TON transfer and return the BOC ready for BLE propagation.
    ///
    /// - Parameters:
    ///   - to: Recipient TON address string
    ///   - amount: Transfer amount in nanoTON (1 TON = 1_000_000_000)
    ///   - comment: Optional text comment
    ///   - seqno: Current wallet seqno (fetch with `TONCenterGateway.getSeqno`)
    ///   - validUntil: Expiry Unix timestamp. Default: now + 1 hour
    /// - Throws: `TONWalletError`
    func signTransfer(
        to: String,
        amount: UInt64,
        comment: String? = nil,
        seqno: UInt32,
        validUntil: UInt32? = nil
    ) async throws -> SignedTONTransfer {
        guard let kp = keyPair else { throw TONWalletError.noKeypair }

        let expiry = validUntil ?? UInt32(Date().timeIntervalSince1970) + TONConfig.defaultValidityWindow

        // Parse destination address
        guard let destAddress = try? Address.parse(to) else {
            throw TONWalletError.invalidAddress(to)
        }

        // Build internal message
        let message: MessageRelaxed
        if let comment = comment, !comment.isEmpty {
            message = try MessageRelaxed.internal(
                to: destAddress,
                value: BigUInt(amount),
                bounce: false,
                textPayload: comment
            )
        } else {
            message = MessageRelaxed.internal(
                to: destAddress,
                value: BigUInt(amount),
                bounce: false
            )
        }

        // Build WalletV4R2 transfer (seqno, timeout, messages)
        let contract = WalletV4R2(workchain: 0, publicKey: kp.publicKey.data)
        let transferData = WalletTransferData(
            seqno: UInt64(seqno),
            messages: [message],
            sendMode: SendMode(payMsgFees: true),
            timeout: UInt64(expiry)
        )
        let transfer = try contract.createTransfer(args: transferData)

        // Sign: returns 64-byte Ed25519 signature over the cell hash
        let signature = try transfer.signMessage(
            signer: WalletTransferSecretKeySigner(secretKey: kp.privateKey.data)
        )

        // Build external message body: [signature (512 bits)] || [signingMessage bits + refs]
        let signingCell = try transfer.signingMessage.endCell()
        let body = try Builder()
            .store(data: signature)
            .store(slice: signingCell.toSlice())
            .endCell()

        // Wrap in external-in message (no stateInit for existing wallet)
        let contractAddress = try contract.address()
        let extMsg = Message.external(to: contractAddress, stateInit: nil, body: body)
        let msgCell = try Builder().store(extMsg).endCell()

        // Serialize to BOC (with CRC32c)
        let bocData = try msgCell.toBoc()

        guard bocData.count <= TONConfig.maxBOCSize else {
            throw TONWalletError.bocTooLarge(size: bocData.count)
        }

        // txId = SHA-256 of the announce payload (for dedup / ACK correlation)
        let announcePayload = BinaryProtocol.encodeTonTxAnnounce(validUntil: expiry, boc: bocData)
        let txId = BinaryProtocol.tonTxId(from: announcePayload)

        return SignedTONTransfer(boc: bocData, validUntil: expiry, txId: txId)
    }

    // MARK: - Keychain Helpers

    private func keychainSaveMnemonic(_ mnemonic: [String]) throws {
        guard let data = mnemonic.joined(separator: " ").data(using: .utf8) else {
            throw TONWalletError.keychainSaveFailed(errSecParam)
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: TONConfig.keychainService,
            kSecAttrAccount as String: TONConfig.keychainSeedKey,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw TONWalletError.keychainSaveFailed(status) }
    }

    private func keychainLoadMnemonic() -> [String]? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: TONConfig.keychainService,
            kSecAttrAccount as String: TONConfig.keychainSeedKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let str = String(data: data, encoding: .utf8) else { return nil }
        let words = str.components(separatedBy: " ")
        return words.count == 24 ? words : nil
    }
}
