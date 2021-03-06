﻿using module ..\Include.psm1

param(
    [PSCustomObject]$Pools,
    [Bool]$InfoOnly
)

if (-not $IsWindows) {return}

$Path = ".\Bin\CPU-OptBF\cpuminer-$($f=$Global:GlobalCPUInfo.Features;$(if($f.avx2 -and $f.sha){'avx2-sha'}elseif($f.avx2){'avx2'}elseif($f.avx){'avx'}elseif($f.aes -and $f.sse42){'aes-sse42'}else{'sse2'})).exe"
$Uri = "https://github.com/RainbowMiner/miner-binaries/releases/download/v3.8.11-cpumineropt/cpuminer-opt-v3.8.11-bf-win64.zip"
$ManualUri = "https://github.com/bellflower2015/cpuminer-opt/releases"
$Port = "504{0:d2}"
$DevFee = 0.0

if (-not $Session.DevicesByTypes.CPU -and -not $InfoOnly) {return} # No CPU present in system

$Commands = [PSCustomObject[]]@(
    #[PSCustomObject]@{MainAlgorithm = "yespower"; Params = ""; ExtendInterval = 2} #Yespower, CpuminerYespower faster
    [PSCustomObject]@{MainAlgorithm = "yescryptr8"; Params = ""; ExtendInterval = 2} #YescryptR8
    [PSCustomObject]@{MainAlgorithm = "yescryptr16"; Params = ""; ExtendInterval = 2} #YescryptR16
    [PSCustomObject]@{MainAlgorithm = "yescryptr24"; Params = ""; ExtendInterval = 2} #YescryptR24
    [PSCustomObject]@{MainAlgorithm = "yescryptr32"; Params = ""; ExtendInterval = 2} #YescryptR32
    #[PSCustomObject]@{MainAlgorithm = "yespower05r16"; Params = ""; ExtendInterval = 2} #yespowerR16 (old yenten)
    [PSCustomObject]@{MainAlgorithm = "yespowerr8"; Params = ""; ExtendInterval = 2} #YespowerR8
    [PSCustomObject]@{MainAlgorithm = "yespowerr16"; Params = ""; ExtendInterval = 2} #YespowerR16
    [PSCustomObject]@{MainAlgorithm = "yespowerr24"; Params = ""; ExtendInterval = 2} #YespowerR24
    [PSCustomObject]@{MainAlgorithm = "yespowerr32"; Params = ""; ExtendInterval = 2} #YespowerR32
)

$Name = Get-Item $MyInvocation.MyCommand.Path | Select-Object -ExpandProperty BaseName

if ($InfoOnly) {
    [PSCustomObject]@{
        Type      = @("CPU")
        Name      = $Name
        Path      = $Path
        Port      = $Miner_Port
        Uri       = $Uri
        DevFee    = $DevFee
        ManualUri = $ManualUri
        Commands  = $Commands
    }
    return
}

$Session.DevicesByTypes.CPU | Select-Object Vendor, Model -Unique | ForEach-Object {
    $Miner_Device = $Session.DevicesByTypes.CPU | Where-Object Model -EQ $_.Model
    $Miner_Port = $Port -f ($Miner_Device | Select-Object -First 1 -ExpandProperty Index)
    $Miner_Model = $_.Model
    $Miner_Name = (@($Name) + @($Miner_Device.Name | Sort-Object) | Select-Object) -join '-'
    $Miner_Port = Get-MinerPort -MinerName $Name -DeviceName @($Miner_Device.Name) -Port $Miner_Port

    $DeviceParams = "$(if ($Session.Config.CPUMiningThreads){"-t $($Session.Config.CPUMiningThreads)"}) $(if ($Session.Config.CPUMiningAffinity -ne ''){"--cpu-affinity $($Session.Config.CPUMiningAffinity)"})"

    $Commands | ForEach-Object {

        $Algorithm_Norm = Get-Algorithm $_.MainAlgorithm

		foreach($Algorithm_Norm in @($Algorithm_Norm,"$($Algorithm_Norm)-$($Miner_Model)")) {
			if ($Pools.$Algorithm_Norm.Host -and $Miner_Device) {
				[PSCustomObject]@{
					Name = $Miner_Name
					DeviceName = $Miner_Device.Name
					DeviceModel = $Miner_Model
					Path = $Path
					Arguments = "-b $($Miner_Port) -a $($_.MainAlgorithm) -o $($Pools.$Algorithm_Norm.Protocol)://$($Pools.$Algorithm_Norm.Host):$($Pools.$Algorithm_Norm.Port) -u $($Pools.$Algorithm_Norm.User)$(if ($Pools.$Algorithm_Norm.Pass) {" -p $($Pools.$Algorithm_Norm.Pass)"}) -R 10 -r 4 $($DeviceParams) $($_.Params)"
					HashRates = [PSCustomObject]@{$Algorithm_Norm = $Session.Stats."$($Miner_Name)_$($Algorithm_Norm -replace '\-.*$')_HashRate".Week}
					API = "Ccminer"
					Port = $Miner_Port
					Uri = $Uri
					FaultTolerance = $_.FaultTolerance
					ExtendInterval = $_.ExtendInterval
					DevFee = $DevFee
					ManualUri = $ManualUri
				}
			}
		}
    }
}