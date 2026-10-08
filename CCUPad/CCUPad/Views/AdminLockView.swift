//
//  AdminLockView.swift
//  CCUPad
//
//  「锁定其他项目」这一个功能的两个界面：
//    · AdminUnlockSheet    —— 主控台上点「解锁其他项目」时弹出的密码框
//    · AdminSecuritySection —— 设置里的安全区：设密码 / 开关锁定 / 清密码
//
//  现场用法：操作员只该「推增益、看 tally」，参数发现 / 设备 / 设置这类会改配置的地方
//  要密码才进得去。因此：
//    · 密码存在 Keychain（不进设置文件、不进日志）；
//    · **解锁状态不持久化** —— 重启 App 自动回到锁定；
//    · 只有已设置密码时才能打开锁定，否则锁上就再也进不去设置页了。
//

import SwiftUI

struct AdminUnlockSheet: View {
    @EnvironmentObject private var manager: CCUManager
    @Environment(\.dismiss) private var dismiss

    @State private var password = ""
    @State private var errorText: String? = nil

    var body: some View {
        NavigationStack {
            Form {
                Section("管理密码") {
                    SecureField("密码", text: $password)

                    if let errorText = errorText {
                        Text(errorText)
                            .font(.caption)
                            .foregroundStyle(Theme.program)
                    }

                    Text("输入后才能看到「参数发现 / 设备 / 设置」三个页。解锁状态不会保留到下次启动。")
                        .font(.caption2)
                        .foregroundStyle(Color.secondary)
                }
            }
            .navigationTitle("解锁其他项目")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("解锁") {
                        if manager.unlockAdmin(with: password) {
                            dismiss()
                        } else {
                            errorText = "密码不对"
                        }
                    }
                }
            }
        }
    }
}

struct AdminSecuritySection: View {
    @EnvironmentObject private var manager: CCUManager

    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var message: String? = nil

    var body: some View {
        Section("安全：锁定其他项目") {
            if manager.adminPasswordIsSet {
                Text("已设置管理密码。")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            } else {
                Text("还没有管理密码。「锁定其他项目」只有在设置密码之后才能打开 —— 否则锁上就进不来了。")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }

            SecureField("设置 / 修改管理密码", text: $newPassword)
            SecureField("再输入一遍", text: $confirmPassword)

            Button("保存管理密码") { savePassword() }
                .disabled(newPassword.isEmpty)

            Toggle("锁定「其他项目」（只留主控台）", isOn: Binding(
                get: { manager.settings.lockAdmin },
                set: { locked in
                    _ = manager.setLockAdmin(locked)
                }
            ))
            .disabled(!manager.adminPasswordIsSet)

            if manager.adminPasswordIsSet {
                Button("清除管理密码", role: .destructive) {
                    manager.clearAdminPassword()
                    message = "已清除管理密码，锁定也已关闭"
                }
            }

            if let message = message {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(Color.secondary)
            }
        }
    }

    private func savePassword() {
        guard newPassword == confirmPassword else {
            message = "两次输入不一致"
            return
        }
        guard newPassword.count >= 4 else {
            message = "密码太短（至少 4 位）"
            return
        }
        if manager.setAdminPassword(newPassword) {
            message = "已保存管理密码"
            newPassword = ""
            confirmPassword = ""
        } else {
            message = "保存失败（Keychain 写入被拒绝）"
        }
    }
}
