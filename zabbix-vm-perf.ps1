<# 
Zabbix Agent PowerShell script for Hyper-V monitoring 


Copyright (c) 2015,2016 Dmitry Sarkisov <ait.meijin@gmail.com>

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"),
to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense,
and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.


#>


param(
	[Parameter(Mandatory=$False)]
	[string]$QueryName,
	[string]$VMName,
	[string]$VMObject
)

$hostname = Get-WmiObject win32_computersystem | Select-Object -ExpandProperty name

$VMName = $VMName.Replace("_" + $hostname, '')

<# Zabbix Hyper-V Virtual Machine Discovery #>
if ($QueryName -eq '') {
    
	
    $colItems = Get-VM

    write-host "{"
    write-host " `"data`":["
    write-host
	
    $n = $colItems.Count

    foreach ($objItem in $colItems) {
        $line =  ' { "{#VMNAME}":"' + $objItem.Name + '" ,"{#VMSTATE}":"' + $objItem.State  + '", "{#VMHOST}":"' + $hostname + '" }'
        if ($n -gt 1){
            $line += ","
        }
        write-host $line
        $n--
    }

    write-host " ]"
    write-host "}"
    write-host
    exit
}



<# Zabbix Hyper-V VM Perf Counter Discovery #>
if ($psboundparameters.Count -eq 2) {

    switch ($QueryName)
        {
        
        ('GetVMDisks'){
            $ItemType = "VMDISK"
            $Results =  (Get-Counter -Counter '\Hyper-V Virtual Storage Device(*)\Read Bytes/sec').CounterSamples  | Where-Object  {$_.InstanceName -like '*-'+$VMName+'-*'} | select InstanceName
        }

        ('GetVMNICs'){
            $ItemType = "VMNIC"
            $Results = (Get-Counter -Counter '\Hyper-V Virtual Network Adapter(*)\Packets Sent/sec').CounterSamples | Where-Object  {$_.InstanceName -like $VMName+'_*'} | select InstanceName
        }

        ('GetVMCPUs'){
             $ItemType  ="VMCPU"
             $Results = (Get-Counter -Counter '\Hyper-V Hypervisor Virtual Processor(*)\% Total Run Time').CounterSamples | Where-Object {$_.InstanceName -like $VMName+':*'} | select InstanceName
        }
            
        default {$Results = "Bad Request"; exit}
        }

    write-host "{"
    write-host " `"data`":["
    write-host      
    #write-host $Results
               
       
    $n = ($Results | measure).Count

            foreach ($objItem in $Results) {
                $line = " { `"{#"+$ItemType+"}`":`""+$objItem.InstanceName+"`"}"
                 
                if ($n -gt 1 ){
                    $line += ","
                }

                write-host $line
                $n--
            }
    
    write-host " ]"
    write-host "}"
    write-host


    exit
}



<# Zabbix Hyper-V VM Get Performance Counter Value #>
if ($psboundparameters.Count -eq 3) {


    switch ($QueryName){
            <# Disk Counters #>
            ('VMDISKBytesRead'){
                    $ItemType = $QueryName
                    $Results =  (Get-Counter -Counter "\Hyper-V Virtual Storage Device($VMObject)\Read Bytes/sec").CounterSamples

            }
            ('VMDISKBytesWrite'){
                    $ItemType = $QueryName
                    $Results =  (Get-Counter -Counter "\Hyper-V Virtual Storage Device($VMObject)\Write Bytes/sec").CounterSamples
            }
            ('VMDISKOpsRead'){
                    $ItemType = $QueryName
                    $Results =  (Get-Counter -Counter "\Hyper-V Virtual Storage Device($VMObject)\Read Operations/sec").CounterSamples

            }
            ('VMDISKOpsWrite'){
                    $ItemType = $QueryName
                    $Results =  (Get-Counter -Counter "\Hyper-V Virtual Storage Device($VMObject)\Write Operations/sec").CounterSamples

            }

            <# Network Counters #>
            ('VMNICSent'){
                    $ItemType = $QueryName
                    $Results = (Get-Counter -Counter "\Hyper-V Virtual Network Adapter($VMObject)\Bytes Sent/sec").CounterSamples
            }
            ('VMNICRecv'){
                    $ItemType = $QueryName
                    $Results = (Get-Counter -Counter "\Hyper-V Virtual Network Adapter($VMObject)\Bytes Received/sec").CounterSamples
            }


            <# Virtual CPU Counters #>
            ('VMCPUTotal'){
                $ItemType = $QueryName
                $Results = (Get-Counter -Counter "\Hyper-V Hypervisor Virtual Processor($VMObject)\% Total Run Time").CounterSamples
            }



            default {$Results = "Bad Request"; exit}
    }

    
            foreach ($objItem in $Results) {
                $line = [int]$objItem.CookedValue
                write-host $line
            }
        



    exit
}


