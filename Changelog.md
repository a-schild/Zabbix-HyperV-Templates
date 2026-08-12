# Changelog

- 2026-08-12 (unreleased)
  - Checkpoint triggers no longer fire on Hyper-V Replica recovery points.
    Get-VMSnapshot returns those next to normal checkpoints, so a replica VM
    configured for additional hourly recovery points ("Abdeckung durch
    zusätzliche Wiederherstellungspunkte", e.g. 24 hours) permanently carried
    ~25 checkpoints, the oldest a day old, and kept both checkpoint triggers in
    alarm. The script now classifies every checkpoint by its snapshot type
    (Replica, AppConsistentReplica, SyncedReplica, Planned, Recovery and Missing
    are Hyper-V Replica's own, Standard is a user checkpoint) and reports the
    counts and oldest/newest figures separately. New VM Guest items:
    'Checkpoints: user count', 'Checkpoints: user oldest age', 'Checkpoints:
    user oldest name' and 'Checkpoints: replica recovery points'. The two
    existing triggers now evaluate the user figures; the total count and oldest
    age items are unchanged and still include the recovery points. The raw
    checkpoint list gained an IsReplica flag per entry.
    Needs the updated hyper-v-monitoring2.ps1 on the Hyper-V hosts, the new
    items stay unsupported with the old script.
  - Replication monitoring on the VM guest hosts. Until now replication was
    only collected in the 'vms' payload, so it could only be seen on the
    Hyper-V host, never on the Zabbix host that represents the VM itself.
    The 'vmdetails' payload now carries the same fields and the VM Guest
    template exposes them as nine items: enabled, state, mode, health,
    frequency, last sync, last sync age, primary and replica server, with
    triggers on health Critical (high) and Warning.
    Collection moved into a shared Get-ReplicationSummary so both payloads
    stay in step.
  - Alerting on a replication that stopped running. Both payloads now report
    the age of the last completed replication in seconds, computed on the
    Hyper-V host so the Zabbix server does not have to guess its timezone.
    New trigger in both templates, driven by {$VM.REPLICATION.LAG.MAX}
    (default 1h): fires when a replicated VM has not completed a replication
    within that time. Hyper-V's own health field can still read Normal while
    cycles are merely slow, so this watches the clock directly.
    Keep {$VM.REPLICATION.LAG.MAX} well above the master item interval, the
    age is only refreshed when the item runs.
    On the Hyper-V Host template this arrives as the new
    'Replication last sync age {#VM.NAME}' item prototype; it reports 0
    instead of going unsupported when the host still runs the old script.
  - Replica recovery points that stop being merged are now caught. Both
    payloads report the VM's configured recovery point count and VSS snapshot
    interval (RecoveryHistory and VSSSnapshotFrequencyHour, both already
    available from the Get-VMReplication call, so no extra cost per poll), and
    the VM Guest template exposes them as 'Replication: recovery points
    configured' and 'Replication: VSS snapshot frequency'.
    The accompanying trigger fires when a Replica mode VM holds more recovery
    points than its own settings ask for, which means Hyper-V has stopped
    merging the old ones and the avhdx chain keeps growing. One point of slack
    is allowed for the moment during a replication cycle when the newest point
    exists alongside a full history.
    This is the counterpart to the checkpoint fix above: normal checkpoint
    alerting ignores replica recovery points, this watches them against what
    was actually configured.
  - Replication throughput and reliability, from Measure-VMReplication. Nine
    new VM Guest items: pending, average and maximum replication size, average
    and maximum latency, successful, missed and errored cycles, and the length
    of the measuring window those figures refer to.
    Two new triggers with tolerant defaults, since healthy VMs do miss the odd
    cycle and log the odd error: {$VM.REPLICATION.MISSED.MAX} (default 3) and
    {$VM.REPLICATION.ERRORS.MAX} (default 5).
    Note the cycle counts are per measuring window, not lifetime totals, and
    Hyper-V resets that window on its own, so never put a change() based
    trigger on them.
    Measure-VMReplication returns every replicated VM of a host in a single
    call, about a second for a host with a dozen VMs, so the 'vms' path fetches
    it once per run and looks the values up per VM instead of calling it in the
    loop. The 'vmdetails' path measures the single VM it was asked about.
  - Per VM CPU and memory usage. The VM Guest template had no runtime CPU or
    memory items at all: everything it showed was configuration (vCPU count,
    startup/min/max memory), and the only performance counters were disk and
    network ones. Both payloads now report the runtime figures the Get-VM
    object already carries, so this costs nothing per poll: CPU usage, memory
    assigned, memory demand and demand as a percentage of assigned, plus
    heartbeat, primary and secondary operational status, smart paging file in
    use, clustered and resource metering enabled.
    Memory demand is populated even with dynamic memory switched off, so the
    pressure figure works for every VM.
    Three new triggers: memory pressure above {$VM.MEMORY.PRESSURE.MAX}
    (default 90), no heartbeat from a running VM (NoContact or
    LostCommunication, the only signal these agentless VMs give that the guest
    OS is alive), and the smart paging file being in use.
    Note CPU usage is a spot sample taken when the master item runs, not an
    average over the interval. It answers "what is it doing right now" and is
    documented as unsuitable for CPU alerting; per virtual processor
    performance counters are the right source and are not collected yet.
    Not collected, having been checked on a real host and found unusable:
    MemoryStatus and IntegrationServicesState are empty and
    IntegrationServicesVersion reads 0.0 on current guests.
  - VLAN mode per network adapter. The templates already had a VLAN item, but it
    reported AccessVlanId alone, which is ambiguous: it reads 0 for an untagged
    adapter AND for a trunk, whose configuration actually lives in the native
    VLAN and the allowed list. Three new item prototypes on the network
    discovery rule report the operation mode (Untagged, Access, Trunk,
    Private), the native VLAN and the allowed VLAN list.
    No extra cost: Get-VMNetworkAdapter already returns the complete VLAN
    setting object on .VlanSetting, the same type Get-VMNetworkAdapterVlan
    hands back, so no additional cmdlet call is needed.
  - VM security items: virtual TPM, shielded, and whether saved state and live
    migration traffic are encrypted. One Get-VMSecurity call per VM, all values
    pure configuration, everything defaulting to False on hosts where the
    cmdlet is unavailable.
  - Replication page on the VM dashboard. The VM Guest template's dashboard
    gained a second page, 'Replication', with four graphs: latency and lag
    (average and maximum cycle latency, time since the last replication, and
    the configured frequency as a reference line), replication size (pending,
    average and maximum), cycles (successful, missed, errors) and replica
    recovery points (points held against points configured, with the user
    checkpoint count alongside).
    The existing page is now named 'Overview'.

- 2026-08-10 (unreleased)
  - README: added a Requirements section and a troubleshooting section keyed on
    the actual error messages (#39). It now states that the Hyper-V host needs
    a Zabbix Agent interface, and that the VM guest items are passive checks,
    so the server has to be able to reach the agent on port 10050. The host
    template is active and the guest template is passive, which is why a
    firewalled or Zabbix Cloud setup shows a perfectly healthy Hyper-V host and
    nothing but unavailable VMs. On site Zabbix proxy is the recommended fix.

- 2026-08-10
  - Release v2.0.6
  - Checkpoint monitoring (#47). The script already collected checkpoints but
    nothing consumed them. hyper-v-monitoring2.ps1 now also reports the oldest
    and newest checkpoint (name, creation time, epoch and age) in both the
    'vms' and the 'vmdetails' payload, and the VM Guest template exposes count,
    type, oldest/newest name, creation time and age, plus the raw list.
    Two new triggers: too many checkpoints ({$VM.CHECKPOINT.COUNT.MAX},
    default 3) and a checkpoint left behind ({$VM.CHECKPOINT.AGE.MAX},
    default 7d). Ages are computed on the Hyper-V host, so the Zabbix server
    does not have to guess the host's timezone.
  - The whole vm_info block was collected every poll and thrown away: no item
    in either template read a single field of it (#45 "I dont see any
    informations about the VMs like memory, CPU only Disks and NICs"). The VM
    Guest template now has 38 dependent items covering state, status, uptime,
    generation, configuration version, vCPU count/reserve/limit/weight, memory
    startup/min/max/dynamic/buffer/weight, autostart and autostop behaviour,
    config/checkpoint/smart-paging paths, notes, adapter/disk/dvd counts and
    the integration services. All are dependent on the existing master item,
    so they cost no additional agent or script calls.
  - Two new triggers on VM health: status not 'Operating normally' (warning)
    and VM not running (info, disable where VMs are legitimately off).
  - {#VM.INTEGRATION.INFO} is now part of the vmdetails payload too.
    Get-VMIntegrationService was already being called there and its result
    discarded.
  - Performance (#40):
    - The VM details poll interval is now the {$VM.DETAILS.INTERVAL} macro.
      The default stays 10m, so nothing changes unless you tune it. Every poll
      starts a powershell.exe, imports the Hyper-V module and runs Get-VHD over
      each disk, once per VM, so on a host with 20 VMs the 10m default is one
      such run every 30 seconds. Raise the macro to 30m or 60m on busy hosts.
    - The 21 disk performance counters now poll every 5m instead of every 1m.
      16 of them are queried on demand, so that is five times fewer agent
      queries per disk per VM.
    - The five disk counters that carry an averaging window (latency, read and
      write bytes/sec, read and write operations/sec) now average over 300s
      instead of 30s, so the value covers the whole 5m interval rather than
      sampling 30 seconds out of every 300. Note this changes their item key,
      so Zabbix treats them as new items and their history starts fresh.
      The agent samples these counters once a second regardless of the polling
      interval, so the change is about data quality, not agent load.
    - Network counters are left at 1m.
  - Refactor: checkpoint and integration service collection moved into
    Get-CheckpointSummary / Get-IntegrationServiceInfo so both payloads expose
    identical fields instead of duplicating the loops.
  - Fixed three further problems reported in #45:
    - The 'Replication Data' item prototype was a dependent item with no
      preprocessing and no explicit value type, so it defaulted to
      Numeric (unsigned) and received the entire VM array. It failed on every
      discovered VM with 'Value of type "string" is not suitable for value type
      "Numeric (unsigned)"'. It is now a TEXT item that extracts just its own
      VM's record. Its key also had a stray $ (hyperv.vm.data[${#VM.ID}]).
    - The replication items threw ZBX_UNSUPPORTED whenever a field was empty,
      which is the normal case for a VM without replication: no primary
      server, no replica server and no last sync time. Every non replicated VM
      therefore had three permanently unsupported items. They now return an
      empty value ("0" for the numeric replication frequency) and only throw
      when the VM itself is missing from the payload.
    - The calculated 'Hyper-V Host free memory' item needs vm.memory.size[total]
      and vm.memory.size[used], which come from a windows agent template and
      not from this one. That requirement is now documented in the item, in the
      template description and in the readme, instead of surfacing as
      'Cannot evaluate function: item ... does not exist'.

- 2026-08-10
  - Release v2.0.5
  - Fix #54: VM discovery failed on Hyper-V hosts with exactly one VM, with
    'Cannot find the "data" array in the received JSON object'. Piping an array
    to ConvertTo-Json unrolls it, so a single VM was emitted as a bare JSON
    object instead of an array. All discovery functions now serialize via
    ConvertTo-Json -InputObject. Hosts with zero VMs returned empty output
    before and now correctly return [].
  - Same fix applied to the embedded {#VM.NETWORK.INFO} / {#VM.DISK.INFO} /
    {#VM.DVD.INFO} / {#VM.INTEGRATION.INFO} / {#VM.CHECKPOINT.INFO} and
    {#HOST.VIRTUAL.SWITCHES} payloads, which had the same single-element
    problem (a VM with one nic, one disk, ...)
  - Developers.md: removed the stale notes about the xml/json counter cache and
    the RebuildCache command, which only existed in the v1 script

- 2026-06-11
  - Release v2.0.4
  - Removed a redundant agent/script call: the "Hyper-V VM Discovery" LLD rule
    is now a dependent rule on the hyperv.discovery.vms master item instead of
    polling the agent on its own schedule. Dropped the duplicate
    hyperv.discover.vms UserParameter from hyper-v.conf. This saves one full
    ~30s VM enumeration per discovery cycle.
  - hyper-v-monitoring2.ps1: replaced the remaining deprecated
    [System.Net.Dns]::GetHostByName() call (the v2.0.3 fix missed one of the
    two occurrences)
  - Host dashboard: added a "Hyper-V Host Memory" graph (free memory + memory
    pressure on a second axis), VMs-running / Total-VMs / vmms-service-state
    value tiles, and a Current problems widget
  - VM Guest dashboard: added a Current problems widget

- 2026-06-11
  - Release v2.0.3
  - Added data-collection health triggers on the Hyper-V host template: alert
    when the host data or VM master data item stops receiving data (catches an
    unsigned/blocked script, wrong path, or a stopped agent)
  - hyper-v-monitoring2.ps1: replaced the deprecated
    [System.Net.Dns]::GetHostByName() with GetHostEntry() for host FQDN
    resolution

- 2026-06-11
  - Release v2.0.2
  - Removed stale, disabled VM host prototype that still referenced the
    obsolete {#VMNAME_SAFE}/{#VMNAME}/{#VMHOST} LLD macros
  - Renamed the "Hyper-V VM Disk Discovery" rule to
    "Hyper-V VM Host Prototype Discovery" and added a description, since it
    creates one Zabbix host per VM (not per disk)
  - Added ZabbixAgentScriptSigner.ps1 helper to sign the monitoring script for
    AllSigned/RemoteSigned environments (based on PR #46 by AnthonyTepach),
    with a -ScriptPath parameter, admin requirement, signature timestamping,
    and documented signing/trust risks in the README

- 2025-12-02
  - Release v2.0.1
  - Fix some filenames in the readme.md file

- 2025-10-09
  - Release v2.0.0
  - Complete rewrite of LLD logic and related templates

- 2025-09-22
  - Better handling of special characters in VM names

- 2024-11-20
  - Switch item prototypes in VM Guest template to Zabbix passive agent

- 2024-11-13
  - Switched performance counters to work with all OS languages.
    Thanks to the new perf_counter_en zabbix item.
	Updated documentation
