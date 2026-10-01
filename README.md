# powershell-scripts
In a hybrid environment there are multiple misterious states in which a Windows machine can live it's life but here we're interested in only one working state.
This PowerShell script will try to clear leftovers from previous enrollments and freshly enroll machine in Intune after forced restart.
It will:
    - Find previous stuck enrollment.
    - Delete respective reg key only and Intune certificate.
    - Log everything to C:\temp\IntuneCleanUp\IntuneCleanUp.log.
    - Initiate forced reboot within 60 minutes window and present restart dialog box to the logged user.

If WinRM service is running on a remote machine you can execute the script from your admin machine:
Invoke-Command -ComputerName COMPUTERNAME -FilePath C:\Temp\Remove-IntuneCurrentEnrollment.ps1 -SessionOption (New-PSSessionOption -nomachineprofile)

If WinRM is not running you can try to start it with :
sc.exe \\COMPUTERNAME start WinRM

