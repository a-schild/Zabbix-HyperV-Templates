# Zabbix Agent 2 Templates for Hyper-V monitoring 

## Important infos for users of the original version
The new version uses a complete new approach for discover and monitorting.
Due to this, the templates and the powershell scripts have been renamed.
Also all the naming of the detected VM's has been changed to VM on HOST.domain.local (FQDN)

So all old values/vm's in Zabbix will not be used by the new solution.
Old and new monitoring can work side-by-side, so you can do the transition
on a per-host basis.

Once all hosts are switched over to the new monitoring you can
delete and clear the old templates from your Zabbix server.


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
  1. Template_Windows_HyperV_VM_Guest2.xml (or the yaml version)
  2. Template_Windows_HyperV_Host2.xml (or the yaml version)

* Copy provided PowerShell script to the desired location on your HyperV host machine.
   `C:\Program Files\Zabbix Agent 2\` is the default used in the config file.
* Copy provided zabbix agent config file hyper-v.confto the desired location on your HyperV host machine.
   `C:\Program Files\Zabbix Agent 2\zabbix_agent2.d` is the default used in the config file.

* Optionally, depending your powershell security settings
Assuming your host is called my-hyperv-hostname, you can create a self siged certificate and sign it as follow:
```$cert = New-SelfSignedCertificate -DnsName "my-hyperv-hostname" -type codesigning
 Set-AuthenticodeSignature -Certificate $cert -FilePath 'C:\Program Files\Zabbix Agent 2\hyper-v-monitoring2.ps1
$exportPath = "C:\myCert.cer"
Export-Certificate -Cert $cert -FilePath $exportPath
Import-Certificate -FilePath $exportPath -CertStoreLocation Cert:\LocalMachine\TrustedPublisher
Import-Certificate -FilePath $exportPath -CertStoreLocation Cert:\LocalMachine\Root
Remove-Item -Path $exportPath
```

* In case you don't care about security, you can lower the restrictions
  If you downloaded the script from internet, then make sure windows is not blocking it.
   
  `Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope LocalMachine`
   
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
```The argument 'C:\Program Files\Zabbix Agent 2\hyper-v-monitoring2.ps1' to the -File parameter does not exist. 
Provide the path to an existing '.ps1' file as an argument to the -File parameter.
Windows PowerShell 
Copyright (C) 2016 Microsoft Corporation. All rights reserved.
```


## F.A.Q.

- Depending on the load of your Hyper-V server, you will have to increase the default
  **Zabbix Timeout from 3 to 15-30 seconds

- The Hyper-V Host needs to be setup to use passive Zabbix agent.
  The active agent won't work, as the VM's don't have an active agent inside
  
- Make sure the agent is allowed to execute the hyper-v-monitoring2.ps1 file.
  For this open a cmd console in the `C:\Program Files\Zabbix Agent 2` location
  Then type `powershell hyper-v-monitoring2.ps1` + enter
  This should return a json structure with all the VM's on this host,
  including the vm state, and the replication status

```cmd
c:\Program Files\Zabbix Agent 2\>powershell .\hyper-v-monitoring2.ps1
```
- This should return a big json object with all VM's on the server
  including some details

If the discovery still does not work, try to get the vm list via zabbix_get and the agent.
You might have to allow 127.0.0.1 in the agent config.
This should return the same json data as invoking the script directly

```cmd
zabbix_get -s 127.0.0.1 -k hyperv.discovery --tls-connect psk \
    --tls-psk-identity SERVER-IDENTITY --tls-psk-file "C:\Program Files\Zabbix Agent 2\psk.key"
```
