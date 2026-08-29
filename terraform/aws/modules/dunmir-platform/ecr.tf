# The registry the function pulls its image from.
#
# WHY IT IS HERE AT ALL. `image_uri` used to be a bare input and the repository was expected to
# exist already, created by hand before the first apply. That is a cold-start trap — the runbook
# said "create an ECR repository" in prose and nothing enforced it — and it also left ECR out of
# the free-tier accounting entirely, which was wrong twice over: the module's own cost note
# claimed RDS was "the only" line item that is not permanently free, and ECR's 500 MB allowance
# is a TWELVE-MONTH tier, not an always-free one. The image is ~250 MB, so two retained tags
# already exceed it.
#
# Lambda cannot pull from a third-party registry, so this has to be ECR, in this account and
# this region. That is why `docker-bake.hcl`'s `lambda` target sits outside the `default` group
# that publishes everything else to GHCR.

resource "aws_ecr_repository" "backend" {
  count = var.localstack ? 0 : 1

  name = var.ecr_repository_name

  # Immutable tags. Lambda resolves a tag to a digest ONCE, at update time, so re-pushing the
  # same tag does not redeploy — the function silently keeps running whatever it resolved
  # before, and the deploy looks like it worked. Making tags immutable turns that silent
  # non-deploy into a push that fails loudly.
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    # Free on push. It will not stop a bad image deploying, but it is the difference between
    # learning about a base-image CVE from a findings list and learning about it from a bulletin.
    scan_on_push = true
  }

  encryption_configuration {
    # AES256, not KMS: the image is built from public base layers and this repository's own
    # source, and a customer-managed key here would add a per-request charge and another key to
    # lose in exchange for encrypting nothing secret.
    encryption_type = "AES256"
  }

  tags = { Name = var.ecr_repository_name }
}

# Without this the repository grows forever. Every push from the publish workflow adds ~250 MB,
# the free allowance is 500 MB for twelve months, and storage past it is billed per GB-month —
# so an untended repository is precisely the "bill that grows without anyone deciding it should"
# this module refuses elsewhere (storage autoscaling, log retention).
#
# Ten tagged images is roughly a quarter's worth of releases and comfortably more than any
# rollback has ever needed.
resource "aws_ecr_lifecycle_policy" "backend" {
  count = var.localstack ? 0 : 1

  repository = aws_ecr_repository.backend[0].name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after a day — these are build leftovers, not artefacts"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep the last 10 tagged images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = { type = "expire" }
      },
    ]
  })
}
