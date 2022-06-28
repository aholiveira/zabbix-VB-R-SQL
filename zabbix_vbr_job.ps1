<#
.SYNOPSIS
Query Veeam job information
This script is intended for use with Zabbix > 6.X

.DESCRIPTION
Query Veeam job information
This script is intended for use with Zabbix > 6.X
It uses SQL queries to the Veeam database to obtain the information
Please change the values of the variables below to match your configuration

You can create the user with SQL Server Management Studio (SSMS) or with sqlcmd.exe.
Using SSMS GUI, create a new SQL user, add it to veeam's database and assign it to db_datareader role.
Alternatively, you can run the following query in either of them to create the user and grant it appropriate rights.
Change password "CHANGEME" with something more secure.

USE [VeeamBackup]
CREATE LOGIN [zabbixveeam] WITH PASSWORD = N'CHANGEME', CHECK_POLICY = OFF, CHECK_EXPIRATION = OFF;
CREATE USER [zabbixveeam] FOR LOGIN [zabbixveeam];
EXEC sp_addrolemember 'db_datareader', 'zabbixveeam';
GO

.INPUTS
The script takes an unnamed single argument which specifies the information to supply
RepoInfo - Get repository information
JobsInfo - Get job information
TotalJob - The number of Veeam active jobs 

.OUTPUTS
None. Information is directly sent to Zabbix agent using zabbix_sender.exe

.EXAMPLE
zabbix_vbr_jobs.ps1 RepoInfo

Description
---------------------------------------
Gets information about Veeam repository

.EXAMPLE
zabbix_vbr_jobs.ps1 JobsInfo

Description
---------------------------------------
Gets information about Veeam jobs

.EXAMPLE
zabbix_vbr_jobs.ps1 TotalJob

Description
---------------------------------------
Sends total number of active Veeam jobs to Zabbix

.NOTES
Created by   : Romainsi   https://github.com/romainsi
Contributions: aholiveira https://github.com/aholiveira
               xtonousou  https://github.com/xtonousou
Version      : 2.6

.LINK
https://github.com/romainsi/zabbix-VB-R-SQL

#>
########### Adjust the following variables to match your configuration ###########
$veeamserver = 'veeam.contoso.local'   # Machine name where Veeam is installed
$SQLServer = 'sqlserver.contoso.local' # Database server where Veeam database is located. Change to sqlserver.contoso.local\InstanceName if you are running an SQL named instance
$SQLIntegratedSecurity = $false        # Use Windows integrated security?
$SQLuid = 'zabbixveeam'                # SQL Username when using SQL Authentication - ignored if using Integrated security
$SQLpwd = 'CHANGEME'                   # SQL user password
$SQLveeamdb = 'VeeamBackup'            # Name of Veeam database. VeeamBackup is the default

<#
Supported job types.
You can add additional types by extending the variables below
Look into Veeam database table [BJobs] to find more job types
Both variables below should be changed otherwise the script might fail
If using version 2.0 or higher of the Zabbix template new types added here are automatically used in Zabbix
If you extend this, please inform the author so that the script can be extended
#>

# $jobtypes is used in SQL queries
$jobTypes = "(0, 1, 2, 28, 51, 63, 4030, 12002, 12003)"

# $typeNames is used in Get-JobInfo function the send the type name to Zabbix
$typeNames = @{
    0     = "Job";
    1     = "Replication";
    2     = "File";
    28    = "Tape";
    51    = "Sync";
    63    = "Copy";
	4030  = "RMAN"
    12002 = "Agent backup policy";
    12003 = "Agent backup job";
}

########### DO NOT MODIFY BELOW ###########

<#
.SYNOPSIS
Build and return a SQL connection string
It uses the variables defined at the top of the script

.INPUTS
None. The function uses the variables defined at the top of the script

.OUTPUTS
System.String. A SQL connection string
#>
function Get-ConnectionString() {
    $builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $builder.Add("Data Source", $SQLServer)
    $builder.Add("Integrated Security", $SQLIntegratedSecurity)
    $builder.Add("Initial Catalog", $SQLveeamdb)
    $builder.Add("User Id", $SQLuid)
    $builder.Add("Password", $SQLpwd)

    return $builder.ConnectionString
}

<#
.SYNOPSIS
Opens a connection to the database
Retries if unsucessfull on the first try

.INPUTS
None

.OUTPUTS
System.String. A SQL connection string
#>
function Start-Connection() {
    $connectionString = Get-ConnectionString

    # Create a connection to MSSQL
    $connection = New-Object System.Data.SqlClient.SqlConnection
    $connection.ConnectionString = $connectionString
    $connection.Open()
    if ($connection.State -notmatch "Open") {
        # Connection open failed. Wait and retry connection
        Start-Sleep -s 5
        $connection = New-Object System.Data.SqlClient.SqlConnection
        $connection.ConnectionString = $connectionString
        $connection.Open()
    }
    return $connection
}

<#
.SYNOPSIS
Runs a query against the database given the supplied query string

.PARAMETER Command
Query string to run

.INPUTS
None

.OUTPUTS
System.Data.DataTable. A datatable object on success or $null on failure
#>
function Get-SqlCommand {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [System.String]$Command
    )

    $Connection = $null
    # Use try-catch to avoid exceptions if connection to SQL cannot be opened or data cannot be read
    # It either returns the data read or $null on failure
    try {
        $Connection = Start-Connection
        $SqlCmd = New-Object System.Data.SqlClient.SqlCommand
        $SqlCmd.CommandText = $Command
        $SqlCmd.Connection = $Connection
        $SqlCmd.CommandTimeout = 0
        $SqlAdapter = New-Object System.Data.SqlClient.SqlDataAdapter
        $SqlAdapter.SelectCommand = $SqlCmd
        $DataSet = New-Object System.Data.DataSet
        $SqlAdapter.Fill($DataSet)
        $retval = $DataSet.Tables[0]
    }
    catch {
        $retval = $null
        # We output the error message. This gets sent to Zabbix.
        Write-Host $_.Exception.Message
    }
    finally {
        # Make sure the connection is closed
        if ($null -ne $Connection) {
            $Connection.Close()
        }
    }
    return $retval
}

<#
.SYNOPSIS
Convert to unix timestamp - Seconds elapsed since unix epoch

.PARAMETER date
System.DateTime. The reference date to convert to unix timestamp

.INPUTS
None

.OUTPUTS
System.Int. The converted date to unix timestamp or -1 if date was before the epoch
#>
function ConvertTo-Unixtimestamp {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [System.DateTime]$date
    )
    # Unix epoch
    [System.DateTime]$unixepoch = (get-date -date "01/01/1970 00:00:00Z")

    # Handle empty dates
    # We make this one second less than $unixepoch.
    # This makes the time calculations below return -1 to Zabbix, making the item "unsupported" while the job is running (or before it ran for the first time)
    if ($null -eq $date -or $date -lt $unixepoch) {
        $date = $unixepoch.AddSeconds(-1);
    }

    # Return the seconds elapsed between the reference date and the epoch
    return [int]((New-TimeSpan -Start $unixepoch -end $date).TotalSeconds)
}

<#
.SYNOPSIS
Builds an object with the information for each job

.PARAMETER item
System.String. An object containing job information

.PARAMETER backupsessions
System.Object. An object containing job session information

.INPUTS
None

.OUTPUTS
System.Object. An object with the job information with the tags used by the Zabbix template
#>
function Get-JobInfo {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [System.String]$jobname,
        [Parameter(Mandatory = $true)]
        [System.Object]$backupsessions
    )

    $Object = $null

    # Get last job session
    $lastsession = $backupsessions | Where-Object { $_.job_name -eq $jobname } | Sort-Object creation_time -Descending | Select-Object -First 1

    # Return $null if there is no session data
    if (!$lastsession) { 
        return $Object 
    }

    # Get reason for the job failure/warning
    # We get all jobs reasons from both table column and log_xml
    $Log = (([Xml]$lastsession.log_xml).Root.Log | Where-Object { $_.Status -eq 'EFailed' }).Title
    $reason = $lastsession.reason
    foreach ($logreason in $Log) {
        $reason += "`r`n$logreason"
    }

    # Build the output object
    $Object = New-Object System.Object
    $Object | Add-Member -type NoteProperty -Name JOBID -Value $lastsession.job_id
    $Object | Add-Member -type NoteProperty -Name JOBTYPEID -Value $lastsession.job_type
    $Object | Add-Member -type NoteProperty -Name JOBTYPENAME -Value $typeNames[$lastsession.job_type]
    $Object | Add-Member -type NoteProperty -Name JOBNAME -Value ([System.Net.WebUtility]::HtmlEncode($lastsession.job_name))
    $Object | Add-Member -type NoteProperty -Name JOBRESULT -Value $lastsession.result
    $Object | Add-Member -type NoteProperty -Name JOBRETRY -Value $lastsession.is_retry
    $Object | Add-Member -type NoteProperty -Name JOBREASON -Value ([System.Net.WebUtility]::HtmlEncode($reason))
    $Object | Add-Member -type NoteProperty -Name JOBPROGRESS -Value $lastsession.progress
    $Object | Add-Member -type NoteProperty -Name JOBSTART -Value (ConvertTo-Unixtimestamp $lastsession.creation_time.ToUniversalTime())
    $Object | Add-Member -type NoteProperty -Name JOBEND -Value (ConvertTo-Unixtimestamp $lastsession.end_time.ToUniversalTime())

    return $Object
}

<#
.SYNOPSIS
Queries Veeam's database to obtain information about all supported job types.

.INPUTS
None

.OUTPUTS
Job information in JSON format
#>
function Get-AllJobsInfo() {
    # Get backup jobs session information
    $BackupSessions = Get-SqlCommand -Command "SELECT * FROM [VeeamBackup].[dbo].[Backup.Model.JobSessions] 
        INNER JOIN [VeeamBackup].[dbo].[Backup.Model.BackupJobSessions] 
        ON [VeeamBackup].[dbo].[Backup.Model.JobSessions].[id] = [VeeamBackup].[dbo].[Backup.Model.BackupJobSessions].[id]
        WHERE job_type IN $jobTypes 
        ORDER BY creation_time DESC, job_type, job_name"

    # Get all active jobs
    $BackupJobs = Get-SqlCommand -Command "SELECT name, options FROM [VeeamBackup].[dbo].[JobsView] WHERE [Schedule_Enabled] = 'true' AND [type] IN $jobTypes ORDER BY [type], [name]"

    $return = @()
    # Get information for each active job
    foreach ($job in $BackupJobs) {
        if (([Xml]$job.options).JobOptionsRoot.RunManually -eq "False") {
            $jobinfo = Get-JobInfo -jobname $job.Name -backupsessions $BackupSessions
            $return += ($jobinfo)
        }
    }

    # Convert data to JSON
    $return = ConvertTo-Json -Compress -InputObject @($return)
    Write-Output $return
}

<#
.SYNOPSIS
Queries WIM to obtain Veeam's repository information

.INPUTS
None

.OUTPUTS
Repository information in JSON format
#>
function Get-RepoInfo() {

    # Get data from WIM class
    $repoinfo = Get-CimInstance -Class Repository -ComputerName $veeamserver -Namespace ROOT\VeeamBS

    $return = @()
    # Build the output object
    foreach ($item in $repoinfo) {
        $Object = New-Object System.Object
        $Object | Add-Member -type NoteProperty -Name REPONAME -Value ([System.Net.WebUtility]::HtmlEncode($item.NAME)) 
        $Object | Add-Member -type NoteProperty -Name REPOCAPACITY -Value $item.Capacity
        $Object | Add-Member -type NoteProperty -Name REPOFREE -Value $item.FreeSpace
        $Object | Add-Member -type NoteProperty -Name REPOOUTOFDATE -Value $item.OutOfDate
        $return += $Object
    }

    # Convert data to JSON
    $return = ConvertTo-Json -Compress -InputObject @($return)
    Write-Output $return
}

<#
.SYNOPSIS
Main program
Gets the requested information from Veeam

.INPUTS
None

.OUTPUTS
Requested data in JSON format to be ingested by Zabbix
In case of an error a message is printed to standard output
#>
switch ([string]$args[0]) {
    "RepoInfo" {
        Get-RepoInfo
    }
    "JobsInfo" {
        Get-AllJobsInfo
    }
    "TotalJob" {
        $BackupJobs = Get-SqlCommand -Command "SELECT jobs.name FROM [VeeamBackup].[dbo].[JobsView] jobs WHERE [Schedule_Enabled] = 'true' AND [type] IN $jobTypes"
        if ($null -ne $BackupJobs) {
            Write-Host $BackupJobs.Rows.Count
        }
    }
    default {
        Write-Output "-- ERROR -- : Need an option  !"
        Write-Output "Valid options are: RepoInfo, JobsInfo or TotalJob"
        Write-Output "This script is not intended to be run directly but called by Zabbix."
    }
}
