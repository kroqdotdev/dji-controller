// Sends a command to a running debug build of Lavboard.
// Build: swiftc -O -o /tmp/lavctl tools/lavctl.swift
// Usage: lavctl "status /tmp/status.json" | "mode quad" | "mute 2" | "gain 3 4" | "record" | "snapshot /tmp/x.png"
import Foundation

guard CommandLine.arguments.count > 1 else {
    print("usage: lavctl \"<command>\"")
    exit(1)
}
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("com.sauerdev.lavboard.debug"),
    object: CommandLine.arguments.dropFirst().joined(separator: " "),
    userInfo: nil,
    deliverImmediately: true)
