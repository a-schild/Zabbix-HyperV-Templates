# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Zabbix 7.0+ monitoring for Hyper-V: one PowerShell collector script plus two exported Zabbix
templates. There is no build system, no test suite and no compiled artifacts — the "product" is
the four deployable files:

| File | Deployed to |
|---|---|
| `hyper-v-monitoring2.ps1` | `C:\Program Files\Zabbix Agent 2\` on each Hyper-V host |
| `hyper-v.conf` | `C:\Program Files\Zabbix Agent 2\zabbix_agent2.d\` |
| `Template_Windows_Hyper-V_Host2.yaml` | imported into Zabbix (import **second**) |
| `Template_Windows_Hyper-V_VM_Guest_2.yaml` | imported into Zabbix (import **first** — the host template links to it) |

`ZabbixAgentScriptSigner.ps1` is an optional helper for `AllSigned`/`RemoteSigned` hosts.
`sample-data/` holds captured script output and performance-counter dumps used as reference when
working on counter names — it is not test fixtures.

## Verifying changes

Everything is verified by running the script by hand on a Hyper-V host (or against a captured
sample) and checking the JSON:

```powershell
.\hyper-v-monitoring2.ps1 host                                  # host info object
.\hyper-v-monitoring2.ps1 vms                                   # array, one entry per VM (~30s on a busy host)
.\hyper-v-monitoring2.ps1 -DiscoveryType vmdetails -VmID <guid> # { vm_info, networks, disks }
.\hyper-v-monitoring2.ps1 vms -Debug                            # DEBUG lines to stdout — breaks JSON, diagnostics only
```

Then through the agent, which is where path/signing/timeout problems actually surface:

```cmd
zabbix_get -s 127.0.0.1 -k hyperv.discovery.vms
```

The YAML templates are only validated by importing them into a Zabbix server. Keep them valid
YAML and keep every `uuid:` unique — new items/triggers/prototypes need a freshly generated UUID
or the import fails.

## Architecture

**One script, three entry points.** `hyper-v.conf` maps three UserParameters onto
`hyper-v-monitoring2.ps1` (`host`, `vms`, `vmdetails[<vmid>]`); the script dispatches on
`$DiscoveryType` in the `switch` at the bottom. Adding a data source means adding a function, a
`switch` case, and usually a master item — not a new script.

**Master item → dependent everything.** Script invocations are expensive (a full `vms` run
enumerates every VM and takes ~30s), so each script call feeds exactly one master item and
everything else is `DEPENDENT` on it:

- Host template: `hyperv.discovery.host` and `hyperv.discovery.vms` are the only agent items that
  call the script. VM counts, replication items, the `Hyper-V VM Discovery` LLD rule and the
  `Hyper-V VM Host Prototype Discovery` rule all hang off them as dependent items/rules.
- Guest template: `hyperv.discovery.vmdetails[{$VM.ID}]` is the single master item; the three LLD
  rules (disks, regular NICs, legacy NICs, plus a disabled vCPU rule) and ~95 template-level
  items parse it. Its payload has
  five roots — `vm_info`, `networks`, `disks`, `checkpoints`, `vcpus`.

When adding anything, make it dependent on an existing master item. A new LLD rule or item that
polls the agent directly costs another full enumeration per interval.

**Know what a poll actually costs.** The vmdetails master item runs once *per VM per interval*,
and each run starts a `powershell.exe`, imports the Hyper-V module and calls `Get-VHD` on every
disk. On a 20-VM host a 10-minute interval is a fresh PowerShell every 30 seconds — the cause of
the CPU spikes in issue #40. The interval is the `{$VM.DETAILS.INTERVAL}` macro (default 30m).
Separately, the guest template's `perf_counter_en[...]` prototypes poll at 1m and there are ~21
per disk and ~19 per NIC, so a VM with two disks and a NIC is ~60 agent queries a minute. Those
are agent-side and cheap individually, but they multiply by VM count.

**Host prototypes create the VM hosts.** `Hyper-V VM Host Prototype Discovery` creates one Zabbix
host per VM named `{#VM.ID} {#VMHOST.FQDN}` and sets `{$VM.ID}`/`{$VMHOST.FQDN}` on it. That
`{$VM.ID}` macro is what parameterises the guest template's master item key. The prototype defines
no interface, so the created VM hosts inherit the Hyper-V host's agent interface.

**Item type asymmetry is deliberate.** Host-template script/counter items are `ZABBIX_ACTIVE`;
guest-template items (notably every `perf_counter_en[...]`) have no `type:` and are therefore
passive agent items. The VMs have no agent of their own — the requests go to the Hyper-V host's
agent over the inherited interface. Do not "fix" guest items to active.

## Conventions and traps

**Save `hyper-v-monitoring2.ps1` as UTF-8 *with* BOM.** Without it, localized counter and adapter
names get mangled. The file currently carries the BOM; preserve it when editing.

**LLD macros are the wire format.** The script emits Zabbix macro names as literal JSON keys
(`"{#DISK.ID}"`, `"{#VM.REPLICATION.HEALTH}"`, …) and the templates read those keys back. Renaming
a macro means editing the script *and* every consuming template item.

**JavaScript preprocessing splits macro names on purpose.** Inside preprocessing steps you will see:

```javascript
var diskIdMacro = "{"+"#"+"DISK.ID}";
```

The concatenation stops Zabbix from substituting the macro during LLD expansion, so the literal
string survives into the running script and can be used as a JSON key lookup. Never "simplify"
these into a single string literal.

**Counter names are English on every locale.** Items use `perf_counter_en[...]` with English
counter paths; the script additionally normalises localized Hyper-V strings (adapter names,
VM status, integration service names) through the `ConvertToEnglish` translation table for
German/French/Spanish/Italian/Portuguese. New localized values go into that table.
Note the German legacy adapter must be matched with a capital `Ä` — Windows is case-sensitive here
even though counters normally are not, and the legacy adapter exposes bytes/frames but no packet
counters.

**Never pipe an array into `ConvertTo-Json`.** PowerShell unrolls the pipeline, so a
single-element array serialises as a bare object and an empty one produces *no output at all* —
which is exactly how issue #54 (discovery broken on hosts with one VM) happened. Always
`ConvertTo-Json -InputObject $array`. (`-AsArray` would also work but needs PowerShell 6+; the
agent runs Windows PowerShell 5.1.) Arrays *nested inside* a hashtable are safe — only the
top-level pipeline unrolls. Note `Get-HyperVHostInfo` deliberately returns an object, not an
array: the host template addresses it as `$["{#HOST.VM.TOTAL.COUNT}"]`.

**Not every checkpoint is a checkpoint.** `Get-VMSnapshot` also returns the recovery points
Hyper-V Replica maintains, so a replica VM set to keep additional hourly recovery points carries
one per covered hour forever. `Get-CheckpointSummary` splits them off by `SnapshotType`
(`$script:ReplicaSnapshotTypes`: Replica, AppConsistentReplica, SyncedReplica, Planned, Recovery,
Missing) and exposes both sets; the triggers watch the `USER` figures only. `SnapshotType` is not
the VM's `CheckpointType` — a production checkpoint made by an admin is still `Standard` here.

**Not every property on the `Get-VM` object is usable.** Verified on a Server 2016-era host:
`MemoryStatus` and `IntegrationServicesState` come back empty, `IntegrationServicesVersion` reads
`0.0` (modern guests get the components through Windows Update), and `$vm.ReplicationState` can
disagree with `Get-VMReplication` for the same VM — it read `WaitingForInitialReplication` for a VM
that `Get-VMReplication` reported as `Replicating` with a recent `LastReplicationTime`. Replication
data comes from `Get-VMReplication`, never from the VM object. What *is* reliable and free:
`CPUUsage` (a spot sample, not an average — see `Get-VMRuntimeInfo`), `MemoryAssigned`,
`MemoryDemand` (populated even with dynamic memory off), `Heartbeat`, `PrimaryOperationalStatus`
(enum, unlike the localized `Status`) and `SmartPagingFileInUse`.

**VLAN needs no extra cmdlet.** `Get-VMNetworkAdapter` already returns the full VLAN setting
object on `.VlanSetting` — the same type `Get-VMNetworkAdapterVlan` returns — so mode, native VLAN
and allowed list are free. `AccessVlanId` on its own is ambiguous: it reads 0 both for an untagged
adapter and for a trunk, hence `{#ADAPTER.VLAN.MODE}` alongside it.

**Agent config requirements:** `UnsafeUserParameters=1` (counter paths contain backslashes) and a
raised agent `Timeout` (15–30s; items are set to `timeout: 30s`).

`Developers.md` holds the same hard-won notes from the maintainer's side — read it too.

## Branches and releases

**`main` is the default branch** and the working branch for everything described above.
`compat-3.0` is a frozen 2024 snapshot of the Zabbix 3.0-era version (XML templates,
`zabbix-vm-perf.ps1`), kept for users still on that server version; it is an ancestor of `main`
with nothing unique in it, so no changes go there. If git offers `compat-3.0` as the PR base, your
clone has a stale `origin/HEAD` — fix it with `git remote set-head origin -a`.

Release checklist:

1. Update `Changelog.md` — newest entry first, `YYYY-MM-DD`, then `Release vX.Y.Z` and the
   user-facing bullets.
2. Bump `vendor.version` in **both** templates to the same version. It is easy to forget and it is
   what Zabbix shows admins as the installed template version.
3. Merge to `main`, then push a `v*` tag.
4. `.github/workflows/build-package.yml` fires on the tag, zips the repo and uploads
   `Zabbix-HyperV-Templates.<tag>.zip` to a GitHub release.
5. The workflow leaves the release title and description **empty** — write them by hand. Fixes
   that need a redeployed `hyper-v-monitoring2.ps1` must say so explicitly, since re-importing the
   templates alone will not pick up script changes.
