﻿Function Start-APIServer {
    Param(
        [Parameter(Mandatory = $false)]
        [Switch]$RemoteAPI = $false,
        [Parameter(Mandatory = $false)]
        [int]$LocalAPIport = 4000
    )

    # Create a global synchronized hashtable that all threads can access to pass data between the main script and API
    $Global:API = [hashtable]::Synchronized(@{})
  
    # Setup flags for controlling script execution
    $API.Stop = $false
    $API.Pause = $false
    $API.Update = $false
    $API.RemoteAPI = $RemoteAPI
    $API.LocalAPIport = $LocalAPIport

    if ($IsWindows) {
        # Starting the API for remote access requires that a reservation be set to give permission for non-admin users.
        # If switching back to local only, the reservation needs to be removed first.
        # Check the reservations before trying to create them to avoid unnecessary UAC prompts.
        $urlACLs = & netsh http show urlacl | Out-String

        if ($API.RemoteAPI -and (!$urlACLs.Contains("http://+:$($LocalAPIport)/"))) {
            # S-1-5-32-545 is the well known SID for the Users group. Use the SID because the name Users is localized for different languages
            (Start-Process netsh -Verb runas -PassThru -ArgumentList "http add urlacl url=http://+:$($LocalAPIport)/ sddl=D:(A;;GX;;;S-1-5-32-545) user=everyone").WaitForExit()>$null
        }
        if (!$API.RemoteAPI -and ($urlACLs.Contains("http://+:$($LocalAPIport)/"))) {
            (Start-Process netsh -Verb runas -PassThru -ArgumentList "http delete urlacl url=http://+:$($LocalAPIport)/").WaitForExit()>$null
        }
    }

    # Setup runspace to launch the API webserver in a separate thread
    $newRunspace = [runspacefactory]::CreateRunspace()
    $newRunspace.Open()
    $newRunspace.SessionStateProxy.SetVariable("API", $API)
    $newRunspace.SessionStateProxy.Path.SetLocation($(pwd)) | Out-Null

    $API.Server = [PowerShell]::Create().AddScript({
        # Set the starting directory
        if ($MyInvocation.MyCommand.Path) {Set-Location (Split-Path $MyInvocation.MyCommand.Path)}

        Import-Module ".\Include.psm1"

        $BasePath = "$PWD\web"

        if ($IsWindows -eq $null) {
            if ([System.Environment]::OSVersion.Platform -eq "Win32NT") {
                $Global:IsWindows = $true
                $Global:IsLinux = $false
                $Global:IsMacOS = $false
            }
        }

        # List of possible mime types for files
        $MIMETypes = @{
            ".js" = "application/x-javascript"
            ".html" = "text/html"
            ".htm" = "text/html"
            ".json" = "application/json"
            ".css" = "text/css"
            ".txt" = "text/plain"
            ".ico" = "image/x-icon"
            ".png" = "image/png"
            ".jpg" = "image/jpeg"
            ".gif" = "image/gif"
            ".ps1" = "text/html" # ps1 files get executed, assume their response is html
            ".7z"  = "application/x-7z-compressed”
            ".zip" = "application/zip”
        }

        function Get-FilteredMinerObject {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory = $false, ValueFromPipeline = $true)]
                $Miner
            )
            $Out = [PSCustomObject]@{}
            $Miner.PSObject.Properties.Name | Where-Object {$_ -ne 'Process'} | Foreach-Object {$Out | Add-Member $_ $Miner.$_ -Force}
            $Out
        }

        # Setup the listener
        $Server = New-Object System.Net.HttpListener
        if ($API.RemoteAPI) {
            $Server.Prefixes.Add("http://+:$($API.LocalAPIport)/")
            # Require authentication when listening remotely
            $Server.AuthenticationSchemes = [System.Net.AuthenticationSchemes]::IntegratedWindowsAuthentication
        } else {
            $Server.Prefixes.Add("http://localhost:$($API.LocalAPIport)/")
        }
        $Server.Start()

        While ($Server.IsListening -and -not $API.Stop) {
            $Context = $Server.GetContext()
            $Request = $Context.Request
            $URL = $Request.Url.OriginalString

            # Determine the requested resource and parse query strings
            $Path = $Request.Url.LocalPath

            # Parse any parameters in the URL - $Request.Url.Query looks like "+ ?a=b&c=d&message=Hello%20world"
            $Parameters = [PSCustomObject]@{}
            $Request.Url.Query -Replace "\?", "" -Split '&' | Foreach-Object {
                $key, $value = $_ -Split '='
                # Decode any url escaped characters in the key and value
                $key = [URI]::UnescapeDataString($key)
                $value = [URI]::UnescapeDataString($value)
                if ($key -and $value) {
                    $Parameters | Add-Member $key $value
                }
            }

            if($Request.HasEntityBody) {
                $Reader = New-Object System.IO.StreamReader($Request.InputStream)
                $NewParameters = $Reader.ReadToEnd()
            }

            # Create a new response and the defaults for associated settings
            $Response = $Context.Response
            $ContentType = "application/json"
            $StatusCode = 200
            $Data = ""
            $ContentFileName = ""
            
            if($API.RemoteAPI -and (!$Request.IsAuthenticated)) {
                $Data = "Unauthorized"
                $StatusCode = 403
                $ContentType = "text/html"
            } else {
                # Set the proper content type, status code and data for each resource
                Switch($Path) {
                "/version" {
                    $Data = $API.Version
                    break
                }
                "/info" {
                    $Data = ConvertTo-Json $API.Info
                    break
                }
                "/activeminers" {
                    $Data = ConvertTo-Json @($API.ActiveMiners | Select-Object | Foreach-Object {Get-FilteredMinerObject $_}) -Depth 2
                    break
                }
                "/runningminers" {
                    $Data = ConvertTo-Json @($API.RunningMiners | Select-Object | Foreach-Object {Get-FilteredMinerObject $_}) -Depth 2
                    Break
                }
                "/failedminers" {
                    $Data = ConvertTo-Json @($API.FailedMiners | Select-Object | Foreach-Object {Get-FilteredMinerObject $_}) -Depth 2
                    Break
                }
                "/remoteminers" {
                    $Data = ConvertTo-Json @(($API.RemoteMiners | Select-Object | ConvertFrom-Json) | Select-Object) -Depth 10
                    Break
                }
                "/minersneedingbenchmark" {
                    $Data = ConvertTo-Json @(($API.MinersNeedingBenchmark | Select-Object | ConvertFrom-Json) | Select-Object)
                    Break
                }
                "/minerinfo" {
                    $Data = ConvertTo-Json @($API.MinerInfo | Select-Object)
                    Break
                }
                "/pools" {
                    $Data = ConvertTo-Json @(($API.Pools | Select-Object | ConvertFrom-Json).PSObject.Properties | Select-Object -ExpandProperty Value)
                    Break
                }
                "/newpools" {
                    $Data = ConvertTo-Json @(($API.NewPools | Select-Object) | ConvertFrom-Json | Select-Object)
                    Break
                }
                "/allpools" {
                    $Data = ConvertTo-Json @($API.AllPools | Select-Object)
                    Break
                }
                "/selectedpools" {
                    $Data = ConvertTo-Json @(($API.SelectedPools | Select-Object | ConvertFrom-Json) | Select-Object)
                    Break
                }
                "/algorithms" {
                    $Data = ConvertTo-Json @(($API.AllPools | Select-Object | ConvertFrom-Json).Algorithm | Sort-Object -Unique)
                    Break
                }
                "/miners" {
                    $Data = ConvertTo-Json @(($API.Miners | Select-Object | ConvertFrom-Json) | Select-Object)
                    Break
                }
                "/fastestminers" {
                    $Data = ConvertTo-Json @(($API.FastestMiners | Select-Object | ConvertFrom-Json) | Select-Object)
                    Break
                }
                "/config" {
                    $Data = ConvertTo-Json $API.Config
                    Break
                }
                "/userconfig" {
                    $Data = ConvertTo-Json $API.UserConfig
                    Break
                }
                "/downloadlist" {
                    $Data = ConvertTo-Json @(($API.DownloadList | Select-Object | ConvertFrom-Json) | Select-Object)
                    Break
                }
                "/debug" {
                    #create zip log and xxx out all purses
                    $DebugDate = Get-Date -Format "yyyy-MM-dd"
                    $DebugPath = ".\Logs\debug-$DebugDate"
                    $PurgeStrings = @()
                    @($API.Config,$API.UserConfig) | Select-Object | Foreach-Object {
                        $CurrentConfig = $_
                        @("Wallet","UserName","API_ID","API_Key","MinerStatusKey","MinerStatusEmail","PushOverUserKey") | Where-Object {$CurrentConfig.$_} | Foreach-Object {$PurgeStrings += $CurrentConfig.$_}
                        $CurrentConfig.Pools.PSObject.Properties.Value | Foreach-Object {
                            $CurrentPool = $_
                            $PurgeStrings += @($CurrentPool.Wallets.PSObject.Properties.Value | Select-Object)
                            @("Wallet","User","API_ID","API_Key","API_Secret","Password","PartyPassword","Email") | Where-Object {$CurrentPool.$_ -and $CurrentPool.$_.Length -gt 2} | Foreach-Object {$PurgeStrings += $CurrentPool.$_}
                        }
                    }
                    $PurgeStrings = $PurgeStrings | Select-Object -Unique | Foreach-Object {[regex]::Escape($_)}

                    if (-not (Test-Path $DebugPath)) {New-Item $DebugPath -ItemType "directory" > $null}
                    @(Get-ChildItem ".\Logs\*$(Get-Date -Format "yyyy-MM-dd")*.txt" | Select-Object) + @(Get-ChildItem ".\Logs\*$((Get-Date).AddDays(-1).ToString('yyyy-MM-dd'))*.txt" | Select-Object) | Sort-Object LastWriteTime | Foreach-Object {
                        $LastWriteTime = $_.LastWriteTime
                        $NewFile = "$DebugPath\$($_.Name)"
                        Get-Content $_ -Raw | Foreach-Object {$_ -replace "($($PurgeStrings -join "|"))","XXX"} | Out-File $NewFile
                        (Get-Item $NewFile).LastWriteTime = $LastWriteTime
                    }

                    @("Config","UserConfig") | Where-Object {$API.$_} | Foreach-Object {
                        $NewFile = "$DebugPath\$($_).json"
                        ($API.$_ | Select-Object | ConvertTo-Json -Depth 10) -replace "($($PurgeStrings -join "|"))","XXX" | Out-File $NewFile
                    }


                    if ($IsLinux) {
                        $Params = @{
                            FilePath     = "7z"
                            ArgumentList = "a `"$($DebugPath).zip`" `"$($DebugPath)\*`" -y -sdel -tzip"
                        }
                    } else {
                        $Params = @{
                            FilePath     = "7z"
                            ArgumentList = "a `"$($DebugPath).zip`" `"$($DebugPath)\*`" -y -sdel -tzip"
                            WindowStyle  = "Hidden"
                        }
                    }

                    $Params.PassThru = $true
                    (Start-Process @Params).WaitForExit()>$null

                    Remove-Item $DebugPath -Recurse -Force

                    $Data = [System.IO.File]::ReadAllBytes([IO.Path]::GetFullPath("$($DebugPath).zip"))
                    $ContentType = $MIMETypes[".zip"]
                    $ContentFileName = "debug_$($DebugDate).zip"

                    Remove-Item "$($DebugPath).zip" -Force -ErrorAction Ignore
                    Break
                }
                "/alldevices" {
                    $Data = ConvertTo-Json @($API.AllDevices | Select-Object)
                    Break
                }
                "/devices" {
                    $Data = ConvertTo-Json @($API.Devices | Select-Object)
                    Break
                }
                "/devicecombos" {
                    $Data = ConvertTo-Json @($API.DeviceCombos | Select-Object)
                    Break
                }
                "/stats" {
                    $Data = ConvertTo-Json @($API.Stats | Select-Object)
                    Break
                }
                "/totals" {
                    $Data = ConvertTo-Json @((Get-Stat -Totals).Values | Select-Object)
                    Break
                }
                "/totalscsv" {
                    $Data = @((Get-Stat -Totals).Values | Sort-Object Pool | Select-Object) | ConvertTo-Csv -NoTypeInformation -ErrorAction Ignore
                    $Data = $Data -join "`r`n"
                    $ContentType = "text/csv"
                    $ContentFileName = "totals_$(Get-Date -Format "yyyy-MM-dd_HHmmss").txt"
                    Break
                }
                "/poolstats" {
                    $Data = ConvertTo-Json @(Get-Stat -Pools | Select-Object)
                    Break
                }
                "/sessionvars" {                    
                    $Data = ConvertTo-Json $API.SessionVars
                    Break
                }
                "/watchdogtimers" {
                    $Data = ConvertTo-Json @($API.WatchdogTimers | Select-Object)
                    Break
                }
                "/balances" {
                    $Data = ConvertTo-Json @(($API.Balances | Select-Object | ConvertFrom-Json) | Select-Object)
                    Break
                }
                "/payouts" {
                    $Data = ConvertTo-Json @(($API.Balances | Select-Object | ConvertFrom-Json) | Where {$_.Currency -ne $null -and $_.Payouts} | Select-Object BaseName,Currency,Payouts | Foreach-Object {
                        $Balance_BaseName = $_.BaseName
                        $Balance_Currency = $_.Currency
                        $_.Payouts | Foreach-Object {
                            $DateTime = "$(if ($_.time) {$_.time} elseif ($_.date) {$_.date} elseif ($_.datetime) {$_.datetime})"
                            [PSCustomObject]@{
                                Name     = $Balance_BaseName
                                Currency = $Balance_Currency
                                Date     = $(if ($DateTime -match "^\d+$") {[DateTime]::new(1970, 1, 1, 0, 0, 0, 0, 'Utc') + [TimeSpan]::FromSeconds($DateTime)} else {(Get-Date $DateTime).ToUniversalTime()}).ToString("yyyy-MM-dd HH:mm:ss")
                                Amount   = [Double]$_.amount
                                Txid     = "$(if ($_.tx) {$_.tx} elseif ($_.txid) {$_.txid} elseif ($_.txHash) {$_.txHash})"
                            }
                        }
                    } | Sort-Object Date,Name,Currency | Select-Object)
                    Break
                }
                "/rates" {
                    $Data = ConvertTo-Json @($API.Rates | Select-Object)
                    Break
                }
                "/asyncloaderjobs" {
                    $Data = ConvertTo-Json @($API.Asyncloaderjobs | Select-Object)
                    Break
                }
                "/decsep" {
                    $Data = (Get-Culture).NumberFormat.NumberDecimalSeparator | ConvertTo-Json
                    Break
                }
                "/minerstats" {
                    [hashtable]$JsonUri_Dates = @{}
                    [hashtable]$Miners_List = @{}
                    [System.Collections.ArrayList]$Out = @()
                    ($API.Miners | Select-Object | ConvertFrom-Json) | Where-Object {$_.DeviceModel -notmatch '-'} | Select-Object BaseName,Name,Path,HashRates,DeviceModel | Foreach-Object {
                        if (-not $JsonUri_Dates.ContainsKey($_.BaseName)) {
                            $JsonUri = Join-Path (Get-MinerInstPath $_.Path) "_uri.json"
                            $JsonUri_Dates[$_.BaseName] = if (Test-Path $JsonUri) {(Get-ChildItem $JsonUri -ErrorAction Ignore).LastWriteTime.ToUniversalTime()} else {$null}
                        }
                        [String]$Algo = $_.HashRates.PSObject.Properties.Name | Select -First 1
                        [String]$SecondAlgo = ''
                        $Speed = @($_.HashRates.$Algo)
                        if (($_.HashRates.PSObject.Properties.Name | Measure-Object).Count -gt 1) {
                            $SecondAlgo = $_.HashRates.PSObject.Properties.Name | Select -Index 1
                            $Speed += $_.HashRates.$SecondAlgo
                        }
                        
                        $Miners_Key = "$($_.Name)_$($Algo -replace '\-.*$')"
                        if ($JsonUri_Dates[$_.BaseName] -ne $null -and -not $Miners_List.ContainsKey($Miners_Key)) {
                            $Miners_List[$Miners_Key] = $true
                            $Miner_Path = Get-ChildItem "Stats\Miners\*-$($Miners_Key)_HashRate.txt" -ErrorAction Ignore
                            $Miner_Failed = @($_.HashRates.PSObject.Properties.Value) -contains 0 -or @($_.HashRates.PSObject.Properties.Value) -contains $null
                            $Miner_NeedsBenchmark = $Miner_Path -and $Miner_Path.LastWriteTime.ToUniversalTime() -lt $JsonUri_Dates[$_.BaseName]
                            if ($_.DeviceModel -notmatch "-" -or $Miner_Path) {
                                $Out.Add([PSCustomObject]@{
                                    BaseName = $_.BaseName
                                    Name = $_.Name
                                    Algorithm = $Algo
                                    SecondaryAlgorithm = $SecondAlgo
                                    Speed = $Speed                                    
                                    DeviceModel = $_.DeviceModel
                                    Benchmarking = -not $Miner_Path
                                    NeedsBenchmark = $Miner_NeedsBenchmark
                                    BenchmarkFailed = $Miner_Failed
                                })>$null
                            }
                        }
                    }
                    $Data = ConvertTo-Json @($Out)
                    $Out.Clear()
                    $JsonUri_Dates.Clear()
                    $Miners_List.Clear()
                    Break
                }
                "/activity" {
                    $LimitDays = (Get-Date).ToUniversalTime().AddDays(-2)
                    $BigJson = ''
                    Get-ChildItem "Logs\Activity_*.txt" -ErrorAction Ignore | Where-Object LastWriteTime -gt $LimitDays | Sort-Object LastWriteTime -Descending | Get-Content -Raw | Foreach-Object {$BigJson += $_}
                    $GroupedData = "[$($BigJson -replace "[,\r\n]+$")]" | ConvertFrom-Json
                    $Data = $GroupedData | Group-Object ActiveStart,Name,Device | Foreach-Object {
                        $AvgProfit     = ($_.Group | Measure-Object Profit -Average).Average
                        $AvgPowerDraw  = ($_.Group | Measure-Object PowerDraw -Average).Average
                        $One           = $_.Group | Sort-Object ActiveLast -Descending | Select-Object -First 1
                        $Active        = ((Get-Date $One.ActiveLast)-(Get-Date $One.ActiveStart)).TotalMinutes
                        $One.Profit    = $AvgProfit
                        if ($One.PowerDraw -eq $null) {$One | Add-Member PowerDraw $AvgPowerDraw -Force} else {$One.PowerDraw = $AvgPowerDraw}
                        $One | Add-Member TotalPowerDraw ($AvgPowerDraw * $Active / 60000) #kWh
                        $One | Add-Member TotalProfit ($AvgProfit * $Active / 1440)
                        $One | Add-Member Active $Active -PassThru
                    } | Sort-Object ActiveStart,Name,Device | ConvertTo-Json
                    Break
                }
                "/computerstats" {
                    $Data = $API.ComputerStats
                    Break
                }
                "/minerports" {
                    $Data = $API.MinerPorts
                    Break
                }
                "/currentprofit" {
                    $Profit = $API.CurrentProfit
                    $RemoteMiners = $API.RemoteMiners | Select-Object | ConvertFrom-Json
                    $RemoteMiners | Where-Object {[Math]::Floor(([DateTime]::UtcNow - [DateTime]::new(1970, 1, 1, 0, 0, 0, 0, 'Utc')).TotalSeconds)-5*60 -lt $_.lastseen} | Foreach-Object {$Profit += $_.profit}
                    $Rates = [PSCustomObject]@{}; $API.Rates.Keys | Where-Object {$API.Config.Currency -icontains $_} | Foreach-Object {$Rates | Add-Member $_ $API.Rates.$_}
                    $Data  = [PSCustomObject]@{AllProfitBTC=$Profit;ProfitBTC=$API.CurrentProfit;Rates=$Rates} | ConvertTo-Json
                    Remove-Variable "Rates"
                    Remove-Variable "RemoteMiners"
                    Break
                }
                "/stop" {
                    $API.Stop = $true
                    $Data = "Stopping"
                    Break
                }
                "/pause" {
                    $API.Pause = -not $API.Pause
                    $Data = $API.Pause | ConvertTo-Json
                    Break
                }
                "/update" {
                    $API.Update = $true
                    $Data = $API.Update | ConvertTo-Json
                    Break
                }
                "/status" {
                    $Data = [PSCustomObject]@{Pause=$API.Pause} | ConvertTo-Json
                    Break
                }
                default {
                    # Set index page
                    if ($Path -eq "/") {
                        $Path = "/index.html"
                    }

                    # Check if there is a file with the requested path
                    $Filename = $BasePath + $Path
                    if (Test-Path $Filename -PathType Leaf) {
                        # If the file is a powershell script, execute it and return the output. A $Parameters parameter is sent built from the query string
                        # Otherwise, just return the contents of the file
                        $File = Get-ChildItem $Filename -ErrorAction Ignore

                        If ($File.Extension -eq ".ps1") {
                            $Data = (& $File.FullName -Parameters $Parameters) -join "`r`n"
                        } elseif (@(".html",".css",".js",".json",".xml",".txt") -icontains $File.Extension) {
                            $Data = Get-Content $Filename -Raw -ErrorAction Ignore

                            # Process server side includes for html files
                            # Includes are in the traditional '<!-- #include file="/path/filename.html" -->' format used by many web servers
                            $IncludeRegex = [regex]'<!-- *#include *file="(.*)" *-->'
                            $IncludeRegex.Matches($Data) | Foreach-Object {
                                $IncludeFile = $BasePath +'/' + $_.Groups[1].Value
                                If (Test-Path $IncludeFile -PathType Leaf) {
                                    $IncludeData = Get-Content $IncludeFile -Raw -ErrorAction Ignore
                                    $Data = $Data -Replace $_.Value, $IncludeData
                                }
                            }
                        } else {
                            $Data = [System.IO.File]::ReadAllBytes($File.FullName)
                        }

                        # Set content type based on file extension
                        If ($MIMETypes.ContainsKey($File.Extension)) {
                            $ContentType = $MIMETypes[$File.Extension]
                        } else {
                            # If it's an unrecognized file type, prompt for download
                            $ContentType = "application/octet-stream"
                        }
                    } else {
                        $StatusCode = 404
                        $ContentType = "text/html"
                        $Data = "URI '$Path' is not a valid resource."
                    }
                }
            }
            }

            # If $Data is null, the API will just return whatever data was in the previous request.  Instead, show an error
            # This happens if the script just started and hasn't filled all the properties in yet.
            If($Data -eq $Null) { 
                $Data = @{'Error' = "API data not available"} | ConvertTo-Json
            }

            # Send the response
            $Response.Headers.Add("Content-Type", $ContentType)
            if ($ContentFileName -ne "") {$Response.Headers.Add("Content-Disposition", "attachment; filename=$($ContentFileName)")}
            $Response.StatusCode = $StatusCode
            $ResponseBuffer = if ($Data -is [string]) {[System.Text.Encoding]::UTF8.GetBytes($Data)} else {$Data}
            $Response.ContentLength64 = $ResponseBuffer.Length
            $Response.OutputStream.Write($ResponseBuffer,0,$ResponseBuffer.Length)
            $Response.Close()
            if ($Error.Count) {$Error | Out-File "Logs\errors_$(Get-Date -Format "yyyy-MM-dd").api.txt" -Append -Encoding utf8}
            $Error.Clear()
            Remove-Variable "Data" -Force
            Remove-Variable "ResponseBuffer" -Force
            Remove-Variable "Response" -Force
        }
        # Only gets here if something is wrong and the server couldn't start or stops listening
        $Server.Stop()
        $Server.Close()
    }) #end of $apiserver

    $API.Server.Runspace = $newRunspace
    $API.Handle = $API.Server.BeginInvoke()
}

Function Stop-APIServer {
    if (-not $Global:API.Stop) {
        try {$result = Invoke-WebRequest -Uri "http://localhost:$($API.LocalAPIport)/stop" } catch { Write-Host "Listener ended"}
    }
    if ($Global:API.Server) {$Global:API.Server.dispose()}
    $Global:API.Server = $null
    $Global:API.Handle = $null
    Remove-Variable "API" -Scope Global -Force    
}

function Set-APIInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [String]$Name,
        [Parameter(Mandatory = $true)]
        $Value
    )
    if (-not $API.Info) {$API.Info = [hashtable]@{}}
    $API.Info[$Name] = $Value
}
