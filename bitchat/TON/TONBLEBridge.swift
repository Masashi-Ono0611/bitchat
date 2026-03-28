// TONBLEBridge.swift
// bitchat — TON Payment Integration
//
// This is free and unencumbered software released into the public domain.

import Foundation

/// Delegate that BLEService calls for TON-specific packet events.
/// Implemented by `ChatViewModel` (or any coordinator) to forward events to `TONViewModel`.
@MainActor
protocol TONBLEDelegate: AnyObject {
    /// A tonTxAnnounce packet arrived. Gateway-capable nodes should submit to TonCenter.
    func didReceiveTonTxAnnounce(payload: Data)
    /// A tonTxAck packet arrived.
    func didReceiveTonTxAck(txId: Data, blockId: String)
    /// A tonTxReject packet arrived.
    func didReceiveTonTxReject(txId: Data, reason: UInt8)
}
