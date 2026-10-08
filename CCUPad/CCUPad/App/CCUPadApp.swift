//
//  CCUPadApp.swift
//  CCUPad
//
//  iPad 上的索尼 CCU 音频增益 + Tally 面板。
//  协议层完全自己实现（HTTP Digest / WebSocket / MessagePack），工程零外部依赖。
//

import SwiftUI

@main
struct CCUPadApp: App {
    @StateObject private var manager = CCUManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(manager)
                .preferredColorScheme(.dark)
        }
    }
}
