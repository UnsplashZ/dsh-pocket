import DSHKit
import SwiftUI

/// 权限档位的显示文案。
///
/// 抽出来是因为输入框和权限选择页都要用 —— 两处各写一份必然会漂移
/// （之前模型名就在两个地方各写了一份）。
///
/// 用 DSH 自己的措辞（`permission.access` 词典）而不是直译，
/// 这样手机和电脑上是同一套说法。
enum PermissionLabel {
    static func text(_ value: String?) -> String {
        switch value {
        case "read-only": return String(localized: "仅可查看")
        case "workspace-write": return String(localized: "工作区内修改")
        case "danger-full-access": return String(localized: "完全权限")
        case .some(let other): return other
        case nil: return String(localized: "权限")
        }
    }

    static func symbol(_ value: String?) -> String {
        switch value {
        case "read-only": return "eye"
        case "workspace-write": return "folder.badge.gearshape"
        case "danger-full-access": return "exclamationmark.shield"
        default: return "lock.shield"
        }
    }

    /// 危险档位：图标要变色，别让它看起来跟只读一样无害。
    static func isRisky(_ value: String?) -> Bool { value == "danger-full-access" }
}
