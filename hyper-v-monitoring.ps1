<#
Zabbix Agent PowerShell script for optimized Hyper-V monitoring
Returns VMs with their performance counter paths in a single discovery

Make sure this script is saved as UTF8 including BOM

Copyright (c) 2015, Dmitry Sarkisov <ait.meijin@gmail.com>
Enhanced by Andre Schild <a.schild@aarboard.ch>
Optimized for direct performance counter discovery

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
	[string]$QueryName = "",
	[string]$VMName,
	[string]$CounterPath
)

# Make sure to output the json names correctly encoded
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

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
    # Suppress warning messages that break JSON output
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
        $CounterHash | ConvertTo-Json | Out-File -FilePath $CacheFilePath -Encoding utf8
    }
    catch {
        # Suppress warning messages that break JSON output
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
        $json = Get-Content -Path $CacheFilePath -Raw 
        if ([string]::IsNullOrWhiteSpace($json)) {
            return $null
        }

        $obj = $json | ConvertFrom-Json
        if (-not $obj) {
            return $null
        }

        # Convert PSCustomObject to hashtable for PowerShell 5.1 compatibility
        $hashtable = @{}
        $obj.PSObject.Properties | ForEach-Object {
            $hashtable[$_.Name] = $_.Value
        }

        return $hashtable
    }
    catch {
        # Return null instead of empty hashtable to indicate load failure
        return $null
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
        'Packets Received/sec',
        'Packets Sent/sec'
    )
}

function Initialize-EnglishCounterCache
{
    $cacheFile = Get-CacheFilePath "english"

    # Try to load from cache first
    if (Test-CacheValid $cacheFile) {
        $loadedCache = Load-CounterCache $cacheFile
        if ($loadedCache -and $loadedCache.Count -gt 0) {
            $script:englishPerfHash = $loadedCache
            return
        }
    }

    # Cache miss or invalid - build comprehensive cache like original script
    $script:englishPerfHash = @{}

    try {
        # Always use English registry (009) - build FULL cache like original script
        $key = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Perflib\009"
        $counters = (Get-ItemProperty -Path $key -Name Counter -ErrorAction Stop).Counter
        $all = $counters.Count

        # Build complete hash like the original script (not just Hyper-V counters)
        for($i = 0; $i -lt $all; $i+=2)
        {
            $counterName = $counters[$i+1]
            $counterId = $counters[$i]

            # Add ALL counters to the hash (like original script)
            $script:englishPerfHash.$counterName = $counterId
        }

        # Save to cache for next time
        Save-CounterCache $script:englishPerfHash $cacheFile
    }
    catch {
        # If English counter loading fails, initialize empty hash
        $script:englishPerfHash = @{}
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
            $loadedCache = Load-CounterCache $cacheFile
            if ($loadedCache -and $loadedCache.Count -gt 0) {
                $script:localizedCounterCache = $loadedCache
            }
        }
    }

    # Check if we already have this counter in cache
    if ($script:localizedCounterCache.ContainsKey($EnglishName)) {
        return $script:localizedCounterCache.$EnglishName
    }

    # Cache miss - resolve and store
    $localizedName = $EnglishName  # Default to English as fallback

    # Direct mapping of English to German counter names based on actual system
    $counterMappings = @{
        # CPU Counters
        "Hyper-V Hypervisor Virtual Processor" = "Hyper-V Hypervisor: virtueller Prozessor"
        "% Total Run Time" = "% Gesamtlaufzeit"

        # Storage Counters
        "Hyper-V Virtual Storage Device" = "Virtuelle Hyper-V-Speichervorrichtung"
        "Read Bytes/sec" = "Gelesene Bytes/s"
        "Write Bytes/sec" = "Geschriebene Bytes/s"
        "Read Operations/sec" = "Lesevorgänge/s"
        "Write Operations/sec" = "Schreibvorgänge/s"

        # Network Counters
        "Hyper-V Virtual Network Adapter" = "Virtueller Hyper-V-Netzwerkadapter"
        "Bytes Received/sec" = "Empfangene Bytes/s"
        "Bytes Sent/sec" = "Gesendete Bytes/s"
        "Packets Received/sec" = "Empfangene Pakete/s"
        "Packets Sent/sec" = "Gesendete Pakete/s"
    }

    # Use direct mapping instead of registry lookup
    if ($counterMappings.ContainsKey($EnglishName)) {
        $localizedName = $counterMappings[$EnglishName]
    }

    # Store in cache for future use (only if not already cached)
    if (-not $script:localizedCounterCache.ContainsKey($EnglishName)) {
        $script:localizedCounterCache.$EnglishName = $localizedName

        # Save updated cache to disk for persistence across script executions
        try {
            $cacheFile = Get-CacheFilePath "localized"
            Save-CounterCache $script:localizedCounterCache $cacheFile
        }
        catch {
            # Ignore save errors to avoid breaking functionality
            Write-Warning "Failed to save localized cache: $_"
        }
    }

    return $localizedName
}

function Sanitize-VMName
{
    param
    (
        [Parameter(Mandatory=$true)]
        [string]$VMName
    )

    # Remove or replace characters that are invalid in Zabbix item keys and performance counter paths
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

function Build-EnglishCounterPath
{
    param
    (
        [Parameter(Mandatory=$true)]
        [string]$EnglishCategoryName,
        [Parameter(Mandatory=$true)]
        [string]$EnglishCounterName,
        [Parameter(Mandatory=$false)]
        [string]$InstanceName = "*"
    )

    # Always use English counter names for performance counter paths
    # This ensures consistency regardless of system locale

    # Quote instance names that contain spaces or special characters
    $quotedInstance = $InstanceName
    if ($InstanceName -ne "*" -and ($InstanceName -like "* *" -or $InstanceName -like "*:*" -or $InstanceName -like "*(*")) {
        $quotedInstance = "`"$InstanceName`""
    }

    return "\$EnglishCategoryName($quotedInstance)\$EnglishCounterName"
}

function Build-LocalizedCounterPath
{
    param
    (
        [Parameter(Mandatory=$true)]
        [string]$LocalizedCategoryName,
        [Parameter(Mandatory=$true)]
        [string]$LocalizedCounterName,
        [Parameter(Mandatory=$false)]
        [string]$InstanceName = "*"
    )

    # Build localized counter path - don't quote here, let Get-Counter handle it
    # The issue is that pre-quoted paths cause problems when passed as PowerShell parameters

    return "\$LocalizedCategoryName($InstanceName)\$LocalizedCounterName"
}

function Get-ShortResourceName
{
    param
    (
        [Parameter(Mandatory=$true)]
        [string]$FullName,
        [Parameter(Mandatory=$false)]
        [int]$MaxLength = 20,
        [Parameter(Mandatory=$false)]
        [string]$ResourceType = "GENERIC"
    )

    # Special handling for NIC resources
    if ($ResourceType -eq "NIC") {
        return Get-NicShortName $FullName
    }

    # Handle different types of resource names
    if ($FullName -like "*-hyper-v-*") {
        # Disk instances: "d:-hyper-v-hyper-v replica-virtual hard disks-17808674-b02d-408c-9ab8-a85700685ff7-sv101.vhd"
        # Extract the meaningful part (usually the filename at the end)
        $parts = $FullName -split '-'
        $lastPart = $parts[-1]  # e.g., "sv101.vhd"

        if ($lastPart.Length -le $MaxLength) {
            return $lastPart
        }

        # If still too long, try to extract VM name from filename
        $fileName = [System.IO.Path]::GetFileNameWithoutExtension($lastPart)
        if ($fileName.Length -le $MaxLength) {
            return $fileName
        }

        # Fallback: truncate with ellipsis
        return $fileName.Substring(0, $MaxLength - 3) + "..."
    }
    elseif ($FullName -like "*:*" -and $FullName -like "*-*") {
        # Network instances: "vmname:Microsoft Hyper-V Network Adapter"
        # Take the part before the colon (VM identifier)
        $vmPart = ($FullName -split ':')[0]
        if ($vmPart.Length -le $MaxLength) {
            return $vmPart
        }
        return $vmPart.Substring(0, $MaxLength - 3) + "..."
    }
    else {
        # Generic approach: try to find the most identifying part
        # Look for patterns with dashes, underscores, or dots
        $candidates = @()

        # Split by common separators and find the most meaningful parts
        $separators = @('-', '_', '.', '\', '/')
        foreach ($sep in $separators) {
            if ($FullName.Contains($sep)) {
                $parts = $FullName -split [regex]::Escape($sep)
                # Add non-empty parts that aren't too generic
                foreach ($part in $parts) {
                    if ($part.Length -gt 2 -and $part -notmatch '^\d+$' -and $part -notlike "*hyper-v*") {
                        $candidates += $part
                    }
                }
            }
        }

        # Pick the best candidate (shortest meaningful one)
        $bestCandidate = $candidates | Where-Object { $_.Length -le $MaxLength } | Sort-Object Length | Select-Object -First 1

        if ($bestCandidate) {
            return $bestCandidate
        }

        # Final fallback: truncate the full name
        if ($FullName.Length -le $MaxLength) {
            return $FullName
        }
        return $FullName.Substring(0, $MaxLength - 3) + "..."
    }
}

function Get-NicShortName
{
    param
    (
        [Parameter(Mandatory=$true)]
        [string]$NicInstanceName
    )

    # Create a clear 10-character NIC identifier without VM name
    # Focus on identifying the NIC adapter itself

    $shortName = ""

    # Look for adapter type indicators
    if ($NicInstanceName -like "*Legacy*") {
        $shortName = "LegacyNIC1"
    }
    elseif ($NicInstanceName -like "*Synthetic*") {
        $shortName = "SynthNIC01"
    }
    elseif ($NicInstanceName -like "*Microsoft*Hyper-V*Network*Adapter*") {
        $shortName = "HyperVNIC1"
    }
    elseif ($NicInstanceName -like "*External*") {
        $shortName = "ExtNIC001"
    }
    elseif ($NicInstanceName -like "*Internal*") {
        $shortName = "IntNIC001"
    }
    elseif ($NicInstanceName -like "*Private*") {
        $shortName = "PvtNIC001"
    }
    else {
        # Generic NIC - try to extract meaningful identifier
        # Remove common words and get unique part
        $cleaned = $NicInstanceName -replace "Microsoft|Hyper-V|Network|Adapter|Virtual", ""
        $cleaned = $cleaned -replace "[^a-zA-Z0-9]", ""

        if ($cleaned.Length -ge 4) {
            $shortName = "NIC" + $cleaned.Substring(0, 7).ToUpper()
        }
        else {
            # Use hash of full name for uniqueness
            $hash = [System.Math]::Abs($NicInstanceName.GetHashCode()) % 999999
            $shortName = "NIC" + $hash.ToString("D6")
        }
    }

    # Ensure exactly 10 characters
    if ($shortName.Length -lt 10) {
        $shortName = $shortName.PadRight(10, '0')
    }
    elseif ($shortName.Length -gt 10) {
        $shortName = $shortName.Substring(0, 10)
    }

    return $shortName
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

function Get-VMResourceInstances
{
    param
    (
        [Parameter(Mandatory=$true)]
        [string]$VMName
    )

    $vmResources = @{
        CPUs = @()
        Disks = @()
        NICs = @()
    }

    try {
        # Get the VM object
        $vm = Get-VM -Name $VMName -ErrorAction Stop
        $sanitizedVMName = Sanitize-VMName $VMName

        # CPU Discovery - Find CPU performance counters
        try {
            $cpuCounterPath = Build-EnglishCounterPath "Hyper-V Hypervisor Virtual Processor" "% Total Run Time" "*"
            $cpuInstances = (Get-Counter -Counter $cpuCounterPath -ErrorAction Stop).CounterSamples

            # Match CPU instances for this VM
            $vmCpuInstances = $cpuInstances | Where-Object {
                $_.InstanceName -like "${VMName}:*" -or
                $_.InstanceName -like "${sanitizedVMName}:*"
            }

            foreach ($cpuInstance in $vmCpuInstances) {
                $vmResources.CPUs += [PSCustomObject]@{
                    InstanceName = $cpuInstance.InstanceName
                    CounterPath = Build-EnglishCounterPath "Hyper-V Hypervisor Virtual Processor" "% Total Run Time" $cpuInstance.InstanceName
                }
            }
        }
        catch {
            Write-Warning "Failed to discover CPU instances for VM '$VMName': $($_.Exception.Message)"
        }

        # Disk Discovery - Find disk performance counters
        try {
            $vmDisks = Get-VMHardDiskDrive -VM $vm -ErrorAction Stop

            # Get all storage performance counter instances
            $diskCounterPath = Build-EnglishCounterPath "Hyper-V Virtual Storage Device" "Read Bytes/sec" "*"
            $diskInstances = (Get-Counter -Counter $diskCounterPath -ErrorAction Stop).CounterSamples

            foreach ($disk in $vmDisks) {
                $diskFileName = Split-Path $disk.Path -Leaf
                $diskFileNameNoExt = [System.IO.Path]::GetFileNameWithoutExtension($diskFileName)

                # Find matching performance counter instances
                $matchingDiskInstances = $diskInstances | Where-Object {
                    $_.InstanceName -like "*$diskFileName*" -or
                    $_.InstanceName -like "*$diskFileNameNoExt*"
                }

                foreach ($diskInstance in $matchingDiskInstances) {
                    $vmResources.Disks += [PSCustomObject]@{
                        InstanceName = $diskInstance.InstanceName
                        DiskPath = $disk.Path
                        ReadBytesCounter = Build-EnglishCounterPath "Hyper-V Virtual Storage Device" "Read Bytes/sec" $diskInstance.InstanceName
                        WriteBytesCounter = Build-EnglishCounterPath "Hyper-V Virtual Storage Device" "Write Bytes/sec" $diskInstance.InstanceName
                        ReadOpsCounter = Build-EnglishCounterPath "Hyper-V Virtual Storage Device" "Read Operations/sec" $diskInstance.InstanceName
                        WriteOpsCounter = Build-EnglishCounterPath "Hyper-V Virtual Storage Device" "Write Operations/sec" $diskInstance.InstanceName
                    }
                }
            }
        }
        catch {
            Write-Warning "Failed to discover disk instances for VM '$VMName': $($_.Exception.Message)"
        }

        # NIC Discovery - Find network performance counters
        try {
            $vmNics = Get-VMNetworkAdapter -VM $vm -ErrorAction Stop

            # Get all network performance counter instances
            $nicCounterPath = Build-EnglishCounterPath "Hyper-V Virtual Network Adapter" "Bytes Received/sec" "*"
            $nicInstances = (Get-Counter -Counter $nicCounterPath -ErrorAction Stop).CounterSamples

            foreach ($nic in $vmNics) {
                # Match network instances for this VM
                $matchingNicInstances = $nicInstances | Where-Object {
                    $_.InstanceName -like "*${VMName}*" -or
                    $_.InstanceName -like "*${sanitizedVMName}*" -or
                    $_.InstanceName -like "${VMName}_*" -or
                    $_.InstanceName -like "${sanitizedVMName}_*"
                }

                foreach ($nicInstance in $matchingNicInstances) {
                    $vmResources.NICs += [PSCustomObject]@{
                        InstanceName = $nicInstance.InstanceName
                        AdapterName = $nic.Name
                        BytesReceivedCounter = Build-EnglishCounterPath "Hyper-V Virtual Network Adapter" "Bytes Received/sec" $nicInstance.InstanceName
                        BytesSentCounter = Build-EnglishCounterPath "Hyper-V Virtual Network Adapter" "Bytes Sent/sec" $nicInstance.InstanceName
                        PacketsSentCounter = Build-EnglishCounterPath "Hyper-V Virtual Network Adapter" "Packets Sent/sec" $nicInstance.InstanceName
                    }
                }
            }
        }
        catch {
            Write-Warning "Failed to discover NIC instances for VM '$VMName': $($_.Exception.Message)"
        }

    }
    catch {
        Write-Warning "Failed to access VM '$VMName': $($_.Exception.Message)"
    }

    return $vmResources
}

function Get-PerformanceCounterValue
{
    param
    (
        [Parameter(Mandatory=$true)]
        [string]$CounterPath
    )

    try {
        # Parse the counter path to extract category, instance, and counter
        # Format: \Category(Instance)\Counter
        # Use non-greedy matching and be more careful with the regex
        if ($CounterPath -match '^\\([^(]+)\((.+)\)\\(.+)$') {
            $category = $matches[1].Trim()
            $instance = $matches[2]
            $counter = $matches[3]

            # Only quote if instance contains spaces (colons and dashes are usually OK in Get-Counter)
            if ($instance -like "* *") {
                $CounterPath = "\" + $category + '("' + $instance + '")' + "\" + $counter
            }
        }

        $result = (Get-Counter -Counter $CounterPath -ErrorAction Stop).CounterSamples
        if ($result -and $result.Count -gt 0) {
            $value = $result[0].CookedValue
            # Handle null or invalid values
            if ($value -eq $null) {
                return "ZBX_NOTSUPPORTED: Counter returned null value"
            }
            return [int]$value
        }
        else {
            return "ZBX_NOTSUPPORTED: Counter returned no data samples"
        }
    }
    catch {
        # Extract meaningful error information
        $errorMsg = $_.Exception.Message
        if ($errorMsg -like "*counter*not*found*" -or $errorMsg -like "*Indikator*nicht*gefunden*" -or $errorMsg -like "*nicht gefunden*") {
            return "ZBX_NOTSUPPORTED: Performance counter does not exist"
        }
        elseif ($errorMsg -like "*access*denied*" -or $errorMsg -like "*Zugriff*verweigert*") {
            return "ZBX_NOTSUPPORTED: Access denied to performance counter"
        }
        elseif ($errorMsg -like "*invalid*path*" -or $errorMsg -like "*ungültiger*Pfad*") {
            return "ZBX_NOTSUPPORTED: Invalid counter path format"
        }
        else {
            # Generic error with first 50 characters of error message
            $shortError = $errorMsg.Substring(0, [Math]::Min(50, $errorMsg.Length))
            return "ZBX_NOTSUPPORTED: $shortError"
        }
    }
}

try {
    $hostname = Get-WmiObject win32_computersystem | Select-Object -ExpandProperty name
}
catch {
    $hostname = $env:COMPUTERNAME  # Fallback to environment variable
}

# Initialize counter cache only if needed (not for simple counter value queries)
if ($QueryName -ne 'GetCounterValue' -and $QueryName -ne 'GetVMStatus' -and $QueryName -ne 'GetVMReplication') {
    Initialize-EnglishCounterCache
}

<# Main Logic #>

if ($QueryName -eq '' -or $QueryName -eq 'DiscoverVMs') {
    # Simple VM Discovery (same as original script)
    try {
        $colItems = Get-VM -ErrorAction Stop
    }
    catch {
        write-host "{"
        write-host ' "data":[]'
        write-host "}"
        Write-Warning "Error accessing Hyper-V VMs: $($_.Exception.Message)"
        exit 1
    }

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
elseif ($QueryName -eq 'DiscoverVMCounters' -and $VMName) {
    # Discover performance counters for a specific VM using proven logic from original script
    # VMName parameter format: "VMNAME_SAFE_VMHOST" (e.g., "sv101 _linux_SV03-HV")

    # Parse the VMName parameter to extract safe name and hostname
    # Format: "VMNAME_SAFE_VMHOST" (e.g., "sv101 _linux_SV03-HV")
    $vmHost = $hostname  # Default to current hostname
    $safeVMName = $VMName

    # Check if VMName contains hostname suffix with underscore
    $hostnameSuffix = "_" + $hostname
    if ($VMName.EndsWith($hostnameSuffix)) {
        # Remove the hostname suffix to get the safe VM name
        $safeVMName = $VMName.Substring(0, $VMName.Length - $hostnameSuffix.Length)
        $vmHost = $hostname
    }

    # Get the original VM name from the safe VM name
    try {
        $allVMs = Get-VM | Select-Object -ExpandProperty Name
        $originalVMName = $safeVMName  # Default fallback

        # Try to find original VM by comparing sanitized versions
        foreach ($vm in $allVMs) {
            $sanitizedVMName = Sanitize-VMName $vm
            if ($sanitizedVMName -eq $safeVMName) {
                $originalVMName = $vm
                break
            }
        }

        # If no match found, try exact match
        if ($originalVMName -eq $safeVMName -and $allVMs -contains $safeVMName) {
            $originalVMName = $safeVMName
        }

# Uncomment for debugging:
        # Write-Host "Debug: Input VMName: '$VMName'" -ForegroundColor Yellow
        # Write-Host "Debug: Parsed Safe VMName: '$safeVMName'" -ForegroundColor Yellow
        # Write-Host "Debug: Parsed VM Host: '$vmHost'" -ForegroundColor Yellow
        # Write-Host "Debug: Found Original VMName: '$originalVMName'" -ForegroundColor Yellow
    }
    catch {
        # Suppress warning messages that break JSON output
        write-host "{"
        write-host ' "data":[]'
        write-host "}"
        exit
    }

    $discoveryItems = @()

    # CPU Discovery using original script logic
    try {
        # Use the original script's CPU discovery logic
        $ItemType = "VMCPU"

        # Initialize counter cache
        if ($script:englishPerfHash -eq $null) {
            Initialize-EnglishCounterCache
        }


        # Build counter path for CPU discovery - use localized names from cache
        $localCategoryName = Get-LocalizedCounterName "Hyper-V Hypervisor Virtual Processor"
        $localCounterName = Get-LocalizedCounterName "% Total Run Time"

        $cpuCounterPath = "\$localCategoryName(*)\$localCounterName"

        try {
            $allCpuInstances = (Get-Counter -Counter $cpuCounterPath -ErrorAction Stop).CounterSamples

            if ($allCpuInstances -and $allCpuInstances.Count -gt 0) {
                # Create different VM name variations for matching
                $bracketsName = ($originalVMName -replace '\(', '[') -replace '\)', ']'
                $spacesName = $safeVMName -replace '_', ' '

                $vmNameVariations = @(
                    $originalVMName,
                    $safeVMName,
                    $bracketsName,  # Convert parentheses to brackets
                    $spacesName     # Convert underscores back to spaces for matching
                ) | Sort-Object -Unique

                $cpuResults = $allCpuInstances | Where-Object {
                    $instanceMatched = $false
                    foreach ($vmName in $vmNameVariations) {
                        # Escape square brackets for PowerShell -like operator
                        $escapedVmName = $vmName -replace '\[', '`[' -replace '\]', '`]'
                        if ($_.InstanceName -like "${escapedVmName}:*") {
                            $instanceMatched = $true
                            break
                        }
                    }
                    return $instanceMatched
                }

                foreach ($cpuInstance in $cpuResults) {
                    $discoveryItems += [PSCustomObject]@{
                        "{#VMNAME}" = $originalVMName
                        "{#VMNAME_SAFE}" = $safeVMName
                        "{#ITEM_TYPE}" = "CPU"
                        "{#INSTANCE}" = $cpuInstance.InstanceName
                        "{#COUNTER_PATH}" = "\Hyper-V Hypervisor Virtual Processor($($cpuInstance.InstanceName))\% Total Run Time"
                        "{#COUNTER_PATH_LOCAL}" = "\$localCategoryName($($cpuInstance.InstanceName))\$localCounterName"
                        "{#METRIC}" = "TotalRunTime"
                        "{#VMHOST}" = $vmHost
                    }
                }
            }
        }
        catch {
            # Suppress warning messages that break JSON output
        }
    }
    catch {
        # Suppress warning messages that break JSON output
    }

    # Disk Discovery using exact original script logic
    try {
        # Use Hyper-V cmdlets to get accurate VM disk instances (like original script)
        $diskInstances = Get-VMDiskInstances -VMName $originalVMName

        if ($diskInstances -and (($diskInstances | Measure-Object).Count -gt 0)) {
            # Deduplicate based on short name (disk file name) to avoid Hyper-V Replica duplicates
            $uniqueDisks = @{}
            $deduplicatedInstances = @()

            foreach ($disk in $diskInstances) {
                $shortName = Get-ShortResourceName $disk.InstanceName
                if (-not $uniqueDisks.ContainsKey($shortName)) {
                    $uniqueDisks[$shortName] = $true
                    $deduplicatedInstances += $disk
                }
            }

            foreach ($disk in $deduplicatedInstances) {
                $shortName = Get-ShortResourceName $disk.InstanceName

                # Get localized disk counter names
                $localDiskCategory = Get-LocalizedCounterName "Hyper-V Virtual Storage Device"
                $localReadBytesCounter = Get-LocalizedCounterName "Read Bytes/sec"
                $localWriteBytesCounter = Get-LocalizedCounterName "Write Bytes/sec"
                $localReadOpsCounter = Get-LocalizedCounterName "Read Operations/sec"
                $localWriteOpsCounter = Get-LocalizedCounterName "Write Operations/sec"

                # If localization returned English names, hardcode German names for German systems
                if ($localDiskCategory -eq "Hyper-V Virtual Storage Device") {
                    $localDiskCategory = "Virtuelle Hyper-V-Speichervorrichtung"
                }
                if ($localReadBytesCounter -eq "Read Bytes/sec") {
                    $localReadBytesCounter = "Gelesene Bytes/Sek."
                }
                if ($localWriteBytesCounter -eq "Write Bytes/sec") {
                    $localWriteBytesCounter = "Geschriebene Bytes/Sek."
                }
                if ($localReadOpsCounter -eq "Read Operations/sec") {
                    $localReadOpsCounter = "Lesevorgänge/s"
                }
                if ($localWriteOpsCounter -eq "Write Operations/sec") {
                    $localWriteOpsCounter = "Schreibvorgänge/s"
                }

                # Create counter paths for each disk metric
                $discoveryItems += [PSCustomObject]@{
                    "{#VMNAME}" = $originalVMName
                    "{#VMNAME_SAFE}" = $safeVMName
                    "{#ITEM_TYPE}" = "DISK"
                    "{#INSTANCE}" = $disk.InstanceName
                    "{#COUNTER_PATH}" = (Build-EnglishCounterPath "Hyper-V Virtual Storage Device" "Read Bytes/sec" $disk.InstanceName)
                    "{#COUNTER_PATH_LOCAL}" = (Build-LocalizedCounterPath $localDiskCategory $localReadBytesCounter $disk.InstanceName)
                    "{#METRIC}" = "ReadBytes"
                    "{#DISK_SHORT}" = $shortName
                    "{#VMHOST}" = $vmHost
                }
                $discoveryItems += [PSCustomObject]@{
                    "{#VMNAME}" = $originalVMName
                    "{#VMNAME_SAFE}" = $safeVMName
                    "{#ITEM_TYPE}" = "DISK"
                    "{#INSTANCE}" = $disk.InstanceName
                    "{#COUNTER_PATH}" = (Build-EnglishCounterPath "Hyper-V Virtual Storage Device" "Write Bytes/sec" $disk.InstanceName)
                    "{#COUNTER_PATH_LOCAL}" = (Build-LocalizedCounterPath $localDiskCategory $localWriteBytesCounter $disk.InstanceName)
                    "{#METRIC}" = "WriteBytes"
                    "{#DISK_SHORT}" = $shortName
                    "{#VMHOST}" = $vmHost
                }
                $discoveryItems += [PSCustomObject]@{
                    "{#VMNAME}" = $originalVMName
                    "{#VMNAME_SAFE}" = $safeVMName
                    "{#ITEM_TYPE}" = "DISK"
                    "{#INSTANCE}" = $disk.InstanceName
                    "{#COUNTER_PATH}" = (Build-EnglishCounterPath "Hyper-V Virtual Storage Device" "Read Operations/sec" $disk.InstanceName)
                    "{#COUNTER_PATH_LOCAL}" = (Build-LocalizedCounterPath $localDiskCategory $localReadOpsCounter $disk.InstanceName)
                    "{#METRIC}" = "ReadOps"
                    "{#DISK_SHORT}" = $shortName
                    "{#VMHOST}" = $vmHost
                }
                $discoveryItems += [PSCustomObject]@{
                    "{#VMNAME}" = $originalVMName
                    "{#VMNAME_SAFE}" = $safeVMName
                    "{#ITEM_TYPE}" = "DISK"
                    "{#INSTANCE}" = $disk.InstanceName
                    "{#COUNTER_PATH}" = (Build-EnglishCounterPath "Hyper-V Virtual Storage Device" "Write Operations/sec" $disk.InstanceName)
                    "{#COUNTER_PATH_LOCAL}" = (Build-LocalizedCounterPath $localDiskCategory $localWriteOpsCounter $disk.InstanceName)
                    "{#METRIC}" = "WriteOps"
                    "{#DISK_SHORT}" = $shortName
                    "{#VMHOST}" = $vmHost
                }
            }
        } else {
            # Fallback: try name-based matching with storage counter instances (like original script)
            $allStorageInstances = Get-StorageCounterInstances

            if ($allStorageInstances.Count -gt 0) {
                # Try matching with both original and safe VM names
                $baseVMName = $originalVMName -replace '_.*$', ''  # Remove _SV03-HV suffix
                $baseSafeVMName = $safeVMName -replace '_.*$', ''

                $matchedInstances = $allStorageInstances | Where-Object  {
                    $_.InstanceName -like '*-'+$originalVMName+'*' -or
                    $_.InstanceName -like '*-'+$safeVMName+'*' -or
                    $_.InstanceName -like '*'+$originalVMName+'*' -or
                    $_.InstanceName -like '*'+$safeVMName+'*' -or
                    $_.InstanceName -like '*-'+$baseVMName+'*' -or
                    $_.InstanceName -like '*-'+$baseSafeVMName+'*' -or
                    $_.InstanceName -like '*'+$baseVMName+'*' -or
                    $_.InstanceName -like '*'+$baseSafeVMName+'*'
                }

                # Deduplicate based on short name (disk file name) to avoid Hyper-V Replica duplicates
                $uniqueDisks = @{}
                $deduplicatedInstances = @()

                foreach ($instance in $matchedInstances) {
                    $shortName = Get-ShortResourceName $instance.InstanceName
                    if (-not $uniqueDisks.ContainsKey($shortName)) {
                        $uniqueDisks[$shortName] = $true
                        $deduplicatedInstances += $instance
                    }
                }

                foreach ($disk in $deduplicatedInstances) {
                    $shortName = Get-ShortResourceName $disk.InstanceName

                    # Get localized disk counter names
                    $localDiskCategory = Get-LocalizedCounterName "Hyper-V Virtual Storage Device"
                    $localReadBytesCounter = Get-LocalizedCounterName "Read Bytes/sec"
                    $localWriteBytesCounter = Get-LocalizedCounterName "Write Bytes/sec"
                    $localReadOpsCounter = Get-LocalizedCounterName "Read Operations/sec"
                    $localWriteOpsCounter = Get-LocalizedCounterName "Write Operations/sec"

                    # If localization returned English names, hardcode German names for German systems
                    if ($localDiskCategory -eq "Hyper-V Virtual Storage Device") {
                        $localDiskCategory = "Virtuelle Hyper-V-Speichervorrichtung"
                    }
                    if ($localReadBytesCounter -eq "Read Bytes/sec") {
                        $localReadBytesCounter = "Gelesene Bytes/Sek."
                    }
                    if ($localWriteBytesCounter -eq "Write Bytes/sec") {
                        $localWriteBytesCounter = "Geschriebene Bytes/Sek."
                    }
                    if ($localReadOpsCounter -eq "Read Operations/sec") {
                        $localReadOpsCounter = "Lesevorgänge/s"
                    }
                    if ($localWriteOpsCounter -eq "Write Operations/sec") {
                        $localWriteOpsCounter = "Schreibvorgänge/s"
                    }

                    # Create counter paths for each disk metric
                    $discoveryItems += [PSCustomObject]@{
                        "{#VMNAME}" = $originalVMName
                        "{#VMNAME_SAFE}" = $safeVMName
                        "{#ITEM_TYPE}" = "DISK"
                        "{#INSTANCE}" = $disk.InstanceName
                        "{#COUNTER_PATH}" = (Build-EnglishCounterPath "Hyper-V Virtual Storage Device" "Read Bytes/sec" $disk.InstanceName)
                        "{#COUNTER_PATH_LOCAL}" = (Build-LocalizedCounterPath $localDiskCategory $localReadBytesCounter $disk.InstanceName)
                        "{#METRIC}" = "ReadBytes"
                        "{#DISK_SHORT}" = $shortName
                        "{#VMHOST}" = $vmHost
                    }
                    $discoveryItems += [PSCustomObject]@{
                        "{#VMNAME}" = $originalVMName
                        "{#VMNAME_SAFE}" = $safeVMName
                        "{#ITEM_TYPE}" = "DISK"
                        "{#INSTANCE}" = $disk.InstanceName
                        "{#COUNTER_PATH}" = (Build-EnglishCounterPath "Hyper-V Virtual Storage Device" "Write Bytes/sec" $disk.InstanceName)
                        "{#COUNTER_PATH_LOCAL}" = (Build-LocalizedCounterPath $localDiskCategory $localWriteBytesCounter $disk.InstanceName)
                        "{#METRIC}" = "WriteBytes"
                        "{#DISK_SHORT}" = $shortName
                        "{#VMHOST}" = $vmHost
                    }
                    $discoveryItems += [PSCustomObject]@{
                        "{#VMNAME}" = $originalVMName
                        "{#VMNAME_SAFE}" = $safeVMName
                        "{#ITEM_TYPE}" = "DISK"
                        "{#INSTANCE}" = $disk.InstanceName
                        "{#COUNTER_PATH}" = (Build-EnglishCounterPath "Hyper-V Virtual Storage Device" "Read Operations/sec" $disk.InstanceName)
                        "{#COUNTER_PATH_LOCAL}" = (Build-LocalizedCounterPath $localDiskCategory $localReadOpsCounter $disk.InstanceName)
                        "{#METRIC}" = "ReadOps"
                        "{#DISK_SHORT}" = $shortName
                        "{#VMHOST}" = $vmHost
                    }
                    $discoveryItems += [PSCustomObject]@{
                        "{#VMNAME}" = $originalVMName
                        "{#VMNAME_SAFE}" = $safeVMName
                        "{#ITEM_TYPE}" = "DISK"
                        "{#INSTANCE}" = $disk.InstanceName
                        "{#COUNTER_PATH}" = (Build-EnglishCounterPath "Hyper-V Virtual Storage Device" "Write Operations/sec" $disk.InstanceName)
                        "{#COUNTER_PATH_LOCAL}" = (Build-LocalizedCounterPath $localDiskCategory $localWriteOpsCounter $disk.InstanceName)
                        "{#METRIC}" = "WriteOps"
                        "{#DISK_SHORT}" = $shortName
                        "{#VMHOST}" = $vmHost
                    }
                }
            }
        }
    }
    catch {
        # Suppress warning messages that break JSON output
    }

    # NIC Discovery using exact original script logic
    try {
        # Try multiple network counter categories using localized resolution (like original script)
        $networkCategories = @(
            (Get-LocalizedCounterName "Hyper-V Virtual Network Adapter"),
            "Virtuelle Hyper-V-Netzwerkkarte - vRSS",   # Specific vRSS category
            "Hyper-V Virtual Network Adapter"           # English fallback
        )

        $allNetworkInstances = @()
        foreach ($categoryName in $networkCategories) {
            try {
                $counterSet = Get-Counter -ListSet $categoryName -ErrorAction Stop
                if ($counterSet.Counter.Count -gt 0) {
                    $anyCounter = $counterSet.Counter[0]
                    $instances = (Get-Counter -Counter $anyCounter -ErrorAction Stop).CounterSamples
                    $allNetworkInstances += $instances
                }
            }
            catch {
                continue
            }
        }

        # Try matching with both original and safe VM names (like original script)
        $baseVMName = $originalVMName -replace '_.*$', ''  # Remove _SV03-HV suffix
        $baseSafeVMName = $safeVMName -replace '_.*$', ''

        $matchedInstances = $allNetworkInstances | Where-Object  {
            $_.InstanceName -like '*'+$originalVMName+'*' -or
            $_.InstanceName -like '*'+$safeVMName+'*' -or
            $_.InstanceName -like '*'+$baseVMName+'*' -or
            $_.InstanceName -like '*'+$baseSafeVMName+'*' -or
            $_.InstanceName -like $originalVMName+'_*' -or
            $_.InstanceName -like $safeVMName+'_*' -or
            $_.InstanceName -like $baseVMName+'_*' -or
            $_.InstanceName -like $baseSafeVMName+'_*'
        }

        # If no VM-specific matches found, return empty results instead of all interfaces
        if ($matchedInstances.Count -eq 0) {
            $matchedInstances = @()
        }

        # Deduplicate network interfaces by removing entry variants (like original script)
        # Keep only the main interface, filter out "entry_X" duplicates
        $deduplicatedInstances = @()
        $seenBaseNames = @{}

        # First pass: collect all main interfaces (without "entry_")
        foreach ($instance in $matchedInstances) {
            if ($instance.InstanceName -notlike "*_entry_*") {
                $shortName = Get-ShortResourceName $instance.InstanceName
                if (-not $seenBaseNames.ContainsKey($shortName)) {
                    $seenBaseNames[$shortName] = $true
                    $deduplicatedInstances += $instance
                }
            }
        }

        # Second pass: if no main interface found, take the first entry variant
        if ($deduplicatedInstances.Count -eq 0) {
            foreach ($instance in $matchedInstances) {
                $shortName = Get-ShortResourceName $instance.InstanceName
                if (-not $seenBaseNames.ContainsKey($shortName)) {
                    $seenBaseNames[$shortName] = $true
                    $deduplicatedInstances += $instance
                }
            }
        }

        foreach ($nic in $deduplicatedInstances) {
            $shortName = Get-ShortResourceName $nic.InstanceName -ResourceType "NIC"

            # Get localized NIC counter names
            $localNicCategory = Get-LocalizedCounterName "Hyper-V Virtual Network Adapter"
            $localBytesReceivedCounter = Get-LocalizedCounterName "Bytes Received/sec"
            $localBytesSentCounter = Get-LocalizedCounterName "Bytes Sent/sec"
            $localPacketsReceivedCounter = Get-LocalizedCounterName "Packets Received/sec"
            $localPacketsSentCounter = Get-LocalizedCounterName "Packets Sent/sec"

            # Create counter paths for each NIC metric
            $discoveryItems += [PSCustomObject]@{
                "{#VMNAME}" = $originalVMName
                "{#VMNAME_SAFE}" = $safeVMName
                "{#ITEM_TYPE}" = "NIC"
                "{#INSTANCE}" = $nic.InstanceName
                "{#COUNTER_PATH}" = (Build-EnglishCounterPath "Hyper-V Virtual Network Adapter" "Bytes Received/sec" $nic.InstanceName)
                "{#COUNTER_PATH_LOCAL}" = (Build-LocalizedCounterPath $localNicCategory $localBytesReceivedCounter $nic.InstanceName)
                "{#METRIC}" = "BytesReceived"
                "{#NIC_SHORT}" = $shortName
                "{#VMHOST}" = $vmHost
            }
            $discoveryItems += [PSCustomObject]@{
                "{#VMNAME}" = $originalVMName
                "{#VMNAME_SAFE}" = $safeVMName
                "{#ITEM_TYPE}" = "NIC"
                "{#INSTANCE}" = $nic.InstanceName
                "{#COUNTER_PATH}" = (Build-EnglishCounterPath "Hyper-V Virtual Network Adapter" "Bytes Sent/sec" $nic.InstanceName)
                "{#COUNTER_PATH_LOCAL}" = (Build-LocalizedCounterPath $localNicCategory $localBytesSentCounter $nic.InstanceName)
                "{#METRIC}" = "BytesSent"
                "{#NIC_SHORT}" = $shortName
                "{#VMHOST}" = $vmHost
            }
            $discoveryItems += [PSCustomObject]@{
                "{#VMNAME}" = $originalVMName
                "{#VMNAME_SAFE}" = $safeVMName
                "{#ITEM_TYPE}" = "NIC"
                "{#INSTANCE}" = $nic.InstanceName
                "{#COUNTER_PATH}" = (Build-EnglishCounterPath "Hyper-V Virtual Network Adapter" "Packets Received/sec" $nic.InstanceName)
                "{#COUNTER_PATH_LOCAL}" = (Build-LocalizedCounterPath $localNicCategory $localPacketsReceivedCounter $nic.InstanceName)
                "{#METRIC}" = "PacketsReceived"
                "{#NIC_SHORT}" = $shortName
                "{#VMHOST}" = $vmHost
            }
            $discoveryItems += [PSCustomObject]@{
                "{#VMNAME}" = $originalVMName
                "{#VMNAME_SAFE}" = $safeVMName
                "{#ITEM_TYPE}" = "NIC"
                "{#INSTANCE}" = $nic.InstanceName
                "{#COUNTER_PATH}" = (Build-EnglishCounterPath "Hyper-V Virtual Network Adapter" "Packets Sent/sec" $nic.InstanceName)
                "{#COUNTER_PATH_LOCAL}" = (Build-LocalizedCounterPath $localNicCategory $localPacketsSentCounter $nic.InstanceName)
                "{#METRIC}" = "PacketsSent"
                "{#NIC_SHORT}" = $shortName
                "{#VMHOST}" = $vmHost
            }
        }
    }
    catch {
        # Suppress warning messages that break JSON output
    }

    # Output JSON format
    write-host "{"
    write-host ' "data":['

    $n = $discoveryItems.Count
    foreach ($item in $discoveryItems) {
        $properties = @()
        $item.PSObject.Properties | ForEach-Object {
            # Properly escape JSON special characters
            $value = $_.Value
            $value = $value -replace '\\', '\\\\'  # Escape backslashes first
            $value = $value -replace '"', '\"'     # Escape quotes
            $value = $value -replace "`n", '\n'    # Escape newlines
            $value = $value -replace "`r", '\r'    # Escape carriage returns
            $value = $value -replace "`t", '\t'    # Escape tabs
            $properties += "`"$($_.Name)`":`"$value`""
        }

        $line = " {" + ($properties -join ",") + "}"
        if ($n -gt 1) {
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
elseif ($QueryName -eq 'GetCounterValue' -and $CounterPath) {
    # Get performance counter value directly using provided counter path
    $result = Get-PerformanceCounterValue -CounterPath $CounterPath
    write-host $result
    exit
}
elseif ($QueryName -eq 'GetVMStatus' -and $VMName) {
    # Get VM status - resolve safe VM name to original VM name first
    try {
        # Handle both safe and original VM names
        $originalVMName = $VMName
        $allVMs = Get-VM | Select-Object -ExpandProperty Name

        # First try exact match
        if ($allVMs -contains $VMName) {
            $originalVMName = $VMName
        } else {
            # Try to find original VM by comparing sanitized versions
            foreach ($vm in $allVMs) {
                if ((Sanitize-VMName $vm) -eq $VMName) {
                    $originalVMName = $vm
                    break
                }
            }
        }

        $vm = Get-VM -Name $originalVMName -ErrorAction Stop
        if ($vm) {
            write-host $vm.State
        } else {
            write-host "VM not found"
        }
    }
    catch {
        write-host "Error accessing Hyper-V: $($_.Exception.Message)"
    }
    exit
}
elseif ($QueryName -eq 'GetVMReplication' -and $VMName) {
    # Get VM replication status - resolve safe VM name to original VM name first
    try {
        # Handle both safe and original VM names
        $originalVMName = $VMName
        $allVMs = Get-VM | Select-Object -ExpandProperty Name

        # First try exact match
        if ($allVMs -contains $VMName) {
            $originalVMName = $VMName
        } else {
            # Try to find original VM by comparing sanitized versions
            foreach ($vm in $allVMs) {
                if ((Sanitize-VMName $vm) -eq $VMName) {
                    $originalVMName = $vm
                    break
                }
            }
        }

        # First check if the VM has replication enabled at all
        $vm = Get-VM -Name $originalVMName -ErrorAction Stop
        if ($vm.ReplicationState -eq "Disabled") {
            write-host "Off"
        } else {
            # VM has replication enabled, get the replication health
            $vmReplication = Get-VMReplication -VMName $originalVMName -ErrorAction Stop
            if ($vmReplication) {
                write-host $vmReplication.ReplicationHealth
            } else {
                write-host "Off"
            }
        }
    }
    catch {
        # Check if the error is specifically about replication not being enabled
        $errorMessage = $_.Exception.Message
        if ($errorMessage -like "*keine Replikation aktiviert*" -or
            $errorMessage -like "*replication is not enabled*" -or
            $errorMessage -like "*no replication*" -or
            $errorMessage -like "*not configured for replication*") {
            write-host "Off"
        } else {
            write-host "Error accessing VM replication: $errorMessage"
        }
    }
    exit
}
elseif ($QueryName -eq 'FindCounters') {
    # Find the actual Hyper-V counter names available on this system
    Write-Host "=== Finding Available Hyper-V Counters ===" -ForegroundColor Yellow

    try {
        # Get all available counter sets
        $allCounterSets = Get-Counter -ListSet "*" | Where-Object { $_.CounterSetName -like "*Hyper-V*" }

        Write-Host "`nFound $($allCounterSets.Count) Hyper-V counter sets:" -ForegroundColor Green

        foreach ($counterSet in $allCounterSets) {
            Write-Host "`n  Counter Set: '$($counterSet.CounterSetName)'" -ForegroundColor Cyan
            Write-Host "    Description: $($counterSet.Description)" -ForegroundColor Gray

            # Show first few counters from each set
            $sampleCounters = $counterSet.Counter | Select-Object -First 3
            foreach ($counter in $sampleCounters) {
                Write-Host "    - $counter" -ForegroundColor White
            }

            if ($counterSet.Counter.Count -gt 3) {
                Write-Host "    ... and $($counterSet.Counter.Count - 3) more counters" -ForegroundColor Gray
            }
        }
    }
    catch {
        Write-Host "Error getting counter sets: $($_.Exception.Message)" -ForegroundColor Red
    }

    exit
}
elseif ($QueryName -eq 'RebuildCache') {
    # Rebuild counter caches from scratch
    Write-Host "=== Rebuilding Counter Caches ===" -ForegroundColor Yellow

    # Get cache file paths
    $englishCacheFile = Get-CacheFilePath "english"
    $localizedCacheFile = Get-CacheFilePath "localized"

    # Create temporary file names
    $tempEnglishCacheFile = $englishCacheFile + ".tmp"
    $tempLocalizedCacheFile = $localizedCacheFile + ".tmp"

    # Clear script variables to force rebuild
    $script:englishPerfHash = $null
    $script:localizedCounterCache = $null

    try {
        # Force rebuild of English cache
        Write-Host "Building new English cache..." -ForegroundColor Cyan
        Initialize-EnglishCounterCache

        # Save to temporary file
        Save-CounterCache $script:englishPerfHash $tempEnglishCacheFile
        Write-Host "Built English cache with $($script:englishPerfHash.Count) entries" -ForegroundColor Green

        # Force rebuild of localized cache for all needed counters
        Write-Host "Building new localized cache..." -ForegroundColor Cyan
        $script:localizedCounterCache = @{}
        $neededCounters = Get-HyperVCounterNames

        foreach ($counterName in $neededCounters) {
            $localizedName = Get-LocalizedCounterName $counterName
            Write-Host "  '$counterName' -> '$localizedName'" -ForegroundColor Gray
        }

        # Save to temporary file
        Save-CounterCache $script:localizedCounterCache $tempLocalizedCacheFile
        Write-Host "Built localized cache with $($script:localizedCounterCache.Count) entries" -ForegroundColor Green

        # Atomic replacement: move temp files to final locations
        Write-Host "Replacing cache files..." -ForegroundColor Cyan

        if (Test-Path $englishCacheFile) {
            Remove-Item $englishCacheFile -Force
        }
        Move-Item $tempEnglishCacheFile $englishCacheFile
        Write-Host "Replaced English cache: $englishCacheFile" -ForegroundColor Green

        if (Test-Path $localizedCacheFile) {
            Remove-Item $localizedCacheFile -Force
        }
        Move-Item $tempLocalizedCacheFile $localizedCacheFile
        Write-Host "Replaced localized cache: $localizedCacheFile" -ForegroundColor Green

        Write-Host "Cache rebuild complete!" -ForegroundColor Yellow
    }
    catch {
        Write-Host "Error during cache rebuild: $($_.Exception.Message)" -ForegroundColor Red

        # Clean up temp files if they exist
        if (Test-Path $tempEnglishCacheFile) {
            Remove-Item $tempEnglishCacheFile -Force -ErrorAction SilentlyContinue
            Write-Host "Cleaned up temporary English cache file" -ForegroundColor Yellow
        }

        if (Test-Path $tempLocalizedCacheFile) {
            Remove-Item $tempLocalizedCacheFile -Force -ErrorAction SilentlyContinue
            Write-Host "Cleaned up temporary localized cache file" -ForegroundColor Yellow
        }
    }

    exit
}
elseif ($QueryName -eq 'TestCounters' -and $VMName) {
    # Test what storage and network counter categories are available
    Write-Host "=== Testing Available Counter Categories ===" -ForegroundColor Yellow

    # Test storage categories
    Write-Host "`nTesting Storage Categories:" -ForegroundColor Cyan
    $storageCategories = @(
        "Hyper-V Virtual Storage Device",
        "Virtuelle Hyper-V-Speichervorrichtung",
        "Hyper-V - virtueller IDE-Controller (emuliert)",
        "Hyper-V Virtual IDE Controller (Emulated)",
        "Hyper-V Virtual SCSI Controller",
        "Hyper-V Virtual NVMe Controller"
    )

    foreach ($category in $storageCategories) {
        try {
            $counterSet = Get-Counter -ListSet $category -ErrorAction Stop
            Write-Host "  ✓ FOUND: '$category' with $($counterSet.Counter.Count) counters" -ForegroundColor Green

            # Try to get instances
            if ($counterSet.Counter.Count -gt 0) {
                $firstCounter = $counterSet.Counter[0]
                try {
                    $instances = (Get-Counter -Counter $firstCounter -ErrorAction Stop).CounterSamples
                    Write-Host "    Sample instances ($($instances.Count)):"
                    $instances | Select-Object -First 3 | ForEach-Object {
                        Write-Host "      - $($_.InstanceName)"
                    }
                    if ($instances.Count -gt 3) {
                        Write-Host "      ... and $($instances.Count - 3) more"
                    }
                }
                catch {
                    Write-Host "    Could not get instances: $($_.Exception.Message)" -ForegroundColor Red
                }
            }
        }
        catch {
            Write-Host "  ✗ NOT FOUND: '$category'" -ForegroundColor Red
        }
    }

    # Test network categories
    Write-Host "`nTesting Network Categories:" -ForegroundColor Cyan
    $networkCategories = @(
        "Hyper-V Virtual Network Adapter",
        "Virtuelle Hyper-V-Netzwerkkarte",
        "Virtuelle Hyper-V-Netzwerkkarte - vRSS"
    )

    foreach ($category in $networkCategories) {
        try {
            $counterSet = Get-Counter -ListSet $category -ErrorAction Stop
            Write-Host "  ✓ FOUND: '$category' with $($counterSet.Counter.Count) counters" -ForegroundColor Green

            # Try to get instances
            if ($counterSet.Counter.Count -gt 0) {
                $firstCounter = $counterSet.Counter[0]
                try {
                    $instances = (Get-Counter -Counter $firstCounter -ErrorAction Stop).CounterSamples
                    Write-Host "    Sample instances ($($instances.Count)):"
                    $instances | Select-Object -First 3 | ForEach-Object {
                        Write-Host "      - $($_.InstanceName)"
                    }
                    if ($instances.Count -gt 3) {
                        Write-Host "      ... and $($instances.Count - 3) more"
                    }
                }
                catch {
                    Write-Host "    Could not get instances: $($_.Exception.Message)" -ForegroundColor Red
                }
            }
        }
        catch {
            Write-Host "  ✗ NOT FOUND: '$category'" -ForegroundColor Red
        }
    }

    # Test what the original script finds
    Write-Host "`nTesting Original Script Results:" -ForegroundColor Cyan
    try {
        Write-Host "Original disk discovery for '$VMName':"
        $diskResult = & .\zabbix-vm-perf.ps1 GetVMDisks $VMName
        $diskResult

        Write-Host "`nOriginal NIC discovery for '$VMName':"
        $nicResult = & .\zabbix-vm-perf.ps1 GetVMNICs $VMName
        $nicResult
    }
    catch {
        Write-Host "Error running original script: $($_.Exception.Message)" -ForegroundColor Red
    }

    exit
}
else {
    Write-Host "Error: Invalid parameters" -ForegroundColor Red
    Write-Host "Usage examples:" -ForegroundColor Yellow
    Write-Host "  .\hyper-v-monitoring.ps1                                              # VM discovery with performance counters" -ForegroundColor Gray
    Write-Host "  .\hyper-v-monitoring.ps1 DiscoverVMsWithCounters                     # Same as above" -ForegroundColor Gray
    Write-Host "  .\hyper-v-monitoring.ps1 GetCounterValue -CounterPath '\path\to\counter' # Get counter value" -ForegroundColor Gray
    Write-Host "  .\hyper-v-monitoring.ps1 GetVMStatus VMName                          # Get VM status" -ForegroundColor Gray
    Write-Host "  .\hyper-v-monitoring.ps1 GetVMReplication VMName                     # Get replication status" -ForegroundColor Gray
    exit 1
}