﻿#
# version 1.9 Derrick Cole, Snowflake Computing
#
# see co-located Revision-History.txt for additional information
#

<#
    .SYNOPSIS
    Extracts object DDL from a SQL Server instance.

    .DESCRIPTION
    Connects to an instance of SQL Server and, for each database/schema that survives inclusion/exclusion filters, retrieves object Data Definition Language (DDL) to files in a specified directory.

    .PARAMETER ServerInstance
    Specifies the instance to use.  Format is [[<server>]\[<named_instance>]] (i.e., \<named_instance>, <server>, <server>\<named_instance>, or not specified).  If not specified, use the default instance on the local server.

    .PARAMETER Port
    Specifies the port to use when connecting to <server>.  Overrides a <named_instance> if specified in -ServerInstance and forces -UseTcp.  Default is none.

    .PARAMETER UseTcp
    Specify whether to use the TCP format when connecting to -ServerInstance. Default is to not use TCP format.

    .PARAMETER UserName
    Specifies the user name to use with SQL Authentication.  If not specified, use the current user with Windows Authentication.

    .PARAMETER Password
    Specifies the password associated with -UserName (otherwise prompted interactively if -UserName is specified).

    .PARAMETER ScriptDirectory
    Specifies the root directory under which server-, instance-, database-, and object-related files are stored.  Default is 'C:\MyScriptsDirectory'.

    .PARAMETER IncludeDatabases
    Specifies which database(s) to include via a comma-delimited list of patterns (using PowerShell -match syntax).  Default is to include all databases other than SQL Server system databases.

    .PARAMETER ExcludeDatabases
    Specifies which database(s) to exclude via a comma-delimited list of patterns (using PowerShell -match syntax).  Default is to exclude none.

    .PARAMETER IncludeSchemas
    Specifies which schema(s) to include via a comma-delimited list of patterns (using PowerShell -match syntax).  Default is to include all.

    .PARAMETER ExcludeSchemas
    Specifies which schema(s) to exclude via a comma-delimited list of patterns (using PowerShell -match syntax).  Default is to exclude none.

    .PARAMETER IncludeSystemDatabases
    Specify whether to include SQL Server system databases prior to applying inclusion/exclusion filters.  Default is false.

    .PARAMETER ExistingDirectoryAction
    Specify whether to (non-interactively) 'delete' or 'keep' existing directories where encountered.  Default is to prompt interactively.

    .PARAMETER NoSysAdminAction
    Specify whether to (non-interactively) 'stop' or 'continue' when the -UserName does not have the sysadmin role on -ServerInstance.  Default is to prompt interactively.

    .INPUTS
    None.  You cannot pipe objects to this script.

    .OUTPUTS
    System.String.

    .NOTES
    It is HIGHLY RECOMMENDED that the user connecting to the instance have the sysadmin server role.  The script checks for this and warns if not the case, as errors or an incomplete extract may result.
    The database object types retrieved by this script are relative to SQL Server 2019.  Prior versions of SQL Server may produce a benign "can not find an overload for EnumObjects" error during extraction.  This can be ignored.
    The current version of this script does not support named pipe connections.

    .LINK
    For more information on the Microsoft SqlServer SMO assemblies used by this script, please visit: https://docs.microsoft.com/en-us/sql/relational-databases/server-management-objects-smo/installing-smo?view=sql-server-ver15

#>

[CmdletBinding(PositionalBinding=$false)]
param(
    [string]$ServerInstance = '(local)',
    [string]$Port = '',
    [switch]$UseTcp = $false,
    [string]$UserName = '',
    [string]$Password = '',
    [string]$ScriptDirectory = 'C:\MyScriptsDirectory',
    [string[]]$IncludeDatabases = '.*',
    [string[]]$ExcludeDatabases = ' ',
    [string[]]$IncludeSchemas = '.*',
    [string[]]$ExcludeSchemas = ' ',
    [switch]$IncludeSystemDatabases = $false,
    [ValidateSet('delete', 'keep')][string]$ExistingDirectoryAction,
    [ValidateSet('continue', 'stop')][string]$NoSysAdminAction
)

# initialize
set-psdebug -strict
$ErrorActionPreference = 'stop'
$version = 'v1.9'
$hostName = $env:COMPUTERNAME
$startTime = Get-Date
Write-Host "[ $($MyInvocation.MyCommand.Name) version $($version) on $($hostName), start time $($startTime) ]"

function Confirm-NextAction {
    param(
        [string]$prompt,
        [string]$first,
        [string]$second,
        [string]$action
    )
    $prompt = "Please enter action to take ['$($first)' or '$($second)']"
    if (!($action.ToLower() -eq $first -or $action.ToLower() -eq $second)) {
        While (!($action.ToLower() -eq $first -or $action.ToLower() -eq $second)) {
            $action = Read-Host -prompt $prompt
        }
    } else {
        Write-Host "$($prompt): $($action)"
    }
    return $action.ToLower()
}

function Confirm-ExistingDirectory {
    param(
        [string]$name
    )
    if (Test-Path -Path $name -PathType Container) {
        Write-Warning "Directory $($name) exists"
        if ((Confirm-NextAction -first 'delete' -second 'keep' -action $ExistingDirectoryAction) -eq 'delete') {
            try {
                Remove-Item -Path $name -Recurse
                Write-Host "Deleted directory '$($name)'"
            }
            catch {
                Write-Warning "Error deleting directory '$($name)': $_"
                Exit 1
            }
        }
    }
    if (!(Test-Path -Path $name -PathType Container)) {
        try {
            $null = New-Item -Path $name -ItemType Directory -Force
            Write-Host "Created directory '$($name)'"
        }
        catch {
            Write-Warning "Error creating directory '$($name)': $_"
            Exit 1
        }
    }
}

function Get-Param {
    param(
        [string]$name,
        [string]$prompt,
        [switch]$isPassword = $false
    )
    if ($name.Length -eq 0) {
        switch($isPassword) {
            $true {
                $secureString = Read-Host -Prompt $prompt -AsSecureString
                $name = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureString))
            }
            $false { $name = Read-Host -Prompt $prompt }
        }
    }
    return $name
}

# check powershell version
$minimumPowerShellVersionNumber = 5
switch($PSVersionTable.PSVersion.Major -ge $minimumPowerShellVersionNumber) {
    $true { Write-Host "PowerShell $($PSVersionTable.PSVersion) installed." }
    $false {
        Write-Warning "PowerShell $($minimumPowerShellVersionNumber).0 or later required."
        Exit 1
    }
}

# load required assemblies
$requiredModule = "SqlServer"
$requiredAssemblies = @(
    "Smo",
    "ConnectionInfo",
    "SqlClrProvider",
    "Management.Sdk.Sfc",
    "SqlEnum",
    "Dmf.Common"
)
try {
    foreach ($requiredAssembly in $requiredAssemblies) {
        if ($null -eq [System.Reflection.Assembly]::LoadWithPartialName("Microsoft.$($requiredModule).$($requiredAssembly)")) { throw }
    }
    Write-Host "Required assemblies loaded."
}
catch {
    Write-Warning "Required assemblies not loaded."
    Write-Host @"
As PowerShell Administrator, please execute the following on $($hostname):

"@
    if ($null -eq (Get-Module -ListAvailable -Name $requiredModule)) {
        Write-Host @"
    # answer 'Y' in response to any prompts received
    Install-Module -Name $($requiredModule) -AllowClobber

"@
    }
    Write-Host @"
    # ensure the required $($requiredModule) assemblies are published to the Global Assembly Cache
    `$requiredAssemblies = @("$($requiredAssemblies -Join '", "')")
    `$modulePath = [System.IO.Path]::GetDirectoryName((Get-Module -ListAvailable -Name $($requiredModule)).Path)
    [System.Reflection.Assembly]::LoadWithPartialName("System.EnterpriseServices") | Out-Null
    `$publish = New-Object System.EnterpriseServices.Internal.Publish
    Foreach (`$requiredAssembly in `$requiredAssemblies) { `$publish.GacInstall("`$(`$modulePath)\Microsoft.$($requiredModule).`$(`$requiredAssembly).dll") }

Once the above action(s) are executed successfully on $($hostname) as PowerShell Administrator, please open a new PowerShell session on $($hostname) and re-execute the extraction script.
"@
    Write-Warning "If circumstances prevent taking any of the above action(s) on devices like $($hostname), the extraction script must be executed on a device running SQL Server."
    Exit 1
}

# initiate a (TCP) connection to (specified/unspecified) port else to (default/named) instance on (local/remote) server using (Windows/SQL) authentication
$serverName, $instanceName = $ServerInstance.split('\')
if ($serverName.length -eq 0) { $serverName = '(local)' }
if ('' -ne $Port) { $UseTcp = $true }
$connectionString = @{
    "Data Source" = "$(if ($UseTcp) { 'tcp:' } else { '' })$($serverName)$(if ('' -ne $Port) { ",$($Port)" } elseif ($instanceName.length -gt 0) { "\$($instanceName)" } else { '' })"
    "Integrated Security" = "True"
    "Persist Security Info" = "False"
    "MultipleActiveResultSets" = "False"
    "Encrypt" = "False"
    "TrustServerCertificate" = "False"
    "Connection Timeout" = "30"
}
if ($UserName) {
    $connectionString["Integrated Security"] = "False"
    $connectionString["User ID"] = $UserName
    $connectionString["Password"] = Get-Param -name $Password -prompt "Please enter the password for '$($UserName)'" -isPassword
}
$connectionString = ($connectionString.GetEnumerator() | Foreach-Object { "$($_.Key)=$($_.Value)" }) -Join ";"
if ($serverName -in '(local)', '.') { $serverName = $hostName }
if ($instanceName.length -eq 0) { $instanceName = "MSSQLSERVER" }
$ServerInstance = "$($serverName)\$($instanceName)"
try {
    $sqlConnection = New-Object System.Data.SqlClient.SqlConnection $connectionString
    $serverConnection = New-Object Microsoft.SqlServer.Management.Common.ServerConnection $sqlConnection
    $server = New-Object Microsoft.SqlServer.Management.Smo.Server $serverConnection
    switch($null -ne $server.Version) {
        $true { Write-Host "Connected to '$($serverName)' (version $($server.Version))." }
        $false { throw "Not connected to '$($serverName)'" }
    }
}
catch {
    Write-Warning $_
    Exit 1
}

# check user role on server
$sysadmin = "sysadmin"
try {
    $sqlCommand = New-Object System.Data.SqlClient.SqlCommand
    $sqlCommand.Connection = $sqlConnection
    $sqlCommand.CommandText = "select is_srvrolemember('$($sysadmin)')"
    $sqlCommand.CommandTimeout = 0
    $isSrvRoleMember = $sqlCommand.ExecuteReader()
    if ($isSrvRoleMember.Read()) {
        switch(1 -eq $isSrvRoleMember.GetValue(0)) {
            $true { Write-Host "User has '$($sysadmin)' role on instance '$($ServerInstance)'." }
            $false {
                Write-Warning "User does not have '$($sysadmin)' role on instance '$($ServerInstance)'.  Extraction may be incomplete and/or errors may occur."
                if ((Confirm-NextAction -first 'stop' -second 'continue' -action $NoSysAdminAction) -eq 'stop') { Exit 1 }
            }
        }
    } else {
        throw
    }
}
catch {
    Write-Warning "Unable to obtain role memberships for user from instance '$($ServerInstance)'.  Extraction may be incomplete and/or errors may occur."
    if ((Confirm-NextAction -first 'stop' -second 'continue' -action $NoSysAdminAction) -eq 'stop') { Exit 1 }
}
finally {
    $sqlCommand.Connection.Close()
}

# initialize scripter
try {
    $scripter = New-Object Microsoft.SqlServer.Management.Smo.Scripter $serverConnection
    $scripter.Options.ToFileOnly = $true
    $scripter.Options.AppendToFile = $true
    $scripter.Options.DRIAll = $true
    $scripter.Options.Indexes = $true
    $scripter.Options.Triggers = $true
    $scripter.Options.ScriptBatchTerminator = $true
    $scripter.Options.ExtendedProperties = $true
    Write-Host "Scripter object initialized."
}
catch {
    Write-Warning "Error initializing scripter object: $_"
    Exit 1
}

# set up initial directories
Confirm-ExistingDirectory -name $ScriptDirectory
Confirm-ExistingDirectory -name ($instanceDirectory = "$($ScriptDirectory)\$($serverName)\$($instanceName)")

# save server summary
[PSCustomObject]@{
    "Script Version" = $version
    "Run Date" = $startTime
    "Server" = $serverName
    "Instance" = $instanceName
    "Version" = $server.Version
    "Product Level" = $server.ProductLevel
    "Update Level" = $server.UpdateLevel
    "Host Platform" = $server.HostPlatform
    "Host Distribution" = $server.HostDistribution
} | Export-Csv -Path "$($ScriptDirectory)\server_summary.csv" -NoTypeInformation -Append

# get databases
if ($server.Databases.Count -gt 0) {
    $databases = $server.Databases | Where-Object { ($_.Name -match ($IncludeDatabases -Join "|")) -and (!$_.IsSystemObject -or $IncludeSystemDatabases) -and ($_.Name -notmatch ($ExcludeDatabases -Join "|")) }
    if ($databases.Count -eq 0) {
        Write-Warning "Existing databases on '$($ServerInstance)' did not survive specified inclusion/exclusion criteria."
        Exit 1
    }
} else {
    Write-Warning "No databases found on '$($ServerInstance)'."
    Exit 1
}

function Get-DatabaseObjectDdl {
    param(
        [object[]]$objects,
        [string]$type,
        [switch]$isTableType = $false
    )

    try {
        $objectsToProcess = $objects |
            Where-Object { !($_.Name[0] -eq "#") } |
            Where-Object { !($_.DatabaseObjectTypes -eq "Schema" -and ($_.Name -eq "sys" -or $_.Name -eq "INFORMATION_SCHEMA")) } |
            Where-Object { !($_.Schema -eq "sys" -or $_.Schema -eq "INFORMATION_SCHEMA") } |
            Where-Object { $_.Schema -match ($IncludeSchemas -Join "|") -and $_.Schema -notmatch ($ExcludeSchemas -Join "|") }
        if ($objectsToProcess.Count -eq 0) { throw "No objects of type '$($type)' found in database '$($database.Name)'" }

        # start with fresh extraction of this database object type
        $urnCollection = New-Object Microsoft.SqlServer.Management.Smo.UrnCollection
        $scripterFile = "$($databaseDirectory)\DDL_$($type).sql"
        Remove-Item -Path $scripterFile -ErrorAction Ignore
        $scripter.Options.Filename = $scripterFile

        $objectsProcessed = 0
        $objectsEncrypted = 0
        $objectsErrored = 0
        foreach ($object in $objectsToProcess) {
            try {
                $encrypted = $object.IsEncrypted -or $false
                $ddlFile = if ($encrypted) { $null } else { $scripterFile }

                # save object summary
                [PSCustomObject]@{
                    "Script Version" = $version
                    "Run Date" = $startTime
                    "Server" = $serverName
                    "Instance" = $instanceName
                    "Database" = $database.Name
                    "Schema" = $object.Schema
                    "Name" = $object.Name
                    "Type" = $type
                    "Encrypted" = $encrypted
                    "DDL File" = $ddlFile
                } | Export-Csv -Path "$($ScriptDirectory)\object_inventory.csv" -NoTypeInformation -Append

                switch($encrypted) {
                    $true {
                        $objectsEncrypted += 1
                        Write-Warning "object '$($database.Name).$($object.Schema).$($object.Name)' encrypted, not retrieved"
                    }
                    $false {
                        if ($isTableType) {

                            # save table summary
                            [PSCustomObject]@{
                                "Script Version" = $version
                                "Run Date" = $startTime
                                "Server" = $serverName
                                "Instance" = $instanceName
                                "Database" = $database.Name
                                "Schema" = $object.Schema
                                "Name" = $object.Name
                                "Data Space Used (KB)" = $object.DataSpaceUsed
                                "Index Space Used (KB)" = $object.IndexSpaceUsed
                                "Row Count" = $object.RowCount
                            } | Export-Csv -Path "$($ScriptDirectory)\table_summary.csv" -NoTypeInformation -Append
                        }

                        $urnCollection.add($object.urn)
                        $objectsProcessed += 1
                    }
                }
            }
            catch {
                $objectsErrored += 1
                Write-Warning $_
            }
        }
        if ($objectsProcessed -gt 0) {
            $scripter.script($urnCollection)
        }
        Write-Host "Retrieved $($objectsProcessed) of $($objectsToProcess.Count) object(s) of type '$($type)' ($($objectsEncrypted) encrypted, $($objectsErrored) errors) from database '$($database.Name)'"
        $global:totalObjectsProcessed += $objectsProcessed
        $global:totalObjectsEncrypted += $objectsEncrypted
        $global:totalObjectsErrored += $objectsErrored
        $global:totalObjectsToProcess += $objectsToProcess.Count
        if ($isTableType) {
            $global:totalTablesProcessed += $objectsProcessed
            $global:totalTablesToProcess += $objectsToProcess.Count
        }
    }
    catch {
        Write-Warning $_
    }
}

# iterate over databases
$databasesProcessed = 0
$global:totalObjectsProcessed = 0
$global:totalObjectsEncrypted = 0
$global:totalObjectsErrored = 0
$global:totalObjectsToProcess = 0
$global:totalTablesProcessed = 0
$global:totalTablesToProcess = 0
foreach ($database in $databases) {
    try {

        # set up this database directory
        Confirm-ExistingDirectory -name ($databaseDirectory = "$($instanceDirectory)\$($database.Name)")

        # save this database summary
        [PSCustomObject]@{
            "Script Version" = $version
            "Run Date" = $startTime
            "Server" = $serverName
            "Instance" = $instanceName
            "Database" = $database.Name
            "Size (MB)" = $database.Size
            "Data Space Usage (KB)" = $database.DataSpaceUsage
            "Index Space Usage (KB)" = $database.IndexSpaceUsage
            "Space Available (KB)" = $database.SpaceAvailable
        } | Export-Csv -Path "$($ScriptDirectory)\database_summary.csv" -NoTypeInformation -Append
        Write-Host "Retrieved summary information for database '$($database.Name)'"

        # get object types
        Get-DatabaseObjectDdl -objects $database.Roles -type DatabaseRole
        Get-DatabaseObjectDdl -objects $database.ExtendedStoredProcedures -type ExtendedStoredProcedure
        Get-DatabaseObjectDdl -objects $database.ExternalDataSources -type ExternalDataSource
        Get-DatabaseObjectDdl -objects $database.ExternalFileFormats -type ExternalFileFormat
        Get-DatabaseObjectDdl -objects $database.ExternalLibraries -type ExternalLibrary
        Get-DatabaseObjectDdl -objects $database.Sequences -type Sequence
        Get-DatabaseObjectDdl -objects $database.Synonyms -type Synonym
        Get-DatabaseObjectDdl -objects $database.Schemas -type Schema
        Get-DatabaseObjectDdl -objects $database.StoredProcedures -type StoredProcedure
        Get-DatabaseObjectDdl -objects $database.Tables -type Table -isTableType
        Get-DatabaseObjectDdl -objects $database.UserDefinedAggregates -type UserDefinedAggregate
        Get-DatabaseObjectDdl -objects $database.UserDefinedDataTypes -type UserDefinedDataType
        Get-DatabaseObjectDdl -objects $database.UserDefinedFunctions -type UserDefinedFunction
        Get-DatabaseObjectDdl -objects $database.UserDefinedTableTypes -type UserDefinedTableType
        Get-DatabaseObjectDdl -objects $database.UserDefinedTypes -type UserDefinedType
        Get-DatabaseObjectDdl -objects $database.Views -type View

        $databasesProcessed += 1
    }
    catch {
        Write-Warning $_
    }
}

$endTime = Get-Date
Write-Host "[ $($MyInvocation.MyCommand.Name) processed $($databasesProcessed) out of $($databases.Count) databases on instance '$($ServerInstance)' in $(New-TimeSpan -Start $startTime -End $endTime) ]"
Write-Host "[ $($global:totalObjectsProcessed) of $($global:totalObjectsToProcess) total database objects retrieved ($($global:totalObjectsEncrypted) encrypted, $($global:totalObjectsErrored) errors) ]"
Write-Host "[ $($global:totalTablesProcessed) of $($global:totalTablesToProcess) total tables retrieved ]"

exit 0