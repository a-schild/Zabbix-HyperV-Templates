# Changelog

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
