# Windows VM POC: web + SQL disk layout (Terraform)

Deploys the Windows Server 2025 VMs listed in [terraform.tfvars](terraform.tfvars). Each VM's OS disk, data disks, drive letters and volume labels are configured there. A one-time in-guest script formats the disks and assigns their letters.

**What it demonstrates:** a local child module called with `for_each`; typed `optional()` defaults and validation owned by the module; `dynamic` blocks; zonal Premium SSD v2; managed Run Command; tempdb on the temp disk without the SQL IaaS Agent extension; and Microsoft's SQL-on-VM disk guidance.

## Structure

| Path | Holds |
|---|---|
| `main.tf` | Shared resources (resource group, VNet, subnet, NSG, admin password) and the `module "vm"` call, one instance per entry in `vms` |
| `modules/windows-vm/` | Everything for one VM: public IP, NIC, VM, data disks and attachments, disk setup Run Command, auto-shutdown. Owns the data disk defaults and validation. |
| `modules/windows-vm/scripts/Initialize-DataDisks.ps1` | One-time in-guest disk setup, run by the module |
| `modules/windows-vm/scripts/Set-SqlDefaultPaths.ps1` | One-time SQL Server default data, log and backup folders, run after disk setup on SQL VMs |
| `modules/windows-vm/scripts/Set-SqlTempDb.ps1` | One-time move of tempdb to the temp disk, and install of the startup task, run last on SQL VMs |
| `modules/windows-vm/scripts/Start-SqlOnTempDisk.ps1` | Runs at every boot: re-creates the tempdb folders, then starts SQL Server |
| `scripts/Get-DriveInventory.ps1` | Read-only drive snapshot you run yourself (see below) |

## Layout

| VM | Size | Drives |
|---|---|---|
| web1 | `Standard_B2als_v2`, Windows Server 2025 | C: OS (128 GB StandardSSD), D: Data |
| db01 | `Standard_B2ms`, SQL Server 2025 Standard Developer on Windows Server 2025 | C: OS (128 GB Premium), D: temp disk (tempdb, pagefile), E: Application, F: SqlData (`F:\Data`), G: SqlLogs (`G:\Log`), H: SqlBackups (`H:\Backup`) |

CD/DVD drives move to Z:. Both VMs are in zone 1. The folders in brackets are SQL Server's default locations for new databases and backups.

## Design decisions

| Decision | Reason |
|---|---|
| db01 uses a temp-disk size; tempdb on D: | Microsoft's recommended placement. The temp disk is wiped on deallocation, and SQL Server can't start if the tempdb folders are missing, so something must re-create them at boot. |
| No SQL IaaS Agent extension | The deploying identity isn't allowed to create `azurerm_mssql_virtual_machine`, so scripts do what it did. You also lose what only the extension gives: the portal's SQL virtual machines blade, automated backup and patching. SQL licensing on a Marketplace image still bills through the image. If the subscription turns on automatic SQL registration, the extension can appear anyway, so check that it doesn't take over tempdb. |
| Startup task instead of the extension | `Set-SqlTempDb.ps1` sets the SQL services to Manual and registers a scheduled task, run as SYSTEM, that creates the folders, grants the service account access and starts SQL Server. This is the one piece of this design that runs at every boot, so tell the hardening team: it needs scheduled tasks, `-ExecutionPolicy Bypass`, and SQL services left on Manual. If the task fails, SQL Server stays stopped; its log is `C:\ProgramData\SqlTempDb\Start-SqlOnTempDisk.log`. |
| tempdb moved in single-user mode | SYSTEM isn't a sysadmin on these images, and Run Command runs as SYSTEM. Starting SQL Server with `/mSQLCMD` gives local administrators sysadmin rights for that session, with no stored password. |
| No `data_settings`/`log_settings` either | The extension's own storage pools would need Premium SSD, not Premium SSD v2 (except a portal-only preview on Ebdsv5/Ebsv5). The setup scripts format the disks and set the default folders. |
| SQL default folders set by a second Run Command | A data disk with `sql_role = "data"`, `"log"` or `"backup"` becomes SQL Server's default folder for that role (`<letter>:\Data`, `\Log`, `\Backup`). `Set-SqlDefaultPaths.ps1` creates the folders, grants the SQL Server service account full control, writes the instance's `DefaultData`, `DefaultLog` and `BackupDirectory` registry values (what SSMS's Server Properties page changes) and restarts SQL Server. One-time, like the disk setup, and ordered after it. Keeps Premium SSD v2 for data and log. |
| tempdb uses the default 8 data files | Microsoft's guidance is one file per vCPU, up to 8. Production SQL VMs have 8 or more vCPUs, so `Set-SqlTempDb.ps1` defaults to 8, with the extension's sizes (256 MB per file, 512 MB growth) rather than the image's 8 MB. On the 2-vCPU lab VM, 8 files is more than needed but harmless. Going past 8 files (in multiples of 4) is a tuning step after you see contention. |
| Pagefile on the temp disk (db01) and on C: (web1) | Azure's defaults for sizes with and without a temp disk |
| db01 is `B2ms` | Cheapest x64 size with a SCSI temp disk and Premium storage (Premium SSD v2 needs it). 8 GB RAM is enough for SQL Server in a design test. Max 4 data disks, all used. Avoid v6 sizes: their temp disks are NVMe. |
| SQL Server 2025 Standard Developer image | No SQL license cost for dev/test (`PAYG` license type). Standard Developer matches Standard edition's feature limits. |
| Zone 1 | Premium SSD v2 attaches only to zonal VMs in East US 2. A zonal VM's disks must be in the same zone. |
| Caching: None on all data disks (module default) | Microsoft guidance: logs None. Premium SSD v2 doesn't support host caching. On Premium SSD v1, use ReadOnly for data files. |
| 64 KB NTFS allocation units on SQL volumes | Microsoft guidance for SQL data, log, tempdb and backup volumes |
| Premium SSD v2 `iops` / `mbps` inputs | Performance is set separately from size. Validation applies Azure's rules: IOPS from 3,000 up to 500 per GiB (max 80,000); MB/s from 125 up to 0.25 per IOPS (max 2,000), fixed at 125 for disks of 6 GiB or less. |
| VM uncached disk limit | `B2ms` allows only 1,920 IOPS / 22.5 MB/s for all data disks combined, so db01 is for design tests, not performance tests. Check with `az vm list-skus --size <size>` and look for `UncachedDisk*`: disk performance above the VM's limit is wasted. |
| Explicit `lun` per disk in tfvars | A disk's LUN is part of its identity. If list position decided it, inserting a disk would renumber (detach and reattach) every disk after it. |
| One-time Run Command, LUN-based | Runs at deploy only, never at boot. The LUN is the identifier Azure and Windows share. The script only considers disks off the boot disk's SCSI controller, because the OS disk and temp disk share that controller and its LUN numbers. SCSI sizes only: NVMe (v6) sizes number disks differently. |

## Run

```powershell
az login
$env:ARM_SUBSCRIPTION_ID = az account show --query id --output tsv
$env:TF_VAR_allowed_rdp_source_ip = Invoke-RestMethod https://api.ipify.org

terraform init
terraform plan -out tfplan
terraform apply tfplan
```

Connect:

```powershell
terraform output rdp_commands
terraform output -raw admin_password | Set-Clipboard
```

Check the disk setup output without RDP:

```powershell
az vm run-command show --resource-group rg-lab-eastus2 --vm-name db01 --name initialize-data-disks --instance-view --query instanceView.output --output tsv
```

Snapshot disks, volumes, letter reservations and pagefile (read-only):

```powershell
az vm run-command invoke --resource-group rg-lab-eastus2 --name db01 --command-id RunPowerShellScript --scripts '@scripts\Get-DriveInventory.ps1'
```

Tear down (stops all charges). Start the VMs first if auto-shutdown deallocated them: Azure only deletes extensions (Run Command) on a running VM.

```powershell
az vm start --ids (az vm list --resource-group rg-lab-eastus2 --query "[].id" --output tsv)
terraform destroy
```

## Adding or changing VMs

Edit `terraform.tfvars`. Leave out `caching` and `allocation_unit_kb` when they match the module defaults (`None`, 4 KB). Each data disk sets its `lun` explicitly (0–63, unique per VM). The convention is sequential in drive-letter order. Because LUNs are explicit, list order doesn't matter, and adding a disk never renumbers the others. Changing an *existing* disk's LUN detaches and reattaches it, so treat LUNs as fixed once deployed. On a SQL VM, set `sql_role = "data"`, `"log"` or `"backup"` on at most one disk each to make it SQL Server's default folder for that role.

## Notes

- **Cost:** about $0.05/hour for web1 and $0.09/hour for db01 (compute plus Windows license; SQL Developer edition is free), plus roughly $30/month for disks. Auto-shutdown at 19:00 Central deallocates the VMs, but disks and public IPs still bill. Use `destroy` when you're done.
- The admin password is generated by Terraform and stored in local state, which is gitignored.
- If your IP changes, set `TF_VAR_allowed_rdp_source_ip` again and re-apply.
