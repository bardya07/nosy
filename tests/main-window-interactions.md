# Main window interaction regression

The installed build reproduced the owner's failure: clicking the visible Session name field immediately removed the field from the accessibility tree.

The old dismissal monitor compared an AppKit background view's flipped point with a SwiftUI named-coordinate panel rectangle. Titlebar insets and changing window geometry made those coordinates disagree. It also excluded the three toggle buttons from the protected region, so mouse down could dismiss a panel before the same button's action reopened it.

The replacement uses a native boundary around both the toggle row and its inline panel. AppKit converts the event into that boundary's own bounds. It ignores native menu windows, returns every event unchanged, and dismisses outside clicks only after the press/tracking finishes. A default run loop timer waits for release after native tracking instead of depending on a mouse up monitor. SwiftUI can report a native visible rectangle larger than the measurement view, so the boundary is intersected with its own bounds. Removing movement transitions keeps controls in place through a click.

Folder selection stays open. Long folder lists scroll while New folder and its name field remain reachable. The whole custom terms disclosure row toggles its editor. Decorative borders, material, and native measurement views do not hit test. Press feedback retains the outer hit shape. Microphone discovery only publishes actual device changes, avoiding menu rebuilds on unchanged hover. The mic menu has a subtle circular fill and press feedback. Native traffic lights share the custom titlebar's vertical center.

`MainWindowInteraction.swift` hosts the real SwiftUI view in a native window, locates rendered bounds with test-only transparent anchors, and posts AppKit mouse/key events through NSApplication's event loop. It checks folder rows, New folder typing, Session typing, the native subject menu and autosave, the custom terms disclosure and text editor, direct dropdown switching, same-button close, outside control actions, Escape, repeated toggles, a held edge press, and traffic light centering. Fixtures use temporary folders and never record or play audio.

## MBB322 Chemistry investigation

The owner's file contains an explicit `subject: chemistry`, schema 1, with an empty secondary subject. Every revision of SubjectCatalog since subject routing was introduced in `534420f` maps MBB to Biology. Auto resolves the folder name without persisting a guessed subject. Legacy migration maps biochemistry/biochem to biology, off/none to general, and business-economics to meetings-work; it never maps anything to chemistry. The old popover and the current draft capture their destination folder when opened, and autosave writes the draft's existing subject or an explicit menu selection.

No code path was found that generates Chemistry for MBB322 automatically. An explicit Chemistry selection is supported, so its origin cannot be determined from the file alone. Regression tests cover Auto remaining Auto after term autosave, opening/closing without writing settings, explicit Chemistry surviving autosave/migration, and pending saves remaining attached to the original folder. No speculative migration was added and the owner's file was not edited.

## Verification

Passed `./build.sh`, `tests/run_unit.sh` (including the native interaction tests), `tests/run_pipeline.sh` with real Whisper and vocabulary refinement, and strict Swift 6 typechecking for `arm64-apple-macos14.0`. Existing deprecation/capture warnings remain unchanged. Generated the isolated snapshot set and visually inspected light/dark Save to, New folder, Session, collapsed/expanded Vocabulary, and both mode captions. Native snapshot sizing checks also passed.
