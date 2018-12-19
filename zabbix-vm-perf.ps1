<# 
Zabbix Agent PowerShell script for Hyper-V monitoring 


Copyright (c) 2015, Dmitry Sarkisov <ait.meijin@gmail.com>
Enhanced by Andre Schild <a.schild@aarboard.ch>

Language independent counter names from
http://www.powershellmagazine.com/2013/07/19/querying-performance-counters-from-powershell/

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"),
to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense,
and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.


#>


param(
	[Parameter(Mandatory=$False)]
	[string]$QueryName,
	[string]$VMName,
	[string]$VMObject
)

Function Get-PerformanceCounterLocalName
{
  param
  (
    [UInt32]
    $ID,
 
    $ComputerName = $env:COMPUTERNAME
  )
 
  $code = '[DllImport("pdh.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern UInt32 PdhLookupPerfNameByIndex(string szMachineName, uint dwNameIndex, System.Text.StringBuilder szNameBuffer, ref uint pcchNameBufferSize);'
 
  $Buffer = New-Object System.Text.StringBuilder(1024)
  [UInt32]$BufferSize = $Buffer.Capacity
 
  $t = Add-Type -MemberDefinition $code -PassThru -Name PerfCounter -Namespace Utility
  $rv = $t::PdhLookupPerfNameByIndex($ComputerName, $id, $Buffer, [Ref]$BufferSize)
 
  if ($rv -eq 0)
  {
    $Buffer.ToString().Substring(0, $BufferSize-1)
  }
  else
  {
    Throw 'Get-PerformanceCounterLocalName : Unable to retrieve localized name. Check computer name and performance counter ID.'
  }
}

function Get-PerformanceCounterID
{
    param
    (
        [Parameter(Mandatory=$true)]
        $Name
    )
 
    if ($script:perfHash -eq $null)
    {
        Write-Progress -Activity 'Retrieving PerfIDs' -Status 'Working'
 
        $key = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Perflib\CurrentLanguage'
        $counters = (Get-ItemProperty -Path $key -Name Counter).Counter
        $script:perfHash = @{}
        $all = $counters.Count
 
        for($i = 0; $i -lt $all; $i+=2)
        {
           Write-Progress -Activity 'Retrieving PerfIDs' -Status 'Working' -PercentComplete ($i*100/$all)
           $script:perfHash.$($counters[$i+1]) = $counters[$i]
        }
    }
 
    $script:perfHash.$Name
}

$hostname = Get-WmiObject win32_computersystem | Select-Object -ExpandProperty name

$VMName = $VMName.Replace("_" + $hostname, '')

<# Zabbix Hyper-V Virtual Machine Discovery #>
if ($QueryName -eq '') {
    
	
    $colItems = Get-VM

    write-host "{"
    write-host " `"data`":["
    write-host
	
    $n = $colItems.Count

    foreach ($objItem in $colItems) {
        $line =  ' { "{#VMNAME}":"' + $objItem.Name + '" ,"{#VMSTATE}":"' + $objItem.State  +
                     '", "{#VMHOST}":"' + $hostname + '" ,"{#REPLICATION}":"' + $objItem.ReplicationState +'" }'
        if ($n -gt 1){
            $line += ","
        }
        write-host $line
        $n--
    }

    write-host " ]"
    write-host "}"
    write-host
    exit
}

<# Zabbix Hyper-V VM Perf Counter Discovery #>
if ($psboundparameters.Count -eq 2) {
	if ($QueryName -eq "GetPerformanceCounterID")
	{
		$pcID= Get-PerformanceCounterID($VMName)
		write "ID of counter name <"$VMName"> is <"$pcID">"
		exit
	}
	elseif ($QueryName -eq "GetPerformanceCounterLocalName")
	{
		$pcLN= Get-PerformanceCounterLocalName($VMName);
		write "ID of counter name <"$VMName"> is <"$pcNL">"
		exit
	}
	else
	{
		<# $counterNames = LoadCounterNames <# Load localized counter names #>
		switch ($QueryName)
			{
			
			('GetVMDisks'){
				$ItemType = "VMDISK"
				$counterPart1 = Get-PerformanceCounterLocalName(9470)
				$counterPart2 = Get-PerformanceCounterLocalName(9482)
				$counterName= "\$counterPart1(*)\$counterPart2"
				<# $Results =  (Get-Counter -Counter '\Hyper-V Virtual Storage Device(*)\Read Bytes/sec').CounterSamples  | Where-Object  {$_.InstanceName -like '*-'+$VMName+'*'} | select InstanceName #>
				$Results =  (Get-Counter -Counter $counterName).CounterSamples  | Where-Object  {$_.InstanceName -like '*-'+$VMName+'*'} | select InstanceName
			}

			('GetVMNICs'){
				$ItemType = "VMNIC"
				$counterPart1 = Get-PerformanceCounterLocalName(11386)
				$counterPart2 = Get-PerformanceCounterLocalName(11248)
				$counterName= "\$counterPart1(*)\$counterPart2"
				<# $Results = (Get-Counter -Counter '\Virtueller Hyper-V-Netzwerkadapter(*)\Gesendete Pakete/s').CounterSamples | Where-Object  {$_.InstanceName -like $VMName+'_*'} | select InstanceName #>
				<# $Results = (Get-Counter -Counter '\Hyper-V Virtual Network Adapter(*)\Packets Sent/sec').CounterSamples | Where-Object  {$_.InstanceName -like $VMName+'_*'} | select InstanceName #>
				$Results =  (Get-Counter -Counter $counterName).CounterSamples  | Where-Object  {$_.InstanceName -like '*-'+$VMName+'*'} | select InstanceName
			}

			('GetVMCPUs'){
				 $ItemType  ="VMCPU"
				$counterPart1 = Get-PerformanceCounterLocalName(10500)
				$counterPart2 = Get-PerformanceCounterLocalName(10788)
				$counterName= "\$counterPart1(*)\$counterPart2"
				 <# $Results = (Get-Counter -Counter '\Hyper-V - virtueller Prozessor des Hypervisors(*)\% Gesamtausführungszeit').CounterSamples | Where-Object {$_.InstanceName -like $VMName+':*'} | select InstanceName #>
				 <# $Results = (Get-Counter -Counter '\Hyper-V Hypervisor Virtual Processor(*)\% Total Run Time').CounterSamples | Where-Object {$_.InstanceName -like $VMName+':*'} | select InstanceName #>
				$Results =  (Get-Counter -Counter $counterName).CounterSamples  | Where-Object  {$_.InstanceName -like '*-'+$VMName+'*'} | select InstanceName
			}
				
			default {$Results = "Bad Request"; write-host $Results; exit}
			}

		write-host "{"
		write-host " `"data`":["
		write-host      
		#write-host $Results
				   
		   
		$n = ($Results | measure).Count

				foreach ($objItem in $Results) {
					$line = " { `"{#"+$ItemType+"}`":`""+$objItem.InstanceName+"`"}"
					 
					if ($n -gt 1 ){
						$line += ","
					}

					write-host $line
					$n--
				}
		
		write-host " ]"
		write-host "}"
		write-host


		exit
	}
}



<# Zabbix Hyper-V VM Get Performance Counter Value #>
if ($psboundparameters.Count -eq 3) 
{
    if ($QueryName -eq 'GetVMReplication')
    {
        $Results = (Get-VMReplication | Where-Object {$_.VMName -eq $VMName}).ReplicationHealth
        write-host $Results
        exit
    }
    elseif ($QueryName -eq 'GetVMStatus')
    {
        $Results =  (Get-VM | Where-Object {$_.Name -eq $VMName}).State
        write-host $Results
        exit
    }
    else
    {
        switch ($QueryName){
                <# Disk Counters #>
                ('VMDISKBytesRead'){
					$ItemType = $QueryName
					$counterPart1 = Get-PerformanceCounterLocalName(9470)
					$counterPart2 = Get-PerformanceCounterLocalName(9480)
					$counterName= "\$counterPart1($VMObject)\$counterPart2"
					<# $Results =  (Get-Counter -Counter "\Hyper-V Virtual Storage Device($VMObject)\Read Bytes/sec").CounterSamples #>
					$Results =  (Get-Counter -Counter $counterName).CounterSamples
                }
                ('VMDISKBytesWrite'){
					$ItemType = $QueryName
					$counterPart1 = Get-PerformanceCounterLocalName(9470)
					$counterPart2 = Get-PerformanceCounterLocalName(9482)
					$counterName= "\$counterPart1($VMObject)\$counterPart2"
					<# $Results =  (Get-Counter -Counter "\Hyper-V Virtual Storage Device($VMObject)\Write Bytes/sec").CounterSamples #>
					$Results =  (Get-Counter -Counter $counterName).CounterSamples
                }
                ('VMDISKOpsRead'){
					$ItemType = $QueryName
					$counterPart1 = Get-PerformanceCounterLocalName(9470)
					$counterPart2 = Get-PerformanceCounterLocalName(9484)
					$counterName= "\$counterPart1($VMObject)\$counterPart2"
					<# $Results =  (Get-Counter -Counter "\Hyper-V Virtual Storage Device($VMObject)\Read Operations/sec").CounterSamples #>
					$Results =  (Get-Counter -Counter $counterName).CounterSamples
                }
                ('VMDISKOpsWrite'){
					$ItemType = $QueryName
					$counterPart1 = Get-PerformanceCounterLocalName(9470)
					$counterPart2 = Get-PerformanceCounterLocalName(9486)
					$counterName= "\$counterPart1($VMObject)\$counterPart2"
					<# $Results =  (Get-Counter -Counter "\Hyper-V Virtual Storage Device($VMObject)\Write Operations/sec").CounterSamples #>
					$Results =  (Get-Counter -Counter $counterName).CounterSamples
                }

                <# Network Counters #>
                ('VMNICSent'){
					$ItemType = $QueryName
					$counterPart1 = Get-PerformanceCounterLocalName(11386)
					$counterPart2 = Get-PerformanceCounterLocalName(11236)
					$counterName= "\$counterPart1($VMObject)\$counterPart2"
					<# $Results = (Get-Counter -Counter "\Hyper-V Virtual Network Adapter($VMObject)\Bytes Sent/sec").CounterSamples #>
					$Results =  (Get-Counter -Counter $counterName).CounterSamples
                }
                ('VMNICRecv'){
					$ItemType = $QueryName
					$counterPart1 = Get-PerformanceCounterLocalName(11386)
					$counterPart2 = Get-PerformanceCounterLocalName(11232)
					$counterName= "\$counterPart1($VMObject)\$counterPart2"
					<# $Results = (Get-Counter -Counter "\Hyper-V Virtual Network Adapter($VMObject)\Bytes Received/sec").CounterSamples #>
					$Results =  (Get-Counter -Counter $counterName).CounterSamples
                }


                <# Virtual CPU Counters #>
                ('VMCPUTotal'){
                    $ItemType = $QueryName
					$counterPart1 = Get-PerformanceCounterLocalName(10500)
					$counterPart2 = Get-PerformanceCounterLocalName(10788)
					$counterName= "\$counterPart1(*)\$counterPart2"
                    <# $Results = (Get-Counter -Counter "\Hyper-V Hypervisor Virtual Processor($VMObject)\% Total Run Time").CounterSamples #>
					$Results =  (Get-Counter -Counter $counterName).CounterSamples
                }

                default {$Results = "Bad Request"; exit}
        }

    
        foreach ($objItem in $Results) {
                $line = [int]$objItem.CookedValue
                write-host $line
        }

        exit
    }
}

