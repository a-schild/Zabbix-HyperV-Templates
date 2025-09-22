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
	
## Usage
* Import provided templates in this order
  1. Template_Windows_HyperV_VM_Guest.xml (or the yaml version)
  2. Template_Windows_HyperV_Host.xml (or the yaml version)

*  Copy provided PowerShell script to the desired location on your HyperV host machine.
   `C:\Program Files\Zabbix Agent 2\` is the default used in the config file.

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
c:\Program Files\Zabbix Agent 2\>powershell .\zabbix-vm-perf.ps1
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


## Bugs
* There are no Triggers for VM Guest.

## Changelog
- 2025-09-22
  - Better handling of special characters in VM names
- 2024-11-20
  - Switch item prototypes in VM Guest template to Zabbix passive agent
- 2024-11-13
  - Switched performance counters to work with all OS languages.
    Thanks to the new perf_counter_en zabbix item.
	Updated documentation
