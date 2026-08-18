# The Cost and Usage export (CUR 2.0), and the exact columns the handler reads.
#
# THE EXPORT ITSELF IS FREE. AWS charges nothing to generate or deliver a data export; the
# only cost is the S3 bytes it lands in, which storage.tf caps three separate ways. This is
# the whole reason the stack reads a file instead of calling Cost Explorer, which bills
# $0.01 per request with no free allowance — $0.30 a month to report on $0.00004 of spend.
#
# THE QUERY AND THE HANDLER ARE ONE CONTRACT. Every column below is named in handler.py as a
# COL_* constant. Removing one here does not fail the apply and does not fail the function;
# it produces a report of zeros, which is the one failure mode a cost report must not have.
# Change them together.
resource "aws_bcmdataexports_export" "cur" {
  provider = aws.us_east_1

  export {
    name        = var.name_prefix
    description = "Daily per-account cost and usage, read by the ${var.name_prefix} Lambda."

    data_query {
      # line_item_usage_type and line_item_usage_amount are NOT for the cost report — they
      # are what lets the free-tier report attribute an organisation-wide allowance back to
      # the account consuming it. GetFreeTierUsage reports the org total against the limit
      # and has no account dimension, so without these two columns the "who is the biggest
      # spender" question has no answer at all.
      query_statement = join(" ", [
        "SELECT",
        join(", ", [
          "line_item_usage_account_id",
          "line_item_usage_start_date",
          "line_item_product_code",
          "line_item_unblended_cost",
          "line_item_usage_type",
          "line_item_usage_amount",
        ]),
        "FROM COST_AND_USAGE_REPORT",
      ])

      table_configurations = {
        COST_AND_USAGE_REPORT = {
          # DAILY is what makes "yesterday" answerable. HOURLY would multiply the row count
          # by 24 for a report that never asks a question finer than a day.
          TIME_GRANULARITY                      = "DAILY"
          INCLUDE_RESOURCES                     = "FALSE"
          INCLUDE_MANUAL_DISCOUNT_COMPATIBILITY = "FALSE"
          INCLUDE_SPLIT_COST_ALLOCATION_DATA    = "FALSE"
        }
      }
    }

    destination_configurations {
      s3_destination {
        s3_bucket = aws_s3_bucket.cur.id
        s3_prefix = var.export_prefix
        s3_region = aws_s3_bucket.cur.region

        s3_output_configurations {
          compression = "GZIP"
          format      = "TEXT_OR_CSV"
          output_type = "CUSTOM"
          # OVERWRITE_REPORT, not CREATE_NEW_REPORT. The latter keeps every version AWS has
          # ever written for the billing period, which is the difference between a bucket
          # that stays at a few KB and one that grows every day forever.
          overwrite = "OVERWRITE_REPORT"
        }
      }
    }

    refresh_cadence {
      frequency = "SYNCHRONOUS"
    }
  }

  depends_on = [aws_s3_bucket_policy.cur]
}
