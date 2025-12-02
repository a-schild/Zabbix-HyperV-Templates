# Zabbix LLD Discovery Script for Hyper-V VMs
# For Zabbix 7.0+ JSON format (direct array)

param(
    [string]$DiscoveryType = "vms",
    [string]$VmId = "",
    [switch]$Debug = $false
)

# Make sure to output the json names correctly encoded
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8


function Write-DebugInfo {
    param($Message)
    if ($Debug) {
        Write-Host "DEBUG: $Message" -ForegroundColor Yellow
    }
}

# Force English culture for consistent output regardless of system locale
$originalCulture = [System.Threading.Thread]::CurrentThread.CurrentCulture
$originalUICulture = [System.Threading.Thread]::CurrentThread.CurrentUICulture

try {
    Write-DebugInfo "Setting culture to en-US for consistent English output"

    # Set culture to English at multiple levels
    $enUSCulture = [System.Globalization.CultureInfo]::GetCultureInfo("en-US")
    [System.Threading.Thread]::CurrentThread.CurrentCulture = $enUSCulture
    [System.Threading.Thread]::CurrentThread.CurrentUICulture = $enUSCulture

    # Set environment variables for child processes
    [System.Environment]::SetEnvironmentVariable("LANG", "en-US", "Process")
    [System.Environment]::SetEnvironmentVariable("LC_ALL", "en-US.UTF-8", "Process")
    [System.Environment]::SetEnvironmentVariable("LANGUAGE", "en-US", "Process")

    # Import Hyper-V module with English culture (only if not already loaded)
    if (-not (Get-Module -Name Hyper-V)) {
        Write-DebugInfo "Importing Hyper-V module with English culture"
        Import-Module Hyper-V -ErrorAction Stop
    } else {
        Write-DebugInfo "Hyper-V module already loaded, skipping import"
    }

    Write-DebugInfo "Culture successfully set to en-US and Hyper-V module reloaded"
} catch {
    Write-DebugInfo "Could not set culture or reload module: $($_.Exception.Message)"
}

# Convert localized terms to English while preserving original values
function ConvertToEnglish {
    param($Value)

    if ([string]::IsNullOrEmpty($Value)) {
        return $Value
    }

    # Comprehensive translation mapping for multiple languages
    $translations = @{
        # German translations
        "Netzwerkkarte" = "Network Adapter"
        "Ältere Netzwerkkarte" = "Legacy Network Adapter"
        "Gastdienstschnittstelle" = "Guest Service Interface"
        "Takt" = "Heartbeat"
        "Austausch von Schlüsselwertepaaren" = "Key-Value Pair Exchange"
        "Herunterfahren" = "Shutdown"
        "Zeitsynchronisierung" = "Time Synchronization"
        "Kein Kontakt" = "No contact"
        "Normaler Betrieb" = "Operating normally"
        "VSS" = "VSS"
        "Wird heruntergefahren" = "Shutting down"
        "Wird gestartet" = "Starting up"
        "Angehalten" = "Paused"
        "Gespeichert" = "Saved"
        "Fehler" = "Error"

        # French translations
        "Carte réseau" = "Network Adapter"
        "Carte réseau héritée" = "Legacy Network Adapter"
        "Interface de service invité" = "Guest Service Interface"
        "Pulsation" = "Heartbeat"
        "Échange de paires clé-valeur" = "Key-Value Pair Exchange"
        "Arrêt" = "Shutdown"
        "Synchronisation de l'heure" = "Time Synchronization"
        "Aucun contact" = "No contact"
        "Fonctionnement normal" = "Operating normally"
        "Erreur" = "Error"
        "Arrêt en cours" = "Shutting down"
        "Démarrage" = "Starting up"
        "En pause" = "Paused"
        "Enregistré" = "Saved"

        # Spanish translations
        "Adaptador de red" = "Network Adapter"
        "Adaptador de red heredado" = "Legacy Network Adapter"
        "Interfaz de servicio de invitado" = "Guest Service Interface"
        "Latido" = "Heartbeat"
        "Intercambio de pares clave-valor" = "Key-Value Pair Exchange"
        "Apagar" = "Shutdown"
        "Sincronización de hora" = "Time Synchronization"
        "Sin contacto" = "No contact"
        "Funcionamiento normal" = "Operating normally"
        "Error" = "Error"
        "Cerrando" = "Shutting down"
        "Iniciando" = "Starting up"
        "Pausado" = "Paused"
        "Guardado" = "Saved"

        # Italian translations
        "Scheda di rete" = "Network Adapter"
        "Scheda di rete legacy" = "Legacy Network Adapter"
        "Interfaccia del servizio guest" = "Guest Service Interface"
        "Heartbeat" = "Heartbeat"
        "Scambio coppie chiave-valore" = "Key-Value Pair Exchange"
        "Arresto" = "Shutdown"
        "Sincronizzazione ora" = "Time Synchronization"
        "Nessun contatto" = "No contact"
        "Funzionamento normale" = "Operating normally"

        # Portuguese translations
        "Adaptador de rede" = "Network Adapter"
        "Adaptador de rede herdado" = "Legacy Network Adapter"
        "Interface de serviço convidado" = "Guest Service Interface"
        "Pulsação" = "Heartbeat"
        "Troca de pares chave-valor" = "Key-Value Pair Exchange"
        "Desligar" = "Shutdown"
        "Sincronização de hora" = "Time Synchronization"
        "Sem contato" = "No contact"
        "Operação normal" = "Operating normally"
    }

    if ($translations.ContainsKey($Value)) {
        $translatedValue = $translations[$Value]
        Write-DebugInfo "Translated '$Value' to '$translatedValue'"
        return $translatedValue
    }
    Write-DebugInfo "No translation found for '$Value'"
    return $Value
}

function Get-VMDiscoveryData {
    try {
        Write-DebugInfo "Starting VM discovery using PowerShell module"

        # Test if Hyper-V module is available
        try {
            $module = Get-Module -Name Hyper-V -ListAvailable -ErrorAction Stop
            Write-DebugInfo "Hyper-V PowerShell module found: $($module.Version)"
        } catch {
            Write-DebugInfo "Hyper-V PowerShell module not available: $($_.Exception.Message)"
            throw "Hyper-V PowerShell module not available"
        }

        # Get hypervisor host information
        Write-DebugInfo "Getting hypervisor host information"
        $hostName = $env:COMPUTERNAME
        $hostFQDN = "Unknown"
        try {
            $hostFQDN = [System.Net.Dns]::GetHostByName($env:COMPUTERNAME).HostName
            Write-DebugInfo "Host Name: $hostName"
            Write-DebugInfo "Host FQDN: $hostFQDN"
        } catch {
            Write-DebugInfo "Error getting host FQDN: $($_.Exception.Message)"
            $hostFQDN = $hostName
        }

        # Get all VMs on the Hyper-V host
        Write-DebugInfo "Querying VMs using Get-VM"
        $vms = Get-VM | Sort-Object Name
        Write-DebugInfo "Found $($vms.Count) VMs"

        if ($vms.Count -eq 0) {
            Write-DebugInfo "No VMs found on this Hyper-V host"
        }

        $discoveryData = @()

        foreach ($vm in $vms) {
            Write-DebugInfo "Processing VM: $($vm.Name) (State: $($vm.State))"
            # Get VM configuration details
            try {
                Write-DebugInfo "  Getting memory settings for $($vm.Name)"
                $vmSettings = Get-VMMemory -VM $vm -ErrorAction Stop

                Write-DebugInfo "  Getting processor settings for $($vm.Name)"
                $vmProcessor = Get-VMProcessor -VM $vm -ErrorAction Stop

                Write-DebugInfo "  Getting network adapters for $($vm.Name)"
                $vmNetworkAdapters = Get-VMNetworkAdapter -VM $vm -ErrorAction Stop
                Write-DebugInfo "    Found $($vmNetworkAdapters.Count) network adapters"

                Write-DebugInfo "  Getting hard disk drives for $($vm.Name)"
                $vmHardDisks = Get-VMHardDiskDrive -VM $vm -ErrorAction Stop
                Write-DebugInfo "    Found $($vmHardDisks.Count) hard disk drives"

                Write-DebugInfo "  Getting DVD drives for $($vm.Name)"
                $vmDvdDrives = Get-VMDvdDrive -VM $vm -ErrorAction Stop
                Write-DebugInfo "    Found $($vmDvdDrives.Count) DVD drives"

                Write-DebugInfo "  Getting integration services for $($vm.Name)"
                $vmIntegrationServices = Get-VMIntegrationService -VM $vm -ErrorAction Stop
                Write-DebugInfo "    Found $($vmIntegrationServices.Count) integration services"
            } catch {
                Write-DebugInfo "  Error getting VM details for $($vm.Name): $($_.Exception.Message)"
                continue
            }
            
            # Build network adapter info
            Write-DebugInfo "  Building network adapter info for $($vm.Name)"
            $networkInfo = @()
            foreach ($adapter in $vmNetworkAdapters) {
                try {
                    Write-DebugInfo "    Processing adapter: $($adapter.Name)"
                    $networkInfo += @{
                        "Name" = $adapter.Name
                        "NameTranslated" = ConvertToEnglish -Value $adapter.Name
                        "SwitchName" = $adapter.SwitchName
                        "MacAddress" = $adapter.MacAddress
                        "Connected" = $adapter.Connected.ToString()
                        "VlanId" = $adapter.VlanSetting.AccessVlanId
                    }
                } catch {
                    Write-DebugInfo "    Error processing adapter $($adapter.Name): $($_.Exception.Message)"
                }
            }
            
            # Build disk info
            Write-DebugInfo "  Building disk info for $($vm.Name)"
            $diskInfo = @()
            foreach ($disk in $vmHardDisks) {
                try {
                    Write-DebugInfo "    Processing disk: $($disk.Path)"
                    $vhdInfo = $null
                    if ($disk.Path) {
                        try {
                            $vhdInfo = Get-VHD -Path $disk.Path -ErrorAction SilentlyContinue
                            if ($vhdInfo) {
                                Write-DebugInfo "      VHD info retrieved successfully"
                            } else {
                                Write-DebugInfo "      Could not get VHD info for $($disk.Path)"
                            }
                        } catch {
                            Write-DebugInfo "      Error getting VHD info: $($_.Exception.Message)"
                        }
                    }

                    $diskInfo += @{
                        "ControllerType" = $disk.ControllerType.ToString()
                        "ControllerNumber" = $disk.ControllerNumber
                        "ControllerLocation" = $disk.ControllerLocation
                        "Path" = $disk.Path
                        "VhdType" = if ($vhdInfo) { $vhdInfo.VhdType.ToString() } else { "Unknown" }
                        "VhdSizeGB" = if ($vhdInfo) { [math]::Round($vhdInfo.Size / 1GB, 2) } else { 0 }
                        "VhdFileSizeGB" = if ($vhdInfo) { [math]::Round($vhdInfo.FileSize / 1GB, 2) } else { 0 }
                    }
                } catch {
                    Write-DebugInfo "    Error processing disk: $($_.Exception.Message)"
                }
            }
            
            # Build DVD drive info
            $dvdInfo = @()
            foreach ($dvd in $vmDvdDrives) {
                $dvdInfo += @{
                    "ControllerNumber" = $dvd.ControllerNumber
                    "ControllerLocation" = $dvd.ControllerLocation
                    "Path" = $dvd.Path
                }
            }
            
            # Build integration services info
            Write-DebugInfo "  Building integration services info for $($vm.Name)"
            $integrationInfo = @()
            foreach ($service in $vmIntegrationServices) {
                try {
                    Write-DebugInfo "    Processing service: $($service.Name)"
                    $integrationInfo += @{
                        "Name" = $service.Name
                        "NameTranslated" = ConvertToEnglish -Value $service.Name
                        "Enabled" = $service.Enabled.ToString()
                        "PrimaryStatusDescription" = $service.PrimaryStatusDescription
                        "PrimaryStatusDescriptionTranslated" = ConvertToEnglish -Value $service.PrimaryStatusDescription
                    }
                } catch {
                    Write-DebugInfo "    Error processing integration service: $($_.Exception.Message)"
                }
            }
            
            # Get checkpoint information
            Write-DebugInfo "  Getting checkpoints for $($vm.Name)"
            $checkpoints = Get-VMSnapshot -VM $vm -ErrorAction SilentlyContinue
            Write-DebugInfo "    Found $($checkpoints.Count) checkpoints"
            $checkpointInfo = @()
            foreach ($checkpoint in $checkpoints) {
                try {
                    Write-DebugInfo "    Processing checkpoint: $($checkpoint.Name)"
                    $checkpointInfo += @{
                        "Name" = $checkpoint.Name
                        "CreationTime" = $checkpoint.CreationTime.ToString("yyyy-MM-dd HH:mm:ss")
                        "ParentCheckpointName" = $checkpoint.ParentCheckpointName
                    }
                } catch {
                    Write-DebugInfo "    Error processing checkpoint: $($_.Exception.Message)"
                }
            }

            # Get replication information
            Write-DebugInfo "  Getting replication status for $($vm.Name)"
            $vmReplication = $null
            $replicationEnabled = $false
            $replicationState = "NotEnabled"
            $replicationMode = "None"
            $replicationHealth = "NotApplicable"
            $replicationFrequency = 0
            $lastReplicationTime = ""
            $primaryServer = ""
            $replicaServer = ""

            try {
                $vmReplication = Get-VMReplication -VM $vm -ErrorAction SilentlyContinue
                if ($vmReplication) {
                    $replicationEnabled = $true
                    $replicationState = $vmReplication.State.ToString()
                    $replicationMode = $vmReplication.ReplicationMode.ToString()
                    $replicationHealth = $vmReplication.ReplicationHealth.ToString()
                    $replicationFrequency = $vmReplication.ReplicationFrequencySec
                    if ($vmReplication.LastReplicationTime) {
                        $lastReplicationTime = $vmReplication.LastReplicationTime.ToString("yyyy-MM-dd HH:mm:ss")
                    }
                    $primaryServer = if ($vmReplication.PrimaryServerName) { $vmReplication.PrimaryServerName } else { "" }
                    $replicaServer = if ($vmReplication.ReplicaServerName) { $vmReplication.ReplicaServerName } else { "" }
                    Write-DebugInfo "    Replication enabled: State=$replicationState, Mode=$replicationMode, Health=$replicationHealth"
                } else {
                    Write-DebugInfo "    Replication not enabled for this VM"
                }
            } catch {
                Write-DebugInfo "    Error getting replication status: $($_.Exception.Message)"
            }
            
            $vmData = @{
                "{#VM.NAME}" = $vm.Name
                "{#VM.ID}" = $vm.Id.ToString()
                "{#VM.STATE}" = $vm.State.ToString()
                "{#VM.STATE.VALUE}" = [int]$vm.State
                "{#VM.STATUS}" = $vm.Status.ToString()
                "{#VM.STATUS.TRANSLATED}" = ConvertToEnglish -Value $vm.Status.ToString()
                "{#VM.GENERATION}" = $vm.Generation.ToString()
                "{#VM.VERSION}" = $vm.Version.ToString()
                "{#VM.UPTIME}" = if ($vm.Uptime) { $vm.Uptime.TotalSeconds.ToString() } else { "0" }
                "{#VM.MEMORY.STARTUP.MB}" = $vmSettings.Startup
                "{#VM.MEMORY.MINIMUM.MB}" = $vmSettings.Minimum
                "{#VM.MEMORY.MAXIMUM.MB}" = $vmSettings.Maximum
                "{#VM.MEMORY.DYNAMIC}" = $vmSettings.DynamicMemoryEnabled.ToString()
                "{#VM.MEMORY.BUFFER}" = $vmSettings.Buffer.ToString()
                "{#VM.MEMORY.PRIORITY}" = $vmSettings.Priority.ToString()
                "{#VM.CPU.COUNT}" = $vmProcessor.Count.ToString()
                "{#VM.CPU.RESERVE}" = $vmProcessor.Reserve.ToString()
                "{#VM.CPU.MAXIMUM}" = $vmProcessor.Maximum.ToString()
                "{#VM.CPU.WEIGHT}" = $vmProcessor.RelativeWeight.ToString()
                "{#VM.AUTOSTART.ACTION}" = $vm.AutomaticStartAction.ToString()
                "{#VM.AUTOSTART.ACTION.VALUE}" = [int]$vm.AutomaticStartAction
                "{#VM.AUTOSTART.DELAY}" = $vm.AutomaticStartDelay.ToString()
                "{#VM.AUTOSTOP.ACTION}" = $vm.AutomaticStopAction.ToString()
                "{#VM.AUTOSTOP.ACTION.VALUE}" = [int]$vm.AutomaticStopAction
                "{#VM.CHECKPOINT.TYPE}" = $vm.CheckpointType.ToString()
                "{#VM.CHECKPOINT.TYPE.VALUE}" = [int]$vm.CheckpointType
                "{#VM.SMART.PAGING.PATH}" = $vm.SmartPagingFilePath
                "{#VM.CONFIG.PATH}" = $vm.ConfigurationLocation
                "{#VM.SNAPSHOT.PATH}" = $vm.SnapshotFileLocation
                "{#VM.NOTES}" = $vm.Notes
                "{#VM.NETWORK.COUNT}" = $vmNetworkAdapters.Count.ToString()
                "{#VM.DISK.COUNT}" = $vmHardDisks.Count.ToString()
                "{#VM.DVD.COUNT}" = $vmDvdDrives.Count.ToString()
                "{#VM.CHECKPOINT.COUNT}" = $checkpoints.Count.ToString()
                "{#VM.NETWORK.INFO}" = ($networkInfo | ConvertTo-Json -Compress)
                "{#VM.DISK.INFO}" = ($diskInfo | ConvertTo-Json -Compress)
                "{#VM.DVD.INFO}" = ($dvdInfo | ConvertTo-Json -Compress)
                "{#VM.INTEGRATION.INFO}" = ($integrationInfo | ConvertTo-Json -Compress)
                "{#VM.CHECKPOINT.INFO}" = ($checkpointInfo | ConvertTo-Json -Compress)
                "{#VM.REPLICATION.ENABLED}" = $replicationEnabled.ToString()
                "{#VM.REPLICATION.STATE}" = $replicationState
                "{#VM.REPLICATION.MODE}" = $replicationMode
                "{#VM.REPLICATION.HEALTH}" = $replicationHealth
                "{#VM.REPLICATION.FREQUENCY}" = $replicationFrequency.ToString()
                "{#VM.REPLICATION.LAST.TIME}" = $lastReplicationTime
                "{#VM.REPLICATION.PRIMARY.SERVER}" = $primaryServer
                "{#VM.REPLICATION.REPLICA.SERVER}" = $replicaServer
                "{#VMHOST.NAME}" = $hostName
                "{#VMHOST.FQDN}" = $hostFQDN
            }
            
            $discoveryData += $vmData
            Write-DebugInfo "Successfully processed VM: $($vm.Name)"
        }

        Write-DebugInfo "Discovery completed. Processed $($discoveryData.Count) VMs"

        # Return direct JSON array for Zabbix 7.0+
        return $discoveryData | ConvertTo-Json -Depth 10

    } catch {
        Write-DebugInfo "Fatal error in VM discovery: $($_.Exception.Message)"
        Write-DebugInfo "Stack trace: $($_.ScriptStackTrace)"
        # Return empty array in case of error
        return @() | ConvertTo-Json
    }
}

# Additional discovery types for specific components
function Get-VMNetworkDiscovery {
    try {
        Write-DebugInfo "Starting network adapter discovery"
        $vms = Get-VM
        Write-DebugInfo "Found $($vms.Count) VMs for network discovery"
        $discoveryData = @()

        foreach ($vm in $vms) {
            Write-DebugInfo "Processing network adapters for VM: $($vm.Name)"
            try {
                $adapters = Get-VMNetworkAdapter -VM $vm -ErrorAction Stop
                Write-DebugInfo "  Found $($adapters.Count) adapters"
                foreach ($adapter in $adapters) {
                    try {
                        Write-DebugInfo "    Processing adapter: $($adapter.Name)"

                        # Format adapter ID for performance counter path
                        # Check if this is a legacy adapter and format accordingly
                        $adapterCounter = ""
                        $isLegacy = $false
                        if ($adapter.PSObject.Properties["IsLegacy"] -and $adapter.IsLegacy) {
                            $isLegacy = $true
                            Write-DebugInfo "    Detected legacy adapter: $($adapter.Name)"

                            # For legacy adapters, use format: VMName_AdapterName_VMID--InterfaceIndex
                            # Extract VM ID (remove curly braces)
                            $vmIdClean = $vm.Id.ToString() -replace '[{}]', ''

                            # Extract interface index from adapter ID (usually the last part after the last -)
                            $interfaceIndex = "0"
                            if ($adapter.Id -match '--(\d+)$') {
                                $interfaceIndex = $matches[1]
                            }

                            # Use original adapter name for legacy counter (not translated)
                            $adapterNameOriginal = $adapter.Name

                            # Escape VM name for performance counter (replace parentheses with square brackets)
                            $vmNameEscaped = $vm.Name -replace '\(', '[' -replace '\)', ']'

                            # Build legacy counter format: VMName_AdapterNameOriginal_VMID--InterfaceIndex
                            $adapterCounter = "$($vmNameEscaped)_$($adapterNameOriginal)_$($vmIdClean)--$interfaceIndex"
                            Write-DebugInfo "    Legacy counter format: $adapterCounter"
                        } else {
                            # Standard adapter processing
                            if ($adapter.Id) {
                                $adapterCounter = $adapter.Id -replace '^Microsoft:', '' -replace '\\', '--'
                            }
                        }

                        # Create shortname for easy identification
                        # Format: NIC_ABC123 where ABC123 are last 6 chars of MAC address
                        # If MAC is 0 or empty, use last part of adapter ID after last \\
                        $shortName = "NIC"
                        if ($adapter.MacAddress -and $adapter.MacAddress -ne "000000000000" -and $adapter.MacAddress.Length -ge 6) {
                            $macSuffix = $adapter.MacAddress.Substring($adapter.MacAddress.Length - 6)
                            $shortName = "NIC_$macSuffix"
                        } elseif ($adapter.Id) {
                            $idParts = $adapter.Id -split '\\'
                            $lastPart = $idParts[-1]
                            $shortName = "NIC_$lastPart"
                        }

                        $discoveryData += @{
                            "{#VM.NAME}" = $vm.Name
                            "{#VM.ID}" = $vm.Id.ToString()
                            "{#ADAPTER.NAME}" = $adapter.Name
                            "{#ADAPTER.NAME.TRANSLATED}" = ConvertToEnglish -Value $adapter.Name
                            "{#ADAPTER.SHORTNAME}" = $shortName
                            "{#ADAPTER.ID}" = $adapter.Id
                            "{#ADAPTER.ID.JS}" = if ($adapter.Id) { $adapter.Id -replace '\\', '\\' } else { "" }
                            "{#ADAPTER.COUNTER}" = $adapterCounter
                            "{#ADAPTER.IS.LEGACY}" = $isLegacy.ToString()
                            "{#ADAPTER.SWITCH}" = $adapter.SwitchName
                            "{#ADAPTER.MAC}" = $adapter.MacAddress
                            "{#ADAPTER.VLAN}" = $adapter.VlanSetting.AccessVlanId.ToString()
                        }
                    } catch {
                        Write-DebugInfo "    Error processing adapter: $($_.Exception.Message)"
                    }
                }
            } catch {
                Write-DebugInfo "  Error getting adapters for $($vm.Name): $($_.Exception.Message)"
            }
        }

        Write-DebugInfo "Network discovery completed. Found $($discoveryData.Count) adapters"
        return $discoveryData | ConvertTo-Json -Depth 5
    } catch {
        Write-DebugInfo "Error in network discovery: $($_.Exception.Message)"
        return @() | ConvertTo-Json
    }
}

function Get-VMDiskDiscovery {
    try {
        Write-DebugInfo "Starting disk discovery"
        $vms = Get-VM
        Write-DebugInfo "Found $($vms.Count) VMs for disk discovery"
        $discoveryData = @()

        foreach ($vm in $vms) {
            Write-DebugInfo "Processing disks for VM: $($vm.Name)"
            try {
                $disks = Get-VMHardDiskDrive -VM $vm -ErrorAction Stop
                Write-DebugInfo "  Found $($disks.Count) disks"
                foreach ($disk in $disks) {
                    try {
                        Write-DebugInfo "    Processing disk: $($disk.Path)"
                        # Extract VHD filename for performance counter path
                        # Format: Replace \ with - for performance counter instance name
                        $diskPathCounter = ""
                        if ($disk.Path) {
                            $diskPathCounter = $disk.Path -replace '\\', '-'
                        }

                        $discoveryData += @{
                            "{#VM.NAME}" = $vm.Name
                            "{#VM.ID}" = $vm.Id.ToString()
                            "{#DISK.CONTROLLER}" = $disk.ControllerType
                            "{#DISK.NUMBER}" = $disk.ControllerNumber.ToString()
                            "{#DISK.LOCATION}" = $disk.ControllerLocation.ToString()
                            "{#DISK.PATH}" = $disk.Path
                            "{#DISK.PATH_COUNTER}" = $diskPathCounter
                            "{#DISK.ID}" = "$($vm.Name)_$($disk.ControllerType)_$($disk.ControllerNumber)_$($disk.ControllerLocation)"
                        }
                    } catch {
                        Write-DebugInfo "    Error processing disk: $($_.Exception.Message)"
                    }
                }
            } catch {
                Write-DebugInfo "  Error getting disks for $($vm.Name): $($_.Exception.Message)"
            }
        }

        Write-DebugInfo "Disk discovery completed. Found $($discoveryData.Count) disks"
        return $discoveryData | ConvertTo-Json -Depth 5
    } catch {
        Write-DebugInfo "Error in disk discovery: $($_.Exception.Message)"
        return @() | ConvertTo-Json
    }
}

function Get-HyperVHostInfo {
    try {
        Write-DebugInfo "Starting Hyper-V host information discovery"

        $hostInfo = @{}

        # Get Hyper-V host information
        try {
            Write-DebugInfo "Getting Hyper-V host configuration"
            $vmHost = Get-VMHost -ErrorAction Stop

            $hostInfo["{#HOST.NAME}"] = $env:COMPUTERNAME
            $hostInfo["{#HOST.FQDN}"] = [System.Net.Dns]::GetHostByName($env:COMPUTERNAME).HostName
            $hostInfo["{#HOST.HYPERV.VERSION}"] = $vmHost.HyperVVersion
            $hostInfo["{#HOST.LOGICAL.PROCESSORS}"] = $vmHost.LogicalProcessorCount.ToString()
            $hostInfo["{#HOST.MEMORY.CAPACITY.GB}"] = [math]::Round($vmHost.MemoryCapacity / 1GB, 2).ToString()
            $hostInfo["{#HOST.MEMORY.CAPACITY}"] = $vmHost.MemoryCapacity.ToString()
            $hostInfo["{#HOST.NUMA.ENABLED}"] = $vmHost.NumaSpanningEnabled.ToString()
            $hostInfo["{#HOST.VIRTUALIZATION.FIRMWARE.VERSION}"] = if ($vmHost.VirtualizationFirmwareVersion) { $vmHost.VirtualizationFirmwareVersion } else { "Unknown" }
            $hostInfo["{#HOST.IOMMU.SUPPORT}"] = $vmHost.IovSupport.ToString()
            $hostInfo["{#HOST.MAX.STORAGE.MIGRATIONS}"] = $vmHost.MaximumStorageMigrations.ToString()
            $hostInfo["{#HOST.MAX.VM.MIGRATIONS}"] = $vmHost.MaximumVirtualMachineMigrations.ToString()
            $hostInfo["{#HOST.ENHANCED.SESSION.MODE}"] = $vmHost.EnableEnhancedSessionMode.ToString()

            Write-DebugInfo "Got basic host information"
        } catch {
            Write-DebugInfo "Error getting host information: $($_.Exception.Message)"
        }

        # Get Virtual Switch information
        try {
            Write-DebugInfo "Getting virtual switch information"
            $switches = Get-VMSwitch -ErrorAction SilentlyContinue
            $switchInfo = @()
            foreach ($switch in $switches) {
                $switchInfo += @{
                    "Name" = $switch.Name
                    "SwitchType" = $switch.SwitchType.ToString()
                    "NetAdapterInterfaceDescription" = if ($switch.NetAdapterInterfaceDescription) { $switch.NetAdapterInterfaceDescription } else { "N/A" }
                    "AllowManagementOS" = if ($switch.AllowManagementOS -ne $null) { $switch.AllowManagementOS.ToString() } else { "N/A" }
                    "DefaultFlowMinimumBandwidthAbsolute" = if ($switch.DefaultFlowMinimumBandwidthAbsolute) { $switch.DefaultFlowMinimumBandwidthAbsolute.ToString() } else { "0" }
                    "Extensions" = if ($switch.Extensions) { ($switch.Extensions | ForEach-Object { $_.Name }) -join "," } else { "" }
                }
            }
            $hostInfo["{#HOST.VIRTUAL.SWITCHES}"] = ($switchInfo | ConvertTo-Json -Compress)
            $hostInfo["{#HOST.VIRTUAL.SWITCHES.COUNT}"] = $switches.Count.ToString()
            Write-DebugInfo "Found $($switches.Count) virtual switches"
        } catch {
            Write-DebugInfo "Error getting virtual switches: $($_.Exception.Message)"
            $hostInfo["{#HOST.VIRTUAL.SWITCHES}"] = "[]"
            $hostInfo["{#HOST.VIRTUAL.SWITCHES.COUNT}"] = "0"
        }

        # Get VM summary statistics - optimized to only retrieve State property
        try {
            Write-DebugInfo "Getting VM summary statistics"
            # Only select the State property to speed up the query significantly
            $vmStates = @(Get-VM -ErrorAction SilentlyContinue | Select-Object -ExpandProperty State)
            $vmStats = @{
                "Total" = $vmStates.Count
                "Running" = @($vmStates | Where-Object { $_ -eq "Running" }).Count
                "Off" = @($vmStates | Where-Object { $_ -eq "Off" }).Count
                "Saved" = @($vmStates | Where-Object { $_ -eq "Saved" }).Count
                "Paused" = @($vmStates | Where-Object { $_ -eq "Paused" }).Count
                "Other" = @($vmStates | Where-Object { $_ -notin @("Running", "Off", "Saved", "Paused") }).Count
            }

            $hostInfo["{#HOST.VM.TOTAL.COUNT}"] = $vmStats.Total.ToString()
            $hostInfo["{#HOST.VM.RUNNING.COUNT}"] = $vmStats.Running.ToString()
            $hostInfo["{#HOST.VM.OFF.COUNT}"] = $vmStats.Off.ToString()
            $hostInfo["{#HOST.VM.SAVED.COUNT}"] = $vmStats.Saved.ToString()
            $hostInfo["{#HOST.VM.PAUSED.COUNT}"] = $vmStats.Paused.ToString()
            $hostInfo["{#HOST.VM.OTHER.COUNT}"] = $vmStats.Other.ToString()
            $hostInfo["{#HOST.VM.STATISTICS}"] = ($vmStats | ConvertTo-Json -Compress)

            Write-DebugInfo "VM Statistics: Total=$($vmStats.Total), Running=$($vmStats.Running), Off=$($vmStats.Off)"
        } catch {
            Write-DebugInfo "Error getting VM statistics: $($_.Exception.Message)"
            $hostInfo["{#HOST.VM.TOTAL.COUNT}"] = "0"
            $hostInfo["{#HOST.VM.RUNNING.COUNT}"] = "0"
            $hostInfo["{#HOST.VM.OFF.COUNT}"] = "0"
            $hostInfo["{#HOST.VM.SAVED.COUNT}"] = "0"
            $hostInfo["{#HOST.VM.PAUSED.COUNT}"] = "0"
            $hostInfo["{#HOST.VM.OTHER.COUNT}"] = "0"
            $hostInfo["{#HOST.VM.STATISTICS}"] = "{}"
        }

        # Get Hyper-V feature status - OPTIMIZED: Skip this slow check
        # The Get-WindowsOptionalFeature command is extremely slow (10-20 seconds)
        # Since we already know Hyper-V is enabled (we're running Get-VMHost successfully),
        # we can safely assume it's "Enabled" and skip this expensive check
        try {
            Write-DebugInfo "Skipping slow Hyper-V feature status check (assumed Enabled)"
            # If Get-VMHost worked above, Hyper-V is definitely enabled
            if ($vmHost) {
                $hostInfo["{#HOST.HYPERV.FEATURE.STATE}"] = "Enabled"
            } else {
                $hostInfo["{#HOST.HYPERV.FEATURE.STATE}"] = "Unknown"
            }
        } catch {
            Write-DebugInfo "Error getting Hyper-V feature status: $($_.Exception.Message)"
            $hostInfo["{#HOST.HYPERV.FEATURE.STATE}"] = "Unknown"
        }

        # Get OS information - optimized to only select needed properties
        try {
            Write-DebugInfo "Getting OS information"
            $osInfo = Get-CimInstance -ClassName Win32_OperatingSystem -Property Caption,Version,BuildNumber,OSArchitecture,InstallDate,LastBootUpTime -ErrorAction SilentlyContinue
            if ($osInfo) {
                $hostInfo["{#HOST.OS.NAME}"] = $osInfo.Caption
                $hostInfo["{#HOST.OS.VERSION}"] = $osInfo.Version
                $hostInfo["{#HOST.OS.BUILD}"] = $osInfo.BuildNumber
                $hostInfo["{#HOST.OS.ARCHITECTURE}"] = $osInfo.OSArchitecture
                $hostInfo["{#HOST.OS.INSTALL.DATE}"] = $osInfo.InstallDate.ToString("yyyy-MM-dd HH:mm:ss")
                $hostInfo["{#HOST.OS.LAST.BOOT}"] = $osInfo.LastBootUpTime.ToString("yyyy-MM-dd HH:mm:ss")
                $hostInfo["{#HOST.UPTIME.SECONDS}"] = [math]::Round(((Get-Date) - $osInfo.LastBootUpTime).TotalSeconds).ToString()
            } else {
                $hostInfo["{#HOST.OS.NAME}"] = "Unknown"
                $hostInfo["{#HOST.OS.VERSION}"] = "Unknown"
                $hostInfo["{#HOST.OS.BUILD}"] = "Unknown"
                $hostInfo["{#HOST.OS.ARCHITECTURE}"] = "Unknown"
                $hostInfo["{#HOST.OS.INSTALL.DATE}"] = ""
                $hostInfo["{#HOST.OS.LAST.BOOT}"] = ""
                $hostInfo["{#HOST.UPTIME.SECONDS}"] = "0"
            }
        } catch {
            Write-DebugInfo "Error getting OS information: $($_.Exception.Message)"
        }

        Write-DebugInfo "Hyper-V host discovery completed"

        # Return as single-item array for Zabbix LLD format
        return @($hostInfo) | ConvertTo-Json -Depth 10

    } catch {
        Write-DebugInfo "Fatal error in host discovery: $($_.Exception.Message)"
        return @() | ConvertTo-Json
    }
}

function Get-VMDetailsById {
    param([string]$VmId)

    try {
        Write-DebugInfo "Starting VM details discovery for VM ID: $VmId"

        if ([string]::IsNullOrEmpty($VmId)) {
            Write-DebugInfo "VM ID parameter is required for vmdetails discovery type"
            throw "VM ID parameter is required"
        }

        # Try to find the VM by ID
        $vm = $null
        try {
            $vm = Get-VM -Id $VmId -ErrorAction Stop
            Write-DebugInfo "Found VM: $($vm.Name) with ID: $VmId"
        } catch {
            Write-DebugInfo "VM with ID $VmId not found: $($_.Exception.Message)"
            throw "VM with ID $VmId not found"
        }

        # Get VM configuration details
        Write-DebugInfo "Getting VM configuration details for $($vm.Name)"
        $vmSettings = Get-VMMemory -VM $vm -ErrorAction Stop
        $vmProcessor = Get-VMProcessor -VM $vm -ErrorAction Stop
        $vmNetworkAdapters = Get-VMNetworkAdapter -VM $vm -ErrorAction Stop
        $vmHardDisks = Get-VMHardDiskDrive -VM $vm -ErrorAction Stop
        $vmDvdDrives = Get-VMDvdDrive -VM $vm -ErrorAction Stop
        $vmIntegrationServices = Get-VMIntegrationService -VM $vm -ErrorAction Stop
        $checkpoints = Get-VMSnapshot -VM $vm -ErrorAction SilentlyContinue

        # Build network adapter LLD data
        Write-DebugInfo "Building network adapter LLD data for $($vm.Name)"
        Write-DebugInfo "Found $($vmNetworkAdapters.Count) network adapters"
        $networkLLD = @()
        foreach ($adapter in $vmNetworkAdapters) {
            try {
                Write-DebugInfo "  Processing adapter: $($adapter.Name)"

                # Format adapter ID for performance counter path
                # Check if this is a legacy adapter and format accordingly
                $adapterCounter = ""
                $isLegacy = $false
                if ($adapter.PSObject.Properties["IsLegacy"] -and $adapter.IsLegacy) {
                    $isLegacy = $true
                    Write-DebugInfo "    Detected legacy adapter: $($adapter.Name)"

                    # For legacy adapters, use format: VMName_AdapterName_VMID--InterfaceIndex
                    # Extract VM ID (remove curly braces)
                    $vmIdClean = $vm.Id.ToString() -replace '[{}]', ''

                    # Extract interface index from adapter ID (usually the last part after the last -)
                    $interfaceIndex = "0"
                    if ($adapter.Id -match '--(\d+)$') {
                        $interfaceIndex = $matches[1]
                    }

                    # Use original adapter name for legacy counter (not translated)
                    $adapterNameOriginal = $adapter.Name

                    # Escape VM name for performance counter (replace parentheses with square brackets)
                    $vmNameEscaped = $vm.Name -replace '\(', '[' -replace '\)', ']'

                    # Build legacy counter format: VMName_AdapterNameOriginal_VMID--InterfaceIndex
                    $adapterCounter = "$($vmNameEscaped)_$($adapterNameOriginal)_$($vmIdClean)--$interfaceIndex"
                    Write-DebugInfo "    Legacy counter format: $adapterCounter"
                } else {
                    # Standard adapter processing
                    if ($adapter.Id) {
                        $adapterCounter = $adapter.Id -replace '^Microsoft:', '' -replace '\\', '--'
                    }
                }

                # Create shortname for easy identification
                # Format: NIC_ABC123 where ABC123 are last 6 chars of MAC address
                # If MAC is 0 or empty, use last part of adapter ID after last \\
                $shortName = "NIC"
                if ($adapter.MacAddress -and $adapter.MacAddress -ne "000000000000" -and $adapter.MacAddress.Length -ge 6) {
                    $macSuffix = $adapter.MacAddress.Substring($adapter.MacAddress.Length - 6)
                    $shortName = "NIC_$macSuffix"
                } elseif ($adapter.Id) {
                    $idParts = $adapter.Id -split '\\'
                    $lastPart = $idParts[-1]
                    $shortName = "NIC_$lastPart"
                }

                # Basic adapter information that should always be available
                $adapterData = @{
                    "{#VM.NAME}" = $vm.Name
                    "{#VM.ID}" = $vm.Id.ToString()
                    "{#ADAPTER.NAME}" = if ($adapter.Name) { $adapter.Name } else { "Unknown" }
                    "{#ADAPTER.NAME.TRANSLATED}" = if ($adapter.Name) { ConvertToEnglish -Value $adapter.Name } else { "Unknown" }
                    "{#ADAPTER.SHORTNAME}" = $shortName
                    "{#ADAPTER.ID}" = if ($adapter.Id) { $adapter.Id } else { "Unknown" }
                    "{#ADAPTER.ID.JS}" = if ($adapter.Id) { $adapter.Id -replace '\\', '\\' } else { "Unknown" }
                    "{#ADAPTER.COUNTER}" = $adapterCounter
                    "{#ADAPTER.IS.LEGACY}" = $isLegacy.ToString()
                    "{#ADAPTER.SWITCH}" = if ($adapter.SwitchName) { $adapter.SwitchName } else { "Not Connected" }
                    "{#ADAPTER.MAC}" = if ($adapter.MacAddress) { $adapter.MacAddress } else { "Unknown" }
                    "{#ADAPTER.CONNECTED}" = if ($adapter.Connected -ne $null) { $adapter.Connected.ToString() } else { "Unknown" }
                }

                # VLAN settings - handle safely
                try {
                    if ($adapter.VlanSetting -and $adapter.VlanSetting.AccessVlanId) {
                        $adapterData["{#ADAPTER.VLAN}"] = $adapter.VlanSetting.AccessVlanId.ToString()
                    } else {
                        $adapterData["{#ADAPTER.VLAN}"] = "0"
                    }
                } catch {
                    $adapterData["{#ADAPTER.VLAN}"] = "0"
                }

                # Optional properties - add only if they exist
                if ($adapter.PSObject.Properties["DynamicMacAddressEnabled"]) {
                    $adapterData["{#ADAPTER.DYNAMIC.MAC}"] = $adapter.DynamicMacAddressEnabled.ToString()
                }

                if ($adapter.PSObject.Properties["MacAddressSpoofing"]) {
                    $adapterData["{#ADAPTER.MAC.SPOOFING}"] = $adapter.MacAddressSpoofing.ToString()
                }

                if ($adapter.PSObject.Properties["DhcpGuard"]) {
                    $adapterData["{#ADAPTER.DHCP.GUARD}"] = $adapter.DhcpGuard.ToString()
                }

                if ($adapter.PSObject.Properties["PortMirroringMode"]) {
                    $adapterData["{#ADAPTER.PORT.MIRRORING}"] = $adapter.PortMirroringMode.ToString()
                }

                if ($adapter.PSObject.Properties["IeeePriorityTag"]) {
                    $adapterData["{#ADAPTER.IEEE.PRIORITY}"] = $adapter.IeeePriorityTag.ToString()
                }

                if ($adapter.PSObject.Properties["VmqWeight"]) {
                    $adapterData["{#ADAPTER.VM.QUEUE}"] = $adapter.VmqWeight.ToString()
                }

                if ($adapter.PSObject.Properties["IPsecOffloadMaximumSecurityAssociation"]) {
                    $adapterData["{#ADAPTER.IP.SEC.OFFLOAD}"] = $adapter.IPsecOffloadMaximumSecurityAssociation.ToString()
                }

                if ($adapter.PSObject.Properties["IovWeight"]) {
                    $adapterData["{#ADAPTER.SR.IOV}"] = $adapter.IovWeight.ToString()
                }

                if ($adapter.PSObject.Properties["PacketDirectNumProcs"]) {
                    $adapterData["{#ADAPTER.PACKET.DIRECT}"] = $adapter.PacketDirectNumProcs.ToString()
                }

                # Add adapter type/generation info if available
                if ($adapter.PSObject.Properties["IsLegacy"]) {
                    $adapterData["{#ADAPTER.IS.LEGACY}"] = $adapter.IsLegacy.ToString()
                }

                if ($adapter.PSObject.Properties["AdapterType"]) {
                    $adapterData["{#ADAPTER.TYPE}"] = $adapter.AdapterType.ToString()
                }

                $networkLLD += $adapterData
                Write-DebugInfo "    Successfully processed adapter: $($adapter.Name)"

            } catch {
                Write-DebugInfo "  Error processing adapter $($adapter.Name): $($_.Exception.Message)"
                # Add basic info even if there's an error
                $networkLLD += @{
                    "{#VM.NAME}" = $vm.Name
                    "{#VM.ID}" = $vm.Id.ToString()
                    "{#ADAPTER.NAME}" = if ($adapter.Name) { $adapter.Name } else { "Error" }
                    "{#ADAPTER.NAME.TRANSLATED}" = "Error"
                    "{#ADAPTER.ID}" = "Error"
                    "{#ADAPTER.SWITCH}" = "Error"
                    "{#ADAPTER.MAC}" = "Error"
                    "{#ADAPTER.CONNECTED}" = "Error"
                    "{#ADAPTER.VLAN}" = "0"
                }
            }
        }

        # Build disk LLD data
        Write-DebugInfo "Building disk LLD data for $($vm.Name)"
        $diskLLD = @()
        foreach ($disk in $vmHardDisks) {
            try {
                Write-DebugInfo "  Processing disk: $($disk.Path)"
                $vhdInfo = $null
                if ($disk.Path) {
                    try {
                        $vhdInfo = Get-VHD -Path $disk.Path -ErrorAction SilentlyContinue
                    } catch {
                        Write-DebugInfo "    Error getting VHD info: $($_.Exception.Message)"
                    }
                }

                # Extract VHD filename for performance counter path
                # Format: Replace \ with - for performance counter instance name
                $diskPathCounter = ""
                if ($disk.Path) {
                    $diskPathCounter = $disk.Path -replace '\\', '-'
                }

                $diskLLD += @{
                    "{#VM.NAME}" = $vm.Name
                    "{#VM.ID}" = $vm.Id.ToString()
                    "{#DISK.CONTROLLER}" = $disk.ControllerType.ToString()
                    "{#DISK.NUMBER}" = $disk.ControllerNumber.ToString()
                    "{#DISK.LOCATION}" = $disk.ControllerLocation.ToString()
                    "{#DISK.PATH}" = $disk.Path
                    "{#DISK.PATH_COUNTER}" = $diskPathCounter
                    "{#DISK.ID}" = "$($vm.Name)_$($disk.ControllerType)_$($disk.ControllerNumber)_$($disk.ControllerLocation)"
                    "{#DISK.VHD.TYPE}" = if ($vhdInfo) { $vhdInfo.VhdType.ToString() } else { "Unknown" }
                    "{#DISK.VHD.FORMAT}" = if ($vhdInfo) { $vhdInfo.VhdFormat.ToString() } else { "Unknown" }
                    "{#DISK.SIZE.GB}" = if ($vhdInfo) { [math]::Round($vhdInfo.Size / 1GB, 2).ToString() } else { "0" }
                    "{#DISK.FILE.SIZE.GB}" = if ($vhdInfo) { [math]::Round($vhdInfo.FileSize / 1GB, 2).ToString() } else { "0" }
                    "{#DISK.MINIMUM.SIZE.GB}" = if ($vhdInfo) { [math]::Round($vhdInfo.MinimumSize / 1GB, 2).ToString() } else { "0" }
                    "{#DISK.SIZE}" = if ($vhdInfo) { $vhdInfo.Size.ToString() } else { "0" }
                    "{#DISK.FILE.SIZE}" = if ($vhdInfo) { $vhdInfo.FileSize.ToString() } else { "0" }
                    "{#DISK.MINIMUM.SIZE}" = if ($vhdInfo) { $vhdInfo.MinimumSize.ToString() } else { "0" }
                    "{#DISK.FRAGMENTATION}" = if ($vhdInfo) { $vhdInfo.FragmentationPercentage.ToString() } else { "0" }
                    "{#DISK.ALIGNMENT}" = if ($vhdInfo) { $vhdInfo.Alignment.ToString() } else { "0" }
                    "{#DISK.BLOCK.SIZE}" = if ($vhdInfo) { $vhdInfo.BlockSize.ToString() } else { "0" }
                    "{#DISK.LOGICAL.SECTOR.SIZE}" = if ($vhdInfo) { $vhdInfo.LogicalSectorSize.ToString() } else { "0" }
                    "{#DISK.PHYSICAL.SECTOR.SIZE}" = if ($vhdInfo) { $vhdInfo.PhysicalSectorSize.ToString() } else { "0" }
                }
            } catch {
                Write-DebugInfo "  Error processing disk: $($_.Exception.Message)"
            }
        }

        # Build VM details response with all LLD data
        $vmDetails = @{
            "vm_info" = @{
                "{#VM.NAME}" = $vm.Name
                "{#VM.ID}" = $vm.Id.ToString()
                "{#VM.STATE}" = $vm.State.ToString()
                "{#VM.STATE.VALUE}" = [int]$vm.State
                "{#VM.STATUS}" = $vm.Status.ToString()
                "{#VM.STATUS.TRANSLATED}" = ConvertToEnglish -Value $vm.Status.ToString()
                "{#VM.GENERATION}" = $vm.Generation.ToString()
                "{#VM.VERSION}" = $vm.Version.ToString()
                "{#VM.UPTIME}" = if ($vm.Uptime) { $vm.Uptime.TotalSeconds.ToString() } else { "0" }
                "{#VM.MEMORY.STARTUP.MB}" = $vmSettings.Startup
                "{#VM.MEMORY.MINIMUM.MB}" = $vmSettings.Minimum
                "{#VM.MEMORY.MAXIMUM.MB}" = $vmSettings.Maximum
                "{#VM.MEMORY.DYNAMIC}" = $vmSettings.DynamicMemoryEnabled.ToString()
                "{#VM.MEMORY.BUFFER}" = $vmSettings.Buffer.ToString()
                "{#VM.MEMORY.PRIORITY}" = $vmSettings.Priority.ToString()
                "{#VM.CPU.COUNT}" = $vmProcessor.Count.ToString()
                "{#VM.CPU.RESERVE}" = $vmProcessor.Reserve.ToString()
                "{#VM.CPU.MAXIMUM}" = $vmProcessor.Maximum.ToString()
                "{#VM.CPU.WEIGHT}" = $vmProcessor.RelativeWeight.ToString()
                "{#VM.AUTOSTART.ACTION}" = $vm.AutomaticStartAction.ToString()
                "{#VM.AUTOSTART.ACTION.VALUE}" = [int]$vm.AutomaticStartAction
                "{#VM.AUTOSTART.DELAY}" = $vm.AutomaticStartDelay.ToString()
                "{#VM.AUTOSTOP.ACTION}" = $vm.AutomaticStopAction.ToString()
                "{#VM.AUTOSTOP.ACTION.VALUE}" = [int]$vm.AutomaticStopAction
                "{#VM.CHECKPOINT.TYPE}" = $vm.CheckpointType.ToString()
                "{#VM.CHECKPOINT.TYPE.VALUE}" = [int]$vm.CheckpointType
                "{#VM.SMART.PAGING.PATH}" = $vm.SmartPagingFilePath
                "{#VM.CONFIG.PATH}" = $vm.ConfigurationLocation
                "{#VM.SNAPSHOT.PATH}" = $vm.SnapshotFileLocation
                "{#VM.NOTES}" = $vm.Notes
                "{#VM.NETWORK.COUNT}" = $vmNetworkAdapters.Count.ToString()
                "{#VM.DISK.COUNT}" = $vmHardDisks.Count.ToString()
                "{#VM.DVD.COUNT}" = $vmDvdDrives.Count.ToString()
                "{#VM.CHECKPOINT.COUNT}" = $checkpoints.Count.ToString()
            }
            "networks" = @($networkLLD)
            "disks" = @($diskLLD)
        }

        Write-DebugInfo "VM details discovery completed for $($vm.Name)"
        return $vmDetails | ConvertTo-Json -Depth 10 -Compress:$false

    } catch {
        Write-DebugInfo "Error in VM details discovery: $($_.Exception.Message)"
        Write-DebugInfo "Stack trace: $($_.ScriptStackTrace)"
        # Return empty structure in case of error
        return @{
            "vm_info" = @{}
            "networks" = @()
            "disks" = @()
        } | ConvertTo-Json -Depth 5
    }
}

# Main execution based on discovery type
try {
    switch ($DiscoveryType.ToLower()) {
        "vms" { Get-VMDiscoveryData }
        "networks" { Get-VMNetworkDiscovery }
        "disks" { Get-VMDiskDiscovery }
        "host" { Get-HyperVHostInfo }
        "vmdetails" { Get-VMDetailsById -VmId $VmId }
        default { Get-VMDiscoveryData }
    }
} finally {
    # Restore original culture settings
    try {
        [System.Threading.Thread]::CurrentThread.CurrentCulture = $originalCulture
        [System.Threading.Thread]::CurrentThread.CurrentUICulture = $originalUICulture
        Write-DebugInfo "Original culture restored"
    } catch {
        Write-DebugInfo "Could not restore original culture: $($_.Exception.Message)"
    }
}
