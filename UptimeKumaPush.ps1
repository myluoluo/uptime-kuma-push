#==============================================================================
# UptimeKumaPush.ps1
# https://github.com/jmclaren7/uptimekumapush
#==============================================================================
function Test-Port {
    param (
        $obj
    )

    if ($obj.timeout) { $timeout = $obj.timeout } Else { $timeout = 2000 }

    $tcpClient = New-Object System.Net.Sockets.TcpClient
    return $tcpClient.ConnectAsync($obj.host, $obj.port).Wait($timeout)
}
function Test-Ping {
    param (
        $obj
    )
    if ($obj.timeout) { $timeout = $obj.timeout } Else { $timeout = 2000 }

    $return = Get-CimInstance -ClassName Win32_PingStatus -Filter "(Address='$($obj.host)') and timeout=$timeout" | Select-Object -Property Address, StatusCode, ResponseTime
    If ($return.StatusCode -eq 0 -and $return.ResponseTime -eq 0) { $return.ResponseTime = 1 }

    return $return.ResponseTime
}
function Test-Website {
    param (
        $obj
    )
    
    if ($obj.statuscode) {
        $statuscode = $obj.statuscode
    } Else {        
        # If search isn't set, set it to blank
        if ($obj.search) { $sSearch = $obj.search } Else { $sSearch = "" }
    }

    # If host doesnt start with https:// or http:// then use https://
    if ($obj.host -notmatch "^(https://|http://)") { $obj.host = "https://$($obj.host)" }

    # Set timeout to 4 seconds if not set, 
    if ($obj.timeout) { $timeout = $obj.timeout } Else { $timeout = 4 }

    try {
        $result = Invoke-WebRequest $obj.host -UseDefaultCredentials -TimeoutSec $timeout
        $httpStatusCode = $result.StatusCode
    }
    catch {
        $result = $false
        $httpStatusCode = $_.Exception.Response.StatusCode.value__
    }

    if ($httpStatusCode -eq $obj.statuscode) {
        $result = $true
    } else {
        $result = $false
        If ($result) { $result = $result -like "*$sSearch*" }
    }

    return $result
}

# Tests whichever type of monitor is provided
function Test-Host {
    param (
        $monitor
    )

    Switch ($monitor.type) {
        "ping" { $result = Test-Ping $monitor }
        "website" { $result = Test-Website $monitor }
        "port" { $result = Test-Port $monitor }
    }
    
    If ($result) {
        Write-Host "Up:   $monitor" -ForegroundColor Green
    }
    else {
        Write-Host "Down: $monitor" -ForegroundColor Red
    }

    # Return result
    return $result
}

# Force TLS 1.2 for older Windows versions
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

#==============================================================================
#==============================================================================
While ($true) {
    $config = Get-Content -Path "$PSScriptRoot\$((Get-Item $PSCommandPath ).Basename).json" | ConvertFrom-Json

    if ($config) {
        "Total monitors: $($config.monitors.count)"

        $push_url = if ($monitor.push_url) { $monitor.push_url } Else { $config.settings.push_url }
        $push_if_down = if ($monitor.push_if_down) { $monitor.push_if_down } Else { $config.settings.push_if_down }

        # Loop through each monitor
        $config.monitors | ForEach-Object {
            $monitor = $_
            $message = ""
            $ping = 0
            
            # If monitor has a group of monitors
            if ($monitor.group) {
                $result = $true
                $down_message = ""
                $up_message = ""

                Write-Host "Group Monitor: name=$($monitor.name) id=$($monitor.id) count=$($monitor.group.count)"

                # Loop over each group member
                $monitor.group | ForEach-Object {
                    $groupmonitor = $_
                    $member_result = Test-Host $groupmonitor
                    
                    # If this monitor is down, set group_monitor_return to false and add $groupmonitor.host to $msg
                    if ($member_result -eq $false) {
                        $result = $false
                        $down_message += "$($_.type):$($_.host)  "
                    }
                    else {
                        $up_message += "$($_.type):$($_.host)  "
                    }
                }

                # Combine down and up messages
                if ($down_message -ne "") { $down_message = "Down: $down_message" }
                if ($up_message -ne "") { $up_message = "Up: $up_message" }
                $message = $down_message + $up_message

                # If monitor is not a group, run test
            }
            else {
                $result = Test-Host $monitor
                if ($result -eq $false) { $message = "Failed ($monitor.type)): $($monitor.host)" }
                if ($result -match "^[\d\.]+$") { $ping = $result }
                $message = "$($_.type):$($_.host)"
            }

            # If push_if_down is set to false and the monitor is down, dont send a notification, continue loop
            if ($result -eq $false -and $push_if_down -eq $false) { return }

            # Set status to up or down based on result
            if ($result) { $status = "up" } else { $status = "down" }

            # Encode the message and replace variables in push_url
            $message_encoded = [System.Web.HttpUtility]::UrlEncode($message)
            $push_url_updated = $push_url.replace('{ID}', $monitor.id).replace('{STATUS}', $status).replace('{MSG}', $message_encoded).replace('{PING}', $ping)

            # Output debug info
            #Write-Host "  `$result=$result  `$status=$status  `$ping=$ping"
            #Write-Host "  `$message=$message"
            #Write-Host "  `$push_url_updated=$push_url_updated"

            # Send push notification to the server
            try {
                $webrequest = Invoke-RestMethod -Uri $push_url_updated
                Write-Host "Push Response: $webrequest" -ForegroundColor Blue

            }
            catch {
                Write-Host "Push Error: $($_.Exception.Message) $(($_.ErrorDetails | ConvertFrom-Json -ErrorAction SilentlyContinue).msg )" -ForegroundColor Red
            }
            
        }

        # Check loop setting, if false exit script, if true sleep for loop_delay seconds
        if ($config.settings.loop -eq $false) { 
            Exit
        }
        else {
            Write-Host "Sleeping for $($config.settings.loop_delay) seconds"
            Start-Sleep $config.settings.loop_delay
        }
        
    }
    else {
        Write-Host "Config issue"
        Start-Sleep 2
    }
    
}