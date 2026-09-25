# WallpaperRotator

Automatically changes your Windows desktop wallpaper to a fresh random photo **every 5 minutes**.

It's a small PowerShell script run by Windows Task Scheduler, with no installs or API keys.

## What it does

Every 5 minutes it:

1. Checks your main screen's resolution (e.g. 1920×1080).
2. Downloads a random high-quality photo at exactly that size from [Lorem Picsum](https://picsum.photos/).
3. Saves it in the `cache` folder, keeping only the **5 most recent** images so the folder doesn't grow.
4. Sets it as the wallpaper on **all monitors**, using the *Fill* position.

It runs completely hidden, so no windows flash on screen.

## Requirements

- Windows 10 or 11
- Windows PowerShell 5.1 (built into Windows)
- An internet connection

## Files

| File | Purpose |
|---|---|
| `Change-Wallpaper.ps1` | Downloads a new photo and sets it as the wallpaper (runs once, then exits) |
| `RunHidden.vbs` | Launches the script with no visible PowerShell window |
| `cache/` | Recent downloaded wallpapers (created automatically, not stored in Git) |

## Setup

### 1. Get the files

Put the folder somewhere permanent, e.g. `C:\Users\<you>\WallpaperRotator`:

```bash
git clone git@github.com:jamalxcode/WallpaperRotator.git
```

(or click **Code → Download ZIP** on GitHub and extract it). If Windows blocks the downloaded files, right-click each one → **Properties** → tick **Unblock**.

### 2. Point the launcher at your folder

Open `RunHidden.vbs` in Notepad and change the path to where **your** `Change-Wallpaper.ps1` is:

```vb
objShell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File ""C:\Users\<you>\WallpaperRotator\Change-Wallpaper.ps1""", 0, False
```

### 3. Test it once

Double-click `RunHidden.vbs`. Within a few seconds your wallpaper should change.

### 4. Schedule it every 5 minutes

Open **PowerShell** in the WallpaperRotator folder and run:

```powershell
$action  = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$PWD\RunHidden.vbs`""
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 3650)
Register-ScheduledTask -TaskName 'WallpaperRotator' -Action $action -Trigger $trigger
```

That's it. The wallpaper now changes every 5 minutes while you're signed in.

## Managing it

| To… | Run in PowerShell |
|---|---|
| Change wallpaper right now | `Start-ScheduledTask WallpaperRotator` |
| Pause it | `Disable-ScheduledTask WallpaperRotator` |
| Resume it | `Enable-ScheduledTask WallpaperRotator` |
| Remove it completely | `Unregister-ScheduledTask WallpaperRotator -Confirm:$false` |

You can also manage it in the **Task Scheduler** app, where it's listed as **WallpaperRotator** in the Task Scheduler Library.

## Customizing

**Change how often it rotates:** re-run the step 4 commands with a different `-Minutes` value, after first removing the old task (see above).

**Change the kind of photos:** edit the `$url` line in `Change-Wallpaper.ps1`. Picsum supports options such as:

| URL | Result |
|---|---|
| `https://picsum.photos/$width/$height` | Random photo (default) |
| `https://picsum.photos/$width/$height?grayscale` | Black & white |
| `https://picsum.photos/$width/$height?blur=2` | Softly blurred (easier to see desktop icons) |

**Keep more or fewer cached images:** change `-Skip 5` in `Change-Wallpaper.ps1`.

**Change how the image fits the screen:** change `DesktopWallpaperPosition.Fill` to `Fit`, `Stretch`, `Center`, `Tile` or `Span`.

## Troubleshooting

| Problem | Fix |
|---|---|
| Wallpaper never changes | Check the task exists and is enabled: `Get-ScheduledTask WallpaperRotator`. Make sure the path in `RunHidden.vbs` is correct. |
| Want to see the error | Run the script directly in a visible window: `powershell -NoProfile -ExecutionPolicy Bypass -File .\Change-Wallpaper.ps1` |
| Stops while offline | Expected. It needs internet to download a photo, and resumes on the next run once you're back online. |
| Photo looks stretched on a second monitor | The photo is sized for the main screen. Try the `Span` or `Fit` position (see Customizing). |
