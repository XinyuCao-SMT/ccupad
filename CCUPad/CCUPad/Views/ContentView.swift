//
//  ContentView.swift
//  CCUPad
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var manager: CCUManager
    @State private var selection = 0

    var body: some View {
        TabView(selection: $selection) {
            DashboardView()
                .tabItem { Label("主控台", systemImage: "slider.horizontal.3") }
                .tag(0)

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
        .tint(Theme.accent)
    }
}
