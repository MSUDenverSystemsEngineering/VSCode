## Define variables
$fileShare = New-PSSession -ComputerName $Env:serverName

$stagingDir = $Env:stagingDirectory
$cert = (Get-ChildItem Cert:\LocalMachine\My -CodeSigningCert)

$initParams = @{}
## Uncomment the next line for debugging
## $initParams.Add("Verbose", $true)

## Set application properties
$appName = $Env:APPVEYOR_PROJECT_NAME
$appName = $appName -replace "_+"," " -replace "\-{2,}"," - " -replace "\b-+\b"," "
$install = "Deploy-Application.exe -DeploymentType `"Install`" -AllowRebootPassThru"
$uninstall = "Deploy-Application.exe -DeploymentType `"Uninstall`" -AllowRebootPassThru"

## Determine the app's author
switch ($Env:APPVEYOR_REPO_COMMIT_AUTHOR) {
  $Env:jordanGitHub { $author = $Env:jordan }
  $Env:quanGitHub { $author = $Env:quan }
  $Env:steveGitHub { $author = $Env:steve }
  $Env:truongGitHub { $author = $Env:truong }
  $Env:jamesGitHub { $author = $Env:james }
  $Env:davidGitHub { $author = $Env:david }
  $Env:craigGitHub { $author = $Env:craig }
}

## Remove unneeded files from the repository before uploading to the file share
Write-Output "Cleaning up Git and CI files..."
Remove-Item -Path "$Env:APPLICATION_PATH\appveyor.yml"
Remove-Item -Path "$Env:APPLICATION_PATH\deploy.ps1"
Remove-Item -Path "$Env:APPLICATION_PATH\TestsResults.xml"
Remove-Item -Path "$Env:APPLICATION_PATH\.DS_Store" -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$Env:APPLICATION_PATH\.gitignore" -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$Env:APPLICATION_PATH\.gitattributes" -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$Env:APPLICATION_PATH\Tests" -Recurse
Remove-Item -Path "$Env:APPLICATION_PATH\.git" -Recurse -Force

## Sign PowerShell files to allow running the script directly with a RemoteSigned execution policy
Get-ChildItem  "$Env:APPLICATION_PATH\AppDeployToolkit" `
  | Where-Object { $_.Name -like "*.ps1" } `
    | ForEach-Object `
      { Set-AuthenticodeSignature $_.FullName $cert `
        -HashAlgorithm SHA256 `
        -TimestampServer "$Env:timestampServer" `
      }

Get-ChildItem  "$Env:APPLICATION_PATH" `
  | Where-Object { $_.Name -like "Deploy-Application.ps1" } `
    | ForEach-Object `
      { Set-AuthenticodeSignature $_.FullName $cert `
        -HashAlgorithm SHA256 `
        -TimestampServer "$Env:timestampServer" `
      }

$contentLocation = "$Env:stagingContentLocation\$appName"

## Remove previous staging toolkit files if detected, except for Files and SupportFiles
Invoke-Command -Session $fileShare -ScriptBlock {
  If (Test-Path -Path "$Using:stagingDir\$Using:appName" -PathType Container) {
    Write-Output "Removing staging PowerShell App Deployment Toolkit..."
    Remove-Item -Path "$Using:stagingDir\$Using:appName\*.*" -Force | Where-Object { ! $_.PSIsContainer }
    Remove-Item -Path "$Using:stagingDir\$Using:appName\AppDeployToolkit" -Force -Recurse | `
      Where-Object { $_.PSIsContainer }
  } Else {
    New-Item -Path $Using:stagingDir -Name $Using:appName -ItemType "directory"
  }
}

## Upload the repository to the staging directory, overwriting any remaining files or support files
Copy-Item -Path "$Env:APPLICATION_PATH\*" -Destination "$stagingDir\$appName\" -ToSession $fileShare -Force -Recurse

## Set the application name as we want it to appear in Configuration Manager
$appName = "Staging - $appName"

## Import the ConfigurationManager.psd1 module
If ($null -eq (Get-Module ConfigurationManager)) {
  Import-Module "$($Env:SMS_ADMIN_UI_PATH)\..\ConfigurationManager.psd1" @initParams
}

## Connect to the site's drive if it is not already present
If ($null -eq (Get-PSDrive -Name $Env:siteCode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
  New-PSDrive -Name $Env:siteCode -PSProvider CMSite -Root $Env:siteServer @initParams
}

## Set the active PSDrive to the ConfigMgr site code
Set-Location "$($Env:siteCode):\" @initParams

## Create the ConfigMgr application (if it doesn't exist) in the format "Staging - GitHub project name"
## This also adds a link to the GitHub repository in the Administrator Comments field for reference and checks the box next to "Allow this application to be installed from the Install Application task sequence action without being deployed"
## Reference: https://docs.microsoft.com/en-us/powershell/module/configurationmanager/new-cmapplication
If ((Get-CMApplication -Name $appName -ErrorAction SilentlyContinue) `
  -or (Get-CMApplication -Name "Staging - $Env:APPVEYOR_PROJECT_NAME" -ErrorAction SilentlyContinue)) {
  
    ## Rename an existing Staging application if detected
  If (Get-CMApplication -Name "Staging - $Env:APPVEYOR_PROJECT_NAME" -ErrorAction SilentlyContinue) {
    Get-CMApplication -Name "Staging - $Env:APPVEYOR_PROJECT_NAME" | Set-CMApplication -NewName $appName
  }
  ## Clear any existing owners and support contacts
  Get-CMApplication -Name $appName | Set-CMApplication -ClearOwner -ClearSupportContact
} Else {
  New-CMApplication -Name $appName
}

Get-CMApplication -Name $appName | `
  Set-CMApplication -Description "Repository: https://github.com/$Env:APPVEYOR_REPO_NAME" `
    -ReleaseDate $(Get-Date -Format d) `
    -Owner $author `
    -SupportContact 'System Engineers' `
    -AutoInstall $True

## Create a new script deployment type with standard settings for PowerShell App Deployment Toolkit
## You'll need to manually update the deployment type's detection method to find the software, make any other needed customizations to the application and deployment type, then distribute your content when ready.
## Reference: https://docs.microsoft.com/en-us/powershell/module/configurationmanager/add-cmscriptdeploymenttype
Get-CMApplication -Name $appName | `
  Add-CMScriptDeploymentType -DeploymentTypeName `
    "$appName $Env:APPVEYOR_BUILD_VERSION" `
    -InstallCommand $install `
    -ScriptLanguage "PowerShell" `
    -ScriptText "Update this application's detection method to accurately locate the application." `
    -ContentLocation $contentLocation `
    -InstallationBehaviorType "InstallForSystem" `
    -LogonRequirementType "WhetherOrNotUserLoggedOn" `
    -MaximumRuntimeMins 120 `
    -UserInteractionMode "Normal" `
    -UninstallCommand $uninstall `
    -ContentFallback `
    -Comment "Commit: https://github.com/$Env:APPVEYOR_REPO_NAME/commit/$Env:APPVEYOR_REPO_COMMIT" `
    -SlowNetworkDeploymentMode 'Download' `
    -EnableBranchCache

# SIG # Begin signature block
# MIIU9wYJKoZIhvcNAQcCoIIU6DCCFOQCAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQU+J17ymFWPSuzW6Pne22fTlFz
# iSigghHXMIIFbzCCBFegAwIBAgIQSPyTtGBVlI02p8mKidaUFjANBgkqhkiG9w0B
# AQwFADB7MQswCQYDVQQGEwJHQjEbMBkGA1UECAwSR3JlYXRlciBNYW5jaGVzdGVy
# MRAwDgYDVQQHDAdTYWxmb3JkMRowGAYDVQQKDBFDb21vZG8gQ0EgTGltaXRlZDEh
# MB8GA1UEAwwYQUFBIENlcnRpZmljYXRlIFNlcnZpY2VzMB4XDTIxMDUyNTAwMDAw
# MFoXDTI4MTIzMTIzNTk1OVowVjELMAkGA1UEBhMCR0IxGDAWBgNVBAoTD1NlY3Rp
# Z28gTGltaXRlZDEtMCsGA1UEAxMkU2VjdGlnbyBQdWJsaWMgQ29kZSBTaWduaW5n
# IFJvb3QgUjQ2MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAjeeUEiIE
# JHQu/xYjApKKtq42haxH1CORKz7cfeIxoFFvrISR41KKteKW3tCHYySJiv/vEpM7
# fbu2ir29BX8nm2tl06UMabG8STma8W1uquSggyfamg0rUOlLW7O4ZDakfko9qXGr
# YbNzszwLDO/bM1flvjQ345cbXf0fEj2CA3bm+z9m0pQxafptszSswXp43JJQ8mTH
# qi0Eq8Nq6uAvp6fcbtfo/9ohq0C/ue4NnsbZnpnvxt4fqQx2sycgoda6/YDnAdLv
# 64IplXCN/7sVz/7RDzaiLk8ykHRGa0c1E3cFM09jLrgt4b9lpwRrGNhx+swI8m2J
# mRCxrds+LOSqGLDGBwF1Z95t6WNjHjZ/aYm+qkU+blpfj6Fby50whjDoA7NAxg0P
# OM1nqFOI+rgwZfpvx+cdsYN0aT6sxGg7seZnM5q2COCABUhA7vaCZEao9XOwBpXy
# bGWfv1VbHJxXGsd4RnxwqpQbghesh+m2yQ6BHEDWFhcp/FycGCvqRfXvvdVnTyhe
# Be6QTHrnxvTQ/PrNPjJGEyA2igTqt6oHRpwNkzoJZplYXCmjuQymMDg80EY2NXyc
# uu7D1fkKdvp+BRtAypI16dV60bV/AK6pkKrFfwGcELEW/MxuGNxvYv6mUKe4e7id
# FT/+IAx1yCJaE5UZkADpGtXChvHjjuxf9OUCAwEAAaOCARIwggEOMB8GA1UdIwQY
# MBaAFKARCiM+lvEH7OKvKe+CpX/QMKS0MB0GA1UdDgQWBBQy65Ka/zWWSC8oQEJw
# IDaRXBeF5jAOBgNVHQ8BAf8EBAMCAYYwDwYDVR0TAQH/BAUwAwEB/zATBgNVHSUE
# DDAKBggrBgEFBQcDAzAbBgNVHSAEFDASMAYGBFUdIAAwCAYGZ4EMAQQBMEMGA1Ud
# HwQ8MDowOKA2oDSGMmh0dHA6Ly9jcmwuY29tb2RvY2EuY29tL0FBQUNlcnRpZmlj
# YXRlU2VydmljZXMuY3JsMDQGCCsGAQUFBwEBBCgwJjAkBggrBgEFBQcwAYYYaHR0
# cDovL29jc3AuY29tb2RvY2EuY29tMA0GCSqGSIb3DQEBDAUAA4IBAQASv6Hvi3Sa
# mES4aUa1qyQKDKSKZ7g6gb9Fin1SB6iNH04hhTmja14tIIa/ELiueTtTzbT72ES+
# BtlcY2fUQBaHRIZyKtYyFfUSg8L54V0RQGf2QidyxSPiAjgaTCDi2wH3zUZPJqJ8
# ZsBRNraJAlTH/Fj7bADu/pimLpWhDFMpH2/YGaZPnvesCepdgsaLr4CnvYFIUoQx
# 2jLsFeSmTD1sOXPUC4U5IOCFGmjhp0g4qdE2JXfBjRkWxYhMZn0vY86Y6GnfrDyo
# XZ3JHFuu2PMvdM+4fvbXg50RlmKarkUT2n/cR/vfw1Kf5gZV6Z2M8jpiUbzsJA8p
# 1FiAhORFe1rYMIIGGjCCBAKgAwIBAgIQYh1tDFIBnjuQeRUgiSEcCjANBgkqhkiG
# 9w0BAQwFADBWMQswCQYDVQQGEwJHQjEYMBYGA1UEChMPU2VjdGlnbyBMaW1pdGVk
# MS0wKwYDVQQDEyRTZWN0aWdvIFB1YmxpYyBDb2RlIFNpZ25pbmcgUm9vdCBSNDYw
# HhcNMjEwMzIyMDAwMDAwWhcNMzYwMzIxMjM1OTU5WjBUMQswCQYDVQQGEwJHQjEY
# MBYGA1UEChMPU2VjdGlnbyBMaW1pdGVkMSswKQYDVQQDEyJTZWN0aWdvIFB1Ymxp
# YyBDb2RlIFNpZ25pbmcgQ0EgUjM2MIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIB
# igKCAYEAmyudU/o1P45gBkNqwM/1f/bIU1MYyM7TbH78WAeVF3llMwsRHgBGRmxD
# eEDIArCS2VCoVk4Y/8j6stIkmYV5Gej4NgNjVQ4BYoDjGMwdjioXan1hlaGFt4Wk
# 9vT0k2oWJMJjL9G//N523hAm4jF4UjrW2pvv9+hdPX8tbbAfI3v0VdJiJPFy/7Xw
# iunD7mBxNtecM6ytIdUlh08T2z7mJEXZD9OWcJkZk5wDuf2q52PN43jc4T9OkoXZ
# 0arWZVeffvMr/iiIROSCzKoDmWABDRzV/UiQ5vqsaeFaqQdzFf4ed8peNWh1OaZX
# nYvZQgWx/SXiJDRSAolRzZEZquE6cbcH747FHncs/Kzcn0Ccv2jrOW+LPmnOyB+t
# AfiWu01TPhCr9VrkxsHC5qFNxaThTG5j4/Kc+ODD2dX/fmBECELcvzUHf9shoFvr
# n35XGf2RPaNTO2uSZ6n9otv7jElspkfK9qEATHZcodp+R4q2OIypxR//YEb3fkDn
# 3UayWW9bAgMBAAGjggFkMIIBYDAfBgNVHSMEGDAWgBQy65Ka/zWWSC8oQEJwIDaR
# XBeF5jAdBgNVHQ4EFgQUDyrLIIcouOxvSK4rVKYpqhekzQwwDgYDVR0PAQH/BAQD
# AgGGMBIGA1UdEwEB/wQIMAYBAf8CAQAwEwYDVR0lBAwwCgYIKwYBBQUHAwMwGwYD
# VR0gBBQwEjAGBgRVHSAAMAgGBmeBDAEEATBLBgNVHR8ERDBCMECgPqA8hjpodHRw
# Oi8vY3JsLnNlY3RpZ28uY29tL1NlY3RpZ29QdWJsaWNDb2RlU2lnbmluZ1Jvb3RS
# NDYuY3JsMHsGCCsGAQUFBwEBBG8wbTBGBggrBgEFBQcwAoY6aHR0cDovL2NydC5z
# ZWN0aWdvLmNvbS9TZWN0aWdvUHVibGljQ29kZVNpZ25pbmdSb290UjQ2LnA3YzAj
# BggrBgEFBQcwAYYXaHR0cDovL29jc3Auc2VjdGlnby5jb20wDQYJKoZIhvcNAQEM
# BQADggIBAAb/guF3YzZue6EVIJsT/wT+mHVEYcNWlXHRkT+FoetAQLHI1uBy/YXK
# ZDk8+Y1LoNqHrp22AKMGxQtgCivnDHFyAQ9GXTmlk7MjcgQbDCx6mn7yIawsppWk
# vfPkKaAQsiqaT9DnMWBHVNIabGqgQSGTrQWo43MOfsPynhbz2Hyxf5XWKZpRvr3d
# MapandPfYgoZ8iDL2OR3sYztgJrbG6VZ9DoTXFm1g0Rf97Aaen1l4c+w3DC+IkwF
# kvjFV3jS49ZSc4lShKK6BrPTJYs4NG1DGzmpToTnwoqZ8fAmi2XlZnuchC4NPSZa
# PATHvNIzt+z1PHo35D/f7j2pO1S8BCysQDHCbM5Mnomnq5aYcKCsdbh0czchOm8b
# kinLrYrKpii+Tk7pwL7TjRKLXkomm5D1Umds++pip8wH2cQpf93at3VDcOK4N7Ew
# oIJB0kak6pSzEu4I64U6gZs7tS/dGNSljf2OSSnRr7KWzq03zl8l75jy+hOds9TW
# SenLbjBQUGR96cFr6lEUfAIEHVC1L68Y1GGxx4/eRI82ut83axHMViw1+sVpbPxg
# 51Tbnio1lB93079WPFnYaOvfGAA0e0zcfF/M9gXr+korwQTh2Prqooq2bYNMvUoU
# KD85gnJ+t0smrWrb8dee2CvYZXD5laGtaAxOfy/VKNmwuWuAh9kcMIIGQjCCBKqg
# AwIBAgIRAKVN33D73PFMVIK48rFyyjEwDQYJKoZIhvcNAQEMBQAwVDELMAkGA1UE
# BhMCR0IxGDAWBgNVBAoTD1NlY3RpZ28gTGltaXRlZDErMCkGA1UEAxMiU2VjdGln
# byBQdWJsaWMgQ29kZSBTaWduaW5nIENBIFIzNjAeFw0yMTA2MDkwMDAwMDBaFw0y
# NDA2MDgyMzU5NTlaMIGVMQswCQYDVQQGEwJVUzERMA8GA1UECAwIQ29sb3JhZG8x
# DzANBgNVBAcMBkRlbnZlcjEwMC4GA1UECgwnTWV0cm9wb2xpdGFuIFN0YXRlIFVu
# aXZlcnNpdHkgb2YgRGVudmVyMTAwLgYDVQQDDCdNZXRyb3BvbGl0YW4gU3RhdGUg
# VW5pdmVyc2l0eSBvZiBEZW52ZXIwggGiMA0GCSqGSIb3DQEBAQUAA4IBjwAwggGK
# AoIBgQCm6Atd6yEc/W5UCNp/h5BikWqPKgINMSLcRjaIRilzk9VGu4Q1hufpdjAa
# XXW0EHzEjshU/gMorErUXxUW9U1NWkiPEMRydb5DquuAGSlyCrjcUxEL+9USsk4J
# 483biCOEKgYbCLK1+LzeT2hav8ioyaikrGEIxXo+CsdnzkVzBUR56mgBlu6gMCby
# nE1As1Z/9YavXYem908Tnd7dcdi9D2s/+GhfiQIZDThfRnNgfIXk6EZZU0DjklHT
# 898JFt8u7us3CTBIMXp54kz+35N+PIV5azwY8me6oswid8Fh/kEagakoXimTfzpc
# OmmHaiwJm5fS2d2dP670DJPwA0x7GOYwF8AEY8QJVPoJ8Y/+pMrEuiQxT/tB+wg9
# 30ZUgTlrHD24N9eM3hjMfHjizfNVlirv+/Ut1h1gH/OLsTZ6dg3Ff/GjbI16GsX3
# UFlyaerN1dcH+ScsL+58XGYLUufjCcx07/mHN4T1D+14y6WgIpx3/Pq2nusj+zle
# q9yWd/UCAwEAAaOCAcswggHHMB8GA1UdIwQYMBaAFA8qyyCHKLjsb0iuK1SmKaoX
# pM0MMB0GA1UdDgQWBBTLXarMi7SgsX53Cweg5K+AM/BXJTAOBgNVHQ8BAf8EBAMC
# B4AwDAYDVR0TAQH/BAIwADATBgNVHSUEDDAKBggrBgEFBQcDAzARBglghkgBhvhC
# AQEEBAMCBBAwSgYDVR0gBEMwQTA1BgwrBgEEAbIxAQIBAwIwJTAjBggrBgEFBQcC
# ARYXaHR0cHM6Ly9zZWN0aWdvLmNvbS9DUFMwCAYGZ4EMAQQBMEkGA1UdHwRCMEAw
# PqA8oDqGOGh0dHA6Ly9jcmwuc2VjdGlnby5jb20vU2VjdGlnb1B1YmxpY0NvZGVT
# aWduaW5nQ0FSMzYuY3JsMHkGCCsGAQUFBwEBBG0wazBEBggrBgEFBQcwAoY4aHR0
# cDovL2NydC5zZWN0aWdvLmNvbS9TZWN0aWdvUHVibGljQ29kZVNpZ25pbmdDQVIz
# Ni5jcnQwIwYIKwYBBQUHMAGGF2h0dHA6Ly9vY3NwLnNlY3RpZ28uY29tMC0GA1Ud
# EQQmMCSBIml0c3N5c3RlbWVuZ2luZWVyaW5nQG1zdWRlbnZlci5lZHUwDQYJKoZI
# hvcNAQEMBQADggGBAH/FAFHuy+iH7Vk/LuZw8nkpQIBsQc4+A3d8YI0cJLIUh+x+
# U78k2nZGZQQaKEy9/dCBtV9bryx5jgtt6hiNGMrWCwnzXCqatSY6PFdCXPXtUcBx
# h/8+ud3CeE7AmGHRk4LcM9SdTmRx1XjMK9Kest4O7dBEUbgQpatb54sVESclkcIO
# 5pUowa4kab9gCmPMcEgdyTHAxffmLEWAkoYofoS3D6eGMoJGh45VYXOSv4irKEtY
# +wk+Km41ZdO+wplcrDvCjA0kwEzHzmmBZ4GsRbz3znKjcQrvJ9SDCBZzJ3aIlnv0
# rd7Q3cIEnUEKgcWduCmWRg6mvY/o5b3DuwL4k9ufPonL2Ym154FATNWk3j7zJ1vd
# bkyZcMpefCtVtgg511abPE2VDF0KvLg/WJ+FQNTAzZHzeZnhwVJpoiPGTBwa9ra8
# zPeFPxKUwlSvh7kpTgdKE1QtPbTKq3KCt1CVzXTXPo/iCh3pPnc1HMIuFYJiRvnY
# K4Elz1T3NrNPgL038zGCAoowggKGAgEBMGkwVDELMAkGA1UEBhMCR0IxGDAWBgNV
# BAoTD1NlY3RpZ28gTGltaXRlZDErMCkGA1UEAxMiU2VjdGlnbyBQdWJsaWMgQ29k
# ZSBTaWduaW5nIENBIFIzNgIRAKVN33D73PFMVIK48rFyyjEwCQYFKw4DAhoFAKB4
# MBgGCisGAQQBgjcCAQwxCjAIoAKAAKECgAAwGQYJKoZIhvcNAQkDMQwGCisGAQQB
# gjcCAQQwHAYKKwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwIwYJKoZIhvcNAQkE
# MRYEFAqrc6o/sQsOgKV+h1zvgOLoWjHPMA0GCSqGSIb3DQEBAQUABIIBgFpMBPP9
# ytsJjQWe2aj8RWDfWsxS5HVNySzj2kQxDQR7d/bLjIInwn0cHfs8kpGgrQT24/l+
# 8ibY7L9LQeueMw8UknqfdK1Tm+sOFJWTWheTjTRdgZAg5DMqSQ+bFj0ioISliTSg
# L+f34JDNmkoOYotRtwGiEUfIjvVb7BI+ecPN18FxN3h6KDNxhG3uVm0X+TA07qga
# Fk5lA1s/T/Gzp7IBqZ7459rI7qWfq5WXi4937IWgbo1Be8PBo443i7beB81HDFIq
# zQDhriAP39iltzIgO8JN08YBgJ5DK/EPDUIWseiF+KHZgfXXPw2LzcOZuLZZGtay
# BQb98oBDHqjQfC2I4q2KL36bIHRafpSL64WLe5oiTlBGKuBh2ffUHEfJMycftemp
# 4gE/ATuSJFvFjiUMOZRjWmibINM29SCDs1ztsShVJM5NGaiVVpP4q4M0cAtIAGJf
# HKh7HFI2C3ukYc/UZJ4yyF/rGMEcuZJY+H0CC0P1/r5aduUbW/KKUOjjWg==
# SIG # End signature block
