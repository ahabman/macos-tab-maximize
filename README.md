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

- **Input recency (default, free).** Asking whether Command is held does not work, and
  measurement is how that was settled: the switcher commits when you *release* Command,
  so by the time the activation notification arrives the modifier is always already up.
  What survives is timing. `CGEventSource` reports how long ago the keyboard and the
  mouse were last used, without any TCC grant, because it exposes input *recency*, not
  input *content*. A real Cmd+Tab measured 0.27 s since the last keystroke against
  35.65 s since the last click; clicking back to another app measured 0.01 s since the
  click. So the rule is simply: the keyboard was used more recently than the mouse, and
  within the last two seconds.
- **Event tap (optional).** A listen-only tap at the head of the session tap, which runs
  before symbolic hotkey dispatch. Observes the keystroke directly regardless of timing,
  but costs a second TCC grant — Input Monitoring. Only needed if the timing heuristic
  misjudges your habits; when it is running it takes precedence.

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

The first build after creating the certificate may show a **"codesign wants to use a
key in your keychain"** dialog — click **Always Allow** and it will not ask again.
`make cert` tries to prevent it outright by setting the key's partition list, which
needs your login keychain password; neither `-T` nor `-A` at import time is sufficient
on its own.

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

## What testing turned up

Findings from verifying this on macOS 26, all of which shaped the code:

- **A minimized window lies about its subrole.** The same TextEdit document window
  reports `AXStandardWindow` while visible and **`AXDialog`** once minimized (Finder
  behaves identically). Filtering candidates by subrole — the obvious implementation —
  rejects exactly the windows this app exists to restore. Minimized windows are
  therefore classified by role alone.
- **`kAXWindows` contains things that are not windows.** Finder reports its desktop as
  an `AXScrollArea` in the same list. Counting it as a visible window would have meant
  Finder's minimized windows never came back.
- **The window server's window count is not a window count.** AppKit keeps offscreen
  backing windows for menu bars and toolbars at layer 0; a TextEdit with no documents
  open at all reported nine of them. Only the *onscreen* count is meaningful, and that
  is all this app uses it for.
- **macOS restores an app's minimized windows as a group, and there is no way around
  it.** Deminiaturizing one window of an app with several minimized brings back all of
  them. This was bisected rather than assumed: it happens with a bare `AXMinimized`
  write and no raise and no main (`--restore-ax`), and equally when pressing a single
  window's own Dock tile (`--dock-press`), which is the exact gesture a person uses to
  restore one window. Putting the siblings back down afterwards was also tried and does
  not work — the re-minimize is overridden by the restore animation still in flight, and
  forcing it would mean windows visibly popping up and sinking again.

  So "Restore All Minimized Windows" only controls how many windows TabMaximize writes
  to; how many actually appear is the system's call. In practice this matches what
  Option+Cmd+Tab does anyway.
- **A shell-launched binary has no Accessibility access.** TCC attributes it to the
  terminal, not to this bundle, so `Contents/MacOS/TabMaximize --dump-ax` fails unless
  the terminal itself holds the grant. `make dump` launches the bundle through
  LaunchServices instead and reads results back out of the unified log.

## Requirements

macOS 13+. Builds with Swift 6 and Command Line Tools — no Xcode needed.
