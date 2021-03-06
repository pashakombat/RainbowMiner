﻿using module ..\Include.psm1

param(
    [PSCustomObject]$Wallets,
    [PSCustomObject]$Params,
    [alias("WorkerName")]
    [String]$Worker,
    [TimeSpan]$StatSpan,
    [String]$DataWindow = "avg",
    [Bool]$InfoOnly = $false,
    [Bool]$AllowZero = $false,
    [String]$StatAverage = "Minute_10"
)

$Name = Get-Item $MyInvocation.MyCommand.Path | Select-Object -ExpandProperty BaseName

$Pool_Request = [PSCustomObject]@{}

try {
    $Pool_Request = Invoke-RestMethodAsync "https://ravenminer.com/api/status" -tag $Name -cycletime 120
}
catch {
    if ($Error.Count){$Error.RemoveAt(0)}
    Write-Log -Level Warn "Pool API ($Name) has failed. "
    return
}

try {
    $PoolCoins_Request = Invoke-RestMethodAsync "https://ravenminer.com/api/currencies" -tag $Name -cycletime 120
}
catch {
    if ($Error.Count){$Error.RemoveAt(0)}
    Write-Log -Level Info "Pool Currency API ($Name) has failed. "
}

$Pool_Coin = "Ravencoin"
$Pool_Currency = "RVN"
$Pool_Host = "ravenminer.com"

[hashtable]$Pool_RegionsTable = @{}

$Pool_Regions = @("us","eu","asia")
$Pool_Regions | Foreach-Object {$Pool_RegionsTable.$_ = Get-Region $_}

$Pool_Request | Get-Member -MemberType NoteProperty -ErrorAction Ignore | Select-Object -ExpandProperty Name | Where-Object {$Pool_Request.$_.actual_last24h -gt 0 -or $InfoOnly -or $AllowZero} | ForEach-Object {
    $Pool_Algorithm = $Pool_Request.$_.name
    $Pool_Algorithm_Norm = Get-Algorithm $Pool_Algorithm
    $Pool_PoolFee = [Double]$Pool_Request.$_.fees
    $Pool_User = $Wallets.$Pool_Currency
    $Pool_Port = $Pool_Request.$_.port

    $Pool_Factor = $Pool_Request.$_.mbtc_mh_factor

    $Pool_TSL = if ($PoolCoins_Request) {$PoolCoins_Request.$Pool_Currency.timesincelast}else{$null}
    $Pool_BLK = $PoolCoins_Request.$Pool_Currency."24h_blocks"

    if (-not $InfoOnly) {
        $NewStat = $false; if (-not (Test-Path "Stats\Pools\$($Name)_$($Pool_Algorithm_Norm)_Profit.txt")) {$NewStat = $true; $DataWindow = "estimate_last24h"}
        $Pool_Price = Get-YiiMPValue $Pool_Request.$_ -DataWindow $DataWindow -Factor $Pool_Factor
        $Stat = Set-Stat -Name "$($Name)_$($Pool_Algorithm_Norm)_Profit" -Value $Pool_Price -Duration $(if ($NewStat) {New-TimeSpan -Days 1} else {$StatSpan}) -ChangeDetection $false -ErrorRatio 0.000 -HashRate $Pool_Request.$_.hashrate -BlockRate $Pool_BLK -Quiet
    }

    $Pool_Params = if ($Params.$Pool_Currency) {",$($Params.$Pool_Currency)"}

    if ($Pool_User -or $InfoOnly) {
        foreach($Pool_Region in $Pool_Regions) {
            [PSCustomObject]@{
                Algorithm     = $Pool_Algorithm_Norm
                CoinName      = $Pool_Coin
                CoinSymbol    = $Pool_Currency
                Currency      = $Pool_Currency
                Price         = $Stat.$StatAverage #instead of .Live
                StablePrice   = $Stat.Week
                MarginOfError = $Stat.Week_Fluctuation
                Protocol      = "stratum+tcp"
                Host          = "$($Pool_Region).$($Pool_Host)"
                Port          = $Pool_Port
                User          = $Pool_User
                Pass          = "{workername:$Worker},c=$Pool_Currency{diff:,d=`$difficulty}$Pool_Params"
                Region        = $Pool_Regions.$Pool_Region
                SSL           = $false
                Updated       = $Stat.Updated
                PoolFee       = $Pool_PoolFee
                DataWindow    = $DataWindow
                Workers       = $Pool_Request.$_.workers
                Hashrate      = $Stat.HashRate_Live
                BLK           = $Stat.BlockRate_Average
                TSL           = $Pool_TSL
                ErrorRatio    = $Stat.ErrorRatio_Average
            }
        }
    }
}
