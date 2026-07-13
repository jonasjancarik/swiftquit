# Swift Quit

Swift Quit is a dockless macOS menu bar utility that makes the red close button quit an app when it closes that app's last standard window.

This fork targets `macOS 15+` and keeps the original product shape intact:

- menu bar utility with `LSUIElement = true`
- explicit include or exclude rules for bundled apps
- RedQuits-style handling that distinguishes the last standard window before it closes
- native Accessibility monitoring built on `AXUIElement`
- native launch-at-login integration built on `SMAppService`
- event-driven close-button checks with no continuous background polling

## Requirements

- macOS 15 or later
- Xcode 26.4 or later recommended
- Accessibility permission for Swift Quit

## How It Works

Swift Quit installs a global left-click monitor. When a click lands on an enabled Accessibility close button, it snapshots that app's windows before macOS handles the close.

If the clicked window is the app's only standard window, Swift Quit sends the app a normal quit request immediately. This avoids the windowless state that can make apps such as Pages and TextEdit open a document chooser. If two or more standard windows are open, Swift Quit does nothing and macOS closes only the clicked window normally.

Dialogs, sheets, palettes, and other auxiliary windows do not count as standard windows. Ambiguous Accessibility results are skipped rather than risking an incorrect quit. Keyboard commands such as Command-W are not intercepted.

If an app ignores a quit request, Swift Quit briefly verifies the result and then enters a short per-app cooldown instead of repeatedly hammering the same process.

Rule precedence is:

1. protected apps are never terminated
2. explicit include or exclude rules are applied
3. optional safety protections can keep browser hosts, accessory/background apps, hidden apps, and apps with minimized or hidden standard windows running
4. the pre-close snapshot must contain exactly one qualifying standard window

Protected apps include Swift Quit itself plus core system processes such as Finder, Dock, `SystemUIServer`, Control Center, Spotlight, and `loginwindow`.

Accessory/background apps, minimized windows, and hidden apps/windows are protected by default. Browser protection is optional and disabled by default, so Safari and other browsers receive the same last-window behavior as other regular apps.

## First Launch

1. Launch Swift Quit.
2. If macOS has not granted Accessibility access yet, Swift Quit will show a recovery alert and offer to open the correct System Settings pane.
3. In System Settings, go to `Privacy & Security > Accessibility` and enable Swift Quit.
4. Return to Swift Quit. It re-checks permission automatically when the app becomes active or the settings window regains focus.

Manually opening Swift Quit from Finder, Spotlight, Xcode, or your Applications folder always shows Settings. Opening Swift Quit again while it is already running also brings Settings forward.

Swift Quit treats ordinary AppKit launches conservatively as manual, including launches from Finder, Spotlight, Xcode, Applications, and login items. Settings will stay hidden only for a launch source that Swift Quit can positively classify as background. For those confirmed background launches, Settings still appears when one of these is true:

- Accessibility permission is missing
- `Hide settings after confirmed background launch` is disabled
- the menu bar icon is hidden and Settings needs to remain reachable

## Launch At Login

Swift Quit uses `SMAppService.mainApp` on macOS 15+.

In Settings you can:

- enable or disable launch at login
- inspect the current login item state
- jump directly to `System Settings > General > Login Items` if macOS requires approval or the login item needs attention

Known recovery behavior:

- if the item is already registered, Swift Quit refreshes state instead of treating it as a failure
- if macOS denies registration, Swift Quit surfaces a `Needs Approval` state
- if the item is already unregistered, Swift Quit refreshes back to `Disabled`
- if stored settings say launch at login should be enabled but macOS reports it disabled, Swift Quit retries registration at startup and surfaces any approval or error state

## Settings

The settings window is implemented in SwiftUI and exposes:

- launch at login
- menu bar icon visibility
- whether confirmed background launches hide Settings
- rule mode: all apps except listed, or only listed apps
- safety options for browsers and web apps, accessory/background apps, minimized windows, and hidden apps/windows
- app rules with icon, display name, and resolved bundle path metadata
- diagnostics for Accessibility permission, launch-at-login state, active safety options, and recent termination decisions

App rules are stored primarily by bundle identifier so they remain stable if an app moves on disk.

## Build

```bash
xcodebuild -project "Swift Quit.xcodeproj" -scheme "Swift Quit" -destination "platform=macOS" build
```

Unsigned release archive:

```bash
xcodebuild -project "Swift Quit.xcodeproj" -scheme "Swift Quit" -configuration Release -destination "generic/platform=macOS" -archivePath /tmp/SwiftQuit.xcarchive CODE_SIGNING_ALLOWED=NO archive
```

Developer ID distribution builds use the separate `Distribution` configuration, which keeps hardened runtime enabled and expects a local `Developer ID Application` signing identity:

```bash
xcodebuild -project "Swift Quit.xcodeproj" -scheme "Swift Quit" -configuration Distribution -destination "generic/platform=macOS" archive
```

## Test

```bash
xcodebuild test -project "Swift Quit.xcodeproj" -scheme "Swift Quit" -destination "platform=macOS"
```

The unit suite covers:

- last-window close-button decisions, multi-window behavior, dialogs, ambiguous state, and Safari behavior
- termination rule precedence and safety options
- settings-presentation policy for launch, activation, and reopen flows
- legacy defaults and safety-option migration into the typed settings store
- migration idempotence and migration-version behavior
- login item state mapping, approval recovery, and toggle behavior
- cooldown behavior for apps that refuse to quit

## Legacy Migration

On first launch after upgrading, Swift Quit migrates the legacy `SwiftQuitSettings` and `SwiftQuitExcludedApps` defaults into the typed `SwiftQuitSettingsV2` store and records a one-time migration version key.

## Notes

- Swift Quit only accepts bundled `.app` selections in the app-rule picker.
- Hidden apps/windows and minimized windows count as open by default.
- Browser-host protection can be enabled when browsers should stay running after their last window closes.
- Accessory-app, hidden-window, and minimized-window protections can be relaxed in Settings.
- Returning from System Settings refreshes permission and login-item state without forcing Settings back open after you close it.
- Storyboard UI and older third-party window-monitoring dependencies were removed in favor of native macOS APIs.
