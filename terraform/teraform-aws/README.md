# AWS EC2 deployment

Set `ssh_cidr` in `terraform.tfvars` to the external server's public IPv4 address
with `/32` (or its trusted network CIDR). The instance receives a public IP and
allows TCP port 22 from that source. The selected default subnet must have a route
to an internet gateway. `key_name` must identify an existing EC2 key pair in the
configured region; SSH requires its matching private key on the external server.

Authenticate Terraform using an AWS shared credentials profile or the process
environment variables `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`. Temporary
credentials also require `AWS_SESSION_TOKEN`. Do not put AWS secrets in Terraform
files or commit them to Git.

In Bash (including Git Bash), load credentials with interactive prompts:

```bash
source ./aws-env.sh
terraform init
terraform plan -out=deployment.tfplan
terraform apply deployment.tfplan
```

The script exports credentials only in that shell; it does not save them to disk
or make them available to a separate Codex process. Source it again in each new
shell. A session token is optional for long-term keys and required for temporary
credentials. To clear credentials, run
`unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN`.

Run from this directory:

```powershell
# If using an existing named AWS credentials profile:
$env:AWS_PROFILE = 'your-profile'
terraform init
terraform fmt -check
terraform validate
terraform plan '-out=deployment.tfplan'
terraform apply deployment.tfplan
terraform output ssh_command
```

Terraform has been installed locally for this workspace task at
`$env:LOCALAPPDATA\DevOpsTools\terraform\terraform.exe`; if it is not on PATH,
invoke that executable with PowerShell's `&` operator.

The public IP can change after an instance stop/start. Deployments incur AWS
charges. Terraform state and plan files are ignored by Git.
