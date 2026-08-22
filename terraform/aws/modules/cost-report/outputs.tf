output "function_name" {
  description = "Invoke this by hand to send a report immediately: aws lambda invoke --function-name <this> /dev/stdout"
  value       = aws_lambda_function.report.function_name
}

output "topic_arn" {
  description = "The SNS topic the report is published to."
  value       = aws_sns_topic.cost.arn
}

output "schedule_name" {
  description = "The EventBridge schedule driving the daily report."
  value       = one(aws_scheduler_schedule.daily[*].name)
}
