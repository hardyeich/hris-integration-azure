# Integration Credential Management

**Version:** 1.0  
**Last Updated:** 2026-06-16  
**Owner:** Dr. Hardy Eich 
**External Store:** <!-- link to password manager / Key Vault -->

---

## 1. Overview

This document describes all credentials used by the HRIS integration scripts and Oracle OIC flows. It covers where credentials are configured, how they are structured, and when they should be rotated.

**Actual credential values are NOT stored here.** All values are stored in:  
`<!-- Netwrix -->`

### Systems covered

| System | Purpose |
|---|---|
| Oracle HCM REST | Employee data, absence, time |
| SQL Server (D365) | Timesheet, capacity and financial reports staging |
| Kelio SOAP | Absence and time source data |
| Oracle OIC | Integration platform (service user) |
| Azure Automation | Runbook execution |
| Azure Storage | Blob and table storage |
| Active Directory (CORP) | On-premise AD write account |
| Active Directory (SOLVIAS.CH) | Legacy domain write account |
| DocuSign | Document signing extract |
| D365 Logic Apps | Dynamics 365 employee master data integration |
| SwissSalary BC | Payroll data via Business Central API |

### Who to contact

| Role | Contact |
|---|---|
| Credential owner / rotation | <!-- name --> |
| Oracle HCM admin | Hardy / Mastek
| Entra / Azure admin | Remo |
| AD admin | Remo |
| Kelio admin | Sabine - FR HR |
| DocuSign | Remo |
| SwissSalary support | Stefanie / SwissSalarySupport |

---

## 2. Credential Inventory

> **Key:** Basic = username/password · CC = OAuth2 Client Credentials · SAS - MS Shared Access Signature

### Azure Runbooks
|Name|Use
|----|---
|ReportDataLoader|Stage Data in D365 for Fin reporting
|CapacityDataGenerator|Stage Data in D365 for Capacity Planning
|ProjectDataLoader|Load D365 Project Lines into Oracle OTL
|TimesheetLoader|Load Oracle OTL Timesheet data to D365 staging

### OIC (Oracle Integration Cloud) Projects
|Name|Use
|----|---
|DocuSignProject|Send HR contracts for signature and upload signed doc to Oracle HR|
|SwissSalaryProject|Send HR data changes to SwissSalary|
|MSDynamicsProject|Send HR employee master data to D365|
|KelioSageProject|Load Kelio Time&Absence data into Oracle Absence/OTL|
|UtilitiesProject|Run Oracle HR Extracts, Retrieve Extract/BIP data for Azure RBs, Write Log|


### Inventory
| ID | Name | Type | Used By (Scripts) | Used By (OIC Projects) | Azure Credential /OIC Adapter Name | Entra App | Rotation | Notes |
|---|---|---|---|---|---|---|---|---|
| CR-01 | Oracle HCM REST | Basic | All Projects | ProjectDataLoader | `Prod_Oracle_Rest` / Oracle Prod SOAP Call BI, Oracle HCM PROD, Oracle HCM REST| — | 90 days | Service user in Oracle Prod|
| CR-02 | SQL Server D365 | Basic | ReportDataLoader, CapacityDataGenerator, ProjectDataLoader, TimesheetLoader   | — | `Prod_D365_SqlServer` | — | On change | Prod/Dev separate, Deloitte D365 team |
| CR-03 | Kelio SOAP | Basic | — | KelioSageProject | KelioAccountsTotal, KelioDailyScheduleAssignment, KelioAbsenceFile | — | On change | HR France |
| CR-04 | Azure Storage | Key | All runbooks | — | `StorageAccountKey` | — | Manual | Encrypted AA variable |
| CR-05 | AD Admin (CORP) | Basic | AD Sync | — | `ADADMIN` | — | 90 days | On-premise service account |
| CR-06 | AD Admin (SOLVIAS.CH) | Basic | AD Sync | — | `ADADMIN` | — | 90 days | On-premise service account |
| CR-07 | OIC Service User | Basic | ReportDataLoader, CapacityDataGenerator, TimesheetLoader  | All projects (platform auth) | `Prod_OIC` | — | 90 days | OIC internal service user |
| CR-08 | DocuSign | OAuth2 CC | DocSign Extract | DocuSign | `docusign-prod` | —  | 365 days | Secret in DocuSign App Setup |
| CR-09 | D365 Logic Apps | SAS | D365 Sync | D365 | `D365MasterDataLogicApp` | —  |none | fix |
| CR-10 | SwissSalary BC | OAuth2 CC | — | SwissSalary | — | `SwissSalary OAuth2.0 for HRIS` | 365 days | SP in SS tenant required |
| CR-11 | Oracle HCM SOAP | Basic | —  | DocuSignProject, SwissSalaryProject, MSDynamicsProject, UtilitiesProject | UcmGenericSoapService, Oracle HCM FlowActionService, Oracle Prod SOAP Call BI | —  |  90 days  | Service user in Oracle Prod (same as for REST) |
| CR-12 | <!-- name --> | <!-- type --> | <!-- scripts --> | <!-- projects --> | <!-- AA name --> | <!-- Entra app --> | <!-- cycle --> | <!-- notes --> |

---

## 3. Setup Locations

### 3.1 Oracle OIC — Connections

Each OIC project has its own connection (Adapter) instances. The same underlying credential may appear in multiple projects.

**To update a credential in OIC:**
> OIC → Projects → `[Project Name]` → Connections → `[Connection Name]` → Edit → update value → Test → Save

**Projects and their connections:**

| OIC Project | Connection Name | Credential ID |
|---|---|---|
|MSDynamicsProject	|D365MasterDataLogicApp	|CR-09
|MSDynamicsProject	|Oracle Prod SOAP Call BI	|CR-11
|MSDynamicsProject	|Oracle HCM PROD	|CR-01
|KelioSageProject	|Oracle HCM UAT REST	|CR-01
|KelioSageProject	|KelioAccountsTotal	|CR-03
|KelioSageProject	|KelioDailyScheduleAssignment	|CR-03
|KelioSageProject	|KelioAbsenceFile	|CR-03
|UtilitiesProject	|UcmGenericSoapService	|CR-11
|UtilitiesProject	|Oracle HCM FlowActionService	|CR-11
|UtilitiesProject	|Oracle Prod SOAP Call BI	|CR-11
|DocuSignProject	|Oracle HCM REST	|CR-01
|DocuSignProject	|UcmGenericSoapService	|CR-11
|DocuSignProject	|docusign-prod	|CR-08
|DocuSignProject	|DocuSignCallback	|CR-07
|SwissSalaryProject	|UcmGenericSoapService	|CR-11
|SwissSalaryProject	|Oracle HCM FlowActionService	|CR-11
|SwissSalaryProject	|SwissSalary	|CR-10

**Security policy by type:**

| Type | OIC Security Policy Setting |
|---|---|
| Basic Auth | Basic Authentication |
| OAuth2 CC | OAuth 2.0 Client Credentials |
| SAS | no additional settings |

---

### 3.2 Azure Automation — Credentials and Variables

**Credentials** (username + password pairs):
> Automation Account → Shared Resources → Credentials

Referenced in scripts as:
```powershell
Get-AutomationPSCredential -Name 'ADADMIN'
```

| AA Credential Name | Credential ID | Type |
|---|---|---|
| `Prod_Oracle_Rest` | CR-01 | Basic |
| `Prod_D365_SqlServer` | CR-02 | Basic |
| `ADADMIN` | CR-05 | Basic |
| `Prod_OIC` | CR-07 | Basic |



**Variables** (single values, can be encrypted):
> Automation Account → Shared Resources → Variables

| AA Variable Name | Credential ID | Encrypted | Purpose |
|---|---|---|---|
| `StorageAccountKey` | CR-04 | Yes | Azure blob/table access |
| `Environment` | — | No | PROD / TEST |
| `Prod_Oracle_BaseUrl` | — | No | Oracle REST base URL |
| `Prod_D365_SqlServerConnectionString` | CR-02 | No | SQL connection string (no password) |
| `Prod_OIC_DataRetrieval_BaseUrl` | CR-07 | No | OIC data retrieval endpoint URL
| `<!-- name -->` | <!-- ID --> | <!-- Yes/No --> | <!-- purpose --> |

---

### 3.3 Local Development — Server Credential Files

Credentials for local dev/test runs on the integration server are stored as encrypted PowerShell CliXML files.

**Location:** `C:\Integration\creds\`  
**Access:** Only readable by the Windows user account that created them

**Create a credential file:**
```powershell
Get-Credential | Export-CliXml -Path 'C:\Integration\AZMigration\creds\ORCLREST.xml'
```

**Read a credential file:**
```powershell
$cred = Import-CliXml -Path 'C:\Integration\AZMigration\creds\ORCLREST.xml'
```

**Files present on server:**

| File | Credential ID |
|---|---|
|`Prod_D365_SqlServer.xml`| CR-02 |
|`Prod_OIC.xml` | CR-07 |
|`Prod_Oracle_Rest.xml`| CR-01 |
|`ADAdmin.xml`| CR-05 |
| `<!-- name -->.clixml` | <!-- ID --> |

> These files are excluded from Git via `.gitignore`.

---

### 3.4 Microsoft Entra — App Registrations

OAuth2 app registrations used by integrations.

> Azure Portal → Entra ID → App Registrations

| App Name | Credential ID | Tenant | Permission Type | Scope |
|---|---|---|---|---|
| `docusign-prod` | CR-08 | DocuSign tenant | Application (OfferLetters) | DocuSign API |
| `SwissSalary OAuth2.0 for HRIS` | CR-10 | Our tenant (SP in SS tenant) | Application | BC API ReadWrite |

**To rotate a client secret:**
> App Registration → Certificates & Secrets → New Client Secret  
> ⚠️ Create new before deleting old — see Section 4.2

---

## 4. Rotation Procedures

### 4.1 Basic Auth — Password Change

When a password changes for a basic auth credential:

1. Get new password from external store or system owner
2. **Azure Automation:**
   - AA → Shared Resources → Credentials → `[name]` → Edit → update password
3. **OIC** — update every affected connection (see Section 3.1 table):
   - OIC → Connections → `[name]` → Edit → update password → Test → Save
4. **Local server:**
   ```powershell
   Get-Credential | Export-CliXml -Path 'C:\Integration\creds\[name].xml'
   ```
5. Store new value in external store
6. Test affected integrations

---

### 4.2 OAuth2 Client Secret Rotation (Entra)

> ⚠️ Never delete the old secret before the new one is confirmed working

1. **Entra** → App Registration → Certificates & Secrets → Add New Secret
2. Copy new secret value immediately — only shown once
3. Store in external store
4. **Azure Automation** → Variables → update encrypted variable
5. **OIC** → Connection → Edit → update client secret → Test → Save
6. Run a test integration end-to-end
7. **Delete old secret** in Entra only after confirming success

---

### 4.3 Azure Storage Key Rotation

1. **Azure Portal** → Storage Account → Access Keys → Rotate key2 (keep key1 active)
2. Copy new key2 value
3. **Azure Automation** → Variables → `StorageAccountKey` → Edit → update value
4. Test runbooks that use blob/table storage
5. Rotate key1 (same process)

---

## 5. External Store Reference

> Credential values are **never** stored in this document or in the Git repository.

| | |
|---|---|
| **Store** | <!-- Netrix --> |
| **Location** | <!-- URL or file path --> |
| **Folder structure** | `Integration / [Environment] / [System]` |
| **Access** | Request via <!-- IT helpdesk / team lead --> |

**Naming convention in store:**

```
[System]-[Environment]-[CredentialType]

Examples:
  Oracle-Prod-REST
  D365-Prod-SqlPassword
  SwissSalary-Prod-ClientSecret
  AD-Corp-ServiceAccount
```

---

## 6. Rotation Schedule

| Credential ID | Name | Last Rotated | Next Due | Rotation Cycle |
|---|---|---|---|---|
| CR-01 | Oracle HCM REST | <!-- date --> | 20-08-2026 | 90 days |
| CR-01a | Oracle HCM REST UAT | <!-- date --> | 31-08-2026| 90 days |
| CR-02 | SQL Server D365 | — | — | on change |
| CR-03 | Kelio SOAP | — | — | On change |
| CR-04 | Azure Storage Key | <!-- date --> | — | Manual |
| CR-05 | AD Admin CORP | <!-- date --> | <!-- date --> | 365 days days |
| CR-06 | AD Admin Legacy | — | — | same user as CR-05 |
| CR-07 | OIC Service User | 2026-05-26 | 2026-09-22 | 120 days |
| CR-08 | DocuSign Secret | 2026-03-?? | 2027--3-?? | 365 days |
| CR-09 | D365 Logic App Signature | —| — | on change |
| CR-10 | SwissSalary BC | <!-- date --> | 2028-06-16 | 720 days |
| CR-11 | Oracle HCM SOAP | — | — | same user as CR-01 |
---

## 7. Adding a New Credential

When a new integration requires a new credential:

1. Assign the next `CR-XX` ID from the inventory table
2. Add row to Section 2 inventory
3. Configure in all relevant locations (Section 3)
4. Store value in external store using naming convention
5. Add to rotation schedule (Section 6)
6. Update this document and commit to Git

---

*This document is version-controlled at `docs/credential-management.md` in the integration repository.*
