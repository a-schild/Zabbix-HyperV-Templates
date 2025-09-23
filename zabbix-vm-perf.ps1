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

# Get script directory for cache files
$script:ScriptDirectory = Split-Path $MyInvocation.MyCommand.Path -Parent

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

function Get-CacheFilePath
{
    param
    (
        [Parameter(Mandatory=$true)]
        [string]$CacheType
    )

    # Use the script directory that was set at the beginning
    if ($script:ScriptDirectory) {
        $scriptDir = $script:ScriptDirectory
    } else {
        # Fallback to current directory
        $scriptDir = Get-Location
    }

    return Join-Path $scriptDir "zabbix-hyperv-$CacheType-cache.json"
}

function Test-CacheValid
{
    param
    (
        [Parameter(Mandatory=$true)]
        [string]$CacheFilePath
    )

    if (-not (Test-Path $CacheFilePath)) {
        return $false
    }

    $fileAge = (Get-Date) - (Get-Item $CacheFilePath).LastWriteTime
    return $fileAge.Days -lt 1
}

function Save-CounterCache
{
    param
    (
        [Parameter(Mandatory=$true)]
        [hashtable]$CounterHash,
        [Parameter(Mandatory=$true)]
        [string]$CacheFilePath
    )

    try {
        $CounterHash | ConvertTo-Json | Out-File -FilePath $CacheFilePath -Encoding UTF8
    }
    catch {
        Write-Warning "Failed to save cache to $CacheFilePath`: $($_.Exception.Message)"
    }
}

function Load-CounterCache
{
    param
    (
        [Parameter(Mandatory=$true)]
        [string]$CacheFilePath
    )

    try {
        $json = Get-Content -Path $CacheFilePath -Raw -Encoding UTF8
        $obj = $json | ConvertFrom-Json

        # Convert PSCustomObject to hashtable for PowerShell 5.1 compatibility
        $hashtable = @{}
        $obj.PSObject.Properties | ForEach-Object {
            $hashtable[$_.Name] = $_.Value
        }

        return $hashtable
    }
    catch {
        Write-Warning "Failed to load cache from $CacheFilePath`: $($_.Exception.Message)"
        return @{}
    }
}

function Clear-CounterCaches
{
    # Clear old cache files - useful for troubleshooting or forcing refresh
    $cacheFiles = @(
        (Get-CacheFilePath "english"),
        (Get-CacheFilePath "localized")
    )

    foreach ($cacheFile in $cacheFiles) {
        if (Test-Path $cacheFile) {
            try {
                Remove-Item $cacheFile -Force
                Write-Host "Cleared cache: $cacheFile"
            }
            catch {
                Write-Warning "Failed to clear cache $cacheFile`: $($_.Exception.Message)"
            }
        }
    }
}

function Get-HyperVCounterNames
{
    # Return only the Hyper-V counters we actually use
    return @(
        'Hyper-V Hypervisor Virtual Processor',
        '% Total Run Time',
        'Hyper-V Virtual Storage Device',
        'Read Bytes/sec',
        'Write Bytes/sec',
        'Read Operations/sec',
        'Write Operations/sec',
        'Hyper-V Virtual Network Adapter',
        'Bytes Received/sec',
        'Bytes Sent/sec',
        'Packets Sent/sec'
    )
}

function Initialize-EnglishCounterCache
{
    $cacheFile = Get-CacheFilePath "english"

    # Try to load from cache first
    if (Test-CacheValid $cacheFile) {
        # Write-Progress -Activity 'Loading English Counter Cache' -Status 'Reading from cache'
        $script:englishPerfHash = Load-CounterCache $cacheFile
        if ($script:englishPerfHash.Count -gt 0) {
            # Write-Progress -Activity 'Loading English Counter Cache' -Completed
            return
        }
    }

    # Cache miss or invalid - build optimized cache with only needed counters
    Write-Progress -Activity 'Building Optimized Counter Cache' -Status 'Reading registry'
    $script:englishPerfHash = @{}

    try {
        # Always use English registry (009)
        $key = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Perflib\009"
        $counters = (Get-ItemProperty -Path $key -Name Counter -ErrorAction Stop).Counter
        $all = $counters.Count

        # Get list of Hyper-V counters we need
        $neededCounters = Get-HyperVCounterNames
        $foundCount = 0

        for($i = 0; $i -lt $all; $i+=2)
        {
            Write-Progress -Activity 'Building Optimized Counter Cache' -Status "Processing counters ($foundCount found)" -PercentComplete ($i*100/$all)

            $counterName = $counters[$i+1]
            $counterId = $counters[$i]

            # Only cache Hyper-V related counters to speed things up
            if ($neededCounters -contains $counterName -or $counterName -like "*Hyper-V*") {
                $script:englishPerfHash.$counterName = $counterId
                $foundCount++
            }

            # Early exit if we found all our needed counters
            if ($foundCount -ge $neededCounters.Count) {
                Write-Progress -Activity 'Building Optimized Counter Cache' -Status "Found all needed counters"
            }
        }

        # Save to cache for next time
        Save-CounterCache $script:englishPerfHash $cacheFile
        Write-Progress -Activity 'Building Optimized Counter Cache' -Completed
    }
    catch {
        Write-Warning "Failed to load English counters: $($_.Exception.Message)"
    }
}

function Get-EnglishCounterID
{
    param
    (
        [Parameter(Mandatory=$true)]
        [string]$EnglishName
    )

    if ($script:englishPerfHash -eq $null)
    {
        Initialize-EnglishCounterCache
    }

    return $script:englishPerfHash.$EnglishName
}

function Get-LocalizedCounterName
{
    param
    (
        [Parameter(Mandatory=$true)]
        [string]$EnglishName
    )

    # Initialize localized cache if needed
    if ($script:localizedCounterCache -eq $null) {
        $script:localizedCounterCache = @{}

        # Try to load from cache file
        $cacheFile = Get-CacheFilePath "localized"
        if (Test-CacheValid $cacheFile) {
            $script:localizedCounterCache = Load-CounterCache $cacheFile
        }
    }

    # Check if we already have this counter in cache
    if ($script:localizedCounterCache.ContainsKey($EnglishName)) {
        return $script:localizedCounterCache.$EnglishName
    }

    # Cache miss - resolve and store
    $counterId = Get-EnglishCounterID $EnglishName
    $localizedName = $EnglishName  # Default fallback

    if ($counterId) {
        # Try to get the localized name using the ID
        $resolvedName = Get-PerformanceCounterLocalName $counterId
        if ($resolvedName) {
            $localizedName = $resolvedName
        }
        else {
            Write-Warning "Could not localize counter '$EnglishName' (ID: $counterId), using English name"
        }
    }
    else {
        Write-Warning "Could not find counter ID for '$EnglishName', using English name"
    }

    # Store in cache for future use
    $script:localizedCounterCache.$EnglishName = $localizedName

    # Save updated cache to file (async to avoid blocking)
    $cacheFile = Get-CacheFilePath "localized"
    try {
        Save-CounterCache $script:localizedCounterCache $cacheFile
    }
    catch {
        # Don't fail if cache save fails
    }

    return $localizedName
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
        $EnglishCategoryName,
        [Parameter(Mandatory=$true)]
        $EnglishCounterName,
        [Parameter(Mandatory=$false)]
        $Instance = "*"
    )

    # Get localized names from English names
    $localCategoryName = Get-LocalizedCounterName $EnglishCategoryName
    $localCounterName = Get-LocalizedCounterName $EnglishCounterName

    if ($localCategoryName -and $localCounterName) {
        return "\$localCategoryName($Instance)\$localCounterName"
    }
    else {
        # Fallback to English names if localization fails
        Write-Warning "Using English counter names as fallback: \$EnglishCategoryName($Instance)\$EnglishCounterName"
        return "\$EnglishCategoryName($Instance)\$EnglishCounterName"
    }
}

function Get-SafePerformanceCounter
{
    param
    (
        [Parameter(Mandatory=$true)]
        $EnglishCategoryName,
        [Parameter(Mandatory=$true)]
        $EnglishCounterName,
        [Parameter(Mandatory=$true)]
        $InstanceName
    )

    # Get the original VM name if we received a sanitized one
    $originalInstanceName = Get-OriginalVMName $InstanceName

    # Try with original instance name first (performance counters typically use original names)
    try {
        $counterPath = Build-SafeCounterPath -EnglishCategoryName $EnglishCategoryName -EnglishCounterName $EnglishCounterName -Instance $originalInstanceName
        $result = (Get-Counter -Counter $counterPath -ErrorAction Stop).CounterSamples
        if ($result) {
            return $result
        }
    }
    catch {
        Write-Warning "Failed with original instance name '$originalInstanceName': $($_.Exception.Message)"
    }

    # Try with the provided instance name if it's different from original
    if ($InstanceName -ne $originalInstanceName) {
        try {
            $counterPath = Build-SafeCounterPath -EnglishCategoryName $EnglishCategoryName -EnglishCounterName $EnglishCounterName -Instance $InstanceName
            $result = (Get-Counter -Counter $counterPath -ErrorAction Stop).CounterSamples
            if ($result) {
                return $result
            }
        }
        catch {
            Write-Warning "Failed with provided instance name '$InstanceName': $($_.Exception.Message)"
        }
    }

    # Try with sanitized instance name as last resort
    $safeInstanceName = Sanitize-VMName $originalInstanceName
    if ($safeInstanceName -ne $originalInstanceName -and $safeInstanceName -ne $InstanceName) {
        try {
            $counterPath = Build-SafeCounterPath -EnglishCategoryName $EnglishCategoryName -EnglishCounterName $EnglishCounterName -Instance $safeInstanceName
            $result = (Get-Counter -Counter $counterPath -ErrorAction Stop).CounterSamples
            if ($result) {
                return $result
            }
        }
        catch {
            Write-Warning "Failed with sanitized instance name '$safeInstanceName': $($_.Exception.Message)"
        }
    }

    return $null
}

function Sanitize-VMName
{
    param
    (
        [Parameter(Mandatory=$true)]
        [string]$VMName
    )

    # Remove or replace characters that are invalid in Zabbix item keys and performance counter paths
    # Zabbix doesn't allow: ( ) [ ] { } | \ / ? * " ' : ; , = + & % @ ! # $ ^
    # Performance counters are especially sensitive to ( ) [ ] { }

    $sanitized = $VMName

    # Replace problematic characters with safe alternatives
    $sanitized = $sanitized -replace '\(', '_'    # Replace ( with _
    $sanitized = $sanitized -replace '\)', '_'    # Replace ) with _
    $sanitized = $sanitized -replace '\[', '_'    # Replace [ with _
    $sanitized = $sanitized -replace '\]', '_'    # Replace ] with _
    $sanitized = $sanitized -replace '\{', '_'    # Replace { with _
    $sanitized = $sanitized -replace '\}', '_'    # Replace } with _
    $sanitized = $sanitized -replace '\\', '_'    # Replace \ with _
    $sanitized = $sanitized -replace '/', '_'     # Replace / with _
    $sanitized = $sanitized -replace '\|', '_'    # Replace | with _
    $sanitized = $sanitized -replace '\?', '_'    # Replace ? with _
    $sanitized = $sanitized -replace '\*', '_'    # Replace * with _
    $sanitized = $sanitized -replace '"', '_'     # Replace " with _
    $sanitized = $sanitized -replace "'", '_'     # Replace ' with _
    $sanitized = $sanitized -replace ':', '_'     # Replace : with _
    $sanitized = $sanitized -replace ';', '_'     # Replace ; with _
    $sanitized = $sanitized -replace ',', '_'     # Replace , with _
    $sanitized = $sanitized -replace '=', '_'     # Replace = with _
    $sanitized = $sanitized -replace '\+', '_'    # Replace + with _
    $sanitized = $sanitized -replace '&', '_'     # Replace & with _
    $sanitized = $sanitized -replace '%', '_'     # Replace % with _
    $sanitized = $sanitized -replace '@', '_'     # Replace @ with _
    $sanitized = $sanitized -replace '!', '_'     # Replace ! with _
    $sanitized = $sanitized -replace '#', '_'     # Replace # with _
    $sanitized = $sanitized -replace '\$', '_'    # Replace $ with _
    $sanitized = $sanitized -replace '\^', '_'    # Replace ^ with _
    $sanitized = $sanitized -replace '`', '_'     # Replace ` with _
    $sanitized = $sanitized -replace '~', '_'     # Replace ~ with _

    # Remove any leading/trailing underscores and collapse multiple underscores
    $sanitized = $sanitized -replace '^_+', ''    # Remove leading underscores
    $sanitized = $sanitized -replace '_+$', ''    # Remove trailing underscores
    $sanitized = $sanitized -replace '_+', '_'    # Collapse multiple underscores

    # Ensure we don't return an empty string
    if ([string]::IsNullOrWhiteSpace($sanitized)) {
        $sanitized = "VM_" + $VMName.GetHashCode().ToString().Replace('-', '')
    }

    return $sanitized
}

function Get-OriginalVMName
{
    param
    (
        [Parameter(Mandatory=$true)]
        [string]$SafeVMName
    )

    try {
        # Get all current VM names
        $allVMs = Get-VM | Select-Object -ExpandProperty Name

        # First try exact match (for VMs that didn't need sanitization)
        if ($allVMs -contains $SafeVMName) {
            return $SafeVMName
        }

        # Try to find original VM by comparing sanitized versions
        foreach ($vm in $allVMs) {
            if ((Sanitize-VMName $vm) -eq $SafeVMName) {
                return $vm
            }
        }

        # If no match found, return the safe name as fallback
        return $SafeVMName
    }
    catch {
        Write-Warning "Error in Get-OriginalVMName for '$SafeVMName': $($_.Exception.Message)"
        return $SafeVMName
    }
}

function Get-StorageCounterInstances
{
    # Get storage performance counter instances using proper localized counter names
    try {
        # Use our cached counter resolution to get the localized category and counter names
        $localCategoryName = Get-LocalizedCounterName "Hyper-V Virtual Storage Device"

        # Try to get any counter from this category to access instances
        # We don't need a specific counter, any counter will give us the instance list
        try {
            $counterSet = Get-Counter -ListSet $localCategoryName -ErrorAction Stop
            if ($counterSet.Counter.Count -gt 0) {
                $anyCounter = $counterSet.Counter[0]
                $instances = (Get-Counter -Counter $anyCounter -ErrorAction Stop).CounterSamples
                return $instances
            }
        }
        catch {
            # Fallback: try English category name
            try {
                $counterSet = Get-Counter -ListSet "Hyper-V Virtual Storage Device" -ErrorAction Stop
                if ($counterSet.Counter.Count -gt 0) {
                    $anyCounter = $counterSet.Counter[0]
                    $instances = (Get-Counter -Counter $anyCounter -ErrorAction Stop).CounterSamples
                    return $instances
                }
            }
            catch {
                return @()
            }
        }

        return @()
    }
    catch {
        return @()
    }
}

function Get-VMDiskInstances
{
    param
    (
        [Parameter(Mandatory=$true)]
        [string]$VMName
    )

    try {
        # Get the VM and its hard drives
        $vm = Get-VM -Name $VMName -ErrorAction Stop
        $vmDisks = Get-VMHardDiskDrive -VM $vm -ErrorAction Stop

        if ($vmDisks.Count -eq 0) {
            return @()
        }

        # Get all storage performance counter instances
        $allStorageInstances = Get-StorageCounterInstances

        if ($allStorageInstances.Count -eq 0) {
            return @()
        }

        $matchedInstances = @()

        foreach ($disk in $vmDisks) {
            $diskPath = $disk.Path

            # Extract filename from path
            $diskFileName = Split-Path $diskPath -Leaf
            $diskFileNameNoExt = [System.IO.Path]::GetFileNameWithoutExtension($diskFileName)

            # Try to find matching performance counter instances
            $matchingInstances = $allStorageInstances | Where-Object {
                $_.InstanceName -like "*$diskFileName*" -or
                $_.InstanceName -like "*$diskFileNameNoExt*"
            }

            foreach ($instance in $matchingInstances) {
                $matchedInstances += [PSCustomObject]@{
                    InstanceName = $instance.InstanceName
                    DiskPath = $diskPath
                    ControllerType = $disk.ControllerType
                    ControllerNumber = $disk.ControllerNumber
                    ControllerLocation = $disk.ControllerLocation
                }
            }
        }

        # Ensure we return an array (even if empty)
        return @($matchedInstances)
    }
    catch {
        return @()
    }
}

$hostname = Get-WmiObject win32_computersystem | Select-Object -ExpandProperty name

<# Zabbix Hyper-V Virtual Machine Discovery #>
if ($QueryName -eq '') {


    $colItems = Get-VM

    write-host "{"
    write-host " `"data`":["
    write-host

    $n = $colItems.Count

    foreach ($objItem in $colItems) {
        $originalName = $objItem.Name
        $sanitizedName = Sanitize-VMName $originalName

        $line =  ' { "{#VMNAME}":"' + $originalName + '" ,"{#VMNAME_SAFE}":"' + $sanitizedName + '" ,"{#VMSTATE}":"' + $objItem.State  +
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
    # Only remove hostname suffix if it actually exists at the end of the VM name
    $hostnameSuffix = "_" + $hostname
    if ($VMName.EndsWith($hostnameSuffix)) {
        $VMName = $VMName.Substring(0, $VMName.Length - $hostnameSuffix.Length)

        # Ensure VMName is not empty after hostname removal
        if ([string]::IsNullOrWhiteSpace($VMName)) {
            Write-Error "VMName became empty after hostname removal. Original VMName may have been only the hostname suffix."
            exit 1
        }
    }

    # Get the original VM name if we received a sanitized one
    $originalVMName = Get-OriginalVMName $VMName
    $safeVMName = Sanitize-VMName $originalVMName

    # Also handle VMObject if provided (contains instance names)
    if ($VMObject) {
        $originalVMObject = Get-OriginalVMName $VMObject
        $safeVMObject = Sanitize-VMName $originalVMObject
    }
	if ($QueryName -eq "GetPerformanceCounterID")
	{
		$pcID= Get-EnglishCounterID($VMName)
		write "ID of English counter name <"$VMName"> is <"$pcID">"
		exit
	}
	elseif ($QueryName -eq "GetPerformanceCounterLocalName")
	{
		$pcLN= Get-PerformanceCounterLocalName($VMName);
		write "Localized name of counter ID <"$VMName"> is <"$pcLN">"
		exit
	}
	elseif ($QueryName -eq "ClearCache")
	{
		Clear-CounterCaches
		write "Performance counter caches cleared. Next run will rebuild cache."
		exit
	}
	elseif ($QueryName -eq "TestVMDisks")
	{
		# Test the VM disk discovery for a specific VM
		Write-Host "Testing VM disk discovery for '$VMName'..."

		try {
			# Get the original VM name
			$originalVMName = Get-OriginalVMName $VMName
			Write-Host "Original VM name: '$originalVMName'"

			# First show the VM's actual disks
			$vm = Get-VM -Name $originalVMName -ErrorAction Stop
			$vmDisks = Get-VMHardDiskDrive -VM $vm -ErrorAction Stop

			Write-Host "`nVM has $($vmDisks.Count) disks:"
			foreach ($disk in $vmDisks) {
				Write-Host "  Path: $($disk.Path)"
				Write-Host "  Controller: $($disk.ControllerType) $($disk.ControllerNumber):$($disk.ControllerLocation)"
			}

			# Test the disk discovery method
			$diskInstances = Get-VMDiskInstances -VMName $originalVMName

			Write-Host "`nFound $(($diskInstances | Measure-Object).Count) performance counter instances:"
			foreach ($disk in $diskInstances) {
				Write-Host "  Instance: $($disk.InstanceName)"
				Write-Host "  Path: $($disk.DiskPath)"
				Write-Host "  Controller: $($disk.ControllerType) $($disk.ControllerNumber):$($disk.ControllerLocation)"
				Write-Host ""
			}
		}
		catch {
			Write-Warning "Error testing VM disks: $($_.Exception.Message)"
		}
		exit
	}
	elseif ($QueryName -eq "ListStorageCounters")
	{
		# Show all counters in the Virtual Storage Device category
		Write-Host "Listing all counters in 'Virtuelle Hyper-V-Speichervorrichtung'..."

		try {
			$storageCounters = Get-Counter -ListSet "Virtuelle Hyper-V-Speichervorrichtung" -ErrorAction Stop
			Write-Host "`nCounters in '$($storageCounters.CounterSetName)':"
			foreach ($counter in $storageCounters.Counter) {
				$counterName = $counter.Split('(')[0].Split('\')[-1]
				Write-Host "  - $counterName"
			}

			# Try to get some sample instances
			Write-Host "`nTrying to get sample instances..."
			$sampleCounter = $storageCounters.Counter | Select-Object -First 1
			if ($sampleCounter) {
				try {
					$instances = (Get-Counter -Counter $sampleCounter -ErrorAction Stop).CounterSamples
					Write-Host "Sample instances:"
					$instances | ForEach-Object { Write-Host "  - $($_.InstanceName)" }
				}
				catch {
					Write-Warning "Failed to get sample instances: $($_.Exception.Message)"
				}
			}
		}
		catch {
			Write-Warning "Error accessing storage counters: $($_.Exception.Message)"
		}
		exit
	}
	elseif ($QueryName -eq "FindHyperVCounters")
	{
		# Help find the correct Hyper-V counter names on this system
		Write-Host "Searching for Hyper-V related performance counters..."

		try {
			# Get all available counter sets
			$allCounterSets = Get-Counter -ListSet "*"
			$hyperVSets = $allCounterSets | Where-Object {
				$_.CounterSetName -like "*Hyper*" -or
				$_.CounterSetName -like "*Virtual*" -or
				$_.CounterSetName -like "*Speicher*" -or
				$_.CounterSetName -like "*Storage*"
			}

			Write-Host "`nFound $($hyperVSets.Count) Hyper-V/Virtual related counter sets:"
			foreach ($set in $hyperVSets) {
				Write-Host "`nCategory: '$($set.CounterSetName)'"
				Write-Host "  Description: $($set.Description)"
				Write-Host "  Relevant Counters:"

				$relevantCounters = $set.Counter | Where-Object {
					$_ -like "*Bytes*" -or $_ -like "*Run*" -or $_ -like "*Packets*" -or $_ -like "*Operations*"
				}

				if ($relevantCounters.Count -gt 0) {
					foreach ($counter in $relevantCounters) {
						$counterName = $counter.Split('(')[0].Split('\')[-1]
						Write-Host "    - $counterName"
					}
				} else {
					Write-Host "    (No relevant counters found)"
				}
			}

			Write-Host "`n=== ALL COUNTER CATEGORIES (filtered) ==="
			$allCounterSets | Where-Object {
				$_.CounterSetName -like "*Speicher*" -or
				$_.CounterSetName -like "*Storage*" -or
				$_.CounterSetName -like "*Disk*" -or
				$_.CounterSetName -like "*Datenträger*"
			} | ForEach-Object {
				Write-Host "- $($_.CounterSetName)"
			}
		}
		catch {
			Write-Warning "Error finding counters: $($_.Exception.Message)"
		}
		exit
	}
	else
	{
		switch ($QueryName)
			{

			('GetVMDisks'){
				$ItemType = "VMDISK"

				# Use Hyper-V cmdlets to get accurate VM disk instances
				$diskInstances = Get-VMDiskInstances -VMName $originalVMName

				if ($diskInstances -and (($diskInstances | Measure-Object).Count -gt 0)) {
					$Results = $diskInstances | Select-Object @{Name="InstanceName"; Expression={$_.InstanceName}}
				} else {
					# Fallback: try name-based matching with storage counter instances
					$allStorageInstances = Get-StorageCounterInstances

					if ($allStorageInstances.Count -gt 0) {
						# Try matching with both original and safe VM names
						$baseVMName = $originalVMName -replace '_.*$', ''  # Remove _SV03-HV suffix
						$baseSafeVMName = $safeVMName -replace '_.*$', ''

						$Results = $allStorageInstances | Where-Object  {
							$_.InstanceName -like '*-'+$originalVMName+'*' -or
							$_.InstanceName -like '*-'+$safeVMName+'*' -or
							$_.InstanceName -like '*'+$originalVMName+'*' -or
							$_.InstanceName -like '*'+$safeVMName+'*' -or
							$_.InstanceName -like '*-'+$baseVMName+'*' -or
							$_.InstanceName -like '*-'+$baseSafeVMName+'*' -or
							$_.InstanceName -like '*'+$baseVMName+'*' -or
							$_.InstanceName -like '*'+$baseSafeVMName+'*'
						} | select InstanceName
					} else {
						$Results = @()
					}
				}
			}

			('GetVMNICs'){
				$ItemType = "VMNIC"
				$counterName = Build-SafeCounterPath -EnglishCategoryName "Hyper-V Virtual Network Adapter" -EnglishCounterName "Packets Sent/sec" -Instance "*"
				# Try matching with both original and safe VM names
				$Results =  (Get-Counter -Counter $counterName -ErrorAction SilentlyContinue).CounterSamples  | Where-Object  {
					$_.InstanceName -like '*-'+$originalVMName+'*' -or
					$_.InstanceName -like '*-'+$safeVMName+'*' -or
					$_.InstanceName -like '*'+$originalVMName+'*' -or
					$_.InstanceName -like '*'+$safeVMName+'*'
				} | select InstanceName
			}

			('GetVMCPUs'){
				 $ItemType  ="VMCPU"

				# Use English counter names and let the function handle localization
				$counterName = Build-SafeCounterPath -EnglishCategoryName "Hyper-V Hypervisor Virtual Processor" -EnglishCounterName "% Total Run Time" -Instance "*"

				if (Test-PerformanceCounter $counterName) {
					$Results = (Get-Counter -Counter $counterName -ErrorAction SilentlyContinue).CounterSamples | Where-Object {
						$_.InstanceName -like $originalVMName+':*' -or
						$_.InstanceName -like $safeVMName+':*' -or
						$_.InstanceName -like '*-'+$originalVMName+'*' -or
						$_.InstanceName -like '*-'+$safeVMName+'*' -or
						$_.InstanceName -like '*'+$originalVMName+'*' -or
						$_.InstanceName -like '*'+$safeVMName+'*'
					} | select InstanceName
				}
				else {
					Write-Warning "Could not access counter: $counterName"
					$Results = @()
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
        # Try with original VM name first, then with provided name
        $originalVMName = Get-OriginalVMName $VMName
        $Results = (Get-VMReplication | Where-Object {$_.VMName -eq $originalVMName -or $_.VMName -eq $VMName}).ReplicationHealth
        write-host $Results
        exit
    }
    elseif ($QueryName -eq 'GetVMStatus')
    {
        # Try with original VM name first, then with provided name
        $originalVMName = Get-OriginalVMName $VMName
        $Results = (Get-VM | Where-Object {$_.Name -eq $originalVMName -or $_.Name -eq $VMName}).State
        write-host $Results
        exit
    }
    else
    {
        switch ($QueryName){
                <# Disk Counters #>
                ('VMDISKBytesRead'){
					$ItemType = $QueryName
					$Results = Get-SafePerformanceCounter -EnglishCategoryName "Hyper-V Virtual Storage Device" -EnglishCounterName "Read Bytes/sec" -InstanceName $VMObject
                }
                ('VMDISKBytesWrite'){
					$ItemType = $QueryName
					$Results = Get-SafePerformanceCounter -EnglishCategoryName "Hyper-V Virtual Storage Device" -EnglishCounterName "Write Bytes/sec" -InstanceName $VMObject
                }
                ('VMDISKOpsRead'){
					$ItemType = $QueryName
					$Results = Get-SafePerformanceCounter -EnglishCategoryName "Hyper-V Virtual Storage Device" -EnglishCounterName "Read Operations/sec" -InstanceName $VMObject
                }
                ('VMDISKOpsWrite'){
					$ItemType = $QueryName
					$Results = Get-SafePerformanceCounter -EnglishCategoryName "Hyper-V Virtual Storage Device" -EnglishCounterName "Write Operations/sec" -InstanceName $VMObject
                }

                <# Network Counters #>
                ('VMNICSent'){
					$ItemType = $QueryName
					$Results = Get-SafePerformanceCounter -EnglishCategoryName "Hyper-V Virtual Network Adapter" -EnglishCounterName "Bytes Sent/sec" -InstanceName $VMObject
                }
                ('VMNICRecv'){
					$ItemType = $QueryName
					$Results = Get-SafePerformanceCounter -EnglishCategoryName "Hyper-V Virtual Network Adapter" -EnglishCounterName "Bytes Received/sec" -InstanceName $VMObject
                }


                <# Virtual CPU Counters #>
                ('VMCPUTotal'){
                    $ItemType = $QueryName
					$Results = Get-SafePerformanceCounter -EnglishCategoryName "Hyper-V Hypervisor Virtual Processor" -EnglishCounterName "% Total Run Time" -InstanceName $VMObject
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