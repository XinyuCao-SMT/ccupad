//
//  ContentView.swift
//  CCUPad
//
//  分两个岗位两个台面：
//    · 音频主控台 —— 只管音频（推子 + tally），不出现彩条；
//    · 视频主控台 —— 只管彩条，**要管理密码**才能打开。
//  再加三个管理页（参数发现 / 设备 / 设置），它们受「锁定其他项目」控制。
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var manager: CCUManager
    @State private var selection = 0

    /// 管理页被锁上时，把选中页收回到前两页（音频 / 视频），
    /// 免得停在一个已经不存在（被隐藏）的页上。
    private var tabSelection: Binding<Int> {
        Binding(
            get: { manager.adminAreaVisible ? selection : min(selection, 1) },
            set: { selection = $0 }
        )
    }

    var body: some View {
        TabView(selection: tabSelection) {
            DashboardView()
                .tabItem { Label("音频", systemImage: "waveform") }
                .tag(0)

            VideoConsoleView()
                .tabItem {
                    Label("视频", systemImage: manager.videoConsoleAvailable
                          ? "rectangle.on.rectangle"
                          : "lock.fill")
                }
                .tag(1)

            if manager.adminAreaVisible {
                DiscoveryView()
                    .tabItem { Label("参数发现", systemImage: "magnifyingglass") }
                    .tag(2)

                DevicesView()
                    .tabItem { Label("设备", systemImage: "server.rack") }
                    .tag(3)

                SettingsView()
                    .tabItem { Label("设置", systemImage: "gearshape") }
                    .tag(4)
            }
        }
        .tint(Theme.accent)
    }
}
