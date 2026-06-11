# Changelog

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
