//
//  XCTestProbe.swift
//  iPhoneUse
//
//  Experiment: can this app talk to testmanagerd's runner service, the way an XCTest runner
//  does, to get the foreground app's accessibility snapshot in one call? Launch with
//  `-xctestProbe YES`; results go to Documents/xctest-probe.txt.
//

import Foundation

@objc private protocol XCTRunnerDaemon {
    func _XCT_enableAutomationMode(reply: @escaping (NSError?) -> Void)
}

enum XCTestProbe {
    static func run() {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("xctest-probe.txt")
        var lines: [String] = []
        func log(_ s: String) {
            lines.append("\(Date()) \(s)")
            try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        }
        log("start")
        // NSXPCConnection(machServiceName:) is marked unavailable on iOS; call it through the runtime.
        let sel = NSSelectorFromString("initWithMachServiceName:options:")
        let cls: AnyObject = NSXPCConnection.self
        guard let blank = cls.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue(),
              let raw = blank.perform(sel, with: "com.apple.dt.testmanagerd.runner", with: nil),
              let connection = raw.takeUnretainedValue() as? NSXPCConnection else {
            return log("could not create the connection")
        }
        connection.remoteObjectInterface = NSXPCInterface(with: XCTRunnerDaemon.self)
        connection.invalidationHandler = { log("invalidated (lookup denied or daemon refused)") }
        connection.interruptionHandler = { log("interrupted") }
        connection.resume()
        let started = Date()
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            log("error: \(error)")
        } as? XCTRunnerDaemon
        proxy?._XCT_enableAutomationMode { error in
            log(String(format: "REPLY after %.0f ms: error=%@", Date().timeIntervalSince(started) * 1000,
                       error.map { "\($0)" } ?? "nil"))
        }
        log("sent _XCT_enableAutomationModeWithReply:")
    }
}
