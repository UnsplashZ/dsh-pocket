import AVFoundation
import DSHKit
import SwiftUI
import TetherKit
import VisionKit

/// S7 配对。
///
/// 主路径：**扫码**（电脑端「连接手机」显示二维码，内容就是 `endpointId#code`）。
/// 备选：粘贴整串（`.textContentType(.oneTimeCode)` 便于从剪贴板自动填）或手输 6 位码。
///
/// 失败按**原因码本地化**：不把码本身显示给用户（TRANSPORT §2）。
struct PairingSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private enum Step {
        case intro
        case scanning
        case manual
        case connecting
        case failed(String)
    }

    @State private var step: Step = .intro
    @State private var pasted = ""
    @State private var endpointId = ""
    @State private var code = ""
    @State private var copiedEndpoint = false

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .intro: intro
                case .scanning: scanner
                case .manual: manual
                case .connecting: connecting
                case .failed(let message): failure(message)
                }
            }
            .navigationTitle("连接电脑")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    // MARK: 第一步

    private var intro: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: Token.Spacing.tight) {
                    Text("在电脑上打开 DSH 的「连接手机」，它会显示一个二维码和 6 位配对码。")
                        .fixedSize(horizontal: false, vertical: true)
                    Text("配对窗口 10 分钟内有效，最多错 3 次。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button {
                    step = .scanning
                } label: {
                    Label("扫描电脑上的二维码", systemImage: "qrcode.viewfinder")
                }
                .disabled(!DataScannerViewController.isSupported)

                Button {
                    step = .manual
                } label: {
                    Label("手动输入配对码", systemImage: "keypad")
                }
            }

            Section {
                LabeledContent("这台手机的设备 ID") {
                    VStack(alignment: .trailing, spacing: Token.Spacing.hairline) {
                        Text(model.localEndpointId.isEmpty ? "…" : model.localEndpointId)
                            .font(.caption2.monospaced())
                            .lineLimit(2)
                            .multilineTextAlignment(.trailing)
                        Button(copiedEndpoint ? "已复制" : "复制") {
                            UIPasteboard.general.string = model.localEndpointId
                            copiedEndpoint = true
                        }
                        .font(.caption)
                    }
                }
            } footer: {
                Text("电脑端按这把公钥授权给这台手机；换手机或重置身份后需要重新配对。")
            }
        }
    }

    // MARK: 扫码

    @ViewBuilder
    private var scanner: some View {
        if DataScannerViewController.isSupported, DataScannerViewController.isAvailable {
            CodeScannerView { value in
                handleScanned(value)
            }
            .ignoresSafeArea(edges: .bottom)
            .overlay(alignment: .bottom) {
                Text("把电脑上的二维码放进取景框")
                    .font(.footnote)
                    .padding(Token.Spacing.tight)
                    .background(.regularMaterial, in: Capsule(style: .continuous))
                    .padding(.bottom, Token.Spacing.section)
            }
        } else {
            ContentUnavailableView {
                Label("这台设备不能扫码", systemImage: "camera.metering.unknown")
            } description: {
                Text("可以手动输入 6 位配对码。")
            } actions: {
                Button("手动输入") { step = .manual }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: 手输

    private var manual: some View {
        Form {
            Section {
                TextField("配对码", text: $code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .font(.title2.monospaced())
                    .onChange(of: code) { _, newValue in
                        code = String(newValue.filter(\.isNumber).prefix(6))
                    }
            } header: {
                Text("6 位配对码")
            } footer: {
                Text("电脑上「连接手机」对话框里显示的那 6 个数字。")
            }

            Section {
                TextField("电脑 ID（可选）", text: $endpointId)
                    .font(.caption.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("电脑 ID")
            } footer: {
                Text("已配对过的电脑会自动填上；第一次配对时也可以整串粘贴到这里。")
            }

            Section {
                TextField("粘贴配对串", text: $pasted, axis: .vertical)
                    .font(.caption.monospaced())
                    .textContentType(.oneTimeCode)
                    .onChange(of: pasted) { _, newValue in
                        applyPasted(newValue)
                    }
            } footer: {
                Text("格式是「电脑 ID#配对码」，整串粘进来会自动拆开。")
            }

            Section {
                Button {
                    connect()
                } label: {
                    Text("连接").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(code.count != 6)
            }
        }
    }

    private var connecting: some View {
        VStack(spacing: Token.Spacing.compact) {
            ProgressView().controlSize(.large)
            Text("正在连接电脑…").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failure(_ message: String) -> some View {
        ContentUnavailableView {
            Label("配对没有成功", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("再试一次") {
                step = .manual
                code = ""
            }
            .buttonStyle(.borderedProminent)
            Button("取消") { dismiss() }
        }
    }

    // MARK: 逻辑

    private func applyPasted(_ text: String) {
        guard let parsed = TetherPairingCode.parse(text) else { return }
        if let id = parsed.endpointId { endpointId = id }
        if !parsed.code.isEmpty { code = parsed.code }
    }

    private func handleScanned(_ value: String) {
        guard let parsed = TetherPairingCode.parse(value), let id = parsed.endpointId, !parsed.code.isEmpty else {
            step = .failed(String(localized: "这个二维码里没有配对信息。请确认扫的是 DSH「连接手机」显示的那一个。"))
            return
        }
        endpointId = id
        code = parsed.code
        connect()
    }

    private func connect() {
        guard let id = resolveEndpointId(), !code.isEmpty else { return }
        step = .connecting
        Task {
            // 用 connect 的**返回值**判断结果。之前是立刻去读 model.connection，
            // 而它是异步更新的 —— 明明连上了也会显示"连接没有完成"，
            // 用户再点一次就发了第二个 pair，被电脑端判成协议错误。
            let failure = await model.connect(hostId: id, pairingCode: code)
            if let failure {
                step = .failed(failure)
            } else {
                dismiss()
            }
        }
    }

    private func resolveEndpointId() -> String? {
        if TetherPairingCode.isEndpointId(endpointId) { return endpointId.lowercased() }
        if let id = model.settings.activeHostId, TetherPairingCode.isEndpointId(id), endpointId.isEmpty {
            return id
        }
        return nil
    }
}

// MARK: - 条码扫描（SwiftUI 没有对应控件，桥接 UIKit）

/// 用 `DataScannerViewController`（VisionKit）而不是自己写 AVFoundation：
/// 系统控件自带取景框、高亮与可访问性。
struct CodeScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr, .code128, .ean13])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {
        try? controller.startScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onCode: (String) -> Void
        private var handled = false

        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !handled else { return }
            for item in addedItems {
                if case .barcode(let barcode) = item, let value = barcode.payloadStringValue {
                    handled = true
                    onCode(value)
                    return
                }
            }
        }
    }
}
