//
//  GodotAppDelegate.swift
//
//

#if os(macOS)

import Foundation
import AppKit

import SwiftGodot

open class GodotAppDelegate: NSObject, NSApplicationDelegate {
    weak var app: GodotApp?

    public func applicationDidBecomeActive(_ aNotification: Notification) {
        app?.applicationDidBecomeActive()
    }
    
    public func applicationDidResignActive(_ aNotification: Notification) {
        app?.applicationDidResignActive()
    }

    /// Shut the engine down while its own globals are still alive, rather than
    /// letting `exit()` race Godot's C++ static destructors. See the teardown
    /// note in `GodotApp`.
    public func applicationWillTerminate(_ aNotification: Notification) {
        app?.shutdown()
    }
}

#endif
