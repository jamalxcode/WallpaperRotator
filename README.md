# WallpaperRotator

Changes your Windows desktop wallpaper **every 5 minutes**, rotating through landscape photography, space images, live satellite views of Earth, today's news photos, museum masterpieces, wildlife and fun openly licensed photos. Each wallpaper gets a small caption telling you what you're looking at.

It's a PowerShell script run by Windows Task Scheduler, with no installs or API keys.

## Sources

Each run picks one source at random:

| Source | What you get |
|---|---|
| **Bing** | Bing's photo of the day (one of the last 8), in 4K |
| **Wikimedia Picture of the Day** | A featured photo from Wikimedia Commons, chosen from the last 60 days |
| **NASA Astronomy Picture of the Day** | A random pick from NASA's APOD archive since 2010: galaxies, nebulae, eclipses |
| **Live Earth** | One of three live views: **your region** right now (Meteosat, daytime only), **the Americas** (NOAA GOES-19, updated every 10 min, city lights at night), or **the whole Earth** from 1.5 million km (NASA EPIC) |
| **Wikipedia In the News** | Photos tied to today's top world stories from Wikipedia's front page |
| **The Met** | Public-domain masterpiece paintings from the Metropolitan Museum of Art |
| **Art Institute of Chicago** | Public-domain paintings: Van Gogh, Monet, Seurat and others |
| **Wikimedia Commons featured pictures** | Commons' best photos of animals, landscapes, mountains, beaches, night skies, cities and more (people and bones are skipped) |
| **Openverse** | Openly licensed photos of fun subjects: red pandas, hot air balloons, coral reefs, lantern festivals... Mature content is filtered out |
| **Google Earth View** | Striking satellite shots of the planet, with a Google Maps link to the spot |
| **NASA Image Library** | Nebulae, galaxies, planets, aurora and rocket launches |
| **Pixabay** | Editors' choice photos with SafeSearch on. Needs a free key (see below) and is skipped without one |

If a source is down, it quietly tries the next one. As a last resort it uses a random photo from [Lorem Picsum](https://picsum.photos/).

### How images are fitted

- **Photos shaped like your screen** fill it completely.
- **Tall or oddly shaped images**, such as portrait paintings, are shown whole on a blurred, darkened copy of themselves.
- **Earth from space** is shown whole on black.

### Caption

The bottom-right corner shows the title, a short description, and the source or credit. To read more about the current wallpaper, open `cache\current.txt`: it has the full details and a link.

## Requirements

- Windows 10 or 11
- Windows PowerShell 5.1 (built into Windows)
- An internet connection

## Files

| File | Purpose |
|---|---|
| `Change-Wallpaper.ps1` | Picks a source, downloads the image, adds the caption and sets it as the wallpaper (runs once, then exits) |
| `RunHidden.vbs` | Launches the script with no visible PowerShell window |
| `cache/` | Created automatically, not stored in Git. Holds recent wallpapers, `current.txt` (what's showing now) and `log.txt` (any source failures) |

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

All settings are at the top of `Change-Wallpaper.ps1`:

| Setting | What it does |
|---|---|
| `$Sources` | Which sources to rotate through, each with a weight: a source set to 12 shows up twelve times as often as one set to 1. Set it to 0 to drop a source. |
| `$ShowCaption` | `$false` hides the caption |
| `$RegionBox` / `$RegionName` | The area shown by the regional live satellite view, as `south,west,north,east` in degrees. The default covers the Arabian Peninsula and the Gulf. Meteosat covers Europe, Africa, the Middle East and the Indian Ocean; keep the box roughly 16:9. |
| `$KeepImages` | How many recent wallpapers to keep in `cache` |
| `$FunTopics` | Search words used by Openverse and Pixabay. Add your own favourites |

**Pixabay key:** sign up free at [pixabay.com](https://pixabay.com/accounts/register/), sign in, and open the [API docs](https://pixabay.com/api/docs/); your key is shown under *Parameters → key*. Save just the key in a file named `pixabay-key.txt` next to the script. Git ignores that file, so it's never committed. Normal keys get 1280-px-wide images, which look a little soft on large screens.

**Try a single source** without waiting for it to come up:

```powershell
.\Change-Wallpaper.ps1 NasaApod
```

The source names are `Bing`, `WikimediaPotd`, `NasaApod`, `LiveEarth`, `WikipediaNews`, `MetMuseum`, `ArtInstitute`, `CommonsFeatured`, `Openverse`, `EarthView`, `NasaImages` and `Pixabay`.

**Change how often it rotates:** remove the task (see above), then re-run the step 4 commands with a different `-Minutes` value.

## Troubleshooting

| Problem | Fix |
|---|---|
| Wallpaper never changes | Check the task exists and is enabled: `Get-ScheduledTask WallpaperRotator`. Make sure the path in `RunHidden.vbs` is correct. |
| A source never shows up | Look in `cache\log.txt` for its error. |
| Want to see errors live | Run the script directly: `powershell -NoProfile -ExecutionPolicy Bypass -File .\Change-Wallpaper.ps1` |
| No caption / plain photo | Every source failed (e.g. no internet) and it fell back to Lorem Picsum. It recovers on the next run. |
| Stops while offline | Expected. It needs internet to download a photo, and resumes on the next run once you're back online. |

## Bonus: update everything for security

`Update-Security.ps1` is a separate tool, unrelated to the wallpaper. It installs every security-relevant update on the PC in one run:

| What | Included | Left alone |
|---|---|---|
| **Microsoft Defender** | Latest virus definitions | Skipped if another antivirus is in charge |
| **Windows Update** | Security, critical and rollup updates, most severe first, plus the Defender platform update | Drivers, feature upgrades, previews, optional updates |
| **Apps** (via winget) | Every app with an update. Browsers, PDF readers, runtimes and chat apps go first | Anything you list in `-ExcludeApps` |
| **Microsoft Office** | Starts the Click-to-Run update, if Office is installed | |

App updates are included in full because that's how most app security fixes arrive, and winget can't tell a security fix from a cosmetic one.

While it runs, the screen shows a progress bar, the elapsed time, what's done (with result), what's running now (with a live timer) and what's up next. When it's done you get a summary, the log file path, and an offer to restart if one is needed. It keeps the PC awake while it works.

Run it from PowerShell in the folder (it asks for administrator rights itself):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Update-Security.ps1
```

| Option | What it does |
|---|---|
| `-ListOnly` | Show the plan without installing anything |
| `-SkipWindowsUpdate` | Leave Windows Update out |
| `-SkipApps` | Leave apps out |
| `-ExcludeApps Spotify.Spotify,Valve.Steam` | Never touch these apps (winget IDs, as shown by `winget upgrade`) |

If an app fails, it's usually because it was open. Close it and run the script again; anything already updated gets skipped.
