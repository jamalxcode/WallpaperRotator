$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------

# Each run picks one of these at random. Remove any you don't want.
$Sources = @(
    'Bing'           # Bing photo of the day (last 8 days)
    'WikimediaPotd'  # Wikimedia Commons picture of the day (last 60 days)
    'NasaApod'       # NASA Astronomy Picture of the Day (random from the archive)
    'LiveEarth'      # Live satellite view: your region, the Americas, or the whole Earth
    'WikipediaNews'  # Photos from Wikipedia's "In the news" (today's world events)
    'MetMuseum'      # Public-domain masterpieces from The Met
    'ArtInstitute'   # Public-domain paintings from the Art Institute of Chicago
    'CommonsFeatured' # Wikimedia Commons featured photos: animals, landscapes, night skies, cities...
    'Openverse'      # Openly licensed photos of fun subjects (see $FunTopics), mature content filtered out
    'EarthView'      # Google Earth View: striking satellite shots of the planet
    'NasaImages'     # NASA image library: nebulae, galaxies, planets, rocket launches
    'Pixabay'        # Pixabay editors' choice photos (needs a free key in pixabay-key.txt)
)

# Search words for Openverse and Pixabay. Add or remove whatever you like.
$FunTopics = @(
    'hot air balloons', 'northern lights', 'red panda', 'fox', 'owl', 'hummingbird', 'puffin', 'penguins',
    'sea turtle', 'jellyfish', 'coral reef', 'dolphins', 'elephant', 'giraffe', 'tiger', 'snow leopard',
    'waterfall', 'tropical beach', 'lavender field', 'cherry blossom', 'autumn forest', 'ice cave',
    'volcano', 'canyon', 'rainbow', 'milky way', 'fireworks', 'lantern festival', 'lighthouse', 'castle',
    'colorful houses', 'street art', 'steam train', 'lego', 'chameleon', 'macro dewdrops', 'tulip field'
)

# Pixabay key: sign up free at https://pixabay.com, then copy the key from https://pixabay.com/api/docs/
# into a file named pixabay-key.txt next to this script (it's git-ignored, so it never gets committed).
$PixabayKeyFile = Join-Path $PSScriptRoot 'pixabay-key.txt'

# Draw the title / description / credit in the bottom-right corner.
$ShowCaption = $true

# NASA's shared DEMO_KEY allows ~50 requests a day. For more, get a free key at https://api.nasa.gov
$NasaApiKey = 'DEMO_KEY'

# Area shown by the regional live satellite view (Meteosat): south, west, north, east in degrees.
# Keep a 16:9 shape (east-west span = 1.78 x north-south span). Default: Arabian Peninsula & Gulf.
$RegionBox  = '11,33,35.75,77'
$RegionName = 'Arabian Peninsula & the Gulf'

# How many finished wallpapers to keep in the cache folder.
$KeepImages = 5

# ---------------------------------------------------------------------------

$UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0 Safari/537.36 WallpaperRotator/2.0 (+https://github.com/jamalxcode/WallpaperRotator)'
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

$cacheDir = Join-Path $PSScriptRoot 'cache'
if (-not (Test-Path $cacheDir)) {
    New-Item -ItemType Directory -Path $cacheDir | Out-Null
}

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
# Without this, Windows display scaling makes the screen look smaller than it is (e.g. 1152x720) and wallpapers come out blurry
Add-Type -Namespace Native -Name Dpi -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
[void][Native.Dpi]::SetProcessDPIAware()
$screen = [System.Windows.Forms.Screen]::PrimaryScreen
$width = $screen.Bounds.Width
$height = $screen.Bounds.Height
# Wikimedia serves pre-made thumbnail sizes; pick the one that covers the screen
$wikiSize = if ($width -le 1920) { 1920 } else { 3840 }

function Write-Log([string]$message) {
    $logPath = Join-Path $cacheDir 'log.txt'
    Add-Content -Path $logPath -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $message) -Encoding UTF8
    $lines = @(Get-Content $logPath -Encoding UTF8)
    if ($lines.Count -gt 200) { $lines | Select-Object -Last 200 | Set-Content $logPath -Encoding UTF8 }
}

# Always decode as UTF-8: some APIs omit the charset and PowerShell 5.1 would garble accents
function Get-Json([string]$url, [hashtable]$headers = @{}) {
    $r = Invoke-WebRequest -Uri $url -UserAgent $UserAgent -Headers $headers -TimeoutSec 20 -UseBasicParsing
    $bytes = New-Object byte[] $r.RawContentStream.Length
    [void]$r.RawContentStream.Read($bytes, 0, $bytes.Length)
    [System.Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
}

function Get-PlainText([string]$html) {
    [System.Net.WebUtility]::HtmlDecode(($html -replace '<[^>]+>', '')).Trim() -replace '\s+', ' '
}

function Limit-Text([string]$text, [int]$max) {
    if (-not $text -or $text.Length -le $max) { return $text }
    $cut = $text.Substring(0, $max)
    $space = $cut.LastIndexOf(' ')
    if ($space -gt $max * 0.6) { $cut = $cut.Substring(0, $space) }
    return $cut.TrimEnd(',', '.', ';', ':', ' ') + [char]0x2026
}

# Returns a Wikimedia URL no wider than the screen needs (originals can be 50+ MB)
function Get-WikiImageUrl([string]$url, [int]$imageWidth) {
    $url = ($url -split '\?')[0]
    if ($imageWidth -le $wikiSize) { return $url }
    if ($url -match '/thumb/') { return $url -replace '/\d+px-', "/${wikiSize}px-" }
    if ($url -match '^(https://upload\.wikimedia\.org/wikipedia/[^/]+/)(.+/)([^/]+)$') {
        return "$($Matches[1])thumb/$($Matches[2])$($Matches[3])/${wikiSize}px-$($Matches[3])"
    }
    return $url
}

# ---------------------------------------------------------------------------
# Sources. Each returns: Url, Title, Text, Credit, Link, and optionally Fit and Headers
#   Fit: 'Fill' (crop to screen), 'Blur' (whole image on a blurred backdrop),
#        'Black' (whole image on black). Left empty, it's chosen by the image's shape.
# ---------------------------------------------------------------------------

function Get-Bing {
    $r = Get-Json 'https://www.bing.com/HPImageArchive.aspx?format=js&idx=0&n=8&mkt=en-US'
    $img = $r.images | Get-Random
    # copyright looks like: "Place, Country (<copyright sign> Photographer/Agency)"
    # (built from its code: PowerShell 5.1 misreads non-ASCII characters typed into this file)
    $c = [char]0x00A9
    $place = ($img.copyright -replace "\s*\($c.*$", '')
    $credit = if ($img.copyright -match "\(($c[^)]*)\)") { $Matches[1] } else { '' }
    [pscustomobject]@{
        Url    = "https://www.bing.com$($img.urlbase)_UHD.jpg"
        Title  = $img.title
        Text   = $place
        Credit = "Bing  $([char]0x00B7)  $credit"
        Link   = $img.copyrightlink
    }
}

function Get-WikimediaPotd {
    $day = (Get-Date).ToUniversalTime().AddDays(-(Get-Random -Minimum 0 -Maximum 60)).ToString('yyyy/MM/dd')
    $f = Get-Json "https://api.wikimedia.org/feed/v1/wikipedia/en/featured/$day"
    $img = $f.image
    if (-not $img) { throw "No picture of the day for $day" }
    $artist = Limit-Text (Get-PlainText $img.artist.text) 60
    [pscustomobject]@{
        Url    = Get-WikiImageUrl $img.image.source $img.image.width
        Title  = 'Picture of the Day'
        Text   = Limit-Text (Get-PlainText $img.description.text) 220
        Credit = "Wikimedia Commons  $([char]0x00B7)  $artist"
        Link   = $img.file_page
    }
}

function Get-NasaApod {
    $items = Get-Json "https://api.nasa.gov/planetary/apod?api_key=$NasaApiKey&count=5"
    $img = $items | Where-Object { $_.media_type -eq 'image' } | Select-Object -First 1
    if (-not $img) { throw 'APOD returned no images' }
    $url = if ($img.hdurl) { $img.hdurl } else { $img.url }
    # first two sentences of the explanation
    $text = (($img.explanation -split '(?<=\.)\s+') | Select-Object -First 2) -join ' '
    $credit = if ($img.copyright) { "$([char]0x00A9) $(($img.copyright -replace '\s+', ' ').Trim())" } else { 'NASA' }
    [pscustomobject]@{
        Url    = $url
        Title  = $img.title
        Text   = Limit-Text $text 220
        Credit = "NASA Astronomy Picture of the Day  $([char]0x00B7)  $($img.date)  $([char]0x00B7)  $credit"
        Link   = 'https://apod.nasa.gov/apod/ap{0}.html' -f ([datetime]$img.date).ToString('yyMMdd')
    }
}

function Get-LiveEarth {
    $views = @('Americas', 'WholeEarth')
    # The regional view is true-colour, so it's black at night
    $hour = (Get-Date).Hour
    if ($hour -ge 7 -and $hour -lt 17) { $views += 'Region', 'Region' }
    switch ($views | Get-Random) {
        'Region' {
            $b = $RegionBox -split ','
            $boxH = [math]::Round($width * ([double]$b[2] - [double]$b[0]) / ([double]$b[3] - [double]$b[1]))
            [pscustomobject]@{
                Url    = "https://view.eumetsat.int/geoserver/ows?service=WMS&request=GetMap&version=1.3.0&layers=msg_iodc:rgb_naturalenhncd,backgrounds:ne_boundary_lines_land,backgrounds:ne_10m_coastline&styles=&format=image/jpeg&crs=EPSG:4326&bbox=$RegionBox&width=$width&height=$boxH&bgcolor=0x000000"
                Title  = "Live: $RegionName"
                Text   = 'Satellite view from the last 15 minutes'
                Credit = "EUMETSAT Meteosat  $([char]0x00B7)  $(Get-Date -Format 'HH:mm')"
                Link   = 'https://view.eumetsat.int/'
                Fit    = 'Fill'
            }
        }
        'Americas' {
            [pscustomobject]@{
                Url    = 'https://cdn.star.nesdis.noaa.gov/GOES19/ABI/FD/GEOCOLOR/1808x1808.jpg'
                Title  = 'Live: the Americas from orbit'
                Text   = 'Updated every 10 minutes. City lights show where it is night.'
                Credit = "NOAA GOES-19  $([char]0x00B7)  $(Get-Date -Format 'HH:mm')"
                Link   = 'https://www.star.nesdis.noaa.gov/GOES/fulldisk.php?sat=G19'
                Fit    = 'Black'
            }
        }
        'WholeEarth' {
            $img = Get-Json 'https://epic.gsfc.nasa.gov/api/natural' | Get-Random
            $date = [datetime]$img.date
            [pscustomobject]@{
                Url    = 'https://epic.gsfc.nasa.gov/archive/natural/{0}/jpg/{1}.jpg' -f $date.ToString('yyyy/MM/dd'), $img.image
                Title  = 'Earth from 1.5 million km'
                Text   = "The whole sunlit side of Earth, photographed $($date.ToString('d MMMM yyyy, HH:mm')) UTC"
                Credit = 'NASA EPIC camera on NOAA DSCOVR'
                Link   = 'https://epic.gsfc.nasa.gov/'
                Fit    = 'Black'
            }
        }
    }
}

function Get-WikipediaNews {
    $today = (Get-Date).ToUniversalTime()
    $candidates = @()
    foreach ($day in $today, $today.AddDays(-1)) {
        $f = Get-Json "https://api.wikimedia.org/feed/v1/wikipedia/en/featured/$($day.ToString('yyyy/MM/dd'))"
        foreach ($story in $f.news) {
            foreach ($link in $story.links) {
                $img = $link.originalimage
                # skip logos/diagrams and tiny pictures
                if ($img -and $img.source -notmatch '\.svg' -and [math]::Max($img.width, $img.height) -ge 900) {
                    $candidates += [pscustomobject]@{ Story = $story.story; Link = $link; Image = $img }
                }
            }
        }
        if ($candidates) { break }
    }
    if (-not $candidates) { throw 'No usable news photos today' }
    $c = $candidates | Get-Random
    [pscustomobject]@{
        Url    = Get-WikiImageUrl $c.Image.source $c.Image.width
        Title  = 'In the news'
        Text   = Limit-Text (Get-PlainText $c.Story) 220
        Credit = "Wikipedia  $([char]0x00B7)  $($c.Link.normalizedtitle)"
        Link   = $c.Link.content_urls.desktop.page
    }
}

function Get-MetMuseum {
    # The list of highlighted paintings rarely changes, so only fetch it once a week
    $idsPath = Join-Path $cacheDir 'met-ids.json'
    if (-not (Test-Path $idsPath) -or (Get-Item $idsPath).LastWriteTime -lt (Get-Date).AddDays(-7)) {
        $s = Get-Json 'https://collectionapi.metmuseum.org/public/collection/v1/search?isHighlight=true&hasImages=true&medium=Paintings&q=*'
        $s.objectIDs | ConvertTo-Json -Compress | Set-Content $idsPath -Encoding UTF8
    }
    $ids = Get-Content $idsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    for ($try = 0; $try -lt 5; $try++) {
        $o = Get-Json "https://collectionapi.metmuseum.org/public/collection/v1/objects/$($ids | Get-Random)"
        if ($o.isPublicDomain -and $o.primaryImage) {
            $who = @($o.artistDisplayName, $o.objectDate) | Where-Object { $_ }
            return [pscustomobject]@{
                Url    = $o.primaryImage
                Title  = Limit-Text $o.title 90
                Text   = $who -join ', '
                Credit = 'The Metropolitan Museum of Art, New York'
                Link   = $o.objectURL
            }
        }
    }
    throw 'No public-domain Met painting found'
}

function Get-ArtInstitute {
    # AIC asks for this header, and its image server refuses requests without it
    $aicHeaders = @{ 'AIC-User-Agent' = 'WallpaperRotator (https://github.com/jamalxcode/WallpaperRotator)' }
    # Public-domain paintings (artwork type 1), random page of 100
    $page = Get-Random -Minimum 1 -Maximum 11
    $r = Get-Json "https://api.artic.edu/api/v1/artworks/search?query[bool][must][0][term][is_public_domain]=true&query[bool][must][1][term][artwork_type_id]=1&fields=id,title,image_id,artist_title,date_display&limit=100&page=$page" $aicHeaders
    $a = $r.data | Where-Object { $_.image_id } | Get-Random
    $who = @($a.artist_title, $a.date_display) | Where-Object { $_ }
    [pscustomobject]@{
        Url    = "https://www.artic.edu/iiif/2/$($a.image_id)/full/1686,/0/default.jpg"
        Title  = Limit-Text $a.title 90
        Text   = $who -join ', '
        Credit  = 'Art Institute of Chicago'
        Link    = "https://www.artic.edu/artworks/$($a.id)"
        Headers = $aicHeaders
    }
}

function Get-CommonsFeatured {
    $topics = @(
        'Featured pictures of landscapes', 'Featured pictures of cityscapes', 'Featured night photography',
        'Featured pictures of mountains', 'Featured pictures of waterfalls', 'Featured pictures of beaches',
        'Featured pictures of astronomy', 'Featured pictures taken from satellites', 'Featured pictures of nature',
        'Featured pictures of animals', 'Featured pictures of birds', 'Featured pictures of mammals',
        'Featured pictures of architecture', 'Featured pictures of transport'
    )
    # Subcategories to stay out of: people, bones, creepy-crawlies, maps and diagrams
    $skip = 'by country|by user|by subject|Primates|people|human|bones|fossil|Arthropoda|Annelida|Platyhelminthes|diagrams|maps|posters'
    $api = 'https://commons.wikimedia.org/w/api.php?format=json&action=query'

    # Random walk down the category tree until we land on a landscape-shaped photo
    for ($try = 0; $try -lt 3; $try++) {
        $cat = "Category:$($topics | Get-Random)"
        $file = $null
        for ($depth = 0; $depth -lt 5 -and -not $file; $depth++) {
            $r = Get-Json "$api&list=categorymembers&cmtitle=$([uri]::EscapeDataString($cat))&cmtype=file%7Csubcat&cmlimit=500"
            $files = @($r.query.categorymembers | Where-Object { $_.ns -eq 6 -and $_.title -match '\.(jpe?g|png)$' })
            $subs = @($r.query.categorymembers | Where-Object { $_.ns -eq 14 -and $_.title -notmatch $skip })
            # Sometimes go deeper even when this level has photos, so small subcategories get a turn
            if ($files.Count -and (-not $subs.Count -or (Get-Random -Maximum 3))) { $file = ($files | Get-Random).title }
            elseif ($subs.Count) { $cat = ($subs | Get-Random).title }
            else { break }
        }
        if (-not $file) { continue }

        $q = Get-Json "$api&prop=imageinfo&titles=$([uri]::EscapeDataString($file))&iiprop=url%7Csize%7Cextmetadata&iiurlwidth=$wikiSize&iiextmetadatafilter=ImageDescription%7CArtist%7CObjectName"
        $ii = ($q.query.pages.PSObject.Properties.Value | Select-Object -First 1).imageinfo[0]
        if ($ii.width -lt $ii.height -and $try -lt 2) { continue }   # portrait: try for a wider one

        $meta = $ii.extmetadata
        $title = if ($meta.ObjectName.value) { Get-PlainText $meta.ObjectName.value } else { $file -replace '^File:', '' -replace '\.\w+$', '' }
        $artist = Limit-Text (Get-PlainText $meta.Artist.value) 60
        return [pscustomobject]@{
            Url    = if ($ii.width -gt $wikiSize -and $ii.thumburl) { $ii.thumburl } else { $ii.url }
            Title  = Limit-Text $title 90
            Text   = Limit-Text (Get-PlainText $meta.ImageDescription.value) 220
            Credit = "Wikimedia Commons featured picture  $([char]0x00B7)  $artist"
            Link   = $ii.descriptionurl
        }
    }
    throw 'No featured picture found'
}

function Get-Openverse {
    $topic = $FunTopics | Get-Random
    $r = Get-Json "https://api.openverse.org/v1/images/?q=$([uri]::EscapeDataString($topic))&mature=false&size=large&aspect_ratio=wide&page_size=20"
    $img = $r.results | Where-Object { $_.width -ge 1600 } | Get-Random
    if (-not $img) { throw "No large Openverse photos for '$topic'" }
    $title = $img.title -replace '^File:', '' -replace '\.(jpe?g|png|tiff?)$', ''
    $by = if ($img.creator) { "$(Limit-Text $img.creator 40)  $([char]0x00B7)  " } else { '' }
    [pscustomobject]@{
        Url    = $img.url
        Title  = Limit-Text $title 90
        Text   = (Get-Culture).TextInfo.ToTitleCase($topic)
        Credit = "Openverse  $([char]0x00B7)  $by" + "CC $($img.license.ToUpper()) $($img.license_version)"
        Link   = $img.foreign_landing_url
    }
}

function Get-EarthView {
    # Earth View has no list of its ~2,600 images, so probe random ids (about 1 in 7 exists)
    for ($try = 0; $try -lt 40; $try++) {
        $id = Get-Random -Minimum 1003 -Maximum 14800
        try { $e = Get-Json "https://www.gstatic.com/prettyearth/assets/data/v3/$id.json" } catch { continue }
        $g = $e.geocode
        $place = @($g.locality, $g.administrative_area_level_1, $g.country) | Where-Object { $_ } | Select-Object -Unique
        return [pscustomobject]@{
            # The image comes inside the JSON, so there's nothing more to download
            Bytes  = [Convert]::FromBase64String(($e.dataUri -replace '^data:[^,]+,', ''))
            Title  = if ($place) { $place -join ', ' } else { 'Earth View' }
            Text   = 'Seen from above, {0:N2}, {1:N2}' -f $e.lat, $e.lng
            Credit = "Google Earth View  $([char]0x00B7)  $($e.attribution)"
            Link   = 'https://www.google.com/maps/@{0},{1},{2}z/data=!3m1!1e3' -f $e.lat, $e.lng, $e.zoom
            Fit    = 'Fill'
        }
    }
    throw 'No Earth View image found'
}

function Get-NasaImages {
    $topic = @('nebula', 'galaxy', 'star cluster', 'supernova', 'aurora', 'Jupiter', 'Saturn', 'Hubble',
               'Webb telescope', 'rocket launch', 'Earth from space', 'Mars surface') | Get-Random
    $r = Get-Json "https://images-api.nasa.gov/search?q=$([uri]::EscapeDataString($topic))&media_type=image&page_size=100"
    # Leave out photos of meetings and press events
    $items = @($r.collection.items | Where-Object { "$($_.data[0].title) $($_.data[0].description)" -notmatch 'press conference|briefing|ceremony|meeting|portrait|award|visits?\b' })
    for ($try = 0; $try -lt 5 -and $items.Count; $try++) {
        $item = $items | Get-Random
        # PowerShell 5.1 hands back a JSON array as one object; ForEach-Object unrolls it
        $assets = @(Get-Json $item.href | ForEach-Object { $_ })
        $url = foreach ($size in '~large.jpg', '~orig.jpg', '~medium.jpg') {
            $assets | Where-Object { $_ -like "*$size" } | Select-Object -First 1
        }
        $url = @($url)[0]
        if (-not $url) { continue }
        $d = $item.data[0]
        $who = @($d.center, $(if ($d.date_created) { ([datetime]$d.date_created).Year })) | Where-Object { $_ }
        return [pscustomobject]@{
            Url    = $url -replace '^http:', 'https:'
            Title  = Limit-Text $d.title 90
            Text   = Limit-Text ((((Get-PlainText $d.description) -split '(?<=\.)\s+') | Select-Object -First 2) -join ' ') 220
            Credit = "NASA Image Library  $([char]0x00B7)  $($who -join ', ')"
            Link   = "https://images.nasa.gov/details/$($d.nasa_id)"
        }
    }
    throw "No NASA image found for '$topic'"
}

function Get-Pixabay {
    if (-not (Test-Path $PixabayKeyFile)) { throw 'No pixabay-key.txt' }
    $key = (Get-Content $PixabayKeyFile -Raw).Trim()
    $topic = $FunTopics | Get-Random
    # Pixabay asks apps to cache search results for 24 hours
    $cachePath = Join-Path $cacheDir ("pixabay-{0}.json" -f ($topic -replace '\W', '_'))
    if ((Test-Path $cachePath) -and (Get-Item $cachePath).LastWriteTime -gt (Get-Date).AddHours(-23)) {
        $hits = Get-Content $cachePath -Raw -Encoding UTF8 | ConvertFrom-Json
    } else {
        $base = "https://pixabay.com/api/?key=$key&q=$([uri]::EscapeDataString($topic))&image_type=photo&orientation=horizontal&safesearch=true&min_width=1920&per_page=50"
        $hits = (Get-Json "$base&editors_choice=true").hits
        if (-not $hits) { $hits = (Get-Json $base).hits }
        ConvertTo-Json @($hits) -Depth 4 -Compress | Set-Content $cachePath -Encoding UTF8
    }
    $img = $hits | Get-Random
    if (-not $img) { throw "No Pixabay photos for '$topic'" }
    [pscustomobject]@{
        # fullHDURL only comes with Pixabay's approved full API access; normal keys get 1280px
        Url    = if ($img.fullHDURL) { $img.fullHDURL } else { $img.largeImageURL }
        Title  = (Get-Culture).TextInfo.ToTitleCase($topic)
        Text   = $img.tags
        Credit = "Pixabay  $([char]0x00B7)  $($img.user)"
        Link   = $img.pageURL
    }
}

function Get-Picsum {
    [pscustomobject]@{
        Url = "https://picsum.photos/$width/$height"; Title = ''; Text = ''; Credit = 'Lorem Picsum'; Link = 'https://picsum.photos/'; Fit = 'Fill'
    }
}

# ---------------------------------------------------------------------------
# Drawing
# ---------------------------------------------------------------------------

function New-RoundedRect([float]$x, [float]$y, [float]$w, [float]$h, [float]$r) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $p.AddArc($x, $y, 2 * $r, 2 * $r, 180, 90)
    $p.AddArc($x + $w - 2 * $r, $y, 2 * $r, 2 * $r, 270, 90)
    $p.AddArc($x + $w - 2 * $r, $y + $h - 2 * $r, 2 * $r, 2 * $r, 0, 90)
    $p.AddArc($x, $y + $h - 2 * $r, 2 * $r, 2 * $r, 90, 90)
    $p.CloseFigure()
    return $p
}

# Draws $img so it covers ($cover) or fits inside the screen, centred
function Draw-Scaled($g, $img, [bool]$cover, [double]$shrink = 1.0, $attributes = $null) {
    # [double]: 2880/2880 is an Int32 in PowerShell, and [math]::Max(Int32, Double) would then round to Int32
    $scaleW = [double]$width / $img.Width
    $scaleH = [double]$height / $img.Height
    $scale = if ($cover) { [math]::Max($scaleW, $scaleH) } else { [math]::Min($scaleW, $scaleH) * $shrink }
    $w = [int][math]::Ceiling($img.Width * $scale)
    $h = [int][math]::Ceiling($img.Height * $scale)
    $rect = New-Object System.Drawing.Rectangle ([int](($width - $w) / 2)), ([int](($height - $h) / 2)), $w, $h
    if ($attributes) {
        $g.DrawImage($img, $rect, 0, 0, $img.Width, $img.Height, [System.Drawing.GraphicsUnit]::Pixel, $attributes)
    } else {
        $g.DrawImage($img, $rect)
    }
}

function New-Wallpaper([string]$sourcePath, [string]$outPath, $info) {
    $img = [System.Drawing.Image]::FromFile($sourcePath)
    $canvas = New-Object System.Drawing.Bitmap $width, $height
    $g = [System.Drawing.Graphics]::FromImage($canvas)
    $g.InterpolationMode = 'HighQualityBicubic'
    $g.SmoothingMode = 'AntiAlias'
    $g.PixelOffsetMode = 'HighQuality'
    $g.TextRenderingHint = 'AntiAliasGridFit'

    $fit = $info.Fit
    if (-not $fit) {
        # Close to the screen's shape: crop to fill. Otherwise show it whole.
        $ratio = ($img.Width / $img.Height) / ($width / $height)
        $fit = if ($ratio -gt 0.8 -and $ratio -lt 1.25) { 'Fill' } else { 'Blur' }
    }

    switch ($fit) {
        'Fill' { Draw-Scaled $g $img $true }
        'Black' {
            $g.Clear([System.Drawing.Color]::Black)
            Draw-Scaled $g $img $false 0.94
        }
        'Blur' {
            # Cheap blur: shrink to a tiny image, then stretch it back over the whole screen
            $tinyW = 32
            $tinyH = [math]::Max(1, [int]($tinyW * $img.Height / $img.Width))
            $tiny = New-Object System.Drawing.Bitmap $tinyW, $tinyH
            $tg = [System.Drawing.Graphics]::FromImage($tiny)
            $tg.InterpolationMode = 'HighQualityBicubic'
            $tg.DrawImage($img, 0, 0, $tinyW, $tinyH)
            $tg.Dispose()
            $attr = New-Object System.Drawing.Imaging.ImageAttributes
            $attr.SetWrapMode([System.Drawing.Drawing2D.WrapMode]::TileFlipXY)   # no dark edges
            Draw-Scaled $g $tiny $true 1.0 $attr
            $shade = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(120, 0, 0, 0))
            $g.FillRectangle($shade, 0, 0, $width, $height)
            Draw-Scaled $g $img $false
            $shade.Dispose(); $attr.Dispose(); $tiny.Dispose()
        }
    }
    $img.Dispose()

    if ($ShowCaption -and ($info.Title -or $info.Text)) {
        $k = $height / 1080
        $titleFont = New-Object System.Drawing.Font('Segoe UI Semibold', [float](22 * $k), [System.Drawing.GraphicsUnit]::Pixel)
        $textFont = New-Object System.Drawing.Font('Segoe UI', [float](16 * $k), [System.Drawing.GraphicsUnit]::Pixel)
        $creditFont = New-Object System.Drawing.Font('Segoe UI', [float](12.5 * $k), [System.Drawing.GraphicsUnit]::Pixel)
        $pad = 16 * $k
        $gap = 6 * $k
        $maxW = [float]($width * 0.32)

        $parts = @()
        if ($info.Title) { $parts += , @($info.Title, $titleFont, [System.Drawing.Color]::White) }
        if ($info.Text) { $parts += , @($info.Text, $textFont, [System.Drawing.Color]::FromArgb(235, 255, 255, 255)) }
        if ($info.Credit) { $parts += , @($info.Credit, $creditFont, [System.Drawing.Color]::FromArgb(170, 255, 255, 255)) }

        $sizes = foreach ($p in $parts) { $g.MeasureString($p[0], $p[1], [int]$maxW) }
        $boxW = ($sizes | ForEach-Object { $_.Width } | Measure-Object -Maximum).Maximum + 2 * $pad
        $boxH = ($sizes | ForEach-Object { $_.Height } | Measure-Object -Sum).Sum + 2 * $pad + $gap * ($parts.Count - 1)

        # Bottom-right corner, above the taskbar
        $area = $screen.WorkingArea
        $margin = 28 * $k
        $x = $area.Right - $screen.Bounds.X - $margin - $boxW
        $y = $area.Bottom - $screen.Bounds.Y - $margin - $boxH

        $path = New-RoundedRect $x $y $boxW $boxH (10 * $k)
        $bg = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(150, 0, 0, 0))
        $g.FillPath($bg, $path)

        $ty = $y + $pad
        for ($i = 0; $i -lt $parts.Count; $i++) {
            $brush = New-Object System.Drawing.SolidBrush $parts[$i][2]
            $rect = New-Object System.Drawing.RectangleF ([float]($x + $pad)), ([float]$ty), ([float]($maxW + 1)), ([float]($sizes[$i].Height + 1))
            $g.DrawString($parts[$i][0], $parts[$i][1], $brush, $rect)
            $brush.Dispose()
            $ty += $sizes[$i].Height + $gap
        }
        $bg.Dispose(); $path.Dispose(); $titleFont.Dispose(); $textFont.Dispose(); $creditFont.Dispose()
    }
    $g.Dispose()

    $jpeg = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' }
    $params = New-Object System.Drawing.Imaging.EncoderParameters 1
    $params.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter ([System.Drawing.Imaging.Encoder]::Quality), ([long]92)
    $canvas.Save($outPath, $jpeg, $params)
    $canvas.Dispose()
}

# ---------------------------------------------------------------------------
# Setting the wallpaper
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# Main: try sources in random order until one works; Picsum is the last resort
# ---------------------------------------------------------------------------

# Pass a source name to test it, e.g.  .\Change-Wallpaper.ps1 NasaApod
$active = @($Sources | Where-Object { $_ -ne 'Pixabay' -or (Test-Path $PixabayKeyFile) })
$order = @(if ($args.Count -gt 0) { $args[0] } else { $active | Get-Random -Count $active.Count }) + 'Picsum'

$downloadPath = Join-Path $cacheDir 'download.tmp'
$imagePath = Join-Path $cacheDir ("wallpaper_{0}.jpg" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))

$info = $null
foreach ($name in $order) {
    try {
        $candidate = & "Get-$name"
        if ($candidate.Bytes) {
            [System.IO.File]::WriteAllBytes($downloadPath, $candidate.Bytes)
        } else {
            $headers = if ($candidate.Headers) { $candidate.Headers } else { @{} }
            Invoke-WebRequest -Uri $candidate.Url -OutFile $downloadPath -UserAgent $UserAgent -Headers $headers -TimeoutSec 60 -UseBasicParsing
        }
        New-Wallpaper $downloadPath $imagePath $candidate
        $info = $candidate
        $info | Add-Member Source $name
        break
    } catch {
        Write-Log "$name failed: $($_.Exception.Message)"
    }
}
Remove-Item $downloadPath -Force -ErrorAction SilentlyContinue
if (-not $info) { throw 'Every source failed; see cache\log.txt' }

# What's on screen right now, in case you want to know more
@(
    $info.Title, $info.Text, $info.Credit, '', "More: $($info.Link)", "Source: $($info.Source)", "Set: $(Get-Date)"
) | Set-Content (Join-Path $cacheDir 'current.txt') -Encoding UTF8

# keep only the most recent wallpapers so this folder doesn't grow forever
Get-ChildItem $cacheDir -Filter 'wallpaper_*.jpg' |
    Sort-Object LastWriteTime -Descending |
    Select-Object -Skip $KeepImages |
    Remove-Item -Force

[WallpaperSetter]::SetOnAllMonitors($imagePath)
