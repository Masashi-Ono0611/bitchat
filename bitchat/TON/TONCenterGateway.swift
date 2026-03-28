// TONCenterGateway.swift
// bitchat — TON Payment Integration
//
// This is free and unencumbered software released into the public domain.

import Foundation

/// Errors from TonCenter API calls
enum TONCenterError: LocalizedError {
    case httpError(Int)
    case apiError(code: Int, message: String)
    case networkError(underlying: Error)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .httpError(let code):
            return "HTTP error \(code)"
        case .apiError(let code, let msg):
            return "TonCenter error \(code): \(msg)"
        case .networkError(let err):
            return "Network error: \(err.localizedDescription)"
        case .invalidResponse:
            return "Invalid response from TonCenter"
        }
    }

    /// Map TonCenter error message to a TON reject reason byte
    var rejectReason: UInt8 {
        if case .apiError(_, let msg) = self {
            let lower = msg.lowercased()
            if lower.contains("seqno") || lower.contains("wrong seqno") { return 0x02 }
            if lower.contains("signature") || lower.contains("sign") { return 0x03 }
        }
        return 0x04  // TON_NODE_ERROR
    }
}

/// Codable wrappers for TonCenter JSON-RPC responses
private struct TONCenterResponse<T: Decodable>: Decodable {
    let result: T?
    let error: TONCenterAPIError?
}

private struct TONCenterAPIError: Decodable {
    let code: Int
    let message: String
}

private struct SendBocResult: Decodable {
    let hash: String?
}

private struct GetSeqnoResult: Decodable {
    let stack: [[AnyCodable]]

    struct AnyCodable: Decodable {
        let value: Any

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let str = try? container.decode(String.self) { value = str; return }
            if let int = try? container.decode(Int.self) { value = int; return }
            value = ""
        }
    }
}

/// Submits signed TON BOCs to TonCenter and fetches wallet seqno.
///
/// Works with both testnet and mainnet via `TONConfig.active`.
final class TONCenterGateway {
    private let network: TONNetwork
    private let session: URLSession

    init(network: TONNetwork = TONConfig.active) {
        self.network = network
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    // MARK: - sendBoc

    /// Submit a signed BOC to TonCenter. Returns the transaction hash on success.
    func sendBoc(_ boc: Data) async throws -> String {
        let bocBase64 = boc.base64EncodedString()
        let body: [String: Any] = [
            "id": "1",
            "jsonrpc": "2.0",
            "method": "sendBoc",
            "params": ["boc": bocBase64]
        ]
        let responseData = try await jsonRPC(body: body)

        // Parse response
        if let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] {
            if let error = json["error"] as? [String: Any],
               let code = error["code"] as? Int,
               let message = error["message"] as? String {
                throw TONCenterError.apiError(code: code, message: message)
            }
            if let result = json["result"] as? [String: Any],
               let hash = result["hash"] as? String {
                return hash
            }
        }
        throw TONCenterError.invalidResponse
    }

    // MARK: - getSeqno

    /// Fetch the current seqno for a TON wallet address.
    func getSeqno(address: String) async throws -> UInt32 {
        let body: [String: Any] = [
            "id": "1",
            "jsonrpc": "2.0",
            "method": "runGetMethod",
            "params": [
                "address": address,
                "method": "seqno",
                "stack": []
            ]
        ]
        let responseData = try await jsonRPC(body: body)

        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw TONCenterError.invalidResponse
        }

        if let error = json["error"] as? [String: Any],
           let code = error["code"] as? Int,
           let message = error["message"] as? String {
            throw TONCenterError.apiError(code: code, message: message)
        }

        // Parse seqno from stack: [["num", "0x<hex>"]]
        if let result = json["result"] as? [String: Any],
           let stack = result["stack"] as? [[Any]],
           let firstEntry = stack.first,
           firstEntry.count >= 2,
           let hexStr = firstEntry[1] as? String {
            let cleaned = hexStr.hasPrefix("0x") ? String(hexStr.dropFirst(2)) : hexStr
            if let seqno = UInt32(cleaned, radix: 16) {
                return seqno
            }
        }
        throw TONCenterError.invalidResponse
    }

    // MARK: - Private

    private func jsonRPC(body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: network.tonCenterEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw TONCenterError.httpError(http.statusCode)
            }
            return data
        } catch let error as TONCenterError {
            throw error
        } catch {
            throw TONCenterError.networkError(underlying: error)
        }
    }
}
