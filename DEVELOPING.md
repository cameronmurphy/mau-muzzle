# Developing

## Build

Needs Xcode command line tools.

```sh
make app       # compile + assemble + sign into build/
make install   # the above, then let the app install itself
make selftest  # exercise the decision table
make status    # running MAU instances, agent state, recent log
make clean
```

`make install` just runs the built app with `--install`, which is the same
thing double-clicking it does. The app owns its own installation: it copies
itself to `~/Applications`, then writes and loads the LaunchAgent.

## Modes

| Command | Effect |
| --- | --- |
| (no args) / `--install` | Install: copy to `~/Applications`, load the agent. |
| `--watch` | Watch app launches and activations. What the LaunchAgent runs. |
| `--status` | List running MAU instances and whether each is silent or hidden. |
| `--selftest` | Exercise the decision table. No side effects. |

## How it decides

MAU is started with `-silent` when it's launched in the background. That's the
instance that pops up uninvited, so it's the only one touched. The argument is
read from the process's argv with `sysctl(KERN_PROCARGS2)`, in-process.

It watches `NSWorkspace` for two events:

- **Launch** of a silent MAU: hide it immediately. MAU can put a window up
  without taking focus, and that window should stay out of sight too.
- **Activation** of a silent MAU: decide whether you brought it forward or it
  brought itself forward. If it brought itself, hide it and reactivate the app
  that was frontmost before.

Deciding "was this you" uses input timing from `CGEventSource`, which needs no
Accessibility or Input Monitoring grant:

- A left mouse-up in the last 0.5s means you clicked something, such as the Dock
  icon. The Dock activates on mouse-up, so a real click lands well inside that.
- Command held down means Cmd-Tab.
- Typing is deliberately not evidence. MAU jumping in front while you type is
  exactly the case this exists for.

For the first 5 seconds after launch, activation is always muzzled, so a click
you happened to make at the moment it popped up doesn't count.

Each activation is judged on its own, with no "user released it" state. So if
you open MAU, switch away, and it jumps back in front later, it's hidden again.

`decide(silent:sinceLaunch:sinceClick:commandHeld:)` is pure and covered by
`--selftest`.

### What it can't do

Activation is reported after it happens, so MAU is in front for a moment before
it's hidden. macOS gives another process no way to stop an app activating in
the first place.

An Accessibility "press" on the Dock icon (such as from AppleScript) isn't a
mouse event, so it counts as MAU activating itself and gets muzzled. Real clicks
are fine.

## Install internals, and App Translocation

Same approach as privileges-rearm:

- **App Translocation.** A quarantined app opened from `~/Downloads` runs from a
  read-only randomized mount, not in place. `originalPath(of:)` resolves it back
  via `SecTranslocateCreateOriginalPathForURL`, bound with `dlsym` because it's
  C-only in the SDK.
- **Ordering.** Starting the installed copy can tear down the translocated mount
  we're running from, so cleanup and logging happen before `launchctl
  bootstrap`, which is the last thing the installer does.
- **Cleanup.** Only a source carrying `com.apple.quarantine` is trashed, so a
  local build is never deleted.

The installer boots out any running watcher before replacing the bundle, so
reinstalling over a running copy is safe.

## Signing

`make` auto-detects a `Developer ID Application` identity. Override with
`make app SIGN_ID="..."`, or `SIGN_ID=-` for ad-hoc. `make sign-info` shows
what it picked.

No TCC grant is involved, so ad-hoc signing works for local use. Developer ID
signing and notarization only matter for a build that will be downloaded, since
downloads are quarantined and Gatekeeper refuses unnotarized apps.

```sh
xcrun notarytool store-credentials mau-muzzle   # once
make notarize
```

## CI

`.github/workflows/build.yml` is the same pipeline as privileges-rearm, and uses
the same secrets. It builds, signs, uploads an artifact, and for `v*` tags it
notarizes, staples, and attaches to a release. Without secrets it falls back to
an unsigned compile check.
