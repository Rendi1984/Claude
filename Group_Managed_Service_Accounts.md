# Group Managed Service Accounts (gMSA)

Group Managed Service Accounts (gMSA) are service accounts incapable of interactive logon. Their passwords are stored securely in Active Directory similarly to LAPS, and they can be used to run services or scheduled tasks. gMSA only work on Windows Server 2012 servers and newer.

## Usage

gMSA are tied to computer objects in AD. We will be using Security Groups that have these computer objects as members to delegate permissions between a gMSA and a set of computer objects where it would be used.

First, we will create the security group in question under the following context:

`<domain> > OUs > Groups > gMSA Groups`

The name of the group will describe the purpose of the service or the computers it is to be used on, followed by "gMSA Group" for easy filtering. We will add the computers the gMSA will be used on to this Security Group now.

Next, we will open a PowerShell window with a Domain Admin or Account Operator AD user and run the following command:

```powershell
New-ADServiceAccount -Name ServiceAccountName -DNSHostName ServiceAccountName.cc.co.il -PrincipalsAllowedToRetrieveManagedPassword "OurNewGroup gMSA Group"
```

**Example:**

```powershell
New-ADServiceAccount -Name s-adconnect -DNSHostName s-adconnect.cc.co.il -PrincipalsAllowedToRetrieveManagedPassword "ADConnect gMSA Group"
```

This will create our gMSA and tie it to the Security Group we have created earlier. We'll make sure to add the gMSA description in AD to detail its purpose before proceeding.

We could always check that the gMSA is connected properly to the correct Security Group via the following command:

```powershell
Get-ADServiceAccount ServiceAccountName -Properties * | select Name, PrincipalsAllowedToRetrieveManagedPassword
```

We'll need to wait a few minutes for the account to properly replicate, before proceeding to the computers we are intending to use the gMSA on.

There, we will confirm that the Active Directory PowerShell module is installed via the following PowerShell command on the computer in question:

```powershell
Get-WindowsFeature -Name RSAT-AD-PowerShell
```

If it is not installed, we will install it with the following command:

```powershell
Install-WindowsFeature -Name RSAT-AD-PowerShell
```

Finally, we will open a PowerShell window on the computer in question and run the following commands:

```powershell
Install-ADServiceAccount ServiceAccountName
Test-ADServiceAccount ServiceAccountName
```

The expected response for the Install command is that the command proceeds with no error messages. The expected response for the Test command is `True`.

**Example:**

```
PS U:\> Install-ADServiceAccount s-adconnect
PS U:\> Test-ADServiceAccount s-adconnect
True
```

When we no longer need to use the gMSA on a given computer, we can uninstall it with the following PowerShell command from the computer in question:

```powershell
Uninstall-ADServiceAccount -Identity ServiceAccountName
```

## Common Errors

### Install-ADServiceAccount

```
Install-ADServiceAccount : Cannot install service account. Error Message: '{Access Denied}
A process has requested access to an object, but has not been granted those access rights.'.
At line:1 char:1
+ Install-ADServiceAccount s-adconnect
+ ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    + CategoryInfo          : WriteError: (s-adconnect:String) [Install-ADServiceAccount], ADException
    + FullyQualifiedErrorId : InstallADServiceAccount:PerformOperation:InstallServiceAcccountFailure,Microsoft.ActiveD
   irectory.Management.Commands.InstallADServiceAccount
```

### Test-ADServiceAccount

```
WARNING: Test failed for Managed Service Account s-adconnect. If standalone Managed Service Account, the account is
linked to another computer object in the Active Directory. If group Managed Service Account, either this computer does
not have permission to use the group MSA or this computer does not support all the Kerberos encryption types required
for the gMSA. See the MSA operational log for more information.
```

Upon receiving errors, we will confirm that the computer in question is indeed a member of the security group linked to the gMSA. If everything is correct, we'll wait a bit longer before trying again.

---

If the gMSA installed and tested correctly, we are ready to use the gMSA on the server.

## Windows Service, IIS Application Pool and SQL Cluster 2014/2016

When used to run a Windows Service, the gMSA must be entered in the service we wish to run with the gMSA under the service's **Log On** tab in the following format:

```
<domain>\ServiceAccountName$
```

The `$` sign after the ServiceAccountName is necessary. The password field must also be kept blank.

Once the new credentials have been entered and saved, restart the service to confirm it is running properly.

This may also be done with PowerShell rather than via GUI.

Application Pools can be set up to run the same way, through the **Advanced Settings** of the desired Application Pool via IIS Manager.

For SQL Clusters, the gMSA should also be added to the SQL instances as a `sysadmin`.

## Scheduled Task

Unlike with setting up a service, this can only be done via PowerShell.

We will define the command/script the scheduled task will run, the time/frequency of the scheduled task and add the gMSA in question before creating our scheduled task.

The suggested format is as follows:

```powershell
$action = New-ScheduledTaskAction  "c:\scripts\script1.bat"
$trigger = New-ScheduledTaskTrigger -At 23:00 -Daily
$principal = New-ScheduledTaskPrincipal -UserID <domain>\ServiceAccountName$ -LogonType Password
Register-ScheduledTask myAdminTask –Action $action –Trigger $trigger –Principal $principal
```

The gMSA must have all necessary permissions on the computer to execute the scheduled task, which may require the "Log on as a batch job" right or membership in the local Administrators group.

> **Tip:** After the log on account of a service is set to a gMSA, the log on tab will be permanently unavailable (greyed out).
> To fix this, open an elevated Command Prompt and execute:
>
> ```
> sc managedaccount <ServiceName> false
> ```
