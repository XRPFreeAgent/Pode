function Find-PodeSchedule
{
    param(
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name
    )

    return $PodeContext.Schedules[$Name]
}

function Start-PodeScheduleRunspace
{
    if ((Get-PodeCount $PodeContext.Schedules) -eq 0) {
        return
    }

    $script = {
        # select the schedules that trigger on-start
        $_now = [DateTime]::Now

        $PodeContext.Schedules.Values |
            Where-Object {
                $_.OnStart
            } | ForEach-Object {
                Invoke-PodeInternalSchedule -Schedule $_
            }

        # complete any schedules
        Complete-PodeInternalSchedules -Now $_now

        # first, sleep for a period of time to get to 00 seconds (start of minute)
        Start-Sleep -Seconds (60 - [DateTime]::Now.Second)

        while ($true)
        {
            $_now = [DateTime]::Now

            # select the schedules that need triggering
            $PodeContext.Schedules.Values |
                Where-Object {
                    (($null -eq $_.StartTime) -or ($_.StartTime -le $_now)) -and
                    (($null -eq $_.EndTime) -or ($_.EndTime -ge $_now)) -and
                    (Test-PodeCronExpressions -Expressions $_.Crons -DateTime $_now) -and !$_.Completed
                } | ForEach-Object {
                    Invoke-PodeInternalSchedule -Schedule $_
                }

            # complete any schedules
            Complete-PodeInternalSchedules -Now $_now

            # cron expression only goes down to the minute, so sleep for 1min
            Start-Sleep -Seconds (60 - [DateTime]::Now.Second)
        }
    }

    Add-PodeRunspace -Type 'Main' -ScriptBlock $script
}

function Complete-PodeInternalSchedules
{
    param(
        [Parameter(Mandatory=$true)]
        [datetime]
        $Now
    )

    # add any schedules to remove that have exceeded their end time
    $Schedules = @($PodeContext.Schedules.Values |
        Where-Object { (($null -ne $_.EndTime) -and ($_.EndTime -lt $Now)) })

    if (($null -eq $Schedules) -or ($Schedules.Length -eq 0)) {
        return
    }

    # set any expired schedules as being completed
    $Schedules | ForEach-Object {
        $_.Completed = $true
    }
}

function Invoke-PodeInternalSchedule
{
    param(
        [Parameter(Mandatory=$true)]
        $Schedule
    )

    $Schedule.OnStart = $false

    # increment total number of triggers for the schedule
    $Schedule.Count++

    # check if we have hit the limit, and remove
    if (($Schedule.Limit -gt 0) -and ($Schedule.Count -ge $Schedule.Limit)) {
        $Schedule.Completed = $true
    }

    # trigger the schedules logic
    Invoke-PodeInternalScheduleLogic -Schedule $Schedule

    # reset the cron if it's random
    if (!$Schedule.Completed) {
        $Schedule.Crons = Reset-PodeRandomCronExpressions -Expressions $Schedule.Crons
    }
}

function Invoke-PodeInternalScheduleLogic
{
    param(
        [Parameter(Mandatory=$true)]
        $Schedule
    )

    try {
        $parameters = @{
            Event = @{
                Lockable = $PodeContext.Lockable
            }
        }

        foreach ($key in $Schedule.Arguments.Keys) {
            $parameters[$key] = $Schedule.Arguments[$key]
        }

        Add-PodeRunspace -Type Schedules -ScriptBlock (($Schedule.Script).GetNewClosure()) -Parameters $parameters -Forget
    }
    catch {
        $_ | Write-PodeErrorLog
    }
}