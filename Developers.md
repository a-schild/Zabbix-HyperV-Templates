# Zabbix Agent 2 Templates for Hyper-V monitoring 

## Important informations for developers

- The powershell script needs to the saved with UTF-8 encoding,
  __including __BOM (Byte order mask).
- Failing to do so, might result in corrupt localized counter names
  
- Put the file hyper-v.conf in C:\Program files\Zabbix Agent 2\zabbix_agentd.d
  Adjust the paths according to the previous step if needed
  __Set UnsafeUserParameters=1 as the performance counters names have \\ in it

- The whole counter naming is a big mess in windows and even worse 
  when used via powershell.
  The templates therefore use the perf_counter_en[] item key with the
  english counter paths, and hyper-v-monitoring2.ps1 normalizes localized
  values (adapter names, vm status, integration services) through the
  ConvertToEnglish translation table. New localized strings go in there.

- Usually counters and instances are not case sensitive
- But for the legacy network adapter, in german it's called 
  "Ältere Netzwerkkarte...", you must call the perf counter
  with a capital Ä  , a lowercase ä won't work, MS apparently has a problem
  here
  
- And the legacy network interface has only counters for bytes and frames sent
  but not for packets

- To test the script manually on a Hyper-V host:
```powershell
.\hyper-v-monitoring2.ps1 host
.\hyper-v-monitoring2.ps1 vms
.\hyper-v-monitoring2.ps1 -DiscoveryType vmdetails -VmID <vm-guid>
.\hyper-v-monitoring2.ps1 vms -Debug   # debug output, breaks the json
```