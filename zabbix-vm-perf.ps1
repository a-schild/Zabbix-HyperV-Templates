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

function Save-LocalizedCacheIfDirty
{
    # Save localized counter cache if it has been modified
    if ($script:localizedCacheDirty -and $script:localizedCounterCache) {
        $cacheFile = Get-CacheFilePath "localized"
        try {
            Save-CounterCache $script:localizedCounterCache $cacheFile
            $script:localizedCacheDirty = $false
        }
        catch {
            # Don't fail if cache save fails - just log warning
            Write-Warning "Failed to save localized counter cache: $($_.Exception.Message)"
        }
    }
}

function Exit-WithCacheSave
{
    param([int]$ExitCode = 0)
    Save-LocalizedCacheIfDirty
    exit $ExitCode
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

    # Mark cache as dirty for batch save at script end
    $script:localizedCacheDirty = $true

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

function Get-CounterNameVariations
{
    param($CounterName)

    $variations = @($CounterName)

    # Try common German localization variations
    if ($CounterName -like "*Sek.*") {
        $variations += $CounterName -replace "Sek\.", "s"
    }
    if ($CounterName -like "*s") {
        $variations += $CounterName -replace "s$", "Sek."
    }

    # Try CPU counter variations
    if ($CounterName -like "*Gesamtlaufzeit*") {
        $variations += $CounterName -replace "Gesamtlaufzeit", "Gesamte Laufzeit"
        $variations += $CounterName -replace "% Gesamtlaufzeit", "Gesamte Laufzeit in %"
    }

    return $variations
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
        $Instance = "*",
        [Parameter(Mandatory=$false)]
        [switch]$TryVariations
    )

    # Get localized names from English names
    $localCategoryName = Get-LocalizedCounterName $EnglishCategoryName
    $localCounterName = Get-LocalizedCounterName $EnglishCounterName

    # Quote instance names that contain spaces or special characters
    $quotedInstance = $Instance
    if ($Instance -ne "*" -and ($Instance -like "* *" -or $Instance -like "*:*" -or $Instance -like "*(*")) {
        $quotedInstance = "`"$Instance`""
    }

    if ($localCategoryName -and $localCounterName) {
        $counterPaths = @()

        if ($TryVariations) {
            # Try counter name variations
            $nameVariations = Get-CounterNameVariations $localCounterName
            foreach ($variation in $nameVariations) {
                $counterPaths += "\$localCategoryName($quotedInstance)\$variation"
            }
        }
        else {
            $counterPaths += "\$localCategoryName($quotedInstance)\$localCounterName"
        }

        # Always add English fallback as last resort
        $counterPaths += "\$EnglishCategoryName($quotedInstance)\$EnglishCounterName"

        return $counterPaths
    }
    else {
        # Fallback to English names if localization fails
        return @("\$EnglishCategoryName($quotedInstance)\$EnglishCounterName")
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

    # For disk instance names, don't try to resolve VM names - use the instance name directly
    if ($InstanceName -like "*hyper-v*" -and ($InstanceName -like "*vhd*" -or $InstanceName -like "*disk*")) {
        # This is likely a disk performance counter instance - try multiple categories

        # Disk counters can be in different categories depending on controller type
        $diskCategories = @(
            "Virtuelle Hyper-V-Speichervorrichtung",      # German - SCSI/VHD
            "Hyper-V - virtueller IDE-Controller (emuliert)"  # German - IDE
        )

        # Try each disk category to find the right controller type
        foreach ($category in $diskCategories) {
            # Get all possible counter path variations to try
            $counterPaths = Build-SafeCounterPath -EnglishCategoryName $category -EnglishCounterName $EnglishCounterName -Instance "*" -TryVariations

            foreach ($counterPath in $counterPaths) {
                try {
                    $allInstances = (Get-Counter -Counter $counterPath -ErrorAction Stop).CounterSamples

                    if ($allInstances) {
                        # Try to find an instance that matches our disk
                        # Extract key parts from the discovery instance name for matching
                        $fileName = Split-Path $InstanceName -Leaf -ErrorAction SilentlyContinue
                        $guidPattern = [regex]::Matches($InstanceName, '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}') | Select-Object -First 1

                        $matchingInstance = $allInstances | Where-Object {
                            $instance = $_.InstanceName
                            # Try multiple matching strategies
                            ($fileName -and $instance -like "*$fileName*") -or
                            ($guidPattern -and $instance -like "*$($guidPattern.Value)*") -or
                            ($instance -eq $InstanceName)
                        } | Select-Object -First 1

                        if ($matchingInstance) {
                            return $matchingInstance
                        }
                    }
                }
                catch {
                    # Try next counter name variation - silently continue
                }
            }
        }

        return $null
    }
    elseif ($InstanceName -like "*network adapter*" -or $InstanceName -like "*-*-*-*-*" -or $EnglishCategoryName -like "*Network*") {
        # This is likely a network adapter performance counter instance - try network categories

        # Network counters can be in different categories
        $networkCategories = @(
            "Virtueller Hyper-V-Netzwerkadapter",        # German
            "Virtuelle Hyper-V-Netzwerkkarte - vRSS",   # German vRSS
            "Hyper-V Virtual Network Adapter"           # English fallback
        )

        # Try each network category
        foreach ($category in $networkCategories) {
            # Get all possible counter path variations to try
            $counterPaths = Build-SafeCounterPath -EnglishCategoryName $category -EnglishCounterName $EnglishCounterName -Instance "*" -TryVariations

            foreach ($counterPath in $counterPaths) {
                try {
                    $allInstances = (Get-Counter -Counter $counterPath -ErrorAction Stop).CounterSamples

                    if ($allInstances) {
                        # Try to find an instance that matches our network adapter
                        # Extract GUID patterns for matching
                        $guidPatterns = [regex]::Matches($InstanceName, '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}')

                        $matchingInstance = $allInstances | Where-Object {
                            $instance = $_.InstanceName
                            # Try multiple matching strategies
                            ($instance -eq $InstanceName) -or
                            ($guidPatterns -and ($guidPatterns | ForEach-Object { $instance -like "*$($_.Value)*" } | Where-Object { $_ -eq $true }).Count -gt 0)
                        } | Select-Object -First 1

                        if ($matchingInstance) {
                            return $matchingInstance
                        }
                    }
                }
                catch {
                    # Try next counter name variation - silently continue
                }
            }
        }

        return $null
    }
    else {

        # This is likely a VM name - try VM name resolution
        $originalInstanceName = Get-OriginalVMName $InstanceName

        # Try with original instance name first (performance counters typically use original names)
        $counterPaths = Build-SafeCounterPath -EnglishCategoryName $EnglishCategoryName -EnglishCounterName $EnglishCounterName -Instance $originalInstanceName -TryVariations
        foreach ($counterPath in $counterPaths) {
            try {
                $result = (Get-Counter -Counter $counterPath -ErrorAction Stop).CounterSamples
                if ($result) {
                    return $result
                }
            }
            catch {
                # Try next variation silently
            }
        }

        # Try with the provided instance name if it's different from original
        if ($InstanceName -ne $originalInstanceName) {
            $counterPaths = Build-SafeCounterPath -EnglishCategoryName $EnglishCategoryName -EnglishCounterName $EnglishCounterName -Instance $InstanceName -TryVariations
            foreach ($counterPath in $counterPaths) {
                try {
                    $result = (Get-Counter -Counter $counterPath -ErrorAction Stop).CounterSamples
                    if ($result) {
                        return $result
                    }
                }
                catch {
                    # Try next variation silently
                }
            }
        }

        # Try with hp->hv conversion for CPU instances (hp is used in discovery, hv in performance counters)
        if ($EnglishCategoryName -like "*Virtual Processor*" -and $InstanceName -like "*:hp vp *") {
            $hvInstanceName = $InstanceName -replace ":hp vp ", ":hv vp "

            # Get all CPU instances and find exact match
            try {
                $listPath = "\Hyper-V Hypervisor: virtueller Prozessor(*)\% Gesamtlaufzeit"
                $allInstances = (Get-Counter -Counter $listPath -ErrorAction Stop).CounterSamples
                $exactMatch = $allInstances | Where-Object { $_.InstanceName -eq $hvInstanceName }
                if ($exactMatch) {
                    return $exactMatch
                }
            }
            catch {
                # Failed to get instance list, try individual counter paths
            }

            # Try direct English counter path
            try {
                $englishPath = "\Hyper-V Hypervisor Virtual Processor(`"$hvInstanceName`")\% Total Run Time"
                $result = (Get-Counter -Counter $englishPath -ErrorAction Stop).CounterSamples
                if ($result -and $result.Count -gt 0) {
                    return $result[0]  # Return the first counter sample
                }
            }
            catch {
                # English path failed, try other variations
            }

            # If English failed, try the localized paths
            $counterPaths = Build-SafeCounterPath -EnglishCategoryName $EnglishCategoryName -EnglishCounterName $EnglishCounterName -Instance $hvInstanceName -TryVariations
            foreach ($counterPath in $counterPaths) {
                try {
                    $result = (Get-Counter -Counter $counterPath -ErrorAction Stop).CounterSamples
                    if ($result -and $result.Count -gt 0) {
                        return $result[0]  # Return the first counter sample
                    }
                }
                catch {
                    # Try next variation silently
                }
            }
        }

        # Try with sanitized instance name as last resort for VM instances
        $safeInstanceName = Sanitize-VMName $originalInstanceName
        if ($safeInstanceName -ne $originalInstanceName -and $safeInstanceName -ne $InstanceName) {
            $counterPaths = Build-SafeCounterPath -EnglishCategoryName $EnglishCategoryName -EnglishCounterName $EnglishCounterName -Instance $safeInstanceName -TryVariations
            foreach ($counterPath in $counterPaths) {
                try {
                    $result = (Get-Counter -Counter $counterPath -ErrorAction Stop).CounterSamples
                    if ($result) {
                        return $result
                    }
                }
                catch {
                    # Try next variation silently
                }
            }
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

function Get-ShortResourceName
{
    param
    (
        [Parameter(Mandatory=$true)]
        [string]$FullName,
        [Parameter(Mandatory=$false)]
        [int]$MaxLength = 20
    )

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

try {
    $hostname = Get-WmiObject win32_computersystem | Select-Object -ExpandProperty name
}
catch {
    $hostname = $env:COMPUTERNAME  # Fallback to environment variable
}

<# Zabbix Hyper-V Virtual Machine Discovery #>
if ($QueryName -eq '') {

    try {
        $colItems = Get-VM -ErrorAction Stop
    }
    catch {
        write-host "{"
        write-host ' "data":[]'
        write-host "}"
        Write-Warning "Error accessing Hyper-V VMs: $($_.Exception.Message)"
        Exit-WithCacheSave 1
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
    Exit-WithCacheSave
}

<# Zabbix Hyper-V VM Perf Counter Discovery #>

# Define diagnostic commands that don't require VM names
$diagnosticCommands = @(
    "SearchStorageCounters",
    "SearchNetworkCounters",
    "SearchAllCounters",
    "FindHyperVCounters",
    "SearchCPUCounters",
    "TestCPUMatching",
    "ClearCache"
)

if ($psboundparameters.Count -eq 2) {
    # Skip VM name processing for diagnostic commands
    if ($QueryName -in $diagnosticCommands) {
        # For diagnostic commands, set empty VM names to avoid parameter binding errors
        $originalVMName = ""
        $safeVMName = ""
        $originalVMObject = ""
        $safeVMObject = ""
    } else {
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
	elseif ($QueryName -eq "SearchNetworkCounters")
	{
		# Search specifically for network counter instances
		Write-Host "Searching for Hyper-V network counter instances..."

		$networkCategories = @(
			"Virtueller Hyper-V-Netzwerkadapter",
			"Virtuelle Hyper-V-Netzwerkkarte - vRSS",
			"RemoteFX-Netzwerk",
			"Hyper-V Virtual Network Adapter",
			"Netzwerkschnittstelle",
			"Netzwerkadapter"
		)

		foreach ($categoryName in $networkCategories) {
			Write-Host "`nTrying category: '$categoryName'"
			try {
				$counterSet = Get-Counter -ListSet $categoryName -ErrorAction Stop
				Write-Host "  Category exists with $($counterSet.Counter.Count) counters"

				if ($counterSet.Counter.Count -gt 0) {
					$firstCounter = $counterSet.Counter[0]
					$counterName = $firstCounter.Split('(')[0].Split('\')[-1]
					Write-Host "  Using counter: $counterName"

					$instances = (Get-Counter -Counter $firstCounter -ErrorAction Stop).CounterSamples
					Write-Host "  Found $($instances.Count) instances:"

					foreach ($instance in $instances) {
						Write-Host "    - $($instance.InstanceName)"
					}
				}
			}
			catch {
				Write-Host "  Category not available: $($_.Exception.Message)"
			}
		}

		# Also check if the VM has network adapters configured
		Write-Host "`nChecking VM network adapter configuration..."
		try {
			$originalVMName = Get-OriginalVMName $VMName
			$vm = Get-VM -Name $originalVMName -ErrorAction Stop
			$networkAdapters = Get-VMNetworkAdapter -VM $vm -ErrorAction Stop

			Write-Host "VM '$originalVMName' has $($networkAdapters.Count) network adapters:"
			foreach ($adapter in $networkAdapters) {
				Write-Host "  - Name: $($adapter.Name)"
				Write-Host "    Switch: $($adapter.SwitchName)"
				Write-Host "    Status: $($adapter.Status)"
				Write-Host "    MAC: $($adapter.MacAddress)"
			}
		}
		catch {
			Write-Host "Error checking VM network adapters: $($_.Exception.Message)"
		}
		exit
	}
	elseif ($QueryName -eq "SearchStorageCounters")
	{
		# Search specifically for storage counter instances
		Write-Host "Searching for Hyper-V storage counter instances..."

		$storageCategories = @(
			"Virtuelle Hyper-V-Speichervorrichtung",
			"Hyper-V Virtual Storage Device",
			"PhysicalDisk",
			"LogicalDisk"
		)

		foreach ($categoryName in $storageCategories) {
			Write-Host "`nTrying category: '$categoryName'"
			try {
				$counterSet = Get-Counter -ListSet $categoryName -ErrorAction Stop
				Write-Host "  Category exists with $($counterSet.Counter.Count) counters"

				if ($counterSet.Counter.Count -gt 0) {
					$firstCounter = $counterSet.Counter[0]
					$counterName = $firstCounter.Split('(')[0].Split('\')[-1]
					Write-Host "  Using counter: $counterName"

					$instances = (Get-Counter -Counter $firstCounter -ErrorAction Stop).CounterSamples
					Write-Host "  Found $($instances.Count) instances:"

					foreach ($instance in $instances) {
						Write-Host "    - $($instance.InstanceName)"
					}
				}
			}
			catch {
				Write-Host "  Category not available: $($_.Exception.Message)"
			}
		}
		exit
	}
	elseif ($QueryName -eq "SearchAllCounters")
	{
		# Search ALL counter categories for any that might contain VM network instances
		Write-Host "Searching ALL performance counter categories..."

		try {
			$allCounterSets = Get-Counter -ListSet "*"
			Write-Host "Found $($allCounterSets.Count) total counter categories"

			Write-Host "`nLooking for categories that might contain VM network instances..."
			foreach ($set in $allCounterSets) {
				try {
					# Get first counter from this category
					if ($set.Counter.Count -gt 0) {
						$firstCounter = $set.Counter[0]
						$instances = (Get-Counter -Counter $firstCounter -ErrorAction Stop).CounterSamples

						# Check if any instances match our VM patterns
						$vmMatches = $instances | Where-Object {
							$_.InstanceName -like '*sv101*' -or
							$_.InstanceName -like '*linux*' -or
							$_.InstanceName -like '*:*' -and $_.InstanceName -like '*adapter*'
						}

						if ($vmMatches.Count -gt 0) {
							Write-Host "`nFOUND POTENTIAL MATCH:"
							Write-Host "Category: $($set.CounterSetName)"
							Write-Host "Matching instances:"
							$vmMatches | ForEach-Object { Write-Host "  - $($_.InstanceName)" }
						}
					}
				}
				catch {
					# Ignore categories that fail to query
				}
			}
		}
		catch {
			Write-Warning "Error searching counters: $($_.Exception.Message)"
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
				$_.CounterSetName -like "*Storage*" -or
				$_.CounterSetName -like "*Netzwerk*" -or
				$_.CounterSetName -like "*Network*" -or
				$_.CounterSetName -like "*Adapter*"
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
				$_.CounterSetName -like "*Datenträger*" -or
				$_.CounterSetName -like "*Netzwerk*" -or
				$_.CounterSetName -like "*Network*" -or
				$_.CounterSetName -like "*Adapter*" -or
				$_.CounterSetName -like "*NIC*"
			} | ForEach-Object {
				Write-Host "- $($_.CounterSetName)"
			}
		}
		catch {
			Write-Warning "Error finding counters: $($_.Exception.Message)"
		}
		exit
	}
	elseif ($QueryName -eq "SearchCPUCounters")
	{
		# Search specifically for CPU counter instances
		Write-Host "Searching for Hyper-V CPU counter instances..."

		$cpuCategories = @(
			"Hyper-V Hypervisor Virtual Processor",
			"Hyper-V Hypervisor Logical Processor",
			"Processor",
			"Prozessor"
		)

		foreach ($categoryName in $cpuCategories) {
			Write-Host "`nTrying category: '$categoryName'"
			try {
				$counterSet = Get-Counter -ListSet $categoryName -ErrorAction Stop
				Write-Host "  Category exists with $($counterSet.Counter.Count) counters"

				if ($counterSet.Counter.Count -gt 0) {
					# Look for Total Run Time or similar counter
					$runTimeCounter = $counterSet.Counter | Where-Object { $_ -like "*Total Run Time*" -or $_ -like "*Laufzeit*" } | Select-Object -First 1
					if ($runTimeCounter) {
						$counterName = $runTimeCounter.Split('(')[0].Split('\')[-1]
						Write-Host "  Using counter: $counterName"

						$instances = (Get-Counter -Counter $runTimeCounter -ErrorAction Stop).CounterSamples
						Write-Host "  Found $($instances.Count) instances:"

						foreach ($instance in $instances) {
							Write-Host "    - $($instance.InstanceName)"
						}
					} else {
						Write-Host "  No suitable run time counter found"
					}
				}
			}
			catch {
				Write-Host "  Category not available: $($_.Exception.Message)"
			}
		}

		# Try to build the safe counter path and test it
		Write-Host "`n=== Testing Build-SafeCounterPath ==="
		try {
			$counterPath = Build-SafeCounterPath -EnglishCategoryName "Hyper-V Hypervisor Virtual Processor" -EnglishCounterName "% Total Run Time" -Instance "*"
			Write-Host "Built counter path: $counterPath"

			$testResult = Test-PerformanceCounter $counterPath
			Write-Host "Counter path test result: $testResult"

			if ($testResult) {
				$samples = (Get-Counter -Counter $counterPath -ErrorAction Stop).CounterSamples
				Write-Host "Successfully retrieved $($samples.Count) samples:"
				$samples | ForEach-Object { Write-Host "  - $($_.InstanceName)" }
			}
		}
		catch {
			Write-Host "Error testing counter path: $($_.Exception.Message)"
		}
		exit
	}
	elseif ($QueryName -eq "TestCPUMatching")
	{
		# Test CPU matching logic with the VM name from VMName parameter
		$testVMName = $VMName
		Write-Host "Testing CPU matching for VM: '$testVMName'"

		# Get the original VM name if we received a sanitized one
		$originalVMName = Get-OriginalVMName $testVMName
		$safeVMName = Sanitize-VMName $originalVMName

		Write-Host "Original VM name: '$originalVMName'"
		Write-Host "Safe VM name: '$safeVMName'"

		# Build counter path
		$counterPath = Build-SafeCounterPath -EnglishCategoryName "Hyper-V Hypervisor Virtual Processor" -EnglishCounterName "% Total Run Time" -Instance "*"
		Write-Host "Counter path: $counterPath"

		# Get all CPU instances
		$allCpuInstances = (Get-Counter -Counter $counterPath -ErrorAction SilentlyContinue).CounterSamples
		Write-Host "Total CPU instances found: $($allCpuInstances.Count)"

		# Create different VM name variations for matching
		$bracketsName = ($originalVMName -replace '\(', '[') -replace '\)', ']'
		$spacesName = $safeVMName -replace '_', ' '

		$vmNameVariations = @(
			$originalVMName,
			$safeVMName,
			$bracketsName,  # Convert parentheses to brackets
			$spacesName     # Convert underscores back to spaces for matching
		) | Sort-Object -Unique

		Write-Host "VM name variations to test:"
		foreach ($variation in $vmNameVariations) {
			Write-Host "  - '$variation'"
		}

		Write-Host "`nTesting matches:"
		foreach ($instance in $allCpuInstances) {
			$instanceMatched = $false
			$matchedVariation = ""
			foreach ($vmName in $vmNameVariations) {
				if ($instance.InstanceName -like "${vmName}:*") {
					$instanceMatched = $true
					$matchedVariation = $vmName
					break
				}
			}

			if ($instanceMatched) {
				Write-Host "  MATCH: '$($instance.InstanceName)' matched variation '$matchedVariation'"
			} else {
				# Only show first few non-matches to avoid spam
				if ($allCpuInstances.IndexOf($instance) -lt 5) {
					Write-Host "  no match: '$($instance.InstanceName)'"
				}
			}
		}
		exit
	}
	elseif ($QueryName -eq 'GetVMStatus')
	{
		# Try with original VM name first, then with provided name
		$originalVMName = Get-OriginalVMName $VMName
		try {
			$vm = Get-VM | Where-Object {$_.Name -eq $originalVMName -or $_.Name -eq $VMName} -ErrorAction Stop
			if ($vm) {
				$Results = $vm.State
			} else {
				$Results = "VM not found"
			}
		}
		catch {
			$Results = "Error accessing Hyper-V: $($_.Exception.Message)"
		}
		write-host $Results
		exit
	}
	elseif ($QueryName -eq 'GetVMReplication')
	{
		# Try with original VM name first, then with provided name
		$originalVMName = Get-OriginalVMName $VMName
		try {
			$vmReplication = Get-VMReplication | Where-Object {$_.VMName -eq $originalVMName -or $_.VMName -eq $VMName} -ErrorAction Stop
			if ($vmReplication) {
				$Results = $vmReplication.ReplicationHealth
			} else {
				$Results = "VM replication not found"
			}
		}
		catch {
			$Results = "Error accessing VM replication: $($_.Exception.Message)"
		}
		write-host $Results
		exit
	}
	elseif ($QueryName -eq 'GetVMCPUs')
	{
		$ItemType = "VMCPU"

		# Try direct German counter path that we know works
		$counterName = "\Hyper-V Hypervisor: virtueller Prozessor(*)\% Gesamtlaufzeit"

		try {
			$allCpuInstances = (Get-Counter -Counter $counterName -ErrorAction Stop).CounterSamples
		}
		catch {
			# Fallback to English counter path
			try {
				$counterName = "\Hyper-V Hypervisor Virtual Processor(*)\% Total Run Time"
				$allCpuInstances = (Get-Counter -Counter $counterName -ErrorAction Stop).CounterSamples
			}
			catch {
				$allCpuInstances = @()
			}
		}

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


			$Results = $allCpuInstances | Where-Object {
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
			} | select InstanceName

			# If no matches found, return empty results
			if (($Results | Measure-Object).Count -eq 0) {
				$Results = @()
			}
		}
		else {
			$Results = @()
		}

		# Output JSON format
		write-host "{"
		write-host ' "data":['
		write-host

		$n = ($Results | measure).Count
		foreach ($objItem in $Results) {
			# Convert hv back to hp for discovery (monitoring will convert hp->hv internally)
			$discoveryInstanceName = $objItem.InstanceName -replace ":hv vp ", ":hp vp "
			$line = ' { "{#'+$ItemType+'}":"'+$discoveryInstanceName+'"}'

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
	elseif ($QueryName -eq 'GetVMDisks')
	{
		$ItemType = "VMDISK"

		# Use Hyper-V cmdlets to get accurate VM disk instances
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

			$Results = $deduplicatedInstances | Select-Object @{
				Name="InstanceName"
				Expression={$_.InstanceName}
			}, @{
				Name="ShortName"
				Expression={Get-ShortResourceName $_.InstanceName}
			}
		} else {
			# Fallback: try name-based matching with storage counter instances
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

				$Results = $deduplicatedInstances | Select-Object @{
					Name="InstanceName"
					Expression={$_.InstanceName}
				}, @{
					Name="ShortName"
					Expression={Get-ShortResourceName $_.InstanceName}
				}
			} else {
				$Results = @()
			}
		}

		# Output JSON format
		write-host "{"
		write-host ' "data":['
		write-host

		$n = ($Results | measure).Count
		foreach ($objItem in $Results) {
			if ($objItem.ShortName) {
				$line = ' { "{#'+$ItemType+'}":"'+$objItem.InstanceName+'", "{#'+$ItemType+'_SHORT}":"'+$objItem.ShortName+'"}'
			} else {
				$line = ' { "{#'+$ItemType+'}":"'+$objItem.InstanceName+'"}'
			}

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
	elseif ($QueryName -eq 'GetVMNICs')
	{
		$ItemType = "VMNIC"

		# Try multiple network counter categories found on German systems
		$networkCategories = @(
			"Virtueller Hyper-V-Netzwerkadapter",
			"Virtuelle Hyper-V-Netzwerkkarte - vRSS",
			"Hyper-V Virtual Network Adapter"  # English fallback
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

		# Try matching with both original and safe VM names
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
		# The previous behavior of returning all interfaces was too broad
		if ($matchedInstances.Count -eq 0) {
			$matchedInstances = @()
		}

		# Deduplicate network interfaces by removing entry variants
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

		$Results = $deduplicatedInstances | Select-Object @{
			Name="InstanceName"
			Expression={$_.InstanceName}
		}, @{
			Name="ShortName"
			Expression={Get-ShortResourceName $_.InstanceName}
		}

		# Output JSON format
		write-host "{"
		write-host ' "data":['
		write-host

		$n = ($Results | measure).Count
		foreach ($objItem in $Results) {
			if ($objItem.ShortName) {
				$line = ' { "{#'+$ItemType+'}":"'+$objItem.InstanceName+'", "{#'+$ItemType+'_SHORT}":"'+$objItem.ShortName+'"}'
			} else {
				$line = ' { "{#'+$ItemType+'}":"'+$objItem.InstanceName+'"}'
			}

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
elseif ($psboundparameters.Count -eq 3)
{
    if ($QueryName -eq 'GetVMReplication')
    {
        # Try with original VM name first, then with provided name
        $originalVMName = Get-OriginalVMName $VMName
        try {
            $vmReplication = Get-VMReplication | Where-Object {$_.VMName -eq $originalVMName -or $_.VMName -eq $VMName} -ErrorAction Stop
            if ($vmReplication) {
                $Results = $vmReplication.ReplicationHealth
            } else {
                $Results = "VM replication not found"
            }
        }
        catch {
            $Results = "Error accessing VM replication: $($_.Exception.Message)"
        }
        write-host $Results
        exit
    }
    elseif ($QueryName -eq 'GetVMStatus')
    {
        # Try with original VM name first, then with provided name
        $originalVMName = Get-OriginalVMName $VMName
        try {
            $vm = Get-VM | Where-Object {$_.Name -eq $originalVMName -or $_.Name -eq $VMName} -ErrorAction Stop
            if ($vm) {
                $Results = $vm.State
            } else {
                $Results = "VM not found"
            }
        }
        catch {
            $Results = "Error accessing Hyper-V: $($_.Exception.Message)"
        }
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

        Exit-WithCacheSave
    }
}
else {
	switch ($QueryName) {

			('GetVMDisks'){
				$ItemType = "VMDISK"

				# Use Hyper-V cmdlets to get accurate VM disk instances
				$diskInstances = Get-VMDiskInstances -VMName $originalVMName

				if ($diskInstances -and (($diskInstances | Measure-Object).Count -gt 0)) {
					$Results = $diskInstances | Select-Object @{
						Name="InstanceName"
						Expression={$_.InstanceName}
					}, @{
						Name="ShortName"
						Expression={Get-ShortResourceName $_.InstanceName}
					}
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
						} | Select-Object @{
							Name="InstanceName"
							Expression={$_.InstanceName}
						}, @{
							Name="ShortName"
							Expression={Get-ShortResourceName $_.InstanceName}
						}
					} else {
						$Results = @()
					}
				}
			}

			('GetVMNICs'){
				$ItemType = "VMNIC"

				# Try multiple network counter categories found on German systems
				$networkCategories = @(
					"Virtueller Hyper-V-Netzwerkadapter",
					"Virtuelle Hyper-V-Netzwerkkarte - vRSS",
					"Hyper-V Virtual Network Adapter"  # English fallback
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

				# Try matching with both original and safe VM names
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

				# If no VM-specific matches found and we have instances, return all available
				# This helps when VM access is restricted due to permissions
				if ($matchedInstances.Count -eq 0 -and $allNetworkInstances.Count -gt 0) {
					$matchedInstances = $allNetworkInstances
				}

				$Results = $matchedInstances | Select-Object @{
					Name="InstanceName"
					Expression={$_.InstanceName}
				}, @{
					Name="ShortName"
					Expression={Get-ShortResourceName $_.InstanceName}
				}
			}

			('GetVMCPUs'){
				$ItemType  ="VMCPU"

				# Try direct German counter path that we know works
				$counterName = "\Hyper-V Hypervisor: virtueller Prozessor(*)\% Gesamtlaufzeit"

				try {
					$allCpuInstances = (Get-Counter -Counter $counterName -ErrorAction Stop).CounterSamples
				}
				catch {
					# Fallback to English counter path
					try {
						$counterName = "\Hyper-V Hypervisor Virtual Processor(*)\% Total Run Time"
						$allCpuInstances = (Get-Counter -Counter $counterName -ErrorAction Stop).CounterSamples
					}
					catch {
						$allCpuInstances = @()
					}
				}

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

					$Results = $allCpuInstances | Where-Object {
						$instanceMatched = $false
						foreach ($vmName in $vmNameVariations) {
							if ($_.InstanceName -like "${vmName}:*") {
								$instanceMatched = $true
								break
							}
						}
						return $instanceMatched
					} | select InstanceName

					# Debug: if no matches found, show what instances are available
					if (($Results | Measure-Object).Count -eq 0) {
						Write-Warning "No CPU instances matched for VM '$originalVMName' or '$safeVMName'"
						Write-Warning "Available CPU instances:"
						$allCpuInstances | ForEach-Object { Write-Warning "  - $($_.InstanceName)" }
						$Results = @()
					}
					else {
						Write-Warning "Found $($Results.Count) CPU instances for VM '$originalVMName'"
					}
				}
				else {
					Write-Warning "Could not access counter: $counterName"
					$Results = @()
				}
			}

			default {$Results = "Bad Request"; write-host $Results; exit}
			}

		write-host "{"
		write-host ' "data":['
		write-host
		#write-host $Results


		$n = ($Results | measure).Count

		foreach ($objItem in $Results) {
			if ($objItem.ShortName) {
				$line = ' { "{#'+$ItemType+'}":"'+$objItem.InstanceName+'", "{#'+$ItemType+'_SHORT}":"'+$objItem.ShortName+'"}'
			} else {
				$line = ' { "{#'+$ItemType+'}":"'+$objItem.InstanceName+'"}'
			}

			if ($n -gt 1 ){
				$line += ","
			}

			write-host $line
			$n--
		}

		write-host " ]"
		write-host "}"
		write-host

		Exit-WithCacheSave
}



