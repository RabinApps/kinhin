import Foundation
import KinhinKit
import SwiftUI

/// The Fleet tab's Detail page: a table of the fleet's VMs with a live
/// breakdown of queued and running work by repository, and a drill-down into a
/// selected VM's lifecycle (phase, runner, job, IP).
struct FleetDetailView: View {
    @Bindable var model: FleetDetailModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Mode picker + status line
            HStack {
                Picker("Mode", selection: $model.mode) {
                    ForEach(FleetDetailModel.DetailMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 300)
                .accessibilityLabel("Job state filter")
                .onChange(of: model.mode) { _, _ in
                    Task { await model.refresh() }
                }
                Spacer()
                Text(model.statusLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if !model.noWorkText.isEmpty {
                StatusText(text: model.noWorkText, style: .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Breakdown card
            if !model.breakdownText.isEmpty {
                FormCard(title: "Work by repository") {
                    Text(model.breakdownText)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }

            // VM rows
            VStack(alignment: .leading, spacing: 6) {
                SectionHeader("VMs")
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        if model.selectedVMID != nil {
                            Text(model.selectedVMID!).font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        if model.status?.records.isEmpty == true {
                            secondary("No VMs — the fleet is idle.")
                        } else {
                            ForEach(model.status?.records ?? [], id: \.id) { record in                                    Button {
                                        model.selectVM(record.id)
                                        model.selectedVMID = nil
                                    } label: {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(title(for: record)).font(.system(size: 12, design: .monospaced))
                                            Text(record.job ?? detail(for: record))
                                            .font(.system(size: 10))
                                            .foregroundStyle(record.error != nil ? StatusStyle.error.color : StatusStyle.secondary.color)
                                    }
                                    .contentShape(Rectangle())
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .formSurface(cornerRadius: 8)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Show lifecycle of \(record.id), \(record.phase.rawValue)")
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .containerRelativeFrame(.vertical) { height, _ in height * 0.30 }
            }

            // Drill-down
            if let id = model.selectedVMID, let detail = model.vmDetail(for: id) {
                FormCard(title: "Lifecycle") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("ID").font(.system(size: 11)).foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            Text(detail.id).font(.system(size: 11, design: .monospaced))
                        }
                        HStack {
                            Text("Phase").font(.system(size: 11)).foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            Text(detail.phase.rawValue).font(.system(size: 11, design: .monospaced))
                        }
                        if let runner = detail.runnerName {
                            HStack {
                                Text("Runner").font(.system(size: 11)).foregroundStyle(.secondary)
                                Spacer(minLength: 0)
                                Text(runner).font(.system(size: 11, design: .monospaced))
                            }
                        }
                        if let job = detail.job {
                            HStack {
                                Text("Job").font(.system(size: 11)).foregroundStyle(.secondary)
                                Spacer(minLength: 0)
                                Text(job).font(.system(size: 11, design: .monospaced))
                            }
                        }
                        if let ip = detail.ip {
                            HStack {
                                Text("IP").font(.system(size: 11)).foregroundStyle(.secondary)
                                Spacer(minLength: 0)
                                Text(ip).font(.system(size: 11, design: .monospaced))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            } else {
                // Empty detail pane
                FormCard(title: "Lifecycle") {
                    Text("Select a VM from the table above to see its lifecycle details.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }

            HStack(spacing: 8) {
                Button("Close") { model.selectedVMID = nil }
                    .keyboardShortcut(.escape)
                    .accessibilityLabel("Close detail")
            }
            .padding(.horizontal, 16)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func title(for record: VMRecord) -> String {
        "• \(record.id) — \(record.phase.rawValue)"
    }

    private func detail(for record: VMRecord) -> String {
        var parts: [String] = []
        if let runner = FleetStatusFormatter.repos(of: record) { parts.append(runner) }
        if let job = record.job { parts.append(job) }
        if let usage = FleetStatusFormatter.usage(of: record) { parts.append(usage) }
        if let err = record.error { parts.append("⚠ \(err.prefix(120))") }
        return parts.joined(separator: " · ")
    }

    private func secondary(_ text: String, mono: Bool = false) -> some View {
        Text(text)
            .font(mono ? .system(size: 11, design: .monospaced) : .system(size: 11))
            .foregroundStyle(.secondary)
    }
}
