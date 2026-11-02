param(
    [string]$OutputIco = (Join-Path $PSScriptRoot 'AudioModeTray.ico'),
    [string]$OutputPreview = (Join-Path $PSScriptRoot 'AudioModeTray-icon-preview.png')
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Drawing

$Sizes = @(16, 20, 24, 32, 40, 48, 64, 128, 256)

function New-IconPng {
    param([int]$Size)

    $bitmap = New-Object System.Drawing.Bitmap $Size, $Size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $graphics.Clear([System.Drawing.Color]::Transparent)

    $white = [System.Drawing.Color]::White
    $speakerBrush = New-Object System.Drawing.SolidBrush $white
    $wavePen = New-Object System.Drawing.Pen $white, ([math]::Max(1.25, $Size * 0.065))
    $wavePen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $wavePen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round

    $body = New-Object System.Drawing.RectangleF ($Size * 0.16), ($Size * 0.37), ($Size * 0.18), ($Size * 0.26)
    $graphics.FillRectangle($speakerBrush, $body)

    $points = [System.Drawing.PointF[]]@(
        (New-Object System.Drawing.PointF ($Size * 0.34), ($Size * 0.37)),
        (New-Object System.Drawing.PointF ($Size * 0.56), ($Size * 0.20)),
        (New-Object System.Drawing.PointF ($Size * 0.56), ($Size * 0.80)),
        (New-Object System.Drawing.PointF ($Size * 0.34), ($Size * 0.63))
    )
    $graphics.FillPolygon($speakerBrush, $points)

    $graphics.DrawArc($wavePen, $Size * 0.54, $Size * 0.34, $Size * 0.20, $Size * 0.32, -58, 116)
    $graphics.DrawArc($wavePen, $Size * 0.57, $Size * 0.24, $Size * 0.34, $Size * 0.52, -55, 110)

    $stream = New-Object System.IO.MemoryStream
    $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
    $bytes = $stream.ToArray()

    if ($Size -eq 256) {
        $bitmap.Save($OutputPreview, [System.Drawing.Imaging.ImageFormat]::Png)
    }

    $stream.Dispose()
    $wavePen.Dispose()
    $speakerBrush.Dispose()
    $graphics.Dispose()
    $bitmap.Dispose()
    return ,$bytes
}

$images = @()
foreach ($size in $Sizes) {
    $images += [pscustomobject]@{
        Size = $size
        Data = New-IconPng $size
    }
}

$file = [System.IO.File]::Create($OutputIco)
$writer = New-Object System.IO.BinaryWriter $file
$writer.Write([uint16]0)
$writer.Write([uint16]1)
$writer.Write([uint16]$images.Count)

$offset = 6 + (16 * $images.Count)
foreach ($image in $images) {
    $dimension = if ($image.Size -ge 256) { 0 } else { $image.Size }
    $writer.Write([byte]$dimension)
    $writer.Write([byte]$dimension)
    $writer.Write([byte]0)
    $writer.Write([byte]0)
    $writer.Write([uint16]1)
    $writer.Write([uint16]32)
    $writer.Write([uint32]$image.Data.Length)
    $writer.Write([uint32]$offset)
    $offset += $image.Data.Length
}

foreach ($image in $images) {
    $writer.Write($image.Data)
}

$writer.Flush()
$writer.Dispose()
$file.Dispose()

Get-Item -LiteralPath $OutputIco,$OutputPreview |
    Select-Object FullName,Length,LastWriteTime
