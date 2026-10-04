// Sends a command to a running debug build of DJI Controller.
// Build: swiftc -O -o /tmp/djictl tools/djictl.swift
// Usage: djictl "status /tmp/status.json" | "mode quad" | "mute 2" | "gain 3 4" | "record" | "snapshot /tmp/x.png"
import Foundation

guard CommandLine.arguments.count > 1 else {
    print("usage: djictl \"<command>\"")
    exit(1)
}
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("com.sauerdev.djicontroller.debug"),
    object: CommandLine.arguments.dropFirst().joined(separator: " "),
    userInfo: nil,
    deliverImmediately: true)
