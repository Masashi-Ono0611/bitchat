// TONViewModel.swift
// bitchat — TON Payment Integration
//
// This is free and unencumbered software released into the public domain.

import Foundation
import SwiftUI

/// Status of a TON payment in progress
enum TONPaymentStatus: Equatable {
    case idle
    case fetchingSeqno
    case signing
    case broadcasting         // Injected into BLE mesh, awaiting gateway
    case confirmed(txHash: String)
    case rejected(reason: String)
    case failed(message: String)

    var displayText: String {
        switch self {
        case .idle: return ""
        case .fetchingSeqno: return "Fetching seqno…"
        case .signing: return "Signing transaction…"
        case .broadcasting: return "Broadcasting via BLE mesh…"
        case .confirmed(let hash):
            let short = String(hash.prefix(12))
            return "Confirmed ✓ (\(short)…)"
        case .rejected(let reason): return "Rejected: \(reason)"
        case .failed(let msg): return "Failed: \(msg)"
        }
    }

    var isTerminal: Bool {
        switch self {
        case .confirmed, .rejected, .failed: return true
        default: return false
        }
    }
}

/// ViewModel that bridges TONWallet + TONCenterGateway + BLE mesh injection.
///
/// Injected into `TONPayView` and referenced from `ChatViewModel` for ACK/REJECT callbacks.
@MainActor
final class TONViewModel: ObservableObject {

    // MARK: - Published state

    @Published var wallet: TONWallet
    @Published var paymentStatus: TONPaymentStatus = .idle

    /// Pending transactions: txId (hex) → SignedTONTransfer
    @Published var pendingTxs: [String: SignedTONTransfer] = [:]

    // MARK: - Dependencies (injected)

    /// Called with the BitchatPacket bytes to inject into BLE mesh
    var injectIntoBLE: ((Data, MessageType) -> Void)?

    private let gateway: TONCenterGateway

    // MARK: - Init

    init() {
        self.wallet = TONWallet()
        self.gateway = TONCenterGateway(network: TONConfig.active)
    }

    // MARK: - Send

    /// Fetch seqno → sign → inject into BLE mesh.
    ///
    /// The gateway node (any online peer in range) will pick it up and submit to TonCenter.
    func send(to address: String, amountNano: UInt64, comment: String?) async {
        guard !address.isEmpty else {
            paymentStatus = .failed(message: "Address is required")
            return
        }
        guard amountNano > 0 else {
            paymentStatus = .failed(message: "Amount must be greater than 0")
            return
        }

        do {
            // 1. Fetch seqno (requires internet; falls back to cached value in future)
            paymentStatus = .fetchingSeqno
            let walletAddress = wallet.address ?? address
            let seqno = try await gateway.getSeqno(address: walletAddress)

            // 2. Sign
            paymentStatus = .signing
            let transfer = try await wallet.signTransfer(
                to: address,
                amount: amountNano,
                comment: comment,
                seqno: seqno
            )

            // 3. Build announcement payload and inject into BLE mesh
            paymentStatus = .broadcasting
            let payload = BinaryProtocol.encodeTonTxAnnounce(validUntil: transfer.validUntil, boc: transfer.boc)
            injectIntoBLE?(payload, .tonTxAnnounce)

            // Track as pending
            let txIdHex = transfer.txId.map { String(format: "%02x", $0) }.joined()
            pendingTxs[txIdHex] = transfer

        } catch let error as TONWalletError {
            paymentStatus = .failed(message: error.localizedDescription)
        } catch let error as TONCenterError {
            paymentStatus = .failed(message: error.localizedDescription)
        } catch {
            paymentStatus = .failed(message: error.localizedDescription)
        }
    }

    // MARK: - Gateway mode: handle incoming tonTxAnnounce

    /// Called when this device (as gateway) receives a TON tx from the mesh.
    /// If we have internet, submit to TonCenter and broadcast ACK/REJECT back.
    func handleIncomingTonTxAnnounce(payload: Data) async {
        guard let (validUntil, boc) = BinaryProtocol.decodeTonTxAnnounce(payload: payload) else { return }

        let now = UInt32(Date().timeIntervalSince1970)
        let txId = BinaryProtocol.tonTxId(from: payload)

        // Drop expired transactions
        guard validUntil > now else {
            let rejectPayload = BinaryProtocol.encodeTonTxReject(txId: txId, reason: 0x01)
            injectIntoBLE?(rejectPayload, .tonTxReject)
            return
        }

        do {
            let blockId = try await gateway.sendBoc(boc)
            let ackPayload = BinaryProtocol.encodeTonTxAck(txId: txId, blockId: blockId)
            injectIntoBLE?(ackPayload, .tonTxAck)
        } catch let error as TONCenterError {
            let rejectPayload = BinaryProtocol.encodeTonTxReject(txId: txId, reason: error.rejectReason)
            injectIntoBLE?(rejectPayload, .tonTxReject)
        } catch {
            let rejectPayload = BinaryProtocol.encodeTonTxReject(txId: txId, reason: 0x04)
            injectIntoBLE?(rejectPayload, .tonTxReject)
        }
    }

    // MARK: - ACK / REJECT from mesh

    /// Called when we receive a tonTxAck for one of our pending transactions
    func handleTonTxAck(txId: Data, blockId: String) {
        let txIdHex = txId.map { String(format: "%02x", $0) }.joined()
        guard pendingTxs[txIdHex] != nil else { return }
        pendingTxs.removeValue(forKey: txIdHex)
        paymentStatus = .confirmed(txHash: blockId)
    }

    /// Called when we receive a tonTxReject for one of our pending transactions
    func handleTonTxReject(txId: Data, reason: UInt8) {
        let txIdHex = txId.map { String(format: "%02x", $0) }.joined()
        guard pendingTxs[txIdHex] != nil else { return }
        pendingTxs.removeValue(forKey: txIdHex)

        let reasonText: String
        switch reason {
        case 0x01: reasonText = "Transaction expired"
        case 0x02: reasonText = "Wrong seqno (stale)"
        case 0x03: reasonText = "Invalid signature"
        case 0x04: reasonText = "TON node error"
        default:   reasonText = "Unknown reason (\(reason))"
        }
        paymentStatus = .rejected(reason: reasonText)
    }

    // MARK: - Helpers

    /// Convert TON amount (as decimal string) to nanoTON
    static func parseTON(_ input: String) -> UInt64? {
        guard let decimal = Double(input), decimal > 0 else { return nil }
        return UInt64(decimal * 1_000_000_000)
    }
}
