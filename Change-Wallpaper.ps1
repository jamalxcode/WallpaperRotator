$ErrorActionPreference = 'Stop'

$cacheDir = Join-Path $PSScriptRoot 'cache'
if (-not (Test-Path $cacheDir)) {
    New-Item -ItemType Directory -Path $cacheDir | Out-Null
}

Add-Type -AssemblyName System.Windows.Forms
$bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$width = $bounds.Width
$height = $bounds.Height

$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$imagePath = Join-Path $cacheDir "wallpaper_$timestamp.jpg"

# Picsum returns a random stock photo at the requested resolution, no API key needed.
$url = "https://picsum.photos/$width/$height"
Invoke-WebRequest -Uri $url -OutFile $imagePath -UserAgent 'Mozilla/5.0'

# keep only the 5 most recent cached images so this folder doesn't grow forever
Get-ChildItem $cacheDir -Filter 'wallpaper_*.jpg' |
    Sort-Object LastWriteTime -Descending |
    Select-Object -Skip 5 |
    Remove-Item -Force

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

[ComImport, Guid("C2CF3110-460E-4FC1-B9D0-8A1C0C9CC4BD")]
internal class DesktopWallpaperClass { }

public enum DesktopWallpaperPosition
{
    Center = 0,
    Tile = 1,
    Stretch = 2,
    Fit = 3,
    Fill = 4,
    Span = 5
}

[StructLayout(LayoutKind.Sequential)]
public struct WallpaperRect
{
    public int Left, Top, Right, Bottom;
}

[ComImport, Guid("B92B56A9-8B55-4E14-9A89-0199BBB6F93B"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IDesktopWallpaper
{
    void SetWallpaper([MarshalAs(UnmanagedType.LPWStr)] string monitorId, [MarshalAs(UnmanagedType.LPWStr)] string wallpaper);
    [return: MarshalAs(UnmanagedType.LPWStr)]
    string GetWallpaper([MarshalAs(UnmanagedType.LPWStr)] string monitorId);
    [return: MarshalAs(UnmanagedType.LPWStr)]
    string GetMonitorDevicePathAt(uint monitorIndex);
    uint GetMonitorDevicePathCount();
    WallpaperRect GetMonitorRECT([MarshalAs(UnmanagedType.LPWStr)] string monitorId);
    void SetBackgroundColor(uint color);
    uint GetBackgroundColor();
    void SetPosition(DesktopWallpaperPosition position);
    DesktopWallpaperPosition GetPosition();
    void SetSlideshow(IntPtr items);
    IntPtr GetSlideshow();
    void SetSlideshowOptions(int options, uint slideshowTick);
    void GetSlideshowOptions(out int options, out uint slideshowTick);
    void AdvanceSlideshow([MarshalAs(UnmanagedType.LPWStr)] string monitorId, int direction);
    int GetStatus();
    bool Enable();
}

public static class WallpaperSetter
{
    public static void SetOnAllMonitors(string imagePath)
    {
        var wallpaper = (IDesktopWallpaper)new DesktopWallpaperClass();
        uint count = wallpaper.GetMonitorDevicePathCount();
        if (count == 0)
        {
            // Fallback: null monitor id sets it for all monitors as a single call
            wallpaper.SetWallpaper(null, imagePath);
        }
        else
        {
            for (uint i = 0; i < count; i++)
            {
                string monitorId = wallpaper.GetMonitorDevicePathAt(i);
                wallpaper.SetWallpaper(monitorId, imagePath);
            }
        }
        wallpaper.SetPosition(DesktopWallpaperPosition.Fill);
    }
}
"@

[WallpaperSetter]::SetOnAllMonitors($imagePath)
