# TabMaximize

Command-Tabbing to an app whose windows are all minimized to the Dock brings the app
forward but shows nothing — the menu bar changes, the screen does not. macOS can do the
right thing, but only if you hold Option before releasing Cmd+Tab.

TabMaximize makes that the default. It is a menu-bar-only background agent: when you
Cmd+Tab to an app whose windows are all minimized, it deminiaturizes the front one.

## Install

```sh
make cert      # once — see "Why a certificate" below
make install   # builds, signs, copies to /Applications, launches
```

Then grant Accessibility access when prompted, or via
**System Settings › Privacy & Security › Accessibility**.

## How it decides

On every `NSWorkspace.didActivateApplicationNotification`:

1. Skip anything that is not a regular app, plus a denylist (Dock, Spotlight, Control
   Center, itself…).
2. Unless "Only After Cmd+Tab" is off, require evidence the switch came from the
   switcher — Command still physically held at notification time, or, if the optional
   event tap is enabled, a Cmd+Tab keystroke within the last 750 ms.
3. Ask Accessibility for the app's windows, retrying at 0/30/80/160/300/500 ms because
   the list is routinely empty or stale at the moment of activation.
4. Act **only** if every standard window is minimized. One visible window means macOS is
   already showing something, so it does nothing.
5. Unminimize the app's main window (or the front-most minimized one), confirm it
   actually came back, then raise it.

Apps with no windows at all are left strictly alone — Cmd+Tab to a running-but-windowless
app never conjures a window.

## Menu

| Item | Meaning |
|---|---|
| Enabled | Master switch |
| Only After Cmd+Tab | Off = restore on any activation, including Dock clicks |
| Restore All Minimized Windows | Off = just the front one |
| Launch at Login | `SMAppService`; needs the app in /Applications |
| Cmd+Tab Event Tap | Optional, costs an Input Monitoring grant — see below |
| Dry Run | Log what would happen, change nothing |
| Verbose Logging | Per-attempt detail in the unified log |

## Detecting Cmd+Tab

Cmd+Tab is a system symbolic hotkey: WindowServer hands it to the Dock, and the switcher
holds a keyboard grab, so `NSEvent.addGlobalMonitorForEvents` never sees it. Two
mechanisms are available, and the cheap one is tried first:

- **Modifier check (default, free).** The activation handler reads
  `NSEvent.modifierFlags` synchronously. If Command is still held, it was a Cmd+Tab.
  This catches every switch where you have not yet let go of Command.
- **Event tap (optional).** A listen-only tap at the head of the session tap, which runs
  before symbolic hotkey dispatch. Catches the keystroke regardless of timing, but costs
  a second TCC grant — Input Monitoring. Turn it on only if switches are being missed.

If both are unsatisfying, turn "Only After Cmd+Tab" off: TabMaximize then restores on any
activation of an all-minimized app. Dock clicks already do this themselves, so the
practical difference is small.

## Why a certificate

TCC anchors an Accessibility grant to the bundle identifier *and* a code requirement
captured at grant time. Ad-hoc signing (`codesign -s -`) has no certificate, so that
requirement collapses to the exact build's cdhash — and every rebuild invalidates it.
The symptom is easy to misread: the app still appears in System Settings with its switch
**on**, while `AXIsProcessTrusted()` returns **false**.

`make cert` creates a self-signed code signing certificate once, which makes the
requirement `identifier "com.bamf.tabmaximize" and certificate leaf H"…"` — stable
forever. Verify with:

```sh
codesign -d -r- /Applications/TabMaximize.app   # want 'certificate leaf', not 'cdhash'
```

The certificate is *not* added to the trust store; `codesign` does not need that, and
skipping it avoids an authorization dialog. `security find-identity -v -p codesigning`
will not list it as a result — that is expected.

Changing `CFBundleIdentifier` resets the grant, so it is fixed at `com.bamf.tabmaximize`.

## Debugging

```sh
make logs                         # live unified log
make debug                        # run in the foreground with stderr output
make dump TARGET=TextEdit         # what AX reports for an app's windows
```

`--dump-ax` is the diagnostic that matters: it shows whether a minimized window still
appears in `kAXWindows` with `AXMinimized = true`. Standard AppKit apps do; some
Electron/Qt apps have historically not. If an app is never restored, dump it first.

## Requirements

macOS 13+. Builds with Swift 6 and Command Line Tools — no Xcode needed.
