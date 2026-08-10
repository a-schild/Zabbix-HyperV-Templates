# Changelog

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
