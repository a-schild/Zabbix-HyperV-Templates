#Zabbix Agent Templates for Hyper-V monitoring 



## Usage
1. Import provided templates.  
Allow Zabbix to create necessary groups. (Just to check that everything works as expected. You can modify all the details to suit your needs later.)

2.  Copy provided PowerShell script to the desired location on your HyperV host machine.

3. Put these lines in your _zabbix_agentd.conf_ on Hyper-V Host  
 Adjust the paths according to the previous step.

`UserParameter=hyperv.discovery,powershell.exe -file "C:\Program Files\Zabbix\zabbix-vm-perf.ps1"`

`UserParameter=hyperv.discoveryitem[*],powershell.exe -file "C:\Program Files\Zabbix\zabbix-vm-perf.ps1" "$1" "$2"`

`UserParameter=hyperv.check[*],powershell.exe -file "C:\Program Files\Zabbix\zabbix-vm-perf.ps1" "$1" "$2" "$3"`

 Restart agent

3. Set-up Hyper-V host. 
	* Add a new host as usual.
	* Link it with "Template Windows HyperV Host" template. 
	* Wait for a guest discovery to fire, it will:
		* discover Hyper-V guests, 
		* create a new host for each VM,
		* put discovered VM host into "Hyper-V VM" group,
		* link VM host with "Template Windows HyperV VM Guest"

4. Template Windows Hyper-V Guest  
Intended to discover VM guest performance counters and create Zabbix items for each of them.
The following parameters are monitored:




## License:


Copyright (c) 2014, Dmitry Sarkisov <ait.meijin@gmail.com>

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
