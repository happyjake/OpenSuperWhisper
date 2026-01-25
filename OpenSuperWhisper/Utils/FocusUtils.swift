//
//  FocusUtils.swift
//  OpenSuperWhisper
//
//  Created by user on 07.02.2025.
//

import AppKit
import ApplicationServices
import Carbon
import Cocoa
import Foundation
import KeyboardShortcuts
import SwiftUI

class FocusUtils {

    static func getCurrentCursorPosition() -> NSPoint {
        return NSEvent.mouseLocation
    }

    static func getCaretRect() -> CGRect? {
        // Get system element for access to all UI
        let systemElement = AXUIElementCreateSystemWide()

        // Get focused element
        var focusedElement: CFTypeRef?  // Keep as CFTypeRef? if you prefer
        let errorFocused = AXUIElementCopyAttributeValue(
            systemElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement)

        print("errorFocused: \(errorFocused)")
        guard errorFocused == .success else {
            print("Failed to get focused element")
            return nil
        }

        guard let focusedElementCF = focusedElement else {  // Optional binding to safely unwrap CFTypeRef
            print("Failed to get focused element (CFTypeRef is nil)")  // Extra safety check, though unlikely
            return nil
        }

        let element = focusedElementCF as! AXUIElement
        // Get selected text range from focused element
        var selectedTextRange: AnyObject?
        let errorRange = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedTextRange)
        guard errorRange == .success,
            let textRange = selectedTextRange
        else {
            print("Failed to get selected text range")
            return nil
        }

        // Use parameterized attribute to get range bounds (caret position)
        var caretBounds: CFTypeRef?
        let errorBounds = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            textRange,
            &caretBounds)

        print("errorbounds: \(errorBounds), caretBounds \(String(describing: caretBounds))")
        guard errorBounds == .success else {
            print("Failed to get caret bounds")
            return nil
        }

        let rect = caretBounds as! AXValue

        return rect.toCGRect()
    }

    static func getFocusedWindowScreen() -> NSScreen? {
        let systemWideElement = AXUIElementCreateSystemWide()

        var focusedWindow: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindow)

        guard result == .success else {
            print("Failed to get focused window")
            return NSScreen.main
        }
        let windowElement = focusedWindow as! AXUIElement

        var windowFrameValue: CFTypeRef?
        let frameResult = AXUIElementCopyAttributeValue(
            windowElement,

            "AXFrame" as CFString,
            &windowFrameValue)

        guard frameResult == .success else {
            print("Failed to get window frame")
            return NSScreen.main
        }
        let frameValue = windowFrameValue as! AXValue

        var windowFrame = CGRect.zero
        guard AXValueGetValue(frameValue, AXValueType.cgRect, &windowFrame) else {
            print("Failed to extract CGRect from AXValue")
            return NSScreen.main
        }

        for screen in NSScreen.screens {
            if screen.frame.intersects(windowFrame) {
                return screen
            }
        }

        return NSScreen.main
    }

}

extension AXValue {
    fileprivate func toCGRect() -> CGRect? {
        var rect = CGRect.zero
        let type: AXValueType = AXValueGetType(self)

        guard type == .cgRect else {
            print("AXValue is not of type CGRect, but \(type)")  // More informative error
            return nil
        }

        let success = AXValueGetValue(self, .cgRect, &rect)

        guard success else {
            print("Failed to get CGRect value from AXValue")
            return nil
        }
        return rect
    }
}
