# Zabbix Agent 2 Templates for Hyper-V monitoring 

## Description
Simple Hyper-V Guest and Host templates.

Compatible with Zabbix Server 7.0+

The scripts are setup for the Agent2, but they also work with the 
normal agent if you adapt some paths in the conf file.

* Template Windows Hyper-V Guest  
Discovers VM guest performance counters and creates Zabbix items for each of them.

The following parameters are discovered and monitored:
	* Hyper-V Virtual Storage Device (ops/s and Bytes/s)
	* Hyper-V Virtual Network Adapter (Bytes/s)
	* Hyper-V Hypervisor Virtual Processor(Total Run Time, %)
    * Hyper-V VM replication status

* Template Windows HyperV Host  
The following _host_ parameters are monitored:
	* Hyper-V Hypervisor Logical Processor(_Total)\% Guest Run Time
	* Hyper-V Hypervisor Logical Processor(_Total)\% Hypervisor Run Time
	* Hyper-V Hypervisor Logical Processor(_Total)\% Idle Time
	* Hyper-V Hypervisor Root Virtual Processor(_Total)\% Guest Run Time
	* Hyper-V Hypervisor Root Virtual Processor(_Total)\% Hypervisor Run Time
	* Hyper-V Hypervisor Root Virtual Processor(_Total)\% Remote Run Time
	* Hyper-V Hypervisor Root Virtual Processor(_Total)\% Total Run Time
	* Hyper-V Hypervisor Virtual Processor(_Total)\% Guest Run Time
	* Hyper-V Hypervisor Virtual Processor(_Total)\% Hypervisor Run Time
	* Hyper-V Hypervisor Virtual Processor(_Total)\% Remote Run Time
	* Hyper-V Hypervisor Virtual Processor(_Total)\% Total Run Time
	* Hyper-V Virtual Switch(*)\Bytes
	* Hyper-V Virtual Machine Health Summary\Health Critical
	
* Currently the script+template only work for servers installed with the EN or DE image
  This is due to the way windows handels performance counters, they always
  use names corresponding to the initial windows image language

## Usage
* Import provided templates in this order
  1. Template_Windows_HyperV_VM_Guest.xml (or the yaml version)
  2. Template_Windows_HyperV_Host.xml (or the yaml version)

*  Copy provided PowerShell script to the desired location on your HyperV host machine.
   If your server(s) are not running a english version of windows, you will have to modify
   the performance counters to match the names in the server OS language.

*  Assuming your host is called my-hyperv-hostname, you can create a self siged certificate and sign it as follow:
```$cert = New-SelfSignedCertificate -DnsName "my-hyperv-hostname" -type codesigning
 Set-AuthenticodeSignature -Certificate $cert -FilePath 'C:\Program Files\Zabbix Agent 2\zabbix-vm-perf.ps1
$exportPath = "C:\myCert.cer"
Export-Certificate -Cert $cert -FilePath $exportPath
Import-Certificate -FilePath $exportPath -CertStoreLocation Cert:\LocalMachine\TrustedPublisher
Import-Certificate -FilePath $exportPath -CertStoreLocation Cert:\LocalMachine\Root
Remove-Item -Path $exportPath
```

*  In case you don't care about security, you can lower the restrictions
   If you downloaded the script from internet, then make sure windows is not blocking it.
   
   Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope LocalMachine
   
   
* Put the file hyper-v.conf in C:\Program files\Zabbix Agent 2\zabbix_agentd.d
  Adjust the paths according to the previous step if needed

* Restart zabbix agent.

* Set-up Hyper-V host in Zabbix interface. 
	* Add a new host, if needed.
	* Link it with "Template Windows HyperV Host" template. 
	* Wait for a guest discovery to fire, it will:
		* discover Hyper-V guests, 
		* create a new host for each VM,
		* put discovered VM host into "Hyper-V VM" group,
		* link VM host with "Template Windows HyperV VM Guest"
* Go to the Hyper-V host in the Zabbix interface and click on the discoveries, and click on test.
	* If you get an error check
		* If your certificate is signed/you changed the policy to unrestricted.
		* If your path in the config file is correct.
```The argument 'C:\Program Files\Zabbix Agent 2\zabbix-vm-perf.ps1' to the -File parameter does not exist. 
Provide the path to an existing '.ps1' file as an argument to the -File parameter.
Windows PowerShell 
Copyright (C) 2016 Microsoft Corporation. All rights reserved.
```


## F.A.Q.

- Depending on the load of your Hyper-V server, you will have to increase the default
  Zabbix Temout from 3 to 10-30 seconds
  
- Make sure the agent is allowed to execute the zabbix-vm-perf.ps1 file.
  For this open a cmd console in the `C:\Program Files\Zabbix Agent 2` location
  Then type `powershell zabbix-vm-perf.ps1` + enter
  This should return a json structure with all the VM's on this host,
  including the vm state, and the replication status

```cmd
c:\Program Files\Zabbix Agent 2\zabbix_agent2.d>powershell .\zabbix-vm-perf.ps1
```
Example output
```json
{
 "data":[

 { "{#VMNAME}":"apps-company" ,"{#VMSTATE}":"Running", "{#VMHOST}":"SV02-HV" ,"{#REPLICATION}":"Suspended" },
 { "{#VMNAME}":"ipva-company" ,"{#VMSTATE}":"Running", "{#VMHOST}":"SV02-HV" ,"{#REPLICATION}":"Suspended" },
 { "{#VMNAME}":"rp-company" ,"{#VMSTATE}":"Running", "{#VMHOST}":"SV02-HV" ,"{#REPLICATION}":"Error" },
 { "{#VMNAME}":"SV02" ,"{#VMSTATE}":"Running", "{#VMHOST}":"SV02-HV" ,"{#REPLICATION}":"Error" },
 { "{#VMNAME}":"sv03" ,"{#VMSTATE}":"Running", "{#VMHOST}":"SV02-HV" ,"{#REPLICATION}":"Disabled" },
 { "{#VMNAME}":"sv05" ,"{#VMSTATE}":"Running", "{#VMHOST}":"SV02-HV" ,"{#REPLICATION}":"Error" },
 { "{#VMNAME}":"sv101" ,"{#VMSTATE}":"Running", "{#VMHOST}":"SV02-HV" ,"{#REPLICATION}":"Error" },
 { "{#VMNAME}":"XCase" ,"{#VMSTATE}":"Off", "{#VMHOST}":"SV02-HV" ,"{#REPLICATION}":"WaitingForStartResynchronize" }
 ]
}
```

If the discovery still does not work, try to get the vm list via zabbix_get and the agent.
You might have to allow 127.0.0.1 in the agent config.
This should return the same json data as invoking the script directly

```cmd
zabbix_get -s 127.0.0.1 -k hyperv.discovery --tls-connect psk \
    --tls-psk-identity SERVER-IDENTITY --tls-psk-file "C:\Program Files\Zabbix Agent 2\psk.key"
```

- Zabbix log file
  It is normal to see some errors in the zabbix agent log file.
  Since the script works for EN and DE installed servers, we have to query both
  performance counters. And the counters in the other language don't exist
  so they show up as errors in the log file, but can be ignored.

```log
2024/11/13 10:07:31.031561 check 'perf_counter[\Hyper-V Hypervisor Root Virtual Processor(_Total)\% Remote Run Time]' is not supported: Failed to get counter for path "\\Hyper-V Hypervisor Root Virtual Processor(_Total)\\% Remote Run Time" and lang 0: Cannot add counter: Das angegebene Objekt wurde nicht auf dem Computer gefunden.
.
2024/11/13 10:07:32.030406 check 'perf_counter[\Hyper-V Hypervisor Root Virtual Processor(_Total)\% Total Run Time]' is not supported: Failed to get counter for path "\\Hyper-V Hypervisor Root Virtual Processor(_Total)\\% Total Run Time" and lang 0: Cannot add counter: Das angegebene Objekt wurde nicht auf dem Computer gefunden.
. ```  

## Bugs
* There are no Triggers for VM Guest.


## License:


Copyright (c) 2014     , Dmitry Sarkisov <ait.meijin@gmail.com>
Copyright (c) 2016-2024, Andre Schild <a.schild@aarboard.ch>

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
