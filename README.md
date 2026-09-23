# mau-muzzle

Stops Microsoft AutoUpdate from popping up and stealing focus while you work.

On a managed Mac, MAU is launched in the background and then puts its window in
front of whatever you're doing, often mid-sentence. The auto-update setting is
locked by your MDM, so it can't be turned off. This keeps that window out of
the way instead.

- When MAU opens by itself, it's hidden and focus goes back to the app you were
  in.
- When you want it, click its Dock icon or Cmd-Tab to it, and it comes up
  normally.
- If it tries to jump in front again later, it's hidden again.

MAU is never closed, so updates still install. If you open MAU yourself (for
example from Help > Check for Updates), it's left alone.

## Install

Open `MAUMuzzle.app`. It copies itself to `~/Applications` and starts in the
background. No permissions to approve.

## If it's not working

Check the log:

```sh
tail ~/Library/Application\ Support/mau-muzzle/muzzle.log
```

Each time MAU comes to the front, there's a line saying whether it was muzzled
or allowed.

## Uninstall

```sh
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.camurphy.mau-muzzle.plist
rm -f ~/Library/LaunchAgents/com.camurphy.mau-muzzle.plist
rm -rf ~/Applications/MAUMuzzle.app
```

---

Building, signing, and how it works internally: [DEVELOPING.md](DEVELOPING.md).
