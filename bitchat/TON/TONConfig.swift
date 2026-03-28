// TONConfig.swift
// bitchat — TON Payment Integration
//
// This is free and unencumbered software released into the public domain.

import Foundation

/// Network environment selection.
/// Default is testnet for experimentation; switch to mainnet for production.
enum TONNetwork {
    case testnet
    case mainnet

    var tonCenterEndpoint: URL {
        switch self {
        case .testnet:
            return URL(string: "https://testnet.toncenter.com/api/v2/jsonRPC")!
        case .mainnet:
            return URL(string: "https://toncenter.com/api/v2/jsonRPC")!
        }
    }

    /// TON global network ID — used by WalletV4R2 for replay protection across networks
    var globalId: Int32 {
        switch self {
        case .testnet: return -3
        case .mainnet: return -239
        }
    }

    var displayName: String {
        switch self {
        case .testnet: return "Testnet"
        case .mainnet: return "Mainnet"
        }
    }

    /// Explorer URL for a given transaction hash
    func explorerURL(txHash: String) -> URL? {
        switch self {
        case .testnet:
            return URL(string: "https://testnet.tonscan.org/tx/\(txHash)")
        case .mainnet:
            return URL(string: "https://tonscan.org/tx/\(txHash)")
        }
    }
}

/// Global app-wide TON configuration.
/// Change `active` to switch environments.
enum TONConfig {
    /// Primary network. Set to .mainnet when ready for production.
    static let active: TONNetwork = .testnet

    /// Keychain service identifier for TON keypair storage
    static let keychainService = "chat.bitchat.ton"

    /// Keychain account key for the Ed25519 seed
    static let keychainSeedKey = "ton_seed"

    /// Maximum BOC size accepted for BLE propagation (bytes)
    static let maxBOCSize = 800

    /// Default transaction validity window (seconds from signing time)
    static let defaultValidityWindow: UInt32 = 3600  // 1 hour
}
