//
//  ContentView.swift
//  CCUPad
//
//  四个页。「锁定其他项目」打开且未解锁时，只留主控台 —— 操作员看到的就是推子 + tally。
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var manager: CCUManager
    @State private var selection = 0

    /// 锁上时把选中页强制回到主控台，免得停在一个已经不存在（被隐藏）的页上。
    private var tabSelection: Binding<Int> {
        Binding(
            get: { manager.adminAreaVisible ? selection : 0 },
            set: { selection = $0 }
        )
    }

    var body: some View {
        TabView(selection: tabSelection) {
            DashboardView()
                .tabItem { Label("主控台", systemImage: "slider.horizontal.3") }
                .tag(0)

            if manager.adminAreaVisible {
                DiscoveryView()
                    .tabItem { Label("参数发现", systemImage: "magnifyingglass") }
                    .tag(1)

                DevicesView()
                    .tabItem { Label("设备", systemImage: "server.rack") }
                    .tag(2)

                SettingsView()
                    .tabItem { Label("设置", systemImage: "gearshape") }
                    .tag(3)
            }
        }
        .tint(Theme.accent)
    }
}
