﻿function ConvertTo-DbaXESession {
    <#
        .SYNOPSIS
        Uses a slightly modified version of sp_SQLskills_ConvertTraceToExtendedEvents.sql to convert Traces to Extended Events

        .DESCRIPTION
        Uses a slightly modified version of sp_SQLskills_ConvertTraceToExtendedEvents.sql to convert Traces to Extended Events

        T-SQL code by: Jonathan M. Kehayias, SQLskills.com. T-SQL can be found in this module directory and at
        https://www.sqlskills.com/blogs/jonathan/converting-sql-trace-to-extended-events-in-sql-server-2012/

        .PARAMETER InputObject
        Piped input from Get-DbaTrace

        .PARAMETER Name
        The name of the Trace - if the name exists, extra characters will be appended

        .PARAMETER OutputScriptOnly
        Output the script in plain-ol T-SQL instead of executing it

        .PARAMETER EnableException
        By default, when something goes wrong we try to catch it, interpret it and give you a friendly warning message.
        This avoids overwhelming you with "sea of red" exceptions, but is inconvenient because it basically disables advanced scripting.
        Using this switch turns this "nice by default" feature off and enables you to catch exceptions with your own try/catch.

        .NOTES
        Tags: Trace, ExtendedEvent
        Website: https://dbatools.io
        Copyright: (C) Chrissy LeMaire, clemaire@gmail.com
        License: GNU GPL v3 https://opensource.org/licenses/GPL-3.0

        .EXAMPLE
        Get-DbaTrace -SqlInstance sql2017, sql2012 | Where Id -eq 2 | ConvertTo-DbaXESession -Name 'Test'

        Converts Trace with ID 2 to a Session named Test on SQL Server instances named sql2017 and sql2012
        and creates the Session on each respective server

       .EXAMPLE
        Get-DbaTrace -SqlInstance sql2014 | Out-GridView -PassThru | ConvertTo-DbaXESession -Name 'Test' | Start-DbaXESession

        Converts selected traces on sql2014 to sessions, creates the session and starts it

        .EXAMPLE
        Get-DbaTrace -SqlInstance sql2014 | Where Id -eq 1 | ConvertTo-DbaXESession -Name 'Test' -OutputScriptOnly

        Converts trace ID 1 on sql2014 to an Extended Event and outputs the resulting T-SQL
#>
    [CmdletBinding()]
    Param (
        [parameter(Mandatory, ValueFromPipeline)]
        [object[]]$InputObject,
        [parameter(Mandatory)]
        [string]$Name,
        [switch]$OutputScriptOnly,
        [switch]$EnableException
    )
    begin {
        $createsql = Get-Content "$script:PSModuleRoot\bin\sp_SQLskills_ConvertTraceToEEs.sql" -Raw
        $dropsql = "IF OBJECT_ID('sp_SQLskills_ConvertTraceToExtendedEvents') IS NOT NULL DROP PROCEDURE sp_SQLskills_ConvertTraceToExtendedEvents;"
    }
    process {
        foreach ($trace in $InputObject) {
            if (-not $trace.id -and -not $trace.Parent) {
                Stop-Function -Message "Input is of the wrong type. Use Get-DbaTrace." -Continue
                return
            }

            $server = $trace.Parent

            if ($server.VersionMajor -lt 11) {
                Stop-Function -Message "SQL Server version 2012+ required - $server not supported."
                return
            }

            $tempdb = $server.Databases['tempdb']
            $traceid = $trace.id

            if ((Get-DbaXESession -SqlInstance $server -Session $PSBoundParameters.Name)) {
                $oldname = $name
                $Name = "$name-$traceid"
                Write-Message -Level Output -Message "XE Session $oldname already exists on $server, trying $name"
            }

            if ((Get-DbaXESession -SqlInstance $server -Session $Name)) {
                $oldname = $name
                $Name = "$name-$(Get-Random)"
                Write-Message -Level Output -Message "XE Session $oldname already exists on $server, trying $name"
            }

            $executesql = "sp_SQLskills_ConvertTraceToExtendedEvents @traceid = $traceid, @sessionname = [$Name]"

            try {
                # I attempted to make this a straightforward query but then ended up
                # changing the script too much, so decided to drop/create/drop in tempdb
                Write-Message -Level Verbose -Message "Dropping sp_SQLskills_ConvertTraceToExtendedEvents from tempdb if it exists"
                $null = $tempdb.Query($dropsql)
                Write-Message -Level Verbose -Message "Creating sp_SQLskills_ConvertTraceToExtendedEvents in tempdb"
                $null = $tempdb.Query($createsql)
                Write-Message -Level Verbose -Message "Executing $executesql from tempdb"
                $results = $tempdb.ExecuteWithResults($executesql).Tables.Rows.SqlString
                Write-Message -Level Verbose -Message "Dropping sp_SQLskills_ConvertTraceToExtendedEvents from tempdb"
                $null = $tempdb.Query($dropsql)
            }
            catch {
                Stop-Function -Message "Issue creating, dropping or executing sp_SQLskills_ConvertTraceToExtendedEvents in tempdb on $server" -Target $server -ErrorRecord $_
            }

            $results = $results -join "`r`n"

            if ($OutputScriptOnly) {
                $results
            }
            else {
                Write-Message -Level Verbose -Message "Creating XE Session $name"
                try {
                    $tempdb.ExecuteNonQuery($results)
                }
                catch {
                    Stop-Function -Message "Issue creating extended event $name on $server" -Target $server -ErrorRecord $_
                }
                Get-DbaXESession -SqlInstance $server -Session $name
            }
        }
    }
}