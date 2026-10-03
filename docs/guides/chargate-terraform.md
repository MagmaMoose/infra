# Terraform security suppression conventions

Chargate integrates multiple security scanners into the PR pipeline. When a scanner finds a
security issue in Terraform code that you have deliberately accepted, suppress it in-source using
the syntax your scanner honours. A suppression **must** carry a one-line justification; you are
responsible for resolving net-new findings before requesting review.

## Suppression syntax

Terraform code in `terraform/aws/` is scanned by three tools. Each uses its own comment marker:

| Tool | Syntax | Example |
|---|---|---|
| Checkov | `# checkov:skip=<RULE>:<justification>` | `# checkov:skip=CKV_AWS_158:No KMS CMK for the log group. A CMK bills per key per month and the logs carry no secret.` |
| Semgrep (nosemgrep) | `# nosemgrep: <RULE>` | `# nosemgrep: terraform.aws.security.aws-provider-static-credentials.aws-provider-static-credentials` |
| DevSkim | `# DevSkim: ignore <RULE>` | `# DevSkim: ignore DS162092` |

Comment placement:

- **Checkov** and **DevSkim**: inline comment on the same line as the value being suppressed
- **Semgrep**: inline comment on the resource block line, or in a preceding comment block

## Mandatory justification

Every suppression **must explain why** the finding is not a problem. The justification goes in
the comment itself, not in a commit message or PR description — future readers need it at the
point of the code.

A justification that fails the common-sense test:

- ❌ `# checkov:skip=CKV_AWS_158:Needed for the product` ← vague, does not explain why
- ❌ `# checkov:skip=CKV_AWS_158:Legacy code` ← a reason to fix it, not to suppress it
- ✅ `# checkov:skip=CKV_AWS_158:No KMS CMK for the log group. A CMK bills per key per month and the logs carry no secret — the DSN and the JWKS are environment variables.`
- ✅ `# checkov:skip=CKV_AWS_116:No DLQ. The function is invoked synchronously, so there is no async failure path a DLQ could catch.`

## Before requesting review

Net-new findings are scanned at PR time and block merge. You are responsible for resolving them
before requesting review — either by fixing the code or by adding the appropriate suppression
with a justification. Do not ask a reviewer to clear findings on your behalf; do not suppress
findings you do not fully understand.

## Examples in the codebase

- **Checkov suppression**: `terraform/aws/modules/dunmir-platform/lambda.tf:263`
- **DevSkim suppression**: `terraform/aws/localstack/localstack_provider.tf:50`
- **Semgrep suppression**: `terraform/aws/localstack/localstack_provider.tf:32`
