# Updating Amaranth

Amaranth never updates on its own. It can tell you when a newer build is out, and it installs one only when you click
**Install and Relaunch**.

## Checking for a newer build

- Choose **Amaranth ▸ Check for Updates…** at any time.
- Amaranth also checks once each time it opens. You can turn that off in **Settings → Updates**. There is no
  background timer.
- When a newer build exists, an **Update Available** button appears in the toolbar. Click **Later** to hide it until
  the next time you open the app. It stays hidden while you're recording.
- If the check at launch fails (you're offline, for example), nothing is shown. A check you start yourself tells you
  what went wrong.

## Where builds come from

**Settings → Updates** has three choices:

| Choice | What it does |
|---|---|
| **GitHub** (default) | Looks at this project's releases on GitHub. |
| **A local folder** | Looks in a folder you pick, such as a shared drive. Useful if you build Amaranth yourself. |
| **Off** | Never checks. |

**Include Debug builds** is off by default. Leave it off unless you're helping test.

Checking GitHub is the only time Amaranth uses the network, apart from downloading the models. It asks for the list
of releases and nothing else: no meeting content, no account, no identifier. Choose **Off** and Amaranth makes no
network requests of its own.

## Installing

Click **Install and Relaunch**. Amaranth won't start an install while you're recording, or if it isn't running from
your Applications folder.

Before anything is replaced, Amaranth checks the download:

- its size and checksum match what the release says;
- it is signed by the same developer as the copy you're running, and is the same app;
- it is built for your Mac and your version of macOS;
- it is the build the release says it is.

If any check fails, nothing is changed and Amaranth tells you why. If the swap itself fails, your current copy is put
back and the toolbar says **Update Didn't Install**. The details are in `~/Library/Logs/Amaranth/update.log`.

After a successful install the app reopens and the toolbar shows **Updated to build N** once. Meetings that were
still being processed carry on where they left off.

## Good to know

- Amaranth only ever offers a newer build. There is no way to go back to an older one from inside the app.
- Builds aren't notarized by Apple yet. The first time you open a copy you downloaded by hand, right-click it and
  choose **Open**.
- If you built Amaranth yourself without a signing team, it can't verify updates, so it won't install them. Build
  again from the latest code instead (`scripts/install-local.sh`).
