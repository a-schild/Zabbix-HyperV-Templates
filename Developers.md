# Zabbix Agent 2 Templates for Hyper-V monitoring 

## Important informations for developers

- The powershell script needs to the saved with UTF-8 encoding,
  __including __BOM (Byte order mask).
- Failing to do so, might result in corrupt localized counter names
  
- Put the file hyper-v.conf in C:\Program files\Zabbix Agent 2\zabbix_agentd.d
  Adjust the paths according to the previous step if needed
  __Set UnsafeUserParameters=1 as the performance counters names have \\ in it

- `.\hyper-v-monitoring.ps1 RebuildCache`