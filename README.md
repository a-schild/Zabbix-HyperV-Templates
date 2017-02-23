#Zabbix Agent Templates for Hyper-V monitoring 

## Description
Simple Hyper-V Guest and Host templates

* Template Windows Hyper-V Guest  
Intended to discover VM guest performance counters and create Zabbix items for each of them.
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
* Import provided templates.  
Allow Zabbix to create necessary groups. 
(Just to check that everything works as expected. You can modify all the details to suit your needs later.)

*  Copy provided PowerShell script to the desired location on your HyperV host machine.
   If your server(s) are not running a english version of windows, you will have to modify
   the performance counters to match the names in the server OS language.

*  Depending on your powershell security settings, you need to lower the restrictions
   If you downloaded the script from internet, then make sure windows is not blocking it.
   
   Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope LocalMachine
   
* Put these lines in your _zabbix_agentd.conf_ on Hyper-V Host  
 Adjust the paths according to the previous step.

`UserParameter=hyperv.discovery,powershell.exe -file "C:\Program Files\Zabbix\zabbix-vm-perf.ps1"`

`UserParameter=hyperv.discoveryitem[*],powershell.exe -file "C:\Program Files\Zabbix\zabbix-vm-perf.ps1" "$1" "$2"`

`UserParameter=hyperv.check[*],powershell.exe -file "C:\Program Files\Zabbix\zabbix-vm-perf.ps1" "$1" "$2" "$3"`

* Restart zabbix agent.

* Set-up Hyper-V host in Zabbix interface. 
	* Add a new host, if needed.
	* Link it with "Template Windows HyperV Host" template. 
	* Wait for a guest discovery to fire, it will:
		* discover Hyper-V guests, 
		* create a new host for each VM,
		* put discovered VM host into "Hyper-V VM" group,
		* link VM host with "Template Windows HyperV VM Guest"

## F.A.Q.



## Bugs
* There are no Triggers for VM Guest.


## License:


Copyright (c) 2014     , Dmitry Sarkisov <ait.meijin@gmail.com>
Copyright (c) 2016-2017, Andre Schild <a.schild@aarboard.ch>

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
