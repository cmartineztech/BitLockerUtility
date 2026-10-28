<#Carlos Martinez Date: 11/16/2019 GitHub @cmartinezone

DESCRIPTION: Manipulate BitLocker from WinPE Environment
BitLockerUtility 3.0
#>

Set-StrictMode -Version 2.0

#Function To Get the Drive encrypted.
function GetDrivesEncryption {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $false, ValueFromPipeline = $false)]
        [ValidateSet("Locked", "Unlocked", "Off")]
        $Status
    )

    #Get List of Storage Devices and exclude "CD-DVD ROM".
    $ListOfDrives = @(Get-Volume | Where-Object { $null -ne $_.DriveLetter -and $_.DriveType -ne "CD-ROM" })
    #Select Initial object properties.
    $ListOfDrives = @($ListOfDrives | Select-Object DriveLetter, FileSystemType, DriveType, HealthStatus, OperationalStatus, @{n = "Size / GB"; e = { [math]::Truncate($_.Size / 1GB) } })
    #Add additional Properties to the output object of the Storage devices.
    foreach ($drv in $ListOfDrives) {
        $drv | Add-Member -MemberType NoteProperty -Name Encrypted        -Value 'False' -Force
        $drv | Add-Member -MemberType NoteProperty -Name ProtectorStatus  -Value 'None'  -Force
        $drv | Add-Member -MemberType NoteProperty -Name EncryptionMethod -Value 'None'  -Force
        $drv | Add-Member -MemberType NoteProperty -Name RecoveryKeyID    -Value 'None'  -Force
    }

    #WMI Object to query Encrypted.
    $BitLockerDrives = @(Get-WmiObject -Namespace "Root\cimv2\Security\MicrosoftVolumeEncryption" -Class "Win32_EncryptableVolume" -ErrorAction SilentlyContinue)
    $KeyProtectorType = 3 # Recovery password Protector type.

    #For each Drive Found in the WMI object as encrypted.
    foreach ($blDrive in $BitLockerDrives) {
        if ($null -eq $blDrive) { continue }

        #Temp Variables.
        $DriveLetter      = $blDrive.DriveLetter
        $Encrypted        = $blDrive.IsVolumeInitializedForProtection
        $ProtectorStatus  = [string]$blDrive.ProtectionStatus
        $EncryptionMethod = [string]$blDrive.EncryptionMethod

        #Type of protector status.
        switch ($ProtectorStatus) {
            ("0")   { $ProtectorStatus = "Off" }
            ("1")   { $ProtectorStatus = "On (UnLocked)" }
            ("2")   { $ProtectorStatus = "On (Locked)" }
            Default { $ProtectorStatus = "Unknown" }
        }

        #Type of encryption Methods.
        switch ($EncryptionMethod) {
            ("0")   { $EncryptionMethod = "None" }
            ("1")   { $EncryptionMethod = "AES 128 WITH DIFFUSER" }
            ("2")   { $EncryptionMethod = "AES 256 WITH DIFFUSER" }
            ("3")   { $EncryptionMethod = "AES 128" }
            ("4")   { $EncryptionMethod = "AES 256" }
            ("5")   { $EncryptionMethod = "Hardware Encryption" }
            ("6")   { $EncryptionMethod = "XTS-AES 128" }
            ("7")   { $EncryptionMethod = "XTS-AES 256" }
            Default { $EncryptionMethod = "Unknown" }
        }

        #Get Recovery key (Recovery password ID).
        $protectorResult = $blDrive.GetKeyProtectors($KeyProtectorType)
        $RecoveryKeyID = if ($null -ne $protectorResult) { $protectorResult.volumekeyprotectorID } else { 'None' }

        $ListOfDrives | ForEach-Object {
            if ($DriveLetter -eq ($_.DriveLetter + ':')) {
                if ($_."Size / GB" -eq "0") { $_."Size / GB" = "Unknown" }
                $_.Encrypted = [string]$Encrypted
                $_.ProtectorStatus = $ProtectorStatus
                $_.EncryptionMethod = $EncryptionMethod
                $_.RecoveryKeyID = $RecoveryKeyID
            }
        }

        #Clear Temp Variable values.
        Clear-Variable -Name DriveLetter, Encrypted, ProtectorStatus, EncryptionMethod, RecoveryKeyID -ErrorAction SilentlyContinue
    }

    switch ($Status) {
        ("UnLocked") { return @($ListOfDrives | Where-Object { $_.Encrypted -eq "True" -and $_.ProtectorStatus -ne "On (Locked)" }) }
        ("Locked")   { return @($ListOfDrives | Where-Object { $_.ProtectorStatus -eq "On (Locked)" }) }
        ("Off")      { return @($ListOfDrives | Where-Object { $_.Encrypted -eq "False" }) }
        Default      { return $ListOfDrives }
    }
}

#FUNCTION TO UNLOCK THE ENCRYPTED DRIVE
function UnLockDrive {

    #Get the list of Drives Found as encrypted and Locked from the main function.
    $EncryptedDrives = @(GetDrivesEncryption -Status Locked | Sort-Object -Property DriveLetter)

    #If the return drives object is not empty.
    if ($EncryptedDrives.Count -gt 0) {

        if ($EncryptedDrives.Count -gt 1) { Clear-Host }

        #Print list of drives by encrypted status.
        Write-Host "`r`nLocked Drive Volumes Detected:" -ForegroundColor Yellow
        $EncryptedDrives | Format-List -GroupBy Encrypted

        Write-Host "Enter the Drive Volume Letter to Unlock:" -ForegroundColor Black -BackgroundColor Yellow -NoNewline
        $EnterDriveLetter = [string](Read-Host)
        $cleanLetter = $EnterDriveLetter.Trim().TrimEnd(':').ToUpperInvariant()

        #Find Drive Letter in the property DriveLetter in the Object array using exact match
        $GetDrive = @($EncryptedDrives | Where-Object { ([string]$_.DriveLetter).ToUpperInvariant() -eq $cleanLetter })

        #Evaluate user input and object return
        if ([string]::IsNullOrWhiteSpace($cleanLetter) -or $cleanLetter -notmatch '^[A-Z]$' -or $GetDrive.Count -ne 1) {

            Write-Host "`r`nNo Drive Volume Letter Found, Please try again.`r`n" -ForegroundColor Red
            Clear-Variable -Name EnterDriveLetter, cleanLetter, GetDrive -ErrorAction SilentlyContinue
        }
        else {
            $selectedDrive = $GetDrive[0]
            Clear-Host
            Write-Host "`r`nDrive Volume selected: " -ForegroundColor Yellow
            $selectedDrive
            Write-Host "Recovery Key Password IDs: " -ForegroundColor Yellow -NoNewline
            Write-Host $selectedDrive.RecoveryKeyID -ForegroundColor Green
            Write-Host "Enter the Recovery Key Password in the below format:" -ForegroundColor Yellow
            Write-Host "Recovery Key: XXXXXX-XXXXXX-XXXXXX-XXXXXX-XXXXXX-XXXXXX-XXXXXX-XXXXXX" -BackgroundColor Yellow -ForegroundColor Black

            $Key = $null
            $manageoutput = $null
            $DriveLetter = $selectedDrive.DriveLetter + ":"
            try {
                $Key = [string](Read-Host "Recovery Key")
                if ($null -ne $Key) { $Key = $Key.Trim() }

                #Validate 48-digit BitLocker Recovery Password format (8 groups of 6 digits separated by hyphens, length 55)
                if (-not [string]::IsNullOrEmpty($Key) -and $Key.Length -eq 55 -and $Key -match '^\d{6}(-\d{6}){7}$') {
                    manage-bde -Unlock $DriveLetter -RecoveryPassword $Key | Out-String -OutVariable manageoutput | Out-Null
                    if ($manageoutput -match "successfully unlocked") {
                        Write-Host "`r`nThe Recovery Password successfully unlocked volume: $DriveLetter `r`n" -ForegroundColor Green
                    }
                    else {
                        Write-Host "`n$manageoutput" -ForegroundColor Red
                    }
                }
                else {
                    Write-Host "`r`nThe Recovery Key Password format is not correct, Please try again. `r`n" -ForegroundColor Red
                }
            }
            finally {
                $Key = $null
                $manageoutput = $null
                Clear-Variable -Name Key, manageoutput, EnterDriveLetter, cleanLetter, GetDrive, selectedDrive, DriveLetter -ErrorAction SilentlyContinue
            }
        }
    }
    else {
        Write-Host "`r`nNo Encrypted and Locked drive detected" -ForegroundColor Yellow
        Write-Host "Please make sure the Drive is connected!`r`n" -ForegroundColor Yellow
    }
}

#FUNCTION FOR TURN OFF AND SUSPEND BITLOCKER ENCRYPTION
function TurnOffBitLockerAndSuspend {

    #Get the list of Drives Found as encrypted and UnLocked from the main function.
    $UnlockDrives = @(GetDrivesEncryption -Status Unlocked | Sort-Object -Property DriveLetter)

    #If the return drives object is not empty.
    if ($UnlockDrives.Count -gt 0) {
        if ($UnlockDrives.Count -gt 1) { Clear-Host }

        #Print list of drives by Protector status
        Write-Host "`r`nUnlocked Drive Volumes Detected:" -ForegroundColor Yellow
        $UnlockDrives | Format-List -GroupBy ProtectorStatus

        Write-Host "Enter the Drive Volume Letter:" -ForegroundColor Black -BackgroundColor Yellow -NoNewline
        $EnterDriveLetter = [string](Read-Host)
        $cleanLetter = $EnterDriveLetter.Trim().TrimEnd(':').ToUpperInvariant()

        #Find Drive Letter in the property DriveLetter in the Object array using exact match
        $GetDrive = @($UnlockDrives | Where-Object { ([string]$_.DriveLetter).ToUpperInvariant() -eq $cleanLetter })

        #Evaluate user input and object return
        if ([string]::IsNullOrWhiteSpace($cleanLetter) -or $cleanLetter -notmatch '^[A-Z]$' -or $GetDrive.Count -ne 1) {
            Write-Host "`r`nNo Drive Volume Letter Found, Please try again.`r`n" -ForegroundColor Red
            Clear-Variable -Name EnterDriveLetter, cleanLetter, GetDrive -ErrorAction SilentlyContinue
        }
        else {
            $selectedDrive = $GetDrive[0]
            Clear-Host
            Write-Host "`nDrive Volume selected: " -ForegroundColor Yellow
            $selectedDrive
            $DriveLetter = $selectedDrive.DriveLetter + ":"

            Write-Host "BitLocker Options:`r`n" -ForegroundColor Yellow
            Write-Host "  -> Press 1: Turn OFF" -ForegroundColor Yellow
            Write-Host "  -> Press 2: Suspend " -ForegroundColor Yellow
            Write-Host "`r`nEnter one option:" -ForegroundColor Black -BackgroundColor Yellow -NoNewline
            $SelectOption = Read-Host

            #Evaluate Selection if Option 1
            if ($SelectOption -eq "1") {
                $Manageoutput = $null
                try {
                    manage-bde -off $DriveLetter | Out-String -OutVariable Manageoutput | Out-Null
                    [string]$TestManageOutput = $Manageoutput

                    #Evaluate command output if decryption in progress
                    if ($TestManageOutput -match "Decryption is now in progress") {
                        $maxPolls = 86400
                        $pollCount = 0
                        do {
                            $pollCount++
                            Clear-Host
                            Write-Host "`r`nDecryption in Progress... `r`n" -ForegroundColor Yellow
                            #Get decryption progress status across all output lines safely
                            $DecrypProgress = @(manage-bde -status $DriveLetter 2>&1 | ForEach-Object { "$_" })

                            if ($DecrypProgress.Count -gt 0) {
                                $startIdx = [Math]::Min(3, $DecrypProgress.Count - 1)
                                $endIdx = [Math]::Min(12, $DecrypProgress.Count - 1)
                                for ($i = $startIdx; $i -le $endIdx; $i++) {
                                    $lineStr = $DecrypProgress[$i]
                                    if ($lineStr -match 'Conversion Status|Percentage Encrypted|Fully Decrypted') {
                                        Write-Host $lineStr -ForegroundColor Yellow
                                    }
                                    else {
                                        Write-Host $lineStr
                                    }
                                }
                            }

                            if (($DecrypProgress -match "ERROR:") -or $DecrypProgress.Count -eq 0 -or $pollCount -ge $maxPolls) {
                                $ErrorFound = $true
                            }
                            else {
                                $ErrorFound = $false
                            }

                            Start-Sleep 1
                        } until ((($DecrypProgress -match 'Fully Decrypted') -and ($DecrypProgress -match '0\.0%')) -or $ErrorFound -eq $true)

                        if ($ErrorFound -eq $false) {
                            Write-Host "`r`nThe Drive Volume has been Fully Decrypted :)`r`n" -ForegroundColor Green
                            pause
                        }
                        else {
                            Write-Host "`r`nDecryption Interrupted :(`r`n" -ForegroundColor Red
                            pause
                        }
                    }
                    else {
                        Write-Host "`n$Manageoutput" -ForegroundColor Red
                    }
                }
                finally {
                    $Manageoutput = $null
                    Clear-Variable -Name Manageoutput, TestManageOutput -ErrorAction SilentlyContinue
                }
            }
            #Evaluate Selection if Option 2
            elseif ($SelectOption -eq "2") {
                $manageoutput = $null
                try {
                    manage-bde -protectors -disable $DriveLetter | Out-String -OutVariable manageoutput | Out-Null
                    if ($manageoutput -match "Key protectors are disabled") {
                        Write-Host "`r`nKey protectors are disabled for volume: $DriveLetter `r`n" -ForegroundColor Green
                    }
                    else {
                        Write-Host "`r`n$manageoutput" -ForegroundColor Red
                    }
                }
                finally {
                    $manageoutput = $null
                    Clear-Variable -Name manageoutput -ErrorAction SilentlyContinue
                }
            }
            else {
                Write-Host "`r`nNo Option selected, Please try again..`r`n" -ForegroundColor Red
            }
        }
    }
    else {
        Write-Host "`r`nNo Encrypted and Unlocked drive detected" -ForegroundColor Yellow
        Write-Host "Please UnLock the Drive first and try again!`r`n" -ForegroundColor Yellow
    }
}

function Set-WindowSize {
    Param(
        [int]$x = $host.ui.rawui.windowsize.width,
        [int]$y = $host.ui.rawui.windowsize.height
    )

    $size = New-Object System.Management.Automation.Host.Size($x, $y)
    $host.ui.rawui.WindowSize = $size
}

###MAIN MENU
function WindowsTile ($title) { $Host.UI.RawUI.WindowTitle = $title }
function MenuOption ($Option) {
    Write-Host "`t $Option "
    Write-Host "--------------------------------------------------------" -ForegroundColor Yellow
}

function MainMenu {
    WindowsTile ("BitLockerUtility 3.0 - By CarlosMartinez GitHub @cmartinezone")

    $MenuTitle = 'BitLockerUtility 3.0'

    $MenuOptions = @(
        "-> Press 1: Show All Drives"
        "-> Press 2: UnLock BitLocker Drive"
        "-> Press 3: Turn OFF | Suspend BitLocker"
        "-> Press 4: Go to the CMD"
        "-> Press Q: To Quit"
    )

    Write-Host "`n================= $MenuTitle =================`n" -ForegroundColor Yellow
    $MenuOptions | ForEach-Object { MenuOption($_) }
    Write-Host "`n================= $MenuTitle =================`n" -ForegroundColor Yellow
}

if (-not $env:BITLOCKERUTILITY_LOAD_FUNCTIONS_ONLY) {
    #Set the power scheme to high performance
    powercfg /s 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c

    $UserInput = ''
    while ($UserInput -ne "q") {
        Clear-Host
        MainMenu
        Write-Host "Enter one option:" -ForegroundColor Black -BackgroundColor Yellow -NoNewline
        $UserInput = [string](Read-Host)

        switch ($UserInput) {
            1 {
                Write-Host "`nDrives Detected:" -ForegroundColor Yellow
                $GetDrives = @(GetDrivesEncryption)
                if ($GetDrives.Count -eq 0) {
                    Write-Host "`r`nNo Encrypted Drives Detected :(`r`n" -ForegroundColor Red
                }
                else {
                    $GetDrives | Sort-Object -Property DriveLetter | Format-List
                }
                Pause
            }
            2 { UnLockDrive; Pause }
            3 { TurnOffBitLockerAndSuspend; Pause }
            4 { $UserInput = "q"; Clear-Host; cmd }
            Default { }
        }
    }

    #Quit Execution cleanly without terminating parent/sibling cmd.exe processes
    exit 0
}
