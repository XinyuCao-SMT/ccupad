//
//  AppStore.swift
//  CCUPad
//
//  本地持久化：设备清单、每台设备的参数映射、设置。
//  都是小 JSON，UserDefaults 足够；密码单独进 Keychain。
//

import Foundation

enum AppStore {
    private static let devicesKey = "ccupad.devices.v1"
    private static let mapsKey = "ccupad.parametermaps.v1"
    private static let settingsKey = "ccupad.settings.v1"

    // MARK: 设备清单

    static func loadDevices() -> [CCUDevice] {
        guard let data = UserDefaults.standard.data(forKey: devicesKey),
              let devices = try? JSONDecoder().decode([CCUDevice].self, from: data) else {
            return []
        }
        return devices
    }

    static func saveDevices(_ devices: [CCUDevice]) {
        guard let data = try? JSONEncoder().encode(devices) else { return }
        UserDefaults.standard.set(data, forKey: devicesKey)
    }

    // MARK: 参数映射（按设备 UUID 存）

    static func loadMaps() -> [UUID: ParameterMap] {
        guard let data = UserDefaults.standard.data(forKey: mapsKey),
              let raw = try? JSONDecoder().decode([String: ParameterMap].self, from: data) else {
            return [:]
        }
        var out: [UUID: ParameterMap] = [:]
        for (key, value) in raw {
            if let id = UUID(uuidString: key) { out[id] = value }
        }
        return out
    }

    static func saveMaps(_ maps: [UUID: ParameterMap]) {
        var raw: [String: ParameterMap] = [:]
        for (key, value) in maps { raw[key.uuidString] = value }
        guard let data = try? JSONEncoder().encode(raw) else { return }
        UserDefaults.standard.set(data, forKey: mapsKey)
    }

    // MARK: 设置

    static func loadSettings() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: settingsKey),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return settings
    }

    static func saveSettings(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: settingsKey)
    }

    // MARK: 导出

    /// 参数清单 / 诊断信息写到「文件」App 里的应用目录，方便回传排查。
    /// 返回写成功的文件路径（相对 Documents）。
    @discardableResult
    static func writeExport(named name: String, text: String) -> String? {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let url = documents.appendingPathComponent(name)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return name
        } catch {
            return nil
        }
    }
}
