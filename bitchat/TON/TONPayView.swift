// TONPayView.swift
// bitchat — TON Payment Integration
//
// This is free and unencumbered software released into the public domain.

import SwiftUI

/// Minimal payment UI: address + amount → sign → broadcast via BLE mesh
struct TONPayView: View {
    @ObservedObject var vm: TONViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var toAddress: String = ""
    @State private var amountTON: String = ""
    @State private var comment: String = ""
    @FocusState private var focusedField: Field?

    private enum Field { case address, amount, comment }

    var body: some View {
        NavigationStack {
            Form {
                // Network badge
                Section {
                    HStack {
                        Image(systemName: "network")
                        Text("Network: \(TONConfig.active.displayName)")
                            .foregroundStyle(TONConfig.active == .testnet ? .orange : .green)
                        Spacer()
                        if let address = vm.wallet.address {
                            Text(shortAddress(address))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // Recipient
                Section("Recipient") {
                    TextField("EQD… TON address", text: $toAddress)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .focused($focusedField, equals: .address)
                        .font(.system(.body, design: .monospaced))
                }

                // Amount
                Section("Amount") {
                    HStack {
                        TextField("0.00", text: $amountTON)
                            .keyboardType(.decimalPad)
                            .focused($focusedField, equals: .amount)
                        Text("TON")
                            .foregroundStyle(.secondary)
                    }
                }

                // Comment (optional)
                Section("Comment (optional)") {
                    TextField("Coffee ☕", text: $comment)
                        .focused($focusedField, equals: .comment)
                }

                // Status
                if vm.paymentStatus != .idle {
                    Section {
                        HStack(spacing: 10) {
                            if case .broadcasting = vm.paymentStatus {
                                ProgressView()
                            } else if case .fetchingSeqno = vm.paymentStatus {
                                ProgressView()
                            } else if case .signing = vm.paymentStatus {
                                ProgressView()
                            } else if case .confirmed = vm.paymentStatus {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            } else {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            Text(vm.paymentStatus.displayText)
                                .font(.footnote)
                        }

                        if case .confirmed(let hash) = vm.paymentStatus,
                           let url = TONConfig.active.explorerURL(txHash: hash) {
                            Link("View on \(TONConfig.active.displayName == "Testnet" ? "Testnet" : "") Explorer →", destination: url)
                                .font(.footnote)
                        }
                    }
                }

                // Send button
                Section {
                    Button(action: sendTapped) {
                        HStack {
                            Spacer()
                            Label("Send via Mesh", systemImage: "antenna.radiowaves.left.and.right")
                                .bold()
                            Spacer()
                        }
                    }
                    .disabled(!canSend)
                    .listRowBackground(canSend ? Color.blue : Color.gray.opacity(0.3))
                    .foregroundStyle(.white)
                }
            }
            .navigationTitle("Send TON")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onChange(of: vm.paymentStatus) { _, newStatus in
                if case .confirmed = newStatus {
                    // Auto-dismiss after confirmation
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { dismiss() }
                }
            }
        }
    }

    // MARK: - Actions

    private func sendTapped() {
        focusedField = nil
        guard let nano = TONViewModel.parseTON(amountTON) else {
            vm.paymentStatus = .failed(message: "Invalid amount")
            return
        }
        Task {
            await vm.send(
                to: toAddress.trimmingCharacters(in: .whitespaces),
                amountNano: nano,
                comment: comment.isEmpty ? nil : comment
            )
        }
    }

    // MARK: - Computed

    private var canSend: Bool {
        !toAddress.isEmpty &&
        !amountTON.isEmpty &&
        TONViewModel.parseTON(amountTON) != nil &&
        !vm.paymentStatus.isInProgress
    }

    private func shortAddress(_ addr: String) -> String {
        guard addr.count > 12 else { return addr }
        return "\(addr.prefix(6))…\(addr.suffix(4))"
    }
}

private extension TONPaymentStatus {
    var isInProgress: Bool {
        switch self {
        case .fetchingSeqno, .signing, .broadcasting: return true
        default: return false
        }
    }
}

#Preview {
    TONPayView(vm: TONViewModel())
}
