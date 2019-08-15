#Require -PSEdition Core

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$IsPosix = $IsMacOS -or $IsLinux

$pathSep = if($IsPosix) { ':' } else { ';' }
$dirSep = if($IsPosix) { '/' } else { '\' }


# the packaged solution will be used as the install source for npm
$PackageFile = "$PSScriptRoot/../pwsh-*.tgz"
if (Test-Path $PackageFile){
    $tgz = (get-item $PackageFile).FullName
} else {
    Write-Error "-compile and -package must be completed before running test"
}


# $fromTgz = get-item $PSScriptRoot/../pwsh-*.tgz
# $tgz = "./this-is-the-tgz.tgz"
# remove-item $tgz -ea continue
# move-item $fromTgz $tgz
$npmVersion = (get-content $PSScriptRoot/../package.json | convertfrom-json).version
try {
    $pwshVersion = (get-content $PSScriptRoot/../dist/buildTags.json | convertfrom-json).pwshVersion
} catch {
    $pwshVersion = $null
}

function logBinaryLocations() {
    write-host 'PATH:'
    write-host $env:PATH
    write-host 'BINARY PATHS:'
    write-host (npx which node)
    write-host (npx which npm)
    write-host (npx which pnpm)
    write-host (npx which pwsh)
}

$npm = (Get-Command npm).Source
$pnpm = (Get-Command pnpm).Source

if($IsWindows) {
    try {
        $winPwsh = (get-command pwsh.cmd).path
    } catch {
        $winPwsh = (get-command pwsh.exe).path
    }
}
# Testpath: where to test the installs
$TestPath = $PSScriptRoot 
$platform = if($IsPosix) {'posix' } else { 'windows' } 

# an actual and a symlinked path to thet the install in 
$npmPrefixRealpath    = Join-Path $TestPath -ChildPath "real" -AdditionalChildPath "prefix-$platform"
$npmPrefixSymlink     = Join-Path $TestPath -ChildPath "prefix-link-$platform"

# paths used in testing to verify WHERE the pwsh shim should point to
$npmLocalInstallPath  = Join-Path $TestPath -ChildPath 'node_modules' -AdditionalChildPath '.bin'
if ($IsWindows) {
    $npmGlobalInstallPath = $npmPrefixSymlink
} else {    
    $npmGlobalInstallPath = Join-Path $npmPrefixSymlink -ChildPath 'bin' 
}

# $npmPrefixRealpath = "$PSScriptRoot$( if($IsPosix) { '/real/prefix-posix' } else { '\real\prefix-windows' } )"
# $npmPrefixSymlink = "$PSScriptRoot$( if($IsPosix) { '/prefix-link-posix' } else { '\prefix-link-windows' } )"
# $npmGlobalInstallPath = "$npmPrefixSymlink$( if($IsPosix) { '/bin' } else { '' } )"
# $npmLocalInstallPath = "$PSScriptRoot$( $dirSep )node_modules$( $dirSep ).bin"

<### HELPER FUNCTIONS ###>
function run($block, [switch]$show) {
    if($show) {
        & $block 2>&1 | write-host
    } else {
        & $block
    }
    if($lastexitcode -ne 0) { throw "Non-zero exit code: $LASTEXITCODE" }
}
Function npm {
    & $npm --userconfig "$PSScriptRoot/.npmrc" @args
}
Function pnpm {
    & $pnpm --userconfig "$PSScriptRoot/.npmrc" @args
}
Function retry($times, $delay, $block) {
    while($times) {
        try {
            $block
            break
        } catch {
            $times--
            if($times -le 0) {
                throw $_
            }
            start-sleep $delay
        }
    }
}

# Create a symlink.  On Windows Powershell this requires popping a UAC prompt (ugh)
# however the old-school mklink.exe honors the 'developer workstation setting'

Function symlink($from, $to) {
    $f = get-item $from -ea SilentlyContinue
    if( $f -and $f.target -eq $to) {
        # Write-Verbose  "Symlink already exists: $from --> $to"
        return
    }
    write-host "Symlinking $from --> $to"
    if($IsPosix) {
        new-item -type symboliclink -path $from -Target $to -EA Stop
    }
    else {
        # if Win10 Developer Mode - or running as Admin 
        if ((Test-Path -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock") -or 
            ([bool](([System.Security.Principal.WindowsIdentity]::GetCurrent()).groups -match "S-1-5-32-544") ) )  
        {
            Write-verbose 'Using old-skool mklink to avoid UAC prompt on developer workstations'
            # path has been removed for testing :-( 
            $winpath = $oldPath.Split(';')|?{$_ -like "*:\windows\system32"} | select -First 1
            $cmd = "$winpath\cmd.exe" 
            & $cmd /c mklink /D $from $to
        } else {
            Write-Error "Need to enable Developer Mode or run as Admin to create the Symlink"
            # start-process -verb runas -wait $winPwsh -argumentlist @(
            #     '-noprofile', '-file', "$PSScriptRoot/create-symlink.ps1",
            #     $from, $to
            # ) -erroraction stop
        }
    }
}

Describe 'pwsh' {

    #create testlocation 
    New-Item -Path $TestPath -ItemType Directory -ErrorAction SilentlyContinue | Out-Null
    #copy template files 
    Copy-Item ( join-path $PSScriptRoot 'template/*') -Destination $TestPath -Container -Force
    # move to that location

    $oldLocation = Get-Location
    Set-Location $TestPath #$PSScriptRoot
    BeforeEach {
        <### SETUP ENVIRONMENT ###>

        # Add node_modules/.bin to PATH; remove any paths containing pwsh
        $oldPath = $env:PATH
        $env:PATH = (& {
            # Local bin
            $npmLocalInstallPath
            # Global bin in npm prefix
            $npmGlobalInstallPath
            # Path to node & npm, pnpm, which, sh, etc
            Split-Path -Parent $npm
            Split-Path -Parent $pnpm
            Split-Path -Parent (npx which which)
            # Path to sh
            if($IsPosix) {
                Split-Path -Parent ( Get-Command sh ).Source
            }
        }) -join $pathSep

        <### CLEAN ###>
        if(test-path ./node_modules) {
            remove-item -recurse ./node_modules -force
        }
        if(test-path $npmPrefixRealpath) {
            remove-item -recurse $npmPrefixRealpath -force
        }
        new-item -type directory $npmPrefixRealpath
        
        symlink $npmPrefixSymlink $npmPrefixRealpath

        # Set npm prefix
        set-content ./.npmrc -encoding utf8 "prefix = $($npmPrefix -replace '\\','\\')"

        $preexistingPwsh = get-command pwsh -EA SilentlyContinue
        if($preexistingPwsh) { $preExistingPwsh = $preexistingPwsh.Source }

    }
    AfterEach {
        $env:PATH = $oldPath
    }

    $tests = {
        context 'ready for testing' {
            it 'npm prefix symlink exists' {
                (Get-Item $npmPrefixSymlink).attributes -eq 'symboliclink'
            }

            it 'npm prefix set correctly for testing' {
                run { npm config get prefix } | should -be $npmPrefix
            }
        }

        context 'local installation via npm' {
            Write-Host -F DarkMagenta "BEFORE"
            beforeeach {
                run { npm install $tgz }
            }
            context 'Test' {
                it 'pwsh is in path and is correct version' {
                    (get-command pwsh).source | should -belike "$npmLocalInstallPath*"
                    if($pwshVersion -ne 'latest') {
                        pwsh --version | should -be "PowerShell v$pwshVersion"
                    }
                }
            }
            aftereach {
                run { npm uninstall $tgz }
                retry 4 1 { remove-item -r node_modules }
            }
        }
        context 'local installation via pnpm' {
            beforeeach {
                run { pnpm install $tgz }
            }
            it 'pwsh is in path and is correct version' {
                (get-command pwsh).source | should -belike "$npmLocalInstallPath*"
                
                if($pwshVersion -ne 'latest') {
                    pwsh --version | should -be "PowerShell v$pwshVersion"
                }
            }
            aftereach {
                # run { pnpm uninstall $tgz }
                write-host 'deleting node_modules'
                retry 4 1 { remove-item -r node_modules }
                write-host 'deleted node_modules'
            }
        }
        context 'global installation' {
            beforeeach {
                run { npm install --global $tgz }
            }
            it 'pwsh is in path and is correct version' {
                (get-command pwsh).source | should -belike "$npmGlobalInstallPath*"
                (get-command pwsh).source | should -not -Be $preExistingPwsh
                if($pwshVersion -ne 'latest') {
                    pwsh --version | should -be "PowerShell v$pwshVersion"
                }
            }
            aftereach {
                run { npm uninstall --global $tgz }
            }
        }
    }

    $npmPrefix = $npmPrefixSymlink
    describe 'npm prefix is symlink' {
        . $tests
    }

    $npmPrefix = $npmPrefixRealpath
    describe 'npm prefix is realpath' {
        . $tests
    }

    Set-Location $oldLocation
}
