# Based on a blog by Maxime Rastello
# https://www.maximerastello.com/manually-re-enroll-a-co-managed-or-hybrid-azure-ad-join-windows-10-pc-to-microsoft-intune-without-loosing-current-configuration/
#
# Steve Prentice, 2022

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

Write-Log 'Cleanup script completed.'
