# Copyright 2016 Amazon.com, Inc. or its affiliates. All Rights Reserved.
#
# Licensed under the Amazon Software License (the "License").
# You may not use this file except in compliance with the License.
# A copy of the License is located at
#
# http://aws.amazon.com/asl/
#
# or in the "license" file accompanying this file. This file is distributed
# on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either
# express or implied. See the License for the specific language governing
# permissions and limitations under the License.

<#
.SYNOPSIS
        
    Initializes EC2 instance by configuring all required settings.

.DESCRIPTION
        
    During EC2 instance launch, it configures all required settings and displays information to console.

    0. Wait for sysprep: to ensure that sysprep process is finished.
    1. Add routes: to connect to instance metadata service and KMS service.
    2. Wait for metadata: to ensure that metadata is available to retrieve.
    3. Rename computer: to rename computer based on instance ip address.
    4. Display instance info: to inform user about your instance/AMI.
    5. Extend boot volume: to extend boot volume with unallocated spaces.
    6. Set password: to set password, so you can get password from console
    7. Windows is Ready: to display "Message: Windows is Ready to use" to console.
    8. Execute userdata: to execute userdata retrieved from metadata
    9. Register disabled scheduledTask: to keep the script as scheduledTask for future use.

    * By default, it always checks serial port setup.
    * If any task requires reboot, it re-regsiters the script as scheduledTask.
    * Userdata is executed after windows is ready because it is not required by default and can be a long running process.

.PARAMETER Schedule
        
    Provide this parameter to register script as scheduledtask and trigger it at startup. If you want to run script immediately, run it without this parameter.
        
.EXAMPLE

    ./InitializeInstance.ps1 -Schedule

#>

# Required for powershell to determine what parameter set to use when running with zero args (us a non existent set name)
[CmdletBinding(DefaultParameterSetName = 'Default')]
param (
    # Schedules the script to run on the next boot.
    # If this argument is not provided, script is executed immediately.
    [parameter(Mandatory = $false, ParameterSetName = "Schedule")]
    [switch] $Schedule = $false,
    # Schedules the script to run at every boot.
    # If this argument is not provided, script is executed immediately.
    [parameter(Mandatory = $false, ParameterSetName = "SchedulePerBoot")]
    [switch] $SchedulePerBoot = $false,
    # After the script executes, keeps the schedule instead of disabling it.
    [parameter(Mandatory = $false, ParameterSetName = "KeepSchedule")]
    [switch] $KeepSchedule = $false
)

Set-Variable rootPath -Option Constant -Scope Local -Value (Join-Path $env:ProgramData -ChildPath "Amazon\EC2-Windows\Launch")
Set-Variable modulePath -Option Constant -Scope Local -Value (Join-Path $rootPath -ChildPath "Module\Ec2Launch.psd1")
Set-Variable scriptPath -Option Constant -Scope Local -Value (Join-Path $PSScriptRoot -ChildPath $MyInvocation.MyCommand.Name)
Set-Variable scheduleName -Option Constant -Scope Local -Value "Instance Initialization"

Set-Variable amazonSSMagent -Option Constant -Scope Local -Value "AmazonSSMAgent"
Set-Variable ssmAgentTimeoutSeconds -Option Constant -Scope Local -Value 25
Set-Variable ssmAgentSleepSeconds -Option Constant -Scope Local -Value 5

# Import Ec2Launch module to prepare to use helper functions.
Import-Module $modulePath

# Before calling any function, initialize the log with filename and also allow LogToConsole. 
Initialize-Log -Filename "Ec2Launch.log" -AllowLogToConsole

if ($Schedule -or $SchedulePerBoot) {
    $arguments = $null
    if ($SchedulePerBoot) {
        # If a user wants to run on every reboot, the next invocation of InitializeInstance should not disable it's schedule
        $arguments = "-KeepSchedule"

        # Disable and user data schedule so that user data doesn't run twice on the next run (once in launch, another time in the external schedule)
        Invoke-Userdata -OnlyUnregister
    }

    # Scheduling script with no argument tells script to start normally.
    Register-ScriptScheduler -ScriptPath $scriptPath -ScheduleName $scheduleName -Arguments $arguments

    # Set AmazonSSMAgent StartupType to be Disabled to prevent AmazonSSMAgent from running util windows is ready.
    Set-Service $amazonSSMagent -StartupType Disabled -ErrorAction SilentlyContinue
    Write-Log "Instance initialization is scheduled successfully"
    Complete-Log
    Exit 0
}

try {
    Write-Log "Initializing instance is started"

    # Serial Port must be available in your instance to send logs to console. 
    # If serial port is not available, it sets the serial port and requests reboot. 
    # If serial port is already available, it continues without reboot.
    if ((Test-NanoServer) -and (Set-SerialPort)) {
        # Now Computer can restart.
        Write-Log "Message: Windows is restarting..." 
        Register-ScriptScheduler -ScriptPath $scriptPath -ScheduleName $scheduleName
        Restart-Computer
        Exit 0
    }

    # Serial port COM1 must be opened before executing any task.
    Open-SerialPort

    # Task must be executed after sysprep is complete.
    # WMI object seems to be missing during sysprep.
    Wait-Sysprep

    # Routes need to be added to connect to instance metadata service and KMS service.
    Add-Routes 
            
    # Once routes are added, we need to wait for metadata to be available 
    # becuase there are several tasks that need information from metadata.
    Wait-Metadata

    # Set KMS server and port in registry key.
    Set-ActivationSettings

    # Create wallpaper setup cmd file in windows startup directory, which
    # renders instance information on wallpaper as user logs in.
    New-WallpaperSetup

    # Installs EGPU for customers that request it
    Install-EgpuManager
    
    # Before renaming computer, it checks if computer is already renamed.
    # If computer is not renamed yet, it renames computer and requests reboot.
    # If computer is already renamed or failed to be renamed, it continues without reboot. 
    if (Set-ComputerName) {
        # Now Computer can restart.
        Write-Log "Message: Windows is restarting..." -LogToConsole
        Register-ScriptScheduler -ScriptPath $scriptPath -ScheduleName $scheduleName
        Close-SerialPort
        Restart-Computer
        Exit 0
    }

    # All of the instance information is displayed to console.
    Send-AMIInfo
    Send-OSInfo
    Send-IDInfo
    Send-InstanceInfo
    Send-MsSqlInfo
    Send-DriverInfo
    Send-Ec2LaunchVersion 
    Send-VSSVersion
    Send-SSMAgentVersion
    Send-RDPCertInfo
    Send-FeatureStatus
            
    # Add DNS suffixes in search list and store that in registry key. 
    Add-DnsSuffixList

    # The volume size is extended with unallocated spaces.
    Set-BootVolumeSize

    # Configure ENA Network settings 
    if (Set-ENAConfig) {
        # Now Computer can restart.
        Write-Log "Message: Windows is restarting..." -LogToConsole
        Register-ScriptScheduler -ScriptPath $scriptPath -ScheduleName $scheduleName
        Close-SerialPort
        Restart-Computer
        Exit 0
    }

    # If requested, sets the monitor to never turn off which will interfere with acpi signals
    Set-MonitorAlwaysOn
    # If requested, tells windows to go in to hibernate instead of sleep
    # when the system sends the acpi sleep signal.
    Set-HibernateOnSleep
        
    # Password is randomly generated and provided to console in encrypted format.
    # Here, also admin account gets enabled.
    $creds = Set-AdminAccount

    # Encrypt the admin credentials and send it to console.
    # Console understands the admin password and allows users to decrypt it with private key.
    if ($creds.Username -and $creds.Password) {
        Send-AdminCredentials -Username $creds.Username -Password $creds.Password
    }

    try {
        # Set AmazonSSMAgent StartupType to be back to Automatic
        Set-Service $amazonSSMagent -StartupType Automatic -ErrorAction Stop
    }
    catch {
        Write-Log ("Failed to set AmazonSSMAgent service to Automatic {0}" -f $_.Exception.Message)
    }

    # Windows-is-ready message is displayed to console after all steps above are complete.
    Send-WindowsIsReady

    # Disable the scheduledTask if we were only suppose to run once, otherwise, leave the schedule.
    if (!$KeepSchedule) {
        Register-ScriptScheduler -ScriptPath $scriptPath -ScheduleName $scheduleName -Disabled
    }
    
    # Serial port COM1 must be closed before ending.
    Close-SerialPort

    # If this run is from a "run on every boot" schedule, make sure we only execute user data (dont
    # schedule it as a separate task), this is so we can instead execute it inline on every boot.

    # Userdata can be executed now if user provided one before launching instance. Because 
    # userdata is not required by default and can be a long running process, it is not a 
    # part of windows-is-ready condition and executed after Send-WindowsIsReady.
    $persistUserData = Invoke-Userdata -Username $creds.Username -Password $creds.Password -OnlyExecute:$KeepSchedule
    
    try {
        # Start AmazonSSMAgent service.
        # Have to use closure argument list because the closure will be running in a sub-job that wont have access to local variables
        Invoke-WithTimeout -ScriptName $amazonSSMagent -ScriptBlock { Start-Service -Name $args[0] -ErrorAction Stop } -ArgumentList $amazonSSMagent -SleepSeconds $ssmAgentSleepSeconds -TimeoutSeconds $ssmAgentTimeoutSeconds
    }
    catch {
        Write-Log ("Failed to start AmazonSSMAgent service: {0}" -f $_.Exception.Message)
    }

    # If this run is from a "run on every boot" schedule, disable certain functionality for future runs.
    if ($KeepSchedule) {
        Get-LaunchConfig -Key AdminPasswordType -Delete
        Get-LaunchConfig -Key SetMonitorAlwaysOn -Delete

        # Only disable handle user data if persist was false
        if (!$persistUserData) {
            Get-LaunchConfig -Key HandleUserData -Delete
        }
    }

    Write-Log "Initializing instance is done"
    Exit 0
}
catch {
    Write-Log ("Failed to continue initializing the instance: {0}" -f $_.Exception.Message)

    # Serial port COM1 must be closed before ending.
    Close-SerialPort
    Exit 1
}
finally {
    # Before finishing the script, complete the log.
    Complete-Log
    
    # Clear the credentials from memory.
    if ($creds) {
        $creds.Clear()
    }
}

# SIG # Begin signature block
# MIIePAYJKoZIhvcNAQcCoIIeLTCCHikCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBBS2XSNKCe3GDR
# hJv8mG0/2MbOTr59PxyWmuVyutSFrKCCDJwwggXYMIIEwKADAgECAhABVznfx2xi
# Vuf0Y3KCrPFgMA0GCSqGSIb3DQEBCwUAMGwxCzAJBgNVBAYTAlVTMRUwEwYDVQQK
# EwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xKzApBgNV
# BAMTIkRpZ2lDZXJ0IEVWIENvZGUgU2lnbmluZyBDQSAoU0hBMikwHhcNMTcwNjAx
# MDAwMDAwWhcNMjAwNjA0MTIwMDAwWjCCAR0xHTAbBgNVBA8MFFByaXZhdGUgT3Jn
# YW5pemF0aW9uMRMwEQYLKwYBBAGCNzwCAQMTAlVTMRkwFwYLKwYBBAGCNzwCAQIT
# CERlbGF3YXJlMRAwDgYDVQQFEwc0MTUyOTU0MRgwFgYDVQQJEw80MTAgVGVycnkg
# QXZlIE4xDjAMBgNVBBETBTk4MTA5MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2Fz
# aGluZ3RvbjEQMA4GA1UEBxMHU2VhdHRsZTEiMCAGA1UEChMZQW1hem9uIFdlYiBT
# ZXJ2aWNlcywgSW5jLjEUMBIGA1UECxMLRUMyIFdpbmRvd3MxIjAgBgNVBAMTGUFt
# YXpvbiBXZWIgU2VydmljZXMsIEluYy4wggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAw
# ggEKAoIBAQDIcVfNSR3j5LoUqVUMtxS4NIJq/qOGQMGnTz95nmtpLOG8nv47GzUx
# zFkqnFmDxxjV9LUoMd5yZhVWyfEIMv7RsV0RhMZqJ/rutNfwt3r/4htqxDqiUHwN
# UKtqoHOw0Q2qSyKFbawCUbm/Bf3r/ya5ACbEz/abzCivvJsvQoRtflyfCemwF2Qu
# K8aw5c98Ab9xl0/ZJgd+966Bvxjf2VVKWf5pOuQKNo6ncZOU9gtgk8uV8h5yIttF
# sJP7KpN/hoXZC88EZXzjizSuLhutd7TEzBY56Lf9q0giZ+R8iiYQdenkKBGp75uv
# UqbJV+hjndohgKRZ8EnWQFVvVm2raAZTAgMBAAGjggHBMIIBvTAfBgNVHSMEGDAW
# gBSP6H7wbTJqAAUjx3CXajqQ/2vq1DAdBgNVHQ4EFgQUpJ202cGjSh7SNUwws5w6
# QmE9IYUwDgYDVR0PAQH/BAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMDMHsGA1Ud
# HwR0MHIwN6A1oDOGMWh0dHA6Ly9jcmwzLmRpZ2ljZXJ0LmNvbS9FVkNvZGVTaWdu
# aW5nU0hBMi1nMS5jcmwwN6A1oDOGMWh0dHA6Ly9jcmw0LmRpZ2ljZXJ0LmNvbS9F
# VkNvZGVTaWduaW5nU0hBMi1nMS5jcmwwSwYDVR0gBEQwQjA3BglghkgBhv1sAwIw
# KjAoBggrBgEFBQcCARYcaHR0cHM6Ly93d3cuZGlnaWNlcnQuY29tL0NQUzAHBgVn
# gQwBAzB+BggrBgEFBQcBAQRyMHAwJAYIKwYBBQUHMAGGGGh0dHA6Ly9vY3NwLmRp
# Z2ljZXJ0LmNvbTBIBggrBgEFBQcwAoY8aHR0cDovL2NhY2VydHMuZGlnaWNlcnQu
# Y29tL0RpZ2lDZXJ0RVZDb2RlU2lnbmluZ0NBLVNIQTIuY3J0MAwGA1UdEwEB/wQC
# MAAwDQYJKoZIhvcNAQELBQADggEBAATn4LxNeqlebC8j+gebBiwGYYbc8mM+5NUp
# me5SdJHXsOQptpl9jnZFboEVDltnxfHEMtebLGqX5kz7weqt5HpWatcjvMTTbZrq
# OMTVvsrNgcSjJ/VZoaWqmFsu4uHuwHXCHyqFUA5BxSqJrMjLLYNh5SE/Z8jQ2BAY
# nZhahetnz7Od2IoJzNgRqSHM/OXsZrTKsxv+o8qPqUKwhu+5HFHS+fXXvv5iZ9MO
# LcKTPZYecojbgdZCk+qCYuhyThSR3AUdlRAHHnJyMckNUitEiRNQtxXZ8Su1yBF5
# BExMdUEFAGCHyXq3zUg5g+6Ou53VYmGMJNTIDh77kp10b8usIB4wgga8MIIFpKAD
# AgECAhAD8bThXzqC8RSWeLPX2EdcMA0GCSqGSIb3DQEBCwUAMGwxCzAJBgNVBAYT
# AlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2Vy
# dC5jb20xKzApBgNVBAMTIkRpZ2lDZXJ0IEhpZ2ggQXNzdXJhbmNlIEVWIFJvb3Qg
# Q0EwHhcNMTIwNDE4MTIwMDAwWhcNMjcwNDE4MTIwMDAwWjBsMQswCQYDVQQGEwJV
# UzEVMBMGA1UEChMMRGlnaUNlcnQgSW5jMRkwFwYDVQQLExB3d3cuZGlnaWNlcnQu
# Y29tMSswKQYDVQQDEyJEaWdpQ2VydCBFViBDb2RlIFNpZ25pbmcgQ0EgKFNIQTIp
# MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAp1P6D7K1E/Fkz4SA/K6A
# NdG218ejLKwaLKzxhKw6NRI6kpG6V+TEyfMvqEg8t9Zu3JciulF5Ya9DLw23m7RJ
# Ma5EWD6koZanh08jfsNsZSSQVT6hyiN8xULpxHpiRZt93mN0y55jJfiEmpqtRU+u
# fR/IE8t1m8nh4Yr4CwyY9Mo+0EWqeh6lWJM2NL4rLisxWGa0MhCfnfBSoe/oPtN2
# 8kBa3PpqPRtLrXawjFzuNrqD6jCoTN7xCypYQYiuAImrA9EWgiAiduteVDgSYuHS
# cCTb7R9w0mQJgC3itp3OH/K7IfNs29izGXuKUJ/v7DYKXJq3StMIoDl5/d2/PToJ
# JQIDAQABo4IDWDCCA1QwEgYDVR0TAQH/BAgwBgEB/wIBADAOBgNVHQ8BAf8EBAMC
# AYYwEwYDVR0lBAwwCgYIKwYBBQUHAwMwfwYIKwYBBQUHAQEEczBxMCQGCCsGAQUF
# BzABhhhodHRwOi8vb2NzcC5kaWdpY2VydC5jb20wSQYIKwYBBQUHMAKGPWh0dHA6
# Ly9jYWNlcnRzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydEhpZ2hBc3N1cmFuY2VFVlJv
# b3RDQS5jcnQwgY8GA1UdHwSBhzCBhDBAoD6gPIY6aHR0cDovL2NybDMuZGlnaWNl
# cnQuY29tL0RpZ2lDZXJ0SGlnaEFzc3VyYW5jZUVWUm9vdENBLmNybDBAoD6gPIY6
# aHR0cDovL2NybDQuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0SGlnaEFzc3VyYW5jZUVW
# Um9vdENBLmNybDCCAcQGA1UdIASCAbswggG3MIIBswYJYIZIAYb9bAMCMIIBpDA6
# BggrBgEFBQcCARYuaHR0cDovL3d3dy5kaWdpY2VydC5jb20vc3NsLWNwcy1yZXBv
# c2l0b3J5Lmh0bTCCAWQGCCsGAQUFBwICMIIBVh6CAVIAQQBuAHkAIAB1AHMAZQAg
# AG8AZgAgAHQAaABpAHMAIABDAGUAcgB0AGkAZgBpAGMAYQB0AGUAIABjAG8AbgBz
# AHQAaQB0AHUAdABlAHMAIABhAGMAYwBlAHAAdABhAG4AYwBlACAAbwBmACAAdABo
# AGUAIABEAGkAZwBpAEMAZQByAHQAIABDAFAALwBDAFAAUwAgAGEAbgBkACAAdABo
# AGUAIABSAGUAbAB5AGkAbgBnACAAUABhAHIAdAB5ACAAQQBnAHIAZQBlAG0AZQBu
# AHQAIAB3AGgAaQBjAGgAIABsAGkAbQBpAHQAIABsAGkAYQBiAGkAbABpAHQAeQAg
# AGEAbgBkACAAYQByAGUAIABpAG4AYwBvAHIAcABvAHIAYQB0AGUAZAAgAGgAZQBy
# AGUAaQBuACAAYgB5ACAAcgBlAGYAZQByAGUAbgBjAGUALjAdBgNVHQ4EFgQUj+h+
# 8G0yagAFI8dwl2o6kP9r6tQwHwYDVR0jBBgwFoAUsT7DaQP4v0cB1JgmGggC72Nk
# K8MwDQYJKoZIhvcNAQELBQADggEBABkzSgyBMzfbrTbJ5Mk6u7UbLnqi4vRDQhee
# v06hTeGx2+mB3Z8B8uSI1en+Cf0hwexdgNLw1sFDwv53K9v515EzzmzVshk75i7W
# yZNPiECOzeH1fvEPxllWcujrakG9HNVG1XxJymY4FcG/4JFwd4fcyY0xyQwpojPt
# jeKHzYmNPxv/1eAal4t82m37qMayOmZrewGzzdimNOwSAauVWKXEU1eoYObnAhKg
# uSNkok27fIElZCG+z+5CGEOXu6U3Bq9N/yalTWFL7EZBuGXOuHmeCJYLgYyKO4/H
# mYyjKm6YbV5hxpa3irlhLZO46w4EQ9f1/qbwYtSZaqXBwfBklIAxghD2MIIQ8gIB
# ATCBgDBsMQswCQYDVQQGEwJVUzEVMBMGA1UEChMMRGlnaUNlcnQgSW5jMRkwFwYD
# VQQLExB3d3cuZGlnaWNlcnQuY29tMSswKQYDVQQDEyJEaWdpQ2VydCBFViBDb2Rl
# IFNpZ25pbmcgQ0EgKFNIQTIpAhABVznfx2xiVuf0Y3KCrPFgMA0GCWCGSAFlAwQC
# AQUAoHwwEAYKKwYBBAGCNwIBDDECMAAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcC
# AQQwHAYKKwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIE
# IF9lfyRFP0Oj9VSg2PKn6XUZpIhwWMtQnj3dyHCLMAOaMA0GCSqGSIb3DQEBAQUA
# BIIBAFOmVBm87RGLqlu2muER/dvmeIK+eEmoew+8yloKa6VMGSxJLZ8FgIsxd23H
# /2RVSqdMSsGrkzE2un50ArT2BE4DLvS1crVWa4HDEhJw/2n6j9x1+D6UYRPNEVDE
# sNrjYlaEIE02l/9IQ8s4CauTFPLBlzL1PNHK3ogqGCVBRw7s7omBn31Nyeoo1W1W
# Er6iYX/DIpLrJ5Ct+0uB0H7tEoVcwDbMY940oH3CK+TRGjzpxbUtWNQgTI526Xqq
# 0UC8NG8eXgW/SiFB0TMdFpnw1tm67GWa1sqmU0q4chpjGS3UILbkkRdfhFpvo3Sq
# 1txdXdZTvSMxnELEYxmiscdy2kShgg7IMIIOxAYKKwYBBAGCNwMDATGCDrQwgg6w
# BgkqhkiG9w0BBwKggg6hMIIOnQIBAzEPMA0GCWCGSAFlAwQCAQUAMHcGCyqGSIb3
# DQEJEAEEoGgEZjBkAgEBBglghkgBhv1sBwEwMTANBglghkgBZQMEAgEFAAQg11dg
# m7BrReTxfAplVulPCsKJu2uG1u/gr6prCz++JlACEClw9pf3rbNckP1xzH6CaZUY
# DzIwMTkwMjIxMjEyNTIzWqCCC7swggaCMIIFaqADAgECAhAJwPxGyARCE7VZi68o
# T05BMA0GCSqGSIb3DQEBCwUAMHIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdp
# Q2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xMTAvBgNVBAMTKERp
# Z2lDZXJ0IFNIQTIgQXNzdXJlZCBJRCBUaW1lc3RhbXBpbmcgQ0EwHhcNMTcwMTA0
# MDAwMDAwWhcNMjgwMTE4MDAwMDAwWjBMMQswCQYDVQQGEwJVUzERMA8GA1UEChMI
# RGlnaUNlcnQxKjAoBgNVBAMTIURpZ2lDZXJ0IFNIQTIgVGltZXN0YW1wIFJlc3Bv
# bmRlcjCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAJ6VmGo0O3MbqH78
# x74paYnHaCZGXz2NYnOHgaOhnPC3WyQ3WpLU9FnXdonk3NUn8NVmvArutCsxZ6xY
# xUqRWStFHgkB1mSzWe6NZk37I17MEA0LimfvUq6gCJDCUvf1qLVumyx7nee1Pvt4
# zTJQGL9AtUyMu1f0oE8RRWxCQrnlr9bf9Kd8CmiWD9JfKVfO+x0y//QRoRMi+xLL
# 79dT0uuXy6KsGx2dWCFRgsLC3uorPywihNBD7Ds7P0fE9lbcRTeYtGt0tVmveFdp
# yA8JAnjd2FPBmdtgxJ3qrq/gfoZKXKlYYahedIoBKGhyTqeGnbUCUodwZkjTju+B
# JMzc2GUCAwEAAaOCAzgwggM0MA4GA1UdDwEB/wQEAwIHgDAMBgNVHRMBAf8EAjAA
# MBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMIMIIBvwYDVR0gBIIBtjCCAbIwggGhBglg
# hkgBhv1sBwEwggGSMCgGCCsGAQUFBwIBFhxodHRwczovL3d3dy5kaWdpY2VydC5j
# b20vQ1BTMIIBZAYIKwYBBQUHAgIwggFWHoIBUgBBAG4AeQAgAHUAcwBlACAAbwBm
# ACAAdABoAGkAcwAgAEMAZQByAHQAaQBmAGkAYwBhAHQAZQAgAGMAbwBuAHMAdABp
# AHQAdQB0AGUAcwAgAGEAYwBjAGUAcAB0AGEAbgBjAGUAIABvAGYAIAB0AGgAZQAg
# AEQAaQBnAGkAQwBlAHIAdAAgAEMAUAAvAEMAUABTACAAYQBuAGQAIAB0AGgAZQAg
# AFIAZQBsAHkAaQBuAGcAIABQAGEAcgB0AHkAIABBAGcAcgBlAGUAbQBlAG4AdAAg
# AHcAaABpAGMAaAAgAGwAaQBtAGkAdAAgAGwAaQBhAGIAaQBsAGkAdAB5ACAAYQBu
# AGQAIABhAHIAZQAgAGkAbgBjAG8AcgBwAG8AcgBhAHQAZQBkACAAaABlAHIAZQBp
# AG4AIABiAHkAIAByAGUAZgBlAHIAZQBuAGMAZQAuMAsGCWCGSAGG/WwDFTAfBgNV
# HSMEGDAWgBT0tuEgHf4prtLkYaWyoiWyyBc1bjAdBgNVHQ4EFgQU4acySu4BISh9
# VNXyB5JutAcPPYcwcQYDVR0fBGowaDAyoDCgLoYsaHR0cDovL2NybDMuZGlnaWNl
# cnQuY29tL3NoYTItYXNzdXJlZC10cy5jcmwwMqAwoC6GLGh0dHA6Ly9jcmw0LmRp
# Z2ljZXJ0LmNvbS9zaGEyLWFzc3VyZWQtdHMuY3JsMIGFBggrBgEFBQcBAQR5MHcw
# JAYIKwYBBQUHMAGGGGh0dHA6Ly9vY3NwLmRpZ2ljZXJ0LmNvbTBPBggrBgEFBQcw
# AoZDaHR0cDovL2NhY2VydHMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0U0hBMkFzc3Vy
# ZWRJRFRpbWVzdGFtcGluZ0NBLmNydDANBgkqhkiG9w0BAQsFAAOCAQEAHvBBgjKu
# 7fG0NRPcUMLVl64iIp0ODq8z00z9fL9vARGnlGUiXMYiociJUmuajHNc2V4/Mt4W
# YEyLNv0xmQq9wYS3jR3viSYTBVbzR81HW62EsjivaiO1ReMeiDJGgNK3ppki/cF4
# z/WL2AyMBQnuROaA1W1wzJ9THifdKkje2pNlrW5lo5mnwkAOc8xYT49FKOW8nIjm
# KM5gXS0lXYtzLqUNW1Hamk7/UAWJKNryeLvSWHiNRKesOgCReGmJZATTXZbfKr/5
# pUwsk//mit2CrPHSs6KGmsFViVZqRz/61jOVQzWJBXhaOmnaIrgEQ9NvaDU2ehQ+
# RemYZIYPEwwmSjCCBTEwggQZoAMCAQICEAqhJdbWMht+QeQF2jaXwhUwDQYJKoZI
# hvcNAQELBQAwZTELMAkGA1UEBhMCVVMxFTATBgNVBAoTDERpZ2lDZXJ0IEluYzEZ
# MBcGA1UECxMQd3d3LmRpZ2ljZXJ0LmNvbTEkMCIGA1UEAxMbRGlnaUNlcnQgQXNz
# dXJlZCBJRCBSb290IENBMB4XDTE2MDEwNzEyMDAwMFoXDTMxMDEwNzEyMDAwMFow
# cjELMAkGA1UEBhMCVVMxFTATBgNVBAoTDERpZ2lDZXJ0IEluYzEZMBcGA1UECxMQ
# d3d3LmRpZ2ljZXJ0LmNvbTExMC8GA1UEAxMoRGlnaUNlcnQgU0hBMiBBc3N1cmVk
# IElEIFRpbWVzdGFtcGluZyBDQTCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoC
# ggEBAL3QMu5LzY9/3am6gpnFOVQoV7YjSsQOB0UzURB90Pl9TWh+57ag9I2ziOSX
# v2MhkJi/E7xX08PhfgjWahQAOPcuHjvuzKb2Mln+X2U/4Jvr40ZHBhpVfgsnfsCi
# 9aDg3iI/Dv9+lfvzo7oiPhisEeTwmQNtO4V8CdPuXciaC1TjqAlxa+DPIhAPdc9x
# ck4Krd9AOly3UeGheRTGTSQjMF287DxgaqwvB8z98OpH2YhQXv1mblZhJymJhFHm
# gudGUP2UKiyn5HU+upgPhH+fMRTWrdXyZMt7HgXQhBlyF/EXBu89zdZN7wZC/aJT
# Kk+FHcQdPK/P2qwQ9d2srOlW/5MCAwEAAaOCAc4wggHKMB0GA1UdDgQWBBT0tuEg
# Hf4prtLkYaWyoiWyyBc1bjAfBgNVHSMEGDAWgBRF66Kv9JLLgjEtUYunpyGd823I
# DzASBgNVHRMBAf8ECDAGAQH/AgEAMA4GA1UdDwEB/wQEAwIBhjATBgNVHSUEDDAK
# BggrBgEFBQcDCDB5BggrBgEFBQcBAQRtMGswJAYIKwYBBQUHMAGGGGh0dHA6Ly9v
# Y3NwLmRpZ2ljZXJ0LmNvbTBDBggrBgEFBQcwAoY3aHR0cDovL2NhY2VydHMuZGln
# aWNlcnQuY29tL0RpZ2lDZXJ0QXNzdXJlZElEUm9vdENBLmNydDCBgQYDVR0fBHow
# eDA6oDigNoY0aHR0cDovL2NybDQuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0QXNzdXJl
# ZElEUm9vdENBLmNybDA6oDigNoY0aHR0cDovL2NybDMuZGlnaWNlcnQuY29tL0Rp
# Z2lDZXJ0QXNzdXJlZElEUm9vdENBLmNybDBQBgNVHSAESTBHMDgGCmCGSAGG/WwA
# AgQwKjAoBggrBgEFBQcCARYcaHR0cHM6Ly93d3cuZGlnaWNlcnQuY29tL0NQUzAL
# BglghkgBhv1sBwEwDQYJKoZIhvcNAQELBQADggEBAHGVEulRh1Zpze/d2nyqY3qz
# eM8GN0CE70uEv8rPAwL9xafDDiBCLK938ysfDCFaKrcFNB1qrpn4J6JmvwmqYN92
# pDqTD/iy0dh8GWLoXoIlHsS6HHssIeLWWywUNUMEaLLbdQLgcseY1jxk5R9IEBhf
# iThhTWJGJIdjjJFSLK8pieV4H9YLFKWA1xJHcLN11ZOFk362kmf7U2GJqPVrlsD0
# WGkNfMgBsbkodbeZY4UijGHKeZR+WfyMD+NvtQEmtmyl7odRIeRYYJu6DC0rbaLE
# frvEJStHAgh8Sa4TtuF8QkIoxhhWz0E0tmZdtnR79VYzIi8iNrJLokqV2PWmjlIx
# ggJNMIICSQIBATCBhjByMQswCQYDVQQGEwJVUzEVMBMGA1UEChMMRGlnaUNlcnQg
# SW5jMRkwFwYDVQQLExB3d3cuZGlnaWNlcnQuY29tMTEwLwYDVQQDEyhEaWdpQ2Vy
# dCBTSEEyIEFzc3VyZWQgSUQgVGltZXN0YW1waW5nIENBAhAJwPxGyARCE7VZi68o
# T05BMA0GCWCGSAFlAwQCAQUAoIGYMBoGCSqGSIb3DQEJAzENBgsqhkiG9w0BCRAB
# BDAcBgkqhkiG9w0BCQUxDxcNMTkwMjIxMjEyNTIzWjArBgsqhkiG9w0BCRACDDEc
# MBowGDAWBBRAAZFHXJiJHeuhBK9HCRtettTLyzAvBgkqhkiG9w0BCQQxIgQgIZO3
# cz+GzALSgsQ5MQjbbAeXGUxGe8x41lN6DTg3XYIwDQYJKoZIhvcNAQEBBQAEggEA
# cYxUxdzljhhKRJmFMFneiFXf3gmVpzUzu/16Zzi5l5NDm1trlpBHucRwlRTln3uK
# Dy+PmL6uNeS9jDv08JQW/m7FKBZd3E+DRyZNw5rufbtwWgndtkqjuNLDxTZSJcma
# GxyBYnBLNq9rtjRf+bIKSG9fmsR2erznUHR0chtwzpzoAPYR8LQIwW6Hr5R2WRMi
# aytHzbI3r5Id631kckCHD+9EFkQGB3IArrugM+CUz1u92a9e+zw8tYZrBtDsZP2/
# bvB0TY0VduNMn7SXbhk5FgWl178UkncB8wVt2gQRMTLhp6f6YQTZ7YFuj1odBvyb
# HpCNni1e9OCfRDZyCDVcBA==
# SIG # End signature block
