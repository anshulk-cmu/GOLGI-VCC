# Execution Log: Phase 0 — Infrastructure Setup

> **Plan document:** [`PROJECT_PLAN.md`](PROJECT_PLAN.md)
> **Next phase:** [`execution_log_phase1.md`](execution_log_phase1.md)
> **Course:** CSL7510 — Cloud Computing
> **Students:** Anshul Kumar (M25AI2036), Neha Prasad (M25AI2056)
> **Programme:** M.Tech Artificial Intelligence, IIT Jodhpur
> **Started:** 2026-04-11

This document tracks the execution of Phase 0 — AWS Infrastructure Setup. Every command, output, resource ID, and reasoning is recorded here for reproducibility, debugging, and grading reference.

---

## Table of Contents

- [Phase 0 — AWS Infrastructure Setup](#phase-0--aws-infrastructure-setup)
  - [Step 0.1: AWS Account Preparation](#step-01-aws-account-preparation--completed-2026-04-11)
  - [Step 0.2: Install AWS CLI](#step-02-install-aws-cli--completed-2026-04-11)
  - [Step 0.3: Generate SSH Key Pair](#step-03-generate-ssh-key-pair--completed-2026-04-11)
  - [Steps 0.4–0.9: Network Setup](#steps-049-network-setup--completed-2026-04-11)
  - [Steps 0.10–0.11: EC2 Instance Provisioning](#step-01011-ec2-instance-provisioning--completed-2026-04-11)
  - [Steps 0.12–0.15: k3s Cluster Setup](#steps-01215-k3s-cluster-setup--completed-2026-04-11)
  - [Steps 0.16–0.17: OpenFaaS Deployment](#steps-01617-openfaas-deployment--completed-2026-04-11)
  - [Step 0.18: Python and Monitoring Tools on Workers](#step-018-install-python-and-monitoring-tools-on-worker-nodes--completed-2026-04-11)
  - [Step 0.19: Python and ML Packages on Master](#step-019-install-python-and-ml-packages-on-master-node--completed-2026-04-11)
  - [cgroup Version Verification](#cgroup-version-verification--completed-2026-04-11)
  - [Phase 0 Checkpoint](#phase-0-checkpoint--all-passed-2026-04-11)
- [Resource Reference Table](#resource-reference-table)

---

## Resource Reference Table

A quick-reference of all AWS resources created so far. Updated as new resources are provisioned.

| Resource | ID | Name/Details |
|---|---|---|
| AWS Account | `333650975919` | Personal account |
| IAM User | `AIDAU3LZF3SXVHHG433VD` | `golgi-admin` |
| Access Key | `AKIAU3LZF3SXT4GZR7EA` | CLI access for `golgi-admin` |
| SSH Key Pair | — | `golgi-key` → `C:\Users\worka\.ssh\golgi-key.pem` |
| VPC | `vpc-0613c37c5cde4ea3c` | `golgi-vpc` / `10.0.0.0/16` |
| Subnet | `subnet-059304ec96b5a1958` | `10.0.1.0/24` / `us-east-1a` |
| Internet Gateway | `igw-050cd44d34503b9ec` | Attached to `golgi-vpc` |
| Route Table | `rtb-072e903ac57d41747` | `0.0.0.0/0` → IGW |
| Route Table Assoc. | `rtbassoc-0a09cc952fc68e95d` | Links RTB ↔ Subnet |
| Security Group | `sg-06b976c1028e80262` | `golgi-sg` / 5 inbound rules |
| AMI | `ami-0ea87431b78a82070` | Amazon Linux 2023 (kernel 6.1, x86_64) |
| EC2: Master | `i-0485789851116b85e` | `golgi-master` / t3.medium / `10.0.1.131` / `44.212.35.8` |
| EC2: Worker-1 | `i-02c851cc663d17b3e` | `golgi-worker-1` / t3.xlarge / `10.0.1.110` / `54.173.219.56` |
| EC2: Worker-2 | `i-0fb0f2ac6384d779f` | `golgi-worker-2` / t3.xlarge / `10.0.1.10` / `44.206.236.146` |
| EC2: Worker-3 | `i-07c1c3c65c833a675` | `golgi-worker-3` / t3.xlarge / `10.0.1.94` / `174.129.77.19` |
| EC2: LoadGen | `i-07b31e765e0ff1b45` | `golgi-loadgen` / t3.medium / `10.0.1.142` / `44.211.68.203` |
| k3s Version | `v1.34.6+k3s1` | Kubernetes v1.34.6, containerd 2.2.2 |
| k3s Join Token | `K107e34f...acbde` | Stored at `/var/lib/rancher/k3s/server/node-token` on master |
| Helm | `v3.20.2` | Installed at `/usr/local/bin/helm` on master |
| OpenFaaS | Revision 1 | Deployed via Helm into `openfaas` namespace |
| OpenFaaS Gateway | `http://127.0.0.1:31112` | NodePort 31112, admin / `888c7417424edcbe2a7de236be0fa023` |
| faas-cli | `v0.18.8` | Installed at `/usr/local/bin/faas-cli` on master |
| Python | `3.9.25` | Pre-installed on all nodes (Amazon Linux 2023 base) |
| pip | `21.3.1` | Installed via `yum` on all nodes |
| perf | `6.1.166` | Installed on 3 workers for hardware perf counters |
| gcc | `11.5.0` | Installed on master + loadgen for C extension compilation |
| cgroup version | v2 (`cgroup2fs`) | Unified hierarchy at `/sys/fs/cgroup/` |

---

## Phase 0 — AWS Infrastructure Setup

**Goal of Phase 0:** Set up the foundational AWS infrastructure — account, CLI, networking, EC2 instances, Kubernetes cluster, and serverless platform — so that all subsequent phases (benchmark function deployment, latency measurement, degradation experiments, CFS analysis) have a working platform to run on.

**What gets built in this phase:**
1. An AWS account with a dedicated IAM user (Step 0.1)
2. AWS CLI configured on our local Windows machine (Step 0.2)
3. An SSH key pair for remote access to EC2 instances (Step 0.3)
4. A VPC with networking (subnet, internet gateway, route table, security group) (Steps 0.4–0.9)
5. Five EC2 instances (1 master, 3 workers, 1 load generator) (Steps 0.10–0.11)
6. A k3s Kubernetes cluster across all 4 cluster nodes (Steps 0.12–0.15)
7. OpenFaaS serverless framework deployed on the cluster (Steps 0.16–0.17)

**Estimated cost for Phase 0 resources (running):**
- 2× t3.medium (master + loadgen): 2 × $0.0416/hr = $0.0832/hr
- 3× t3.xlarge (workers): 3 × $0.1664/hr = $0.4992/hr
- Total: ~$0.58/hr = ~$14/day if left running 24 hours
- **Recommendation:** Stop instances when not working. Start them only during active development/testing.

---

#### Step 0.1: AWS Account Preparation — COMPLETED (2026-04-11)

**What we did:** Created a dedicated IAM user (`golgi-admin`) with scoped permissions for this project, rather than using the root account directly. This follows the AWS Well-Architected Framework's security pillar — specifically the principle of least privilege.

**Why not use the root account?**
The root account has unrestricted access to everything — billing, IAM, all services, account closure. Using it for day-to-day work is risky:
- A leaked root credential means **full account takeover** — an attacker could spin up hundreds of expensive GPU instances for crypto mining, delete all resources, or access billing information.
- Root cannot be restricted with IAM policies — it always has full access.
- AWS explicitly recommends: "Do not use the root user for everyday tasks."

An IAM user with only EC2/VPC permissions limits the blast radius. If `golgi-admin`'s credentials leak, an attacker can create EC2 instances but cannot access billing, create new IAM users, or delete the account.

**How we did it (via AWS Console):**

1. Logged into the AWS Console as root: `https://console.aws.amazon.com/`
2. Navigated to **IAM** > **Users** > **Create user**
3. Set username: `golgi-admin`
4. Selected "Provide user access to the AWS Management Console" (optional, for debugging)
5. Under Permissions, chose "Attach policies directly"
6. Searched and selected each policy (see table below)
7. Reviewed and clicked **Create user**
8. Navigated to the user's **Security credentials** tab
9. Under **Access keys**, clicked **Create access key**
10. Selected "Command Line Interface (CLI)" as the use case
11. Added description tag: `golgi-win-cli`
12. Downloaded the `.csv` file with the Access Key ID and Secret Access Key

**Account details:**
- AWS Account ID: `333650975919`
  - *This is a 12-digit unique identifier for the AWS account. It appears in ARNs and is used for cross-account access. It is not sensitive — it's visible in the console URL.*
- Console sign-in URL: `https://333650975919.signin.aws.amazon.com/console`
  - *This is the IAM user sign-in page (different from the root sign-in). Bookmarking this avoids needing to enter the account ID every time.*
- Root account: MFA enabled (hardware/software authenticator)

**IAM user created:**
- Username: `golgi-admin`
- ARN: `arn:aws:iam::333650975919:user/golgi-admin`
  - *ARN = Amazon Resource Name. This is the globally unique identifier for any AWS resource. Format: `arn:aws:service:region:account-id:resource-type/resource-id`. For IAM users, region is blank because IAM is a global service.*
- UserID: `AIDAU3LZF3SXVHHG433VD`
  - *This is an internal AWS identifier for the user. Different from the Access Key ID. You rarely need this directly, but it appears in API responses.*

**Permissions attached (4 policies):**

| Policy | Type | What It Allows | Why We Need It |
|---|---|---|---|
| `AmazonEC2FullAccess` | AWS managed | All EC2 actions: `ec2:*` | Launch/stop/terminate instances, create key pairs, manage AMIs, describe instances |
| `AmazonVPCFullAccess` | AWS managed | All VPC actions: `ec2:*Vpc*`, `ec2:*Subnet*`, `ec2:*SecurityGroup*`, etc. | Create VPC, subnets, security groups, route tables, internet gateways |
| `IAMReadOnlyAccess` | AWS managed | Read-only IAM: `iam:Get*`, `iam:List*` | View our own user details, verify policies are correct. Cannot create/delete users or policies. |
| `IAMUserChangePassword` | AWS managed | `iam:ChangePassword` for own user only | Auto-added by AWS when console access is enabled. Lets `golgi-admin` change its own console password. Cannot change other users' passwords. |

**Why these specific policies?**
- `AmazonEC2FullAccess` is broader than strictly necessary (it includes actions like modifying reserved instances, which we don't need). A production setup would use a custom policy with only the actions we need. For a course project, the managed policy is simpler and avoids the risk of missing a permission that blocks us later.
- `AmazonVPCFullAccess` is similarly broad. VPC resources (subnets, route tables, security groups) are tightly coupled to EC2, so we need both.
- We specifically **did not** attach `AdministratorAccess`, `IAMFullAccess`, or billing-related policies — this keeps the user scoped.

**MFA decision: Skipped on `golgi-admin`**

We decided to skip MFA (Multi-Factor Authentication) on the `golgi-admin` IAM user. Here is the reasoning:

- Root account already has MFA (the critical one — root compromise = full account takeover)
- `golgi-admin` has scoped permissions (EC2/VPC only, no billing, no IAM write)
- This is a short-lived project account that will be deleted after the course project ends
- Single user, single machine — no shared access risk, no team members
- The primary threat vector is the access key leaking (e.g., accidentally committed to GitHub). MFA on the IAM user **does not protect against programmatic key leaks** — if the access key is in a public repo, anyone can use it via the CLI regardless of whether MFA is enabled on the user. Only credential rotation and `.gitignore` discipline protect against this.
- MFA would add friction to every CLI session (requiring `aws sts get-session-token` with a TOTP code) without meaningful security benefit in this context.

**Access key created:**
- Access Key ID: `AKIAU3LZF3SXT4GZR7EA`
  - *The Access Key ID is like a username — it identifies which key is being used. It starts with `AKIA` for long-term IAM user keys (vs `ASIA` for temporary STS credentials). This value is not secret and appears in API logs.*
- Description tag: `golgi-win-cli`
  - *A human-readable label to remember what this key is for. Useful if you have multiple keys.*
- Status: Active
- Secret Access Key: downloaded as CSV, stored offline. Never committed to version control.
  - *The secret key is like a password — it proves you are the holder of the access key. AWS shows it exactly once at creation time. If lost, you must create a new key pair. It should never appear in code, logs, or version control.*
- The access key provides **programmatic (CLI/SDK) access**. It is the equivalent of a username+password for the AWS API. Every `aws` CLI command uses this key pair to sign the HTTP request (AWS Signature v4).

**Security precautions taken:**
- Added `*.pem`, `*.csv`, `.aws/`, `credentials` to `.gitignore` before first commit — prevents accidental exposure of credentials in the git repository
- Secret key stored only in `~/.aws/credentials` (managed by `aws configure`) — this is the standard, secure location that the CLI reads from automatically
- The `.csv` download is kept offline as a backup in case `~/.aws/credentials` is corrupted

**What could go wrong if the access key leaks?**
An attacker with the access key could:
- Launch expensive EC2 instances (e.g., p4d.24xlarge at $32/hr) for crypto mining
- Create resources in any region (not just us-east-1)
- Delete our VPC, instances, and security groups
- They could NOT: access billing, create new IAM users, close the account, or access services outside EC2/VPC (because `golgi-admin` only has EC2/VPC permissions)

**If you suspect a key leak:**
1. Go to IAM > Users > golgi-admin > Security credentials
2. Click Actions > Deactivate on the compromised key
3. Create a new access key
4. Run `aws configure` again with the new key
5. Check CloudTrail logs for unauthorized activity

---

#### Step 0.2: Install AWS CLI — COMPLETED (2026-04-11)

**What we did:** Installed the AWS CLI (Command Line Interface) version 2 on our Windows machine and configured it with the IAM user credentials from Step 0.1.

**Why the CLI instead of the AWS Console?**
- **Reproducibility:** Every command is recorded in this log. If we need to tear down and rebuild, we re-run the commands. Clicking through a web UI is not reproducible.
- **Speed:** Creating 5 EC2 instances takes 5 clicks each in the Console (25+ clicks with configuration). The CLI does it in 5 commands.
- **Scriptability:** We can chain commands, capture outputs into variables, and build automation scripts.
- **Auditability:** Every CLI command maps to an AWS API call logged in CloudTrail. This gives a complete audit trail of what was done and when.

**What is the AWS CLI?** It is a unified command-line tool that provides a consistent interface to all AWS services. Under the hood, it makes HTTPS requests to AWS API endpoints (e.g., `ec2.us-east-1.amazonaws.com`), signed with your access key using AWS Signature v4. The response (usually JSON) is parsed and displayed.

**Step 1: Download the installer**

```powershell
# PowerShell command to download the MSI installer
# -UseBasicParsing avoids depending on Internet Explorer components
Invoke-WebRequest -Uri 'https://awscli.amazonaws.com/AWSCLIV2.msi' `
  -OutFile 'C:\Users\worka\AWSCLIV2.msi' -UseBasicParsing
```
- Downloaded file: `C:\Users\worka\AWSCLIV2.msi` (47,620,096 bytes / ~45 MB)
- The MSI (Microsoft Installer) package contains the CLI binary, Python runtime (bundled — no system Python needed), and all AWS service definitions.

**Why download the MSI directly instead of using `pip install awscli`?**
- The MSI bundles its own Python, avoiding conflicts with any system Python installation.
- It automatically adds itself to the system PATH.
- It is the AWS-recommended installation method for Windows.
- `pip install awscli` installs CLI v1, which is the older version. CLI v2 has better performance, auto-completion, and new features like `aws sso login`.

**Step 2: Install with admin privileges**

```powershell
# Silent install (/qn = quiet, no UI) with elevation (Verb RunAs triggers UAC prompt)
Start-Process -FilePath 'msiexec.exe' `
  -ArgumentList '/i','C:\Users\worka\AWSCLIV2.msi','/qn' `
  -Verb RunAs -Wait
```

**Explanation of the command:**
- `Start-Process` — PowerShell cmdlet to launch a process
- `msiexec.exe` — Windows Installer engine, handles `.msi` packages
- `/i` — "install" mode (vs `/x` for uninstall, `/p` for patch)
- `/qn` — "quiet, no UI" — suppresses the install wizard, runs silently
- `-Verb RunAs` — triggers User Account Control (UAC) elevation prompt, giving admin privileges
- `-Wait` — blocks until the install completes before returning control

**Why admin privileges?** The MSI installs to `C:\Program Files\Amazon\AWSCLIV2\`, which is a protected system directory. Writing to `Program Files` requires administrator rights on Windows. A non-elevated install would fail with "Access denied."

**Result:**
- Install path: `C:\Program Files\Amazon\AWSCLIV2\`
- The installer adds this path to the system `PATH` environment variable, so `aws` is available from any terminal.

**Step 3: Verify installation**

```powershell
& 'C:\Program Files\Amazon\AWSCLIV2\aws.exe' --version
```
Output:
```
aws-cli/2.34.29 Python/3.14.3 Windows/11 exe/AMD64
```

**Reading the version string:**
- `aws-cli/2.34.29` — CLI version 2.34.29 (major version 2)
- `Python/3.14.3` — bundled Python interpreter version (not your system Python)
- `Windows/11` — detected operating system
- `exe/AMD64` — 64-bit executable for x86-64 architecture

**Note:** We used the full path (`C:\Program Files\Amazon\AWSCLIV2\aws.exe`) because we are running inside a bash shell (Git Bash via VS Code) where the Windows PATH update may not have taken effect yet. In a fresh PowerShell or CMD window, just `aws --version` would work.

**Step 4: Configure credentials and defaults**

```powershell
# Set the region — us-east-1 has the widest service availability and lowest latency for US
aws configure set region us-east-1

# Set output format — JSON is machine-parseable and works with --query filters
aws configure set output json

# Set credentials (access key ID and secret from Step 0.1)
aws configure set aws_access_key_id AKIAU3LZF3SXT4GZR7EA
aws configure set aws_secret_access_key <secret-from-csv>
```

**What `aws configure set` does:** Each command writes a key-value pair to a configuration file. Unlike `aws configure` (interactive, prompts for all 4 values), `aws configure set` is non-interactive and sets one value at a time — better for scripting and automation.

**Why `us-east-1`?**
- It is the oldest and most feature-complete AWS region (launched in 2006).
- It has the widest availability of instance types — important for `t3.xlarge` which we use for worker nodes.
- It has the most AMI (Amazon Machine Image) options.
- It generally has the lowest spot instance prices due to the largest capacity pool.
- Our project plan specifies `us-east-1` for all resources.
- If you are physically closer to another region (e.g., `ap-south-1` for India), latency to your instances will be higher, but this only affects SSH responsiveness, not the experiment itself (all cluster components run within the same region).

**Why JSON output?**
- JSON is machine-parseable — we can use the `--query` flag with JMESPath expressions to extract specific fields (e.g., `--query 'Vpc.VpcId'` to get just the VPC ID from a `create-vpc` response).
- Alternative formats: `text` (tab-separated, good for shell scripts), `table` (human-readable ASCII tables, nice for display but harder to parse), `yaml` (similar to JSON but with different syntax).
- JSON is the most versatile — it works with `--query`, can be piped to `jq` for complex transformations, and is the native format of AWS API responses.

**Where the config is stored:**

These commands create/update two files in the user's home directory:

| File | Contents | Example |
|---|---|---|
| `~/.aws/credentials` | Access Key ID + Secret Access Key | `[default]`<br>`aws_access_key_id = AKIA...`<br>`aws_secret_access_key = l2X4...` |
| `~/.aws/config` | Region + Output format | `[default]`<br>`region = us-east-1`<br>`output = json` |

On Windows, `~` is `C:\Users\worka\`, so the files are at:
- `C:\Users\worka\.aws\credentials`
- `C:\Users\worka\.aws\config`

The `[default]` section means these settings apply when no `--profile` flag is specified. You can have multiple profiles (e.g., `[profile dev]`, `[profile prod]`) for different AWS accounts or roles, but we only need the default profile for this project.

**Step 5: Verify identity**

```powershell
aws sts get-caller-identity
```
Output:
```json
{
    "UserId": "AIDAU3LZF3SXVHHG433VD",
    "Account": "333650975919",
    "Arn": "arn:aws:iam::333650975919:user/golgi-admin"
}
```

**What this command does:** `sts get-caller-identity` calls the AWS Security Token Service (STS) API to answer the question: "Who am I?" It returns the identity associated with the credentials in `~/.aws/credentials`.

**Why run this?** It is a sanity check that:
1. The CLI is installed correctly (the command runs without error)
2. The credentials are valid (AWS accepted them)
3. We are the correct user (ARN ends with `user/golgi-admin`, not root or another user)
4. We are in the correct account (`333650975919`)

**Reading the output:**
- `UserId: AIDAU3LZF3SXVHHG433VD` — internal AWS user ID (matches what we saw in IAM)
- `Account: 333650975919` — the 12-digit AWS account number
- `Arn: arn:aws:iam::333650975919:user/golgi-admin` — the full ARN confirming we are `golgi-admin` in account `333650975919`, not root (which would show `arn:aws:iam::333650975919:root`)

**Troubleshooting (if this step had failed):**
- `Unable to locate credentials` → `~/.aws/credentials` is missing or empty. Re-run `aws configure`.
- `InvalidClientTokenId` → the Access Key ID is wrong. Check for typos.
- `SignatureDoesNotMatch` → the Secret Access Key is wrong. Re-download the CSV or create a new key.
- `ExpiredToken` → you are using temporary STS credentials that have expired. Not applicable here since we use long-term IAM user keys.

---

#### Step 0.3: Generate SSH Key Pair — COMPLETED (2026-04-11)

**What we did:** Created an EC2 key pair named `golgi-key` using the AWS CLI. This generates an RSA 2048-bit key pair. AWS keeps the public key in its EC2 key pair store; we download and save the private key locally.

**Why do we need an SSH key pair?**
EC2 instances running Amazon Linux do not have password-based SSH by default. This is a deliberate security choice:
- Passwords can be brute-forced. SSH keys cannot (2048-bit RSA has ~2^112 bits of security).
- Passwords can be guessed or phished. SSH keys require possession of the private key file.
- Passwords are typed (and potentially keylogged). SSH keys are files that never leave disk.

The private key (`.pem` file) acts as your credential. When you run `ssh -i golgi-key.pem ec2-user@<ip>`, the SSH client proves to the server that you possess the private key corresponding to the public key installed on the instance, without ever sending the private key over the network (this is done via a cryptographic challenge-response protocol).

**Why a single key pair for all instances?**
We use one key pair (`golgi-key`) across all 5 instances. In a production environment, you might use separate keys per role or per team member. For a single-person course project, one key is simpler and sufficient.

**Command:**

```powershell
aws ec2 create-key-pair `
  --key-name golgi-key `
  --query 'KeyMaterial' `
  --output text > C:\Users\worka\.ssh\golgi-key.pem
```

**Explanation of each flag:**
- `ec2 create-key-pair` — calls the EC2 `CreateKeyPair` API action
- `--key-name golgi-key` — the name AWS stores the public key under. When we launch EC2 instances later, we pass `--key-name golgi-key` to tell AWS which public key to install in the instance's `~/.ssh/authorized_keys` file.
- `--query 'KeyMaterial'` — JMESPath expression that extracts only the private key PEM content from the full JSON response. Without this, the output would include metadata like the key fingerprint and key pair ID.
- `--output text` — outputs the extracted value as raw text. Without this, the PEM key would be wrapped in JSON quotes with escaped newlines (`"-----BEGIN RSA PRIVATE KEY-----\n..."`) which would not be a valid PEM file.
- `> C:\Users\worka\.ssh\golgi-key.pem` — redirects the private key content to a file in the `.ssh` directory (a conventional location for SSH keys).

**What the full (unfiltered) API response looks like:**
```json
{
    "KeyFingerprint": "ab:cd:ef:...",
    "KeyMaterial": "-----BEGIN RSA PRIVATE KEY-----\nMIIEpAIB...\n-----END RSA PRIVATE KEY-----",
    "KeyName": "golgi-key",
    "KeyPairId": "key-0abc123..."
}
```
The `--query 'KeyMaterial'` extracts just the PEM string, and `--output text` removes the JSON quotes.

**Result:**
- Key name in AWS: `golgi-key`
- Private key file: `C:\Users\worka\.ssh\golgi-key.pem` (1,706 bytes)
- Key registered in EC2 region `us-east-1`
- Key type: RSA 2048-bit (AWS default for `create-key-pair`)

**Critical warning:** AWS does **NOT** store the private key. The `CreateKeyPair` API returns it exactly once. If this file is lost or corrupted:
- You **cannot** download it again from AWS
- You **cannot** SSH into any instance that uses this key pair
- You would need to: create a new key pair, launch new instances with the new key, or use EC2 Instance Connect / SSM Session Manager as an alternative access method
- **Back up this file** to a secure location (e.g., encrypted USB drive or password manager)

**File permissions note:**
- On Linux/Mac, you would run `chmod 400 golgi-key.pem` to make the file readable only by the owner. SSH refuses to use a key file that is readable by others (it prints `Permissions for 'golgi-key.pem' are too open`).
- On Windows, file permissions work differently (NTFS ACLs). The Windows SSH client (`ssh.exe` bundled with Windows 10+) may or may not enforce strict permissions. If you get a permissions error when SSH-ing, right-click the file → Properties → Security → Advanced → disable inheritance → remove all users except your own account.

**How we will use this key (preview of Step 0.10+):**
```powershell
# SSH into an EC2 instance (example)
ssh -i C:\Users\worka\.ssh\golgi-key.pem ec2-user@<public-ip>

# The -i flag specifies the identity file (private key)
# ec2-user is the default username on Amazon Linux 2023
# <public-ip> will be the instance's public IP from Step 0.11
```

---

#### Steps 0.4–0.9: Network Setup — COMPLETED (2026-04-11)

**What we did:** Created a complete network infrastructure on AWS: a Virtual Private Cloud (VPC) with a subnet, internet gateway, route table, and security group. This forms the private network that all 5 EC2 instances will live in.

**Why do we need all this networking?**
EC2 instances cannot exist in a vacuum — they must be placed inside a VPC (Virtual Private Cloud). Think of the VPC as your own private data center in the cloud. The networking components serve these roles:

| Component | Physical Analogy | Purpose |
|---|---|---|
| VPC | Your private data center | Defines the IP address range and network boundary |
| Subnet | A rack or row in the data center | A subdivision of the VPC in a specific availability zone |
| Internet Gateway | The data center's uplink to the ISP | Allows traffic between the VPC and the public internet |
| Route Table | The router's forwarding table | Tells the VPC where to send packets based on destination |
| Security Group | A firewall at each server | Controls which ports and IPs can connect to instances |

**Why not use the default VPC?**
AWS creates a default VPC in each region with default subnets, route tables, and security groups. We could use it, but:
- The default VPC has permissive security group rules (SSH from `0.0.0.0/0` in some setups)
- It is shared with any other work you do in this account — cleaning up later is harder
- Creating our own VPC is a core cloud computing concept worth practicing
- Our own VPC gives us full control over the CIDR range, subnet design, and security rules

**Network topology diagram:**
```
Your Laptop (98.111.206.214)
    |
    | (Internet)
    |
[Internet Gateway: igw-050cd44d34503b9ec]
    |
[VPC: vpc-0613c37c5cde4ea3c / 10.0.0.0/16]
    |
[Route Table: rtb-072e903ac57d41747]
    |  0.0.0.0/0 → IGW (internet-bound traffic)
    |  10.0.0.0/16 → local (intra-VPC traffic)
    |
[Subnet: subnet-059304ec96b5a1958 / 10.0.1.0/24 / us-east-1a]
    |
    +-- [golgi-master]   10.0.1.x  (t3.medium)
    +-- [golgi-worker-1] 10.0.1.x  (t3.xlarge)
    +-- [golgi-worker-2] 10.0.1.x  (t3.xlarge)
    +-- [golgi-worker-3] 10.0.1.x  (t3.xlarge)
    +-- [golgi-loadgen]  10.0.1.x  (t3.medium)
    
[Security Group: sg-06b976c1028e80262 applied to all instances]
    Inbound: SSH(22), HTTP(8080), OpenFaaS(31112), NodePorts(30000-32767) from your IP
    Inbound: All traffic from 10.0.0.0/16 (inter-node)
    Outbound: All traffic (default)
```

---

**Step 0.4: Create VPC**

```powershell
aws ec2 create-vpc --cidr-block 10.0.0.0/16 --query 'Vpc.VpcId' --output text
```
Output: `vpc-0613c37c5cde4ea3c`

```powershell
aws ec2 create-tags --resources vpc-0613c37c5cde4ea3c --tags Key=Name,Value=golgi-vpc
```

**What is a VPC?**
A Virtual Private Cloud is a logically isolated section of the AWS cloud where you launch resources. It is defined by a CIDR (Classless Inter-Domain Routing) block — a range of private IP addresses that belong to your network. Instances inside the VPC get IPs from this range.

**Why `10.0.0.0/16`?**
- `10.0.0.0` is the starting IP address of the range.
- `/16` is the subnet mask, which means the first 16 bits are fixed (the `10.0` part) and the remaining 16 bits are variable. This gives us 2^16 = 65,536 possible IP addresses (10.0.0.0 through 10.0.255.255).
- `10.x.x.x` is one of three private IP ranges defined by RFC 1918 (the others are `172.16.x.x` and `192.168.x.x`). Private IPs are not routable on the public internet — they are for internal use only.
- 65,536 addresses is far more than the 5 we need, but `/16` is AWS's default and is a common choice. There is no cost to having unused IPs in a VPC.
- The `Name=golgi-vpc` tag is purely a human-readable label. It appears in the AWS Console and makes it easy to identify our VPC among other resources.

**What AWS creates automatically with a VPC:**
- A default route table (we create our own, so we ignore this one)
- A default Network ACL (allows all inbound/outbound — we use security groups for access control, so this is fine)
- A default DHCP option set (provides DNS resolution and domain name)

**Result:**
- VPC ID: `vpc-0613c37c5cde4ea3c`
- CIDR: `10.0.0.0/16`
- Name: `golgi-vpc`
- State: `available`

---

**Step 0.5: Create Subnet**

```powershell
aws ec2 create-subnet \
  --vpc-id vpc-0613c37c5cde4ea3c \
  --cidr-block 10.0.1.0/24 \
  --availability-zone us-east-1a \
  --query 'Subnet.SubnetId' --output text
```
Output: `subnet-059304ec96b5a1958`

**What is a subnet?**
A subnet is a subdivision of the VPC's IP range, placed in a specific Availability Zone. Every EC2 instance must be launched into a subnet. The subnet determines:
- Which IP range the instance gets its private IP from
- Which Availability Zone the instance physically runs in
- Whether the instance gets a public IP (based on the subnet's auto-assign setting)

**Why `10.0.1.0/24`?**
- This is a subset of our VPC's `10.0.0.0/16` range.
- `/24` means the first 24 bits are fixed (`10.0.1`) and 8 bits are variable, giving 2^8 = 256 IP addresses (10.0.1.0 through 10.0.1.255).
- AWS reserves 5 IPs in every subnet: `.0` (network), `.1` (VPC router), `.2` (DNS), `.3` (reserved), `.255` (broadcast). So we actually get 251 usable IPs — still plenty for 5 instances.
- We use `10.0.1.0/24` (not `10.0.0.0/24`) by convention — leaving `10.0.0.0/24` available for a future public subnet if needed.

**Why a single subnet?**
Our experimental design calls for all nodes in one subnet for simplicity. In a production setup, you would typically have:
- A public subnet (for load balancers and bastion hosts)
- A private subnet (for application servers and databases)
- Subnets in multiple AZs (for high availability)

For a course project, one subnet is sufficient. All our nodes need to communicate with each other and be accessible from our laptop.

**Why `us-east-1a`?**
- Availability Zones (AZs) are physically separate data centers within a region. `us-east-1` has 6 AZs (a through f).
- Keeping all nodes in the same AZ eliminates cross-AZ network latency (~0.5-1ms round-trip), which matters for:
  - The benchmark scripts invoking functions and collecting latency data
  - The load generator sending requests to function endpoints
  - k3s control plane communicating with kubelets on worker nodes
- Cross-AZ data transfer costs $0.01/GB in each direction. Staying in one AZ avoids this entirely.
- The downside is no AZ-level fault tolerance — if `us-east-1a` has an outage, all our instances go down. This is acceptable for a course project.

**Result:**
- Subnet ID: `subnet-059304ec96b5a1958`
- CIDR: `10.0.1.0/24` (251 usable IPs)
- AZ: `us-east-1a`
- VPC: `vpc-0613c37c5cde4ea3c`

---

**Step 0.6: Create and Attach Internet Gateway**

```powershell
# Create the gateway
aws ec2 create-internet-gateway --query 'InternetGateway.InternetGatewayId' --output text
```
Output: `igw-050cd44d34503b9ec`

```powershell
# Attach it to our VPC
aws ec2 attach-internet-gateway \
  --internet-gateway-id igw-050cd44d34503b9ec \
  --vpc-id vpc-0613c37c5cde4ea3c
```

**What is an Internet Gateway?**
An Internet Gateway (IGW) is a horizontally scaled, redundant, AWS-managed component that connects a VPC to the public internet. It serves two purposes:
1. **Outbound:** Allows instances with public IPs to send traffic to the internet (e.g., `yum install`, `curl`, `docker pull`)
2. **Inbound:** Allows traffic from the internet to reach instances with public IPs (e.g., SSH from your laptop, HTTP requests from the load generator)

**Why is it a separate component?**
A VPC is isolated by default — this is a security feature. You explicitly opt into internet access by creating and attaching an IGW. VPCs without an IGW are "private" — useful for databases and internal services that should never be reachable from the internet.

**How does the IGW work?**
The IGW performs Network Address Translation (NAT) for instances with public IPs:
- **Outbound:** When an instance (`10.0.1.x`) sends a packet to the internet, the IGW replaces the source IP with the instance's public IP. The remote server sees the public IP and responds to it.
- **Inbound:** When a packet arrives for an instance's public IP, the IGW translates the destination to the instance's private IP and forwards it into the VPC.

**Why two commands (create + attach)?**
The IGW is created as a standalone resource and then attached to a specific VPC. This is because:
- An IGW can only be attached to one VPC at a time
- Detaching it instantly cuts internet access (useful for emergency lockdown)
- The lifecycle is independent — you can detach without deleting

**Result:**
- IGW ID: `igw-050cd44d34503b9ec`
- Attached to VPC: `vpc-0613c37c5cde4ea3c`
- State: `attached`

---

**Step 0.7: Create Route Table and Configure Routes**

```powershell
# Create route table
aws ec2 create-route-table \
  --vpc-id vpc-0613c37c5cde4ea3c \
  --query 'RouteTable.RouteTableId' --output text
```
Output: `rtb-072e903ac57d41747`

```powershell
# Add default route: all non-local traffic goes to the internet gateway
aws ec2 create-route \
  --route-table-id rtb-072e903ac57d41747 \
  --destination-cidr-block 0.0.0.0/0 \
  --gateway-id igw-050cd44d34503b9ec
```
Output: `{ "Return": true }`

```powershell
# Associate route table with our subnet
aws ec2 associate-route-table \
  --route-table-id rtb-072e903ac57d41747 \
  --subnet-id subnet-059304ec96b5a1958
```
Output:
```json
{
    "AssociationId": "rtbassoc-0a09cc952fc68e95d",
    "AssociationState": { "State": "associated" }
}
```

**What is a route table?**
A route table contains a set of rules (routes) that determine where network traffic is directed. When an instance sends a packet, the VPC checks the route table associated with the instance's subnet to decide where to send it.

**How routing works — the two routes in our table:**

| Destination | Target | Meaning | Added by |
|---|---|---|---|
| `10.0.0.0/16` | `local` | Traffic for any IP in the VPC stays within the VPC | AWS (automatic, cannot be removed) |
| `0.0.0.0/0` | `igw-050cd44d34503b9ec` | All other traffic goes to the Internet Gateway | Us (Step 0.7) |

When an instance sends a packet to `10.0.1.15`, the VPC matches it against `10.0.0.0/16` → `local` and delivers it directly within the VPC (no IGW involved). When an instance sends a packet to `8.8.8.8` (Google DNS), no local route matches, so it falls through to `0.0.0.0/0` → IGW, which sends it to the internet.

**Why associate the route table with the subnet?**
A route table does nothing on its own — it must be associated with a subnet. All instances in that subnet then use its routes. Each subnet can have exactly one route table association (but one route table can serve multiple subnets).

**Why create our own route table instead of using the VPC's default?**
The default route table created with the VPC only has the `local` route (no internet access). We could add the IGW route to it, but creating a separate route table is cleaner — if we ever add a private subnet, we can give it the default (no-internet) route table while our public subnet keeps the internet route.

**Result:**
- Route Table ID: `rtb-072e903ac57d41747`
- Routes: `10.0.0.0/16` → local, `0.0.0.0/0` → `igw-050cd44d34503b9ec`
- Association ID: `rtbassoc-0a09cc952fc68e95d`
- Associated subnet: `subnet-059304ec96b5a1958`

---

**Step 0.8: Enable Auto-Assign Public IP**

```powershell
aws ec2 modify-subnet-attribute \
  --subnet-id subnet-059304ec96b5a1958 \
  --map-public-ip-on-launch
```

**What this does:** Configures the subnet so that every EC2 instance launched in it automatically receives a public IPv4 address in addition to its private IP.

**Why do instances need public IPs?**
- **SSH access:** We need to connect from our laptop (`98.111.206.214`) to each instance. Our laptop is on the public internet; instances are in a private VPC. The public IP is the bridge.
- **Internet access (outbound):** While instances can reach the internet through the IGW using only a private IP (via a NAT Gateway), a NAT Gateway costs $0.045/hr + $0.045/GB processed. Auto-assigning public IPs is free.
- **Load testing:** The load generator instance sends HTTP requests to the master node's public IP.

**What happens without this setting?**
Instances get only a private IP (e.g., `10.0.1.27`). To reach them, you would need:
- An Elastic IP ($0.005/hr when not attached) manually assigned to each instance, OR
- A NAT Gateway ($0.045/hr) for outbound internet access, OR
- A bastion/jump host in a public subnet, and SSH through it to private instances
All of these add cost and complexity. Auto-assigning public IPs is the simplest approach for a development/project cluster.

**Important caveat:** Public IPs assigned this way are ephemeral — they change if you stop and restart the instance. If you need a fixed IP, use an Elastic IP. For our project, ephemeral IPs are fine because we record the current IPs in Step 0.11 and update them if instances are restarted.

---

**Step 0.9: Create Security Group and Add Inbound Rules**

```powershell
# Create the security group
aws ec2 create-security-group \
  --group-name golgi-sg \
  --description "Golgi cluster security group" \
  --vpc-id vpc-0613c37c5cde4ea3c \
  --query 'GroupId' --output text
```
Output: `sg-06b976c1028e80262`

**What is a security group?**
A security group is a stateful virtual firewall that controls inbound and outbound traffic at the **instance level** (not the subnet level — that's a Network ACL). Key properties:
- **Default deny inbound:** All incoming traffic is blocked unless a rule explicitly allows it.
- **Default allow outbound:** All outgoing traffic is allowed (instances can reach the internet, package repos, etc.).
- **Stateful:** If you allow inbound traffic on port 22, the return traffic (SSH responses) is automatically allowed. You do not need a separate outbound rule for responses.
- **Applied per-instance:** You can assign different security groups to different instances. We use the same group for all 5 instances for simplicity.

**How security groups differ from traditional firewalls:**
- No "deny" rules — you can only allow, not explicitly block. To block traffic, you simply don't add an allow rule.
- No ordering — rules are evaluated as a set, not sequentially. If any rule allows the traffic, it is allowed.
- Instance-level, not subnet-level — Network ACLs (NACLs) operate at the subnet level and are stateless (you need separate inbound and outbound rules). We use security groups because they are simpler and sufficient.

**Our public IP detection:**
```powershell
(Invoke-WebRequest -Uri 'https://checkip.amazonaws.com' -UseBasicParsing).Content.Trim()
```
Output: `98.111.206.214`

This calls an AWS-hosted service that returns your public IP address (the IP that AWS sees when you connect). We use this to restrict security group rules to only our IP.

**Why restrict by IP (`98.111.206.214/32`)?**
- `/32` = a single IP address (32 bits of the 32-bit IPv4 address are fixed = exactly one IP).
- Opening ports to `0.0.0.0/0` (the entire internet) would allow anyone to probe your instances. Port 22 (SSH) is one of the most commonly scanned ports — automated bots continuously try default credentials.
- By restricting to our IP, the security group drops packets from any other source IP before they even reach the instance.

**ISP IP change warning:** Residential internet connections often have dynamic IPs that change periodically (every few hours to days). If your IP changes:
- You will be unable to SSH into instances (connection timeout)
- Fix: find your new IP, add it to the security group, optionally remove the old IP
```powershell
# Find new IP
curl https://checkip.amazonaws.com

# Add new IP
aws ec2 authorize-security-group-ingress --group-id sg-06b976c1028e80262 --protocol tcp --port 22 --cidr <new-ip>/32

# Remove old IP (optional, for hygiene)
aws ec2 revoke-security-group-ingress --group-id sg-06b976c1028e80262 --protocol tcp --port 22 --cidr 98.111.206.214/32
```

---

**Rule 1: Allow SSH (port 22) from our IP**

```powershell
aws ec2 authorize-security-group-ingress \
  --group-id sg-06b976c1028e80262 \
  --protocol tcp --port 22 \
  --cidr 98.111.206.214/32
```
- Rule ID: `sgr-0d73120ea74fd47ae`
- **Protocol:** TCP (SSH runs over TCP)
- **Port:** 22 (the standard SSH port, defined by IANA)
- **Source:** `98.111.206.214/32` (our laptop only)
- **Why:** SSH is the primary way we interact with instances — installing software, running k3s commands, debugging, viewing logs. Every instance in the cluster needs SSH access.

---

**Rule 2: Allow all traffic within the VPC (10.0.0.0/16)**

```powershell
aws ec2 authorize-security-group-ingress \
  --group-id sg-06b976c1028e80262 \
  --protocol all \
  --cidr 10.0.0.0/16
```
- Rule ID: `sgr-01ecb81eb0f8c1dbb`
- **Protocol:** All (-1, which means TCP, UDP, and ICMP)
- **Port:** All (implied by `--protocol all`)
- **Source:** `10.0.0.0/16` (any IP in our VPC)
- **Why:** The 5 instances need unrestricted communication with each other on many ports:

| Port | Protocol | Used By | Purpose |
|---|---|---|---|
| 6443 | TCP | k3s API server | kubectl commands, node registration |
| 10250 | TCP | kubelet | Pod lifecycle management |
| 8472 | UDP | Flannel/VXLAN | Pod-to-pod networking overlay |
| 2379-2380 | TCP | etcd (embedded in k3s) | Cluster state storage |
| 8080 | TCP | OpenFaaS gateway | Function invocation |
| 5000 | TCP | Analysis scripts (Flask) | Data collection API |
| 9090 | TCP | Prometheus | Metrics scraping |
| Various | TCP | OpenFaaS watchdogs | Function lifecycle management |

Rather than listing every port individually (error-prone and fragile), we allow all traffic from the VPC CIDR. This is safe because the VPC is isolated — only our 5 instances are in it, and external traffic is filtered by the other rules.

---

**Rule 3: Allow HTTP on port 8080 from our IP**

```powershell
aws ec2 authorize-security-group-ingress \
  --group-id sg-06b976c1028e80262 \
  --protocol tcp --port 8080 \
  --cidr 98.111.206.214/32
```
- Rule ID: `sgr-0a10400d7071c047d`
- **Why:** The OpenFaaS gateway exposes HTTP services on port 8080. During development, we want to:
  - Test function invocations from our laptop: `curl http://<master-ip>:8080/function/my-function`
  - Access the OpenFaaS dashboard (web UI)
  - Monitor request routing in real-time

---

**Rule 4: Allow OpenFaaS gateway on port 31112 from our IP**

```powershell
aws ec2 authorize-security-group-ingress \
  --group-id sg-06b976c1028e80262 \
  --protocol tcp --port 31112 \
  --cidr 98.111.206.214/32
```
- Rule ID: `sgr-0e094855d57d95a23`
- **Why:** OpenFaaS is deployed as a Kubernetes service, exposed via a NodePort on 31112. A NodePort maps a port on every cluster node's IP to the service inside the cluster. So `http://<any-node-ip>:31112` reaches the OpenFaaS gateway, regardless of which node it is running on. We use this to:
  - Deploy functions via `faas-cli` or the REST API
  - Check function status and replicas
  - Access the OpenFaaS web UI for monitoring

---

**Rule 5: Allow Kubernetes NodePort range (30000–32767) from our IP**

```powershell
aws ec2 authorize-security-group-ingress \
  --group-id sg-06b976c1028e80262 \
  --protocol tcp --port 30000-32767 \
  --cidr 98.111.206.214/32
```
- Rule ID: `sgr-091113b47567aa920`
- **Why:** Kubernetes assigns NodePort services a port in the 30000–32767 range by default. In addition to OpenFaaS on 31112, we may expose other services as NodePorts during development:
  - Data collection or analysis endpoints (if needed)
  - Debug endpoints for experiment monitoring
  - Prometheus or Grafana (if added for monitoring)
  Opening the full range avoids coming back to add rules later.

---

**Security Group Summary:**

| Rule ID | Port(s) | Protocol | Source | Purpose |
|---|---|---|---|---|
| `sgr-0d73120ea74fd47ae` | 22 | TCP | `98.111.206.214/32` | SSH remote login |
| `sgr-01ecb81eb0f8c1dbb` | All | All | `10.0.0.0/16` | Inter-node cluster communication |
| `sgr-0a10400d7071c047d` | 8080 | TCP | `98.111.206.214/32` | OpenFaaS HTTP |
| `sgr-0e094855d57d95a23` | 31112 | TCP | `98.111.206.214/32` | OpenFaaS gateway NodePort |
| `sgr-091113b47567aa920` | 30000–32767 | TCP | `98.111.206.214/32` | K8s NodePort services |
| *(default)* | All | All | `0.0.0.0/0` | Outbound (all egress allowed) |

**What is NOT allowed (denied by default):**
- Any inbound traffic from IPs other than `98.111.206.214` or `10.0.0.0/16`
- Any inbound traffic on ports not listed above (e.g., port 3306/MySQL, port 443/HTTPS)
- This means our instances are invisible to the rest of the internet except on the specific ports we opened, and only from our IP

---

#### Steps 0.10–0.11: EC2 Instance Provisioning — COMPLETED (2026-04-11)

**What we did:** Launched 5 EC2 (Elastic Compute Cloud) instances into our VPC — the virtual machines that form our experiment cluster. These are the actual computers (running in AWS data centers) where all software will be installed and experiments will run.

**Why 5 instances?**
Our experimental setup has distinct roles that should run on separate machines to ensure clean measurements:

| Role | Why It Needs Its Own Machine |
|---|---|
| **Master** | Runs the Kubernetes control plane (k3s server), which manages scheduling, service discovery, and cluster state. Also hosts the OpenFaaS gateway. Separating the control plane from workers prevents control plane overhead from affecting function execution latency measurements. |
| **Workers (×3)** | Run the actual serverless function containers — both OC (overcommitted) and Non-OC (full-resource) instances. Three workers are needed to demonstrate collocation interference: when multiple functions share a node, they compete for CPU, memory, and cache. The paper uses 7 workers; we use 3 as a cost-conscious minimum that still shows the effect. |
| **Load Generator** | Generates HTTP requests to benchmark function latency under various conditions. This must be on a separate machine so that the load generation itself does not consume CPU/memory on the cluster nodes, which would skew the latency measurements. If the load generator ran on a worker node, its CPU usage would appear in the cgroup metrics and contaminate our results. |

**Why these specific instance types?**

**t3.medium (master + loadgen) — 2 vCPU, 4 GB RAM, $0.0416/hr:**
- The master runs k3s server + etcd + OpenFaaS gateway. These are lightweight services — k3s server uses ~500 MB RAM and minimal CPU at our scale (5 nodes, ~20 pods). 4 GB is plenty.
- The load generator runs Locust, which is a Python-based HTTP load testing tool. At our target load (~100 RPS), Locust uses ~200-500 MB RAM and 1 vCPU. 2 vCPUs give headroom.
- t3.medium is the cheapest instance type that has enough RAM for k3s (t3.micro with 1 GB would cause OOM kills under load).

**t3.xlarge (workers) — 4 vCPU, 16 GB RAM, $0.1664/hr:**
- Each worker hosts multiple function containers simultaneously. Our experiment deploys 3 functions, each in both OC and Non-OC variants, with potentially multiple replicas. That's 6+ containers per worker.
- Non-OC containers get full resources (e.g., 512 MB each). OC containers get reduced resources (e.g., ~200 MB each, calculated by the overcommitment formula `0.3 * claimed + 0.7 * actual`).
- With 16 GB RAM and ~2 GB for the OS/k3s/kubelet, we have ~14 GB for function containers — enough for ~20-30 containers per worker.
- 4 vCPUs allow us to observe CPU contention when multiple containers compete for CPU time — this is the core phenomenon that drives overcommitment-induced latency degradation.
- The paper uses c5.9xlarge (36 vCPU, 72 GB) which costs $1.53/hr. t3.xlarge is 10x cheaper while still demonstrating the same principles at a smaller scale.

**Why t3 (burstable) instead of c5/m5 (fixed performance)?**
- t3 instances use a credit-based CPU model: they earn credits when idle and spend them when bursting above baseline. The baseline for t3.xlarge is 40% of 4 vCPUs = 1.6 vCPUs sustained.
- For our workload, functions execute in short bursts (100-500ms per request) with idle time between requests. The burstable model is perfect — we burst during function execution and earn credits during idle periods.
- t3.xlarge costs $0.1664/hr vs m5.xlarge at $0.192/hr (15% cheaper) and c5.xlarge at $0.17/hr (comparable). The savings add up over multiple days of experimentation.
- **Risk:** If we sustain high load for extended periods (hours), we may exhaust CPU credits and get throttled to baseline. At our target of ~100 RPS (not 5000+ like the paper), this is unlikely. If it happens, we can enable "unlimited" mode (`aws ec2 modify-instance-credit-specification`) which charges ~$0.05/vCPU-hour for sustained burst.

**What is an AMI (Amazon Machine Image)?**
An AMI is a pre-built disk image that contains the operating system, pre-installed software, and configuration. When you launch an EC2 instance, the AMI is copied to the instance's root volume (EBS disk). Think of it as a "template" or "ISO image" for virtual machines.

**How we chose the AMI:**

```powershell
# Find the latest Amazon Linux 2023 AMI in us-east-1
aws ec2 describe-images \
  --owners amazon \
  --filters 'Name=name,Values=al2023-ami-2023*-x86_64' \
            'Name=state,Values=available' \
  --query 'Images | sort_by(@, &CreationDate) | [-1].[ImageId,Name]' \
  --output text
```
Output: `ami-0ea87431b78a82070  al2023-ami-2023.11.20260406.2-kernel-6.1-x86_64`

**Explanation of the command:**
- `--owners amazon` — only show AMIs published by Amazon (not community or marketplace AMIs, which could be tampered with)
- `--filters 'Name=name,Values=al2023-ami-2023*-x86_64'` — filter by name pattern: Amazon Linux 2023, x86_64 architecture. The `*` wildcard matches any version/date suffix.
- `'Name=state,Values=available'` — only show AMIs that are ready to use (not deprecated or pending)
- `--query 'Images | sort_by(@, &CreationDate) | [-1].[ImageId,Name]'` — JMESPath expression that:
  - Takes all matching images
  - Sorts them by creation date (oldest first)
  - `[-1]` picks the last one (newest)
  - `.[ImageId,Name]` extracts just the ID and name
- This gives us the latest stable Amazon Linux 2023 AMI, ensuring we have the newest security patches.

**Why Amazon Linux 2023 (AL2023)?**
- It is AWS's own Linux distribution, optimized for EC2 (fast boot, pre-installed AWS tools, kernel tuned for cloud workloads).
- It uses kernel 6.1 LTS, which has good cgroup v2 support — essential for our metric collector that reads container resource usage from cgroup files.
- It comes with `dnf` (package manager), `systemd`, and `cloud-init` pre-installed.
- It has long-term support and regular security updates from Amazon.
- Alternative choices and why we didn't use them:
  - Ubuntu 22.04: Also good, but Amazon Linux has tighter EC2 integration and faster boot times.
  - Debian: Less common on EC2, fewer pre-installed AWS tools.
  - CentOS Stream: Red Hat ecosystem, similar to AL2023 but with less AWS-specific optimization.
  - Windows Server: Not suitable — k3s, OpenFaaS, and all our experiment tooling are Linux-based.

**AMI details:**
- AMI ID: `ami-0ea87431b78a82070`
- Name: `al2023-ami-2023.11.20260406.2-kernel-6.1-x86_64`
- Kernel: `6.1.166-197.305.amzn2023.x86_64` (confirmed via SSH after launch)
- Architecture: `x86_64` (64-bit Intel/AMD)
- Root device: EBS (gp3, 8 GB default — expandable if needed)
- Default user: `ec2-user` (used for SSH login)

---

**Launching the instances:**

We launched each instance with `aws ec2 run-instances`. Here is the command structure and what each flag does:

```powershell
aws ec2 run-instances \
  --image-id ami-0ea87431b78a82070 \        # Which OS to install (Amazon Linux 2023)
  --instance-type t3.medium \                # How much CPU/RAM (2 vCPU, 4 GB for master)
  --key-name golgi-key \                     # Which SSH key to install for remote access
  --security-group-ids sg-06b976c1028e80262 \ # Which firewall rules to apply
  --subnet-id subnet-059304ec96b5a1958 \     # Which subnet (and therefore VPC/AZ) to place it in
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=golgi-master}]' \  # Human-readable name
  --query 'Instances[0].InstanceId' \        # Extract just the instance ID from the response
  --output text                               # Output as plain text (not JSON)
```

**What happens when you run this command:**
1. AWS receives the API call and validates your permissions (does `golgi-admin` have `ec2:RunInstances`? Yes, via `AmazonEC2FullAccess`).
2. AWS selects a physical host server in `us-east-1a` with enough capacity for a t3.medium (or t3.xlarge).
3. The AMI is copied to a new EBS (Elastic Block Store) volume — this becomes the instance's root disk (8 GB gp3 SSD).
4. A virtual machine is created on the host with the specified CPU/RAM allocation.
5. The VM boots the OS from the EBS volume.
6. `cloud-init` runs on first boot: sets the hostname, installs the SSH public key from `golgi-key` into `/home/ec2-user/.ssh/authorized_keys`, configures networking.
7. The instance gets a private IP from the subnet's CIDR range (assigned by DHCP) and a public IP (because we enabled auto-assign in Step 0.8).
8. The security group `golgi-sg` is applied as a virtual firewall.
9. The instance state transitions: `pending` → `running` (usually takes 30-60 seconds).

**Instance 1: Master node**

```powershell
aws ec2 run-instances \
  --image-id ami-0ea87431b78a82070 \
  --instance-type t3.medium \
  --key-name golgi-key \
  --security-group-ids sg-06b976c1028e80262 \
  --subnet-id subnet-059304ec96b5a1958 \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=golgi-master}]' \
  --query 'Instances[0].InstanceId' --output text
```
Output: `i-0485789851116b85e`

- Role: k3s control plane, OpenFaaS gateway
- Instance type: t3.medium (2 vCPU, 4 GB RAM)
- This is the brain of the cluster — it runs the Kubernetes API server that all other nodes register with, and the OpenFaaS gateway through which all function invocations are routed.

**Instance 2: Worker node 1**

```powershell
aws ec2 run-instances \
  --image-id ami-0ea87431b78a82070 \
  --instance-type t3.xlarge \
  --key-name golgi-key \
  --security-group-ids sg-06b976c1028e80262 \
  --subnet-id subnet-059304ec96b5a1958 \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=golgi-worker-1}]' \
  --query 'Instances[0].InstanceId' --output text
```
Output: `i-02c851cc663d17b3e`

**Instance 3: Worker node 2**

```powershell
aws ec2 run-instances \
  --image-id ami-0ea87431b78a82070 \
  --instance-type t3.xlarge \
  --key-name golgi-key \
  --security-group-ids sg-06b976c1028e80262 \
  --subnet-id subnet-059304ec96b5a1958 \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=golgi-worker-2}]' \
  --query 'Instances[0].InstanceId' --output text
```
Output: `i-0fb0f2ac6384d779f`

**Instance 4: Worker node 3**

```powershell
aws ec2 run-instances \
  --image-id ami-0ea87431b78a82070 \
  --instance-type t3.xlarge \
  --key-name golgi-key \
  --security-group-ids sg-06b976c1028e80262 \
  --subnet-id subnet-059304ec96b5a1958 \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=golgi-worker-3}]' \
  --query 'Instances[0].InstanceId' --output text
```
Output: `i-07c1c3c65c833a675`

- Workers 1–3 are identical in configuration. They all run as k3s agents (worker nodes) and host function containers. Having 3 workers allows the Kubernetes scheduler to distribute pods across nodes, creating the collocation scenarios where we measure contention effects under overcommitment.

**Instance 5: Load generator**

```powershell
aws ec2 run-instances \
  --image-id ami-0ea87431b78a82070 \
  --instance-type t3.medium \
  --key-name golgi-key \
  --security-group-ids sg-06b976c1028e80262 \
  --subnet-id subnet-059304ec96b5a1958 \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=golgi-loadgen}]' \
  --query 'Instances[0].InstanceId' --output text
```
Output: `i-07b31e765e0ff1b45`

- This machine is intentionally outside the k3s cluster. It runs load testing tools that generate HTTP requests to the OpenFaaS gateway on the master node. Keeping it separate ensures load generation does not interfere with the cluster's CPU/memory measurements.

---

**Step 0.11: Record and verify IP addresses**

After all instances were launched, we waited for them to reach the `running` state and then retrieved their IP addresses:

```powershell
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=golgi-*" \
  --query 'Reservations[].Instances[].{
    Name:Tags[?Key==`Name`].Value|[0],
    InstanceId:InstanceId,
    Type:InstanceType,
    PublicIP:PublicIpAddress,
    PrivateIP:PrivateIpAddress,
    State:State.Name
  }' --output table
```

**Explanation of the command:**
- `--filters "Name=tag:Name,Values=golgi-*"` — only show instances with a `Name` tag starting with `golgi-`. This filters out any other instances in the account.
- `--query '...'` — JMESPath expression that reshapes the response into a clean table with only the fields we need.
- `Reservations[].Instances[]` — flattens the nested response structure (AWS groups instances by reservation/launch event).
- `Tags[?Key==\`Name\`].Value|[0]` — extracts the value of the `Name` tag from the tags array.
- `--output table` — formats as an ASCII table for human readability.

**Output:**

```
---------------------------------------------------------------------------------------------------
|                                        DescribeInstances                                        |
+---------------------+-----------------+-------------+-----------------+-----------+-------------+
|     InstanceId      |      Name       |  PrivateIP  |    PublicIP     |   State   |    Type     |
+---------------------+-----------------+-------------+-----------------+-----------+-------------+
|  i-0485789851116b85e|  golgi-master   |  10.0.1.131 |  44.212.35.8    |  running  |  t3.medium  |
|  i-02c851cc663d17b3e|  golgi-worker-1 |  10.0.1.110 |  54.173.219.56  |  running  |  t3.xlarge  |
|  i-0fb0f2ac6384d779f|  golgi-worker-2 |  10.0.1.10  |  44.206.236.146 |  running  |  t3.xlarge  |
|  i-07c1c3c65c833a675|  golgi-worker-3 |  10.0.1.94  |  174.129.77.19  |  running  |  t3.xlarge  |
|  i-07b31e765e0ff1b45|  golgi-loadgen  |  10.0.1.142 |  44.211.68.203  |  running  |  t3.medium  |
+---------------------+-----------------+-------------+-----------------+-----------+-------------+
```

**Understanding the two IP addresses:**

Each instance has both a private and public IP:

| IP Type | Range | Visible To | Used For | Persists on Stop/Start? |
|---|---|---|---|---|
| **Private IP** | `10.0.1.x` (from our subnet) | Other instances in the VPC | Inter-node communication (k3s, metrics, routing) | Yes (stays the same) |
| **Public IP** | Various (`44.x`, `54.x`, `174.x`) | The entire internet | SSH from laptop, load generator access | **No** (changes on stop/start) |

- k3s workers join the cluster using the master's **private** IP (`10.0.1.131`), because inter-node traffic should stay within the VPC (faster, free, no internet exposure).
- We SSH into instances using their **public** IPs, because our laptop is on the public internet.
- If you stop and restart an instance, the public IP changes. You would need to re-run `describe-instances` to get the new IP. The private IP stays the same because it is assigned by the subnet's DHCP and is associated with the network interface, not the running state.

**IP address reference (save these — used throughout the project):**

```bash
MASTER_PUBLIC_IP=44.212.35.8
MASTER_PRIVATE_IP=10.0.1.131
WORKER1_PUBLIC_IP=54.173.219.56
WORKER1_PRIVATE_IP=10.0.1.110
WORKER2_PUBLIC_IP=44.206.236.146
WORKER2_PRIVATE_IP=10.0.1.10
WORKER3_PUBLIC_IP=174.129.77.19
WORKER3_PRIVATE_IP=10.0.1.94
LOADGEN_PUBLIC_IP=44.211.68.203
LOADGEN_PRIVATE_IP=10.0.1.142
```

---

**SSH verification:**

We verified SSH access to the master node to confirm everything works end-to-end (key pair, security group, networking, instance boot):

```bash
ssh -i C:/Users/worka/.ssh/golgi-key.pem \
  -o StrictHostKeyChecking=no \
  -o ConnectTimeout=10 \
  ec2-user@44.212.35.8 \
  "hostname && uname -a"
```

**Explanation of SSH flags:**
- `-i C:/Users/worka/.ssh/golgi-key.pem` — specifies the private key file created in Step 0.3
- `-o StrictHostKeyChecking=no` — automatically accepts the instance's host key on first connection. Without this, SSH would pause and ask "Are you sure you want to continue connecting (yes/no)?" which blocks non-interactive use. In production, you would verify the host key fingerprint; for a fresh instance we just launched, auto-accepting is safe.
- `-o ConnectTimeout=10` — fail after 10 seconds if the connection cannot be established (instead of the default ~60 second timeout). Useful for quick feedback if something is wrong.
- `ec2-user` — the default SSH username on Amazon Linux 2023. Other AMIs use different defaults: `ubuntu` on Ubuntu, `centos` on CentOS, `admin` on Debian.
- `"hostname && uname -a"` — runs two commands on the remote instance and returns the output. This is a quick smoke test.

**Output:**
```
Warning: Permanently added '44.212.35.8' (ED25519) to the list of known hosts.
ip-10-0-1-131.ec2.internal
Linux ip-10-0-1-131.ec2.internal 6.1.166-197.305.amzn2023.x86_64 #1 SMP PREEMPT_DYNAMIC Mon Mar 23 09:53:26 UTC 2026 x86_64 x86_64 x86_64 GNU/Linux
```

**Reading the output:**
- `Warning: Permanently added '44.212.35.8' (ED25519)` — SSH saved the instance's host key to `~/.ssh/known_hosts`. Future connections will verify against this stored key (protects against man-in-the-middle attacks).
- `ip-10-0-1-131.ec2.internal` — the hostname, automatically set by AWS based on the private IP. `ec2.internal` is the default domain for instances in `us-east-1`.
- `Linux ip-10-0-1-131.ec2.internal 6.1.166-197.305.amzn2023.x86_64` — confirms the OS is Linux with kernel 6.1.166 (Amazon Linux 2023).
- `SMP PREEMPT_DYNAMIC` — the kernel supports Symmetric Multi-Processing and dynamic preemption, meaning it can handle multiple CPUs and has good scheduling latency characteristics.
- `x86_64` — confirms 64-bit Intel/AMD architecture (matching our AMI choice).

This confirms: the instance booted successfully, the SSH key works, the security group allows port 22 from our IP, and the network path (laptop → internet → IGW → VPC → instance) is functional.

---

**Cost tracking for running instances:**

| Instance | Type | On-demand $/hr | Count | Subtotal $/hr |
|---|---|---|---|---|
| golgi-master | t3.medium | $0.0416 | 1 | $0.0416 |
| golgi-worker-1/2/3 | t3.xlarge | $0.1664 | 3 | $0.4992 |
| golgi-loadgen | t3.medium | $0.0416 | 1 | $0.0416 |
| **Total** | | | **5** | **$0.5824/hr** |

- Per day (24hr): ~$13.98
- Per week: ~$97.86
- **Recommendation:** Stop all instances when not actively working. Stopped instances cost $0 for compute (you still pay ~$0.08/GB-month for EBS storage, which is negligible — 5 instances × 8 GB × $0.08 = $3.20/month).

**How to stop/start instances:**
```powershell
# Stop all instances (preserves data, releases compute, public IPs will change on restart)
aws ec2 stop-instances --instance-ids i-0485789851116b85e i-02c851cc663d17b3e i-0fb0f2ac6384d779f i-07c1c3c65c833a675 i-07b31e765e0ff1b45

# Start all instances (when ready to work again)
aws ec2 start-instances --instance-ids i-0485789851116b85e i-02c851cc663d17b3e i-0fb0f2ac6384d779f i-07c1c3c65c833a675 i-07b31e765e0ff1b45

# After starting, re-run describe-instances to get new public IPs
aws ec2 describe-instances --filters "Name=tag:Name,Values=golgi-*" \
  --query 'Reservations[].Instances[].{Name:Tags[?Key==`Name`].Value|[0],PublicIP:PublicIpAddress,PrivateIP:PrivateIpAddress,State:State.Name}' \
  --output table
```

**EBS (Elastic Block Store) volumes — the instance disks:**
Each instance gets an 8 GB gp3 (General Purpose SSD) root volume by default from the AMI. This contains the OS and all installed software. gp3 volumes provide:
- 3,000 IOPS baseline (enough for our workload — we are not doing heavy disk I/O)
- 125 MB/s throughput baseline
- $0.08/GB-month storage cost
If any instance needs more disk space (e.g., for Docker images or log files), we can expand the volume later with `aws ec2 modify-volume`.

---

**Instance lifecycle and what happens at each state:**

```
                 run-instances
                      |
                      v
    +----------+  boot   +----------+  cloud-init  +----------+
    | pending  | ------> | running  | -----------> | ready    |
    +----------+         +----------+              | (SSH OK) |
                              |                     +----------+
                         stop-instances
                              |
                              v
                         +----------+
                         | stopping |
                         +----------+
                              |
                              v
                         +----------+  start-instances  +----------+
                         | stopped  | ----------------> | pending  | → running
                         +----------+                   +----------+
                              |
                       terminate-instances
                              |
                              v
                         +--------------+
                         | terminated   | (gone forever, EBS deleted)
                         +--------------+
```

- **pending → running:** AWS is allocating hardware, copying the AMI to EBS, starting the VM. Takes 30-60 seconds.
- **running:** The instance is powered on. Billing starts. You can SSH in once cloud-init finishes (usually within 60 seconds of reaching `running`).
- **stopping → stopped:** The VM is shut down. EBS volumes are preserved. Public IP is released. Billing stops for compute (EBS storage billing continues).
- **stopped → pending → running:** The VM is restarted, potentially on a different physical host. Gets a new public IP. Private IP stays the same. All data on EBS is preserved.
- **terminated:** The instance is permanently deleted. EBS root volume is deleted (unless `DeleteOnTermination=false`). This is irreversible. **Do not terminate — use stop instead.**

---

#### Steps 0.12–0.15: k3s Cluster Setup — COMPLETED (2026-04-11)

**What we did:** Installed k3s (a lightweight, certified Kubernetes distribution) across 4 of our 5 EC2 instances to form a Kubernetes cluster. The master node runs the k3s server (control plane), and the 3 worker nodes run k3s agents that register with the master. The load generator instance is intentionally left outside the cluster.

**Why do we need Kubernetes?**
Golgi is a scheduling system for serverless functions. The serverless functions run inside containers, and Kubernetes is the orchestration layer that:
- Schedules containers (pods) onto worker nodes
- Manages container lifecycle (start, stop, restart, health checks)
- Provides service discovery (so the router can find function instances by name)
- Handles networking between containers across different nodes (pod-to-pod networking)
- Manages resource allocation (CPU/memory limits and requests for each container)

Without Kubernetes, we would have to manually start Docker containers on each worker, manage their networking, handle restarts on failure, and implement service discovery ourselves. Kubernetes automates all of this.

**Why k3s instead of full Kubernetes (kubeadm)?**

The paper uses kubeadm (the standard Kubernetes installation tool). We use k3s instead for these reasons:

| Feature | kubeadm (Full K8s) | k3s |
|---|---|---|
| Binary size | ~300 MB (multiple binaries) | ~50 MB (single binary) |
| Install time | 10-15 minutes (multi-step) | 30 seconds (one command) |
| Dependencies | Docker/containerd, kubelet, kubeadm, kubectl (separate installs) | None (containerd bundled) |
| etcd | External etcd cluster (3 nodes for HA) | Embedded SQLite or etcd |
| RAM usage | ~1-2 GB for control plane | ~500 MB for control plane |
| Kubernetes API | Full K8s API (100% compatible) | Full K8s API (100% compatible) |
| kubectl commands | Same | Same |
| Pod/Service/Deployment | Same | Same |
| CNCF certified | Yes | Yes |

The critical point is **API compatibility**: every `kubectl` command, every YAML manifest, every Helm chart that works on full Kubernetes works identically on k3s. OpenFaaS cannot tell the difference. Our benchmark and analysis tools cannot tell the difference. The only difference is operational — k3s is simpler to install and uses fewer resources.

**Why `--disable traefik`?**
k3s bundles Traefik as its default ingress controller (handles HTTP routing into the cluster). We disable it because:
- We use the OpenFaaS gateway directly for function invocation — Traefik adds an unnecessary layer
- Traefik would consume ports and resources we don't need for our experiments
- Disabling it saves ~100 MB of RAM on the master node

**k3s architecture diagram:**

```
+---------------------------------------------+
|           golgi-master (10.0.1.131)          |
|                                              |
|  +----------+  +---------+  +------------+  |
|  | k3s      |  | etcd    |  | CoreDNS    |  |
|  | server   |  | (embed) |  | (DNS for   |  |
|  | (API     |  |         |  |  services)  |  |
|  |  server) |  |         |  |            |  |
|  +----+-----+  +---------+  +------------+  |
|       |                                      |
|       | Port 6443 (K8s API)                  |
+-------+-------------------------------------+
        |
        | k3s agents connect to master:6443
        | using the join token for authentication
        |
   +----+----+----+
   |         |    |
   v         v    v
+--------+ +--------+ +--------+
| worker | | worker | | worker |
|   1    | |   2    | |   3    |
|10.0.1. | |10.0.1. | |10.0.1. |
|  110   | |   10   | |   94   |
|        | |        | |        |
| k3s    | | k3s    | | k3s    |
| agent  | | agent  | | agent  |
|        | |        | |        |
| kubelet| | kubelet| | kubelet|
| contain| | contain| | contain|
| erd    | | erd    | | erd    |
+--------+ +--------+ +--------+

Not in cluster:
+--------+
| loadgen|
|10.0.1. |
|  142   |
| (Locust|
|  only) |
+--------+
```

**What each k3s component does:**
- **k3s server (API server):** The central brain. Receives all `kubectl` commands, stores cluster state in etcd, schedules pods onto nodes, watches for node health.
- **etcd (embedded):** A key-value store that holds all cluster state — which pods exist, which nodes are registered, which services are defined. k3s embeds etcd as a single-node instance (vs full K8s which runs etcd as a separate 3-node cluster for high availability).
- **CoreDNS:** Provides DNS resolution inside the cluster. When a pod needs to reach a service (e.g., `openfaas-gateway.openfaas.svc.cluster.local`), CoreDNS resolves it to the service's internal IP.
- **k3s agent (per worker):** Runs on each worker node. Contains the kubelet (manages pods on this node) and containerd (runs containers). The agent registers itself with the server via the join token and then receives pod scheduling instructions.
- **containerd:** The container runtime that actually creates and runs containers (OCI-compliant). k3s bundles containerd — no separate Docker installation needed.

---

**Step 0.12: Install k3s server on the master node**

We SSH into the master node and run the k3s install script:

```bash
ssh -i C:/Users/worka/.ssh/golgi-key.pem \
  -o StrictHostKeyChecking=no \
  ec2-user@44.212.35.8 \
  "curl -sfL https://get.k3s.io | sh -s - \
    --write-kubeconfig-mode 644 \
    --disable traefik \
    --node-name golgi-master"
```

**Explanation of the command:**

The outer command is `ssh ... "command"` which runs a command on the remote master node via SSH. The inner command has two parts:

**Part 1: `curl -sfL https://get.k3s.io`**
- Downloads the k3s install script from the official k3s website.
- `-s` = silent (no progress bar), `-f` = fail on HTTP errors, `-L` = follow redirects.
- The script is a shell script that detects the OS/architecture, downloads the correct k3s binary, and installs it.

**Part 2: `| sh -s - --write-kubeconfig-mode 644 --disable traefik --node-name golgi-master`**
- Pipes the downloaded script into `sh` (shell) to execute it.
- `-s -` tells `sh` to read from stdin (the pipe) and pass the remaining arguments to the script.
- `--write-kubeconfig-mode 644` — makes the kubeconfig file (`/etc/rancher/k3s/k3s.yaml`) readable by all users, not just root. Without this, `kubectl` requires `sudo`. `644` means owner can read/write, group and others can read.
- `--disable traefik` — do not install the Traefik ingress controller (we use our own router).
- `--node-name golgi-master` — sets the Kubernetes node name. Without this, k3s would use the hostname (`ip-10-0-1-131`), which is hard to read in `kubectl get nodes` output.

**What the install script does internally (step by step):**
1. Detects the OS (`Amazon Linux 2023`) and architecture (`x86_64/amd64`)
2. Queries the k3s GitHub releases API for the latest stable version
3. Downloads the k3s binary (~50 MB) and its SHA256 checksum
4. Verifies the download integrity (checksum must match)
5. Installs the binary to `/usr/local/bin/k3s`
6. Creates symlinks: `/usr/local/bin/kubectl` → k3s, `/usr/local/bin/crictl` → k3s, `/usr/local/bin/ctr` → k3s (the single k3s binary acts as all three tools depending on how it is invoked)
7. Installs SELinux policies (`k3s-selinux` and `container-selinux` RPM packages via `dnf`) so containers can run under SELinux enforcement
8. Creates a systemd service file (`/etc/systemd/system/k3s.service`) and enables it to start on boot
9. Creates convenience scripts: `k3s-killall.sh` (stop all k3s processes) and `k3s-uninstall.sh` (complete removal)
10. Starts the k3s server via systemd

**Full output:**

```
[INFO]  Finding release for channel stable
[INFO]  Using v1.34.6+k3s1 as release
[INFO]  Downloading hash https://github.com/k3s-io/k3s/releases/download/v1.34.6+k3s1/sha256sum-amd64.txt
[INFO]  Downloading binary https://github.com/k3s-io/k3s/releases/download/v1.34.6+k3s1/k3s
[INFO]  Verifying binary download
[INFO]  Installing k3s to /usr/local/bin/k3s
[INFO]  Finding available k3s-selinux versions
Amazon Linux 2023 Kernel Livepatch repository   244 kB/s |  31 kB     00:00    
Rancher K3s Common (stable)                      39 kB/s | 2.6 kB     00:00    
Dependencies resolved.
================================================================================
 Package           Arch   Version               Repository                 Size
================================================================================
Installing:
 k3s-selinux       noarch 1.6-1.el8             rancher-k3s-common-stable  20 k
Installing dependencies:
 container-selinux noarch 4:2.245.0-1.amzn2023  amazonlinux                58 k

Transaction Summary
================================================================================
Install  2 Packages

Total download size: 78 k
Installed size: 167 k
Downloading Packages:
(1/2): k3s-selinux-1.6-1.el8.noarch.rpm         601 kB/s |  20 kB     00:00    
(2/2): container-selinux-2.245.0-1.amzn2023.noa 1.4 MB/s |  58 kB     00:00    
--------------------------------------------------------------------------------
Total                                           985 kB/s |  78 kB     00:00     
Rancher K3s Common (stable)                     103 kB/s | 2.4 kB     00:00    
Importing GPG key 0xE257814A:
 Userid     : "Rancher (CI) <ci@rancher.com>"
 Fingerprint: C8CF F216 4551 26E9 B9C9 18BE 925E A29A E257 814A
 From       : https://rpm.rancher.io/public.key
Key imported successfully
Running transaction check
Transaction check succeeded.
Running transaction test
Transaction test succeeded.
Running transaction
  Preparing        :                                                        1/1 
  Running scriptlet: container-selinux-4:2.245.0-1.amzn2023.noarch          1/2 
  Installing       : container-selinux-4:2.245.0-1.amzn2023.noarch          1/2 
  Running scriptlet: container-selinux-4:2.245.0-1.amzn2023.noarch          1/2 
  Running scriptlet: k3s-selinux-1.6-1.el8.noarch                           2/2 
  Installing       : k3s-selinux-1.6-1.el8.noarch                           2/2 
  Running scriptlet: k3s-selinux-1.6-1.el8.noarch                           2/2 
  Running scriptlet: container-selinux-4:2.245.0-1.amzn2023.noarch          2/2 
  Running scriptlet: k3s-selinux-1.6-1.el8.noarch                           2/2 
  Verifying        : container-selinux-4:2.245.0-1.amzn2023.noarch          1/2 
  Verifying        : k3s-selinux-1.6-1.el8.noarch                           2/2 

Installed:
  container-selinux-4:2.245.0-1.amzn2023.noarch   k3s-selinux-1.6-1.el8.noarch  

Complete!
[INFO]  Creating /usr/local/bin/kubectl symlink to k3s
[INFO]  Creating /usr/local/bin/crictl symlink to k3s
[INFO]  Creating /usr/local/bin/ctr symlink to k3s
[INFO]  Creating killall script /usr/local/bin/k3s-killall.sh
[INFO]  Creating uninstall script /usr/local/bin/k3s-uninstall.sh
[INFO]  env: Creating environment file /etc/systemd/system/k3s.service.env
[INFO]  systemd: Creating service file /etc/systemd/system/k3s.service
[INFO]  systemd: Enabling k3s unit
Created symlink /etc/systemd/system/multi-user.target.wants/k3s.service → /etc/systemd/system/k3s.service.
[INFO]  Host iptables-save/iptables-restore tools not found
[INFO]  Host ip6tables-save/ip6tables-restore tools not found
[INFO]  systemd: Starting k3s
```

**Reading the key output lines:**
- `Using v1.34.6+k3s1 as release` — the k3s version installed. This maps to Kubernetes v1.34.6 (the `+k3s1` suffix is k3s's build number).
- `Installing k3s to /usr/local/bin/k3s` — the single binary location. All of kubectl, crictl, ctr are symlinks to this one binary.
- `Install 2 Packages: k3s-selinux, container-selinux` — SELinux policies that allow containers to run under Amazon Linux 2023's SELinux enforcement mode. Without these, container operations would be blocked by SELinux.
- `Importing GPG key 0xE257814A` — verifies the SELinux RPM packages are signed by Rancher (the company behind k3s). This prevents installing tampered packages.
- `Creating /usr/local/bin/kubectl symlink to k3s` — now `kubectl get nodes` works without specifying the full k3s path. The k3s binary detects it was invoked as `kubectl` and behaves as kubectl.
- `systemd: Enabling k3s unit` — k3s will automatically start on system boot (e.g., if the instance is stopped and started again).
- `systemd: Starting k3s` — the k3s server is now running. It begins initializing the API server, etcd, scheduler, and controller manager.
- `Host iptables-save/iptables-restore tools not found` — this is a non-fatal warning. k3s uses iptables for Kubernetes service networking (kube-proxy). Amazon Linux 2023 uses nftables instead of iptables. k3s falls back to its built-in nftables support — this works correctly.

**Result:**
- k3s version: `v1.34.6+k3s1`
- Kubernetes version: `v1.34.6`
- Container runtime: `containerd://2.2.2-bd1.34`
- Service file: `/etc/systemd/system/k3s.service`
- Kubeconfig: `/etc/rancher/k3s/k3s.yaml` (mode 644)
- Node name: `golgi-master`

---

**Step 0.12b: Retrieve the join token**

The k3s server generates a secret token at installation time. Worker nodes must present this token when connecting to the master to prove they are authorized to join the cluster. Without the token, any machine that can reach port 6443 could register as a node — a security risk.

```bash
ssh -i C:/Users/worka/.ssh/golgi-key.pem \
  ec2-user@44.212.35.8 \
  "sudo cat /var/lib/rancher/k3s/server/node-token"
```

**Output:**
```
K107e34fde2b74a9ecbefefdde4ebf29e954372a412754fccaa0a4ad0fe03c471c3::server:d16c2c422e53b26349a95b796d8acbde
```

**Understanding the token format:**
- `K1` — prefix indicating this is a k3s node token (version 1 format)
- `07e34fde2b74a9ecbefefdde4ebf29e954372a412754fccaa0a4ad0fe03c471c3` — a SHA256 hash of the server's CA certificate. The joining agent uses this to verify it is connecting to the real master (not an impersonator).
- `::server:` — separator indicating this is a server-issued token
- `d16c2c422e53b26349a95b796d8acbde` — the actual secret password. This is randomly generated and stored on disk at `/var/lib/rancher/k3s/server/node-token`.

**Why `sudo`?** The token file is owned by root and has permissions `600` (only root can read). This prevents unprivileged users on the master from reading the token and registering rogue nodes.

**Token location:** `/var/lib/rancher/k3s/server/node-token` — this file is created automatically by the k3s server during installation. It persists across reboots.

---

**Step 0.12c: Verify master node is ready**

Before joining workers, we verify the master node has finished initializing and is in `Ready` state:

```bash
ssh -i C:/Users/worka/.ssh/golgi-key.pem \
  ec2-user@44.212.35.8 \
  "kubectl get nodes -o wide"
```

**Output:**
```
NAME           STATUS   ROLES           AGE   VERSION        INTERNAL-IP   EXTERNAL-IP   OS-IMAGE                        KERNEL-VERSION                    CONTAINER-RUNTIME
golgi-master   Ready    control-plane   9s    v1.34.6+k3s1   10.0.1.131    <none>        Amazon Linux 2023.11.20260406   6.1.166-197.305.amzn2023.x86_64   containerd://2.2.2-bd1.34
```

**Reading each column:**
- `NAME: golgi-master` — the node name we set with `--node-name golgi-master`
- `STATUS: Ready` — the node is healthy and can accept pods. Other possible states: `NotReady` (kubelet not responding), `SchedulingDisabled` (cordoned — won't accept new pods but existing ones keep running)
- `ROLES: control-plane` — this node runs the Kubernetes control plane components (API server, scheduler, controller manager, etcd). In k3s, the server node always gets this role.
- `AGE: 9s` — the node has been registered for 9 seconds
- `VERSION: v1.34.6+k3s1` — the Kubernetes version running on this node
- `INTERNAL-IP: 10.0.1.131` — the node's private IP (matches our EC2 private IP). Kubernetes uses this for inter-node communication.
- `EXTERNAL-IP: <none>` — Kubernetes does not automatically detect the public IP. This is normal for self-managed clusters (vs managed services like EKS which populate this field).
- `OS-IMAGE: Amazon Linux 2023.11.20260406` — the operating system
- `KERNEL-VERSION: 6.1.166-197.305.amzn2023.x86_64` — the Linux kernel version
- `CONTAINER-RUNTIME: containerd://2.2.2-bd1.34` — the container runtime version. containerd is bundled with k3s (no separate Docker installation needed).

**What `kubectl get nodes` actually does behind the scenes:**
1. `kubectl` reads the kubeconfig file (`/etc/rancher/k3s/k3s.yaml`) to find the API server address (`https://127.0.0.1:6443`) and authentication credentials.
2. It sends an HTTPS GET request to `https://127.0.0.1:6443/api/v1/nodes`.
3. The API server queries etcd for all registered node objects.
4. The response is formatted as a table and displayed.

---

**Step 0.13: Join worker nodes to the cluster**

We need to install k3s on each worker node in **agent mode** (not server mode). The agent connects to the master's API server using the join token and registers itself as a worker node.

The key differences between server mode (master) and agent mode (worker):

| Aspect | Server (Master) | Agent (Worker) |
|---|---|---|
| Command | `sh -s -` (no K3S_URL) | `sh -s -` with `K3S_URL` and `K3S_TOKEN` env vars |
| Runs | API server + scheduler + etcd + kubelet + containerd | kubelet + containerd only |
| Systemd service | `k3s.service` | `k3s-agent.service` |
| Uninstall script | `k3s-uninstall.sh` | `k3s-agent-uninstall.sh` |
| Can schedule pods | Yes (but we don't want to — master should run only control plane) | Yes (this is where function containers run) |
| RAM usage | ~500 MB (control plane + runtime) | ~200 MB (runtime only) |

**Worker 1 (golgi-worker-1, 54.173.219.56, 10.0.1.110):**

```bash
ssh -i C:/Users/worka/.ssh/golgi-key.pem \
  -o StrictHostKeyChecking=no \
  ec2-user@54.173.219.56 \
  "curl -sfL https://get.k3s.io | \
    K3S_URL=https://10.0.1.131:6443 \
    K3S_TOKEN='K107e34fde2b74a9ecbefefdde4ebf29e954372a412754fccaa0a4ad0fe03c471c3::server:d16c2c422e53b26349a95b796d8acbde' \
    sh -s - --node-name golgi-worker-1"
```

**Explanation of the agent-specific parts:**
- `K3S_URL=https://10.0.1.131:6443` — tells the agent where to find the k3s server. We use the master's **private IP** (`10.0.1.131`), not the public IP, because:
  - Inter-VPC traffic on private IPs is free (public IP traffic goes through the IGW and costs money)
  - Private IP does not change on stop/start (public IP does)
  - Lower latency (no NAT translation through the IGW)
  - Port 6443 is the Kubernetes API server port (the standard port for K8s)
- `K3S_TOKEN='K107e34f...'` — the join token from Step 0.12b. The agent presents this to the API server to authenticate. The server verifies the token matches and allows the node to register.
- `--node-name golgi-worker-1` — sets the node name in Kubernetes. Without this, it would use the hostname (`ip-10-0-1-110`).

**Full output for worker-1:**
```
[INFO]  Finding release for channel stable
[INFO]  Using v1.34.6+k3s1 as release
[INFO]  Downloading hash https://github.com/k3s-io/k3s/releases/download/v1.34.6+k3s1/sha256sum-amd64.txt
[INFO]  Downloading binary https://github.com/k3s-io/k3s/releases/download/v1.34.6+k3s1/k3s
[INFO]  Verifying binary download
[INFO]  Installing k3s to /usr/local/bin/k3s
[INFO]  Finding available k3s-selinux versions
Amazon Linux 2023 Kernel Livepatch repository   236 kB/s |  31 kB     00:00    
Rancher K3s Common (stable)                      36 kB/s | 2.6 kB     00:00    
Dependencies resolved.
================================================================================
 Package           Arch   Version               Repository                 Size
================================================================================
Installing:
 k3s-selinux       noarch 1.6-1.el8             rancher-k3s-common-stable  20 k
Installing dependencies:
 container-selinux noarch 4:2.245.0-1.amzn2023  amazonlinux                58 k

Transaction Summary
================================================================================
Install  2 Packages

Total download size: 78 k
Installed size: 167 k
Downloading Packages:
(1/2): k3s-selinux-1.6-1.el8.noarch.rpm         548 kB/s |  20 kB     00:00    
(2/2): container-selinux-2.245.0-1.amzn2023.noa 1.4 MB/s |  58 kB     00:00    
--------------------------------------------------------------------------------
Total                                           1.0 MB/s |  78 kB     00:00     
Rancher K3s Common (stable)                      89 kB/s | 2.4 kB     00:00    
Importing GPG key 0xE257814A:
 Userid     : "Rancher (CI) <ci@rancher.com>"
 Fingerprint: C8CF F216 4551 26E9 B9C9 18BE 925E A29A E257 814A
 From       : https://rpm.rancher.io/public.key
Key imported successfully
Running transaction check
Transaction check succeeded.
Running transaction test
Transaction test succeeded.
Running transaction
  Preparing        :                                                        1/1 
  Running scriptlet: container-selinux-4:2.245.0-1.amzn2023.noarch          1/2 
  Installing       : container-selinux-4:2.245.0-1.amzn2023.noarch          1/2 
  Running scriptlet: container-selinux-4:2.245.0-1.amzn2023.noarch          1/2 
  Running scriptlet: k3s-selinux-1.6-1.el8.noarch                           2/2 
  Installing       : k3s-selinux-1.6-1.el8.noarch                           2/2 
  Running scriptlet: k3s-selinux-1.6-1.el8.noarch                           2/2 
  Running scriptlet: container-selinux-4:2.245.0-1.amzn2023.noarch          2/2 
  Running scriptlet: k3s-selinux-1.6-1.el8.noarch                           2/2 
  Verifying        : container-selinux-4:2.245.0-1.amzn2023.noarch          1/2 
  Verifying        : k3s-selinux-1.6-1.el8.noarch                           2/2 

Installed:
  container-selinux-4:2.245.0-1.amzn2023.noarch   k3s-selinux-1.6-1.el8.noarch  

Complete!
[INFO]  Creating /usr/local/bin/kubectl symlink to k3s
[INFO]  Creating /usr/local/bin/crictl symlink to k3s
[INFO]  Creating /usr/local/bin/ctr symlink to k3s
[INFO]  Creating killall script /usr/local/bin/k3s-killall.sh
[INFO]  Creating uninstall script /usr/local/bin/k3s-agent-uninstall.sh
[INFO]  env: Creating environment file /etc/systemd/system/k3s-agent.service.env
[INFO]  systemd: Creating service file /etc/systemd/system/k3s-agent.service
[INFO]  systemd: Enabling k3s-agent unit
Created symlink /etc/systemd/system/multi-user.target.wants/k3s-agent.service → /etc/systemd/system/k3s-agent.service.
[INFO]  Host iptables-save/iptables-restore tools not found
[INFO]  Host ip6tables-save/ip6tables-restore tools not found
[INFO]  systemd: Starting k3s-agent
```

**Key differences from the server install output:**
- `Creating uninstall script /usr/local/bin/k3s-agent-uninstall.sh` — agent-specific uninstall script (vs `k3s-uninstall.sh` on the server)
- `Creating service file /etc/systemd/system/k3s-agent.service` — agent service (vs `k3s.service` on the server)
- `Enabling k3s-agent unit` — the agent service starts on boot
- `Starting k3s-agent` — the agent connects to `https://10.0.1.131:6443` using the token, registers as a node, and begins accepting pod scheduling instructions

**What happens when the agent starts:**
1. The k3s agent reads the `K3S_URL` and `K3S_TOKEN` from its environment file (`/etc/systemd/system/k3s-agent.service.env`)
2. It connects to the master's API server at `https://10.0.1.131:6443`
3. It presents the join token. The server verifies the token's CA hash matches its own CA certificate and the password matches the stored token.
4. The server issues a kubelet client certificate to the agent (TLS mutual authentication for all future communication)
5. The agent's kubelet registers itself as a new Node object in the API server
6. The node transitions from `NotReady` → `Ready` once the kubelet confirms it can manage containers
7. The Kubernetes scheduler can now assign pods to this node

**Worker 2 (golgi-worker-2, 44.206.236.146, 10.0.1.10):**

```bash
ssh -i C:/Users/worka/.ssh/golgi-key.pem \
  -o StrictHostKeyChecking=no \
  ec2-user@44.206.236.146 \
  "curl -sfL https://get.k3s.io | \
    K3S_URL=https://10.0.1.131:6443 \
    K3S_TOKEN='K107e34fde2b74a9ecbefefdde4ebf29e954372a412754fccaa0a4ad0fe03c471c3::server:d16c2c422e53b26349a95b796d8acbde' \
    sh -s - --node-name golgi-worker-2"
```

Output: identical to worker-1 (same k3s version, same SELinux packages, same systemd setup). The only difference is `--node-name golgi-worker-2`. Output ended with:
```
[INFO]  systemd: Starting k3s-agent
```

**Worker 3 (golgi-worker-3, 174.129.77.19, 10.0.1.94):**

```bash
ssh -i C:/Users/worka/.ssh/golgi-key.pem \
  -o StrictHostKeyChecking=no \
  ec2-user@174.129.77.19 \
  "curl -sfL https://get.k3s.io | \
    K3S_URL=https://10.0.1.131:6443 \
    K3S_TOKEN='K107e34fde2b74a9ecbefefdde4ebf29e954372a412754fccaa0a4ad0fe03c471c3::server:d16c2c422e53b26349a95b796d8acbde' \
    sh -s - --node-name golgi-worker-3"
```

Output: identical to worker-1 and worker-2. Output ended with:
```
[INFO]  systemd: Starting k3s-agent
```

**Note on parallel execution:** We launched all 3 worker joins simultaneously (in parallel), not sequentially. This is safe because each worker connects to the master independently — they do not depend on each other. Running in parallel reduced the total wait time from ~3 minutes (sequential) to ~1 minute (parallel, limited by the slowest worker).

**Result for all 3 workers:**
- k3s version: `v1.34.6+k3s1` (same as master — version match is important for compatibility)
- Container runtime: `containerd://2.2.2-bd1.34`
- SELinux packages: `k3s-selinux-1.6-1.el8`, `container-selinux-4:2.245.0-1.amzn2023`
- Service: `k3s-agent.service` (enabled, started)
- Connected to master: `https://10.0.1.131:6443`

---

**Step 0.15: Label worker nodes**

We add custom labels to the worker nodes so that we can control pod scheduling in later phases. Labels are key-value pairs attached to Kubernetes objects (nodes, pods, services) that are used for selection and filtering.

```bash
ssh -i C:/Users/worka/.ssh/golgi-key.pem \
  ec2-user@44.212.35.8 \
  "kubectl label node golgi-worker-1 role=worker node-type=function-host && \
   kubectl label node golgi-worker-2 role=worker node-type=function-host && \
   kubectl label node golgi-worker-3 role=worker node-type=function-host"
```

**Output:**
```
node/golgi-worker-1 labeled
node/golgi-worker-2 labeled
node/golgi-worker-3 labeled
```

**What labels we added and why:**

| Label | Value | Purpose |
|---|---|---|
| `role` | `worker` | Distinguishes workers from the master. We can use `nodeSelector: {role: worker}` in pod specs to ensure function containers only run on workers, never on the master. |
| `node-type` | `function-host` | More specific label for our experiments. In later phases, we may differentiate between nodes hosting OC instances vs Non-OC instances. This label marks nodes eligible to host function containers. |

**Why label nodes?**
By default, Kubernetes will schedule pods on **any** node with sufficient resources, including the master. This is undesirable because:
- The master runs the k3s control plane (API server, etcd, scheduler). Function containers would compete for CPU/memory with the control plane.
- The metric collector measures container resource usage to make routing decisions. If function containers run on the master alongside control plane processes, the metrics would be noisy and misleading.
- Following the Golgi paper's architecture (which we use as our infrastructure reference), the master node should not host function instances — it runs only the control plane and gateway.

With labels, we can add a `nodeSelector` to our OpenFaaS function deployments:
```yaml
nodeSelector:
  role: worker
  node-type: function-host
```
This ensures pods are only scheduled on the 3 worker nodes.

**How labels work in Kubernetes:**
- Labels are stored as metadata on the node object in etcd
- They are not enforced automatically — you must reference them in `nodeSelector`, `nodeAffinity`, or `podAntiAffinity` rules in your pod specifications
- Labels can be added, modified, or removed at any time without restarting the node
- Labels are arbitrary key-value pairs — Kubernetes does not validate the key or value names (except format: must be alphanumeric with `-`, `_`, `.` allowed)

---

**Step 0.14 (verification): Verify the full 4-node cluster**

After all workers joined and were labeled, we verified the complete cluster state:

```bash
ssh -i C:/Users/worka/.ssh/golgi-key.pem \
  ec2-user@44.212.35.8 \
  "kubectl get nodes -o wide"
```

**Output:**
```
NAME             STATUS   ROLES           AGE     VERSION        INTERNAL-IP   EXTERNAL-IP   OS-IMAGE                        KERNEL-VERSION                    CONTAINER-RUNTIME
golgi-master     Ready    control-plane   4m43s   v1.34.6+k3s1   10.0.1.131    <none>        Amazon Linux 2023.11.20260406   6.1.166-197.305.amzn2023.x86_64   containerd://2.2.2-bd1.34
golgi-worker-1   Ready    <none>          3m4s    v1.34.6+k3s1   10.0.1.110    <none>        Amazon Linux 2023.11.20260406   6.1.166-197.305.amzn2023.x86_64   containerd://2.2.2-bd1.34
golgi-worker-2   Ready    <none>          114s    v1.34.6+k3s1   10.0.1.10     <none>        Amazon Linux 2023.11.20260406   6.1.166-197.305.amzn2023.x86_64   containerd://2.2.2-bd1.34
golgi-worker-3   Ready    <none>          18s     v1.34.6+k3s1   10.0.1.94     <none>        Amazon Linux 2023.11.20260406   6.1.166-197.305.amzn2023.x86_64   containerd://2.2.2-bd1.34
```

**Verification checklist:**

| Check | Expected | Actual | Pass? |
|---|---|---|---|
| Number of nodes | 4 | 4 (master + 3 workers) | ✓ |
| All nodes STATUS | Ready | All 4 are `Ready` | ✓ |
| Master ROLE | control-plane | `control-plane` | ✓ |
| Workers ROLE | `<none>` | All 3 show `<none>` (workers don't have built-in roles) | ✓ |
| k3s version match | All same | All `v1.34.6+k3s1` | ✓ |
| Container runtime match | All same | All `containerd://2.2.2-bd1.34` | ✓ |
| OS match | All same | All `Amazon Linux 2023.11.20260406` | ✓ |
| Kernel match | All same | All `6.1.166-197.305.amzn2023.x86_64` | ✓ |
| Master IP | `10.0.1.131` | `10.0.1.131` | ✓ |
| Worker-1 IP | `10.0.1.110` | `10.0.1.110` | ✓ |
| Worker-2 IP | `10.0.1.10` | `10.0.1.10` | ✓ |
| Worker-3 IP | `10.0.1.94` | `10.0.1.94` | ✓ |
| Load generator NOT in cluster | Not listed | Correct — `golgi-loadgen` does not appear | ✓ |

**Note on AGE values:** The staggered ages (4m43s, 3m4s, 114s, 18s) reflect the order in which nodes joined. The master was installed first, then the workers were joined in parallel — but network and download speeds vary slightly, so they registered at slightly different times.

**Note on ROLES column:** Workers show `<none>` because k3s does not assign a role label to agent nodes by default. The master shows `control-plane` (previously called `master` in older Kubernetes versions — the name was changed for inclusive terminology). Our custom `role=worker` label does not appear in the ROLES column — it is a separate label, not the built-in Kubernetes role annotation.

---

**Cluster summary:**

| Node | Instance ID | Private IP | Type | k3s Role | k3s Version | Custom Labels |
|---|---|---|---|---|---|---|
| golgi-master | `i-0485789851116b85e` | `10.0.1.131` | t3.medium | server (control-plane) | v1.34.6+k3s1 | *(default)* |
| golgi-worker-1 | `i-02c851cc663d17b3e` | `10.0.1.110` | t3.xlarge | agent | v1.34.6+k3s1 | `role=worker`, `node-type=function-host` |
| golgi-worker-2 | `i-0fb0f2ac6384d779f` | `10.0.1.10` | t3.xlarge | agent | v1.34.6+k3s1 | `role=worker`, `node-type=function-host` |
| golgi-worker-3 | `i-07c1c3c65c833a675` | `10.0.1.94` | t3.xlarge | agent | v1.34.6+k3s1 | `role=worker`, `node-type=function-host` |
| golgi-loadgen | `i-07b31e765e0ff1b45` | `10.0.1.142` | t3.medium | *(not in cluster)* | *(none)* | *(none)* |

**k3s join token (needed if adding more nodes later):**
```
K107e34fde2b74a9ecbefefdde4ebf29e954372a412754fccaa0a4ad0fe03c471c3::server:d16c2c422e53b26349a95b796d8acbde
```

**Important operational notes:**
- If you stop and restart the EC2 instances, k3s will automatically restart (it is a systemd service set to `enabled`). Workers will reconnect to the master using the stored token. No manual intervention needed.
- If the master's private IP changes (it shouldn't — private IPs persist across stop/start), you would need to reinstall k3s on all workers with the new `K3S_URL`.
- To check cluster health at any time: `ssh -i golgi-key.pem ec2-user@<master-public-ip> "kubectl get nodes"`
- To view system pods (CoreDNS, local-path-provisioner, metrics-server): `kubectl get pods -A` on the master

---

**What Kubernetes system pods are now running:**

After k3s installation, several system pods are automatically created in the `kube-system` namespace. These provide core cluster services:

| Pod | Purpose |
|---|---|
| `coredns` | DNS server for service discovery inside the cluster |
| `local-path-provisioner` | Automatically creates local storage volumes when pods request persistent storage |
| `metrics-server` | Collects CPU/memory usage from kubelets (used by `kubectl top` and autoscaling) |
| `svclb-*` | Service load balancer (k3s built-in, replaces MetalLB) |

These pods run on the master by default and are managed by k3s — we do not need to configure them.

---

#### Step 0.16: Install OpenFaaS via Helm — COMPLETED (2026-04-11)

**What we did:** Installed Helm, added the OpenFaaS chart repository, created the required Kubernetes namespaces, generated a gateway authentication secret, and deployed OpenFaaS onto the k3s cluster.

**Why OpenFaaS?** The Golgi paper uses OpenFaaS as its serverless platform. It runs on any Kubernetes cluster, provides per-function container isolation (important for our OC/Non-OC resource experiments), and exposes Prometheus metrics out of the box — which we need for Phase 2 (Metric Collector).

**Pre-flight check — Cluster health:**

Before installing anything, we confirmed the k3s cluster was healthy:

```bash
[ec2-user@golgi-master ~]$ kubectl get nodes -o wide
```
```
NAME             STATUS   ROLES           AGE   VERSION        INTERNAL-IP   EXTERNAL-IP   OS-IMAGE                        KERNEL-VERSION                    CONTAINER-RUNTIME
golgi-master     Ready    control-plane   19m   v1.34.6+k3s1   10.0.1.131    <none>        Amazon Linux 2023.11.20260406   6.1.166-197.305.amzn2023.x86_64   containerd://2.2.2-bd1.34
golgi-worker-1   Ready    <none>          17m   v1.34.6+k3s1   10.0.1.110    <none>        Amazon Linux 2023.11.20260406   6.1.166-197.305.amzn2023.x86_64   containerd://2.2.2-bd1.34
golgi-worker-2   Ready    <none>          16m   v1.34.6+k3s1   10.0.1.10     <none>        Amazon Linux 2023.11.20260406   6.1.166-197.305.amzn2023.x86_64   containerd://2.2.2-bd1.34
golgi-worker-3   Ready    <none>          14m   v1.34.6+k3s1   10.0.1.94     <none>        Amazon Linux 2023.11.20260406   6.1.166-197.305.amzn2023.x86_64   containerd://2.2.2-bd1.34
```

All 4 nodes are `Ready`. Proceeding with OpenFaaS installation.

---

**Sub-step 1: Install Helm 3**

Helm is the package manager for Kubernetes. OpenFaaS provides an official Helm chart, which is the recommended installation method. Helm was not pre-installed on our Amazon Linux 2023 AMI.

```bash
[ec2-user@golgi-master ~]$ curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```
```
[WARNING] Could not find git. It is required for plugin installation.
Downloading https://get.helm.sh/helm-v3.20.2-linux-amd64.tar.gz
Verifying checksum... Done.
Preparing to install helm into /usr/local/bin
helm installed into /usr/local/bin/helm
```

Helm v3.20.2 installed. The git warning is harmless — we won't need Helm plugins.

---

**Sub-step 2: Add OpenFaaS Helm chart repository**

```bash
[ec2-user@golgi-master ~]$ helm repo add openfaas https://openfaas.github.io/faas-netes/
```
```
"openfaas" has been added to your repositories
```

```bash
[ec2-user@golgi-master ~]$ helm repo update
```
```
Hang tight while we grab the latest from your chart repositories...
...Successfully got an update from the "openfaas" chart repository
Update Complete. ⎈Happy Helming!⎈
```

---

**Sub-step 3: Create Kubernetes namespaces**

OpenFaaS requires two namespaces:
- `openfaas` — for the core components (gateway, prometheus, NATS, etc.)
- `openfaas-fn` — for the deployed functions (our benchmark functions will live here)

```bash
[ec2-user@golgi-master ~]$ kubectl apply -f https://raw.githubusercontent.com/openfaas/faas-netes/master/namespaces.yml
```
```
namespace/openfaas created
namespace/openfaas-fn created
```

---

**Sub-step 4: Generate gateway password and create Kubernetes secret**

The OpenFaaS gateway uses HTTP Basic Auth. We generate a random 32-character password from `/dev/urandom` and store it as a Kubernetes secret so the gateway pods can read it at runtime.

```bash
[ec2-user@golgi-master ~]$ OPENFAAS_PASSWORD=$(head -c 16 /dev/urandom | sha256sum | head -c 32)
[ec2-user@golgi-master ~]$ echo "OPENFAAS_PASSWORD=$OPENFAAS_PASSWORD"
```
```
OPENFAAS_PASSWORD=888c7417424edcbe2a7de236be0fa023
```

```bash
[ec2-user@golgi-master ~]$ kubectl -n openfaas create secret generic basic-auth \
  --from-literal=basic-auth-user=admin \
  --from-literal=basic-auth-password="$OPENFAAS_PASSWORD"
```
```
secret/basic-auth created
```

---

**Sub-step 5: Install OpenFaaS via Helm**

This is the main installation step. We use `helm upgrade --install` which either installs fresh or upgrades an existing release (idempotent).

**First attempt — failed:**

```bash
[ec2-user@golgi-master ~]$ helm upgrade openfaas --install openfaas/openfaas \
  --namespace openfaas \
  --set functionNamespace=openfaas-fn \
  --set generateBasicAuth=false \
  --set gateway.replicas=1 \
  --set queueWorker.replicas=1 \
  --set basic_auth=true \
  --set serviceType=NodePort
```
```
Error: Kubernetes cluster unreachable: Get "http://localhost:8080/version": dial tcp 127.0.0.1:8080: connect: connection refused
```

**Why it failed:** Helm could not find the Kubernetes API server. k3s stores its kubeconfig at `/etc/rancher/k3s/k3s.yaml`, and `kubectl` finds it automatically (k3s configures this via a symlink/alias), but Helm does not — it falls back to the default `localhost:8080`, which is not where k3s runs its API server.

**Fix:** Export the `KUBECONFIG` environment variable pointing to the k3s config file:

```bash
[ec2-user@golgi-master ~]$ export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
```

**Second attempt — succeeded:**

```bash
[ec2-user@golgi-master ~]$ helm upgrade openfaas --install openfaas/openfaas \
  --namespace openfaas \
  --set functionNamespace=openfaas-fn \
  --set generateBasicAuth=false \
  --set gateway.replicas=1 \
  --set queueWorker.replicas=1 \
  --set basic_auth=true \
  --set serviceType=NodePort
```
```
Release "openfaas" does not exist. Installing it now.
NAME: openfaas
LAST DEPLOYED: Sat Apr 11 22:28:08 2026
NAMESPACE: openfaas
STATUS: deployed
REVISION: 1
TEST SUITE: None
NOTES:
To verify that openfaas has started, run:

  kubectl -n openfaas get deployments -l "release=openfaas, app=openfaas"
```

**Helm flags explained:**

| Flag | Value | Why |
|---|---|---|
| `--namespace openfaas` | Install into the `openfaas` namespace we just created |
| `--set functionNamespace=openfaas-fn` | Deploy user functions into a separate namespace for isolation |
| `--set generateBasicAuth=false` | We already created the `basic-auth` secret manually (sub-step 4) |
| `--set gateway.replicas=1` | Single gateway replica (sufficient for our scale) |
| `--set queueWorker.replicas=1` | Single queue worker for async invocations |
| `--set basic_auth=true` | Enable authentication on the gateway |
| `--set serviceType=NodePort` | Expose the gateway on a static port (`31112`) on every node — this lets us access it via `<any-node-ip>:31112` without needing an external load balancer |

---

**Sub-step 6: Wait for gateway rollout**

```bash
[ec2-user@golgi-master ~]$ kubectl -n openfaas rollout status deployment/gateway
```
```
deployment "gateway" successfully rolled out
```

The gateway pod is running and ready to accept requests.

---

**Sub-step 7: Install faas-cli**

`faas-cli` is the command-line tool for interacting with OpenFaaS — deploying functions, invoking them, checking status, etc. We will use it heavily in Phase 1.

```bash
[ec2-user@golgi-master ~]$ curl -sL https://cli.openfaas.com | sudo sh
```
```
Finding latest version from GitHub
0.18.8
Downloading package https://github.com/openfaas/faas-cli/releases/download/0.18.8/faas-cli as /tmp/faas-cli
Download complete.

Running with sufficient permissions to attempt to move faas-cli to /usr/local/bin
New version of faas-cli installed to /usr/local/bin
Creating alias 'faas' for 'faas-cli'.
  ___                   _____           ____
 / _ \ _ __   ___ _ __ |  ___|_ _  __ _/ ___|
| | | | '_ \ / _ \ '_ \| |_ / _` |/ _` \___ \
| |_| | |_) |  __/ | | |  _| (_| | (_| |___) |
 \___/| .__/ \___|_| |_|_|  \__,_|\__,_|____/
      |_|

CLI:
 commit:  bf309592e77386f69cada2f4ceecac9f35f6d206
 version: 0.18.8
```

faas-cli v0.18.8 installed. Both `faas-cli` and the alias `faas` are available.

---

**Sub-step 8: Login to OpenFaaS gateway**

```bash
[ec2-user@golgi-master ~]$ export OPENFAAS_URL=http://127.0.0.1:31112
[ec2-user@golgi-master ~]$ echo -n '888c7417424edcbe2a7de236be0fa023' | faas-cli login --username admin --password-stdin
```
```
Calling the OpenFaaS server to validate the credentials...
credentials saved for admin http://127.0.0.1:31112
```

faas-cli successfully authenticated against the gateway. Credentials are stored in `~/.openfaas/config.yml` for subsequent commands.

---

**Sub-step 9: Persist KUBECONFIG for future sessions**

To avoid the Helm `KUBECONFIG` error in future SSH sessions, we added the export to `~/.bashrc`:

```bash
[ec2-user@golgi-master ~]$ echo 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' >> ~/.bashrc
```

This means every new shell session on the master will automatically have `KUBECONFIG` set correctly for both `kubectl` and `helm`.

**OpenFaaS deployments created:**

| Deployment | Ready | Purpose |
|---|---|---|
| `gateway` | 1/1 | API gateway — receives function invocations, routes to function pods |
| `prometheus` | 1/1 | Metrics collection — scrapes function and gateway metrics |
| `alertmanager` | 1/1 | Alert routing (used by OpenFaaS auto-scaling) |
| `nats` | 1/1 | Message queue for async function invocations |
| `queue-worker` | 1/1 | Processes async invocations from the NATS queue |

**Credentials (save these):**

| Item | Value |
|---|---|
| Gateway URL | `http://127.0.0.1:31112` (on master) |
| Gateway URL (from workers) | `http://10.0.1.131:31112` |
| Username | `admin` |
| Password | `888c7417424edcbe2a7de236be0fa023` |

---

#### Step 0.17: Verify OpenFaaS — COMPLETED (2026-04-11)

**Verification 1: List deployed functions**

This should return an empty list since we haven't deployed any functions yet. If it responds at all, it confirms the gateway is running and faas-cli credentials are valid.

```bash
[ec2-user@golgi-master ~]$ export OPENFAAS_URL=http://127.0.0.1:31112
[ec2-user@golgi-master ~]$ faas-cli list
```
```
Function                      	Invocations    	Replicas
```

Empty list — exactly as expected. The gateway responded and faas-cli is authenticated.

---

**Verification 2: Gateway health endpoint**

The `/healthz` endpoint returns HTTP 200 if the gateway is healthy. We use `-sv` (silent + verbose) to see the HTTP status code.

```bash
[ec2-user@golgi-master ~]$ curl -sv http://127.0.0.1:31112/healthz
```
```
*   Trying 127.0.0.1:31112...
* Connected to 127.0.0.1 (127.0.0.1) port 31112 (#0)
> GET /healthz HTTP/1.1
> Host: 127.0.0.1:31112
> User-Agent: curl/8.5.0
> Accept: */*
>
< HTTP/1.1 200 OK
< Content-Length: 0
< Date: Sat, 11 Apr 2026 22:28:43 GMT
<
* Connection #0 to host 127.0.0.1:31112 left intact
```

HTTP 200 OK — gateway is healthy.

---

**Verification 3: All OpenFaaS deployments**

```bash
[ec2-user@golgi-master ~]$ kubectl -n openfaas get deployments -l "release=openfaas,app=openfaas"
```
```
NAME           READY   UP-TO-DATE   AVAILABLE   AGE
alertmanager   1/1     1            1           29s
gateway        1/1     1            1           29s
nats           1/1     1            1           29s
prometheus     1/1     1            1           29s
queue-worker   1/1     1            1           29s
```

All 5 deployments are `1/1 READY`:

| Component | What it does | Why we need it |
|---|---|---|
| **gateway** | HTTP API gateway — all function invocations go through this. Exposes port 31112 via NodePort. | Core component. All our benchmark scripts invoke functions through this gateway. |
| **prometheus** | Scrapes metrics from the gateway and function pods every 5 seconds. | We will query Prometheus in Phase 2 for OpenFaaS-level metrics like invocation count, duration, and in-flight requests. |
| **alertmanager** | Routes alerts from Prometheus (e.g., function failure thresholds). | Used internally by OpenFaaS auto-scaling. We won't configure custom alerts but it's required. |
| **nats** | Lightweight message broker for asynchronous function invocations. | If we invoke functions asynchronously (fire-and-forget), NATS queues the request. |
| **queue-worker** | Pulls messages from NATS and forwards them to function pods. | Works in tandem with NATS for async processing. |

---

**Result:** Steps 0.16–0.17 are complete. OpenFaaS is fully operational on our k3s cluster. The serverless platform is ready to receive function deployments in Phase 1.

---

#### Step 0.18: Install Python and Monitoring Tools on Worker Nodes — COMPLETED (2026-04-11)

**What we did:** Installed Python 3, pip, and the `perf` performance monitoring tool via `yum` on all 3 worker nodes. Then installed the Python packages needed by the metric collector (Phase 2): `flask`, `requests`, `psutil`, and `numpy`.

**Why these packages?**

| Package | Version Installed | Why we need it |
|---|---|---|
| `python3` | 3.9.25 | Already pre-installed on Amazon Linux 2023, but we needed to verify the version |
| `python3-pip` | 21.3.1 | Package installer — not pre-installed on Amazon Linux 2023 |
| `perf` | 6.1.166 | Linux performance monitoring tool — the Golgi paper uses hardware performance counters (cache misses, instructions per cycle) via `perf stat`. We will use this in Phase 2 for collecting CPU-level metrics from running containers |
| `flask` | 3.1.3 | Web framework — the metric collector agent on each worker runs as a Flask HTTP server that responds to metric queries from the master |
| `requests` | 2.25.1 | HTTP client — the metric collector uses this to push collected metrics to the master node |
| `psutil` | 7.2.2 | System monitoring library — provides CPU usage, memory usage, disk I/O, and network I/O per-process. Easier than parsing `/proc` files manually |
| `numpy` | 2.0.2 | Numerical computing — used for metric aggregation (mean, percentile calculations) before sending to the master |

**Also installed as dependencies:** `libxcrypt-compat` (required by pip).

**Sub-step 1: Install system packages via yum (all 3 workers in parallel)**

```bash
# Ran on all 3 workers simultaneously:
# worker-1 (54.173.219.56), worker-2 (44.206.236.146), worker-3 (174.129.77.19)

[ec2-user@golgi-worker-1 ~]$ sudo yum install -y python3 python3-pip perf
```
```
...
Installed:
  libxcrypt-compat-4.4.33-7.amzn2023.x86_64
  perf-1:6.1.166-197.305.amzn2023.x86_64
  python3-pip-21.3.1-2.amzn2023.0.16.noarch

Complete!
```

All 3 workers produced identical output — `python3` was already installed (part of the base AMI), so `yum` only needed to install `python3-pip`, `perf`, and the `libxcrypt-compat` dependency.

---

**Sub-step 2: Install Python packages via pip (all 3 workers in parallel)**

```bash
[ec2-user@golgi-worker-1 ~]$ pip3 install --user flask requests psutil numpy
```
```
...
Installing collected packages: zipp, markupsafe, werkzeug, jinja2, itsdangerous,
  importlib-metadata, greenlet, click, blinker, psutil, numpy, flask
Successfully installed blinker-1.9.0 click-8.1.8 flask-3.1.3 importlib-metadata-8.7.1
  itsdangerous-2.2.0 jinja2-3.1.6 markupsafe-3.0.3 numpy-2.0.2 psutil-7.2.2
  werkzeug-3.1.8 zipp-3.23.0
```

The `--user` flag installs packages into `~/.local/lib/python3.9/site-packages/` rather than system-wide, which avoids needing `sudo` and keeps the system Python clean. The `requests` package (2.25.1) was already installed system-wide as a dependency of the AWS CLI, so pip skipped it.

All 3 workers produced identical output. Identical package versions across all workers is important — it ensures the metric collector behaves the same regardless of which worker it runs on.

---

**Sub-step 3: Verify installations on all workers**

```bash
[ec2-user@golgi-worker-1 ~]$ python3 --version
Python 3.9.25

[ec2-user@golgi-worker-1 ~]$ pip3 show flask psutil numpy requests | grep -E '^(Name|Version)'
Name: Flask
Version: 3.1.3
Name: psutil
Version: 7.2.2
Name: numpy
Version: 2.0.2
Name: requests
Version: 2.25.1
```

Workers 2 and 3 returned identical output — same Python version (3.9.25) and same package versions.

---

**Sub-step 4: Verify perf tool**

```bash
[ec2-user@golgi-worker-1 ~]$ perf --version
perf version 6.1.166-197.305.amzn2023.x86_64
```

The `perf` version matches the kernel version (6.1.166) — this is correct. `perf` is tightly coupled to the kernel, so version alignment is essential.

---

#### Step 0.19: Install Python and ML Packages on Master Node — COMPLETED (2026-04-11)

**What we did:** Installed Python 3 pip, C build tools (gcc, python3-devel, libffi-devel), and then the Python packages needed for data analysis, statistical computation, visualization, and load generation in subsequent experiment phases.

**Why these packages?**

| Package | Version Installed | Why we need it |
|---|---|---|
| `flask` | 3.1.3 | Lightweight HTTP server for data collection endpoints if needed during experiments |
| `requests` | 2.32.5 | HTTP client for invoking functions via the OpenFaaS gateway from benchmark scripts |
| `numpy` | 2.0.2 | Numerical operations for latency statistics (percentile calculations, statistical tests) |
| `scikit-learn` | 1.6.1 | Statistical analysis — distribution fitting, clustering for identifying bimodal latency patterns |
| `pandas` | 2.3.3 | Data manipulation — loading and processing latency measurement CSV files |
| `matplotlib` | 3.9.4 | Plotting — generating evaluation graphs (latency CDFs, degradation curves, box plots, etc.) |
| `locust` | 2.34.0 | Load testing framework — used to generate concurrent request patterns for the concurrency sweep experiments |

**Sub-step 1: Install pip on master**

```bash
[ec2-user@golgi-master ~]$ sudo yum install -y python3 python3-pip
```
```
...
Installed:
  libxcrypt-compat-4.4.33-7.amzn2023.x86_64
  python3-pip-21.3.1-2.amzn2023.0.16.noarch

Complete!
```

---

**Sub-step 2: First attempt to install Python packages — FAILED**

```bash
[ec2-user@golgi-master ~]$ pip3 install --user flask requests numpy scikit-learn pandas matplotlib locust
```
```
...
  subprocess.CalledProcessError: Command '(cd "/tmp/pip-install-540vx4yf/
    gevent_7c1e0f92a2b94e06844e29ce8f8b05aa/deps/libev" && sh ./configure -C
    > configure-output.txt )' returned non-zero exit status 1.
  ----------------------------------------
  ERROR: Failed building wheel for gevent
Failed to build gevent
ERROR: Could not build wheels for gevent, which is required to install pyproject.toml-based projects
```

**Why it failed:** `locust` depends on `gevent`, which depends on `greenlet`, which is a C extension that compiles native code. The compilation failed because `gcc` (the C compiler) and `python3-devel` (Python header files needed for C extensions) were not installed on the master node.

**Why wasn't this needed on the workers?** Because the worker packages (`flask`, `psutil`, `numpy`, `requests`) are either pure Python or have pre-built binary wheels on PyPI. `gevent` does not have a pre-built wheel for our Python 3.9 + Amazon Linux combination, so pip tried to compile from source — and failed without a compiler.

---

**Sub-step 3: Install C build dependencies**

```bash
[ec2-user@golgi-master ~]$ sudo yum install -y gcc python3-devel libffi-devel
```
```
...
Installed:
  binutils-2.39-6.amzn2023.0.9.x86_64
  binutils-gold-2.39-6.amzn2023.0.9.x86_64
  cpp-11.5.0-5.amzn2023.0.5.x86_64
  gc-8.0.4-5.amzn2023.0.2.x86_64
  gcc-11.5.0-5.amzn2023.0.5.x86_64
  gcc-plugin-annobin-11.5.0-5.amzn2023.0.5.x86_64
  glibc-devel-2.34-231.amzn2023.0.3.x86_64
  glibc-headers-x86-2.34-231.amzn2023.0.3.noarch
  guile22-2.2.7-2.amzn2023.0.3.x86_64
  kernel-headers-1:6.1.166-197.305.amzn2023.x86_64
  libffi-devel-3.4.4-1.amzn2023.0.1.x86_64
  libmpc-1.2.1-2.amzn2023.0.2.x86_64
  libtool-ltdl-2.4.7-1.amzn2023.0.3.x86_64
  libxcrypt-devel-4.4.33-7.amzn2023.x86_64
  make-1:4.3-5.amzn2023.0.2.x86_64
  python3-devel-3.9.25-1.amzn2023.0.3.x86_64

Complete!
```

| Package | Why |
|---|---|
| `gcc` 11.5.0 | C compiler — needed to compile `gevent`'s C extensions |
| `python3-devel` 3.9.25 | Python header files (`Python.h`) — required when compiling C extensions that interface with Python |
| `libffi-devel` 3.4.4 | Foreign Function Interface headers — needed by `cffi`, a common dependency of cryptographic and low-level packages |

---

**Sub-step 4: Second attempt — SUCCEEDED**

```bash
[ec2-user@golgi-master ~]$ pip3 install --user flask requests numpy scikit-learn pandas matplotlib locust
```
```
Building wheels for collected packages: gevent
  Building wheel for gevent (pyproject.toml): started
  Building wheel for gevent (pyproject.toml): still running...
  Building wheel for gevent (pyproject.toml): finished with status 'done'
  Created wheel for gevent: filename=gevent-26.4.0-cp39-cp39-linux_x86_64.whl
    size=6091943
    sha256=df1230fbce9121f9779e73b95177897d99239e79a2d127258063a1a164fa4d26
  Stored in directory: /home/ec2-user/.cache/pip/wheels/dd/d2/3f/...
Successfully built gevent
Installing collected packages: zipp, setuptools, markupsafe, zope.interface,
  zope.event, werkzeug, jinja2, itsdangerous, importlib-metadata, greenlet,
  click, blinker, numpy, gevent, flask, charset-normalizer, certifi, brotli,
  tzdata, typing-extensions, tomli, threadpoolctl, scipy, requests, pyzmq,
  python-dateutil, pyparsing, psutil, pillow, packaging, msgpack, kiwisolver,
  joblib, importlib-resources, geventhttpclient, fonttools, flask-login,
  flask-cors, cycler, contourpy, configargparse, scikit-learn, pandas,
  matplotlib, locust
ERROR: pip's dependency resolver does not currently take into account all the
  packages that are installed. This behaviour is the source of the following
  dependency conflicts.
awscli 2.33.15 requires python-dateutil<=2.9.0,>=2.1, but you have
  python-dateutil 2.9.0.post0 which is incompatible.
Successfully installed blinker-1.9.0 brotli-1.2.0 certifi-2026.2.25
  charset-normalizer-3.4.7 click-8.1.8 configargparse-1.7.5 contourpy-1.3.0
  cycler-0.12.1 flask-3.1.3 flask-cors-6.0.2 flask-login-0.6.3
  fonttools-4.60.2 gevent-26.4.0 geventhttpclient-2.3.9 greenlet-3.2.5
  importlib-metadata-8.7.1 importlib-resources-6.5.2 itsdangerous-2.2.0
  jinja2-3.1.6 joblib-1.5.3 kiwisolver-1.4.7 locust-2.34.0 markupsafe-3.0.3
  matplotlib-3.9.4 msgpack-1.1.2 numpy-2.0.2 packaging-26.0 pandas-2.3.3
  pillow-11.3.0 psutil-7.2.2 pyparsing-3.3.2 python-dateutil-2.9.0.post0
  pyzmq-27.1.0 requests-2.32.5 scikit-learn-1.6.1 scipy-1.13.1
  setuptools-82.0.1 threadpoolctl-3.6.0 tomli-2.4.1 typing-extensions-4.15.0
  tzdata-2026.1 werkzeug-3.1.8 zipp-3.23.0 zope.event-6.0 zope.interface-8.0.1
```

**Note on the `python-dateutil` warning:** pip reports that `awscli 2.33.15` wants `python-dateutil<=2.9.0` but we installed `2.9.0.post0`. This is a trivially incompatible version (a post-release of 2.9.0) and will not cause any issues. The AWS CLI is only used locally for provisioning — it's not involved in our experiment at all.

**Note on `gevent` build time:** The `gevent` wheel took about 60 seconds to compile. pip cached the built wheel at `~/.cache/pip/wheels/`, so if we ever need to reinstall, it will be instant.

---

**Sub-step 5: Verify installations on master**

```bash
[ec2-user@golgi-master ~]$ python3 --version
Python 3.9.25

[ec2-user@golgi-master ~]$ pip3 show flask requests numpy scikit-learn pandas matplotlib locust | grep -E '^(Name|Version)'
Name: Flask
Version: 3.1.3
Name: requests
Version: 2.32.5
Name: numpy
Version: 2.0.2
Name: scikit-learn
Version: 1.6.1
Name: pandas
Version: 2.3.3
Name: matplotlib
Version: 3.9.4
Name: locust
Version: 2.34.0
```

All 7 packages installed successfully with the expected versions.

---

**Sub-step 6: Install locust on the load generator node**

The plan mentions locust on the master, but the load generator (`golgi-loadgen` / `44.211.68.203`) is where we will actually run load tests from (Phase 6). We installed locust there too for flexibility.

```bash
[ec2-user@golgi-loadgen ~]$ sudo yum install -y python3-pip gcc python3-devel libffi-devel
```
```
...
Installed:
  ...gcc-11.5.0-5.amzn2023.0.5.x86_64
  ...python3-devel-3.9.25-1.amzn2023.0.3.x86_64
  ...python3-pip-21.3.1-2.amzn2023.0.16.noarch
  ...make-1:4.3-5.amzn2023.0.2.x86_64

Complete!
```

```bash
[ec2-user@golgi-loadgen ~]$ pip3 install --user locust requests
```
```
...
  Building wheel for gevent (pyproject.toml): finished with status 'done'
  Created wheel for gevent: filename=gevent-26.4.0-cp39-cp39-linux_x86_64.whl
    size=6091891
    sha256=9298e8d2abcf807cb8eab16fff2c569d856fa2a5aba1cf3d1b9b11005db2856d
Successfully built gevent
Installing collected packages: zipp, setuptools, markupsafe, zope.interface,
  zope.event, werkzeug, jinja2, itsdangerous, importlib-metadata, greenlet,
  click, blinker, gevent, flask, charset-normalizer, certifi, brotli,
  typing-extensions, tomli, requests, pyzmq, psutil, msgpack, geventhttpclient,
  flask-login, flask-cors, configargparse, locust
Successfully installed blinker-1.9.0 brotli-1.2.0 certifi-2026.2.25
  charset-normalizer-3.4.7 click-8.1.8 configargparse-1.7.5 flask-3.1.3
  flask-cors-6.0.2 flask-login-0.6.3 gevent-26.4.0 geventhttpclient-2.3.9
  greenlet-3.2.5 importlib-metadata-8.7.1 itsdangerous-2.2.0 jinja2-3.1.6
  locust-2.34.0 markupsafe-3.0.3 msgpack-1.1.2 psutil-7.2.2 pyzmq-27.1.0
  requests-2.32.5 setuptools-82.0.1 tomli-2.4.1 typing-extensions-4.15.0
  werkzeug-3.1.8 zipp-3.23.0 zope.event-6.0 zope.interface-8.0.1
```

---

#### cgroup Version Verification — COMPLETED (2026-04-11)

**Why this matters:** The Golgi paper collects per-container resource metrics (CPU, memory, I/O) by reading cgroup files. Linux has two cgroup versions:

- **cgroup v1** (pre-2022): Each resource controller (cpu, memory, blkio) has its own directory hierarchy under `/sys/fs/cgroup/<controller>/`. The paper was likely developed on this version.
- **cgroup v2** (2022+): A unified hierarchy — all controllers are in a single tree under `/sys/fs/cgroup/`. Amazon Linux 2023 uses cgroup v2.

The metric collection paths in Phase 2 will depend on which version is running.

```bash
[ec2-user@golgi-worker-1 ~]$ stat -fc %T /sys/fs/cgroup/
cgroup2fs
```

**Result: cgroup v2** (as expected for Amazon Linux 2023).

```bash
[ec2-user@golgi-worker-1 ~]$ ls /sys/fs/cgroup/
```
```
cgroup.controllers
cgroup.max.depth
cgroup.max.descendants
cgroup.pressure
cgroup.procs
cgroup.stat
cgroup.subtree_control
cgroup.threads
cpu.pressure
cpu.stat
cpuset.cpus.effective
cpuset.mems.effective
dev-hugepages.mount
dev-mqueue.mount
init.scope
io.cost.model
io.cost.qos
io.pressure
io.stat
kubepods.slice
memory.numa_stat
memory.pressure
memory.reclaim
memory.stat
misc.capacity
sys-fs-fuse-connections.mount
sys-kernel-config.mount
sys-kernel-debug.mount
sys-kernel-tracing.mount
system.slice
user.slice
```

**Key observations for Phase 2:**

| cgroup v2 file | What it provides | Golgi metric it maps to |
|---|---|---|
| `cpu.stat` | CPU usage time in microseconds | CPU utilization |
| `memory.stat` | Memory usage breakdown (anon, file, slab, etc.) | Memory utilization |
| `io.stat` | Block I/O bytes read/written per device | Disk I/O |
| `cpu.pressure` | CPU pressure stall information (PSI) | CPU contention indicator |
| `memory.pressure` | Memory pressure stall information | Memory contention indicator |

The `kubepods.slice` directory is where k3s places its container cgroups. In Phase 2, we will navigate into this directory to find per-container cgroup files at paths like:
```
/sys/fs/cgroup/kubepods.slice/kubepods-burstable.slice/kubepods-burstable-pod<UID>.slice/cri-containerd-<container-ID>.scope/
```

---

#### Phase 0 Checkpoint — ALL PASSED (2026-04-11)

The plan specifies a checklist of items to verify before moving to Phase 1. Here is the full checkpoint with results:

```bash
[ec2-user@golgi-master ~]$ kubectl get nodes
```
```
NAME             STATUS   ROLES           AGE   VERSION
golgi-master     Ready    control-plane   33m   v1.34.6+k3s1
golgi-worker-1   Ready    <none>          32m   v1.34.6+k3s1
golgi-worker-2   Ready    <none>          31m   v1.34.6+k3s1
golgi-worker-3   Ready    <none>          29m   v1.34.6+k3s1
```

```bash
[ec2-user@golgi-master ~]$ kubectl -n openfaas get pods
```
```
NAME                            READY   STATUS    RESTARTS      AGE
alertmanager-fb97cfc46-shcnk    1/1     Running   0             13m
gateway-5f8bf55dfb-2n59b        2/2     Running   1 (13m ago)   13m
nats-5bf8cfb54-vr2c5            1/1     Running   0             13m
prometheus-85cb68fd7b-vmfvh     1/1     Running   0             13m
queue-worker-65bc696bcf-sd5rn   1/1     Running   1 (13m ago)   13m
```

```bash
[ec2-user@golgi-master ~]$ export OPENFAAS_URL=http://127.0.0.1:31112
[ec2-user@golgi-master ~]$ faas-cli list
```
```
Function                      	Invocations    	Replicas
```

```bash
[ec2-user@golgi-master ~]$ curl -s -o /dev/null -w 'HTTP %{http_code}' http://127.0.0.1:31112/healthz
HTTP 200
```

**Checklist results:**

| # | Check | Status | Evidence |
|---|---|---|---|
| 1 | AWS VPC, subnet, and security group created | PASS | `vpc-0613c37c5cde4ea3c`, `subnet-059304ec96b5a1958`, `sg-06b976c1028e80262` |
| 2 | 5 EC2 instances running | PASS | All 5 in `running` state (verified via `aws ec2 describe-instances`) |
| 3 | k3s cluster operational with 4 nodes (1 server + 3 agents) | PASS | All 4 nodes `Ready`, Kubernetes v1.34.6 |
| 4 | OpenFaaS installed and gateway accessible | PASS | 5/5 deployments `Ready`, gateway returns HTTP 200 |
| 5 | faas-cli authenticated | PASS | `faas-cli list` returns successfully |
| 6 | Python + dependencies installed on all nodes | PASS | Python 3.9.25 on all nodes; workers have flask/psutil/numpy/requests; master has scikit-learn/pandas/matplotlib/locust; loadgen has locust |
| 7 | cgroup version identified | PASS | cgroup v2 (`cgroup2fs`) on Amazon Linux 2023 |
| 8 | All SSH connections working | PASS | Successfully SSH'd to all 5 nodes during this session |
| 9 | All private IPs recorded | PASS | See Resource Reference Table at top of this document |

**All 9 checks passed. Phase 0 is COMPLETE.**

---

### Software versions summary (all nodes)

| Software | Version | Location |
|---|---|---|
| Amazon Linux | 2023.11.20260406 | All 5 nodes |
| Kernel | 6.1.166-197.305.amzn2023 | All 5 nodes |
| Python | 3.9.25 | All 5 nodes |
| pip | 21.3.1 | All 5 nodes |
| k3s / Kubernetes | v1.34.6+k3s1 | Master + 3 workers |
| containerd | 2.2.2 | Master + 3 workers |
| Helm | 3.20.2 | Master only |
| faas-cli | 0.18.8 | Master only |
| OpenFaaS | Revision 1 (Helm) | Master (gateway runs here) |
| gcc | 11.5.0 | Master + loadgen (for compiling C extensions) |
| perf | 6.1.166 | 3 workers only |
| locust | 2.34.0 | Master + loadgen |
| scikit-learn | 1.6.1 | Master only |
| pandas | 2.3.3 | Master only |
| matplotlib | 3.9.4 | Master only |
| flask | 3.1.3 | All 5 nodes (master, 3 workers, loadgen) |
| psutil | 7.2.2 | 3 workers + master + loadgen |
| numpy | 2.0.2 | 3 workers + master |

---

**Phase 0 is complete. Ready to proceed to Phase 1 — Benchmark Functions.**
