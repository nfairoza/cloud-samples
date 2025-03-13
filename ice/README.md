# AWS Capacity Error Tracking

This repo provides information and commands for tracking and managing Insufficient Capacity Errors (ICE) in AWS environments.

## Error Code Reference

- **Insufficient Capacity Errors (ICE)**: `InsufficientInstanceCapacity`
- **Auto Scaling Groups Capacity Errors**: `InsufficientCapacity`

## Methods for Tracking ICE Errors

### CloudTrail Logs

You can use AWS CloudTrail to identify instance launch failures due to capacity constraints. The following command searches for `RunInstances` API call failures specifically for AMD instances:

```bash
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=RunInstances \
  --query 'Events[?contains(CloudTrailEvent, `InsufficientInstanceCapacity`) && (contains(CloudTrailEvent, `m6a`) || contains(CloudTrailEvent, `c6a`) || contains(CloudTrailEvent, `r6a`) || contains(CloudTrailEvent, `m7a`) || contains(CloudTrailEvent, `c7a`) || contains(CloudTrailEvent, `r7a`))].{Time: EventTime, InstanceType: CloudTrailEvent}' \
  --output text > ICE_Report.csv
```

## Tracking Failed Capacity Reservations

To monitor failed capacity reservation attempts for AMD instances, use the following command:

```bash
aws ec2 describe-capacity-reservations \
  --query "CapacityReservations[?State=='failed' && (InstanceType=='m6a.*' || InstanceType=='c6a.*' || InstanceType=='r6a.*' || InstanceType=='m7a.*' || InstanceType=='c7a.*' || InstanceType=='r7a.*')].{InstanceType:InstanceType, AvailabilityZone:AvailabilityZone, CapacityRequested:TotalInstanceCount, StartTime:StartDate, EndTime:EndDate}" \
  --output text > failed_capacity_reservations.csv
```

### AWS EC2 Instance Status Monitoring

Monitor instance launch failures with a custom script:

```bash
#!/bin/bash
aws ec2 describe-instances \
  --filters "Name=instance-state-name,Values=pending" \
  --query 'Reservations[*].Instances[*].[InstanceId,StateTransitionReason]' \
  --output text | grep "capacity"
```


### AWS Health Dashboard / AWS Personal Health Dashboard

The AWS Health Dashboard provides personalized information about service health and resource performance:

- Access via AWS Management Console → AWS Health Dashboard
- Set up AWS Health Aware to receive notifications about ICE issues
- You need a Business, Enterprise On-Ramp, or Enterprise Support plan subscription to access the AWS Health API's describe-events operation.
- Use AWS Health API to programmatically monitor for capacity issues

```bash
aws health describe-events \
  --filter 'eventTypeCodes=AWS_EC2_INSUFFICIENT_CAPACITY,eventStatusCodes=open,upcoming'
```

### EC2 API Error Rate Monitoring with Cloudwatch logs

You can use CloudWatch Logs Insights to search through your logs for patterns related to Insufficient Capacity Errors
Monitor EC2 API calls for error responses using AWS X-Ray or custom logging.

```bash
aws logs start-query \
  --log-group-name YOUR-LOG-GROUP \
  --start-time $(date -d '1 hour ago' +%s) \
  --end-time $(date +%s) \
  --query-string 'filter @message like /InsufficientInstanceCapacity/ | stats count() as errorCount by bin(30m)'
```

### CloudWatch Metrics and Alarms

Set up CloudWatch metrics and alarms to monitor and be notified of capacity-related issues with Auto Scaling groups:

```bash
aws cloudwatch put-metric-alarm \
  --alarm-name ASGCapacityErrorAlarm \
  --alarm-description "Alarm when ASG fails to launch instances due to capacity" \
  --metric-name GroupTerminatingCapacity \
  --namespace AWS/AutoScaling \
  --statistic Maximum \
  --period 60 \
  --threshold 0 \
  --comparison-operator GreaterThanThreshold \
  --dimensions Name=AutoScalingGroupName,Value=YOUR-ASG-NAME \
  --evaluation-periods 2 \
  --alarm-actions <your sns topic ARN>
```


## Troubleshooting

1. Check for ICE errors using the CloudTrail commands above
2. Verify if the errors are specific to certain instance types or regions
3. Try launching instances in different Availability Zones
4. Consider using different instance families with similar specifications
5. Contact AWS Support for persistent capacity issues


## References

- [CloudTrail Event Reference](https://docs.aws.amazon.com/awscloudtrail/latest/userguide/cloudtrail-event-reference-record-contents.html)
- [EC2 API Error Reference](https://docs.aws.amazon.com/AWSEC2/latest/APIReference/errors-overview.html)
- [EC2 Capacity Reservations Documentation](https://docs.aws.amazon.com/cli/latest/reference/ec2/describe-capacity-reservations.html)
- [AWS Personal Health Dashboard](https://docs.aws.amazon.com/health/latest/ug/what-is-aws-health.html)
- [CloudWatch Metrics for Auto Scaling](https://docs.aws.amazon.com/autoscaling/ec2/userguide/ec2-auto-scaling-cloudwatch-monitoring.html)
- [AWS Compute Optimizer](https://docs.aws.amazon.com/compute-optimizer/latest/ug/what-is-compute-optimizer.html)
- [EC2 Fleet Documentation](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-fleet.html)
