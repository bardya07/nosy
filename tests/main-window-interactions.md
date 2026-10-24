# Main window interaction regression

The installed build reproduced the owner's failure: clicking the visible Session name field immediately removed the field from the accessibility tree.

The old dismissal monitor compared an AppKit background view's flipped point with a SwiftUI named-coordinate panel rectangle. Titlebar insets and changing window geometry made those coordinates disagree. It also excluded the three toggle buttons from the protected region, so mouse down could dismiss a panel before the same button's action reopened it.

The first replacement (af0b4b1) kept an AppKit local event monitor with a polling timer; it no longer dismissed on inner clicks but outside clicks failed to dismiss in the interaction test. It also sat inside a `ViewThatFits` that held two copies of the fields, so swapping copies could reset panel state and contend for text focus.

Current design is plain SwiftUI. The toggle row plus the open panel publish one frame in a named coordinate space; a root `SpatialTapGesture` (simultaneous, active only while a panel is open) closes the panel when a click ends outside that frame. It fires on mouse-up after the clicked control has acted, so nothing is removed mid-click and toggles never double-toggle. A zero-size `.cancelAction` button closes on Escape regardless of focus. The details live in one `ScrollView` capped to the screen instead of `ViewThatFits`. Removing movement transitions keeps controls in place through a click.

Folder selection stays open. Long folder lists scroll while New folder and its name field remain reachable. (A Save to wheel morph was tried and dropped as unverified.) The whole custom terms disclosure row toggles its editor. Decorative borders, material, and native measurement views do not hit test. Press feedback retains the outer hit shape. Microphone discovery only publishes actual device changes, avoiding menu rebuilds on unchanged hover. The mic menu uses a full size circular button with hover and press feedback. Native traffic lights share the custom titlebar's vertical center.

`MainWindowInteraction.swift` hosts the real SwiftUI view in a native window, locates rendered bounds with test-only transparent anchors, and posts AppKit mouse/key events through NSApplication's event loop. It checks inline folder selection, New folder typing, Home navigation, Session typing, the native subject menu and autosave, the custom terms disclosure and text editor, direct dropdown switching, outside control actions, Escape, repeated toggles, a held edge press, and traffic light centering. Fixtures use temporary folders and never record or play audio.

## MBB322 Chemistry investigation

The owner's file contains an explicit `subject: chemistry`, schema 1, with an empty secondary subject. Every revision of SubjectCatalog since subject routing was introduced in `534420f` maps MBB to Biology. Auto resolves the folder name without persisting a guessed subject. Legacy migration maps biochemistry/biochem to biology, off/none to general, and business-economics to meetings-work; it never maps anything to chemistry. The old popover and the current draft capture their destination folder when opened, and autosave writes the draft's existing subject or an explicit menu selection.

No code path was found that generates Chemistry for MBB322 automatically. An explicit Chemistry selection is supported, so its origin cannot be determined from the file alone. Regression tests cover Auto remaining Auto after term autosave, opening/closing without writing settings, explicit Chemistry surviving autosave/migration, and pending saves remaining attached to the original folder. No speculative migration was added and the owner's file was not edited.

## Verification

Passed `./build.sh`, `tests/run_unit.sh` (including the native interaction tests), `tests/run_pipeline.sh` with real Whisper and vocabulary refinement, and strict Swift 6 typechecking for `arm64-apple-macos14.0`. Existing deprecation/capture warnings remain unchanged. Generated the isolated snapshot set and visually inspected light/dark Save to, New folder, Session, collapsed/expanded Vocabulary, and both mode captions. Native snapshot sizing checks also passed.

The interaction test needs an unlocked, logged in GUI session. When the screen is locked it prints SKIPPED instead of failing on focus and hit checks that cannot work there.
