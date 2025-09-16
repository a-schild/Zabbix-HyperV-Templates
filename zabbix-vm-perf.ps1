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
 
  try {
    $code = '[DllImport("pdh.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern UInt32 PdhLookupPerfNameByIndex(string szMachineName, uint dwNameIndex, System.Text.StringBuilder szNameBuffer, ref uint pcchNameBufferSize);'
   
    # Try with different buffer sizes if the first attempt fails
    $bufferSizes = @(1024, 2048, 4096)
    
    foreach ($initialSize in $bufferSizes) {
      $Buffer = New-Object System.Text.StringBuilder($initialSize)
      [UInt32]$BufferSize = $Buffer.Capacity
   
      $t = Add-Type -MemberDefinition $code -PassThru -Name PerfCounter -Namespace Utility
      $rv = $t::PdhLookupPerfNameByIndex($ComputerName, $id, $Buffer, [Ref]$BufferSize)
   
      if ($rv -eq 0)
      {
        $bufferString = $Buffer.ToString()
        $actualLength = $bufferString.Length
        
        # Handle the case where BufferSize might be larger than actual string
        if ($BufferSize -gt 0 -and $actualLength -gt 0) {
          $targetLength = [Math]::Min($BufferSize-1, $actualLength)
          if ($targetLength -gt 0) {
            return $bufferString.Substring(0, $targetLength)
          }
        }
        
        # Fallback: just trim null characters
        $result = $bufferString.TrimEnd([char]0)
        if ($result.Length -gt 0) {
          return $result
        }
      }
      elseif ($rv -eq 0x800007D2) {
        # PDH_MORE_DATA - buffer too small, try next size
        continue
      }
    }
    
    # If all attempts failed, throw the error
    Throw "Get-PerformanceCounterLocalName : Unable to retrieve localized name for ID $ID. Check computer name and performance counter ID."
  }
  catch {
    Write-Warning "Error in Get-PerformanceCounterLocalName for ID $ID : $($_.Exception.Message)"
    return $null
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
 
        # Try current language first, then fallback to English (009)
        $languages = @('CurrentLanguage', '009')
        $script:perfHash = @{}
        
        foreach ($lang in $languages) {
            try {
                $key = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Perflib\$lang"
                $counters = (Get-ItemProperty -Path $key -Name Counter -ErrorAction Stop).Counter
                $all = $counters.Count
        
                for($i = 0; $i -lt $all; $i+=2)
                {
                   Write-Progress -Activity 'Retrieving PerfIDs' -Status 'Working' -PercentComplete ($i*100/$all)
                   if (-not $script:perfHash.ContainsKey($counters[$i+1])) {
                       $script:perfHash.$($counters[$i+1]) = $counters[$i]
                   }
                }
                break
            }
            catch {
                Write-Warning "Failed to load counters from $lang"
                continue
            }
        }
    }
 
    $result = $script:perfHash.$Name
    if (-not $result) {
        # Try English counter names as fallback
        $englishNames = @{
            'Hyper-V Virtual Storage Device' = '9470'
            'Read Bytes/sec' = '9480'
            'Write Bytes/sec' = '9482'
            'Read Operations/sec' = '9484'
            'Write Operations/sec' = '9486'
            'Hyper-V Virtual Network Adapter' = '11386'
            'Bytes Received/sec' = '11232'
            'Bytes Sent/sec' = '11236'
            'Packets Sent/sec' = '11248'
            'Hyper-V Hypervisor Virtual Processor' = '10500'
            '% Total Run Time' = '10788'
        }
        $result = $englishNames.$Name
    }
    
    return $result
}

function Test-PerformanceCounter
{
    param
    (
        [Parameter(Mandatory=$true)]
        $CounterPath
    )
    
    try {
        $testResult = Get-Counter -Counter $CounterPath -MaxSamples 1 -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

function Build-SafeCounterPath
{
    param
    (
        [Parameter(Mandatory=$true)]
        $CategoryId,
        [Parameter(Mandatory=$true)]
        $CounterId,
        [Parameter(Mandatory=$false)]
        $Instance = "*"
    )
    
    # Get localized names, with fallback to IDs if names can't be resolved
    $categoryName = Get-PerformanceCounterLocalName $CategoryId
    $counterName = Get-PerformanceCounterLocalName $CounterId
    
    if ($categoryName -and $counterName) {
        return "\$categoryName($Instance)\$counterName"
    }
    else {
        # Fallback to numeric IDs if name resolution fails
        Write-Warning "Using numeric counter path as fallback: \$CategoryId($Instance)\$CounterId"
        return "\$CategoryId($Instance)\$CounterId"
    }
}

function Get-HyperVCounterPath
{
    param
    (
        [Parameter(Mandatory=$true)]
        $CounterType,
        [Parameter(Mandatory=$false)]
        $Instance = "*"
    )
    
    $counterMappings = @{
        'VirtualStorageDevice' = @{
            'Category' = 'Hyper-V Virtual Storage Device'
            'Counters' = @{
                'ReadBytes' = 'Read Bytes/sec'
                'WriteBytes' = 'Write Bytes/sec'
                'ReadOps' = 'Read Operations/sec'
                'WriteOps' = 'Write Operations/sec'
            }
        }
        'VirtualNetworkAdapter' = @{
            'Category' = 'Hyper-V Virtual Network Adapter'
            'Counters' = @{
                'BytesReceived' = 'Bytes Received/sec'
                'BytesSent' = 'Bytes Sent/sec'
                'PacketsSent' = 'Packets Sent/sec'
            }
        }
        'HypervisorVirtualProcessor' = @{
            'Category' = 'Hyper-V Hypervisor Virtual Processor'
            'Counters' = @{
                'TotalRunTime' = '% Total Run Time'
            }
        }
    }
    
    $mapping = $counterMappings[$CounterType]
    if (-not $mapping) {
        throw "Unknown counter type: $CounterType"
    }
    
    # Try to get counter IDs dynamically
    $categoryId = Get-PerformanceCounterID $mapping.Category
    if (-not $categoryId) {
        throw "Could not resolve category ID for: $($mapping.Category)"
    }
    
    return $categoryId
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
				$counterName = Build-SafeCounterPath -CategoryId 9470 -CounterId 9482 -Instance "*"
				$Results =  (Get-Counter -Counter $counterName -ErrorAction SilentlyContinue).CounterSamples  | Where-Object  {$_.InstanceName -like '*-'+$VMName+'*'} | select InstanceName
			}

			('GetVMNICs'){
				$ItemType = "VMNIC"
				$counterName = Build-SafeCounterPath -CategoryId 11386 -CounterId 11248 -Instance "*"
				$Results =  (Get-Counter -Counter $counterName -ErrorAction SilentlyContinue).CounterSamples  | Where-Object  {$_.InstanceName -like '*-'+$VMName+'*'} | select InstanceName
			}

			('GetVMCPUs'){
				 $ItemType  ="VMCPU"
				
				# Try multiple approaches to get the counter
				$counterFound = $false
				$Results = @()
				
				# Method 1: Use safe counter path building
				try {
					$counterName = Build-SafeCounterPath -CategoryId 10500 -CounterId 10788 -Instance "*"
					
					if (Test-PerformanceCounter $counterName) {
						$Results = (Get-Counter -Counter $counterName -ErrorAction SilentlyContinue).CounterSamples | Where-Object {$_.InstanceName -like $VMName+':*' -or $_.InstanceName -like '*-'+$VMName+'*'} | select InstanceName
						$counterFound = $true
					}
				}
				catch {
					Write-Warning "Method 1 failed for GetVMCPUs: $($_.Exception.Message)"
				}
				
				# Method 2: Try with English counter names if method 1 failed
				if (-not $counterFound) {
					try {
						$englishCounterName = "\Hyper-V Hypervisor Virtual Processor(*)\% Total Run Time"
						if (Test-PerformanceCounter $englishCounterName) {
							$Results = (Get-Counter -Counter $englishCounterName -ErrorAction SilentlyContinue).CounterSamples | Where-Object {$_.InstanceName -like $VMName+':*' -or $_.InstanceName -like '*-'+$VMName+'*'} | select InstanceName
							$counterFound = $true
						}
					}
					catch {
						Write-Warning "Method 2 failed for GetVMCPUs: $($_.Exception.Message)"
					}
				}
				
				# Method 3: Try alternative pattern matching
				if (-not $counterFound) {
					try {
						$counterPart1 = Get-PerformanceCounterLocalName(10500)
						$counterPart2 = Get-PerformanceCounterLocalName(10788)
						$counterName= "\$counterPart1(*)\$counterPart2"
						$Results = (Get-Counter -Counter $counterName -ErrorAction SilentlyContinue).CounterSamples | Where-Object {$_.InstanceName -match $VMName} | select InstanceName
					}
					catch {
						Write-Warning "Method 3 failed for GetVMCPUs: $($_.Exception.Message)"
					}
				}
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
					$Results =  (Get-Counter -Counter $counterName -ErrorAction SilentlyContinue).CounterSamples
                }
                ('VMDISKBytesWrite'){
					$ItemType = $QueryName
					$counterPart1 = Get-PerformanceCounterLocalName(9470)
					$counterPart2 = Get-PerformanceCounterLocalName(9482)
					$counterName= "\$counterPart1($VMObject)\$counterPart2"
					<# $Results =  (Get-Counter -Counter "\Hyper-V Virtual Storage Device($VMObject)\Write Bytes/sec").CounterSamples #>
					$Results =  (Get-Counter -Counter $counterName -ErrorAction SilentlyContinue).CounterSamples
                }
                ('VMDISKOpsRead'){
					$ItemType = $QueryName
					$counterPart1 = Get-PerformanceCounterLocalName(9470)
					$counterPart2 = Get-PerformanceCounterLocalName(9484)
					$counterName= "\$counterPart1($VMObject)\$counterPart2"
					<# $Results =  (Get-Counter -Counter "\Hyper-V Virtual Storage Device($VMObject)\Read Operations/sec").CounterSamples #>
					$Results =  (Get-Counter -Counter $counterName -ErrorAction SilentlyContinue).CounterSamples
                }
                ('VMDISKOpsWrite'){
					$ItemType = $QueryName
					$counterPart1 = Get-PerformanceCounterLocalName(9470)
					$counterPart2 = Get-PerformanceCounterLocalName(9486)
					$counterName= "\$counterPart1($VMObject)\$counterPart2"
					<# $Results =  (Get-Counter -Counter "\Hyper-V Virtual Storage Device($VMObject)\Write Operations/sec").CounterSamples #>
					$Results =  (Get-Counter -Counter $counterName -ErrorAction SilentlyContinue).CounterSamples
                }

                <# Network Counters #>
                ('VMNICSent'){
					$ItemType = $QueryName
					$counterPart1 = Get-PerformanceCounterLocalName(11386)
					$counterPart2 = Get-PerformanceCounterLocalName(11236)
					$counterName= "\$counterPart1($VMObject)\$counterPart2"
					<# $Results = (Get-Counter -Counter "\Hyper-V Virtual Network Adapter($VMObject)\Bytes Sent/sec").CounterSamples #>
					$Results =  (Get-Counter -Counter $counterName -ErrorAction SilentlyContinue).CounterSamples
                }
                ('VMNICRecv'){
					$ItemType = $QueryName
					$counterPart1 = Get-PerformanceCounterLocalName(11386)
					$counterPart2 = Get-PerformanceCounterLocalName(11232)
					$counterName= "\$counterPart1($VMObject)\$counterPart2"
					<# $Results = (Get-Counter -Counter "\Hyper-V Virtual Network Adapter($VMObject)\Bytes Received/sec").CounterSamples #>
					$Results =  (Get-Counter -Counter $counterName -ErrorAction SilentlyContinue).CounterSamples
                }


                <# Virtual CPU Counters #>
                ('VMCPUTotal'){
                    $ItemType = $QueryName
					$counterPart1 = Get-PerformanceCounterLocalName(10500)
					$counterPart2 = Get-PerformanceCounterLocalName(10788)
					$counterName= "\$counterPart1(*)\$counterPart2"
                    <# $Results = (Get-Counter -Counter "\Hyper-V Hypervisor Virtual Processor($VMObject)\% Total Run Time").CounterSamples #>
					$Results =  (Get-Counter -Counter $counterName -ErrorAction SilentlyContinue).CounterSamples
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

