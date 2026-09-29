# Based on a blog by Maxime Rastello
# https://www.maximerastello.com/manually-re-enroll-a-co-managed-or-hybrid-azure-ad-join-windows-10-pc-to-microsoft-intune-without-loosing-current-configuration/
#
# Steve Prentice, 2022
# This script will cleanup stalled Intune enrollment and remove the Configuration Manager client if installed. It will also schedule a restart in 60 minutes to complete the cleanup.
# Log will be available at C:\Temp\IntuneCleanUp\IntuneCleanUp.log

$logPath = 'C:\Temp\IntuneCleanUp\IntuneCleanUp.log'
$logDirectory = Split-Path -Parent $logPath

Try {
  New-Item -ItemType Directory -Path $logDirectory -Force -ErrorAction Stop | Out-Null
  If (-not (Test-Path -LiteralPath $logPath)) {
    New-Item -ItemType File -Path $logPath -ErrorAction Stop | Out-Null
  }
}
Catch {
  Write-Error "Unable to initialize the cleanup log at ${logPath}: $($_.Exception.Message)"
  Exit 1
}

Function Write-Log {
  Param(
    [Parameter(Mandatory = $true)][string]$Message,
    [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
  )

  $logEntry = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
  Add-Content -LiteralPath $logPath -Value $logEntry -Encoding UTF8 -ErrorAction Stop
}

Write-Log 'Cleanup script started.'

# Remove the Configuration Manager client if installed...
$ccmService = Get-Service -Name CcmExec -ErrorAction SilentlyContinue
$ccmRegistryPath = 'HKLM:\SOFTWARE\Microsoft\CCM'
$ccmRegistryKeyFound = Test-Path -LiteralPath $ccmRegistryPath
$ccmClientInstalled = $ccmService -or $ccmRegistryKeyFound
If ($ccmClientInstalled) {
  Write-Log "Configuration Manager client detected (CcmExec service: $([bool]$ccmService); registry key: $ccmRegistryKeyFound)."
  $ccmSetupPath = Join-Path $env:windir "CCMSetup\ccmsetup.exe"
  If (Test-Path -LiteralPath $ccmSetupPath) {
    Try {
      $ccmSetupProcess = Start-Process -FilePath $ccmSetupPath -ArgumentList "/uninstall" -Wait -PassThru -ErrorAction Stop
      If ($ccmSetupProcess.ExitCode -ne 0) {
        Write-Log "Configuration Manager client uninstall returned exit code $($ccmSetupProcess.ExitCode)." 'WARN'
      }
      Else {
        Write-Log "Configuration Manager client uninstall command completed with exit code 0."
      }
    }
    Catch {
      Write-Log "Failed to uninstall the Configuration Manager client: $($_.Exception.Message)" 'ERROR'
    }
  }
  Else {
    Write-Log "Configuration Manager client was detected, but ccmsetup.exe was not found at $ccmSetupPath." 'WARN'
  }
}
Else {
  Write-Log 'Configuration Manager client not found.'
}

# Find Intune CurrentEnrollmentId and remove enrollment if one exists...
Try {
  $enrollment = Get-ItemProperty HKLM:\SOFTWARE\Microsoft\Provisioning\OMADM\Logger CurrentEnrollmentId -ErrorAction Stop
  $enrollmentId = $enrollment.CurrentEnrollmentId
  Write-Log "Found current Intune enrollment ID: $enrollmentId."
}
Catch {
  $enrollment = $null
  Write-Log 'Current Intune enrollment ID not found.'
}

If ($enrollment) {
  $enrollmentId = $enrollment.CurrentEnrollmentId

  # Get Tasks and delete...
  $taskFolderPath = "\Microsoft\Windows\EnterpriseMgmt\$enrollmentId"
  Try {
    $scheduleObject = New-Object -ComObject Schedule.Service
    $scheduleObject.Connect()
    $taskFolder = $scheduleObject.GetFolder($taskFolderPath)
    $tasks = $taskFolder.GetTasks(1)
    Write-Log "Found $($tasks.Count) scheduled task(s) in $taskFolderPath."
    ForEach ($task in $tasks) {
      Try {
        $taskFolder.DeleteTask($task.Name, 0)
        Write-Log "Removed scheduled task '$($task.Name)'."
      }
      Catch {
        Write-Log "Failed to remove scheduled task '$($task.Name)': $($_.Exception.Message)" 'ERROR'
      }
    }
    Try {
      $rootFolder = $scheduleObject.GetFolder('\Microsoft\Windows\EnterpriseMgmt')
      $rootFolder.DeleteFolder($enrollmentId, 0)
      Write-Log "Removed scheduled task folder for enrollment $enrollmentId."
    }
    Catch {
      Write-Log "Failed to remove scheduled task folder for enrollment ${enrollmentId}: $($_.Exception.Message)" 'ERROR'
    }
  }
  Catch {
    Write-Log "Could not access scheduled tasks for enrollment ${enrollmentId}: $($_.Exception.Message)" 'WARN'
  }

  # Remove old registry keys...
  $registryPaths = @(
    "HKLM:\SOFTWARE\Microsoft\Enrollments\$enrollmentId",
    "HKLM:\SOFTWARE\Microsoft\Enrollments\Status\$enrollmentId",
    "HKLM:\SOFTWARE\Microsoft\EnterpriseResourceManager\Tracked\$enrollmentId",
    "HKLM:\SOFTWARE\Microsoft\PolicyManager\AdmxInstalled\$enrollmentId",
    "HKLM:\SOFTWARE\Microsoft\PolicyManager\Providers\$enrollmentId",
    "HKLM:\SOFTWARE\Microsoft\Provisioning\OMADM\Accounts\$enrollmentId",
    "HKLM:\SOFTWARE\Microsoft\Provisioning\OMADM\Logger\$enrollmentId",
    "HKLM:\SOFTWARE\Microsoft\Provisioning\OMADM\Sessions\$enrollmentId"
  )
  ForEach ($registryPath in $registryPaths) {
    If (Test-Path -LiteralPath $registryPath) {
      Try {
        Remove-Item -LiteralPath $registryPath -Recurse -Force -ErrorAction Stop
        Write-Log "Removed registry key $registryPath."
      }
      Catch {
        Write-Log "Failed to remove registry key ${registryPath}: $($_.Exception.Message)" 'ERROR'
      }
    }
    Else {
      Write-Log "Registry key not found: $registryPath."
    }
  }

  $loggerPath = 'HKLM:\SOFTWARE\Microsoft\Provisioning\OMADM\Logger'
  Try {
    Remove-ItemProperty -LiteralPath $loggerPath -Name CurrentEnrollmentId -Force -ErrorAction Stop
    Write-Log 'Removed CurrentEnrollmentId registry value.'
  }
  Catch {
    Write-Log "Failed to remove CurrentEnrollmentId registry value: $($_.Exception.Message)" 'ERROR'
  }

  # Remove old and new style Intune certificates...
  Try {
    $intuneCertificates = @(Get-ChildItem Cert:\LocalMachine\My\ -ErrorAction Stop | Where-Object {
      $_.Issuer -Match 'CN=Microsoft Intune MDM Device CA' -or $_.Issuer -Match 'CN=SC_Online_Issuing'
    })
    Write-Log "Found $($intuneCertificates.Count) matching Intune certificate(s) in LocalMachine\My."
    ForEach ($certificate in $intuneCertificates) {
      Try {
        Remove-Item -LiteralPath $certificate.PSPath -Force -ErrorAction Stop
        Write-Log "Removed Intune certificate $($certificate.Thumbprint) (issuer: $($certificate.Issuer))."
      }
      Catch {
        Write-Log "Failed to remove Intune certificate $($certificate.Thumbprint): $($_.Exception.Message)" 'ERROR'
      }
    }
  }
  Catch {
    Write-Log "Failed to enumerate Intune certificates: $($_.Exception.Message)" 'ERROR'
  }
}
Else {
  Write-Log 'No Intune enrollment ID found; enrollment tasks, registry keys, and certificates were not changed.'
}

$restartTaskName = 'IntuneCleanUp-GracefulRestart'
$restartTime = (Get-Date).AddMinutes(60)
$restartScheduled = $false

Try {
  $initialBootTimeTicks = [int64](Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime.Ticks
  $restartPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
  $restartSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
  $restartCommand = @'
$restartTaskName = '__RESTART_TASK__'
$reminderTaskName = 'IntuneCleanUp-RestartReminder'
$initialBootTimeTicks = [int64]__INITIAL_BOOT_TICKS__
$logPath = '__LOG_PATH__'
try {
  $currentBootTime = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime
}
catch {
  Disable-ScheduledTask -TaskName $restartTaskName -ErrorAction SilentlyContinue | Out-Null
  Disable-ScheduledTask -TaskName $reminderTaskName -ErrorAction SilentlyContinue | Out-Null
  Unregister-ScheduledTask -TaskName $reminderTaskName -Confirm:$false -ErrorAction SilentlyContinue
  $logEntry = "{0} [ERROR] Could not determine current boot time; pending restart tasks were disabled." -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
  Add-Content -LiteralPath $logPath -Value $logEntry -Encoding UTF8
  exit 1
}
if ($currentBootTime.Ticks -gt $initialBootTimeTicks) {
  Disable-ScheduledTask -TaskName $restartTaskName -ErrorAction SilentlyContinue | Out-Null
  Disable-ScheduledTask -TaskName $reminderTaskName -ErrorAction SilentlyContinue | Out-Null
  Unregister-ScheduledTask -TaskName $reminderTaskName -Confirm:$false -ErrorAction SilentlyContinue
  $logEntry = "{0} [INFO] Device restarted before the scheduled cleanup restart; pending restart was disabled and reminders removed." -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
  Add-Content -LiteralPath $logPath -Value $logEntry -Encoding UTF8
  exit 0
}
$logEntry = "{0} [INFO] Cleanup restart deadline reached; requesting a non-forced restart." -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Add-Content -LiteralPath $logPath -Value $logEntry -Encoding UTF8
& '__SHUTDOWN_EXE__' '/r' '/t' '0' '/d' 'p:2:4' '/c' 'Intune cleanup restart'
exit $LASTEXITCODE
'@
  $restartCommand = $restartCommand.Replace('__RESTART_TASK__', $restartTaskName)
  $restartCommand = $restartCommand.Replace('__INITIAL_BOOT_TICKS__', $initialBootTimeTicks.ToString())
  $restartCommand = $restartCommand.Replace('__LOG_PATH__', $logPath)
  $restartCommand = $restartCommand.Replace('__SHUTDOWN_EXE__', (Join-Path $env:windir 'System32\shutdown.exe'))
  $encodedRestartCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($restartCommand))
  $powershellPath = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $restartAction = New-ScheduledTaskAction -Execute $powershellPath -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand $encodedRestartCommand"
  $restartTriggers = @(
    (New-ScheduledTaskTrigger -Once -At $restartTime),
    (New-ScheduledTaskTrigger -AtStartup)
  )
  Register-ScheduledTask -TaskName $restartTaskName -Action $restartAction -Trigger $restartTriggers -Principal $restartPrincipal -Settings $restartSettings -Force -ErrorAction Stop | Out-Null
  $restartScheduled = $true
  Write-Log "Scheduled a graceful restart for $($restartTime.ToString('yyyy-MM-dd HH:mm:ss')) and an early-reboot cleanup trigger; applications may delay or block restart."
}
Catch {
  Write-Log "Failed to schedule the graceful restart: $($_.Exception.Message)" 'ERROR'
}

If ($restartScheduled) {
  $restartMessage = "This computer will restart in 60 minutes to complete important security update. Please save your work now and restart to avoid data loss."
  $messageArguments = "* /time:540 `"$restartMessage`""
  $msgExePath = Join-Path $env:windir 'System32\msg.exe'
  Try {
    $messageProcess = Start-Process -FilePath $msgExePath -ArgumentList $messageArguments -PassThru -ErrorAction Stop
    Write-Log "Restart warning popup process started (PID $($messageProcess.Id)); delivery depends on an interactive session."
  }
  Catch {
    Write-Log "Failed to display the restart warning popup: $($_.Exception.Message)" 'WARN'
  }

  Try {
    $reminderCommand = @'
$restartTime = [datetime]::ParseExact('__RESTART_TIME__', 'o', [Globalization.CultureInfo]::InvariantCulture)
$remainingMinutes = [Math]::Ceiling(($restartTime - (Get-Date)).TotalMinutes)
if ($remainingMinutes -gt 0) {
  $initialBootTimeTicks = [int64]__INITIAL_BOOT_TICKS__
  $currentBootTime = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime
  if ($currentBootTime.Ticks -gt $initialBootTimeTicks) {
    Disable-ScheduledTask -TaskName '__RESTART_TASK__' -ErrorAction SilentlyContinue | Out-Null
    Disable-ScheduledTask -TaskName 'IntuneCleanUp-RestartReminder' -ErrorAction SilentlyContinue | Out-Null
    Unregister-ScheduledTask -TaskName 'IntuneCleanUp-RestartReminder' -Confirm:$false -ErrorAction SilentlyContinue
    $logEntry = "{0} [INFO] Device restarted before the cleanup deadline; disabled pending restart and removed reminders." -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    Add-Content -LiteralPath '__LOG_PATH__' -Value $logEntry -Encoding UTF8
    exit 0
  }
  $message = "This computer will restart in $remainingMinutes minutes to complete important security update. Please save your work now and restart to avoid data loss."
  & '__MSG_EXE__' '*' '/time:540' $message
  $logEntry = "{0} [INFO] Restart reminder sent with {1} minute(s) remaining (msg.exe exit code {2})." -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $remainingMinutes, $LASTEXITCODE
  Add-Content -LiteralPath '__LOG_PATH__' -Value $logEntry -Encoding UTF8
}
'@
    $reminderCommand = $reminderCommand.Replace('__RESTART_TIME__', $restartTime.ToString('o'))
    $reminderCommand = $reminderCommand.Replace('__INITIAL_BOOT_TICKS__', $initialBootTimeTicks.ToString())
    $reminderCommand = $reminderCommand.Replace('__RESTART_TASK__', $restartTaskName)
    $reminderCommand = $reminderCommand.Replace('__MSG_EXE__', $msgExePath)
    $reminderCommand = $reminderCommand.Replace('__LOG_PATH__', $logPath)
    $encodedReminderCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($reminderCommand))
    $powershellPath = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $reminderAction = New-ScheduledTaskAction -Execute $powershellPath -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand $encodedReminderCommand"
    $reminderStartTime = (Get-Date).AddMinutes(10)
    $reminderTrigger = New-ScheduledTaskTrigger -Once -At $reminderStartTime -RepetitionInterval (New-TimeSpan -Minutes 10) -RepetitionDuration (New-TimeSpan -Minutes 49)
    Register-ScheduledTask -TaskName 'IntuneCleanUp-RestartReminder' -Action $reminderAction -Trigger $reminderTrigger -Principal $restartPrincipal -Settings $restartSettings -Force -ErrorAction Stop | Out-Null
    Write-Log 'Scheduled restart reminders every 10 minutes; each popup will report the remaining minutes until restart.'
  }
  Catch {
    Write-Log "Failed to schedule repeat restart reminders: $($_.Exception.Message)" 'WARN'
  }
}

Write-Log 'Cleanup script completed.'
