# The backstop.
#
# EVERY OTHER CONTROL IN THIS REPO IS A DESIGN CHOICE; this one assumes those choices were
# wrong. The stack is built to be free, the S3 bucket is capped three ways, and the report is
# meant to make sub-cent spend visible before it becomes real spend — but all of that depends
# on the report actually arriving and someone actually reading it. A budget is the thing that
# speaks when nobody is looking.
#
# TWO BUDGETS ARE FREE PER ACCOUNT and this account had none, so this costs nothing. Beyond
# two, AWS charges $0.02/budget/day — which would itself be a surprise bill, so do not add a
# third here without meaning to.
#
# It is deliberately NOT a limit: AWS Budgets cannot stop spend, only report it. Nothing in
# AWS can hard-cap an account's bill. Both thresholds are set because they answer different
# questions — ACTUAL says money has already gone, FORECASTED says the month's trajectory says
# it will, which on a stack that should cost nothing is days of warning rather than none.
resource "aws_budgets_budget" "org" {
  name         = "${var.name_prefix}-org-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # In the management account this covers the whole organisation's consolidated spend, which
  # is the number that actually reaches the card.

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 100
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.cost.arn]
  }

  # A tenth of the budget, forecast. On an organisation whose expected spend is a fraction of
  # a cent, a forecast of even a few cents already means something changed — and this fires
  # while there is still most of a month left to do something about it.
  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 10
    threshold_type            = "PERCENTAGE"
    notification_type         = "FORECASTED"
    subscriber_sns_topic_arns = [aws_sns_topic.cost.arn]
  }
}
