# -----------------------------------------------------------------
#  make-ico.ps1 - genera src\hwbro.ico desde src\ico.png
#
#  El .ico lleva varias resoluciones (16, 24, 32, 48, 64, 128 y 256) con
#  transparencia, que es lo que Windows usa en el Explorador, en la barra de
#  tareas y en la barra de titulo de la ventana. Lo embebe src\hwbro.rc al
#  compilar.
#
#  Si se cambia el dibujo: se reemplaza src\ico.png, se corre esto y se compila.
#
#  Uso: powershell -ExecutionPolicy Bypass -File src\make-ico.ps1
# -----------------------------------------------------------------
param(
    [string]$Src = "ico.png",
    [string]$Dst = "hwbro.ico"
)

Add-Type -AssemblyName System.Drawing

$srcPath = if ([System.IO.Path]::IsPathRooted($Src)) { $Src } else { Join-Path $PSScriptRoot $Src }
$dstPath = if ([System.IO.Path]::IsPathRooted($Dst)) { $Dst } else { Join-Path $PSScriptRoot $Dst }

$sizes = @(16, 24, 32, 48, 64, 128, 256)
$img = [System.Drawing.Image]::FromFile($srcPath)
$frames = @()
foreach ($s in $sizes) {
    $bmp = New-Object System.Drawing.Bitmap $s, $s
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.Clear([System.Drawing.Color]::Transparent)
    $g.DrawImage($img, 0, 0, $s, $s)
    $g.Dispose()
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    $frames += ,@($s, $ms.ToArray())
}
$img.Dispose()

$out = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter $out
$bw.Write([UInt16]0)                       # reservado
$bw.Write([UInt16]1)                       # tipo = icono
$bw.Write([UInt16]$frames.Count)
$offset = 6 + 16 * $frames.Count
foreach ($f in $frames) {
    $s = $f[0]
    $data = $f[1]
    $bw.Write([Byte]($(if ($s -ge 256) { 0 } else { $s })))
    $bw.Write([Byte]($(if ($s -ge 256) { 0 } else { $s })))
    $bw.Write([Byte]0)                     # paleta
    $bw.Write([Byte]0)                     # reservado
    $bw.Write([UInt16]1)                   # planos
    $bw.Write([UInt16]32)                  # bits por pixel
    $bw.Write([UInt32]$data.Length)
    $bw.Write([UInt32]$offset)
    $offset += $data.Length
}
foreach ($f in $frames) { $bw.Write($f[1]) }
$bw.Flush()
[System.IO.File]::WriteAllBytes($dstPath, $out.ToArray())
$bw.Dispose()
Write-Host ("ico escrito: {0} ({1} bytes, {2} tamanos)" -f $dstPath, (Get-Item $dstPath).Length, $frames.Count)
