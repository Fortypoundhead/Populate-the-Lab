# Active Directory Lab Builder (PowerShell)

This repo contains three PowerShell scripts (plus name lists) that build and populate a realistic on-prem Active Directory lab environment. The goal is simple: go from “blank domain” to a domain that feels like a medium-sized company, so you can test GPOs, delegation, and access control without hand-creating hundreds of objects.

## What it creates

### 1) OU structure
`Create-LabADOUStructure.ps1` creates a clean OU hierarchy under a root OU named **MyCompany** (configurable). It separates Users, Computers, Groups, Service Accounts, and common sub-OUs used for workstation/server policy targeting.

### 2) Department security groups
`Create-LabUserSecurityGroups.ps1` creates department-based security groups (example: `Users-IT`, `Users-Finance`, etc.) suitable for access control and GPO filtering.

### 3) Populated lab objects
`Populate-LabUsers.ps1` generates realistic objects using the included name lists:

- Users with realistic attributes (department, title, office, phone, address)
- Random passwords (exported to CSV for lab convenience)
- Each user assigned to a random department group (matching the group script)
- Resource accounts:
  - conference rooms
  - shared accounts (front desk/helpdesk-style)
- Service accounts
- Pre-staged computer objects (device accounts) like:
  - `LAP-IT-014`
  - `DESK-FIN-003`
  - `KIOSK-CORP-002`

This makes GPO testing feel much more “end-to-end.”

## Files in this repo

- `Create-LabADOUStructure.ps1`
- `Create-LabUserSecurityGroups.ps1`
- `Populate-LabUsers.ps1`
- `names-first-female.txt`
- `names-first-male.txt`
- `names-surnames.txt`

## Requirements

- On-prem Active Directory domain (lab)
- Windows PowerShell 5.1 or PowerShell 7 (PowerShell 5.1 compatible)
- RSAT / ActiveDirectory module available (or run on a domain controller)
- Permissions to create OUs, groups, users, and computer accounts (Domain Admin in a lab is fine)

## Quick start

Run the scripts in order:

**1) Build OU structure**

`.\Create-LabADOUStructure.ps1`

**2) Create department security groups**

`.\Create-LabUserSecurityGroups.ps1`

**3) Populate the lab (example: big run)**

`.\Populate-LabUsers.ps1 -UserCount 500 -RoomCount 25 -SharedCount 10 -ServiceAccountCount 20 -DeviceCount 500`

## Name lists

User generation pulls random names from the provided text files (one entry per line):

- names-first-female.txt
- names-first-male.txt
- names-surnames.txt

You can replace these with your own lists if you want the lab to match a specific theme (regional names, fictional names, etc.). Keep the same format: one name per line.

## Notes on naming and collisions

User sAMAccountName is generated as first initial + last name (e.g., jsmith). If a collision occurs, the script appends a number (e.g., jsmith2, jsmith3)

Resource accounts and device objects are created with collision-safe naming as well, so reruns are generally safe.

## Lab-only caution

The population script exports a CSV that includes generated passwords for convenience. That is great for a lab, but don’t copy this pattern into a production environment.

## Suggested lab workflow

Build a few GPOs targeting:

- OU=Workstations,OU=Computers,OU=MyCompany,...
- department workstation sub-OUs (Finance, IT, etc.)
- department user groups (Users-Finance, Users-IT, …)

Join a few VMs to the domain and rename them to match pre-staged device names to simulate real workstation targeting.  Test loopback processing scenarios using user/device OU separation.

## License

Use whatever license fits your project (MIT is common for this type of utility). Add a LICENSE file if you want it explicit.

## Author / Credits

Built for lab and learning use. If you’re publishing this as part of a blog or toolkit, drop your preferred credit line here.
