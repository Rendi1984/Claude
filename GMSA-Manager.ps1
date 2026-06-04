#Requires -Version 5.1
<#
.SYNOPSIS
    GMSA Manager - Active Directory Group Managed Service Account Automation
.DESCRIPTION
    PowerShell WinForms GUI for full GMSA lifecycle management:
    creation on domain controllers and installation on client machines,
    with both local and remote execution modes.
.NOTES
    Run as Administrator on a domain-joined machine with RSAT installed.
#>

#region Section 1: Assembly Loads & Namespace Imports
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)
#endregion

#region Section 2: Global State & Constants
$Script:ExecutionMode   = 'Local'
$Script:RemoteTarget    = $null
$Script:RemoteCred      = $null
$Script:VerboseLogging  = $false
$Script:AutoScroll      = $true
$Script:KDSCheckPassed  = $false

$Script:Colors = @{
    FormBack     = [System.Drawing.Color]::FromArgb(240, 240, 245)
    GroupBack    = [System.Drawing.Color]::FromArgb(250, 250, 255)
    LogBack      = [System.Drawing.Color]::FromArgb(15, 15, 20)
    Primary      = [System.Drawing.Color]::FromArgb(0, 120, 212)
    Danger       = [System.Drawing.Color]::FromArgb(196, 43, 28)
    Success      = [System.Drawing.Color]::LimeGreen
    Warning      = [System.Drawing.Color]::Goldenrod
    Error        = [System.Drawing.Color]::OrangeRed
    Info         = [System.Drawing.Color]::LightGray
    Verbose      = [System.Drawing.Color]::DimGray
}
#endregion

#region Section 3: Utility / Helper Functions

function Test-IsAdmin {
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-FormCredential {
    param(
        [string]$Username,
        [System.Windows.Forms.MaskedTextBox]$PasswordBox
    )
    if ([string]::IsNullOrWhiteSpace($Username) -or [string]::IsNullOrWhiteSpace($PasswordBox.Text)) {
        return $null
    }
    try {
        $securePass = ConvertTo-SecureString $PasswordBox.Text -AsPlainText -Force
        $PasswordBox.Text = ""
        return New-Object System.Management.Automation.PSCredential($Username, $securePass)
    } catch {
        $PasswordBox.Text = ""
        return $null
    }
}

function Test-GMSANameValid {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return "Account name is required." }
    if ($Name.Length -gt 15) { return "Name cannot exceed 15 characters (got $($Name.Length))." }
    if ($Name -notmatch '^[a-zA-Z0-9\-]+$') { return "Name must contain only letters, numbers, and hyphens." }
    return $null
}

function Test-OUPathValid {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    if ($Path -notmatch '^(OU=|CN=|DC=)') { return "OU Path must be in DN format (e.g. OU=ServiceAccounts,DC=contoso,DC=com)." }
    return $null
}

function Get-CurrentDomainFQDN {
    try {
        return [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().Name
    } catch {
        return $null
    }
}

function Show-ErrorBox {
    param([string]$Message, [string]$Title = "Error")
    [System.Windows.Forms.MessageBox]::Show($Message, $Title,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
}

function Show-InfoBox {
    param([string]$Message, [string]$Title = "Information")
    [System.Windows.Forms.MessageBox]::Show($Message, $Title,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
}

function Show-ConfirmBox {
    param([string]$Message, [string]$Title = "Confirm")
    $result = [System.Windows.Forms.MessageBox]::Show($Message, $Title,
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning)
    return ($result -eq [System.Windows.Forms.DialogResult]::Yes)
}
#endregion

#region Section 4: Prerequisites Check Functions

function Test-ADModuleAvailable {
    try {
        $mod = Get-Module -ListAvailable -Name ActiveDirectory -ErrorAction Stop
        if (-not $mod) {
            return [PSCustomObject]@{ Passed = $false; Message = "ActiveDirectory module not found. Install RSAT." }
        }
        Import-Module ActiveDirectory -ErrorAction Stop
        return [PSCustomObject]@{ Passed = $true; Message = "ActiveDirectory module loaded (v$($mod[0].Version))." }
    } catch {
        return [PSCustomObject]@{ Passed = $false; Message = "Failed to load AD module: $($_.Exception.Message)" }
    }
}

function Test-KDSRootKey {
    param(
        [string]$RemoteDC,
        [System.Management.Automation.PSCredential]$Credential
    )
    $kdsBlock = {
        try {
            Import-Module ActiveDirectory -ErrorAction Stop
            $keys = Get-KdsRootKey -ErrorAction Stop
            if ($keys) {
                return [PSCustomObject]@{ Passed = $true; Message = "KDS Root Key found (created: $($keys[0].CreationTime))." }
            } else {
                return [PSCustomObject]@{ Passed = $false; Message = "No KDS Root Key found. Must create one before GMSA." }
            }
        } catch {
            return [PSCustomObject]@{ Passed = $false; Message = "Error checking KDS: $($_.Exception.Message)" }
        }
    }
    try {
        if ($Script:ExecutionMode -eq 'Remote' -and $RemoteDC) {
            $result = Invoke-Command -ComputerName $RemoteDC -Credential $Credential -ScriptBlock $kdsBlock -ErrorAction Stop
        } else {
            $result = & $kdsBlock
        }
        return $result
    } catch {
        return [PSCustomObject]@{ Passed = $false; Message = "Remote KDS check failed: $($_.Exception.Message)" }
    }
}

function Test-DomainConnectivity {
    try {
        $domain = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()
        $pdc = $domain.PdcRoleOwner.Name
        return [PSCustomObject]@{ Passed = $true; Message = "Domain: $($domain.Name) | PDC: $pdc" }
    } catch {
        return [PSCustomObject]@{ Passed = $false; Message = "Cannot reach domain: $($_.Exception.Message)" }
    }
}

function Test-AdminPrivileges {
    $isAdmin = Test-IsAdmin
    if ($isAdmin) {
        return [PSCustomObject]@{ Passed = $true; Message = "Running as Administrator." }
    } else {
        return [PSCustomObject]@{ Passed = $false; Message = "Not running as Administrator. Restart with elevated privileges." }
    }
}

function Invoke-CreateKDSRootKey {
    param(
        [bool]$EffectiveImmediately,
        [string]$RemoteDC,
        [System.Management.Automation.PSCredential]$Credential
    )
    $kdsCreateBlock = {
        param($Immediate)
        Import-Module ActiveDirectory -ErrorAction Stop
        if ($Immediate) {
            Add-KdsRootKey -EffectiveImmediately -ErrorAction Stop
        } else {
            Add-KdsRootKey -EffectiveTime (Get-Date).AddHours(10) -ErrorAction Stop
        }
        return [PSCustomObject]@{ Success = $true; Message = "KDS Root Key created successfully." }
    }
    try {
        if ($Script:ExecutionMode -eq 'Remote' -and $RemoteDC) {
            return Invoke-Command -ComputerName $RemoteDC -Credential $Credential `
                -ScriptBlock $kdsCreateBlock -ArgumentList $EffectiveImmediately -ErrorAction Stop
        } else {
            return & $kdsCreateBlock -Immediate $EffectiveImmediately
        }
    } catch {
        return [PSCustomObject]@{ Success = $false; Message = "Failed to create KDS Root Key: $($_.Exception.Message)" }
    }
}
#endregion

#region Section 5: GMSA Creation Functions

function New-GMSAAccount {
    param(
        [string]$Name,
        [string]$DNSSuffix,
        [string]$Description,
        [int]$PasswordIntervalDays,
        [string]$OUPath,
        [string[]]$AllowedPrincipals,
        [string[]]$SPNList,
        [string]$RemoteDC,
        [System.Management.Automation.PSCredential]$Credential
    )
    $createBlock = {
        param($Name, $DNSSuffix, $Description, $PasswordIntervalDays, $OUPath, $AllowedPrincipals, $SPNList)
        try {
            Import-Module ActiveDirectory -ErrorAction Stop
            $dnsHostName = "$Name.$DNSSuffix"
            $params = @{
                Name                                 = $Name
                DNSHostName                          = $dnsHostName
                ManagedPasswordIntervalInDays        = $PasswordIntervalDays
                Enabled                              = $true
                ErrorAction                          = 'Stop'
            }
            if ($Description) { $params['Description'] = $Description }
            if ($OUPath)      { $params['Path'] = $OUPath }

            if ($AllowedPrincipals -and $AllowedPrincipals.Count -gt 0) {
                $principalObjects = @()
                foreach ($p in $AllowedPrincipals) {
                    try {
                        $obj = Get-ADComputer -Identity $p -ErrorAction Stop
                        $principalObjects += $obj
                    } catch {
                        try {
                            $obj = Get-ADGroup -Identity $p -ErrorAction Stop
                            $principalObjects += $obj
                        } catch {
                            return [PSCustomObject]@{ Success = $false; Message = "Principal '$p' not found as Computer or Group in AD." }
                        }
                    }
                }
                $params['PrincipalsAllowedToRetrieveManagedPassword'] = $principalObjects
            }

            if ($SPNList -and $SPNList.Count -gt 0) {
                $params['ServicePrincipalNames'] = $SPNList
            }

            New-ADServiceAccount @params
            return [PSCustomObject]@{ Success = $true; Message = "GMSA '$Name' created successfully. DNS: $dnsHostName" }
        } catch [Microsoft.ActiveDirectory.Management.ADIdentityAlreadyExistsException] {
            return [PSCustomObject]@{ Success = $false; Message = "Account '$Name' already exists in AD." }
        } catch [Microsoft.ActiveDirectory.Management.ADException] {
            return [PSCustomObject]@{ Success = $false; Message = "AD error: $($_.Exception.Message)" }
        } catch {
            return [PSCustomObject]@{ Success = $false; Message = "Unexpected error: $($_.Exception.Message)" }
        }
    }
    try {
        if ($Script:ExecutionMode -eq 'Remote' -and $RemoteDC) {
            return Invoke-Command -ComputerName $RemoteDC -Credential $Credential `
                -ScriptBlock $createBlock `
                -ArgumentList $Name, $DNSSuffix, $Description, $PasswordIntervalDays, $OUPath, $AllowedPrincipals, $SPNList `
                -ErrorAction Stop
        } else {
            return & $createBlock -Name $Name -DNSSuffix $DNSSuffix -Description $Description `
                -PasswordIntervalDays $PasswordIntervalDays -OUPath $OUPath `
                -AllowedPrincipals $AllowedPrincipals -SPNList $SPNList
        }
    } catch {
        return [PSCustomObject]@{ Success = $false; Message = "Remote execution failed: $($_.Exception.Message)" }
    }
}

function Get-GMSAStatus {
    param(
        [string]$Name,
        [string]$RemoteDC,
        [System.Management.Automation.PSCredential]$Credential
    )
    $statusBlock = {
        param($AccountName)
        try {
            Import-Module ActiveDirectory -ErrorAction Stop
            $acct = Get-ADServiceAccount -Identity $AccountName -Properties * -ErrorAction Stop
            return [PSCustomObject]@{
                Success              = $true
                Name                 = $acct.Name
                DNSHostName          = $acct.DNSHostName
                Enabled              = $acct.Enabled
                Created              = $acct.Created
                PasswordLastSet      = $acct.PasswordLastSet
                DistinguishedName    = $acct.DistinguishedName
                AllowedPrincipals    = ($acct.PrincipalsAllowedToRetrieveManagedPassword | ForEach-Object { $_.Split(',')[0].Replace('CN=','').Replace('DC=','') }) -join ', '
                SPNs                 = ($acct.ServicePrincipalNames -join ', ')
            }
        } catch {
            return [PSCustomObject]@{ Success = $false; Message = "Cannot find GMSA '$AccountName': $($_.Exception.Message)" }
        }
    }
    try {
        if ($Script:ExecutionMode -eq 'Remote' -and $RemoteDC) {
            return Invoke-Command -ComputerName $RemoteDC -Credential $Credential `
                -ScriptBlock $statusBlock -ArgumentList $Name -ErrorAction Stop
        } else {
            return & $statusBlock -AccountName $Name
        }
    } catch {
        return [PSCustomObject]@{ Success = $false; Message = "Status check failed: $($_.Exception.Message)" }
    }
}
#endregion

#region Section 6: GMSA Installation Functions

function Install-GMSAOnComputer {
    param(
        [string]$GMSAName,
        [string]$TargetComputer,
        [bool]$IsRemote,
        [System.Management.Automation.PSCredential]$Credential
    )
    $installBlock = {
        param($AccountName)
        try {
            Import-Module ActiveDirectory -ErrorAction Stop
            Install-ADServiceAccount -Identity $AccountName -ErrorAction Stop
            $testResult = Test-ADServiceAccount -Identity $AccountName -ErrorAction SilentlyContinue
            return [PSCustomObject]@{
                Success    = $true
                TestPassed = $testResult
                Computer   = $env:COMPUTERNAME
                Message    = if ($testResult) { "Installed and verified OK." } else { "Installed but Test-ADServiceAccount returned false (machine may not be in AllowedPrincipals yet)." }
                Timestamp  = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            }
        } catch {
            return [PSCustomObject]@{
                Success    = $false
                TestPassed = $false
                Computer   = $env:COMPUTERNAME
                Message    = "Install failed: $($_.Exception.Message)"
                Timestamp  = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            }
        }
    }
    try {
        if ($IsRemote) {
            $invokeParams = @{
                ComputerName = $TargetComputer
                ScriptBlock  = $installBlock
                ArgumentList = $GMSAName
                ErrorAction  = 'Stop'
            }
            if ($Credential) { $invokeParams['Credential'] = $Credential }
            return Invoke-Command @invokeParams
        } else {
            return & $installBlock -AccountName $GMSAName
        }
    } catch [System.Management.Automation.Remoting.PSRemotingTransportException] {
        return [PSCustomObject]@{
            Success    = $false
            TestPassed = $false
            Computer   = $TargetComputer
            Message    = "WinRM connection failed. Ensure WinRM is enabled on the target."
            Timestamp  = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        }
    } catch {
        return [PSCustomObject]@{
            Success    = $false
            TestPassed = $false
            Computer   = $TargetComputer
            Message    = "Error: $($_.Exception.Message)"
            Timestamp  = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        }
    }
}

function Test-GMSAOnComputer {
    param(
        [string]$GMSAName,
        [string]$TargetComputer,
        [bool]$IsRemote,
        [System.Management.Automation.PSCredential]$Credential
    )
    $testBlock = {
        param($AccountName)
        try {
            Import-Module ActiveDirectory -ErrorAction Stop
            $result = Test-ADServiceAccount -Identity $AccountName -ErrorAction SilentlyContinue
            return [PSCustomObject]@{
                Success    = $true
                TestPassed = $result
                Computer   = $env:COMPUTERNAME
                Message    = if ($result) { "Test-ADServiceAccount: PASSED" } else { "Test-ADServiceAccount: FAILED (not in AllowedPrincipals?)" }
                Timestamp  = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            }
        } catch {
            return [PSCustomObject]@{
                Success    = $false
                TestPassed = $false
                Computer   = $env:COMPUTERNAME
                Message    = "Test error: $($_.Exception.Message)"
                Timestamp  = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            }
        }
    }
    try {
        if ($IsRemote) {
            $invokeParams = @{
                ComputerName = $TargetComputer
                ScriptBlock  = $testBlock
                ArgumentList = $GMSAName
                ErrorAction  = 'Stop'
            }
            if ($Credential) { $invokeParams['Credential'] = $Credential }
            return Invoke-Command @invokeParams
        } else {
            return & $testBlock -AccountName $GMSAName
        }
    } catch {
        return [PSCustomObject]@{
            Success    = $false
            TestPassed = $false
            Computer   = $TargetComputer
            Message    = "Remote test error: $($_.Exception.Message)"
            Timestamp  = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        }
    }
}

function Invoke-BatchInstall {
    param(
        [string[]]$ComputerList,
        [string]$GMSAName,
        [bool]$IsRemote,
        [System.Management.Automation.PSCredential]$Credential,
        [int]$MaxParallelJobs,
        [bool]$UseParallel,
        [bool]$TestOnly,
        [System.Windows.Forms.ListView]$ResultsView,
        [System.Windows.Forms.RichTextBox]$LogBox
    )
    if ($UseParallel -and $IsRemote -and $ComputerList.Count -gt 1) {
        $installBlock = {
            param($GMSAName, $IsRemote, $Computer, $CredXml, $TestOnly)
            $cred = if ($CredXml) { [System.Management.Automation.PSCredential]([System.Management.Automation.PSSerializer]::Deserialize($CredXml)) } else { $null }
            $innerBlock = if ($TestOnly) {
                {
                    param($AccountName)
                    Import-Module ActiveDirectory -ErrorAction Stop
                    $result = Test-ADServiceAccount -Identity $AccountName -ErrorAction SilentlyContinue
                    [PSCustomObject]@{ Success=$true; TestPassed=$result; Computer=$env:COMPUTERNAME; Message=if($result){"PASSED"}else{"FAILED"}; Timestamp=(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') }
                }
            } else {
                {
                    param($AccountName)
                    Import-Module ActiveDirectory -ErrorAction Stop
                    Install-ADServiceAccount -Identity $AccountName -ErrorAction Stop
                    $result = Test-ADServiceAccount -Identity $AccountName -ErrorAction SilentlyContinue
                    [PSCustomObject]@{ Success=$true; TestPassed=$result; Computer=$env:COMPUTERNAME; Message=if($result){"Installed+Verified"}else{"Installed, Test FAILED"}; Timestamp=(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') }
                }
            }
            try {
                $params = @{ ComputerName=$Computer; ScriptBlock=$innerBlock; ArgumentList=$GMSAName; ErrorAction='Stop' }
                if ($cred) { $params['Credential'] = $cred }
                Invoke-Command @params
            } catch {
                [PSCustomObject]@{ Success=$false; TestPassed=$false; Computer=$Computer; Message=$_.Exception.Message; Timestamp=(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') }
            }
        }

        $pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, $MaxParallelJobs)
        $pool.Open()
        $jobs = @()
        $credXml = if ($Credential) { [System.Management.Automation.PSSerializer]::Serialize($Credential) } else { $null }

        foreach ($computer in $ComputerList) {
            $ps = [System.Management.Automation.PowerShell]::Create()
            $ps.RunspacePool = $pool
            [void]$ps.AddScript($installBlock).AddArgument($GMSAName).AddArgument($IsRemote).AddArgument($computer).AddArgument($credXml).AddArgument($TestOnly)
            $handle = $ps.BeginInvoke()
            $jobs += [PSCustomObject]@{ PS = $ps; Handle = $handle; Computer = $computer }
        }

        foreach ($job in $jobs) {
            try {
                $result = $job.PS.EndInvoke($job.Handle)
                Update-ComputerListItem -ResultsView $ResultsView -Computer $job.Computer -Result $result -LogBox $LogBox
            } catch {
                $errResult = [PSCustomObject]@{ Success=$false; TestPassed=$false; Computer=$job.Computer; Message=$_.Exception.Message; Timestamp=(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') }
                Update-ComputerListItem -ResultsView $ResultsView -Computer $job.Computer -Result $errResult -LogBox $LogBox
            } finally {
                $job.PS.Dispose()
            }
        }
        $pool.Close()
        $pool.Dispose()
    } else {
        foreach ($computer in $ComputerList) {
            if ($TestOnly) {
                $result = Test-GMSAOnComputer -GMSAName $GMSAName -TargetComputer $computer -IsRemote $IsRemote -Credential $Credential
            } else {
                $result = Install-GMSAOnComputer -GMSAName $GMSAName -TargetComputer $computer -IsRemote $IsRemote -Credential $Credential
            }
            Update-ComputerListItem -ResultsView $ResultsView -Computer $computer -Result $result -LogBox $LogBox
        }
    }
}

function Update-ComputerListItem {
    param(
        [System.Windows.Forms.ListView]$ResultsView,
        [string]$Computer,
        $Result,
        [System.Windows.Forms.RichTextBox]$LogBox
    )
    $updateAction = [Action]{
        $item = $ResultsView.Items | Where-Object { $_.Text -eq $Computer } | Select-Object -First 1
        if (-not $item) { return }
        if ($Result.Success -and $Result.TestPassed) {
            $item.ForeColor = [System.Drawing.Color]::LimeGreen
            $item.SubItems[1].Text = "OK"
        } elseif ($Result.Success -and -not $Result.TestPassed) {
            $item.ForeColor = [System.Drawing.Color]::Goldenrod
            $item.SubItems[1].Text = "WARN"
        } else {
            $item.ForeColor = [System.Drawing.Color]::OrangeRed
            $item.SubItems[1].Text = "FAILED"
        }
        $item.SubItems[2].Text = $Result.Message
        $item.SubItems[3].Text = $Result.Timestamp
    }
    if ($ResultsView.InvokeRequired) {
        $ResultsView.Invoke($updateAction)
    } else {
        & $updateAction
    }
    $level = if ($Result.Success -and $Result.TestPassed) { 'Success' } elseif ($Result.Success) { 'Warning' } else { 'Error' }
    Write-GUILog -Message "[$Computer] $($Result.Message)" -Level $level -LogBox $LogBox
}
#endregion

#region Section 7: Remote Execution Wrapper Functions

function Test-RemoteConnectivity {
    param(
        [string]$ComputerName,
        [System.Management.Automation.PSCredential]$Credential
    )
    try {
        $pingOk = Test-Connection -ComputerName $ComputerName -Count 1 -Quiet -ErrorAction SilentlyContinue
        if (-not $pingOk) {
            return [PSCustomObject]@{ Success = $false; Message = "Ping failed. Host unreachable: $ComputerName" }
        }
        $wsmanParams = @{ ComputerName = $ComputerName; ErrorAction = 'Stop' }
        if ($Credential) { $wsmanParams['Credential'] = $Credential; $wsmanParams['Authentication'] = 'Negotiate' }
        Test-WSMan @wsmanParams | Out-Null
        return [PSCustomObject]@{ Success = $true; Message = "WinRM connection to $ComputerName is OK." }
    } catch [System.Management.Automation.Remoting.PSRemotingTransportException] {
        return [PSCustomObject]@{ Success = $false; Message = "WinRM not available on $ComputerName. Run Enable-PSRemoting on the target." }
    } catch {
        return [PSCustomObject]@{ Success = $false; Message = "Connection test failed: $($_.Exception.Message)" }
    }
}
#endregion

#region Section 8: Logging Subsystem

function Write-GUILog {
    param(
        [string]$Message,
        [ValidateSet('Info','Success','Warning','Error','Verbose')]
        [string]$Level = 'Info',
        [System.Windows.Forms.RichTextBox]$LogBox
    )
    if ($Level -eq 'Verbose' -and -not $Script:VerboseLogging) { return }
    $colorMap = @{
        'Info'    = $Script:Colors.Info
        'Success' = $Script:Colors.Success
        'Warning' = $Script:Colors.Warning
        'Error'   = $Script:Colors.Error
        'Verbose' = $Script:Colors.Verbose
    }
    $timestamp = "[$(Get-Date -Format 'HH:mm:ss')]"
    $line = "$timestamp [$($Level.ToUpper().PadRight(7))] $Message"
    $color = $colorMap[$Level]

    $appendAction = [Action]{
        $LogBox.SelectionStart  = $LogBox.TextLength
        $LogBox.SelectionLength = 0
        $LogBox.SelectionColor  = $color
        $LogBox.AppendText("$line`r`n")
        if ($Script:AutoScroll) { $LogBox.ScrollToCaret() }
    }
    if ($LogBox -and $LogBox.IsHandleCreated) {
        if ($LogBox.InvokeRequired) {
            $LogBox.Invoke($appendAction)
        } else {
            & $appendAction
        }
    }
}
#endregion

#region Section 9: GUI Builder

function Build-MainForm {

    #--- Main Form ---
    $form = New-Object System.Windows.Forms.Form
    $form.Text            = "GMSA Manager - Active Directory Automation"
    $form.Size            = New-Object System.Drawing.Size(960, 780)
    $form.MinimumSize     = New-Object System.Drawing.Size(800, 650)
    $form.StartPosition   = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.BackColor       = $Script:Colors.FormBack
    $form.Font            = New-Object System.Drawing.Font("Segoe UI", 9)
    $form.Icon            = [System.Drawing.SystemIcons]::Shield

    #--- StatusStrip ---
    $statusStrip    = New-Object System.Windows.Forms.StatusStrip
    $statusLabel    = New-Object System.Windows.Forms.ToolStripStatusLabel
    $statusLabel.Text   = "Ready  |  Mode: [Local]"
    $statusLabel.Spring = $true
    $statusLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $statusProgress = New-Object System.Windows.Forms.ToolStripProgressBar
    $statusProgress.Width   = 150
    $statusProgress.Visible = $false
    $statusStrip.Items.AddRange(@($statusLabel, $statusProgress))
    $form.Controls.Add($statusStrip)

    #--- Outer SplitContainer (Tabs top, Log bottom) ---
    $splitMain = New-Object System.Windows.Forms.SplitContainer
    $splitMain.Dock        = [System.Windows.Forms.DockStyle]::Fill
    $splitMain.Orientation = [System.Windows.Forms.Orientation]::Horizontal
    $splitMain.SplitterDistance = 430
    $splitMain.Panel1MinSize    = 300
    $splitMain.Panel2MinSize    = 150
    $form.Controls.Add($splitMain)

    #========================
    # TabControl
    #========================
    $tabControl = New-Object System.Windows.Forms.TabControl
    $tabControl.Dock     = [System.Windows.Forms.DockStyle]::Fill
    $tabControl.Font     = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $splitMain.Panel1.Controls.Add($tabControl)

    #--- Helper: styled GroupBox ---
    function New-GroupBox { param([string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H)
        $gb = New-Object System.Windows.Forms.GroupBox
        $gb.Text = $Text; $gb.Location = New-Object System.Drawing.Point($X,$Y)
        $gb.Size = New-Object System.Drawing.Size($W,$H); $gb.Font = New-Object System.Drawing.Font("Segoe UI",9)
        return $gb
    }
    function New-Label { param([string]$Text, [int]$X, [int]$Y, [int]$W=120, [int]$H=20)
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $Text; $l.Location = New-Object System.Drawing.Point($X,$Y)
        $l.Size = New-Object System.Drawing.Size($W,$H); $l.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
        return $l
    }
    function New-TextBox { param([int]$X, [int]$Y, [int]$W=200, [int]$H=22, [bool]$ReadOnly=$false)
        $t = New-Object System.Windows.Forms.TextBox
        $t.Location = New-Object System.Drawing.Point($X,$Y); $t.Size = New-Object System.Drawing.Size($W,$H)
        $t.ReadOnly = $ReadOnly; if($ReadOnly){$t.BackColor=[System.Drawing.Color]::WhiteSmoke}
        return $t
    }
    function New-Button { param([string]$Text, [int]$X, [int]$Y, [int]$W=110, [int]$H=28)
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $Text; $b.Location = New-Object System.Drawing.Point($X,$Y)
        $b.Size = New-Object System.Drawing.Size($W,$H); $b.FlatStyle = [System.Windows.Forms.FlatStyle]::System
        return $b
    }

    ##################################
    # TAB 1 - Prerequisites
    ##################################
    $tabPrereq = New-Object System.Windows.Forms.TabPage
    $tabPrereq.Text    = "  1. Prerequisites  "
    $tabPrereq.Padding = New-Object System.Windows.Forms.Padding(10)
    $tabControl.TabPages.Add($tabPrereq)

    # Environment Info GroupBox
    $gbEnv = New-GroupBox "Environment" 10 10 400 130
    $tabPrereq.Controls.Add($gbEnv)

    $envLabels = @("Domain FQDN:", "Current User:", "Computer Name:", "PS Version:")
    $envFields = @()
    for ($i = 0; $i -lt 4; $i++) {
        $lbl = New-Label $envLabels[$i] 10 (25 + $i*24) 110 20
        $txt = New-TextBox 125 (23 + $i*24) 250 22 $true
        $gbEnv.Controls.AddRange(@($lbl, $txt))
        $envFields += $txt
    }
    $domainResult = Get-CurrentDomainFQDN
    $envFields[0].Text = if ($domainResult) { $domainResult } else { "Not available" }
    $envFields[1].Text = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $envFields[2].Text = $env:COMPUTERNAME
    $envFields[3].Text = "PowerShell $($PSVersionTable.PSVersion)"

    # Checks GroupBox
    $gbChecks = New-GroupBox "Requirement Checks" 10 150 900 200
    $tabPrereq.Controls.Add($gbChecks)

    $checkItems = @(
        @{ Label="RSAT / ActiveDirectory Module"; Key="ADModule" },
        @{ Label="KDS Root Key Present";          Key="KDSKey" },
        @{ Label="Domain Connectivity";            Key="Domain" },
        @{ Label="Administrator Privileges";       Key="Admin" }
    )
    $checkStatusLabels = @{}
    $checkIconLabels   = @{}

    for ($i = 0; $i -lt $checkItems.Count; $i++) {
        $row = $checkItems[$i]
        $yPos = 25 + $i * 38
        $iconLbl = New-Object System.Windows.Forms.Label
        $iconLbl.Text = "●"; $iconLbl.ForeColor = [System.Drawing.Color]::Silver
        $iconLbl.Location = New-Object System.Drawing.Point(15, ($yPos+2))
        $iconLbl.Size = New-Object System.Drawing.Size(20, 20)
        $iconLbl.Font = New-Object System.Drawing.Font("Segoe UI",12)
        $checkIconLabels[$row.Key] = $iconLbl

        $descLbl = New-Object System.Windows.Forms.Label
        $descLbl.Text = $row.Label
        $descLbl.Location = New-Object System.Drawing.Point(40, ($yPos+2))
        $descLbl.Size = New-Object System.Drawing.Size(220, 20)

        $statLbl = New-Object System.Windows.Forms.Label
        $statLbl.Text = "Not checked"
        $statLbl.ForeColor = [System.Drawing.Color]::Gray
        $statLbl.Location = New-Object System.Drawing.Point(270, ($yPos+2))
        $statLbl.Size = New-Object System.Drawing.Size(550, 20)
        $checkStatusLabels[$row.Key] = $statLbl

        $gbChecks.Controls.AddRange(@($iconLbl, $descLbl, $statLbl))
    }

    $btnRunAllChecks = New-Button "Run All Checks" 10 360 150 30
    $btnRunAllChecks.BackColor = $Script:Colors.Primary
    $btnRunAllChecks.ForeColor = [System.Drawing.Color]::White
    $btnRunAllChecks.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $tabPrereq.Controls.Add($btnRunAllChecks)

    $btnCreateKDS = New-Button "Create KDS Root Key..." 170 360 200 30
    $btnCreateKDS.BackColor = $Script:Colors.Danger
    $btnCreateKDS.ForeColor = [System.Drawing.Color]::White
    $btnCreateKDS.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnCreateKDS.Visible   = $false
    $tabPrereq.Controls.Add($btnCreateKDS)

    ##################################
    # TAB 2 - Create GMSA
    ##################################
    $tabCreate = New-Object System.Windows.Forms.TabPage
    $tabCreate.Text    = "  2. Create GMSA  "
    $tabCreate.Padding = New-Object System.Windows.Forms.Padding(10)
    $tabControl.TabPages.Add($tabCreate)

    # Scroll panel to hold everything
    $createPanel = New-Object System.Windows.Forms.Panel
    $createPanel.Dock          = [System.Windows.Forms.DockStyle]::Fill
    $createPanel.AutoScroll    = $true
    $tabCreate.Controls.Add($createPanel)

    # --- Execution Target GroupBox ---
    $gbCreateMode = New-GroupBox "Execution Target" 10 5 900 110
    $createPanel.Controls.Add($gbCreateMode)

    $rbCreateLocal  = New-Object System.Windows.Forms.RadioButton
    $rbCreateLocal.Text = "Local Execution (this machine)"; $rbCreateLocal.Checked = $true
    $rbCreateLocal.Location = New-Object System.Drawing.Point(15,25); $rbCreateLocal.Size = New-Object System.Drawing.Size(220,22)
    $rbCreateRemote = New-Object System.Windows.Forms.RadioButton
    $rbCreateRemote.Text = "Remote DC / Server"
    $rbCreateRemote.Location = New-Object System.Drawing.Point(15,50); $rbCreateRemote.Size = New-Object System.Drawing.Size(200,22)
    $gbCreateMode.Controls.AddRange(@($rbCreateLocal,$rbCreateRemote))

    $pnlCreateRemote = New-Object System.Windows.Forms.Panel
    $pnlCreateRemote.Location = New-Object System.Drawing.Point(240,18); $pnlCreateRemote.Size = New-Object System.Drawing.Size(640,80)
    $pnlCreateRemote.Visible  = $false
    $gbCreateMode.Controls.Add($pnlCreateRemote)

    $lblDCHost = New-Label "DC Hostname:" 0 5 100 20
    $txtDCHost = New-TextBox 105 3 180 22
    $txtDCHost.PlaceholderText = "dc01.contoso.com"
    $lblDCUser = New-Label "Username:" 300 5 80 20
    $txtDCUser = New-TextBox 383 3 160 22
    $txtDCUser.PlaceholderText = "DOMAIN\admin"
    $lblDCPass = New-Label "Password:" 0 35 100 20
    $txtDCPass = New-Object System.Windows.Forms.MaskedTextBox
    $txtDCPass.UseSystemPasswordChar = $true
    $txtDCPass.Location = New-Object System.Drawing.Point(105,33); $txtDCPass.Size = New-Object System.Drawing.Size(180,22)
    $btnTestConn = New-Button "Test Connection" 300 31 140 26
    $pnlCreateRemote.Controls.AddRange(@($lblDCHost,$txtDCHost,$lblDCUser,$txtDCUser,$lblDCPass,$txtDCPass,$btnTestConn))

    # --- GMSA Properties GroupBox ---
    $gbGMSAProps = New-GroupBox "GMSA Properties" 10 125 900 190
    $createPanel.Controls.Add($gbGMSAProps)

    $propDefs = @(
        @{Label="Account Name *:"; PH="svcMyApp (max 15)"; W=200; Row=0},
        @{Label="DNS Host Suffix *:"; PH="contoso.com"; W=200; Row=1},
        @{Label="Description:"; PH="My service account"; W=400; Row=2},
        @{Label="OU Path (DN):"; PH="OU=ServiceAccounts,DC=contoso,DC=com"; W=500; Row=3}
    )
    $propTextBoxes = @()
    foreach ($def in $propDefs) {
        $y = 25 + $def.Row * 35
        $l = New-Label $def.Label 10 ($y+2) 130 20; $gbGMSAProps.Controls.Add($l)
        $t = New-TextBox 145 $y $def.W 22; $t.PlaceholderText = $def.PH; $gbGMSAProps.Controls.Add($t)
        $propTextBoxes += $t
    }
    $txtGMSAName     = $propTextBoxes[0]
    $txtDNSSuffix    = $propTextBoxes[1]
    $txtDescription  = $propTextBoxes[2]
    $txtOUPath       = $propTextBoxes[3]

    $lblPwdInterval = New-Label "Password Interval:" 660 27 120 20; $gbGMSAProps.Controls.Add($lblPwdInterval)
    $nudPwdInterval = New-Object System.Windows.Forms.NumericUpDown
    $nudPwdInterval.Location = New-Object System.Drawing.Point(783,25); $nudPwdInterval.Size = New-Object System.Drawing.Size(80,22)
    $nudPwdInterval.Minimum = 1; $nudPwdInterval.Maximum = 365; $nudPwdInterval.Value = 30
    $gbGMSAProps.Controls.Add($nudPwdInterval)
    $lblDays = New-Label "days" 866 27 40 20; $lblDays.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft; $gbGMSAProps.Controls.Add($lblDays)

    # Auto-fill DNS suffix from domain
    $domainFQDN = Get-CurrentDomainFQDN
    if ($domainFQDN) { $txtDNSSuffix.Text = $domainFQDN }

    # Name length indicator
    $lblNameHint = New-Object System.Windows.Forms.Label
    $lblNameHint.Text = "0/15"; $lblNameHint.ForeColor = [System.Drawing.Color]::Green
    $lblNameHint.Location = New-Object System.Drawing.Point(350, 27); $lblNameHint.Size = New-Object System.Drawing.Size(50,20)
    $gbGMSAProps.Controls.Add($lblNameHint)
    $txtGMSAName.Add_TextChanged({
        $len = $txtGMSAName.Text.Length
        $lblNameHint.Text = "$len/15"
        $lblNameHint.ForeColor = if($len -gt 15){[System.Drawing.Color]::Red} else {[System.Drawing.Color]::Green}
    })

    # --- Allowed Principals GroupBox ---
    $gbPrincipals = New-GroupBox "Allowed Principals (PrincipalsAllowedToRetrieveManagedPassword)" 10 325 500 145
    $createPanel.Controls.Add($gbPrincipals)

    $lbPrincipals = New-Object System.Windows.Forms.ListBox
    $lbPrincipals.Location = New-Object System.Drawing.Point(10,20); $lbPrincipals.Size = New-Object System.Drawing.Size(290,100)
    $txtAddPrincipal = New-TextBox 310 20 130 22; $txtAddPrincipal.PlaceholderText = "Computer/Group name"
    $btnAddPrincipal = New-Button "Add" 445 18 45 24
    $btnRemPrincipal = New-Button "Remove" 310 50 100 24
    $chkAutoAddPC    = New-Object System.Windows.Forms.CheckBox
    $chkAutoAddPC.Text = "Auto-add this PC ($env:COMPUTERNAME)"
    $chkAutoAddPC.Location = New-Object System.Drawing.Point(310,80); $chkAutoAddPC.Size = New-Object System.Drawing.Size(180,40)
    $chkAutoAddPC.Checked = $true
    $gbPrincipals.Controls.AddRange(@($lbPrincipals,$txtAddPrincipal,$btnAddPrincipal,$btnRemPrincipal,$chkAutoAddPC))

    # --- SPN GroupBox ---
    $gbSPN = New-GroupBox "Service Principal Names (Optional)" 520 325 400 145
    $createPanel.Controls.Add($gbSPN)

    $lbSPNs = New-Object System.Windows.Forms.ListBox
    $lbSPNs.Location = New-Object System.Drawing.Point(10,20); $lbSPNs.Size = New-Object System.Drawing.Size(240,100)
    $txtAddSPN = New-TextBox 260 20 110 22; $txtAddSPN.PlaceholderText = "HTTP/server.domain.com"
    $btnAddSPN = New-Button "Add" 374 18 20 24; $btnAddSPN.Size = New-Object System.Drawing.Size(20,24)
    $btnRemSPN = New-Button "Remove" 260 50 90 24
    $gbSPN.Controls.AddRange(@($lbSPNs,$txtAddSPN,$btnAddSPN,$btnRemSPN))

    # --- Action Buttons ---
    $btnCreateGMSA = New-Button "  Create GMSA  " 10 480 160 36
    $btnCreateGMSA.BackColor = $Script:Colors.Primary
    $btnCreateGMSA.ForeColor = [System.Drawing.Color]::White
    $btnCreateGMSA.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnCreateGMSA.Font = New-Object System.Drawing.Font("Segoe UI",10,[System.Drawing.FontStyle]::Bold)
    $btnVerifyGMSA = New-Button "Verify After Create" 185 480 160 36
    $createPanel.Controls.AddRange(@($btnCreateGMSA, $btnVerifyGMSA))

    ##################################
    # TAB 3 - Install on Clients
    ##################################
    $tabInstall = New-Object System.Windows.Forms.TabPage
    $tabInstall.Text    = "  3. Install on Clients  "
    $tabInstall.Padding = New-Object System.Windows.Forms.Padding(10)
    $tabControl.TabPages.Add($tabInstall)

    $installPanel = New-Object System.Windows.Forms.Panel
    $installPanel.Dock = [System.Windows.Forms.DockStyle]::Fill; $installPanel.AutoScroll = $true
    $tabInstall.Controls.Add($installPanel)

    # --- Execution Mode ---
    $gbInstallMode = New-GroupBox "Execution Mode" 10 5 900 105
    $installPanel.Controls.Add($gbInstallMode)

    $rbInstallLocal  = New-Object System.Windows.Forms.RadioButton
    $rbInstallLocal.Text = "Local - Install on this machine only"; $rbInstallLocal.Checked = $true
    $rbInstallLocal.Location = New-Object System.Drawing.Point(15,22); $rbInstallLocal.Size = New-Object System.Drawing.Size(260,22)
    $rbInstallRemote = New-Object System.Windows.Forms.RadioButton
    $rbInstallRemote.Text = "Remote - Install via WinRM on listed computers"
    $rbInstallRemote.Location = New-Object System.Drawing.Point(15,47); $rbInstallRemote.Size = New-Object System.Drawing.Size(280,22)
    $gbInstallMode.Controls.AddRange(@($rbInstallLocal,$rbInstallRemote))

    $pnlInstallCred = New-Object System.Windows.Forms.Panel
    $pnlInstallCred.Location = New-Object System.Drawing.Point(310,15); $pnlInstallCred.Size = New-Object System.Drawing.Size(570,80)
    $pnlInstallCred.Visible  = $false
    $gbInstallMode.Controls.Add($pnlInstallCred)

    $chkCurrentCreds = New-Object System.Windows.Forms.CheckBox
    $chkCurrentCreds.Text = "Use current credentials"; $chkCurrentCreds.Checked = $true
    $chkCurrentCreds.Location = New-Object System.Drawing.Point(0,5); $chkCurrentCreds.Size = New-Object System.Drawing.Size(180,22)
    $pnlInstallCredFields = New-Object System.Windows.Forms.Panel
    $pnlInstallCredFields.Location = New-Object System.Drawing.Point(0,30); $pnlInstallCredFields.Size = New-Object System.Drawing.Size(570,45)
    $pnlInstallCredFields.Visible = $false
    $lblInstUser = New-Label "Username:" 0 5 80 20; $txtInstUser = New-TextBox 85 3 160 22; $txtInstUser.PlaceholderText = "DOMAIN\user"
    $lblInstPass = New-Label "Password:" 260 5 80 20
    $txtInstPass = New-Object System.Windows.Forms.MaskedTextBox; $txtInstPass.UseSystemPasswordChar = $true
    $txtInstPass.Location = New-Object System.Drawing.Point(345,3); $txtInstPass.Size = New-Object System.Drawing.Size(160,22)
    $pnlInstallCredFields.Controls.AddRange(@($lblInstUser,$txtInstUser,$lblInstPass,$txtInstPass))
    $pnlInstallCred.Controls.AddRange(@($chkCurrentCreds,$pnlInstallCredFields))

    $chkCurrentCreds.Add_CheckedChanged({ $pnlInstallCredFields.Visible = -not $chkCurrentCreds.Checked })

    # --- GMSA to Install ---
    $gbInstallGMSA = New-GroupBox "GMSA Account to Install" 10 120 450 65
    $installPanel.Controls.Add($gbInstallGMSA)
    $lblInstGMSAName = New-Label "Account Name *:" 10 25 120 20; $gbInstallGMSA.Controls.Add($lblInstGMSAName)
    $txtInstGMSAName = New-TextBox 135 23 200 22; $txtInstGMSAName.PlaceholderText = "svcMyApp"; $gbInstallGMSA.Controls.Add($txtInstGMSAName)
    $btnValidateGMSA = New-Button "Lookup/Validate" 345 21 100 26; $gbInstallGMSA.Controls.Add($btnValidateGMSA)

    # --- Target Computers ---
    $gbComputers = New-GroupBox "Target Computers" 10 195 900 200
    $installPanel.Controls.Add($gbComputers)

    $lvComputers = New-Object System.Windows.Forms.ListView
    $lvComputers.View          = [System.Windows.Forms.View]::Details
    $lvComputers.FullRowSelect = $true
    $lvComputers.GridLines     = $true
    $lvComputers.Location      = New-Object System.Drawing.Point(10,20)
    $lvComputers.Size          = New-Object System.Drawing.Size(680,160)
    $lvComputers.BackColor     = [System.Drawing.Color]::White
    [void]$lvComputers.Columns.Add("Computer Name", 200)
    [void]$lvComputers.Columns.Add("Status", 80)
    [void]$lvComputers.Columns.Add("Last Result", 280)
    [void]$lvComputers.Columns.Add("Timestamp", 120)
    $gbComputers.Controls.Add($lvComputers)

    $pnlComputerActions = New-Object System.Windows.Forms.Panel
    $pnlComputerActions.Location = New-Object System.Drawing.Point(700,20); $pnlComputerActions.Size = New-Object System.Drawing.Size(180,160)
    $gbComputers.Controls.Add($pnlComputerActions)

    $txtAddComputer  = New-TextBox 0 0 175 22; $txtAddComputer.PlaceholderText = "Hostname or IP"
    $btnAddComputer  = New-Button "Add Computer" 0 28 175 26
    $btnRemComputer  = New-Button "Remove Selected" 0 58 175 26
    $btnImportCSV    = New-Button "Import CSV/TXT..." 0 88 175 26
    $btnClearComputers = New-Button "Clear All" 0 118 175 26
    $pnlComputerActions.Controls.AddRange(@($txtAddComputer,$btnAddComputer,$btnRemComputer,$btnImportCSV,$btnClearComputers))

    # --- Actions ---
    $gbActions = New-GroupBox "Actions" 10 405 900 80
    $installPanel.Controls.Add($gbActions)

    $btnInstallSelected = New-Button "Install on Selected" 10 25 160 36
    $btnTestSelected    = New-Button "Test on Selected" 180 25 150 36
    $btnInstallTestAll  = New-Button "Install + Test All" 340 25 160 36
    $btnInstallTestAll.BackColor = $Script:Colors.Primary
    $btnInstallTestAll.ForeColor = [System.Drawing.Color]::White
    $btnInstallTestAll.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat

    $chkParallel = New-Object System.Windows.Forms.CheckBox
    $chkParallel.Text = "Parallel"; $chkParallel.Checked = $false
    $chkParallel.Location = New-Object System.Drawing.Point(515,30); $chkParallel.Size = New-Object System.Drawing.Size(80,22)

    $lblMaxJobs = New-Label "Max jobs:" 600 30 70 22; $lblMaxJobs.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $nudMaxJobs = New-Object System.Windows.Forms.NumericUpDown
    $nudMaxJobs.Location = New-Object System.Drawing.Point(670,28); $nudMaxJobs.Size = New-Object System.Drawing.Size(55,22)
    $nudMaxJobs.Minimum = 1; $nudMaxJobs.Maximum = 20; $nudMaxJobs.Value = 5

    $gbActions.Controls.AddRange(@($btnInstallSelected,$btnTestSelected,$btnInstallTestAll,$chkParallel,$lblMaxJobs,$nudMaxJobs))

    #========================
    # Log Panel
    #========================
    $gbLog = New-Object System.Windows.Forms.GroupBox
    $gbLog.Text = "Activity Log"; $gbLog.Dock = [System.Windows.Forms.DockStyle]::Fill
    $splitMain.Panel2.Controls.Add($gbLog)

    $logBox = New-Object System.Windows.Forms.RichTextBox
    $logBox.ReadOnly    = $true
    $logBox.BackColor   = $Script:Colors.LogBack
    $logBox.ForeColor   = $Script:Colors.Info
    $logBox.Font        = New-Object System.Drawing.Font("Consolas", 9)
    $logBox.WordWrap    = $false
    $logBox.ScrollBars  = [System.Windows.Forms.RichTextBoxScrollBars]::Both
    $logBox.Dock        = [System.Windows.Forms.DockStyle]::Fill
    $gbLog.Controls.Add($logBox)

    $pnlLogButtons = New-Object System.Windows.Forms.Panel
    $pnlLogButtons.Dock   = [System.Windows.Forms.DockStyle]::Bottom
    $pnlLogButtons.Height = 32
    $gbLog.Controls.Add($pnlLogButtons)

    $btnClearLog  = New-Button "Clear Log" 5 3 85 26
    $btnSaveLog   = New-Button "Save Log..." 95 3 85 26
    $chkAutoScrollLog = New-Object System.Windows.Forms.CheckBox
    $chkAutoScrollLog.Text = "Auto-scroll"; $chkAutoScrollLog.Checked = $true
    $chkAutoScrollLog.Location = New-Object System.Drawing.Point(190,6); $chkAutoScrollLog.Size = New-Object System.Drawing.Size(90,22)
    $chkVerbose = New-Object System.Windows.Forms.CheckBox
    $chkVerbose.Text = "Verbose"; $chkVerbose.Checked = $false
    $chkVerbose.Location = New-Object System.Drawing.Point(290,6); $chkVerbose.Size = New-Object System.Drawing.Size(75,22)
    $pnlLogButtons.Controls.AddRange(@($btnClearLog,$btnSaveLog,$chkAutoScrollLog,$chkVerbose))

    # Return all controls needed by event handlers
    return [PSCustomObject]@{
        Form                = $form
        StatusLabel         = $statusLabel
        StatusProgress      = $statusProgress
        LogBox              = $logBox
        # Tab 1
        CheckStatusLabels   = $checkStatusLabels
        CheckIconLabels     = $checkIconLabels
        BtnRunAllChecks     = $btnRunAllChecks
        BtnCreateKDS        = $btnCreateKDS
        # Tab 2
        RbCreateLocal       = $rbCreateLocal
        RbCreateRemote      = $rbCreateRemote
        PnlCreateRemote     = $pnlCreateRemote
        TxtDCHost           = $txtDCHost
        TxtDCUser           = $txtDCUser
        TxtDCPass           = $txtDCPass
        BtnTestConn         = $btnTestConn
        TxtGMSAName         = $txtGMSAName
        TxtDNSSuffix        = $txtDNSSuffix
        TxtDescription      = $txtDescription
        TxtOUPath           = $txtOUPath
        NudPwdInterval      = $nudPwdInterval
        LbPrincipals        = $lbPrincipals
        TxtAddPrincipal     = $txtAddPrincipal
        BtnAddPrincipal     = $btnAddPrincipal
        BtnRemPrincipal     = $btnRemPrincipal
        ChkAutoAddPC        = $chkAutoAddPC
        LbSPNs              = $lbSPNs
        TxtAddSPN           = $txtAddSPN
        BtnAddSPN           = $btnAddSPN
        BtnRemSPN           = $btnRemSPN
        BtnCreateGMSA       = $btnCreateGMSA
        BtnVerifyGMSA       = $btnVerifyGMSA
        # Tab 3
        RbInstallLocal      = $rbInstallLocal
        RbInstallRemote     = $rbInstallRemote
        PnlInstallCred      = $pnlInstallCred
        ChkCurrentCreds     = $chkCurrentCreds
        TxtInstUser         = $txtInstUser
        TxtInstPass         = $txtInstPass
        TxtInstGMSAName     = $txtInstGMSAName
        BtnValidateGMSA     = $btnValidateGMSA
        LvComputers         = $lvComputers
        TxtAddComputer      = $txtAddComputer
        BtnAddComputer      = $btnAddComputer
        BtnRemComputer      = $btnRemComputer
        BtnImportCSV        = $btnImportCSV
        BtnClearComputers   = $btnClearComputers
        BtnInstallSelected  = $btnInstallSelected
        BtnTestSelected     = $btnTestSelected
        BtnInstallTestAll   = $btnInstallTestAll
        ChkParallel         = $chkParallel
        NudMaxJobs          = $nudMaxJobs
        # Log controls
        BtnClearLog         = $btnClearLog
        BtnSaveLog          = $btnSaveLog
        ChkAutoScroll       = $chkAutoScrollLog
        ChkVerbose          = $chkVerbose
    }
}
#endregion

#region Section 10: Event Handlers

function Register-EventHandlers {
    param($UI)

    $log = $UI.LogBox

    #--- Helper: set check row result ---
    function Set-CheckResult {
        param([string]$Key, [bool]$Passed, [string]$Message)
        $UI.CheckStatusLabels[$Key].Text = $Message
        $UI.CheckStatusLabels[$Key].ForeColor = if ($Passed) { [System.Drawing.Color]::DarkGreen } else { [System.Drawing.Color]::DarkRed }
        $UI.CheckIconLabels[$Key].Text      = if ($Passed) { "●" } else { "●" }
        $UI.CheckIconLabels[$Key].ForeColor = if ($Passed) { [System.Drawing.Color]::LimeGreen } else { [System.Drawing.Color]::OrangeRed }
    }

    #--- Helper: disable/enable buttons during async work ---
    function Set-UIBusy {
        param([bool]$Busy, [string]$Message = "Working...")
        $buttons = @($UI.BtnRunAllChecks,$UI.BtnCreateGMSA,$UI.BtnVerifyGMSA,
                     $UI.BtnInstallSelected,$UI.BtnTestSelected,$UI.BtnInstallTestAll)
        foreach ($b in $buttons) { $b.Enabled = -not $Busy }
        $UI.StatusProgress.Visible = $Busy
        $UI.StatusLabel.Text = if ($Busy) { $Message } else { "Ready  |  Mode: [$($Script:ExecutionMode)]$(if($Script:RemoteTarget){" - $($Script:RemoteTarget)"})" }
    }

    #--- Log control events ---
    $UI.ChkAutoScroll.Add_CheckedChanged({ $Script:AutoScroll = $UI.ChkAutoScroll.Checked })
    $UI.ChkVerbose.Add_CheckedChanged({ $Script:VerboseLogging = $UI.ChkVerbose.Checked })

    $UI.BtnClearLog.Add_Click({ $UI.LogBox.Clear(); Write-GUILog "Log cleared." -Level Verbose -LogBox $log })

    $UI.BtnSaveLog.Add_Click({
        $dlg = New-Object System.Windows.Forms.SaveFileDialog
        $dlg.Filter = "Text files (*.txt)|*.txt|Log files (*.log)|*.log|All files (*.*)|*.*"
        $dlg.FileName = "GMSA-Manager-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $UI.LogBox.Text | Out-File -FilePath $dlg.FileName -Encoding UTF8
            Write-GUILog "Log saved to: $($dlg.FileName)" -Level Success -LogBox $log
        }
    })

    #--- Tab 2: Remote mode toggle ---
    $rbCreateRemoteHandler = {
        $UI.PnlCreateRemote.Visible = $UI.RbCreateRemote.Checked
        if ($UI.RbCreateRemote.Checked) {
            $Script:ExecutionMode = 'Remote'
            $Script:RemoteTarget  = $UI.TxtDCHost.Text
        } else {
            $Script:ExecutionMode = 'Local'
            $Script:RemoteTarget  = $null
            $Script:RemoteCred    = $null
        }
        $UI.StatusLabel.Text = "Ready  |  Mode: [$($Script:ExecutionMode)]$(if($Script:RemoteTarget){" - $($Script:RemoteTarget)"})"
    }
    $UI.RbCreateLocal.Add_CheckedChanged($rbCreateRemoteHandler)
    $UI.RbCreateRemote.Add_CheckedChanged($rbCreateRemoteHandler)
    $UI.TxtDCHost.Add_TextChanged({ $Script:RemoteTarget = $UI.TxtDCHost.Text })

    #--- Tab 3: Remote mode toggle ---
    $rbInstallRemoteHandler = {
        $UI.PnlInstallCred.Visible = $UI.RbInstallRemote.Checked
    }
    $UI.RbInstallLocal.Add_CheckedChanged($rbInstallRemoteHandler)
    $UI.RbInstallRemote.Add_CheckedChanged($rbInstallRemoteHandler)

    #--- Tab 2: Test remote connection ---
    $UI.BtnTestConn.Add_Click({
        $dc = $UI.TxtDCHost.Text.Trim()
        if (-not $dc) { Show-ErrorBox "Enter a DC hostname first."; return }
        Write-GUILog "Testing connection to $dc..." -Level Info -LogBox $log
        $cred = Get-FormCredential -Username $UI.TxtDCUser.Text.Trim() -PasswordBox $UI.TxtDCPass
        $result = Test-RemoteConnectivity -ComputerName $dc -Credential $cred
        if ($result.Success) {
            Write-GUILog $result.Message -Level Success -LogBox $log
        } else {
            Write-GUILog $result.Message -Level Error -LogBox $log
        }
    })

    #--- Tab 1: Run All Checks ---
    $UI.BtnRunAllChecks.Add_Click({
        Set-UIBusy $true "Running prerequisite checks..."
        Write-GUILog "Starting prerequisite checks..." -Level Info -LogBox $log

        $worker = New-Object System.ComponentModel.BackgroundWorker
        $worker.WorkerReportsProgress = $true

        $worker.Add_DoWork({
            param($sender, $e)
            $results = @{}

            $sender.ReportProgress(10, "Checking AD module...")
            $results['Admin']    = Test-AdminPrivileges
            $sender.ReportProgress(25, "Checking admin privileges...")
            $results['ADModule'] = Test-ADModuleAvailable
            $sender.ReportProgress(50, "Checking domain connectivity...")
            $results['Domain']   = Test-DomainConnectivity
            $sender.ReportProgress(75, "Checking KDS Root Key...")

            $dc   = $null
            $cred = $null
            $results['KDSKey'] = Test-KDSRootKey -RemoteDC $dc -Credential $cred

            $sender.ReportProgress(100, "Done.")
            $e.Result = $results
        })

        $worker.Add_ProgressChanged({
            param($sender, $e)
            $UI.StatusProgress.Value = $e.ProgressPercentage
            $UI.StatusLabel.Text = $e.UserState
        })

        $worker.Add_RunWorkerCompleted({
            param($sender, $e)
            if ($e.Error) {
                Write-GUILog "Checks failed: $($e.Error.Message)" -Level Error -LogBox $log
            } else {
                $results = $e.Result
                foreach ($key in $results.Keys) {
                    $r = $results[$key]
                    Set-CheckResult -Key $key -Passed $r.Passed -Message $r.Message
                    $lvl = if ($r.Passed) { 'Success' } else { 'Warning' }
                    Write-GUILog "[$key] $($r.Message)" -Level $lvl -LogBox $log
                }
                $kdsOk = $results['KDSKey'].Passed
                $UI.BtnCreateKDS.Visible = -not $kdsOk
                $Script:KDSCheckPassed   = $kdsOk
            }
            Set-UIBusy $false
        })

        $worker.RunWorkerAsync()
    })

    #--- Tab 1: Create KDS Root Key ---
    $UI.BtnCreateKDS.Add_Click({
        $msg = "Create KDS Root Key?`n`nChoose:`n  [Yes] = Effective Immediately (LAB only - not safe for production)`n  [No]  = Effective in 10 hours (Production safe - requires AD replication)"
        $result = [System.Windows.Forms.MessageBox]::Show($msg, "Create KDS Root Key",
            [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
            [System.Windows.Forms.MessageBoxIcon]::Warning)

        if ($result -eq [System.Windows.Forms.DialogResult]::Cancel) { return }
        $immediate = ($result -eq [System.Windows.Forms.DialogResult]::Yes)

        Set-UIBusy $true "Creating KDS Root Key..."
        Write-GUILog "Creating KDS Root Key (Immediate=$immediate)..." -Level Warning -LogBox $log

        $dc   = if ($Script:ExecutionMode -eq 'Remote') { $UI.TxtDCHost.Text.Trim() } else { $null }
        $cred = if ($Script:ExecutionMode -eq 'Remote') { Get-FormCredential -Username $UI.TxtDCUser.Text.Trim() -PasswordBox $UI.TxtDCPass } else { $null }

        $worker = New-Object System.ComponentModel.BackgroundWorker
        $worker.Add_DoWork({
            param($sender, $e)
            $args = $e.Argument
            $e.Result = Invoke-CreateKDSRootKey -EffectiveImmediately $args.Immediate -RemoteDC $args.DC -Credential $args.Cred
        })
        $worker.Add_RunWorkerCompleted({
            param($sender, $e)
            if ($e.Error) {
                Write-GUILog "KDS creation error: $($e.Error.Message)" -Level Error -LogBox $log
            } else {
                $r = $e.Result
                $lvl = if ($r.Success) { 'Success' } else { 'Error' }
                Write-GUILog $r.Message -Level $lvl -LogBox $log
                if ($r.Success) { $UI.BtnCreateKDS.Visible = $false; $Script:KDSCheckPassed = $true }
            }
            Set-UIBusy $false
        })
        $worker.RunWorkerAsync([PSCustomObject]@{ Immediate=$immediate; DC=$dc; Cred=$cred })
    })

    #--- Tab 2: Principals list management ---
    $UI.BtnAddPrincipal.Add_Click({
        $name = $UI.TxtAddPrincipal.Text.Trim()
        if ($name -and -not $UI.LbPrincipals.Items.Contains($name)) {
            [void]$UI.LbPrincipals.Items.Add($name)
            $UI.TxtAddPrincipal.Clear()
        }
    })
    $UI.TxtAddPrincipal.Add_KeyDown({
        if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Return) { $UI.BtnAddPrincipal.PerformClick() }
    })
    $UI.BtnRemPrincipal.Add_Click({
        if ($UI.LbPrincipals.SelectedIndex -ge 0) { $UI.LbPrincipals.Items.RemoveAt($UI.LbPrincipals.SelectedIndex) }
    })

    #--- Tab 2: SPN list management ---
    $UI.BtnAddSPN.Add_Click({
        $spn = $UI.TxtAddSPN.Text.Trim()
        if ($spn -and -not $UI.LbSPNs.Items.Contains($spn)) {
            [void]$UI.LbSPNs.Items.Add($spn)
            $UI.TxtAddSPN.Clear()
        }
    })
    $UI.TxtAddSPN.Add_KeyDown({
        if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Return) { $UI.BtnAddSPN.PerformClick() }
    })
    $UI.BtnRemSPN.Add_Click({
        if ($UI.LbSPNs.SelectedIndex -ge 0) { $UI.LbSPNs.Items.RemoveAt($UI.LbSPNs.SelectedIndex) }
    })

    #--- Tab 2: Create GMSA ---
    $UI.BtnCreateGMSA.Add_Click({
        # Validate inputs
        $nameErr = Test-GMSANameValid -Name $UI.TxtGMSAName.Text.Trim()
        if ($nameErr) { Show-ErrorBox $nameErr "Validation Error"; return }
        if ([string]::IsNullOrWhiteSpace($UI.TxtDNSSuffix.Text)) { Show-ErrorBox "DNS Host Suffix is required." "Validation Error"; return }
        $ouErr = Test-OUPathValid -Path $UI.TxtOUPath.Text.Trim()
        if ($ouErr) { Show-ErrorBox $ouErr "Validation Error"; return }

        $gmsaName = $UI.TxtGMSAName.Text.Trim()
        $principals = @($UI.LbPrincipals.Items)
        if ($UI.ChkAutoAddPC.Checked -and $env:COMPUTERNAME -notin $principals) {
            $principals += $env:COMPUTERNAME
        }

        if (-not (Show-ConfirmBox "Create GMSA account '$gmsaName'?`n`nDNS: $gmsaName.$($UI.TxtDNSSuffix.Text.Trim())`nPrincipals: $($principals -join ', ')" "Confirm Create GMSA")) { return }

        Set-UIBusy $true "Creating GMSA '$gmsaName'..."
        Write-GUILog "Creating GMSA: $gmsaName..." -Level Info -LogBox $log

        $dc   = if ($Script:ExecutionMode -eq 'Remote') { $UI.TxtDCHost.Text.Trim() } else { $null }
        $cred = if ($Script:ExecutionMode -eq 'Remote') { Get-FormCredential -Username $UI.TxtDCUser.Text.Trim() -PasswordBox $UI.TxtDCPass } else { $null }

        $params = @{
            Name                 = $gmsaName
            DNSSuffix            = $UI.TxtDNSSuffix.Text.Trim()
            Description          = $UI.TxtDescription.Text.Trim()
            PasswordIntervalDays = [int]$UI.NudPwdInterval.Value
            OUPath               = $UI.TxtOUPath.Text.Trim()
            AllowedPrincipals    = $principals
            SPNList              = @($UI.LbSPNs.Items)
            RemoteDC             = $dc
            Credential           = $cred
        }

        $worker = New-Object System.ComponentModel.BackgroundWorker
        $worker.Add_DoWork({ param($s,$e); $e.Result = New-GMSAAccount @($e.Argument) })
        $worker.Add_RunWorkerCompleted({
            param($s,$e)
            if ($e.Error) {
                Write-GUILog "Error: $($e.Error.Message)" -Level Error -LogBox $log
            } else {
                $r = $e.Result
                $lvl = if ($r.Success) { 'Success' } else { 'Error' }
                Write-GUILog $r.Message -Level $lvl -LogBox $log
                if ($r.Success) {
                    $UI.TxtInstGMSAName.Text = $UI.TxtGMSAName.Text.Trim()
                    Show-InfoBox "GMSA '$($UI.TxtGMSAName.Text.Trim())' created successfully!`n`nYou can now proceed to Tab 3 to install it on client machines." "GMSA Created"
                }
            }
            Set-UIBusy $false
        })
        $worker.RunWorkerAsync($params)
    })

    #--- Tab 2: Verify GMSA ---
    $UI.BtnVerifyGMSA.Add_Click({
        $name = $UI.TxtGMSAName.Text.Trim()
        if (-not $name) { Show-ErrorBox "Enter an account name to verify."; return }
        Set-UIBusy $true "Verifying GMSA '$name'..."
        Write-GUILog "Verifying GMSA: $name..." -Level Info -LogBox $log

        $dc   = if ($Script:ExecutionMode -eq 'Remote') { $UI.TxtDCHost.Text.Trim() } else { $null }
        $cred = if ($Script:ExecutionMode -eq 'Remote') { Get-FormCredential -Username $UI.TxtDCUser.Text.Trim() -PasswordBox $UI.TxtDCPass } else { $null }

        $worker = New-Object System.ComponentModel.BackgroundWorker
        $worker.Add_DoWork({ param($s,$e); $a=$e.Argument; $e.Result = Get-GMSAStatus -Name $a.Name -RemoteDC $a.DC -Credential $a.Cred })
        $worker.Add_RunWorkerCompleted({
            param($s,$e)
            if ($e.Error) {
                Write-GUILog "Verify error: $($e.Error.Message)" -Level Error -LogBox $log
            } else {
                $r = $e.Result
                if ($r.Success) {
                    Write-GUILog "GMSA Verification Results:" -Level Success -LogBox $log
                    Write-GUILog "  Name:             $($r.Name)" -Level Info -LogBox $log
                    Write-GUILog "  DNS Host Name:    $($r.DNSHostName)" -Level Info -LogBox $log
                    Write-GUILog "  Enabled:          $($r.Enabled)" -Level Info -LogBox $log
                    Write-GUILog "  Created:          $($r.Created)" -Level Info -LogBox $log
                    Write-GUILog "  Password Last Set: $($r.PasswordLastSet)" -Level Info -LogBox $log
                    Write-GUILog "  Allowed Principals: $($r.AllowedPrincipals)" -Level Info -LogBox $log
                    Write-GUILog "  SPNs:             $($r.SPNs)" -Level Info -LogBox $log
                    Write-GUILog "  DN:               $($r.DistinguishedName)" -Level Verbose -LogBox $log
                } else {
                    Write-GUILog $r.Message -Level Error -LogBox $log
                }
            }
            Set-UIBusy $false
        })
        $worker.RunWorkerAsync([PSCustomObject]@{ Name=$name; DC=$dc; Cred=$cred })
    })

    #--- Tab 3: Validate GMSA ---
    $UI.BtnValidateGMSA.Add_Click({
        $name = $UI.TxtInstGMSAName.Text.Trim()
        if (-not $name) { Show-ErrorBox "Enter a GMSA account name."; return }
        Write-GUILog "Looking up GMSA: $name..." -Level Info -LogBox $log
        $dc   = if ($Script:ExecutionMode -eq 'Remote') { $UI.TxtDCHost.Text.Trim() } else { $null }
        $cred = if ($Script:ExecutionMode -eq 'Remote') { $Script:RemoteCred } else { $null }
        $result = Get-GMSAStatus -Name $name -RemoteDC $dc -Credential $cred
        if ($result.Success) {
            Write-GUILog "GMSA '$name' found. Enabled: $($result.Enabled), DNSHostName: $($result.DNSHostName)" -Level Success -LogBox $log
        } else {
            Write-GUILog $result.Message -Level Error -LogBox $log
        }
    })

    #--- Tab 3: Computer list management ---
    $UI.BtnAddComputer.Add_Click({
        $name = $UI.TxtAddComputer.Text.Trim()
        if ($name) {
            $existing = $UI.LvComputers.Items | Where-Object { $_.Text -eq $name }
            if (-not $existing) {
                $item = New-Object System.Windows.Forms.ListViewItem($name)
                $item.SubItems.Add("Pending") | Out-Null
                $item.SubItems.Add("") | Out-Null
                $item.SubItems.Add("") | Out-Null
                $item.ForeColor = [System.Drawing.Color]::Gray
                [void]$UI.LvComputers.Items.Add($item)
                $UI.TxtAddComputer.Clear()
            }
        }
    })
    $UI.TxtAddComputer.Add_KeyDown({
        if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Return) { $UI.BtnAddComputer.PerformClick() }
    })

    $UI.BtnRemComputer.Add_Click({
        $toRemove = @($UI.LvComputers.SelectedItems)
        foreach ($item in $toRemove) { [void]$UI.LvComputers.Items.Remove($item) }
    })

    $UI.BtnClearComputers.Add_Click({
        if (Show-ConfirmBox "Clear all computers from the list?" "Confirm Clear") {
            $UI.LvComputers.Items.Clear()
        }
    })

    $UI.BtnImportCSV.Add_Click({
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Filter = "Text/CSV files (*.txt;*.csv)|*.txt;*.csv|All files (*.*)|*.*"
        $dlg.Title  = "Import Computer List"
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $lines = Get-Content $dlg.FileName | Where-Object { $_ -match '\S' } | ForEach-Object { $_.Split(',')[0].Trim() }
            $added = 0
            foreach ($line in $lines) {
                $existing = $UI.LvComputers.Items | Where-Object { $_.Text -eq $line }
                if (-not $existing) {
                    $item = New-Object System.Windows.Forms.ListViewItem($line)
                    $item.SubItems.Add("Pending") | Out-Null; $item.SubItems.Add("") | Out-Null; $item.SubItems.Add("") | Out-Null
                    $item.ForeColor = [System.Drawing.Color]::Gray
                    [void]$UI.LvComputers.Items.Add($item)
                    $added++
                }
            }
            Write-GUILog "Imported $added computers from $($dlg.FileName)" -Level Success -LogBox $log
        }
    })

    #--- Tab 3: Get install credential helper ---
    $getInstallCred = {
        if ($UI.RbInstallRemote.Checked -and -not $UI.ChkCurrentCreds.Checked) {
            return Get-FormCredential -Username $UI.TxtInstUser.Text.Trim() -PasswordBox $UI.TxtInstPass
        }
        return $null
    }

    #--- Tab 3: Install on Selected ---
    $UI.BtnInstallSelected.Add_Click({
        $name = $UI.TxtInstGMSAName.Text.Trim()
        if (-not $name) { Show-ErrorBox "Enter a GMSA account name."; return }
        $selected = @($UI.LvComputers.SelectedItems | ForEach-Object { $_.Text })
        if ($selected.Count -eq 0 -and $UI.RbInstallRemote.Checked) { Show-ErrorBox "Select at least one computer."; return }
        if ($UI.RbInstallLocal.Checked) { $selected = @('localhost') }

        Set-UIBusy $true "Installing GMSA on $($selected.Count) computer(s)..."
        Write-GUILog "Installing '$name' on: $($selected -join ', ')..." -Level Info -LogBox $log

        $isRemote = $UI.RbInstallRemote.Checked
        $cred = & $getInstallCred

        $worker = New-Object System.ComponentModel.BackgroundWorker
        $worker.Add_DoWork({
            param($s,$e)
            $a = $e.Argument
            Invoke-BatchInstall -ComputerList $a.Computers -GMSAName $a.Name -IsRemote $a.Remote `
                -Credential $a.Cred -MaxParallelJobs $a.MaxJobs -UseParallel $a.Parallel `
                -TestOnly $false -ResultsView $a.LV -LogBox $a.Log
        })
        $worker.Add_RunWorkerCompleted({ param($s,$e)
            if ($e.Error) { Write-GUILog "Install error: $($e.Error.Message)" -Level Error -LogBox $log }
            else { Write-GUILog "Install batch complete." -Level Success -LogBox $log }
            Set-UIBusy $false
        })
        $worker.RunWorkerAsync([PSCustomObject]@{
            Computers=$selected; Name=$name; Remote=$isRemote; Cred=$cred
            MaxJobs=[int]$UI.NudMaxJobs.Value; Parallel=$UI.ChkParallel.Checked
            LV=$UI.LvComputers; Log=$log
        })
    })

    #--- Tab 3: Test on Selected ---
    $UI.BtnTestSelected.Add_Click({
        $name = $UI.TxtInstGMSAName.Text.Trim()
        if (-not $name) { Show-ErrorBox "Enter a GMSA account name."; return }
        $selected = @($UI.LvComputers.SelectedItems | ForEach-Object { $_.Text })
        if ($selected.Count -eq 0 -and $UI.RbInstallRemote.Checked) { Show-ErrorBox "Select at least one computer."; return }
        if ($UI.RbInstallLocal.Checked) { $selected = @('localhost') }

        Set-UIBusy $true "Testing GMSA on $($selected.Count) computer(s)..."
        Write-GUILog "Testing '$name' on: $($selected -join ', ')..." -Level Info -LogBox $log

        $isRemote = $UI.RbInstallRemote.Checked
        $cred = & $getInstallCred

        $worker = New-Object System.ComponentModel.BackgroundWorker
        $worker.Add_DoWork({
            param($s,$e)
            $a = $e.Argument
            Invoke-BatchInstall -ComputerList $a.Computers -GMSAName $a.Name -IsRemote $a.Remote `
                -Credential $a.Cred -MaxParallelJobs $a.MaxJobs -UseParallel $a.Parallel `
                -TestOnly $true -ResultsView $a.LV -LogBox $a.Log
        })
        $worker.Add_RunWorkerCompleted({ param($s,$e)
            if ($e.Error) { Write-GUILog "Test error: $($e.Error.Message)" -Level Error -LogBox $log }
            else { Write-GUILog "Test batch complete." -Level Success -LogBox $log }
            Set-UIBusy $false
        })
        $worker.RunWorkerAsync([PSCustomObject]@{
            Computers=$selected; Name=$name; Remote=$isRemote; Cred=$cred
            MaxJobs=[int]$UI.NudMaxJobs.Value; Parallel=$UI.ChkParallel.Checked
            LV=$UI.LvComputers; Log=$log
        })
    })

    #--- Tab 3: Install + Test All ---
    $UI.BtnInstallTestAll.Add_Click({
        $name = $UI.TxtInstGMSAName.Text.Trim()
        if (-not $name) { Show-ErrorBox "Enter a GMSA account name."; return }
        $all = if ($UI.RbInstallLocal.Checked) {
            @('localhost')
        } else {
            @($UI.LvComputers.Items | ForEach-Object { $_.Text })
        }
        if ($all.Count -eq 0) { Show-ErrorBox "Add at least one computer to the list."; return }
        if (-not (Show-ConfirmBox "Install + Test '$name' on ALL $($all.Count) computer(s)?" "Confirm Install All")) { return }

        Set-UIBusy $true "Install+Test on $($all.Count) computer(s)..."
        Write-GUILog "Install+Test '$name' on $($all.Count) computer(s)..." -Level Info -LogBox $log

        $isRemote = $UI.RbInstallRemote.Checked
        $cred = & $getInstallCred

        $worker = New-Object System.ComponentModel.BackgroundWorker
        $worker.Add_DoWork({
            param($s,$e)
            $a = $e.Argument
            Invoke-BatchInstall -ComputerList $a.Computers -GMSAName $a.Name -IsRemote $a.Remote `
                -Credential $a.Cred -MaxParallelJobs $a.MaxJobs -UseParallel $a.Parallel `
                -TestOnly $false -ResultsView $a.LV -LogBox $a.Log
        })
        $worker.Add_RunWorkerCompleted({ param($s,$e)
            if ($e.Error) { Write-GUILog "Error: $($e.Error.Message)" -Level Error -LogBox $log }
            else { Write-GUILog "Install+Test All complete." -Level Success -LogBox $log }
            Set-UIBusy $false
        })
        $worker.RunWorkerAsync([PSCustomObject]@{
            Computers=$all; Name=$name; Remote=$isRemote; Cred=$cred
            MaxJobs=[int]$UI.NudMaxJobs.Value; Parallel=$UI.ChkParallel.Checked
            LV=$UI.LvComputers; Log=$log
        })
    })

    #--- Unhandled exception trap ---
    [System.Windows.Forms.Application]::add_ThreadException({
        param($s, $e)
        Write-GUILog "Unhandled exception: $($e.Exception.Message)" -Level Error -LogBox $log
    })
}
#endregion

#region Section 11: Entry Point

function Start-GMSAManager {
    if (-not (Test-IsAdmin)) {
        $choice = [System.Windows.Forms.MessageBox]::Show(
            "GMSA Manager should be run as Administrator for full functionality.`n`nContinue anyway?",
            "Administrator Required",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($choice -eq [System.Windows.Forms.DialogResult]::No) { return }
    }

    $UI = Build-MainForm
    Register-EventHandlers -UI $UI

    # Initial log greeting
    Write-GUILog "GMSA Manager started. User: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)" -Level Info -LogBox $UI.LogBox
    Write-GUILog "Computer: $env:COMPUTERNAME | PowerShell: $($PSVersionTable.PSVersion)" -Level Verbose -LogBox $UI.LogBox
    Write-GUILog "Start with Tab 1 - run prerequisite checks before creating GMSA accounts." -Level Info -LogBox $UI.LogBox

    [System.Windows.Forms.Application]::Run($UI.Form)
}

Start-GMSAManager
#endregion
