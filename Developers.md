# Zabbix Agent 2 Templates for Hyper-V monitoring 

## Important informations for developers

- The powershell script needs to the saved with UTF-8 encoding,
  __including __BOM (Byte order mask).
- Failing to do so, might result in corrupt localized counter names
  
- Put the file hyper-v.conf in C:\Program files\Zabbix Agent 2\zabbix_agentd.d
  Adjust the paths according to the previous step if needed
  __Set UnsafeUserParameters=1 as the performance counters names have \\ in it

- Storing the cache as json does not work, since the names sometimes contain utf8 entities
  This is why we switched to the xml format for the cache
  
- The whole counter naming is a big mess in windows and even worse 
  when used via powershell
  
- Usually counters and instances are not case sensitive
- But for the legacy network adapter, in german it's called 
  "Ältere Netzwerkkarte...", you must call the perf counter
  with a capital Ä  , a lowercase ä won't work, MS apparently has a problem
  here
  
- And the legacy network interface has only counters for bytes and frames sent
  but not for packets
  
- `.\hyper-v-monitoring.ps1 RebuildCache`