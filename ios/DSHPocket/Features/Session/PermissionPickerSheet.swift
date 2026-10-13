import DSHKit
import SwiftUI

/// 权限档位的**悬浮窗**。
///
/// 就三个选项 + 一个勾，用不着一整页 sheet —— 那个页面 90% 是空白，
/// 而且每次都要弹一层全屏再关掉。用 popover 锚在按钮上，选完即走。
struct PermissionPopover: View {
    let session: SessionModel

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(session.permissionOptions, id: \.value) { preset in
                Button {
                    select(preset.value)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: Token.Spacing.tight) {
                        Image(systemName: preset.symbol)
                            .font(.footnote)
                            .foregroundStyle(preset.isRisky ? Color.orange : Color.secondary)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(PermissionLabel.text(preset.value))
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                            if let explanation = preset.explanation {
                                Text(explanation)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: Token.Spacing.tight)
                        if session.currentPermission == preset.value {
                            Image(systemName: "checkmark")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tint)
                        }
                    }
                    .padding(.horizontal, Token.Spacing.compact)
                    .padding(.vertical, Token.Spacing.tight)
                    .frame(minHeight: Token.minimumHitTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if preset.value != session.permissionOptions.last?.value { Divider() }
            }
        }
        .frame(width: 300)
        .padding(.vertical, Token.Spacing.hairline)
    }

    private func select(_ value: String) {
        guard session.currentPermission != value else {
            dismiss()
            return
        }
        Task {
            await session.applyPermissionPreset(value)
            dismiss()
        }
    }
}

// 权限现在用 `PermissionPopover`（同一个文件上半部分）—— 三个选项 + 一个勾，
// 用不着一整页 sheet。原来的 `PermissionPickerSheet` 已删除。
