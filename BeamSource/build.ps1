param(
    [Parameter(Mandatory)] [string] $UnrealEngine
)
$ErrorActionPreference='Stop'
$project=Join-Path $PSScriptRoot 'Pal.uproject'
$generator=Join-Path $PSScriptRoot 'create_beam.py'
$editor=Join-Path $UnrealEngine 'Engine\Binaries\Win64\UnrealEditor-Cmd.exe'
$pakTool=Join-Path $UnrealEngine 'Engine\Binaries\Win64\UnrealPak.exe'
foreach ($tool in @($editor,$pakTool)) {
    if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) { throw "Missing Unreal Engine tool: $tool" }
}
$assetNames=@('M_ExhaustedTreeBeam','SM_ExhaustedTreeBeam')
$work=Join-Path $PSScriptRoot 'Build'
New-Item -ItemType Directory -Path $work -Force | Out-Null

& $editor $project '-run=pythonscript' "-script=$generator" '-unattended' '-nop4' '-nosplash' '-NullRHI' "-AbsLog=$work\generate.log" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Beam asset generation failed. See $work\generate.log" }
foreach ($name in $assetNames) {
    if (-not (Test-Path -LiteralPath "$PSScriptRoot\Content\ExhaustedResourceMarkers\$name.uasset")) {
        throw "Generated asset is missing: $name"
    }
}
& $editor $project '-run=cook' '-TargetPlatform=Windows' '-Map=/Game/ExhaustedResourceMarkers/L_TreeBeamCook' '-CookSinglePackage' '-unattended' '-nop4' '-nosplash' '-NullRHI' "-AbsLog=$work\cook.log" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Beam cook failed. See $work\cook.log" }

$cooked=Join-Path $PSScriptRoot 'Saved\Cooked\Windows\Pal\Content\ExhaustedResourceMarkers'
foreach ($name in $assetNames) {
    if (-not (Test-Path -LiteralPath "$cooked\$name.uasset")) { throw "Cooked asset is missing: $name" }
}
$response=Join-Path $work 'pak-files.txt'
$lines=Get-ChildItem -LiteralPath $cooked -File |
    Where-Object { $_.BaseName -in $assetNames -and $_.Extension -in @('.uasset','.uexp','.ubulk') } |
    ForEach-Object { '"{0}" "../../../Pal/Content/ExhaustedResourceMarkers/{1}"' -f $_.FullName,$_.Name }
[IO.File]::WriteAllLines($response,[string[]] $lines,[Text.Encoding]::ASCII)
$outputPak=Join-Path $work 'ExhaustedResourceMarkersTreeBeam_P.pak'
& $pakTool $outputPak "-Create=$response"
if ($LASTEXITCODE -ne 0) { throw 'UnrealPak could not create the beam archive.' }
$listing=& $pakTool $outputPak '-List'
if ($LASTEXITCODE -ne 0) { throw 'UnrealPak could not read the beam archive.' }
foreach ($name in $assetNames) {
    if (-not ($listing -match "$name\.uasset")) { throw "PAK is missing $name." }
}
Get-Item -LiteralPath $outputPak | Select-Object FullName,Length
