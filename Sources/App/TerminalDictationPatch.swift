import AppKit
import GhosttyTerminal
import DevSpaceCore

/// Makes macOS dictation work in the embedded terminal.
///
/// Dictation queries the focused view's `NSTextInputClient.selectedRange()` /
/// `markedRange()` to establish an insertion point before delivering any text.
/// libghostty-spm's `AppTerminalView` returns `{NSNotFound, 0}` from both when
/// no IME composition is active (the idle state), which tells the dictation
/// system there is no insertion point — so dictated text is silently dropped.
/// Keyboard and IME input are unaffected (they don't consult those ranges),
/// which is why only dictation breaks. Upstream Ghostty returns an empty
/// `{0, 0}` range instead, and dictation works there.
///
/// Until the package is fixed, rewrite those two responses at runtime: call
/// the original implementation and map `NSNotFound` to the upstream-compatible
/// `{0, 0}`. Anything else passes through, so this degrades to a no-op if a
/// future package version fixes the underlying bug.
enum TerminalDictationPatch {
    static func install() {
        patch(#selector(NSTextInputClient.selectedRange))
        patch(#selector(NSTextInputClient.markedRange))
        Log.write("dictation: patched AppTerminalView NSTextInputClient ranges")
    }

    private static func patch(_ selector: Selector) {
        guard let method = class_getInstanceMethod(AppTerminalView.self, selector) else {
            Log.write("dictation: \(selector) not found on AppTerminalView — patch skipped")
            return
        }
        typealias RangeFn = @convention(c) (AnyObject, Selector) -> NSRange
        let original = unsafeBitCast(method_getImplementation(method), to: RangeFn.self)
        let patched: @convention(block) (AnyObject) -> NSRange = { view in
            let range = original(view, selector)
            return range.location == NSNotFound ? NSRange(location: 0, length: 0) : range
        }
        method_setImplementation(method, imp_implementationWithBlock(patched))
    }
}
