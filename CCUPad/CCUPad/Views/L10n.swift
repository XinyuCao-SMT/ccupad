//
//  L10n.swift
//  CCUPad
//
//  界面文案的本地化。
//
//  为什么还需要这个文件：SwiftUI 里**直接写**的字符串字面量（`Text("主控台")`、
//  `Button("连接")`、`Section("地址")` …）本身就是 `LocalizedStringKey`，
//  系统会自动去 `Localizable.strings` 查表 —— 那部分一行代码都不用改。
//
//  但**从数据模型算出来的**文案（连接状态、tally 文字、通道名、各种提示）是 `String`，
//  系统不会查表，必须在产生它的地方显式查一次。
//
//  查不到就原样返回键本身，而键就是中文原文 —— 所以中文设备上什么都不用做。
//

import Foundation

enum L10n {
    /// 按当前语言查一次表；查不到返回键本身（也就是中文原文）。
    static func t(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: key, table: nil)
    }

    /// 带参数的文案：键里写 `%lld` / `%@`，这里按 format 填。
    static func f(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: t(key), arguments: arguments)
    }
}
