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

# Describe the integration services of a VM.
# Names and status texts are localized by Windows, so both the raw and the
# english value are returned.
function Get-IntegrationServiceInfo {
    param($Services)

    $info = @()
    foreach ($service in $Services) {
        try {
            Write-DebugInfo "    Processing service: $($service.Name)"
            $info += @{
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
    return ,$info
}

# Snapshot types Hyper-V Replica creates and manages by itself. A replicated VM
# holds one of these per configured recovery point, so on the replica server a VM
# with "additional hourly recovery points, coverage 24 hours" permanently carries
# ~25 of them, the oldest a day old. Those are not left-behind user checkpoints
# and must not be alerted on, so they are counted separately.
# The remaining type, Standard, is what New-VMCheckpoint / the UI create --
# production checkpoints are Standard here too, Production/Standard is the VM's
# CheckpointType property, a different enum.
$script:ReplicaSnapshotTypes = @(
    "Replica",
    "AppConsistentReplica",
    "SyncedReplica",
    "Planned",
    "Recovery",
    "Missing"
)

# Summarize the checkpoints of a VM.
# Both the 'vms' and the 'vmdetails' payload expose the same fields, so the
# host template and the VM guest template can monitor checkpoints identically.
# Ages are computed here, on the Hyper-V host, so no timezone handling is
# needed on the Zabbix side (CreationTime carries no offset of its own).
function Get-CheckpointSummary {
    param($Checkpoints)

    $now = Get-Date
    $list = @()

    foreach ($checkpoint in $Checkpoints) {
        try {
            Write-DebugInfo "    Processing checkpoint: $($checkpoint.Name)"
            $created = $checkpoint.CreationTime
            $snapshotType = if ($checkpoint.SnapshotType) { $checkpoint.SnapshotType.ToString() } else { "Unknown" }
            # Unknown counts as a user checkpoint: better a false alert than a
            # silently ignored checkpoint chain.
            $isReplica = $script:ReplicaSnapshotTypes -contains $snapshotType
            $list += @{
                "Name" = $checkpoint.Name
                "CreationTime" = $created.ToString("yyyy-MM-dd HH:mm:ss")
                "CreationEpoch" = [int64]([System.DateTimeOffset]$created).ToUnixTimeSeconds()
                "AgeSeconds" = [int64](New-TimeSpan -Start $created -End $now).TotalSeconds
                "ParentCheckpointName" = $checkpoint.ParentCheckpointName
                "SnapshotType" = $snapshotType
                "IsReplica" = $isReplica
            }
        } catch {
            Write-DebugInfo "    Error processing checkpoint: $($_.Exception.Message)"
        }
    }

    # Sorted oldest first. @() keeps this an array when the VM has one checkpoint.
    $sorted = @($list | Sort-Object { $_.CreationEpoch })
    $userList = @($sorted | Where-Object { -not $_.IsReplica })

    $summary = @{
        "Count" = $sorted.Count
        "Info" = $sorted
        "OldestName" = ""
        "OldestCreated" = ""
        "OldestEpoch" = 0
        "OldestAge" = 0
        "NewestName" = ""
        "NewestCreated" = ""
        "NewestEpoch" = 0
        "NewestAge" = 0
        # Same figures with the replica recovery points filtered out. These are
        # what the triggers watch.
        "UserCount" = $userList.Count
        "UserOldestName" = ""
        "UserOldestCreated" = ""
        "UserOldestEpoch" = 0
        "UserOldestAge" = 0
        "UserNewestName" = ""
        "UserNewestCreated" = ""
        "UserNewestEpoch" = 0
        "UserNewestAge" = 0
        "ReplicaCount" = $sorted.Count - $userList.Count
    }

    if ($sorted.Count -gt 0) {
        $oldest = $sorted[0]
        $newest = $sorted[$sorted.Count - 1]
        $summary["OldestName"] = $oldest.Name
        $summary["OldestCreated"] = $oldest.CreationTime
        $summary["OldestEpoch"] = $oldest.CreationEpoch
        $summary["OldestAge"] = $oldest.AgeSeconds
        $summary["NewestName"] = $newest.Name
        $summary["NewestCreated"] = $newest.CreationTime
        $summary["NewestEpoch"] = $newest.CreationEpoch
        $summary["NewestAge"] = $newest.AgeSeconds
    }

    if ($userList.Count -gt 0) {
        $oldestUser = $userList[0]
        $newestUser = $userList[$userList.Count - 1]
        $summary["UserOldestName"] = $oldestUser.Name
        $summary["UserOldestCreated"] = $oldestUser.CreationTime
        $summary["UserOldestEpoch"] = $oldestUser.CreationEpoch
        $summary["UserOldestAge"] = $oldestUser.AgeSeconds
        $summary["UserNewestName"] = $newestUser.Name
        $summary["UserNewestCreated"] = $newestUser.CreationTime
        $summary["UserNewestEpoch"] = $newestUser.CreationEpoch
        $summary["UserNewestAge"] = $newestUser.AgeSeconds
    }

    return $summary
}

# Differencing chain and storage QoS of one virtual disk.
# Both come from objects the caller already has: ParentPath off the Get-VHD result and
# the QoS limits off the Get-VMHardDiskDrive object, so no extra call is made.
# The parent chain is reported one level deep on purpose. Walking it to its root would
# cost one Get-VHD per level, and a replica VM holding 24 recovery points has a chain
# that deep - per disk, per poll. ParentPath answers "is this disk reading through
# something else", which is the question worth asking every interval.
function Get-DiskChainInfo {
    param($Disk, $VhdInfo)

    $info = @{
        "ParentPath" = ""
        "IsDifferencing" = "False"
        "QosMaxIops" = "0"
        "QosMinIops" = "0"
    }

    try {
        if ($VhdInfo -and $VhdInfo.ParentPath) {
            $info["ParentPath"] = $VhdInfo.ParentPath
            $info["IsDifferencing"] = "True"
        }
        # 0 means no limit, which is also the Hyper-V default
        if ($null -ne $Disk.MaximumIOPS) { $info["QosMaxIops"] = ([int64]$Disk.MaximumIOPS).ToString() }
        if ($null -ne $Disk.MinimumIOPS) { $info["QosMinIops"] = ([int64]$Disk.MinimumIOPS).ToString() }
    } catch {
        Write-DebugInfo "    Error reading disk chain/QoS: $($_.Exception.Message)"
    }

    return $info
}

# Which DVD drives have an image mounted.
# An attached iso blocks live migration and quietly pins the VM to its host, so it is
# worth seeing even though it is a perfectly normal thing to do temporarily.
function Get-MountedIsoInfo {
    param($DvdDrives)

    $paths = @()
    foreach ($dvd in $DvdDrives) {
        if ($dvd.Path) { $paths += $dvd.Path }
    }

    return @{
        "Count" = $paths.Count
        "Paths" = ($paths -join "; ")
    }
}

# VLAN configuration of one network adapter.
# No Get-VMNetworkAdapterVlan call needed: Get-VMNetworkAdapter already hands back the
# whole VLAN setting object on .VlanSetting, the same type that cmdlet returns.
# AccessVlanId on its own is ambiguous - it reads 0 for an untagged adapter AND for a
# trunk, whose real configuration lives in the native VLAN and the allowed list - which
# is why the mode is reported next to it.
function Get-AdapterVlanInfo {
    param($Adapter)

    $info = @{
        "AccessVlanId" = "0"
        "Mode" = "Unknown"
        "NativeVlanId" = "0"
        "AllowedList" = ""
    }

    try {
        $vlan = $Adapter.VlanSetting
        if ($vlan) {
            if ($null -ne $vlan.AccessVlanId) { $info["AccessVlanId"] = $vlan.AccessVlanId.ToString() }
            if ($vlan.OperationMode) { $info["Mode"] = $vlan.OperationMode.ToString() }
            if ($null -ne $vlan.NativeVlanId) { $info["NativeVlanId"] = $vlan.NativeVlanId.ToString() }
            if ($vlan.AllowedVlanIdListString) { $info["AllowedList"] = $vlan.AllowedVlanIdListString }
        }
    } catch {
        Write-DebugInfo "    Error reading VLAN settings: $($_.Exception.Message)"
    }

    return $info
}

# Security posture of a VM: TPM, shielding and encrypted state/migration traffic.
# Get-VMSecurity is one extra call per VM, but the values are pure configuration so
# they suit the long vmdetails interval. Everything defaults to False, which is also
# what a host too old for the cmdlet reports.
function Get-VMSecurityInfo {
    param($VM)

    $info = @{
        "TpmEnabled" = "False"
        "Shielded" = "False"
        "EncryptMigration" = "False"
        # NotSupported rather than Off: a generation 1 VM has no UEFI firmware at all,
        # which is a different statement from Secure Boot being switched off.
        "SecureBoot" = "NotSupported"
        "SecureBootTemplate" = ""
    }

    try {
        $security = Get-VMSecurity -VM $VM -ErrorAction SilentlyContinue
        if ($security) {
            if ($null -ne $security.TpmEnabled) { $info["TpmEnabled"] = $security.TpmEnabled.ToString() }
            if ($null -ne $security.Shielded) { $info["Shielded"] = $security.Shielded.ToString() }
            if ($null -ne $security.EncryptStateAndVmMigrationTraffic) {
                $info["EncryptMigration"] = $security.EncryptStateAndVmMigrationTraffic.ToString()
            }
        }
    } catch {
        Write-DebugInfo "    Error getting VM security: $($_.Exception.Message)"
    }

    # Secure Boot comes from Get-VMFirmware, not Get-VMSecurity, and that cmdlet fails
    # outright on a generation 1 VM - hence the generation check before calling it.
    if ($VM.Generation -eq 2) {
        try {
            $firmware = Get-VMFirmware -VM $VM -ErrorAction SilentlyContinue
            if ($firmware) {
                if ($firmware.SecureBoot) { $info["SecureBoot"] = $firmware.SecureBoot.ToString() }
                if ($firmware.SecureBootTemplate) { $info["SecureBootTemplate"] = $firmware.SecureBootTemplate.ToString() }
            }
        } catch {
            Write-DebugInfo "    Error getting VM firmware: $($_.Exception.Message)"
        }
    }

    return $info
}

# Runtime figures that the Get-VM object already carries, so collecting them costs
# nothing beyond the Get-VM call both payloads already make.
# Deliberately NOT taken from here: MemoryStatus and IntegrationServicesState come
# back empty and IntegrationServicesVersion reads 0.0 on current guests (the
# components ship through Windows Update), and $VM.ReplicationState can disagree
# with Get-VMReplication - see Get-ReplicationSummary, which is the honest source.
function Get-VMRuntimeInfo {
    param($VM)

    $assigned = if ($null -ne $VM.MemoryAssigned) { [int64]$VM.MemoryAssigned } else { 0 }
    $demand = if ($null -ne $VM.MemoryDemand) { [int64]$VM.MemoryDemand } else { 0 }

    # Demand against assigned is populated even with dynamic memory switched off,
    # so this works for every VM. Both are 0 on a stopped VM.
    $pressure = 0
    if ($assigned -gt 0 -and $demand -gt 0) {
        $pressure = [math]::Round((($demand / $assigned) * 100), 2)
    }

    return @{
        # Percentage of the host CPU, sampled at this instant. It is a spot value,
        # not an average over the interval - use the virtual processor performance
        # counters for anything that needs a trend.
        "CpuUsage" = if ($null -ne $VM.CPUUsage) { [int]$VM.CPUUsage } else { 0 }
        "MemoryAssigned" = $assigned
        "MemoryDemand" = $demand
        # Invariant culture: this is the only non integer value in the payload and a
        # decimal comma would make Zabbix reject it.
        "MemoryPressure" = $pressure.ToString([System.Globalization.CultureInfo]::InvariantCulture)
        "Heartbeat" = if ($VM.Heartbeat) { $VM.Heartbeat.ToString() } else { "" }
        # Enum values, unlike $VM.Status which is localized and needs ConvertToEnglish
        "OperationalStatus" = if ($VM.PrimaryOperationalStatus) { $VM.PrimaryOperationalStatus.ToString() } else { "" }
        "OperationalStatusSecondary" = if ($VM.SecondaryOperationalStatus) { $VM.SecondaryOperationalStatus.ToString() } else { "" }
        "SmartPagingInUse" = if ($null -ne $VM.SmartPagingFileInUse) { $VM.SmartPagingFileInUse.ToString() } else { "False" }
        "Clustered" = if ($null -ne $VM.IsClustered) { $VM.IsClustered.ToString() } else { "False" }
        "MeteringEnabled" = if ($null -ne $VM.ResourceMeteringEnabled) { $VM.ResourceMeteringEnabled.ToString() } else { "False" }
    }
}

# Collect the Hyper-V Replica state of a VM.
# Like Get-CheckpointSummary this feeds both the 'vms' and the 'vmdetails'
# payload, so the host template and the VM guest template see the same fields.
# The age of the last replication is computed here, on the Hyper-V host, so the
# Zabbix server does not have to guess the host's timezone.
# Every field has a neutral default: a VM without replication is the normal case
# and must not make items unsupported.
function Get-ReplicationSummary {
    param($VM, $Statistics)

    $summary = @{
        "Enabled" = $false
        "State" = "NotEnabled"
        "Mode" = "None"
        "Health" = "NotApplicable"
        "Frequency" = 0
        "LastTime" = ""
        "LastEpoch" = 0
        "LastAge" = 0
        "PrimaryServer" = ""
        "ReplicaServer" = ""
        "RecoveryHistory" = 0
        "VSSFrequencyHours" = 0
        # From Measure-VMReplication. Everything below is measured over a window that
        # Hyper-V resets on its own (MonitoringStartTime), so the counts are "since the
        # last reset", not lifetime totals. StatsWindow makes that window visible.
        "PendingSize" = 0
        "AvgSize" = 0
        "MaxSize" = 0
        "AvgLatency" = 0
        "MaxLatency" = 0
        "SuccessCount" = 0
        "MissedCount" = 0
        "ErrorCount" = 0
        "StatsWindow" = 0
    }

    try {
        $replication = Get-VMReplication -VM $VM -ErrorAction SilentlyContinue
        if ($replication) {
            $summary["Enabled"] = $true
            $summary["State"] = $replication.State.ToString()
            $summary["Mode"] = $replication.ReplicationMode.ToString()
            $summary["Health"] = $replication.ReplicationHealth.ToString()
            $summary["Frequency"] = $replication.ReplicationFrequencySec
            if ($replication.LastReplicationTime) {
                $last = $replication.LastReplicationTime
                $age = [int64](New-TimeSpan -Start $last -End (Get-Date)).TotalSeconds
                # Clock skew between the replica and the primary can date the
                # last replication a few seconds into the future. Zabbix rejects
                # a negative value on an unsigned item, so floor it at 0.
                if ($age -lt 0) { $age = 0 }
                $summary["LastTime"] = $last.ToString("yyyy-MM-dd HH:mm:ss")
                $summary["LastEpoch"] = [int64]([System.DateTimeOffset]$last).ToUnixTimeSeconds()
                $summary["LastAge"] = $age
            }
            if ($replication.PrimaryServerName) { $summary["PrimaryServer"] = $replication.PrimaryServerName }
            if ($replication.ReplicaServerName) { $summary["ReplicaServer"] = $replication.ReplicaServerName }
            # How many recovery points Hyper-V is told to keep: 0 means "only the
            # latest", anything else is the "additional hourly recovery points"
            # coverage from the VM's replication settings. This is what the replica
            # side's checkpoint count is expected to follow, so a count stuck well
            # above it means Hyper-V has stopped merging them.
            # A missing property just reads $null on older builds, hence the guards.
            if ($null -ne $replication.RecoveryHistory) {
                $summary["RecoveryHistory"] = [int]$replication.RecoveryHistory
            }
            if ($null -ne $replication.VSSSnapshotFrequencyHour) {
                $summary["VSSFrequencyHours"] = [int]$replication.VSSSnapshotFrequencyHour
            }

            # Throughput and reliability figures. The caller normally hands these in:
            # Measure-VMReplication returns every replicated VM of the host in a single
            # call (~1s for a whole host), so the 'vms' path fetches them once and looks
            # them up per VM. Only fall back to a per VM call when nothing was passed.
            $stats = @($Statistics)[0]
            if ($null -eq $stats) {
                try {
                    $stats = @(Measure-VMReplication -VMName $VM.Name -ErrorAction SilentlyContinue)[0]
                } catch {
                    Write-DebugInfo "    Error measuring replication: $($_.Exception.Message)"
                }
            }
            if ($stats) {
                if ($null -ne $stats.PendingReplicationSize) { $summary["PendingSize"] = [int64]$stats.PendingReplicationSize }
                if ($null -ne $stats.AverageReplicationSize) { $summary["AvgSize"] = [int64]$stats.AverageReplicationSize }
                if ($null -ne $stats.MaximumReplicationSize) { $summary["MaxSize"] = [int64]$stats.MaximumReplicationSize }
                # Latencies come back as TimeSpan
                if ($null -ne $stats.AverageReplicationLatency) { $summary["AvgLatency"] = [int64]$stats.AverageReplicationLatency.TotalSeconds }
                if ($null -ne $stats.MaximumReplicationLatency) { $summary["MaxLatency"] = [int64]$stats.MaximumReplicationLatency.TotalSeconds }
                if ($null -ne $stats.SuccessfulReplicationCount) { $summary["SuccessCount"] = [int64]$stats.SuccessfulReplicationCount }
                if ($null -ne $stats.MissedReplicationCount) { $summary["MissedCount"] = [int64]$stats.MissedReplicationCount }
                if ($null -ne $stats.ReplicationErrors) { $summary["ErrorCount"] = [int64]$stats.ReplicationErrors }
                if ($stats.MonitoringStartTime -and $stats.MonitoringEndTime) {
                    $window = [int64](New-TimeSpan -Start $stats.MonitoringStartTime -End $stats.MonitoringEndTime).TotalSeconds
                    if ($window -lt 0) { $window = 0 }
                    $summary["StatsWindow"] = $window
                }
                Write-DebugInfo "    Replication stats: pending=$($summary.PendingSize)B avgLatency=$($summary.AvgLatency)s missed=$($summary.MissedCount) errors=$($summary.ErrorCount)"
            }
            Write-DebugInfo "    Replication enabled: State=$($summary.State), Mode=$($summary.Mode), Health=$($summary.Health), LastAge=$($summary.LastAge)s"
        } else {
            Write-DebugInfo "    Replication not enabled for this VM"
        }
    } catch {
        Write-DebugInfo "    Error getting replication status: $($_.Exception.Message)"
    }

    return $summary
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
            $hostFQDN = [System.Net.Dns]::GetHostEntry($env:COMPUTERNAME).HostName
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

        # Replication statistics for every replicated VM of this host in one call.
        # Measured at ~1s for a host with 11 VMs and ~1.5s for one with 14, so fetching
        # it once here and looking it up per VM is far cheaper than a call per VM.
        # Hosts without replication simply yield an empty table.
        $replicationStats = @{}
        try {
            foreach ($stat in @(Measure-VMReplication -ErrorAction SilentlyContinue)) {
                if ($stat -and $stat.VMId) { $replicationStats[$stat.VMId.ToString()] = $stat }
            }
            Write-DebugInfo "Replication statistics collected for $($replicationStats.Count) VMs"
        } catch {
            Write-DebugInfo "Could not measure replication: $($_.Exception.Message)"
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
                    $vlanInfo = Get-AdapterVlanInfo -Adapter $adapter
                    $networkInfo += @{
                        "Name" = $adapter.Name
                        "NameTranslated" = ConvertToEnglish -Value $adapter.Name
                        "SwitchName" = $adapter.SwitchName
                        "MacAddress" = $adapter.MacAddress
                        "Connected" = $adapter.Connected.ToString()
                        "VlanId" = $vlanInfo.AccessVlanId
                        "VlanMode" = $vlanInfo.Mode
                        "VlanNative" = $vlanInfo.NativeVlanId
                        "VlanAllowed" = $vlanInfo.AllowedList
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

                    $chainInfo = Get-DiskChainInfo -Disk $disk -VhdInfo $vhdInfo
                    $diskInfo += @{
                        "ControllerType" = $disk.ControllerType.ToString()
                        "ControllerNumber" = $disk.ControllerNumber
                        "ControllerLocation" = $disk.ControllerLocation
                        "Path" = $disk.Path
                        "VhdType" = if ($vhdInfo) { $vhdInfo.VhdType.ToString() } else { "Unknown" }
                        "VhdSizeGB" = if ($vhdInfo) { [math]::Round($vhdInfo.Size / 1GB, 2) } else { 0 }
                        "VhdFileSizeGB" = if ($vhdInfo) { [math]::Round($vhdInfo.FileSize / 1GB, 2) } else { 0 }
                        "ParentPath" = $chainInfo.ParentPath
                        "IsDifferencing" = $chainInfo.IsDifferencing
                        "QosMaximumIOPS" = $chainInfo.QosMaxIops
                        "QosMinimumIOPS" = $chainInfo.QosMinIops
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
            $integrationInfo = Get-IntegrationServiceInfo -Services $vmIntegrationServices
            
            # Get checkpoint information
            Write-DebugInfo "  Getting checkpoints for $($vm.Name)"
            $checkpoints = Get-VMSnapshot -VM $vm -ErrorAction SilentlyContinue
            Write-DebugInfo "    Found $($checkpoints.Count) checkpoints"
            $checkpointSummary = Get-CheckpointSummary -Checkpoints $checkpoints
            $checkpointInfo = $checkpointSummary.Info

            # Get replication information
            $isoInfo = Get-MountedIsoInfo -DvdDrives $vmDvdDrives
            $runtimeInfo = Get-VMRuntimeInfo -VM $vm
            $securityInfo = Get-VMSecurityInfo -VM $vm
            Write-DebugInfo "  Runtime: cpu=$($runtimeInfo.CpuUsage)% memoryPressure=$($runtimeInfo.MemoryPressure)% heartbeat=$($runtimeInfo.Heartbeat)"

            Write-DebugInfo "  Getting replication status for $($vm.Name)"
            $replicationSummary = Get-ReplicationSummary -VM $vm -Statistics $replicationStats[$vm.Id.ToString()]

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
                "{#VM.CPU.USAGE}" = $runtimeInfo.CpuUsage.ToString()
                "{#VM.MEMORY.ASSIGNED}" = $runtimeInfo.MemoryAssigned.ToString()
                "{#VM.MEMORY.DEMAND}" = $runtimeInfo.MemoryDemand.ToString()
                "{#VM.MEMORY.PRESSURE}" = $runtimeInfo.MemoryPressure
                "{#VM.HEARTBEAT}" = $runtimeInfo.Heartbeat
                "{#VM.OPERATIONAL.STATUS}" = $runtimeInfo.OperationalStatus
                "{#VM.OPERATIONAL.STATUS.SECONDARY}" = $runtimeInfo.OperationalStatusSecondary
                "{#VM.SMART.PAGING.IN.USE}" = $runtimeInfo.SmartPagingInUse
                "{#VM.CLUSTERED}" = $runtimeInfo.Clustered
                "{#VM.METERING.ENABLED}" = $runtimeInfo.MeteringEnabled
                "{#VM.SECURITY.TPM}" = $securityInfo.TpmEnabled
                "{#VM.SECURITY.SHIELDED}" = $securityInfo.Shielded
                "{#VM.SECURITY.ENCRYPT.MIGRATION}" = $securityInfo.EncryptMigration
                "{#VM.SECURITY.SECURE.BOOT}" = $securityInfo.SecureBoot
                "{#VM.SECURITY.SECURE.BOOT.TEMPLATE}" = $securityInfo.SecureBootTemplate
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
                "{#VM.DVD.ISO.COUNT}" = $isoInfo.Count.ToString()
                "{#VM.DVD.ISO.PATHS}" = $isoInfo.Paths
                "{#VM.CHECKPOINT.COUNT}" = $checkpointSummary.Count.ToString()
                "{#VM.CHECKPOINT.OLDEST.NAME}" = $checkpointSummary.OldestName
                "{#VM.CHECKPOINT.OLDEST.CREATED}" = $checkpointSummary.OldestCreated
                "{#VM.CHECKPOINT.OLDEST.EPOCH}" = $checkpointSummary.OldestEpoch.ToString()
                "{#VM.CHECKPOINT.OLDEST.AGE}" = $checkpointSummary.OldestAge.ToString()
                "{#VM.CHECKPOINT.NEWEST.NAME}" = $checkpointSummary.NewestName
                "{#VM.CHECKPOINT.NEWEST.CREATED}" = $checkpointSummary.NewestCreated
                "{#VM.CHECKPOINT.NEWEST.EPOCH}" = $checkpointSummary.NewestEpoch.ToString()
                "{#VM.CHECKPOINT.NEWEST.AGE}" = $checkpointSummary.NewestAge.ToString()
                # Checkpoints minus the recovery points Hyper-V Replica manages itself
                "{#VM.CHECKPOINT.USER.COUNT}" = $checkpointSummary.UserCount.ToString()
                "{#VM.CHECKPOINT.USER.OLDEST.NAME}" = $checkpointSummary.UserOldestName
                "{#VM.CHECKPOINT.USER.OLDEST.CREATED}" = $checkpointSummary.UserOldestCreated
                "{#VM.CHECKPOINT.USER.OLDEST.EPOCH}" = $checkpointSummary.UserOldestEpoch.ToString()
                "{#VM.CHECKPOINT.USER.OLDEST.AGE}" = $checkpointSummary.UserOldestAge.ToString()
                "{#VM.CHECKPOINT.USER.NEWEST.NAME}" = $checkpointSummary.UserNewestName
                "{#VM.CHECKPOINT.USER.NEWEST.CREATED}" = $checkpointSummary.UserNewestCreated
                "{#VM.CHECKPOINT.USER.NEWEST.EPOCH}" = $checkpointSummary.UserNewestEpoch.ToString()
                "{#VM.CHECKPOINT.USER.NEWEST.AGE}" = $checkpointSummary.UserNewestAge.ToString()
                "{#VM.CHECKPOINT.REPLICA.COUNT}" = $checkpointSummary.ReplicaCount.ToString()
                # -InputObject so a VM with a single nic/disk/dvd/checkpoint still
                # yields a json array in these embedded payloads, not a bare object
                "{#VM.NETWORK.INFO}" = (ConvertTo-Json -InputObject $networkInfo -Compress)
                "{#VM.DISK.INFO}" = (ConvertTo-Json -InputObject $diskInfo -Compress)
                "{#VM.DVD.INFO}" = (ConvertTo-Json -InputObject $dvdInfo -Compress)
                "{#VM.INTEGRATION.INFO}" = (ConvertTo-Json -InputObject $integrationInfo -Compress)
                "{#VM.CHECKPOINT.INFO}" = (ConvertTo-Json -InputObject $checkpointInfo -Compress)
                "{#VM.REPLICATION.ENABLED}" = $replicationSummary.Enabled.ToString()
                "{#VM.REPLICATION.STATE}" = $replicationSummary.State
                "{#VM.REPLICATION.MODE}" = $replicationSummary.Mode
                "{#VM.REPLICATION.HEALTH}" = $replicationSummary.Health
                "{#VM.REPLICATION.FREQUENCY}" = $replicationSummary.Frequency.ToString()
                "{#VM.REPLICATION.LAST.TIME}" = $replicationSummary.LastTime
                "{#VM.REPLICATION.LAST.EPOCH}" = $replicationSummary.LastEpoch.ToString()
                "{#VM.REPLICATION.LAST.AGE}" = $replicationSummary.LastAge.ToString()
                "{#VM.REPLICATION.PRIMARY.SERVER}" = $replicationSummary.PrimaryServer
                "{#VM.REPLICATION.REPLICA.SERVER}" = $replicationSummary.ReplicaServer
                "{#VM.REPLICATION.RECOVERY.HISTORY}" = $replicationSummary.RecoveryHistory.ToString()
                "{#VM.REPLICATION.VSS.FREQUENCY}" = $replicationSummary.VSSFrequencyHours.ToString()
                "{#VM.REPLICATION.PENDING.SIZE}" = $replicationSummary.PendingSize.ToString()
                "{#VM.REPLICATION.AVG.SIZE}" = $replicationSummary.AvgSize.ToString()
                "{#VM.REPLICATION.MAX.SIZE}" = $replicationSummary.MaxSize.ToString()
                "{#VM.REPLICATION.AVG.LATENCY}" = $replicationSummary.AvgLatency.ToString()
                "{#VM.REPLICATION.MAX.LATENCY}" = $replicationSummary.MaxLatency.ToString()
                "{#VM.REPLICATION.SUCCESS.COUNT}" = $replicationSummary.SuccessCount.ToString()
                "{#VM.REPLICATION.MISSED.COUNT}" = $replicationSummary.MissedCount.ToString()
                "{#VM.REPLICATION.ERROR.COUNT}" = $replicationSummary.ErrorCount.ToString()
                "{#VM.REPLICATION.STATS.WINDOW}" = $replicationSummary.StatsWindow.ToString()
                "{#VMHOST.NAME}" = $hostName
                "{#VMHOST.FQDN}" = $hostFQDN
            }
            
            $discoveryData += $vmData
            Write-DebugInfo "Successfully processed VM: $($vm.Name)"
        }

        Write-DebugInfo "Discovery completed. Processed $($discoveryData.Count) VMs"

        # Return direct JSON array for Zabbix 7.0+
        # Use -InputObject instead of the pipeline: piping an array unrolls it,
        # so a host with exactly one VM would emit a bare object instead of an
        # array and Zabbix LLD fails with 'Cannot find the "data" array'.
        return ConvertTo-Json -InputObject $discoveryData -Depth 10

    } catch {
        Write-DebugInfo "Fatal error in VM discovery: $($_.Exception.Message)"
        Write-DebugInfo "Stack trace: $($_.ScriptStackTrace)"
        # Return empty array in case of error
        return ConvertTo-Json -InputObject @()
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
                            "{#ADAPTER.VLAN}" = (Get-AdapterVlanInfo -Adapter $adapter).AccessVlanId
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
        # -InputObject keeps a single-element result an array, see Get-VMDiscoveryData
        return ConvertTo-Json -InputObject $discoveryData -Depth 5
    } catch {
        Write-DebugInfo "Error in network discovery: $($_.Exception.Message)"
        return ConvertTo-Json -InputObject @()
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
        # -InputObject keeps a single-element result an array, see Get-VMDiscoveryData
        return ConvertTo-Json -InputObject $discoveryData -Depth 5
    } catch {
        Write-DebugInfo "Error in disk discovery: $($_.Exception.Message)"
        return ConvertTo-Json -InputObject @()
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
            $hostInfo["{#HOST.FQDN}"] = [System.Net.Dns]::GetHostEntry($env:COMPUTERNAME).HostName
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
            # -InputObject so a host with a single vswitch still yields an array
            $hostInfo["{#HOST.VIRTUAL.SWITCHES}"] = (ConvertTo-Json -InputObject $switchInfo -Compress)
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

        # Return a single JSON object (NOT an array): the host template's
        # dependent items address it directly, e.g. $["{#HOST.VM.TOTAL.COUNT}"]
        return ConvertTo-Json -InputObject $hostInfo -Depth 10

    } catch {
        Write-DebugInfo "Fatal error in host discovery: $($_.Exception.Message)"
        # Keep the object shape so dependent items get valid JSON
        return ConvertTo-Json -InputObject @{}
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
        $checkpointSummary = Get-CheckpointSummary -Checkpoints $checkpoints
        $isoInfo = Get-MountedIsoInfo -DvdDrives $vmDvdDrives
        $runtimeInfo = Get-VMRuntimeInfo -VM $vm
        $securityInfo = Get-VMSecurityInfo -VM $vm
        Write-DebugInfo "Getting replication status for $($vm.Name)"
        $replicationSummary = Get-ReplicationSummary -VM $vm

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

                # VLAN settings. The mode matters as much as the id: on a trunk the
                # id reads 0 and the configuration sits in the native vlan and the
                # allowed list.
                $vlanInfo = Get-AdapterVlanInfo -Adapter $adapter
                $adapterData["{#ADAPTER.VLAN}"] = $vlanInfo.AccessVlanId
                $adapterData["{#ADAPTER.VLAN.MODE}"] = $vlanInfo.Mode
                $adapterData["{#ADAPTER.VLAN.NATIVE}"] = $vlanInfo.NativeVlanId
                $adapterData["{#ADAPTER.VLAN.ALLOWED}"] = $vlanInfo.AllowedList

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
                    "{#ADAPTER.VLAN.MODE}" = "Unknown"
                    "{#ADAPTER.VLAN.NATIVE}" = "0"
                    "{#ADAPTER.VLAN.ALLOWED}" = ""
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

                $chainInfo = Get-DiskChainInfo -Disk $disk -VhdInfo $vhdInfo
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
                    "{#DISK.PARENT.PATH}" = $chainInfo.ParentPath
                    "{#DISK.IS.DIFFERENCING}" = $chainInfo.IsDifferencing
                    "{#DISK.QOS.MAX.IOPS}" = $chainInfo.QosMaxIops
                    "{#DISK.QOS.MIN.IOPS}" = $chainInfo.QosMinIops
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
                "{#VM.CPU.USAGE}" = $runtimeInfo.CpuUsage.ToString()
                "{#VM.MEMORY.ASSIGNED}" = $runtimeInfo.MemoryAssigned.ToString()
                "{#VM.MEMORY.DEMAND}" = $runtimeInfo.MemoryDemand.ToString()
                "{#VM.MEMORY.PRESSURE}" = $runtimeInfo.MemoryPressure
                "{#VM.HEARTBEAT}" = $runtimeInfo.Heartbeat
                "{#VM.OPERATIONAL.STATUS}" = $runtimeInfo.OperationalStatus
                "{#VM.OPERATIONAL.STATUS.SECONDARY}" = $runtimeInfo.OperationalStatusSecondary
                "{#VM.SMART.PAGING.IN.USE}" = $runtimeInfo.SmartPagingInUse
                "{#VM.CLUSTERED}" = $runtimeInfo.Clustered
                "{#VM.METERING.ENABLED}" = $runtimeInfo.MeteringEnabled
                "{#VM.SECURITY.TPM}" = $securityInfo.TpmEnabled
                "{#VM.SECURITY.SHIELDED}" = $securityInfo.Shielded
                "{#VM.SECURITY.ENCRYPT.MIGRATION}" = $securityInfo.EncryptMigration
                "{#VM.SECURITY.SECURE.BOOT}" = $securityInfo.SecureBoot
                "{#VM.SECURITY.SECURE.BOOT.TEMPLATE}" = $securityInfo.SecureBootTemplate
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
                "{#VM.DVD.ISO.COUNT}" = $isoInfo.Count.ToString()
                "{#VM.DVD.ISO.PATHS}" = $isoInfo.Paths
                "{#VM.CHECKPOINT.COUNT}" = $checkpointSummary.Count.ToString()
                "{#VM.CHECKPOINT.OLDEST.NAME}" = $checkpointSummary.OldestName
                "{#VM.CHECKPOINT.OLDEST.CREATED}" = $checkpointSummary.OldestCreated
                "{#VM.CHECKPOINT.OLDEST.EPOCH}" = $checkpointSummary.OldestEpoch.ToString()
                "{#VM.CHECKPOINT.OLDEST.AGE}" = $checkpointSummary.OldestAge.ToString()
                "{#VM.CHECKPOINT.NEWEST.NAME}" = $checkpointSummary.NewestName
                "{#VM.CHECKPOINT.NEWEST.CREATED}" = $checkpointSummary.NewestCreated
                "{#VM.CHECKPOINT.NEWEST.EPOCH}" = $checkpointSummary.NewestEpoch.ToString()
                "{#VM.CHECKPOINT.NEWEST.AGE}" = $checkpointSummary.NewestAge.ToString()
                # Checkpoints minus the recovery points Hyper-V Replica manages itself
                "{#VM.CHECKPOINT.USER.COUNT}" = $checkpointSummary.UserCount.ToString()
                "{#VM.CHECKPOINT.USER.OLDEST.NAME}" = $checkpointSummary.UserOldestName
                "{#VM.CHECKPOINT.USER.OLDEST.CREATED}" = $checkpointSummary.UserOldestCreated
                "{#VM.CHECKPOINT.USER.OLDEST.EPOCH}" = $checkpointSummary.UserOldestEpoch.ToString()
                "{#VM.CHECKPOINT.USER.OLDEST.AGE}" = $checkpointSummary.UserOldestAge.ToString()
                "{#VM.CHECKPOINT.USER.NEWEST.NAME}" = $checkpointSummary.UserNewestName
                "{#VM.CHECKPOINT.USER.NEWEST.CREATED}" = $checkpointSummary.UserNewestCreated
                "{#VM.CHECKPOINT.USER.NEWEST.EPOCH}" = $checkpointSummary.UserNewestEpoch.ToString()
                "{#VM.CHECKPOINT.USER.NEWEST.AGE}" = $checkpointSummary.UserNewestAge.ToString()
                "{#VM.CHECKPOINT.REPLICA.COUNT}" = $checkpointSummary.ReplicaCount.ToString()
                "{#VM.CHECKPOINT.INFO}" = (ConvertTo-Json -InputObject $checkpointSummary.Info -Compress)
                "{#VM.REPLICATION.ENABLED}" = $replicationSummary.Enabled.ToString()
                "{#VM.REPLICATION.STATE}" = $replicationSummary.State
                "{#VM.REPLICATION.MODE}" = $replicationSummary.Mode
                "{#VM.REPLICATION.HEALTH}" = $replicationSummary.Health
                "{#VM.REPLICATION.FREQUENCY}" = $replicationSummary.Frequency.ToString()
                "{#VM.REPLICATION.LAST.TIME}" = $replicationSummary.LastTime
                "{#VM.REPLICATION.LAST.EPOCH}" = $replicationSummary.LastEpoch.ToString()
                "{#VM.REPLICATION.LAST.AGE}" = $replicationSummary.LastAge.ToString()
                "{#VM.REPLICATION.PRIMARY.SERVER}" = $replicationSummary.PrimaryServer
                "{#VM.REPLICATION.REPLICA.SERVER}" = $replicationSummary.ReplicaServer
                "{#VM.REPLICATION.RECOVERY.HISTORY}" = $replicationSummary.RecoveryHistory.ToString()
                "{#VM.REPLICATION.VSS.FREQUENCY}" = $replicationSummary.VSSFrequencyHours.ToString()
                "{#VM.REPLICATION.PENDING.SIZE}" = $replicationSummary.PendingSize.ToString()
                "{#VM.REPLICATION.AVG.SIZE}" = $replicationSummary.AvgSize.ToString()
                "{#VM.REPLICATION.MAX.SIZE}" = $replicationSummary.MaxSize.ToString()
                "{#VM.REPLICATION.AVG.LATENCY}" = $replicationSummary.AvgLatency.ToString()
                "{#VM.REPLICATION.MAX.LATENCY}" = $replicationSummary.MaxLatency.ToString()
                "{#VM.REPLICATION.SUCCESS.COUNT}" = $replicationSummary.SuccessCount.ToString()
                "{#VM.REPLICATION.MISSED.COUNT}" = $replicationSummary.MissedCount.ToString()
                "{#VM.REPLICATION.ERROR.COUNT}" = $replicationSummary.ErrorCount.ToString()
                "{#VM.REPLICATION.STATS.WINDOW}" = $replicationSummary.StatsWindow.ToString()
                "{#VM.INTEGRATION.INFO}" = (ConvertTo-Json -InputObject (Get-IntegrationServiceInfo -Services $vmIntegrationServices) -Compress)
            }
            "networks" = @($networkLLD)
            "disks" = @($diskLLD)
            "checkpoints" = @($checkpointSummary.Info)
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
            "checkpoints" = @()
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
