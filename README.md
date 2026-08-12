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
    * Hyper-V VM replication status, including how long ago the last
      replication completed
    * Checkpoints, counted separately from the recovery points Hyper-V Replica
      maintains by itself

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
	
## Requirements

Before importing anything, check these three. Most of the reported problems come
from one of them.

* **The Hyper-V host needs a Zabbix "Agent" interface.** Not just a host entry -
  an interface of type *Agent*, pointing at the Hyper-V host, port 10050. The
  discovered VM hosts inherit it. Without it, linking the template fails with
  `Cannot inherit LLD rule with key "hyperv.discover.vms" ... because a host
  interface of type "Agent" is required.`

* **The Zabbix server (or a proxy) must be able to reach that agent on port
  10050.** The two templates are deliberately different here:

  | Template | Check type | Direction |
  |---|---|---|
  | Hyper-V Host | active | agent connects out to the server |
  | Hyper-V VM Guest | passive | **server connects in to the agent** |

  Every VM guest item is a passive check, because the performance counters for a
  VM live on the Hyper-V host and the VMs have no agent of their own. If the
  server cannot open a connection to the host's agent, the Hyper-V host itself
  will look perfectly healthy while **every discovered VM stays unavailable**
  with `cannot establish TCP connection to [x.x.x.x]:10050: timed out`.

  This bites hardest with **Zabbix Cloud**, or any setup where the server is not
  on the same network as the Hyper-V host: the server sits on the internet and
  the host is behind NAT. Either allow inbound 10050 from the server, or - much
  better - **run a Zabbix proxy on site**. The proxy connects outbound to the
  cloud server and polls the agent locally, so nothing needs to be exposed.

* **A Windows agent template must be linked to the Hyper-V host as well**, for
  example "Windows by Zabbix agent". See the note under Usage below.

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

  Alternatively, run the bundled helper script `ZabbixAgentScriptSigner.ps1`
  from an **elevated** PowerShell. It creates (or reuses) a self-signed
  code-signing certificate, signs the monitoring script with a timestamp, and
  imports the certificate into the trusted stores:
```powershell
.\ZabbixAgentScriptSigner.ps1
# or point it at a different location / enforce AllSigned afterwards:
.\ZabbixAgentScriptSigner.ps1 -ScriptPath 'D:\Zabbix\hyper-v-monitoring2.ps1' -SetExecutionPolicy
```

  > **Security warning — understand what signing this way does before running it:**
  > - The certificate is imported into `Cert:\LocalMachine\Root`, so the host
  >   trusts it as a root CA. Anything signed by the matching private key is then
  >   treated as a trusted publisher on this machine. (Root is needed only
  >   because the certificate is self-signed and is therefore its own CA.)
  > - The private key stays in `Cert:\LocalMachine\My` on the host. Anyone with
  >   administrative/local access can use it to sign arbitrary scripts that will
  >   pass `AllSigned` and look trusted — the signature proves nothing about
  >   identity, it is self-issued.
  > - `-SetExecutionPolicy AllSigned` affects **every** PowerShell script on the
  >   machine, not just this one.
  >
  > Lower-risk options: sign with a certificate from your internal/enterprise PKI
  > (no Root import, identity is validated), use `RemoteSigned` instead of
  > `AllSigned`, or scope the execution policy to a process/user instead of the
  > whole machine.

  ### Preferred in a domain: sign with an Active Directory CA (AD CS)

  If you have an Active Directory enterprise CA (AD Certificate Services), this
  is the recommended approach and avoids the biggest risks of the self-signed
  flow above. Because the enterprise CA is already a trusted root on every
  domain-joined machine (published automatically via Group Policy), a script
  signed by an AD-issued **Code Signing** certificate is trusted across the
  whole domain with **no per-host `Root` import**.

  Benefits over self-signing:
  * **No `LocalMachine\Root` import** on the Hyper-V hosts — the issuing CA is
    already trusted domain-wide. (At most you push the signing cert into
    `TrustedPublisher` via GPO to suppress the `AllSigned` prompt.)
  * **Sign once, centrally.** Sign `hyper-v-monitoring2.ps1` a single time on a
    controlled workstation/build server, then deploy the already-signed file to
    every host. The private key never has to live on the monitored Hyper-V
    hosts.
  * **Revocable.** If the signing certificate is ever compromised, revoke it at
    the CA (CRL/OCSP) and the whole domain stops trusting anything it signed.
  * **Real identity.** The signature is tied to an AD identity issued under your
    CA's policy, not a self-issued certificate that proves nothing.

  Workflow (requires a Code Signing certificate template enrolled in AD CS):
```powershell
# On a controlled signing box, request a Code Signing certificate from AD CS
# (Get-Certificate uses the "CodeSigning" template; adjust -Template to your
#  duplicated template name and enrollment permissions as needed):
$cert = (Get-Certificate -Template CodeSigning `
    -CertStoreLocation Cert:\CurrentUser\My -Url ldap:).Certificate

# Sign the script once, with a timestamp so it stays valid after cert expiry:
Set-AuthenticodeSignature -Certificate $cert `
    -FilePath 'C:\Program Files\Zabbix Agent 2\hyper-v-monitoring2.ps1' `
    -TimestampServer 'http://timestamp.digicert.com'
```
  Then deploy the now-signed `hyper-v-monitoring2.ps1` to each Hyper-V host. No
  certificate import is needed on the hosts as long as the issuing enterprise CA
  is trusted there (the default for domain members). Under `AllSigned` you may
  additionally push the signing certificate to `TrustedPublisher` via GPO to
  avoid the one-time trust prompt.

  Use the bundled self-signed helper script only when no enterprise PKI is
  available — standing up AD CS just to sign one monitoring script is overkill.

* In case you don't care about security, you can lower the restrictions
  If you downloaded the script from internet, then make sure windows is not blocking it.
   
  `Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope LocalMachine`
   
* Restart zabbix agent.
* Set-up Hyper-V host in Zabbix interface. 
	* Add a new host, if needed.
	* Link it with "Template Windows HyperV Host" template. 
	* **Also link a Windows agent template** to the same host, for example
	  "Windows by Zabbix agent". The host memory items of the Hyper-V template
	  are calculated from `vm.memory.size[total]` and `vm.memory.size[used]`,
	  which come from that template. Without it you get
	  `Cannot evaluate function: item "vm.memory.size[total]" does not exist`
	  and the memory graph stays empty.
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


## Things that ship switched off

Two parts of the VM Guest template are deliberately disabled after import. Both work;
both cost more than they are worth to everybody by default.

### Per vCPU CPU counters — the `VM vCPU Discovery` rule

The `CPU usage` item shows the CPU load of a VM at the instant the master item ran,
once per `{$VM.DETAILS.INTERVAL}`. That answers *what is this VM doing right now*, but
it cannot show a spike that happened between two polls, and it must not be used for CPU
alerting.

Real per VM CPU utilisation comes from the Hyper-V virtual processor performance
counters, which the `VM vCPU Discovery` rule creates: guest run time, hypervisor run
time and total run time, per virtual processor.

**Why it is disabled:** these are agent items polled every minute, one set per virtual
processor. A VM with 4 vCPUs adds 12 agent queries a minute; a host with 20 such VMs
adds 240 a minute, on top of the roughly 60 per VM that the disk and network counters
already generate. On a busy Hyper-V host that is a noticeable amount of extra agent
work, and most people do not need per vCPU numbers on every VM.

**To enable it for every VM:**

*Data collection* → *Templates* → *Template Windows Hyper-V VM Guest 2* → *Discovery
rules* → *VM vCPU Discovery* → set *Enabled* and *Update*.

**To enable it for one VM only**, which is the better way to investigate a single noisy
machine: open that VM's host (*Data collection* → *Hosts* → the `<guid> <fqdn>` host) →
*Discovery rules* → *VM vCPU Discovery* → *Enabled*.

Consider raising the item prototypes' interval from `1m` to `5m` before enabling it
broadly — the counters are averages and stay useful at a lower resolution.

### Resource metering items

`Metering: *` items report 0 until Hyper-V resource metering is switched on for a VM,
which is not a template setting but a host one:

```powershell
Enable-VMResourceMetering -VMName ADS1        # one VM
Get-VM | Enable-VMResourceMetering            # every VM on the host
```

The script checks the per VM `ResourceMeteringEnabled` flag before measuring anything,
so hosts that never enable it pay nothing at all. Once enabled, the items report
averages since the last `Reset-VMResourceMetering`, which is the one honest source of
average CPU in MHz, normalised IOPS and disk latency per VM. `Resource metering
enabled` shows the current state.

## Troubleshooting by alert

**`Hyper-V: no heartbeat from <VM>`** on a VM that is perfectly healthy.
The guest has no working Hyper-V integration components — an appliance, an OS Hyper-V
has no components for, or a Linux guest without `hyperv-daemons` installed. Hyper-V
reports such a VM as `NoContact` forever, because it never had contact to lose.

The trigger already filters most of these out: it only fires when the guest reports an
OS name over the KVP exchange service, which a VM without integration components never
does. A VM whose OS *hangs* keeps its last published KVP values, so a real hang still
alerts.

If a VM still alerts wrongly — a guest that publishes KVP data but no heartbeat, for
instance — switch the check off for that VM alone:

*Data collection* → *Hosts* → the `<guid> <fqdn>` host → *Macros* → *Inherited and host
macros* → set `{$VM.HEARTBEAT.CHECK}` to `0`.

Setting it on the template instead disables the heartbeat check for every VM, which is
rarely what you want.

## Troubleshooting by error message

**`Cannot inherit LLD rule with key "hyperv.discover.vms" ... because a host
interface of type "Agent" is required`** when linking the template.
The Hyper-V host has no Agent interface. Add one (type *Agent*, the host's
address, port 10050) and link the template again.

**`Cannot find the "data" array in the received JSON object`** on
`hyperv.discover.vms.data`, usually on a host with only one VM.
A bug in versions before 2.0.5: a single VM was serialized as a json object
instead of a one element array. Upgrade `hyper-v-monitoring2.ps1` on the
Hyper-V host to 2.0.5 or newer. Re-importing the templates alone does not help,
the fix is in the script.

**`cannot establish TCP connection to [x.x.x.x]:10050: timed out`** on the
discovered VM hosts, while the Hyper-V host itself reports fine.
The VM guest items are passive checks, so the server has to reach the agent.
See Requirements above - with Zabbix Cloud or any server outside the host's
network, run a Zabbix proxy on site.

**`Cannot evaluate function: item "vm.memory.size[total]" does not exist`**.
Link a Windows agent template to the Hyper-V host, that is where those items
come from.

**`Value of type "string" is not suitable for value type "Numeric (unsigned)"`**
or **`ZBX_UNSUPPORTED: Field {#VM.REPLICATION.PRIMARY.SERVER} not found or
empty`**.
Both fixed in 2.0.6, re-import the templates.

**VM hosts are never created**, and the discovery shows no error.
Discovery runs hourly and the VM details every 29 minutes, so allow up to about
1.5 hours. If nothing appears after that, check that the "Hyper-V VMS master
data" item on the Hyper-V host actually has a value, and that both templates
were imported.

## F.A.Q.

- Depending on the load of your Hyper-V server, you will have to increase the default
  **Zabbix Timeout from 3 to 15-30 seconds

- The Hyper-V Host needs to be setup to use passive Zabbix agent.
  The active agent won't work, as the VM's don't have an active agent inside
  See the Requirements section for what that means for firewalls and Zabbix Cloud.
  
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
