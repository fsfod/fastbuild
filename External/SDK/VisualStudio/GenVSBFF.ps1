param (
    [int]$version = 2022,
    [bool]$nopreview = $false,
    [switch][bool]$verbose = $false,
    [switch][bool]$dumpvcvars = $false
)

if($verbose) {
  $VerbosePreference = "Continue"
}

$vswhereDir = "C:\Program Files (x86)\Microsoft Visual Studio\Installer"

$versionToYear = @{
  14 = 2015;
  15 = 2017;
  16 = 2019;
  17 = 2022
}

$yeartoVersion = @{
 2015 = 14;
 2017 = 15;
 2019 = 16;
 2022 = 17
}

$mscVersionBase = @{
 2017 = 1910;
 2019 = 1920;
 2022 = 1930
}

function Run-VSWhere {
    param ([string[]]$Arguments)

  $pinfo = New-Object System.Diagnostics.ProcessStartInfo
  $pinfo.FileName = "$vswhereDir/vswhere.exe"
  $pinfo.RedirectStandardError = $true
  $pinfo.RedirectStandardOutput = $true
  $pinfo.UseShellExecute = $false
  $pinfo.Arguments = $Arguments
  $_p = New-Object System.Diagnostics.Process
  $_p.StartInfo = $pinfo
  $_p.Start() | Out-Null
  $_p.WaitForExit()
  
  return $_p, $_p.StandardOutput.ReadToEnd(), $_p.StandardError.ReadToEnd()
}

function Get-VSDevVars {
  param([string]$installPath)

  $envVars = @{}

  if (-not $installPath) {
    Write-Error "VS install path was empty when trying to run vsdevcmd.bat"
    return $envVars
  }

  $vsdevcmd = "$installPath\Common7\Tools\vsdevcmd.bat"

  if (-not (Test-Path vsdevcmd)) {
   # Write-Error "count not find vsdevcmd.bat in $installPath\Common7\Tools\"
   # return $envVars
  }

  # Use setlocal so PATH is not appended to every time were run causing cmd to fail with line too long errors
  & "${env:COMSPEC}" /s /c "setlocal & `"$vsdevcmd`" -no_logo && set" | foreach-object {
    $name, $value = $_ -split '=', 2
    $envVars.Add($name, $value)
  }
  
  return $envVars
}

function Dump-EnvVarsSet {
    param ([hashtable]$envVars)

  foreach ($varEntry in $envVars.GetEnumerator()){
    if([Environment]::GetEnvironmentVariable($varEntry.Key) -ne $varEntry.Value){
      Write-Output "$($varEntry.Key) = $($varEntry.Value)"
    }
  }
}

$vsVersion = $yeartoVersion[[int]$version]

if(-not $vsVersion){
  Write-Error "Unknown VS version $version"
  exit 1
}

$targetName = "VS$($version)Gen.bff"
$targetFile = "$PSScriptRoot\$targetName"
$oldVSGenContent = $null

# Remove previously written file so the build is not done with stale data
If (-not $dumpvcvars -and (Test-Path $targetFile)){
  $oldVSGenContent = Get-Content -Path $targetFile -Raw
  Remove-Item -Path $targetFile
  Write-Output "Removed old $targetFile"
}

if (-not (Test-Path $vswhereDir)) {
  Write-Error "Cannot find vswhere.exe in $vswhereDir"
  exit 1
}

[System.Collections.ArrayList]$vswhereArgs =  @("-nologo", "-format xml", "-prerelease")

if($true) {
 $vswhereArgs.Add("-products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64")  > $null
} else{
 $vswhereArgs.Add("-legacy") > $null
}

if($vsVersion -and $vsVersion -ne 0){
  $vswhereArgs.Add("-version [$vsVersion.0,$($vsVersion+1).0)")  > $null
}

$p, $output, $stderr = Run-VSWhere($vswhereArgs)

if ($p.ExitCode -ne 0){
  Write-Output $output
  Write-Output $stderr
  Write-Error "Running vswhere.exe failed exitcode $($p.ExitCode)"
  exit 1
}

Write-Verbose ($output -join "\n")

try {
  [xml]$outputXml = $output
  $VSinstances = $outputXml.SelectNodes("//instances/instance"); 
} catch {
  Write-Error "Failed to parse vswhere output"
  Write-Output $output
  exit 1
}

Write-Verbose $VSinstances

if ($VSinstances.Count -eq 0){
  Write-Error "vswhere.exe return no results"
  exit 1
 }else{
  Write-Output "vswhere returned $($VSinstances.Count) results"
 }


$prereleaseVSInstance = $null
$VSInstance = $null

foreach ($instance in $VSinstances)
{
  $installPath = $instance.InstallationPath = $instance.InstallationPath -replace "\\$" # Remove potential trailing backslash
  $installedVersion = $instance.InstallationVersion
  $isPrerelease = $instance.IsPrerelease
  
  if($isPrerelease) {
    $prereleaseVSInstance = $instance
  } else {
    $VSInstance = $instance
  }
  
  Write-Output "  $($instance.displayName) in $installPath"
}

Write-Output ""

if($prereleaseVSInstance -and ($usepreview -ne $true -or (!$VSInstance -and $usepreview -eq $null))) {
  $instance = $prereleaseVSInstance 
} else{
  if(!$VSInstance){
    Write-Error "vswhere.exe returned no non preview versions"
    exit 1
  }
  $instance = $VSInstance
}

$envVars = Get-VSDevVars($instance.InstallationPath)

if($dumpvcvars) {
  Dump-EnvVarsSet($envVars)
  exit 0
}

$SDKVersion = $envVars.WindowsSDKLibVersion.Trim("/","\")

$vsGenContent=@"
.VS$($version)_BasePath = '$($envVars.VCINSTALLDIR)'
.VS$($version)_Version  = '$($envVars.VCToolsVersion)'
.VS$($version)_MSC_VER  = '$(1931)'
"@

$winSDKContent=@"
.Windows10_SDKBasePath = "$($envVars.WindowsSdkDir)"
.Windows10_SDKVersion  = "$($SDKVersion)"
"@

Write-Output "$vsGenContent`n$winSDKContent"

Out-File -FilePath $targetFile -InputObject $vsGenContent -Encoding ASCII
Out-File -FilePath "$PSScriptRoot\..\Windows\Win10SDKGen.bff" -InputObject $winSDKContent -Encoding ASCII

if($oldVSGenContent -and $oldVSGenContent.Equals($vsGenContent+"`r`n")) {
  Write-Output "$targetName unchanged"
}else{
  Write-Output "$targetName written."
}
